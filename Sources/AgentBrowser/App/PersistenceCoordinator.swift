import AppKit
import GRDB

/// Bridges the persistence layer (SessionStore, HistoryStore, BookmarkStore,
/// PersistenceManager) into the app lifecycle. Owned by AppDelegate.
///
/// - Session restore: call `restoreSession(into:)` after the window is ready.
/// - Session save: call `saveSession(from:)` on quit and on the auto-save timer.
/// - Auto-save: call `startAutoSave(tabManager:)` to begin 30-second snapshots.
///
/// Each profile owns its own HistoryStore and BookmarkStore, keyed by profile
/// UUID. Stores are created on demand the first time `setUp(defaultProfileID:)`
/// is called and whenever a new profile requests a store via
/// `makeHistoryStore(for:)` or `makeBookmarkStore(for:)`.
///
/// `@MainActor`-isolated so the mutable `historyStores` and `bookmarkStores`
/// dictionaries are accessed exclusively on the main actor, matching the
/// existing call pattern (all call sites run inside `Task { @MainActor in }`).
@MainActor
final class PersistenceCoordinator {

    // Nonisolated stores — all are actor types, called via await.
    private(set) var sessionStore: SessionStore?

    /// Per-profile history stores, keyed by profile UUID.
    private var historyStores: [UUID: HistoryStore] = [:]

    /// Per-profile bookmark stores, keyed by profile UUID.
    private var bookmarkStores: [UUID: BookmarkStore] = [:]

    /// Per-profile DatabaseManager instances, keyed by profile UUID.
    /// Retains open GRDB pools for the lifetime of the coordinator.
    private var databaseManagers: [UUID: DatabaseManager] = [:]

    /// The profile UUID passed to `setUp(defaultProfileID:)`.
    /// Used by the back-compat shims to return a deterministic store.
    private(set) var defaultProfileID: UUID?

    // MARK: - Back-compat shim (single-profile callers)
    // Retained so existing call sites (NavigationCoordinator injection, tests)
    // continue to compile. Returns the store for the default profile.
    var historyStore: HistoryStore? {
        guard let id = defaultProfileID else { return nil }
        return historyStores[id]
    }

    // MARK: - Init

    /// `nonisolated` so `AppDelegate` can create the coordinator as a plain
    /// stored property without an async hop.  All stored properties are
    /// value-type defaults — no actor-isolated mutation occurs here.
    nonisolated init() {}

    // These are @MainActor-isolated by the class annotation.
    private weak var tabManager: TabManager?
    private weak var profileManager: ProfileManager?
    private weak var windowController: BrowserWindowController?
    private var autoSaveTimer: Timer?

    /// Tracks the most recently dispatched auto-save Task so `stopAutoSave()`
    /// can cancel it when a Task was already in-flight when the timer fired.
    /// Invalidating the Timer alone only stops future firings; a Task that was
    /// dispatched before invalidation continues to run unless explicitly cancelled.
    private var pendingAutoSaveTask: Task<Void, Never>?

    // MARK: - Bootstrap

    /// Asynchronously initialises all stores for the default profile via `DatabaseManager`.
    ///
    /// - Parameter defaultProfileID: The UUID of the app's first / default profile.
    ///   Used to:
    ///   1. Create the initial per-profile HistoryStore and BookmarkStore backed by GRDB.
    ///   2. Perform a one-time migration of any flat `history.json` /
    ///      `bookmarks.json` files from the app-support root into the default
    ///      profile's subdirectory, so existing data is not lost on upgrade.
    ///   3. Anchor the back-compat shims (`makeHistoryStore()`,
    ///      `makeBookmarkStore()`) to a deterministic profile.
    ///
    /// Must be called from an async context (e.g. `Task { @MainActor in await coord.setUp(defaultProfileID:) }`).
    func setUp(defaultProfileID: UUID) async {
        self.defaultProfileID = defaultProfileID
        let pm = PersistenceManager.shared
        let rootDir = await pm.dataDirectory
        let profileDir = await pm.profileDataDirectory(for: defaultProfileID)

        sessionStore = SessionStore(dataDirectory: rootDir)

        // One-time migration: move flat files from root into default profile dir.
        await Self.migrateRootFiles(from: rootDir, to: profileDir)

        // Open a GRDB DatabaseManager for the default profile. Falls back to
        // the dataDirectory convenience inits if the DB cannot be opened.
        do {
            let dbManager = try DatabaseManager(directory: profileDir)
            databaseManagers[defaultProfileID] = dbManager
            historyStores[defaultProfileID]  = HistoryStore(dbWriter: dbManager.historyWriter)
            bookmarkStores[defaultProfileID] = BookmarkStore(dbWriter: dbManager.browserWriter)
        } catch {
            fputs("PersistenceCoordinator.setUp: DatabaseManager failed for default profile: \(error)\n", stderr)
            historyStores[defaultProfileID]  = HistoryStore(dataDirectory: profileDir)
            bookmarkStores[defaultProfileID] = BookmarkStore(dataDirectory: profileDir)
        }
    }

    // MARK: - Migration

