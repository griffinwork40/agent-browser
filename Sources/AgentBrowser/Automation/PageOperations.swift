import AppKit
import WebKit

// MARK: - Page Operations (Async)
//
// Async page.read, page.eval, page.screenshot, content extraction,
// and shared parsing helpers.
// Extension of BrowserAutomationService extracted for the 350 LOC rule.

extension BrowserAutomationService {

    // MARK: - Data Types

    struct PageContent: Codable, Sendable {
        let id: String
        let title: String
        let url: String?
        let content: String
        let format: String        // "markdown", "text", or "html"
        let mode: String?         // "summary", "main", "full" (nil for text/html)
        let characters: Int
        let truncated: Bool
        let extractionTime: Double // seconds
    }

    struct JSEvalResult: Codable, Sendable {
        let id: String
        let value: String?        // JSON-encoded result, null if void
        let type: String          // "string", "number", "boolean", "object", "null", "undefined"
        let error: String?        // non-nil if JS threw
    }

    struct ScreenshotInfo: Codable, Sendable {
        let id: String
        let width: Int
        let height: Int
        let byteLength: Int
        let encoding: String      // "base64"
        let data: String          // base64-encoded PNG
    }

    struct ExtractedContent {
        let content: String
        let format: String
        let mode: String?
        let truncated: Bool
    }

    // MARK: - Read Page (Async)

    /// Read content from the live DOM.
    ///
    /// Formats:
    /// - "markdown": lightweight semantic extraction (headings, paragraphs, links, lists)
    /// - "text": raw document.body.innerText
    /// - "html": full document HTML
    func readPageResponse(
        id: String, format: String, mode: String?, query: String?, budget: Int?
    ) async -> AgentResponse {
        guard let tab = resolveTab(id) else {
            return .failure(code: ErrorCode.tabNotFound, message: "No tab with id: \(id)")
        }

        let start = CFAbsoluteTimeGetCurrent()

        do {
            let result = try await extractContent(
                from: tab.webView, format: format, mode: mode, query: query, budget: budget
            )
            let elapsed = CFAbsoluteTimeGetCurrent() - start
            return .success(PageContent(
                id: tab.id.uuidString,
                title: tab.title,
                url: tab.url?.absoluteString,
                content: result.content,
                format: result.format,
                mode: result.mode,
                characters: result.content.count,
                truncated: result.truncated,
                extractionTime: (elapsed * 1000).rounded() / 1000
            ))
        } catch {
            return .failure(code: ErrorCode.extractionFailed, message: error.localizedDescription)
        }
    }

    // MARK: - Execute JavaScript (Async)

    func evalJSResponse(id: String, script: String) async -> AgentResponse {
        guard let tab = resolveTab(id) else {
            return .failure(code: ErrorCode.tabNotFound, message: "No tab with id: \(id)")
        }

        let wrappedScript = Self.wrapUserScript(script)

        do {
            let raw = try await evaluateJS(on: tab.webView, script: wrappedScript)
            return Self.parseEvalResult(raw: raw, tabID: tab.id.uuidString)
        } catch {
            return .failure(code: ErrorCode.javaScriptError, message: error.localizedDescription)
        }
    }

    // MARK: - Screenshot (Async)

    func screenshotResponse(id: String) async -> AgentResponse {
        guard let tab = resolveTab(id) else {
            return .failure(code: ErrorCode.tabNotFound, message: "No tab with id: \(id)")
        }

        do {
            let image = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<NSImage, Error>) in
                let config = WKSnapshotConfiguration()
                config.afterScreenUpdates = true
                tab.webView.takeSnapshot(with: config) { image, error in
                    if let image {
                        cont.resume(returning: image)
                    } else {
                        cont.resume(throwing: NSError(
                            domain: "AgentBrowser", code: -1,
                            userInfo: [NSLocalizedDescriptionKey: error?.localizedDescription ?? "Unknown snapshot error"]
                        ))
                    }
                }
            }

