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

    // The WebView — recreated on profile switch (Issue #8).
    // Internal(set) so BrowserWindowController can swap the superview reference
    // in syncDisplayedTab after recreation; all mutation goes through
    // recreateWebView(configuration:) which owns the KVO tear-down/setup cycle.
    private(set) var webView: WKWebView

    /// When `true`, this tab's WKWebView was created under a stale profile and
    /// must be recreated with the current profile's configuration before it is
    /// next displayed.  Set by TabManager.recreateWebViews(for:activeTabID:)
    /// for background tabs; cleared by recreateWebView(configuration:).
    var needsWebViewRecreation: Bool = false

    // Delegates must be retained (WKWebView does not retain them)
    private var navigationCoordinator: NavigationCoordinator
    private let uiCoordinator: UICoordinator

    // KVO observations — rebuilt whenever the WKWebView is recreated.
    private var observations: [NSKeyValueObservation] = []

    // Zoom level
    private(set) var zoomLevel: Double = 1.0

    // Callback for when a popup/new-tab navigation is requested
    var onNewTabRequested: ((URL) -> Void)?

    /// Called after any navigation completes (didFinish). Consumers may use this
    /// to run post-navigation checks (e.g. session-expiry detection).
    var onNavigationDidFinish: (() -> Void)?

    /// Inject the shared HistoryStore so every completed navigation is recorded.
    /// Call after async persistence initialisation is complete.
    func attachHistoryStore(_ store: HistoryStore) {
        navigationCoordinator.historyStore = store
    }

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

    // MARK: - WebView Recreation (Issue #8)

    /// Replace this tab's WKWebView with a fresh one built from `configuration`.
    ///
    /// Steps:
    /// 1. Capture the URL currently loaded so we can reload it after recreation.
    /// 2. Tear down KVO on the old WKWebView (prevents dangling observations).
    /// 3. Detach the old WKWebView from its superview (caller owns animation).
    /// 4. Build and wire the new WKWebView.
    /// 5. Set up fresh KVO and delegate callbacks.
    /// 6. Return the old view so the caller can animate the cross-fade.
    ///
    /// - Parameter configuration: The new profile's `WKWebViewConfiguration`.
    /// - Returns: The detached old `WKWebView` for cross-fade animation; the
    ///   caller is responsible for removing it from the view hierarchy.
    @discardableResult
    func recreateWebView(configuration: WKWebViewConfiguration) -> WKWebView {
        let capturedURL = self.url

        // 1. Invalidate all KVO on the outgoing webview.
        observations.forEach { $0.invalidate() }
        observations = []

        // 2. Detach the old webview — return it so callers can animate.
        let old = webView
        old.navigationDelegate = nil
        old.uiDelegate = nil
        old.removeFromSuperview()

        // 3. Build the replacement webview.
        let wv = WKWebView(frame: .zero, configuration: configuration)
        wv.allowsBackForwardNavigationGestures = true
        wv.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"
        wv.pageZoom = zoomLevel

        // 4. Swap: rebuild the NavigationCoordinator to avoid any stale state
        //    from the old webview's delegate callbacks.
        let newNC = NavigationCoordinator()
        newNC.historyStore = navigationCoordinator.historyStore
        navigationCoordinator = newNC

        wv.navigationDelegate = navigationCoordinator
        wv.uiDelegate = uiCoordinator

        webView = wv

        // 5. Wire KVO and callbacks on the new webview.
        setupObservations()
        setupCallbacks()

        // 6. Reload the captured URL.
        if let url = capturedURL {
            wv.load(URLRequest(url: url))
        }

        needsWebViewRecreation = false
        return old
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

        // Wire navigation-finish notifications for post-navigation checks.
        navigationCoordinator.onDidFinish = { [weak self] in
            self?.onNavigationDidFinish?()
        }
    }

    /// Creates a base WKWebViewConfiguration with media and fullscreen settings.
    ///
    /// The automation bridge scripts (automation-bridge-relevance.js and
    /// automation-bridge.js) are NOT injected here. They are injected exclusively
    /// by `ProfileManager.makeConfiguration(for:)`, which owns per-profile
    /// WKWebsiteDataStore setup. Injecting the bridge here would result in
    /// double-injection (once per BrowserTab init, once per ProfileManager config),
    /// leading to duplicate AB._generation resets and undefined bridge behaviour.
    private static func makeDefaultConfiguration() -> WKWebViewConfiguration {
        let config = WKWebViewConfiguration()
        config.preferences.isElementFullscreenEnabled = true
        // Allow inline media playback
        config.mediaTypesRequiringUserActionForPlayback = []
        config.allowsAirPlayForMediaPlayback = true
        return config
    }

    /// Load a named JS file from UserScripts (bundle or dev fallback).
    private static func loadScript(named name: String) -> String? {
        if let url = Bundle.module.url(forResource: name, withExtension: "js",
                                        subdirectory: "UserScripts") {
            return try? String(contentsOf: url, encoding: .utf8)
        }
        if let url = Bundle.main.url(forResource: name, withExtension: "js") {
            return try? String(contentsOf: url, encoding: .utf8)
        }
#if DEBUG
        let devPaths = [
            "Sources/AgentBrowser/WebKit/UserScripts/\(name).js",
            "../Sources/AgentBrowser/WebKit/UserScripts/\(name).js",
        ]
        for path in devPaths {
            if FileManager.default.fileExists(atPath: path) {
                return try? String(contentsOfFile: path, encoding: .utf8)
            }
        }
#endif
        print("[BrowserTab] Warning: \(name).js not found")
        return nil
    }

    /// Load the automation-bridge.js from the bundle or filesystem.
    /// Checks: SPM .copy bundle path, main bundle, working directory fallback.
    private static func loadAutomationBridge() -> String? {
        loadScript(named: "automation-bridge")
    }
}
