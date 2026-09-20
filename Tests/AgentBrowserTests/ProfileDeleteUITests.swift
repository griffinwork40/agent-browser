// ProfileDeleteUITests.swift
// Tests for ProfileManager.deleteProfile — the backing model for the
// profile rename/delete context menu UI introduced in issue #7.

import Testing
import Foundation
@testable import AgentBrowser

@Suite("ProfileDeleteUI")
struct ProfileDeleteUITests {

    // MARK: - Helpers

    @MainActor
    private func makeProfileManager() -> ProfileManager {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("delete-ui-test-\(UUID().uuidString)")
        return ProfileManager(storageURL: tmp.appendingPathComponent("profiles.json"))
    }

    // MARK: - Delete removes profile

    @Test("deleteProfile removes the target profile")
    @MainActor func deleteProfileRemovesIt() async {
        let pm = makeProfileManager()
        let second = pm.createProfile(name: "Work")
        #expect(pm.profiles.count == 2)

        await pm.deleteProfile(id: second.id)

        #expect(pm.profiles.count == 1)
        #expect(!pm.profiles.contains { $0.id == second.id })
    }

    // MARK: - Last profile is protected

    @Test("deleteProfile won't remove the last profile")
    @MainActor func deleteWontRemoveLastProfile() async {
        let pm = makeProfileManager()
        #expect(pm.profiles.count == 1)
        let onlyID = pm.profiles[0].id

        await pm.deleteProfile(id: onlyID)

        // Guard keeps the sole profile intact.
        #expect(pm.profiles.count == 1)
        #expect(pm.profiles[0].id == onlyID)
    }

    // MARK: - Deleting active profile switches to first remaining

    @Test("deleteProfile switches activeProfileID when active profile is deleted")
    @MainActor func deleteActiveSwitchesToFirst() async {
        let pm = makeProfileManager()
        let second = pm.createProfile(name: "Work")

        // Make "Work" active.
        pm.switchTo(profileID: second.id)
        #expect(pm.activeProfileID == second.id)

        // Delete the active profile.
        await pm.deleteProfile(id: second.id)

        // Active should have moved to the first (and only) remaining profile.
        #expect(pm.activeProfileID != second.id)
        #expect(pm.activeProfileID == pm.profiles[0].id)
    }

    // MARK: - Deleting non-active profile keeps active unchanged

    @Test("deleteProfile keeps activeProfileID when a non-active profile is deleted")
    @MainActor func deleteNonActiveKeepsActive() async {
        let pm = makeProfileManager()
        let second = pm.createProfile(name: "Work")
        let defaultID = pm.profiles[0].id

        // Default is active; delete "Work".
        await pm.deleteProfile(id: second.id)

        #expect(pm.activeProfileID == defaultID)
    }

    // MARK: - Deleting persists to disk

    @Test("deleteProfile persists the removal to disk")
    @MainActor func deletePersists() async {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("delete-persist-\(UUID().uuidString)")
        let url = tmp.appendingPathComponent("profiles.json")

        let pm1 = ProfileManager(storageURL: url)
        let second = pm1.createProfile(name: "Work")
        await pm1.deleteProfile(id: second.id)

        // Re-read from disk.
        let pm2 = ProfileManager(storageURL: url)
        #expect(pm2.profiles.count == 1)
        #expect(!pm2.profiles.contains { $0.id == second.id })
    }
}
