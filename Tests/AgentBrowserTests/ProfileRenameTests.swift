import XCTest
@testable import AgentBrowser

// MARK: - ProfileRenameTests

/// Tests for ProfileManager rename, validation, and creation naming (P1).
final class ProfileRenameTests: XCTestCase {

    // MARK: - Helpers

    @MainActor
    private func makeProfileManager() -> ProfileManager {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("rename-test-\(UUID().uuidString)")
        return ProfileManager(storageURL: tmp.appendingPathComponent("profiles.json"))
    }

    // MARK: - Rename

    @MainActor
    func testRenameSucceeds() {
        let pm = makeProfileManager()
        let id = pm.profiles[0].id
        let result = pm.renameProfile(id: id, to: "Work")
        XCTAssertTrue(result)
        XCTAssertEqual(pm.profiles.first?.name, "Work")
    }

    @MainActor
    func testRenameRejectsEmptyName() {
        let pm = makeProfileManager()
        let id = pm.profiles[0].id
        let result = pm.renameProfile(id: id, to: "   ")
        XCTAssertFalse(result)
        XCTAssertEqual(pm.profiles.first?.name, "Default")
    }

    @MainActor
    func testRenameRejectsDuplicateName() {
        let pm = makeProfileManager()
        let second = pm.createProfile(name: "Work")
        // Try renaming Default to "Work"
        let result = pm.renameProfile(id: pm.profiles[0].id, to: "Work")
        XCTAssertFalse(result)
        XCTAssertEqual(pm.profiles.first?.name, "Default")
        _ = second // silence unused warning
    }

    @MainActor
    func testRenameToSameNameSucceeds() {
        // Renaming a profile to its current name is allowed.
        let pm = makeProfileManager()
        let id = pm.profiles[0].id
        let result = pm.renameProfile(id: id, to: "Default")
        XCTAssertTrue(result)
    }

    @MainActor
    func testRenameTrimsWhitespace() {
        let pm = makeProfileManager()
        let id = pm.profiles[0].id
        _ = pm.renameProfile(id: id, to: "  Personal  ")
        XCTAssertEqual(pm.profiles.first?.name, "Personal")
    }

    @MainActor
    func testRenameUnknownIDReturnsFalse() {
        let pm = makeProfileManager()
        let result = pm.renameProfile(id: UUID(), to: "Ghost")
        XCTAssertFalse(result)
    }

    // MARK: - Name availability

    @MainActor
    func testIsNameAvailableTrue() {
        let pm = makeProfileManager()
        XCTAssertTrue(pm.isNameAvailable("Work"))
    }

    @MainActor
    func testIsNameAvailableFalseForExisting() {
        let pm = makeProfileManager()
        XCTAssertFalse(pm.isNameAvailable("Default"))
    }

    @MainActor
    func testIsNameAvailableExcludingOwnID() {
        let pm = makeProfileManager()
        let id = pm.profiles[0].id
        // Excluding the profile's own ID should make its name "available" for itself.
        XCTAssertTrue(pm.isNameAvailable("Default", excludingID: id))
    }

    @MainActor
    func testIsNameAvailableEmptyReturnsFalse() {
        let pm = makeProfileManager()
        XCTAssertFalse(pm.isNameAvailable(""))
        XCTAssertFalse(pm.isNameAvailable("   "))
    }

    // MARK: - Profile creation with name

    @MainActor
    func testCreateProfileWithExplicitName() {
        let pm = makeProfileManager()
        let profile = pm.createProfile(name: "Personal")
        XCTAssertEqual(profile.name, "Personal")
        XCTAssertTrue(pm.profiles.contains { $0.id == profile.id })
    }

    @MainActor
    func testCreateProfileAssignsCyclingColor() {
        let pm = makeProfileManager()
        // Default profile took color 0 ("blue"); new profile should get color 1.
        let second = pm.createProfile(name: "Work")
        let expectedColor = ProfileRecord.defaultColors[1]
        XCTAssertEqual(second.colorName, expectedColor)
    }

    @MainActor
    func testCreateProfilePersists() {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("create-persist-\(UUID().uuidString)")
        let url = tmp.appendingPathComponent("profiles.json")
        let pm1 = ProfileManager(storageURL: url)
        _ = pm1.createProfile(name: "Work")

        // Re-read from disk.
        let pm2 = ProfileManager(storageURL: url)
        XCTAssertEqual(pm2.profiles.count, 2)
        XCTAssertTrue(pm2.profiles.contains { $0.name == "Work" })
    }
}
