import AppKit
import WebKit

/// Transport-independent automation API over live browser tabs.
///
/// This is the single point of entry for any external control surface
/// (HTTP server, CLI, MCP, XPC). It operates on the SAME live WKWebView
/// instances the human is using. No headless browser. No duplicate sessions.
///
/// All methods are @MainActor because WKWebView operations must run on main.
@MainActor
final class BrowserAutomationService {
    private let tabManager: TabManager

    init(tabManager: TabManager) {
        self.tabManager = tabManager
    }

    // MARK: - Callback-based Dispatch (for HTTP server)

    /// Dispatch via completion handler. Avoids async/await so the main run loop
    /// stays free for WKWebView's evaluateJavaScript callbacks. This is the
    /// primary entry point for the HTTP server.
    func dispatchWithCallback(_ request: AgentRequest, completion: @escaping (AgentResponse) -> Void) {
        guard request.version == 1 else {
            completion(.failure(code: ErrorCode.badRequest, message: "Unsupported protocol version: \(request.version)"))
            return
        }

        let params = request.params?.mapValues(\.value) ?? [:]

        switch request.method {
        // Sync operations -- respond immediately
        case "tabs.list":
            completion(.success(listTabs()))
        case "tabs.get":
            guard let id = params["id"] as? String else {
                completion(.failure(code: ErrorCode.invalidParams, message: "Missing 'id' parameter")); return
            }
            completion(getTabResponse(id: id))
        case "tabs.open":
            guard let url = params["url"] as? String else {
                completion(.failure(code: ErrorCode.invalidParams, message: "Missing 'url' parameter")); return
            }
            completion(openURLResponse(url))

        // Async operations -- use callback-based WKWebView APIs
        case "page.read":
            guard let id = params["id"] as? String else {
                completion(.failure(code: ErrorCode.invalidParams, message: "Missing 'id' parameter")); return
            }
            let format = params["format"] as? String ?? "markdown"
            let mode = params["mode"] as? String
            let query = params["query"] as? String
            let budget = params["budget"] as? Int
            readPageCallback(id: id, format: format, mode: mode, query: query, budget: budget, completion: completion)
        case "page.eval":
            guard let id = params["id"] as? String, let script = params["script"] as? String else {
                completion(.failure(code: ErrorCode.invalidParams, message: "Missing 'id' or 'script' parameter")); return
            }
            evalJSCallback(id: id, script: script, completion: completion)
        case "page.screenshot":
            guard let id = params["id"] as? String else {
                completion(.failure(code: ErrorCode.invalidParams, message: "Missing 'id' parameter")); return
            }
            screenshotCallback(id: id, completion: completion)

        case "__bad_request__":
            completion(.failure(code: ErrorCode.badRequest, message: "Invalid AgentRequest JSON"))
        default:
            // Try interactive automation methods (inspect, click, fill, press, select, wait)
            if routeInteractive(request.method, params: params, completion: completion) { return }
            completion(.failure(code: ErrorCode.unknownMethod, message: "Unknown method: \(request.method)"))
        }
    }

    // MARK: - Async Dispatch (for tests and future MCP)

