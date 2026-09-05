import XCTest
@testable import AgentBrowser

// MARK: - ProfileWorkspaceTests

final class ProfileWorkspaceTests: XCTestCase {

    // MARK: - ProfileWorkspace model

    func testEmptyWorkspace() {
        let id = UUID()
        let ws = ProfileWorkspace.empty(for: id)
        XCTAssertEqual(ws.profileID, id)
        XCTAssertTrue(ws.tabs.isEmpty)
        XCTAssertNil(ws.selectedTabID)
        XCTAssertTrue(ws.closedTabHistory.isEmpty)
        XCTAssertTrue(ws.isEmpty)
    }

    func testWorkspaceEquality() {
        let id = UUID()
        let ws1 = ProfileWorkspace.empty(for: id)
        let ws2 = ProfileWorkspace.empty(for: id)
        XCTAssertEqual(ws1, ws2)
    }

    func testAddClosedTabCapsHistory() {
        let id = UUID()
        var ws = ProfileWorkspace.empty(for: id)
        // Add more than the cap
        for i in 0..<(ProfileWorkspace.maxClosedHistory + 5) {
            let entry = makeEntry(profileID: id, title: "Tab \(i)")
            ws = ws.addingClosed(entry)
        }
        XCTAssertEqual(ws.closedTabHistory.count, ProfileWorkspace.maxClosedHistory)
    }

    func testClosedTabHistoryOrderMostRecentFirst() {
        let id = UUID()
        var ws = ProfileWorkspace.empty(for: id)
        let first = makeEntry(profileID: id, title: "First")
        let second = makeEntry(profileID: id, title: "Second")
        ws = ws.addingClosed(first)
        ws = ws.addingClosed(second)
        XCTAssertEqual(ws.closedTabHistory.first?.title, "Second")
        XCTAssertEqual(ws.closedTabHistory.last?.title, "First")
    }

    // MARK: - Codable round-trip

    func testCodableRoundTrip() throws {
        let profileID = UUID()
        let tabID = UUID()
        let entry = ProfileWorkspace.TabEntry(
            id: tabID,
            urlString: "https://example.com",
            title: "Example",
            provenance: .human,
            profileID: profileID
        )
        let ws = ProfileWorkspace(
            profileID: profileID,
            tabs: [entry],
            selectedTabID: tabID,
            closedTabHistory: []
        )
        let data = try JSONEncoder().encode(ws)
        let decoded = try JSONDecoder().decode(ProfileWorkspace.self, from: data)
        XCTAssertEqual(ws, decoded)
    }

    // MARK: - SessionSnapshot workspace migration

    func testMigratedWorkspacesGroupsByProfileID() {
        let profileA = UUID()
        let profileB = UUID()
        let tabA1 = makeTabSnapshot(profileID: profileA, urlString: "https://a1.com")
        let tabA2 = makeTabSnapshot(profileID: profileA, urlString: "https://a2.com")
        let tabB1 = makeTabSnapshot(profileID: profileB, urlString: "https://b1.com")

        let snapshot = SessionSnapshot(
            tabs: [tabA1, tabA2, tabB1],
            selectedTabID: tabA1.id,
            savedAt: Date()
        )

        let migrated = snapshot.migratedWorkspaces(activeProfileID: profileA)

        XCTAssertEqual(migrated.keys.count, 2)
        let wsA = migrated[profileA]
        XCTAssertNotNil(wsA)
        XCTAssertEqual(wsA?.tabs.count, 2)
        XCTAssertEqual(wsA?.selectedTabID, tabA1.id)

        let wsB = migrated[profileB]
        XCTAssertNotNil(wsB)
        XCTAssertEqual(wsB?.tabs.count, 1)
        XCTAssertNil(wsB?.selectedTabID) // inactive profile has no selection
    }

    func testMigratedWorkspacesEmptySnapshot() {
        let snapshot = SessionSnapshot(
            tabs: [],
            selectedTabID: nil,
            savedAt: Date()
        )
        let migrated = snapshot.migratedWorkspaces(activeProfileID: UUID())
        XCTAssertTrue(migrated.isEmpty)
    }

