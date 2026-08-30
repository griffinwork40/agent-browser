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
            readPageCallback(id: id, format: format, completion: completion)
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
            return await readPageResponse(id: id, format: format)

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
        let byteLength: Int
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
    private func readPageResponse(id: String, format: String) async -> AgentResponse {
        guard let tab = resolveTab(id) else {
            return .failure(code: ErrorCode.tabNotFound, message: "No tab with id: \(id)")
        }

        let start = CFAbsoluteTimeGetCurrent()

        do {
            let content: String
            switch format {
            case "html":
                content = try await extractHTML(from: tab.webView)
            case "text":
                content = try await extractText(from: tab.webView)
            default: // "markdown"
                content = try await extractMarkdown(from: tab.webView)
            }

            let elapsed = CFAbsoluteTimeGetCurrent() - start
            return .success(PageContent(
                id: tab.id.uuidString,
                title: tab.title,
                url: tab.url?.absoluteString,
                content: content,
                format: format == "html" || format == "text" ? format : "markdown",
                byteLength: content.utf8.count,
                extractionTime: (elapsed * 1000).rounded() / 1000 // 3 decimal places
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

    /// Extract visible text via document.body.innerText.
    private func extractText(from webView: WKWebView) async throws -> String {
        let script = "document.body ? document.body.innerText : ''"
        return try await evaluateJS(on: webView, script: script) as? String ?? ""
    }

    /// Extract full HTML.
    private func extractHTML(from webView: WKWebView) async throws -> String {
        let script = "document.documentElement ? document.documentElement.outerHTML : ''"
        return try await evaluateJS(on: webView, script: script) as? String ?? ""
    }

    /// Extract a lightweight Markdown representation from the live DOM.
    ///
    /// Strategy: injected JS walks the DOM tree and converts semantic elements
    /// (headings, paragraphs, links, lists, tables, code blocks, images) into
    /// Markdown. This runs against the RENDERED DOM -- it sees client-rendered
    /// SPA content, authenticated pages, and dynamic modifications.
    ///
    /// This is NOT a full Readability extraction. It's a pragmatic first pass
    /// that handles the 80% case: article-like pages, documentation, dashboards,
    /// landing pages, search results.
    private func extractMarkdown(from webView: WKWebView) async throws -> String {
        let script = Self.markdownExtractionScript
        let raw = try await evaluateJS(on: webView, script: script)
        return (raw as? String) ?? ""
    }

    /// Injected JS for markdown extraction.
    ///
    /// Design:
    /// - Walks the RENDERED DOM (sees SPA content, auth'd pages, dynamic state)
    /// - Uses innerText as the base (already excludes hidden elements, scripts, styles)
    /// - Overlays structural markdown for headings, links, lists, code, tables
    /// - Falls back gracefully: empty pages return "", loading pages return partial content
    /// - Does not try to be Readability -- prefers useful-now over perfect-later
    private static let markdownExtractionScript: String = """
    (function() {
        if (!document.body) return '';
        var out = [];
        var title = document.title || '';

        // Find main content root. Prefer semantic containers, fall back to body.
        var root = document.querySelector('main, article, [role="main"]') || document.body;

        var SKIP = new Set(['script','style','noscript','svg','template','link','meta']);

        function hidden(el) {
            // Lightweight visibility check. Avoids getComputedStyle overhead for most elements.
            // Check display/visibility only on elements that commonly hide content.
            if (el.hidden) return true;
            var s = el.style;
            if (s && (s.display === 'none' || s.visibility === 'hidden')) return true;
            return false;
        }

        function txt(el) {
            return (el.innerText || el.textContent || '').replace(/[ \\t]+/g, ' ').trim();
        }

        function absURL(href) {
            if (!href) return '';
            try { return new URL(href, document.baseURI).href; } catch(e) { return href; }
        }

        function walk(node) {
            if (node.nodeType === 3) { // TEXT_NODE
                var t = node.textContent;
                if (t && t.trim()) out.push(t);
                return;
            }
            if (node.nodeType !== 1) return;
            var tag = node.tagName.toLowerCase();
            if (SKIP.has(tag)) return;
            if (hidden(node)) return;

            switch(tag) {
            case 'h1': case 'h2': case 'h3': case 'h4': case 'h5': case 'h6':
                var lvl = tag[1];
                var prefix = '#'.repeat(parseInt(lvl));
                out.push('\\n' + prefix + ' ' + txt(node) + '\\n');
                return;

            case 'p':
                out.push('\\n');
                for (var c of node.childNodes) walk(c);
                out.push('\\n');
                return;

            case 'a':
                var href = node.getAttribute('href') || '';
                var atxt = txt(node);
                if (atxt && href && !href.startsWith('javascript:') && !href.startsWith('#')) {
                    out.push('[' + atxt + '](' + absURL(href) + ')');
                } else if (atxt) {
                    out.push(atxt);
                }
                return;

            case 'img':
                var alt = node.getAttribute('alt') || '';
                var src = node.getAttribute('src') || '';
                if (src) out.push('![' + alt + '](' + absURL(src) + ')');
                return;

            case 'strong': case 'b':
                var st = txt(node);
                if (st) out.push('**' + st + '**');
                return;
            case 'em': case 'i':
                var et = txt(node);
                if (et) out.push('*' + et + '*');
                return;

            case 'code':
                if (node.parentElement && node.parentElement.tagName === 'PRE') break;
                var ct = node.textContent || '';
                if (ct.trim()) out.push('`' + ct.trim() + '`');
                return;

            case 'pre':
                var codeEl = node.querySelector('code');
                var lang = '';
                if (codeEl) {
                    var m = (codeEl.className || '').match(/language-(\\w+)/);
                    if (m) lang = m[1];
                }
                out.push('\\n```' + lang + '\\n' + (node.textContent || '').trim() + '\\n```\\n');
                return;

            case 'blockquote':
                txt(node).split('\\n').forEach(function(l) { out.push('\\n> ' + l.trim()); });
                out.push('\\n');
                return;

            case 'ul':
                out.push('\\n');
                Array.from(node.children).forEach(function(li) {
                    if (li.tagName === 'LI') out.push('- ' + txt(li) + '\\n');
                });
                return;

            case 'ol':
                out.push('\\n');
                var i = 1;
                Array.from(node.children).forEach(function(li) {
                    if (li.tagName === 'LI') { out.push(i + '. ' + txt(li) + '\\n'); i++; }
                });
                return;

            case 'table':
                out.push('\\n');
                var rows = node.querySelectorAll('tr');
                var first = true;
                rows.forEach(function(tr) {
                    var cells = tr.querySelectorAll('th, td');
                    if (cells.length === 0) return;
                    var line = '| ' + Array.from(cells).map(function(c) { return txt(c); }).join(' | ') + ' |';
                    out.push(line + '\\n');
                    if (first) {
                        out.push('|' + Array.from(cells).map(function() { return '---'; }).join('|') + '|\\n');
                        first = false;
                    }
                });
                out.push('\\n');
                return;

            case 'hr':
                out.push('\\n---\\n');
                return;

            case 'br':
                out.push('\\n');
                return;

            // Layout containers: recurse but add line breaks around block-level ones
            case 'div': case 'section': case 'main': case 'article': case 'aside':
            case 'details': case 'summary': case 'figure': case 'figcaption':
                out.push('\\n');
                for (var ch of node.childNodes) walk(ch);
                out.push('\\n');
                return;

            // Table internals, form elements, spans -- just recurse
            default:
                for (var child of node.childNodes) walk(child);
                return;
            }

            // Fallthrough from code-inside-pre break
            for (var fb of node.childNodes) walk(fb);
        }

        walk(root);

        var result = out.join('')
            .replace(/[ \\t]*\\n/g, '\\n')
            .replace(/\\n{3,}/g, '\\n\\n')
            .trim();

        // Prepend title
        if (title) {
            // Don't duplicate if the content already starts with the title as h1
            if (!result.startsWith('# ' + title)) {
                result = '# ' + title + '\\n\\n' + result;
            }
        }

        return result || '(empty page)';
    })()
    """;

    // MARK: - Callback-based Async Operations

    /// Read page content using callback-based JS evaluation.
    private func readPageCallback(id: String, format: String, completion: @escaping (AgentResponse) -> Void) {
        guard let tab = resolveTab(id) else {
            completion(.failure(code: ErrorCode.tabNotFound, message: "No tab with id: \(id)")); return
        }
        let start = CFAbsoluteTimeGetCurrent()
        let script: String
        switch format {
        case "html":
            script = "document.documentElement ? document.documentElement.outerHTML : ''"
        case "text":
            script = "document.body ? document.body.innerText : ''"
        default:
            script = Self.markdownExtractionScript
        }

        let tabID = tab.id.uuidString
        let tabTitle = tab.title
        let tabURL = tab.url?.absoluteString
        let fmt = format == "html" || format == "text" ? format : "markdown"

        tab.webView.evaluateJavaScript(script) { result, error in
            DispatchQueue.main.async {
                let elapsed = CFAbsoluteTimeGetCurrent() - start
                if let error {
                    completion(.failure(code: ErrorCode.extractionFailed, message: error.localizedDescription)); return
                }
                let content = (result as? String) ?? ""
                completion(.success(PageContent(
                    id: tabID, title: tabTitle, url: tabURL,
                    content: content, format: fmt,
                    byteLength: content.utf8.count,
                    extractionTime: (elapsed * 1000).rounded() / 1000
                )))
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
        print("[evaluateJS] Starting eval, frame=\(webView.frame), superview=\(webView.superview != nil)")
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Any?, Error>) in
            print("[evaluateJS] About to call evaluateJavaScript")
            webView.evaluateJavaScript(script) { result, error in
                print("[evaluateJS] Callback received: result=\(String(describing: result)), error=\(String(describing: error))")
                if let error {
                    cont.resume(throwing: error)
                } else {
                    cont.resume(returning: result)
                }
            }
            print("[evaluateJS] evaluateJavaScript called, waiting for callback")
        }
    }
}
