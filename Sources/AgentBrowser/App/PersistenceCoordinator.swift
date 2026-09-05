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
    @MainActor private weak var profileManager: ProfileManager?
    @MainActor private weak var windowController: BrowserWindowController?
    @MainActor private var autoSaveTimer: Timer?

    /// Tracks the most recently dispatched auto-save Task so `stopAutoSave()`
    /// can cancel it when a Task was already in-flight when the timer fired.
    /// Invalidating the Timer alone only stops future firings; a Task that was
    /// dispatched before invalidation continues to run unless explicitly cancelled.
    @MainActor private var pendingAutoSaveTask: Task<Void, Never>?

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
    ///
    /// When `profileManager` and `windowController` are supplied, saves all
    /// profile workspaces (P4). Falls back to the flat session path otherwise.
    @MainActor
    func startAutoSave(
        tabManager: TabManager,
        profileManager: ProfileManager? = nil,
        windowController: BrowserWindowController? = nil
    ) {
        self.tabManager = tabManager
        self.profileManager = profileManager
        self.windowController = windowController
        autoSaveTimer?.invalidate()
        autoSaveTimer = Timer.scheduledTimer(
            withTimeInterval: 30,
            repeats: true
        ) { [weak self] _ in
            guard let self else { return }
            // Track the dispatched Task so stopAutoSave() can cancel it if
            // it is still in-flight when the quit path calls stopAutoSave().
            let task = Task { @MainActor [weak self] in
                guard let self else { return }
                if let wc = self.windowController, let pm = self.profileManager {
                    let registry = wc.snapshotAllWorkspaces(
                        tabManager: self.tabManager, profileManager: pm)
                    self.saveAllWorkspaces(registry, activeProfileID: pm.activeProfileID)
                } else if let tm = self.tabManager {
                    self.saveSession(from: tm)
                }
            }
            // Assign on MainActor; the closure above captures `self` weakly so
            // we use a separate MainActor block to store the handle.
            Task { @MainActor [weak self] in
                self?.pendingAutoSaveTask = task
            }
        }
    }

    @MainActor
    func stopAutoSave() {
        autoSaveTimer?.invalidate()
        autoSaveTimer = nil
        // Cancel any Task that was already dispatched by the timer's last firing
        // but has not yet completed. Without this, a racing auto-save Task can
        // overwrite the quit-time snapshot after saveAllWorkspacesAndWait returns.
        pendingAutoSaveTask?.cancel()
        pendingAutoSaveTask = nil
    }

    // MARK: - Workspace Save

    /// Persists all profile workspaces atomically, including backward-compatible
    /// legacy `tabs` field populated from the active profile's workspace.
    ///
    /// Called from `BrowserWindowController+ProfileSwitch` when switching profiles,
    /// and from the auto-save path when workspace support is active.
    @MainActor
    func saveAllWorkspaces(
        _ workspaces: [UUID: ProfileWorkspace],
        activeProfileID: UUID
    ) {
        guard let store = sessionStore else { return }
        Task {
            await store.saveWorkspaces(workspaces, activeProfileID: activeProfileID)
        }
    }

    /// Awaitable variant used by the quit path (applicationShouldTerminate) so the
    /// caller can await disk flush before calling `NSApp.reply(toApplicationShouldTerminate:)`.
    ///
    /// Ordering note: caller must call `stopAutoSave()` BEFORE this to prevent a
    /// concurrent auto-save from racing the quit snapshot. `stopAutoSave()` also
    /// cancels any in-flight auto-save Task, enforcing the ordering invariant.
    ///
    /// - Returns: `true` if the workspace was written successfully; `false` on
    ///   encode or disk-write failure. The quit path proceeds regardless (we cannot
    ///   block app termination indefinitely on a write error), but the return value
    ///   lets callers log the failure for diagnostics.
    @MainActor
    @discardableResult
    func saveAllWorkspacesAndWait(
        _ workspaces: [UUID: ProfileWorkspace],
        activeProfileID: UUID
    ) async -> Bool {
        guard let store = sessionStore else { return false }
        return await store.saveWorkspaces(workspaces, activeProfileID: activeProfileID)
    }

    // MARK: - Workspace Restore

    /// Reads any saved workspaces from disk. Returns an empty dictionary if none exist.
    /// Falls back to migrating the legacy flat `tabs` array when `workspaces` is absent.
    func restoreWorkspaces(activeProfileID: UUID) async -> [UUID: ProfileWorkspace] {
        guard let store = sessionStore else { return [:] }
        guard let snapshot = await store.restore() else { return [:] }

        if let coded = snapshot.workspaces, !coded.isEmpty {
            // v2 format: keyed by UUID string
            return Dictionary(uniqueKeysWithValues: coded.compactMap { k, v -> (UUID, ProfileWorkspace)? in
                guard let uuid = UUID(uuidString: k) else { return nil }
                return (uuid, v)
            })
        }
        // Legacy migration: distribute flat tabs by profileID.
        return snapshot.migratedWorkspaces(activeProfileID: activeProfileID)
    }

    // MARK: - History Store Access

    /// Returns the shared HistoryStore for injection into NavigationCoordinator.
    func makeHistoryStore() -> HistoryStore? {
        historyStore
    }
}