            return Self.encodeScreenshot(image: image, tabID: tab.id.uuidString)
        } catch {
            return .failure(code: ErrorCode.screenshotFailed, message: error.localizedDescription)
        }
    }

    // MARK: - Content Extraction

    /// Unified content extraction with mode/query/budget support.
    func extractContent(
        from webView: WKWebView, format: String, mode: String?, query: String?, budget: Int?
    ) async throws -> ExtractedContent {
        switch format {
        case "html":
            let script = "document.documentElement ? document.documentElement.outerHTML : ''"
            let content = try await evaluateJS(on: webView, script: script) as? String ?? ""
            return ExtractedContent(content: content, format: "html", mode: nil, truncated: false)
        case "text":
            let script = "document.body ? document.body.innerText : ''"
            let content = try await evaluateJS(on: webView, script: script) as? String ?? ""
            return ExtractedContent(content: content, format: "text", mode: nil, truncated: false)
        default: // "markdown"
            return try await extractMarkdown(from: webView, mode: mode, query: query, budget: budget)
        }
    }

    /// Extract markdown content with bounded/full modes.
    private func extractMarkdown(
        from webView: WKWebView, mode: String?, query: String?, budget: Int?
    ) async throws -> ExtractedContent {
        let readMode = ContentExtraction.ReadMode(rawValue: mode ?? "main") ?? .main
        let effectiveBudget = budget ?? ContentExtraction.defaultBudget(for: readMode)

        let script: String
        switch readMode {
        case .summary:
            script = ContentExtraction.summaryScript(budget: effectiveBudget, query: query)
        case .main:
            script = ContentExtraction.mainContentScript(budget: effectiveBudget, query: query)
        case .full, .text, .html:
            script = ContentExtraction.fullMarkdownScript
        }

        if readMode == .full {
            let content = try await evaluateJS(on: webView, script: script) as? String ?? ""
            return ExtractedContent(content: content, format: "markdown", mode: "full", truncated: false)
        }

        // summary and main modes return JSON with metadata
        let raw = try await evaluateJS(on: webView, script: script)
        if let jsonString = raw as? String,
           let data = jsonString.data(using: .utf8),
           let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let content = dict["content"] as? String ?? ""
            let truncated = dict["truncated"] as? Bool ?? false
            return ExtractedContent(
                content: content, format: "markdown",
                mode: readMode.rawValue, truncated: truncated
            )
        }
        let content = (raw as? String) ?? ""
        return ExtractedContent(content: content, format: "markdown", mode: readMode.rawValue, truncated: false)
    }

    // MARK: - Shared Parsing Helpers

    /// Wrap a user-provided JS snippet for safe evaluation with type capture.
    static func wrapUserScript(_ script: String) -> String {
        """
        (function() {
            try {
                var __r = (function() { \(script) })();
                var __t = (typeof __r);
                if (__r === undefined) return JSON.stringify({__v: null, __t: "undefined"});
                if (__r === null) return JSON.stringify({__v: null, __t: "null"});
                return JSON.stringify({__v: __r, __t: __t});
            } catch(e) {
                return JSON.stringify({__e: e.message || String(e)});
            }
        })()
        """
    }

    /// Parse a wrapped JS eval result into an AgentResponse.
    static func parseEvalResult(raw: Any?, tabID: String) -> AgentResponse {
        guard let jsonString = raw as? String,
              let data = jsonString.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .success(JSEvalResult(
                id: tabID, value: String(describing: raw),
                type: "unknown", error: nil
            ))
        }

        if let err = dict["__e"] as? String {
            return .success(JSEvalResult(id: tabID, value: nil, type: "error", error: err))
        }

        let type = dict["__t"] as? String ?? "unknown"
        let value = dict["__v"]

        let valueJSON: String?
        if value is NSNull {
            valueJSON = "null"
        } else if let valueData = try? JSONSerialization.data(withJSONObject: value as Any) {
            valueJSON = String(data: valueData, encoding: .utf8)
        } else {
            valueJSON = String(describing: value)
        }

        return .success(JSEvalResult(id: tabID, value: valueJSON, type: type, error: nil))
    }

    /// Encode an NSImage screenshot as PNG base64 into an AgentResponse.
    static func encodeScreenshot(image: NSImage, tabID: String) -> AgentResponse {
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let pngData = bitmap.representation(using: .png, properties: [:]) else {
            return .failure(code: ErrorCode.screenshotFailed, message: "Failed to encode PNG")
        }

        return .success(ScreenshotInfo(
            id: tabID,
            width: Int(image.size.width),
            height: Int(image.size.height),
            byteLength: pngData.count,
            encoding: "base64",
            data: pngData.base64EncodedString()
        ))
    }
}
