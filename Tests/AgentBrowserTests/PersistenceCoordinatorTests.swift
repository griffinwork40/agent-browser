import XCTest
@testable import AgentBrowser

// MARK: - PersistenceCoordinatorTests
//
// Covers the quit coordinator's stopAutoSave-before-save ordering invariant:
//
//  1. stopAutoSave cancels a pending auto-save Task before it completes.
//  2. After stopAutoSave, saveAllWorkspacesAndWait produces the definitive
//     quit snapshot without a racing auto-save overwriting it.

final class PersistenceCoordinatorTests: XCTestCase {

    // MARK: - Helpers

    private func withCoordinator(
        _ body: (PersistenceCoordinator, SessionStore, URL) async throws -> Void
    ) async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("coord-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let coordinator = PersistenceCoordinator()
        let store = SessionStore(dataDirectory: dir)
        coordinator._testSetSessionStore(store)

        try await body(coordinator, store, dir)
    }

    private func makeEntry(
        profileID: UUID,
        title: String = "Tab",
        urlString: String? = nil
    ) -> ProfileWorkspace.TabEntry {
        ProfileWorkspace.TabEntry(
            id: UUID(),
            urlString: urlString,
            title: title,
            provenance: .human,
            profileID: profileID
        )
    }

    // MARK: - Test 1: stopAutoSave cancels the pending Task

    @MainActor
    func testStopAutoSave_cancelsPendingTask() async throws {
        try await withCoordinator { coordinator, _, _ in
            var saveBodyRan = false

            let task = Task<Void, Never> {
                // Cooperative cancellation check — mirrors what real async work
                // hits before crossing into actor-isolated operations.
                guard !Task.isCancelled else { return }
                saveBodyRan = true
            }

            coordinator._testSetPendingAutoSaveTask(task)
            coordinator.stopAutoSave()
            await task.value

            XCTAssertFalse(
                saveBodyRan,
                "stopAutoSave() must cancel the pending Task before its body runs"
            )
        }
    }

    // MARK: - Test 2: Quit ordering — no racing auto-save overwrites the quit snapshot

    @MainActor
    func testQuitPath_stopThenSaveAndWait_noRace() async throws {
        try await withCoordinator { coordinator, store, _ in
            let profileID = UUID()

            // Data a racing auto-save would write (the wrong data).
            let racingEntry = makeEntry(
                profileID: profileID,
                title: "Racing AutoSave",
                urlString: "https://racing.example"
            )
            let racingWs = ProfileWorkspace(
                profileID: profileID,
                tabs: [racingEntry],
                selectedTabID: racingEntry.id
            )

            // Simulate an in-flight auto-save Task that yields once before writing.
            let racingTask = Task<Void, Never> {
                await Task.yield()
                guard !Task.isCancelled else { return }
                await store.saveWorkspaces(
                    [profileID: racingWs], activeProfileID: profileID
                )
            }
            coordinator._testSetPendingAutoSaveTask(racingTask)

            // --- Quit path ordering ---
            // Step 1: cancel in-flight task.
            coordinator.stopAutoSave()

            // Step 2: write the authoritative quit snapshot.
            let quitEntry = makeEntry(
                profileID: profileID,
                title: "Quit Snapshot",
                urlString: "https://quit.example"
            )
            let quitWs = ProfileWorkspace(
                profileID: profileID,
                tabs: [quitEntry],
                selectedTabID: quitEntry.id
            )
            let success = await coordinator.saveAllWorkspacesAndWait(
                [profileID: quitWs], activeProfileID: profileID
            )
            XCTAssertTrue(success, "saveAllWorkspacesAndWait must succeed")

            // Drain the racing task so it can't write after our assertion.
            await racingTask.value

            // Verify disk has the quit snapshot, not the racing one.
            let restored = await store.restore()
            let restoredWs = restored?.workspace(for: profileID)
            XCTAssertEqual(
                restoredWs?.tabs.first?.title, "Quit Snapshot",
                "Disk must contain the quit snapshot, not the racing auto-save"
            )
            XCTAssertEqual(restoredWs?.tabs.count, 1)
        }
    }

    // MARK: - Test 3: saveAllWorkspacesAndWait returns false on write failure

    @MainActor
    func testSaveAllWorkspacesAndWait_returnsFalseOnFailure() async throws {
        // Point at a nonexistent directory — the write will fail.
        let badDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("does-not-exist-\(UUID().uuidString)", isDirectory: true)
        let coordinator = PersistenceCoordinator()
        let store = SessionStore(dataDirectory: badDir)
        coordinator._testSetSessionStore(store)

        let profileID = UUID()
        let ws = ProfileWorkspace.empty(for: profileID)
        let result = await coordinator.saveAllWorkspacesAndWait(
            [profileID: ws], activeProfileID: profileID
        )
        XCTAssertFalse(result, "Must return false when the disk write fails")
    }
}
