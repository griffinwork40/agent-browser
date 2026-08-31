import AppKit

/// Bridges the persistence layer (SessionStore, HistoryStore, PersistenceManager)
/// into the app lifecycle. Owned by AppDelegate.
///
/// - Session restore: call `restoreSession(into:)` after the window is ready.
/// - Session save: call `saveSession(from:)` on quit and on the auto-save timer.
/// - Auto-save: call `startAutoSave(tabManager:)` to begin 30-second snapshots.
///
/// Not `@MainActor` at the class level so it can be stored as a plain stored
/// property on `AppDelegate` (which is not actor-isolated). Individual methods
/// that touch MainActor-isolated types (TabManager, BrowserTab) are annotated
/// `@MainActor` and must be called from that context.
final class PersistenceCoordinator {

    // Nonisolated stores — both are actor types, called via await.
    private(set) var sessionStore: SessionStore?
    private(set) var historyStore: HistoryStore?

    // MainActor-isolated state used by auto-save.
    @MainActor private weak var tabManager: TabManager?
    @MainActor private var autoSaveTimer: Timer?

    // MARK: - Bootstrap

    /// Asynchronously initialises both stores from `PersistenceManager.shared`.
    /// Must be called from an async context (e.g. `Task { await coord.setUp() }`).
    func setUp() async {
        let dir = await PersistenceManager.shared.dataDirectory
        sessionStore = SessionStore(dataDirectory: dir)
        historyStore = HistoryStore(dataDirectory: dir)
    }

    // MARK: - Session Restore

    /// Reads the on-disk snapshot and recreates tabs in `tabManager`.
    ///
    /// If no snapshot is present, opens a single blank tab as normal.
    /// Returns `true` when a snapshot was applied (caller can skip the default
    /// blank-tab creation path).
    @MainActor
    @discardableResult
    func restoreSession(into tabManager: TabManager) async -> Bool {
        guard let store = sessionStore else { return false }

        let snapshot = await store.restore()
        guard let snapshot, !snapshot.tabs.isEmpty else { return false }

        for tabSnap in snapshot.tabs {
            let provenance: TabProvenance = .restored(
                originalAgentID: nil,
                originalSessionTag: nil
            )
            tabManager.createTab(
                url: tabSnap.url,
                provenance: provenance,
                profileID: tabSnap.profileID
            )
        }

        // Select the previously-active tab if it still exists.
        if let selectedID = snapshot.selectedTabID,
           let activeTab = tabManager.tab(for: selectedID) {
            tabManager.select(tab: activeTab)
        } else {
            tabManager.selectTab(at: 0)
        }

        return true
    }

    // MARK: - Session Save

    /// Snapshots all tabs in `tabManager` and writes to disk.
    /// Must be called from `@MainActor` context (TabManager is MainActor-isolated).
    @MainActor
    func saveSession(from tabManager: TabManager) {
        guard let store = sessionStore else { return }
        let tabSnapshots = tabManager.tabs.map { tab in
            SessionSnapshot.TabSnapshot(
                id: tab.id,
                urlString: tab.url?.absoluteString,
                title: tab.title,
                provenance: tab.record.provenance,
                profileID: tab.record.profileID
            )
        }
        let selectedID = tabManager.activeTab?.id
        Task {
            await store.save(tabs: tabSnapshots, selectedTabID: selectedID)
        }
    }

    // MARK: - Auto-Save

    /// Starts a repeating 30-second timer that snapshots the current session.
    /// Cancels any existing timer first.
    @MainActor
    func startAutoSave(tabManager: TabManager) {
        self.tabManager = tabManager
        autoSaveTimer?.invalidate()
        autoSaveTimer = Timer.scheduledTimer(
            withTimeInterval: 30,
            repeats: true
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor [weak self] in
                guard let self, let tm = self.tabManager else { return }
                self.saveSession(from: tm)
            }
        }
    }

    @MainActor
    func stopAutoSave() {
        autoSaveTimer?.invalidate()
        autoSaveTimer = nil
    }

    // MARK: - History Store Access

    /// Returns the shared HistoryStore for injection into NavigationCoordinator.
    func makeHistoryStore() -> HistoryStore? {
        historyStore
    }
}
