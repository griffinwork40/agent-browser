import AppKit
import WebKit

// MARK: - Page Operations (Callback)
//
// Callback-based page.read, page.eval, page.screenshot for the HTTP server path.
// Extension of BrowserAutomationService extracted for the 350 LOC rule.

extension BrowserAutomationService {

    // MARK: - Read Page (Callback)

    /// Read page content using callback-based JS evaluation.
    func readPageCallback(
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
        readMarkdownCallback(tab: tab, mode: mode, budget: budget, query: query, start: start, completion: completion)
    }

    /// Markdown-specific callback extraction.
    private func readMarkdownCallback(
        tab: BrowserTab, mode: String?, budget: Int?, query: String?,
        start: CFAbsoluteTime, completion: @escaping (AgentResponse) -> Void
    ) {
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

    // MARK: - Execute JavaScript (Callback)

    /// Execute JS using callback-based API.
    func evalJSCallback(id: String, script: String, completion: @escaping (AgentResponse) -> Void) {
        guard let tab = resolveTab(id) else {
            completion(.failure(code: ErrorCode.tabNotFound, message: "No tab with id: \(id)")); return
        }
        let wrappedScript = Self.wrapUserScript(script)

        let tabID = tab.id.uuidString
        tab.webView.evaluateJavaScript(wrappedScript) { result, error in
            DispatchQueue.main.async {
                if let error {
                    completion(.failure(code: ErrorCode.javaScriptError, message: error.localizedDescription)); return
                }
                completion(Self.parseEvalResult(raw: result, tabID: tabID))
            }
        }
    }

    // MARK: - Screenshot (Callback)

    /// Screenshot using callback-based API.
    func screenshotCallback(id: String, completion: @escaping (AgentResponse) -> Void) {
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
                guard let image else {
                    completion(.failure(code: ErrorCode.screenshotFailed, message: "No image returned")); return
                }
                completion(Self.encodeScreenshot(image: image, tabID: tabID))
            }
        }
    }
}
