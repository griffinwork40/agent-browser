import XCTest
@testable import AgentBrowser

// MARK: - MultiWindowTests
//
// Tests:
//  1. Creating windows registers them in WindowSessionManager.
//  2. Closing a window deregisters it and updates activeWindowController.
//  3. activeWindowController tracks the most-recently-keyed window.
//  4. Each window gets its own TabManager (independent tab sets).
//  5. Session save/restore round-trips with multiple windows.
//  6. Legacy single-window snapshot still restores into a single window.

@MainActor
final class MultiWindowTests: XCTestCase {

    // MARK: - Helpers

    private func makeManager() -> (WindowSessionManager, ProfileManager, PersistenceCoordinator) {
        let pm = ProfileManager()
        let coord = PersistenceCoordinator()
        let wsm = WindowSessionManager(profileManager: pm, persistenceCoordinator: coord)
        return (wsm, pm, coord)
    }

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mw-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - 1. Creating windows

    func testCreateWindow_registersController() {
        let (wsm, _, _) = makeManager()
        XCTAssertTrue(wsm.windowControllers.isEmpty)

        let wc = wsm.createWindow()
        XCTAssertEqual(wsm.windowControllers.count, 1)
        XCTAssertTrue(wsm.windowControllers.first === wc)
    }

    func testCreateMultipleWindows_allRegistered() {
        let (wsm, _, _) = makeManager()
        let wc1 = wsm.createWindow()
        let wc2 = wsm.createWindow()
        let wc3 = wsm.createWindow()

        XCTAssertEqual(wsm.windowControllers.count, 3)
        XCTAssertTrue(wsm.windowControllers[0] === wc1)
        XCTAssertTrue(wsm.windowControllers[1] === wc2)
        XCTAssertTrue(wsm.windowControllers[2] === wc3)
    }

    // MARK: - 2. Closing windows

    func testCloseWindow_deregistersController() {
        let (wsm, _, _) = makeManager()
        let wc1 = wsm.createWindow()
        let wc2 = wsm.createWindow()

        wsm.closeWindow(wc1)

        XCTAssertEqual(wsm.windowControllers.count, 1)
        XCTAssertFalse(wsm.windowControllers.contains { $0 === wc1 })
        XCTAssertTrue(wsm.windowControllers.contains { $0 === wc2 })
    }

    func testCloseLastWindow_emptyRegistry() {
        let (wsm, _, _) = makeManager()
        let wc = wsm.createWindow()

        wsm.closeWindow(wc)

        XCTAssertTrue(wsm.windowControllers.isEmpty)
    }

    func testCloseActiveWindow_updatesActiveController() {
        let (wsm, _, _) = makeManager()
        let wc1 = wsm.createWindow()
        let wc2 = wsm.createWindow()

        // wc2 is active (most recently created)
        XCTAssertTrue(wsm.activeWindowController === wc2)

        wsm.closeWindow(wc2)

        // Should fall back to wc1
        XCTAssertTrue(wsm.activeWindowController === wc1)
    }

    func testCloseNonActiveWindow_activeUnchanged() {
        let (wsm, _, _) = makeManager()
        let wc1 = wsm.createWindow()
        let wc2 = wsm.createWindow()

        // wc2 is active
        wsm.closeWindow(wc1)

        XCTAssertTrue(wsm.activeWindowController === wc2)
    }

    // MARK: - 3. Active window tracking

    func testWindowDidBecomeKey_updatesActive() {
        let (wsm, _, _) = makeManager()
        let wc1 = wsm.createWindow()
        let wc2 = wsm.createWindow()

        // wc2 is active after creation; simulate wc1 becoming key
        wsm.windowDidBecomeKey(wc1)

        XCTAssertTrue(wsm.activeWindowController === wc1)
        _ = wc2 // keep alive
    }

    func testActiveWindowController_nilBeforeAnyWindow() {
        let (wsm, _, _) = makeManager()
        XCTAssertNil(wsm.activeWindowController)
    }

    // MARK: - 4. Independent tab sets