    // MARK: - SessionSnapshot workspace accessor

    func testWorkspaceForProfileIDNilWhenAbsent() {
        let snapshot = SessionSnapshot(tabs: [], selectedTabID: nil, savedAt: Date())
        XCTAssertNil(snapshot.workspace(for: UUID()))
    }

    func testWorkspaceForProfileIDReturnsCorrect() throws {
        let profileID = UUID()
        let ws = ProfileWorkspace.empty(for: profileID)
        var snapshot = SessionSnapshot(tabs: [], selectedTabID: nil, savedAt: Date())
        snapshot.workspaces = [profileID.uuidString: ws]
        let retrieved = snapshot.workspace(for: profileID)
        XCTAssertNotNil(retrieved)
        XCTAssertEqual(retrieved?.profileID, profileID)
    }

    // MARK: - SessionStore workspace persistence

    func testSaveAndRestoreWorkspaces() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ws-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = SessionStore(dataDirectory: dir)
        let profileA = UUID()
        let profileB = UUID()
        let tabEntry = makeEntry(profileID: profileA, title: "Tab A")
        let wsA = ProfileWorkspace(profileID: profileA, tabs: [tabEntry], selectedTabID: tabEntry.id)
        let wsB = ProfileWorkspace.empty(for: profileB)

        await store.saveWorkspaces([profileA: wsA, profileB: wsB], activeProfileID: profileA)

        let restored = await store.restore()
        XCTAssertNotNil(restored)
        XCTAssertNotNil(restored?.workspaces)

        let restoredWsA = restored?.workspace(for: profileA)
        XCTAssertNotNil(restoredWsA)
        XCTAssertEqual(restoredWsA?.tabs.count, 1)
        XCTAssertEqual(restoredWsA?.selectedTabID, tabEntry.id)

        let restoredWsB = restored?.workspace(for: profileB)
        XCTAssertNotNil(restoredWsB)
        XCTAssertTrue(restoredWsB?.tabs.isEmpty ?? false)
    }

    func testLegacyRestoreHasNoWorkspaces() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("legacy-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // Write a legacy snapshot (no workspaces field)
        let legacyJSON = """
        {"tabs":[],"selectedTabID":null,"savedAt":0}
        """
        let fileURL = dir.appendingPathComponent("session.json")
        try legacyJSON.data(using: .utf8)!.write(to: fileURL)

        let store = SessionStore(dataDirectory: dir)
        let restored = await store.restore()
        XCTAssertNotNil(restored)
        XCTAssertNil(restored?.workspaces) // absent in legacy
    }

    func testSaveWorkspacesUpdatesLegacyFieldsFromActiveProfile() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("legacy-sync-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = SessionStore(dataDirectory: dir)
        let activeID = UUID()
        let inactiveID = UUID()
        let tabEntry = makeEntry(profileID: activeID, title: "Active Tab")
        let activeWs = ProfileWorkspace(profileID: activeID, tabs: [tabEntry], selectedTabID: tabEntry.id)
        let inactiveWs = ProfileWorkspace.empty(for: inactiveID)

        await store.saveWorkspaces([activeID: activeWs, inactiveID: inactiveWs], activeProfileID: activeID)

        let restored = await store.restore()
        // Legacy tabs should only contain the active profile's tabs
        XCTAssertEqual(restored?.tabs.count, 1)
        XCTAssertEqual(restored?.selectedTabID, tabEntry.id)
    }

    // MARK: - Helpers

    private func makeEntry(profileID: UUID, title: String = "Tab") -> ProfileWorkspace.TabEntry {
        ProfileWorkspace.TabEntry(
            id: UUID(),
            urlString: nil,
            title: title,
            provenance: .human,
            profileID: profileID
        )
    }

    private func makeTabSnapshot(profileID: UUID, urlString: String) -> SessionSnapshot.TabSnapshot {
        SessionSnapshot.TabSnapshot(
            id: UUID(),
            urlString: urlString,
            title: urlString,
            provenance: .human,
            profileID: profileID
        )
    }
}