    /// Moves `history.json` and `bookmarks.json` from the app-support root into
    /// `profileDir` if they exist at the root and do NOT yet exist in `profileDir`.
    ///
    /// This is a one-time operation: once a file lives in `profileDir` the root
    /// copy is gone and subsequent launches skip the migration silently.
    private static func migrateRootFiles(from rootDir: URL, to profileDir: URL) async {
        let fm = FileManager.default
        for filename in ["history.json", "bookmarks.json"] {
            let source = rootDir.appendingPathComponent(filename)
            let destination = profileDir.appendingPathComponent(filename)
            guard fm.fileExists(atPath: source.path),
                  !fm.fileExists(atPath: destination.path) else { continue }
            do {
                try fm.moveItem(at: source, to: destination)
            } catch {
                // Non-fatal: log and fall through; the profile gets an empty store.
                fputs("PersistenceCoordinator: migration failed for \(filename): \(error)\n", stderr)
            }
        }
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
            // Synchronous assignment — Timer fires on RunLoop.main (main thread).
            // MainActor.assumeIsolated satisfies the compiler's actor-isolation
            // check without scheduling an additional async hop.
            MainActor.assumeIsolated { self.pendingAutoSaveTask = task }
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
        // Track the task so stopAutoSave() can cancel an in-flight profile-switch
        // save — otherwise a concurrent save races the quit snapshot.
        let task = Task {
            let ok = await store.saveWorkspaces(workspaces, activeProfileID: activeProfileID)
            if !ok {
                fputs("PersistenceCoordinator: saveAllWorkspaces failed\n", stderr)
            }
        }
        pendingAutoSaveTask = task
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

    // MARK: - Per-Profile Store Access

    /// Returns the HistoryStore for `profileID`, creating it on demand if needed.
    ///
    /// Opens a GRDB `DatabaseManager` for the profile directory and wires the
    /// store to the shared pool. Falls back to the dataDirectory convenience init
    /// if the DB cannot be opened.
    ///
    /// Stores created on demand do NOT perform the one-time root migration (that
    /// only runs during `setUp`). This covers profiles created after initial
    /// launch — they start with an empty store.
    func makeHistoryStore(for profileID: UUID) async -> HistoryStore {
        if let existing = historyStores[profileID] { return existing }
        let dir = await PersistenceManager.shared.profileDataDirectory(for: profileID)
        let store = await openHistoryStore(for: profileID, directory: dir)
        historyStores[profileID] = store
        return store
    }

    /// Returns the BookmarkStore for `profileID`, creating it on demand if needed.
    func makeBookmarkStore(for profileID: UUID) async -> BookmarkStore {
        if let existing = bookmarkStores[profileID] { return existing }
        let dir = await PersistenceManager.shared.profileDataDirectory(for: profileID)
        let store = await openBookmarkStore(for: profileID, directory: dir)
        bookmarkStores[profileID] = store
        return store
    }

    // MARK: - Back-compat single-profile helpers

    /// Returns the HistoryStore for the default profile.
    /// Kept for call sites that pre-date per-profile partitioning.
    func makeHistoryStore() -> HistoryStore? {
        guard let id = defaultProfileID else { return nil }
        return historyStores[id]
    }

    /// Returns the BookmarkStore for the default profile.
    /// Kept for call sites that pre-date per-profile partitioning.
    func makeBookmarkStore() -> BookmarkStore? {
        guard let id = defaultProfileID else { return nil }
        return bookmarkStores[id]
    }

    // MARK: - Private helpers

    /// Opens or reuses a `DatabaseManager` for `profileID` / `directory` and
    /// returns the HistoryStore wired to its history pool.
    private func openHistoryStore(for profileID: UUID, directory: URL) async -> HistoryStore {
        if let dbManager = databaseManagers[profileID] {
            return HistoryStore(dbWriter: dbManager.historyWriter)
        }
        do {
            let dbManager = try DatabaseManager(directory: directory)
            databaseManagers[profileID] = dbManager
            return HistoryStore(dbWriter: dbManager.historyWriter)
        } catch {
            fputs("PersistenceCoordinator: DatabaseManager failed for profile \(profileID): \(error)\n", stderr)
            return HistoryStore(dataDirectory: directory)
        }
    }

    /// Opens or reuses a `DatabaseManager` for `profileID` / `directory` and
    /// returns the BookmarkStore wired to its browser pool.
    private func openBookmarkStore(for profileID: UUID, directory: URL) async -> BookmarkStore {
        if let dbManager = databaseManagers[profileID] {
            return BookmarkStore(dbWriter: dbManager.browserWriter)
        }
        do {
            let dbManager = try DatabaseManager(directory: directory)
            databaseManagers[profileID] = dbManager
            return BookmarkStore(dbWriter: dbManager.browserWriter)
        } catch {
            fputs("PersistenceCoordinator: DatabaseManager failed for profile \(profileID): \(error)\n", stderr)
            return BookmarkStore(dataDirectory: directory)
        }
    }

    // MARK: - Test Hooks

    /// Inject a SessionStore directly, bypassing `PersistenceManager.shared`.
    /// Internal so `@testable import` exposes it to the test target.
    func _testSetSessionStore(_ store: SessionStore) {
        sessionStore = store
    }

    /// Inject a pending auto-save task for unit testing of the cancellation path.
    func _testSetPendingAutoSaveTask(_ task: Task<Void, Never>) {
        pendingAutoSaveTask = task
    }
}
