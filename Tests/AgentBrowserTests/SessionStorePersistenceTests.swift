import XCTest
@testable import AgentBrowser

// MARK: - SessionStorePersistenceTests
//
// Regression tests for:
//  1. Awaited quit-save actually persists and surfaces write failure.
//  2. Inactive workspaces are retained in the saved file.
//  3. saveWorkspaces returns false on write failure (unwritable dir).
//  4. saveWorkspaces returns true and round-trips on success.
//
// These tests use only the SessionStore actor (no AppKit, no MainActor).

final class SessionStorePersistenceTests: XCTestCase {

    // MARK: - Helpers

    /// Create a temp directory, run the test body, clean up.
    private func withTempStore(_ body: (SessionStore, URL) async throws -> Void) async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("persist-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SessionStore(dataDirectory: dir)
        try await body(store, dir)
    }

    private func makeEntry(profileID: UUID, title: String = "Tab", urlString: String? = nil) -> ProfileWorkspace.TabEntry {
        ProfileWorkspace.TabEntry(
            id: UUID(),
            urlString: urlString,
            title: title,
            provenance: .human,
            profileID: profileID
        )
    }

    // MARK: - 1. Awaited save returns true and persists data

    /// The quit path awaits saveWorkspaces; verify it returns true on success
    /// and that the data is actually on disk (not just acknowledged in memory).
    func testAwaited_saveWorkspaces_returnsTrueAndPersists() async throws {
        try await withTempStore { store, _ in
            let profileID = UUID()
            let entry = makeEntry(profileID: profileID, title: "Quit-save tab")
            let ws = ProfileWorkspace(profileID: profileID, tabs: [entry], selectedTabID: entry.id)

            let success = await store.saveWorkspaces([profileID: ws], activeProfileID: profileID)
            XCTAssertTrue(success, "saveWorkspaces must return true on a successful write")

            // Verify the data actually hit disk (not a silent no-op).
            let restored = await store.restore()
            XCTAssertNotNil(restored, "restore() must return data after a successful save")
            let restoredWs = restored?.workspace(for: profileID)
            XCTAssertEqual(restoredWs?.tabs.count, 1)
            XCTAssertEqual(restoredWs?.tabs.first?.title, "Quit-save tab")
        }
    }

    // MARK: - 2. Inactive workspaces are retained

    /// When saving multiple profiles, a profile that is NOT the active one must
    /// still appear in the restored workspaces dict (regression: inactive profile
    /// tabs must not be silently dropped on save).
    func testInactiveWorkspaceRetainedAfterSave() async throws {
        try await withTempStore { store, _ in
            let activeID = UUID()
            let inactiveID = UUID()

            let activeEntry = makeEntry(profileID: activeID, title: "Active Tab", urlString: "https://active.example")
            let inactiveEntry = makeEntry(profileID: inactiveID, title: "Inactive Tab", urlString: "https://inactive.example")

            let activeWs = ProfileWorkspace(profileID: activeID, tabs: [activeEntry], selectedTabID: activeEntry.id)
            let inactiveWs = ProfileWorkspace(profileID: inactiveID, tabs: [inactiveEntry], selectedTabID: inactiveEntry.id)

            let success = await store.saveWorkspaces(
                [activeID: activeWs, inactiveID: inactiveWs],
                activeProfileID: activeID
            )
            XCTAssertTrue(success)

            let restored = await store.restore()
            XCTAssertNotNil(restored?.workspaces)

            // Active profile preserved.
            let restoredActive = restored?.workspace(for: activeID)
            XCTAssertEqual(restoredActive?.tabs.count, 1, "Active profile tabs must be present")
            XCTAssertEqual(restoredActive?.tabs.first?.title, "Active Tab")

            // Inactive profile preserved — the regression under test.
            let restoredInactive = restored?.workspace(for: inactiveID)
            XCTAssertNotNil(restoredInactive, "Inactive profile workspace must be retained after save")
            XCTAssertEqual(restoredInactive?.tabs.count, 1, "Inactive profile must retain its tabs")
            XCTAssertEqual(restoredInactive?.tabs.first?.title, "Inactive Tab")
        }
    }

