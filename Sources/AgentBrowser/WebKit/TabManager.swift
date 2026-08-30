import AppKit
import WebKit
import Observation

/// Shared, app-global tab registry. Both the UI (BrowserWindowController) and
/// the automation layer (BrowserAutomationService) access tabs through here.
///
/// Single-window for now. When multi-window arrives, this becomes per-window
/// and an AppState object routes to the right one.
@Observable @MainActor
final class TabManager {

    let profileManager: ProfileManager

    /// All open tabs, ordered. Append-only externally; removal via closeTab.
    private(set) var tabs: [BrowserTab] = []

    /// Index of the currently visible tab. -1 if none.
    private(set) var selectedTabIndex: Int = -1

    /// Stack of recently closed tab URLs for reopening.
    /// Stores the URL, original index, and profile the tab belonged to.
    private(set) var closedTabStack: [(url: URL?, index: Int, profileID: UUID)] = []

    /// Called whenever the selected tab changes (from any source: UI or automation).
    /// The window controller registers this to sync its displayed WKWebView.
    var onSelectionChanged: (() -> Void)?

    /// The currently selected tab, or nil.
    var activeTab: BrowserTab? {
        guard selectedTabIndex >= 0, selectedTabIndex < tabs.count else { return nil }
        return tabs[selectedTabIndex]
    }

    init(profileManager: ProfileManager) {
        self.profileManager = profileManager
    }

    /// Convenience initialiser for tests and previews.
    convenience init() {
        self.init(profileManager: ProfileManager())
    }

    // MARK: - Tab Lifecycle

    /// Create a new empty tab. Returns it.
    /// - Parameters:
    ///   - url: Optional URL to load immediately.
    ///   - provenance: Who created this tab.
    ///   - profileID: Which profile's data store to use. Defaults to the active profile.
    @discardableResult
    func createTab(
        url: URL? = nil,
        provenance: TabProvenance = .human,
        profileID: UUID? = nil
    ) -> BrowserTab {
        let resolvedProfileID = profileID ?? profileManager.activeProfileID
        let record = TabRecord(provenance: provenance, profileID: resolvedProfileID)
        let config = profileManager.makeConfiguration(for: resolvedProfileID)
        let tab = BrowserTab(record: record, configuration: config)
        tabs.append(tab)

        // Wire popup callback — child tabs inherit the parent's profile.
        tab.onNewTabRequested = { [weak self] u in
            let t = self?.createTab(url: u, profileID: resolvedProfileID)
            if let t { self?.select(tab: t) }
        }

        if let url {
            tab.load(url)
        }
        return tab
    }

    /// Close a specific tab by reference. Returns true if found and closed.
    @discardableResult
    func closeTab(_ tab: BrowserTab) -> Bool {
        guard let index = tabs.firstIndex(where: { $0.id == tab.id }) else { return false }
        closedTabStack.append((url: tab.url, index: index, profileID: tab.record.profileID))
        tabs.remove(at: index)

        // Adjust selectedTabIndex
        if tabs.isEmpty {
            selectedTabIndex = -1
        } else if index <= selectedTabIndex {
            selectedTabIndex = max(0, min(selectedTabIndex - 1, tabs.count - 1))
        }
        return true
    }

    /// Close the currently selected tab.
    func closeCurrentTab() {
        guard let tab = activeTab else { return }
        closeTab(tab)
    }

    /// Clear the closed-tab history stack. Call after a profile switch so
    /// Cmd+Shift+T cannot reopen tabs that belonged to a different profile.
    func clearClosedTabStack() {
        closedTabStack.removeAll()
    }

    /// Reopen the most recently closed tab. Returns it, or nil.
    /// Blank tabs (no URL) are restored as new empty tabs rather than discarded.
    @discardableResult
    func reopenClosedTab() -> BrowserTab? {
        // Pop first; only return nil if the stack was empty.
        guard let closed = closedTabStack.popLast() else { return nil }
        let profileID = closed.profileID
        let record = TabRecord(
            provenance: .restored(originalAgentID: nil, originalSessionTag: nil),
            profileID: profileID
        )
        let config = profileManager.makeConfiguration(for: profileID)
        let tab = BrowserTab(record: record, configuration: config)
        let insertIndex = min(closed.index, tabs.count)
        tabs.insert(tab, at: insertIndex)

        tab.onNewTabRequested = { [weak self] u in
            let t = self?.createTab(url: u, profileID: profileID)
            if let t { self?.select(tab: t) }
        }

        // Load the saved URL if one exists; otherwise restore as a blank tab.
        if let url = closed.url {
            tab.load(url)
        }
        return tab
    }

    // MARK: - Selection

    func select(tab: BrowserTab) {
        guard let index = tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        selectedTabIndex = index
        onSelectionChanged?()
    }

    func selectTab(at index: Int) {
        guard index >= 0, index < tabs.count else { return }
        selectedTabIndex = index
        onSelectionChanged?()
    }

    func selectNextTab() {
        guard !tabs.isEmpty else { return }
        selectTab(at: (selectedTabIndex + 1) % tabs.count)
    }

    func selectPreviousTab() {
        guard !tabs.isEmpty else { return }
        selectTab(at: (selectedTabIndex - 1 + tabs.count) % tabs.count)
    }

    // MARK: - Lookup

    /// Find a tab by its stable UUID-based ID.
    func tab(for id: UUID) -> BrowserTab? {
        tabs.first { $0.id == id }
    }

    /// Shortened hex ID for external display (first 8 chars of UUID).
    static func shortID(_ uuid: UUID) -> String {
        String(uuid.uuidString.prefix(8)).lowercased()
    }
}