    /// Dispatch a structured protocol request. Returns a structured response.
    func dispatch(_ request: AgentRequest) async -> AgentResponse {
        guard request.version == 1 else {
            return .failure(code: ErrorCode.badRequest, message: "Unsupported protocol version: \(request.version)")
        }

        let params = request.params?.mapValues(\.value) ?? [:]

        switch request.method {
        case "tabs.list":
            return .success(listTabs())

        case "tabs.get":
            guard let id = params["id"] as? String else {
                return .failure(code: ErrorCode.invalidParams, message: "Missing 'id' parameter")
            }
            return getTabResponse(id: id)

        case "tabs.open":
            guard let url = params["url"] as? String else {
                return .failure(code: ErrorCode.invalidParams, message: "Missing 'url' parameter")
            }
            return openURLResponse(url)

        case "page.read":
            guard let id = params["id"] as? String else {
                return .failure(code: ErrorCode.invalidParams, message: "Missing 'id' parameter")
            }
            let format = params["format"] as? String ?? "markdown"
            let mode = params["mode"] as? String
            let query = params["query"] as? String
            let budget = params["budget"] as? Int
            return await readPageResponse(id: id, format: format, mode: mode, query: query, budget: budget)

        case "page.eval":
            guard let id = params["id"] as? String,
                  let script = params["script"] as? String else {
                return .failure(code: ErrorCode.invalidParams, message: "Missing 'id' or 'script' parameter")
            }
            return await evalJSResponse(id: id, script: script)

        case "page.screenshot":
            guard let id = params["id"] as? String else {
                return .failure(code: ErrorCode.invalidParams, message: "Missing 'id' parameter")
            }
            return await screenshotResponse(id: id)

        default:
            // Try interactive automation methods (inspect, click, fill, press, select, wait)
            if let response = await routeInteractiveAsync(request.method, params: params) {
                return response
            }
            return .failure(code: ErrorCode.unknownMethod, message: "Unknown method: \(request.method)")
        }
    }

    // MARK: - Data Types

    struct TabInfo: Codable, Sendable {
        let id: String
        let title: String
        let url: String?
        let isLoading: Bool
        let isActive: Bool
    }

    struct TabDetail: Codable, Sendable {
        let id: String
        let title: String
        let url: String?
        let isLoading: Bool
        let isActive: Bool
        let canGoBack: Bool
        let canGoForward: Bool
        let isSecure: Bool
    }

    struct OpenResult: Codable, Sendable {
        let id: String
        let url: String
    }

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

    // MARK: - Tab Listing

    func listTabs() -> [TabInfo] {
        let activeID = tabManager.activeTab?.id
        return tabManager.tabs.map { tab in
            TabInfo(
                id: tab.id.uuidString,
                title: tab.title,
                url: tab.url?.absoluteString,
                isLoading: tab.isLoading,
                isActive: tab.id == activeID
            )
        }
    }

    // MARK: - Get Tab

    private func getTabResponse(id: String) -> AgentResponse {
        guard let tab = resolveTab(id) else {
            return .failure(code: ErrorCode.tabNotFound, message: "No tab with id: \(id)")
        }
        let activeID = tabManager.activeTab?.id
        return .success(TabDetail(
            id: tab.id.uuidString,
            title: tab.title,
            url: tab.url?.absoluteString,
            isLoading: tab.isLoading,
            isActive: tab.id == activeID,
            canGoBack: tab.canGoBack,
            canGoForward: tab.canGoForward,
            isSecure: tab.isSecure
        ))
    }

    // MARK: - Open URL

    private func openURLResponse(_ urlString: String) -> AgentResponse {
        var resolved = urlString
        if URL(string: resolved)?.scheme == nil {
            if resolved.contains(".") && !resolved.contains(" ") {
                resolved = "https://\(resolved)"
            } else {
                return .failure(code: ErrorCode.invalidURL, message: "Cannot parse URL: \(urlString)")
            }
        }
        guard let url = URL(string: resolved) else {
            return .failure(code: ErrorCode.invalidURL, message: "Cannot parse URL: \(urlString)")
        }
        // Reject non-http(s) schemes (e.g. file://, javascript:) to prevent
        // the agent API from being used as a local-file or JS-injection vector.
        guard ["http", "https"].contains(url.scheme?.lowercased()) else {
            return .failure(code: ErrorCode.invalidURL, message: "Unsupported URL scheme: \(url.scheme ?? "none")")
        }
        let tab = tabManager.createTab(url: url)
        tabManager.select(tab: tab)
        return .success(OpenResult(id: tab.id.uuidString, url: url.absoluteString))
    }

    // MARK: - Read Page

