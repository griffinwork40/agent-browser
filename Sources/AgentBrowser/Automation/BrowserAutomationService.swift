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

    // MARK: - Tab Listing

    /// Structured info for every open tab.
    struct TabInfo: Codable, Sendable {
        let id: String
        let title: String
        let url: String?
        let isLoading: Bool
        let isActive: Bool
    }

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

    enum AutomationError: Error, LocalizedError, Sendable {
        case tabNotFound(String)
        case javaScriptError(String)
        case screenshotFailed(String)
        case invalidURL(String)

        var errorDescription: String? {
            switch self {
            case .tabNotFound(let id): return "Tab not found: \(id)"
            case .javaScriptError(let msg): return "JavaScript error: \(msg)"
            case .screenshotFailed(let msg): return "Screenshot failed: \(msg)"
            case .invalidURL(let url): return "Invalid URL: \(url)"
            }
        }
    }

    func getTab(id: String) throws -> TabDetail {
        guard let uuid = UUID(uuidString: id),
              let tab = tabManager.tab(for: uuid) else {
            throw AutomationError.tabNotFound(id)
        }
        let activeID = tabManager.activeTab?.id
        return TabDetail(
            id: tab.id.uuidString,
            title: tab.title,
            url: tab.url?.absoluteString,
            isLoading: tab.isLoading,
            isActive: tab.id == activeID,
            canGoBack: tab.canGoBack,
            canGoForward: tab.canGoForward,
            isSecure: tab.isSecure
        )
    }

    // MARK: - Open URL

    struct OpenResult: Codable, Sendable {
        let id: String
        let url: String
    }

    func openURL(_ urlString: String) throws -> OpenResult {
        guard let url = URL(string: urlString), url.scheme != nil else {
            // Try adding https:// if it looks like a domain
            if urlString.contains(".") && !urlString.contains(" ") {
                guard let url = URL(string: "https://\(urlString)") else {
                    throw AutomationError.invalidURL(urlString)
                }
                let tab = tabManager.createTab(url: url)
                tabManager.select(tab: tab)
                return OpenResult(id: tab.id.uuidString, url: url.absoluteString)
            }
            throw AutomationError.invalidURL(urlString)
        }
        let tab = tabManager.createTab(url: url)
        tabManager.select(tab: tab)
        return OpenResult(id: tab.id.uuidString, url: url.absoluteString)
    }

    // MARK: - Read Page

    struct PageContent: Codable, Sendable {
        let id: String
        let title: String
        let url: String?
        let text: String
        let html: String?
    }

    /// Read the current live DOM content from a tab's WKWebView.
    /// This returns the ACTUAL rendered page state -- authenticated,
    /// client-rendered, dynamically modified. Not a re-fetch.
    func readPage(id: String, includeHTML: Bool = false) async throws -> PageContent {
        let tab = try resolveTab(id)

        // Extract visible text from the live DOM
        let textScript = "document.body ? document.body.innerText : ''"
        let text = try await evaluateJS(on: tab.webView, script: textScript) as? String ?? ""

        var html: String? = nil
        if includeHTML {
            let htmlScript = "document.documentElement ? document.documentElement.outerHTML : ''"
            html = try await evaluateJS(on: tab.webView, script: htmlScript) as? String
        }

        return PageContent(
            id: tab.id.uuidString,
            title: tab.title,
            url: tab.url?.absoluteString,
            text: text,
            html: html
        )
    }

    // MARK: - Execute JavaScript

    struct JSResult: Codable, Sendable {
        let id: String
        let result: String?
        let error: String?
    }

    /// Execute arbitrary JavaScript in a tab's live page context.
    /// Returns the stringified result.
    func executeJavaScript(id: String, script: String) async throws -> JSResult {
        let tab = try resolveTab(id)

        // Wrap in JSON.stringify to handle all return types safely.
        // The raw script runs first; we stringify whatever it returns.
        let wrappedScript = """
        (function() {
            try {
                var __result = (function() { \(script) })();
                if (__result === undefined) return JSON.stringify(null);
                return JSON.stringify(__result);
            } catch(e) {
                return JSON.stringify({__error: e.message || String(e)});
            }
        })()
        """

        do {
            let raw = try await evaluateJS(on: tab.webView, script: wrappedScript)
            if let jsonString = raw as? String {
                // Check if it was an error
                if jsonString.contains("\"__error\"") {
                    // Parse the error
                    if let data = jsonString.data(using: .utf8),
                       let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                       let errorMsg = dict["__error"] as? String {
                        return JSResult(id: tab.id.uuidString, result: nil, error: errorMsg)
                    }
                }
                return JSResult(id: tab.id.uuidString, result: jsonString, error: nil)
            }
            return JSResult(id: tab.id.uuidString, result: String(describing: raw), error: nil)
        } catch {
            return JSResult(id: tab.id.uuidString, result: nil, error: error.localizedDescription)
        }
    }

    // MARK: - Screenshot

    struct ScreenshotResult: Sendable {
        let id: String
        let pngData: Data
        let width: Int
        let height: Int
    }

    /// Capture the current viewport of a tab as a PNG.
    /// Returns the raw PNG bytes.
    func screenshot(id: String) async throws -> ScreenshotResult {
        let tab = try resolveTab(id)
        let webView = tab.webView

        let image = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<NSImage, Error>) in
            let config = WKSnapshotConfiguration()
            config.afterScreenUpdates = true
            webView.takeSnapshot(with: config) { image, error in
                if let image {
                    cont.resume(returning: image)
                } else {
                    cont.resume(throwing: AutomationError.screenshotFailed(
                        error?.localizedDescription ?? "Unknown error"))
                }
            }
        }

        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let pngData = bitmap.representation(using: .png, properties: [:]) else {
            throw AutomationError.screenshotFailed("Failed to encode PNG")
        }

        return ScreenshotResult(
            id: tab.id.uuidString,
            pngData: pngData,
            width: Int(image.size.width),
            height: Int(image.size.height)
        )
    }

    // MARK: - Private Helpers

    private func resolveTab(_ id: String) throws -> BrowserTab {
        guard let uuid = UUID(uuidString: id),
              let tab = tabManager.tab(for: uuid) else {
            throw AutomationError.tabNotFound(id)
        }
        return tab
    }

    /// Evaluate JS using the callback API (NOT the async overload which crashes on void returns).
    private func evaluateJS(on webView: WKWebView, script: String) async throws -> Any? {
        try await withCheckedThrowingContinuation { cont in
            webView.evaluateJavaScript(script) { result, error in
                if let error {
                    cont.resume(throwing: AutomationError.javaScriptError(error.localizedDescription))
                } else {
                    cont.resume(returning: result)
                }
            }
        }
    }
}