    func testEachWindowHasIndependentTabManager() {
        let (wsm, _, _) = makeManager()
        let wc1 = wsm.createWindow()
        let wc2 = wsm.createWindow()

        // Distinct TabManager objects
        XCTAssertFalse(wc1.tabManager === wc2.tabManager)
    }

    func testTabsInOneWindowDoNotAffectAnother() {
        let (wsm, pm, _) = makeManager()
        let wc1 = wsm.createWindow(skipInitialTab: true)
        let wc2 = wsm.createWindow(skipInitialTab: true)

        wc1.tabManager.createTab(profileID: pm.activeProfileID)
        wc1.tabManager.createTab(profileID: pm.activeProfileID)

        XCTAssertEqual(wc1.tabManager.tabs.count, 2)
        XCTAssertEqual(wc2.tabManager.tabs.count, 0)
    }

    // MARK: - 5. Session save / restore (multi-window)

    func testSaveAndRestoreMultipleWindows() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = SessionStore(dataDirectory: dir)
        let pm = ProfileManager()
        let coord = PersistenceCoordinator()
        coord._testSetSessionStore(store)

        let wsm = WindowSessionManager(profileManager: pm, persistenceCoordinator: coord)

        // Window 1: two tabs
        let wc1 = wsm.createWindow(skipInitialTab: true)
        let pid = pm.activeProfileID
        let t1 = wc1.tabManager.createTab(
            url: URL(string: "https://window1-tab1.example/page"),
            profileID: pid
        )
        let t2 = wc1.tabManager.createTab(
            url: URL(string: "https://window1-tab2.example/page"),
            profileID: pid
        )
        wc1.tabManager.select(tab: t1)

        // Window 2: one tab
        let wc2 = wsm.createWindow(skipInitialTab: true)
        let t3 = wc2.tabManager.createTab(
            url: URL(string: "https://window2-tab1.example/page"),
            profileID: pid
        )
        wc2.tabManager.select(tab: t3)

        // Build snapshots
        let snaps = wsm.windowControllers.map { wc in
            WindowSnapshot(
                workspaces: wc.snapshotAllWorkspaces(
                    tabManager: wc.tabManager,
                    profileManager: wc.profileManager
                ),
                activeProfileID: wc.profileManager.activeProfileID
            )
        }

        let saved = await coord.saveWindowSnapshotsAndWait(snaps, activeProfileID: pid)
        XCTAssertTrue(saved)

        // Restore
        let restored = await coord.restoreWindowSnapshots()
        XCTAssertEqual(restored.count, 2, "Two windows must be restored")

        let win1 = restored[0].workspacesByUUID[pid]
        let win2 = restored[1].workspacesByUUID[pid]

        XCTAssertEqual(win1?.tabs.count, 2)
        XCTAssertEqual(win2?.tabs.count, 1)

        XCTAssertEqual(win1?.selectedTabID, t1.id)
        XCTAssertEqual(win1?.tabs.first?.urlString, "https://window1-tab1.example/page")
        XCTAssertEqual(win2?.tabs.first?.urlString, "https://window2-tab1.example/page")

        _ = t2 // suppress unused warning
    }

    // MARK: - 6. Legacy single-window restore

    func testLegacySingleWindowSnapshot_restoresEmptyWindowArray() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = SessionStore(dataDirectory: dir)
        let pm = ProfileManager()
        let coord = PersistenceCoordinator()
        coord._testSetSessionStore(store)

        let pid = pm.activeProfileID

        // Write an old-style single-window snapshot (no `windows` field).
        let workspace = ProfileWorkspace(
            profileID: pid,
            tabs: [
                .init(id: UUID(), urlString: "https://legacy.example",
                      title: "Legacy", provenance: .human, profileID: pid)
            ],
            selectedTabID: nil
        )
        let ok = await store.saveWorkspaces([pid: workspace], activeProfileID: pid)
        XCTAssertTrue(ok)

        // restoreWindowSnapshots should return [] for legacy files.
        let windows = await coord.restoreWindowSnapshots()
        XCTAssertTrue(windows.isEmpty, "Legacy files must return empty windows array")
    }
}