    // MARK: - 3. Write failure returns false (unwritable path)

    /// saveWorkspaces must return false — not crash, not silently succeed — when
    /// the destination is not writable. This verifies the quit path can detect
    /// failure rather than proceeding with corrupted or absent session data.
    func testSaveWorkspaces_returnsFalseOnUnwritablePath() async {
        // Use a URL whose parent directory does not exist.
        let noSuchDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("does-not-exist-\(UUID().uuidString)", isDirectory: true)
        // Do NOT create the directory — writes will fail.
        let store = SessionStore(dataDirectory: noSuchDir)

        let profileID = UUID()
        let ws = ProfileWorkspace.empty(for: profileID)
        let result = await store.saveWorkspaces([profileID: ws], activeProfileID: profileID)
        XCTAssertFalse(result, "saveWorkspaces must return false when the disk write fails")
    }

    // MARK: - 4. Multiple inactive profiles round-trip correctly

    /// Verify that saving three profiles (one active, two inactive) and restoring
    /// yields all three workspaces with correct tab counts.
    func testMultipleInactiveProfilesRoundTrip() async throws {
        try await withTempStore { store, _ in
            let activeID = UUID()
            let inactive1 = UUID()
            let inactive2 = UUID()

            let e0 = makeEntry(profileID: activeID, title: "A0")
            let e1 = makeEntry(profileID: inactive1, title: "B0")
            let e2 = makeEntry(profileID: inactive1, title: "B1")
            let e3 = makeEntry(profileID: inactive2, title: "C0")

            let workspaces: [UUID: ProfileWorkspace] = [
                activeID: ProfileWorkspace(profileID: activeID, tabs: [e0], selectedTabID: e0.id),
                inactive1: ProfileWorkspace(profileID: inactive1, tabs: [e1, e2], selectedTabID: e1.id),
                inactive2: ProfileWorkspace(profileID: inactive2, tabs: [e3], selectedTabID: nil),
            ]

            let ok = await store.saveWorkspaces(workspaces, activeProfileID: activeID)
            XCTAssertTrue(ok)

            let snap = await store.restore()
            XCTAssertEqual(snap?.workspace(for: activeID)?.tabs.count, 1)
            XCTAssertEqual(snap?.workspace(for: inactive1)?.tabs.count, 2)
            XCTAssertEqual(snap?.workspace(for: inactive2)?.tabs.count, 1)

            // Legacy fields should only reflect the active profile.
            XCTAssertEqual(snap?.tabs.count, 1, "Legacy flat tabs must mirror only the active profile")
        }
    }

    // MARK: - 5. Legacy fields still populated for backward compat

    /// The legacy `tabs` and `selectedTabID` fields must be populated from the
    /// active profile's workspace so pre-workspace readers still get a usable session.
    func testLegacyFieldsPopulatedFromActiveProfile() async throws {
        try await withTempStore { store, _ in
            let activeID = UUID()
            let inactiveID = UUID()
            let tab1 = makeEntry(profileID: activeID, title: "LegacyTab", urlString: "https://legacy.example")
            let tab2 = makeEntry(profileID: inactiveID, title: "InactiveTab")

            let activeWs = ProfileWorkspace(profileID: activeID, tabs: [tab1], selectedTabID: tab1.id)
            let inactiveWs = ProfileWorkspace(profileID: inactiveID, tabs: [tab2])

            _ = await store.saveWorkspaces([activeID: activeWs, inactiveID: inactiveWs], activeProfileID: activeID)

            let snap = await store.restore()
            // Legacy tabs = active profile only.
            XCTAssertEqual(snap?.tabs.count, 1)
            XCTAssertEqual(snap?.tabs.first?.title, "LegacyTab")
            XCTAssertEqual(snap?.selectedTabID, tab1.id)
        }
    }
}
