import Foundation
import WebKit

// MARK: - ContentBlockerManager

/// Manages WKContentRuleList compilation, caching, and application.
///
/// On first launch (or when filter lists are stale >7 days), downloads
/// EasyList and EasyPrivacy JSON rule lists, compiles them via
/// `WKContentRuleListStore`, and caches the identifiers. Falls back to a
/// built-in rule list when offline or before the first download completes.
///
/// Usage:
/// ```swift
/// let manager = ContentBlockerManager()
/// await manager.setUp()
/// manager.applyRules(to: config)
/// ```
@MainActor
final class ContentBlockerManager {

    // MARK: - Public state

    /// Whether content blocking is currently active.
    /// Persisted to UserDefaults and applied to all future configurations.
    private(set) var isEnabled: Bool {
        didSet { defaults.set(isEnabled, forKey: Keys.enabled) }
    }

    // MARK: - Private state

    /// Compiled rule lists ready to be injected into a WKWebViewConfiguration.
    private var compiledLists: [WKContentRuleList] = []

    /// All configurations that currently have rules applied.
    /// Weak-referencing via a wrapper so we can apply/remove rules on toggle.
    private var trackedConfigurations: [WeakConfig] = []

    /// UserDefaults store for persisting enabled state and fetch timestamps.
    private let defaults: UserDefaults

    // MARK: - Constants

    private enum Keys {
        static let enabled      = "contentBlockerEnabled"
        static let lastFetch    = "contentBlockerLastFetch"
        static let easylistID   = "com.agentbrowser.blocklist.easylist"
        static let easyprivacyID = "com.agentbrowser.blocklist.easyprivacy"
    }

    private enum FilterURLs {
        // Safari Content Blocker JSON format (trigger/action) — sourced from brave/brave-ios.
        // block-ads.json covers ad networks; block-trackers.json covers trackers/analytics.
        static let easylist    = URL(string: "https://raw.githubusercontent.com/brave/brave-ios/development/Sources/Brave/WebFilters/ContentBlocker/Lists/block-ads.json")!
        static let easyprivacy = URL(string: "https://raw.githubusercontent.com/brave/brave-ios/development/Sources/Brave/WebFilters/ContentBlocker/Lists/block-trackers.json")!
    }

    /// Maximum age before cached filter lists are re-downloaded.
    private static let maxCacheAge: TimeInterval = 7 * 24 * 60 * 60  // 7 days

    /// Local directory for downloaded filter list JSON.
    private static var cacheDirectory: URL {
        let appSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport
            .appendingPathComponent("AgentBrowser/ContentBlocker", isDirectory: true)
    }

    // MARK: - Init

    /// Production initialiser — uses `UserDefaults.standard`.
    convenience init() {
        self.init(defaults: .standard)
    }

    /// Designated initialiser. Accepts explicit UserDefaults so tests can
    /// supply an isolated suite and avoid polluting shared state.
    init(defaults: UserDefaults) {
        self.defaults = defaults
        // Default to enabled on first launch (no stored value yet).
        if defaults.object(forKey: Keys.enabled) == nil {
            defaults.set(true, forKey: Keys.enabled)
        }
        isEnabled = defaults.bool(forKey: Keys.enabled)
    }

    // MARK: - Setup

    /// Downloads (if stale) and compiles EasyList/EasyPrivacy. Always compiles
    /// the bundled fallback so blocking works offline from first launch.
    func setUp() async {
        // Always ensure the fallback list is compiled first.
        await compileFallback()

        // Capture staleness check on MainActor before detaching.
        let lastFetch = defaults.double(forKey: Keys.lastFetch)
        let elapsed   = Date().timeIntervalSince1970 - lastFetch
        let isStale   = elapsed > Self.maxCacheAge || lastFetch == 0

        guard isStale else { return }

        // Refresh filter lists off the main thread.
        Task.detached(priority: .utility) { [weak self] in
            await self?.refreshFilterLists()
        }
    }

    // MARK: - Apply / Remove

    /// Injects all compiled WKContentRuleLists into `configuration`'s
    /// userContentController if content blocking is enabled.
    func applyRules(to configuration: WKWebViewConfiguration) {
        track(configuration)
        guard isEnabled else { return }
        for list in compiledLists {
            configuration.userContentController.add(list)
        }
    }

    /// Removes all content rule lists from `configuration`.
    func removeRules(from configuration: WKWebViewConfiguration) {
        configuration.userContentController.removeAllContentRuleLists()
    }

