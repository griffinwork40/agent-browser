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

    /// All open tabs, ordered. Append-only externally; removal via closeTab.
    private(set) var tabs: [BrowserTab] = []

    /// Index of the currently visible tab. -1 if none.
    private(set) var selectedTabIndex: Int = -1

    /// Stack of recently closed tab URLs for reopening.
    private(set) var closedTabStack: [(url: URL?, index: Int)] = []

    /// Called whenever the selected tab changes (from any source: UI or automation).
    /// The window controller registers this to sync its displayed WKWebView.
    var onSelectionChanged: (() -> Void)?

    /// The currently selected tab, or nil.
    var activeTab: BrowserTab? {
        guard selectedTabIndex >= 0, selectedTabIndex < tabs.count else { return nil }
        return tabs[selectedTabIndex]
    }

    // MARK: - Tab Lifecycle

    /// Create a new empty tab. Returns it.
    @discardableResult
    func createTab(url: URL? = nil) -> BrowserTab {
        let tab = BrowserTab()
        tabs.append(tab)

        // Wire popup callback
        tab.onNewTabRequested = { [weak self] u in
            let t = self?.createTab(url: u)
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
        closedTabStack.append((url: tab.url, index: index))
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

    /// Reopen the most recently closed tab. Returns it, or nil.
    @discardableResult
    func reopenClosedTab() -> BrowserTab? {
        guard let closed = closedTabStack.popLast(), let url = closed.url else { return nil }
        let tab = BrowserTab()
        let insertIndex = min(closed.index, tabs.count)
        tabs.insert(tab, at: insertIndex)

        tab.onNewTabRequested = { [weak self] u in
            let t = self?.createTab(url: u)
            if let t { self?.select(tab: t) }
        }

        tab.load(url)
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