    /// Read content from the live DOM.
    ///
    /// Formats:
    /// - "markdown": lightweight semantic extraction (headings, paragraphs, links, lists)
    /// - "text": raw document.body.innerText
    /// - "html": full document HTML
    ///
    /// Handles: empty pages (returns empty content), loading pages (returns partial + isLoading flag),
    /// JS-heavy SPAs (reads the live rendered DOM, not source HTML).
    private func readPageResponse(
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

    // MARK: - Execute JavaScript

    private func evalJSResponse(id: String, script: String) async -> AgentResponse {
        guard let tab = resolveTab(id) else {
            return .failure(code: ErrorCode.tabNotFound, message: "No tab with id: \(id)")
        }

        // Strategy: wrap the user script so we can capture the result type and
        // stringify it safely. The user writes raw JS -- no `return` required for
        // simple expressions, but `return` works inside the function body too.
        let wrappedScript = """
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

        do {
            let raw = try await evaluateJS(on: tab.webView, script: wrappedScript)
            guard let jsonString = raw as? String,
                  let data = jsonString.data(using: .utf8),
                  let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return .success(JSEvalResult(
                    id: tab.id.uuidString, value: String(describing: raw),
                    type: "unknown", error: nil
                ))
            }

            // JS error
            if let err = dict["__e"] as? String {
                return .success(JSEvalResult(
                    id: tab.id.uuidString, value: nil, type: "error", error: err
                ))
            }

            // Successful result
            let type = dict["__t"] as? String ?? "unknown"
            let value = dict["__v"]

            // Re-encode just the value portion
            let valueJSON: String?
            if value is NSNull {
                valueJSON = "null"
            } else if let valueData = try? JSONSerialization.data(withJSONObject: value as Any) {
                valueJSON = String(data: valueData, encoding: .utf8)
            } else {
                valueJSON = String(describing: value)
            }

            return .success(JSEvalResult(
                id: tab.id.uuidString, value: valueJSON, type: type, error: nil
            ))
        } catch {
            return .failure(code: ErrorCode.javaScriptError, message: error.localizedDescription)
        }
    }

    // MARK: - Screenshot

    private func screenshotResponse(id: String) async -> AgentResponse {
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

            guard let tiff = image.tiffRepresentation,
                  let bitmap = NSBitmapImageRep(data: tiff),
                  let pngData = bitmap.representation(using: .png, properties: [:]) else {
                return .failure(code: ErrorCode.screenshotFailed, message: "Failed to encode PNG")
            }

            return .success(ScreenshotInfo(
                id: tab.id.uuidString,
                width: Int(image.size.width),
                height: Int(image.size.height),
                byteLength: pngData.count,
                encoding: "base64",
                data: pngData.base64EncodedString()
            ))
        } catch {
            return .failure(code: ErrorCode.screenshotFailed, message: error.localizedDescription)
        }
    }

    // MARK: - Content Extraction

    struct ExtractedContent {
        let content: String
        let format: String
        let mode: String?
        let truncated: Bool
    }

    /// Unified content extraction with mode/query/budget support.
    private func extractContent(
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
            let readMode = ContentExtraction.ReadMode(rawValue: mode ?? "main")
                ?? .main
            let effectiveBudget = budget ?? ContentExtraction.defaultBudget(for: readMode)

            let script: String
            switch readMode {
            case .summary:
                script = ContentExtraction.summaryScript(budget: effectiveBudget, query: query)
            case .main:
                script = ContentExtraction.mainContentScript(budget: effectiveBudget, query: query)
            case .full:
                script = ContentExtraction.fullMarkdownScript
            case .text, .html:
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
    }

    // MARK: - Callback-based Async Operations

    /// Read page content using callback-based JS evaluation.
    private func readPageCallback(
        id: String, format: String, mode: String?, query: String?, budget: Int?,
        completion: @escaping (AgentResponse) -> Void
    ) {
        guard let tab = resolveTab(id) else {
            completion(.failure(code: ErrorCode.tabNotFound, message: "No tab with id: \(id)")); return
        }
        let start = CFAbsoluteTimeGetCurrent()

        // For non-markdown formats, use simple extraction
        if format == "html" || format == "text" {
            let script = format == "html"
                ? "document.documentElement ? document.documentElement.outerHTML : ''"
                : "document.body ? document.body.innerText : ''"
            let tabID = tab.id.uuidString
            let tabTitle = tab.title
            let tabURL = tab.url?.absoluteString
            tab.webView.evaluateJavaScript(script) { result, error in
                DispatchQueue.main.async {
                    let elapsed = CFAbsoluteTimeGetCurrent() - start
                    if let error {
                        completion(.failure(code: ErrorCode.extractionFailed, message: error.localizedDescription)); return
                    }
                    let content = (result as? String) ?? ""
                    completion(.success(PageContent(
                        id: tabID, title: tabTitle, url: tabURL,
                        content: content, format: format, mode: nil,
                        characters: content.count, truncated: false,
                        extractionTime: (elapsed * 1000).rounded() / 1000
                    )))
                }
            }
            return
        }

        // Markdown: use bounded extraction
        let readMode = ContentExtraction.ReadMode(rawValue: mode ?? "main") ?? .main
        let effectiveBudget = budget ?? ContentExtraction.defaultBudget(for: readMode)

        let script: String
        switch readMode {
        case .summary:
            script = ContentExtraction.summaryScript(budget: effectiveBudget, query: query)
        case .main:
            script = ContentExtraction.mainContentScript(budget: effectiveBudget, query: query)
        case .full:
            script = ContentExtraction.fullMarkdownScript
        case .text, .html:
            script = ContentExtraction.fullMarkdownScript
        }

        let tabID = tab.id.uuidString
        let tabTitle = tab.title
        let tabURL = tab.url?.absoluteString
        let isFull = readMode == .full

        tab.webView.evaluateJavaScript(script) { result, error in
            DispatchQueue.main.async {
                let elapsed = CFAbsoluteTimeGetCurrent() - start
                if let error {
                    completion(.failure(code: ErrorCode.extractionFailed, message: error.localizedDescription)); return
                }

                if isFull {
                    let content = (result as? String) ?? ""
                    completion(.success(PageContent(
                        id: tabID, title: tabTitle, url: tabURL,
                        content: content, format: "markdown", mode: "full",
                        characters: content.count, truncated: false,
                        extractionTime: (elapsed * 1000).rounded() / 1000
                    )))
                    return
                }

                // Parse JSON result from summary/main scripts
                if let jsonString = result as? String,
                   let data = jsonString.data(using: .utf8),
                   let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    let content = dict["content"] as? String ?? ""
                    let truncated = dict["truncated"] as? Bool ?? false
                    completion(.success(PageContent(
                        id: tabID, title: tabTitle, url: tabURL,
                        content: content, format: "markdown", mode: readMode.rawValue,
                        characters: content.count, truncated: truncated,
                        extractionTime: (elapsed * 1000).rounded() / 1000
                    )))
                } else {
                    let content = (result as? String) ?? ""
                    completion(.success(PageContent(
                        id: tabID, title: tabTitle, url: tabURL,
                        content: content, format: "markdown", mode: readMode.rawValue,
                        characters: content.count, truncated: false,
                        extractionTime: (elapsed * 1000).rounded() / 1000
                    )))
                }
            }
        }
    }

    /// Execute JS using callback-based API.
    private func evalJSCallback(id: String, script: String, completion: @escaping (AgentResponse) -> Void) {
        guard let tab = resolveTab(id) else {
            completion(.failure(code: ErrorCode.tabNotFound, message: "No tab with id: \(id)")); return
        }
        let wrappedScript = """
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

        let tabID = tab.id.uuidString
        tab.webView.evaluateJavaScript(wrappedScript) { result, error in
            // Dispatch back to main -- the callback may arrive on a non-main thread
            DispatchQueue.main.async {
                if let error {
                    completion(.failure(code: ErrorCode.javaScriptError, message: error.localizedDescription)); return
                }
                guard let jsonString = result as? String,
                      let data = jsonString.data(using: .utf8),
                      let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    completion(.success(JSEvalResult(id: tabID, value: String(describing: result), type: "unknown", error: nil)))
                    return
                }

                if let err = dict["__e"] as? String {
                    completion(.success(JSEvalResult(id: tabID, value: nil, type: "error", error: err))); return
                }

                let type = dict["__t"] as? String ?? "unknown"
                let rawValue = dict["__v"]
                // Re-serialize just the value to JSON. Wrap in array since
                // JSONSerialization requires a top-level array or dictionary.
                let valueJSON: String?
                if rawValue == nil || rawValue is NSNull {
                    valueJSON = "null"
                } else if let arr = try? JSONSerialization.data(withJSONObject: [rawValue!]),
                          let arrStr = String(data: arr, encoding: .utf8) {
                    // Strip the wrapping brackets: "[\"hello\"]" -> "\"hello\""
                    let trimmed = arrStr.dropFirst().dropLast()
                    valueJSON = String(trimmed)
                } else {
                    valueJSON = String(describing: rawValue)
                }

                completion(.success(JSEvalResult(id: tabID, value: valueJSON, type: type, error: nil)))
            }
        }
    }