    // MARK: - Toggle

    /// Flips `isEnabled` and applies or removes rules from every tracked config.
    func toggleEnabled() {
        isEnabled.toggle()
        let liveConfigs = trackedConfigurations.compactMap(\.value)
        if isEnabled {
            for config in liveConfigs {
                for list in compiledLists {
                    config.userContentController.add(list)
                }
            }
        } else {
            for config in liveConfigs {
                config.userContentController.removeAllContentRuleLists()
            }
        }
        // Purge any dead references collected during the loop.
        pruneTrackedConfigurations()
    }

    // MARK: - Private: compilation

    private func compileFallback() async {
        let list = await compile(
            identifier: ContentBlockerRules.fallbackIdentifier,
            json: ContentBlockerRules.fallbackJSON
        )
        if let list, !compiledLists.contains(where: { $0.identifier == list.identifier }) {
            compiledLists.append(list)
        }
    }

    private func compile(identifier: String, json: String) async -> WKContentRuleList? {
        guard let store = WKContentRuleListStore.default() else {
            print("[ContentBlockerManager] WKContentRuleListStore unavailable — compile skipped (\(identifier))")
            return nil
        }
        return await withCheckedContinuation { continuation in
            store.compileContentRuleList(
                forIdentifier: identifier,
                encodedContentRuleList: json
            ) { ruleList, error in
                if let error {
                    print("[ContentBlockerManager] Compile failed (\(identifier)): \(error)")
                }
                continuation.resume(returning: ruleList)
            }
        }
    }

    // MARK: - Private: download + refresh

    /// Called from a detached task — no MainActor isolation assumed.
    private func refreshFilterLists() async {
        let cacheDir = Self.cacheDirectory
        try? FileManager.default.createDirectory(
            at: cacheDir, withIntermediateDirectories: true)

        // Download EasyList (ad-blocking rules in Safari Content Blocker JSON format).
        let easylistURL = cacheDir.appendingPathComponent("easylist.json")
        await downloadIfNeeded(
            from: FilterURLs.easylist,
            to: easylistURL,
            identifier: Keys.easylistID
        )

        // Download EasyPrivacy (tracker/analytics-blocking rules).
        let easyprivacyURL = cacheDir.appendingPathComponent("easyprivacy.json")
        await downloadIfNeeded(
            from: FilterURLs.easyprivacy,
            to: easyprivacyURL,
            identifier: Keys.easyprivacyID
        )
    }

    private func downloadIfNeeded(from url: URL, to file: URL, identifier: String) async {
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                return
            }
            guard let json = String(data: data, encoding: .utf8) else { return }

            // Validate it's JSON before caching.
            guard json.hasPrefix("[") || json.hasPrefix("{") else { return }

            try data.write(to: file, options: .atomic)

            // Compile and register on MainActor.
            let list = await compile(identifier: identifier, json: json)
            await MainActor.run { [weak self, list] in
                guard let self, let list else { return }
                // Replace any existing entry for this identifier.
                self.compiledLists.removeAll { $0.identifier == identifier }
                self.compiledLists.append(list)
                // Re-apply to tracked configs if enabled.
                if self.isEnabled {
                    let liveConfigs = self.trackedConfigurations.compactMap(\.value)
                    for config in liveConfigs {
                        config.userContentController.add(list)
                    }
                }
                self.pruneTrackedConfigurations()
                // Stamp the last-fetch time only after a successful compile.
                self.defaults.set(Date().timeIntervalSince1970, forKey: Keys.lastFetch)
            }
        } catch {
            print("[ContentBlockerManager] Download failed (\(url)): \(error)")
        }
    }

    // MARK: - Private: weak tracking

    private func track(_ configuration: WKWebViewConfiguration) {
        pruneTrackedConfigurations()
        // Don't double-track the same instance.
        guard !trackedConfigurations.contains(where: { $0.value === configuration }) else { return }
        trackedConfigurations.append(WeakConfig(configuration))
    }

    private func pruneTrackedConfigurations() {
        trackedConfigurations.removeAll { $0.value == nil }
    }
}

// MARK: - WeakConfig

/// Wraps WKWebViewConfiguration weakly so ContentBlockerManager doesn't
/// retain configurations (which in turn retain the WKWebView graph).
private final class WeakConfig {
    weak var value: WKWebViewConfiguration?
    init(_ value: WKWebViewConfiguration) { self.value = value }
}
