import AppKit
import WebKit
import Observation

@Observable @MainActor
final class BrowserTab: Identifiable {
    // Identity and provenance — owned by the record
    let record: TabRecord

    /// Stable identity forwarded from the record.
    var id: UUID { record.id }

    /// Creation timestamp forwarded from the record.
    var createdAt: Date { record.createdAt }

    // Display state
    private(set) var url: URL?
    private(set) var title: String = "New Tab"
    private(set) var isLoading: Bool = false
    private(set) var loadProgress: Double = 0
    private(set) var canGoBack: Bool = false
    private(set) var canGoForward: Bool = false
    private(set) var isSecure: Bool = false

    // The WebView -- always created for now (Phase 1)
    let webView: WKWebView

    // Delegates must be retained (WKWebView does not retain them)
    private let navigationCoordinator: NavigationCoordinator
    private let uiCoordinator: UICoordinator

    // KVO observations
    private var observations: [NSKeyValueObservation] = []

    // Zoom level
    private(set) var zoomLevel: Double = 1.0

    // Callback for when a popup/new-tab navigation is requested
    var onNewTabRequested: ((URL) -> Void)?

    /// A point-in-time snapshot of this tab's current navigation state.
    var navState: NavigationState {
        NavigationState(
            url: url,
            title: title,
            isLoading: isLoading,
            loadProgress: loadProgress,
            canGoBack: canGoBack,
            canGoForward: canGoForward,
            isSecure: isSecure,
            zoomLevel: zoomLevel
        )
    }

    init(record: TabRecord = TabRecord(), configuration: WKWebViewConfiguration? = nil) {
        self.record = record
        let config = configuration ?? Self.makeDefaultConfiguration()
        let wv = WKWebView(frame: .zero, configuration: config)
        wv.allowsBackForwardNavigationGestures = true
        // Set a Safari-like user agent to avoid degraded content
        wv.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"

        self.webView = wv
        self.navigationCoordinator = NavigationCoordinator()
        self.uiCoordinator = UICoordinator()

        wv.navigationDelegate = navigationCoordinator
        wv.uiDelegate = uiCoordinator

        setupObservations()
        setupCallbacks()
    }

    // MARK: - Navigation

    func load(_ url: URL) {
        webView.load(URLRequest(url: url))
    }

    func loadSearch(_ query: String) {
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        if let searchURL = URL(string: "https://www.google.com/search?q=\(encoded)") {
            load(searchURL)
        }
    }

    func goBack() {
        webView.goBack()
    }

    func goForward() {
        webView.goForward()
    }

    func reload() {
        webView.reload()
    }

    func reloadFromOrigin() {
        webView.reloadFromOrigin()
    }

    func stopLoading() {
        webView.stopLoading()
    }

    func setZoom(_ level: Double) {
        zoomLevel = level
        webView.pageZoom = level
    }

    // MARK: - Private

    private func setupObservations() {
        observations = [
            webView.observe(\.url) { [weak self] wv, _ in
                MainActor.assumeIsolated {
                    self?.url = wv.url
                    self?.isSecure = wv.url?.scheme == "https"
                }
            },
            webView.observe(\.title) { [weak self] wv, _ in
                MainActor.assumeIsolated {
                    self?.title = wv.title ?? "New Tab"
                }
            },
            webView.observe(\.isLoading) { [weak self] wv, _ in
                MainActor.assumeIsolated {
                    self?.isLoading = wv.isLoading
                }
            },
            webView.observe(\.estimatedProgress) { [weak self] wv, _ in
                MainActor.assumeIsolated {
                    self?.loadProgress = wv.estimatedProgress
                }
            },
            webView.observe(\.canGoBack) { [weak self] wv, _ in
                MainActor.assumeIsolated {
                    self?.canGoBack = wv.canGoBack
                }
            },
            webView.observe(\.canGoForward) { [weak self] wv, _ in
                MainActor.assumeIsolated {
                    self?.canGoForward = wv.canGoForward
                }
            },
        ]
    }

    private func setupCallbacks() {
        // Wire popup/new-window requests from UICoordinator to our callback
        uiCoordinator.onNewWindowRequested = { [weak self] url in
            self?.onNewTabRequested?(url)
        }
    }

    private static func makeDefaultConfiguration() -> WKWebViewConfiguration {
        let config = WKWebViewConfiguration()
        config.preferences.isElementFullscreenEnabled = true
        // Allow inline media playback
        config.mediaTypesRequiringUserActionForPlayback = []
        config.allowsAirPlayForMediaPlayback = true

        // Inject the automation bridge into every page for element inspection,
        // click, fill, press, select, and wait operations.
        // Runs in the page content world so evaluateJavaScript() can access
        // window.__agentBrowser directly. The bridge is safe to expose --
        // it only provides inspection and interaction helpers, no privileged APIs.
        if let bridgeJS = Self.loadAutomationBridge() {
            let script = WKUserScript(
                source: bridgeJS,
                injectionTime: .atDocumentEnd,
                forMainFrameOnly: true
            )
            config.userContentController.addUserScript(script)
        }

        return config
    }

    /// Load the automation-bridge.js from the bundle or filesystem.
    /// Checks: SPM .copy bundle path, main bundle, working directory fallback.
    private static func loadAutomationBridge() -> String? {
        // SPM .copy preserves the subdirectory structure
        if let url = Bundle.module.url(forResource: "automation-bridge", withExtension: "js",
                                        subdirectory: "UserScripts") {
            return try? String(contentsOf: url, encoding: .utf8)
        }
        if let url = Bundle.main.url(forResource: "automation-bridge", withExtension: "js") {
            return try? String(contentsOf: url, encoding: .utf8)
        }
        // Development fallback: load from cwd-relative source path
        let devPaths = [
            "Sources/AgentBrowser/WebKit/UserScripts/automation-bridge.js",
            "../Sources/AgentBrowser/WebKit/UserScripts/automation-bridge.js",
        ]
        for path in devPaths {
            if FileManager.default.fileExists(atPath: path) {
                return try? String(contentsOfFile: path, encoding: .utf8)
            }
        }
        print("[BrowserTab] Warning: automation-bridge.js not found")
        return nil
    }
}