    /// Screenshot using callback-based API.
    private func screenshotCallback(id: String, completion: @escaping (AgentResponse) -> Void) {
        guard let tab = resolveTab(id) else {
            completion(.failure(code: ErrorCode.tabNotFound, message: "No tab with id: \(id)")); return
        }

        let tabID = tab.id.uuidString
        let config = WKSnapshotConfiguration()
        config.afterScreenUpdates = true
        tab.webView.takeSnapshot(with: config) { image, error in
            DispatchQueue.main.async {
                if let error {
                    completion(.failure(code: ErrorCode.screenshotFailed, message: error.localizedDescription)); return
                }
                guard let image,
                      let tiff = image.tiffRepresentation,
                      let bitmap = NSBitmapImageRep(data: tiff),
                      let pngData = bitmap.representation(using: .png, properties: [:]) else {
                    completion(.failure(code: ErrorCode.screenshotFailed, message: "Failed to encode PNG")); return
                }
                completion(.success(ScreenshotInfo(
                    id: tabID, width: Int(image.size.width), height: Int(image.size.height),
                    byteLength: pngData.count, encoding: "base64", data: pngData.base64EncodedString()
                )))
            }
        }
    }

    // MARK: - Private Helpers

    func resolveTab(_ id: String) -> BrowserTab? {
        guard let uuid = UUID(uuidString: id) else { return nil }
        return tabManager.tab(for: uuid)
    }

    /// Evaluate JS using the callback API (NOT the async overload which crashes on void returns).
    /// Includes a 10-second timeout to prevent indefinite hangs when the WKWebView is in a
    /// state that prevents callback delivery (zero frame, not in hierarchy, process suspended).
    private func evaluateJS(on webView: WKWebView, script: String) async throws -> Any? {
#if DEBUG
        print("[evaluateJS] Starting eval, frame=\(webView.frame), superview=\(webView.superview != nil)")
#endif
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Any?, Error>) in
#if DEBUG
            print("[evaluateJS] About to call evaluateJavaScript")
#endif
            webView.evaluateJavaScript(script) { result, error in
#if DEBUG
                print("[evaluateJS] Callback received: result=\(String(describing: result)), error=\(String(describing: error))")
#endif
                if let error {
                    cont.resume(throwing: error)
                } else {
                    cont.resume(returning: result)
                }
            }
#if DEBUG
            print("[evaluateJS] evaluateJavaScript called, waiting for callback")
#endif
        }
    }
}
