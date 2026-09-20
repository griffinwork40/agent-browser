import Testing
import Foundation
@testable import AgentBrowser

// MARK: - ExtensionInfo tests

@Suite("ExtensionInfo")
struct ExtensionInfoTests {

    @Test("Default values are set correctly")
    func defaultValues() {
        let url = URL(fileURLWithPath: "/tmp/my-extension")
        let info = ExtensionInfo(
            id: "com.example.ext",
            name: "My Extension",
            version: "1.2.3",
            isEnabled: true,
            extensionURL: url
        )
        #expect(info.id == "com.example.ext")
        #expect(info.name == "My Extension")
        #expect(info.version == "1.2.3")
        #expect(info.isEnabled == true)
        #expect(info.extensionURL == url)
    }

    @Test("isEnabled is mutable")
    func isEnabledMutable() {
        var info = ExtensionInfo(
            id: "x",
            name: "X",
            version: "1.0",
            isEnabled: true,
            extensionURL: URL(fileURLWithPath: "/tmp")
        )
        info.isEnabled = false
        #expect(info.isEnabled == false)
    }

    @Test("Equatable: same values are equal")
    func equalityEqual() {
        let url = URL(fileURLWithPath: "/tmp/ext")
        let a = ExtensionInfo(id: "id", name: "n", version: "1", isEnabled: true, extensionURL: url)
        let b = ExtensionInfo(id: "id", name: "n", version: "1", isEnabled: true, extensionURL: url)
        #expect(a == b)
    }

    @Test("Equatable: differing IDs are not equal")
    func equalityDifferentID() {
        let url = URL(fileURLWithPath: "/tmp/ext")
        let a = ExtensionInfo(id: "a", name: "n", version: "1", isEnabled: true, extensionURL: url)
        let b = ExtensionInfo(id: "b", name: "n", version: "1", isEnabled: true, extensionURL: url)
        #expect(a != b)
    }

    @Test("Identifiable uses id property")
    func identifiable() {
        let info = ExtensionInfo(
            id: "my-id",
            name: "n",
            version: "1",
            isEnabled: true,
            extensionURL: URL(fileURLWithPath: "/tmp")
        )
        #expect(info.id == "my-id")
    }
}

// MARK: - ExtensionManager tests

@Suite("ExtensionManager")
struct ExtensionManagerTests {

    @Test("Extensions directory is created on init")
    @MainActor func directoryCreatedOnInit() {
        let manager = ExtensionManager()
        let exists = FileManager.default.fileExists(
            atPath: manager.extensionsDirectory.path,
            isDirectory: nil
        )
        #expect(exists == true)
    }

    @Test("Starts with no loaded extensions")
    @MainActor func startsEmpty() {
        let manager = ExtensionManager()
        #expect(manager.loadedExtensions.isEmpty)
    }

    @Test("unloadExtension with unknown id is a no-op")
    @MainActor func unloadUnknownIsNoOp() {
        let manager = ExtensionManager()
        // Should not crash
        manager.unloadExtension(id: "does-not-exist")
        #expect(manager.loadedExtensions.isEmpty)
    }

    @Test("setEnabled on unknown id is a no-op")
    @MainActor func setEnabledUnknownIsNoOp() {
        let manager = ExtensionManager()
        // Should not crash
        manager.setEnabled(true, forExtensionWithID: "ghost")
        #expect(manager.loadedExtensions.isEmpty)
    }

    @Test("extensionsDirectory is inside Application Support/AgentBrowser/Extensions")
    @MainActor func directoryPath() {
        let manager = ExtensionManager()
        let path = manager.extensionsDirectory.path
        #expect(path.contains("AgentBrowser"))
        #expect(path.contains("Extensions"))
    }

    // MARK: - Enable/disable round-trip via injected state

    @Test("setEnabled toggles isEnabled in loadedExtensions")
    @MainActor func enableDisableToggle() async throws {
        guard #available(macOS 15.4, *) else {
            // Below 15.4 the manager is a no-op; nothing to test.
            return
        }

        let manager = ExtensionManager()
        // Manually inject a fake ExtensionInfo to avoid real bundle loading.
        injectFakeExtension(into: manager, id: "test.ext", enabled: true)

        #expect(manager.loadedExtensions.first?.isEnabled == true)

        manager.setEnabled(false, forExtensionWithID: "test.ext")
        #expect(manager.loadedExtensions.first?.isEnabled == false)

        manager.setEnabled(true, forExtensionWithID: "test.ext")
        #expect(manager.loadedExtensions.first?.isEnabled == true)
    }

    @Test("setEnabled with same value is idempotent")
    @MainActor func setEnabledIdempotent() async throws {
        guard #available(macOS 15.4, *) else { return }

        let manager = ExtensionManager()
        injectFakeExtension(into: manager, id: "test.ext2", enabled: true)

        manager.setEnabled(true, forExtensionWithID: "test.ext2")
        #expect(manager.loadedExtensions.first?.isEnabled == true)
        manager.setEnabled(true, forExtensionWithID: "test.ext2")
        #expect(manager.loadedExtensions.first?.isEnabled == true)
    }

    @Test("unloadExtension removes info from loadedExtensions")
    @MainActor func unloadRemovesFromList() async throws {
        guard #available(macOS 15.4, *) else { return }

        let manager = ExtensionManager()
        injectFakeExtension(into: manager, id: "removable", enabled: true)
        #expect(manager.loadedExtensions.count == 1)

        manager.unloadExtension(id: "removable")
        #expect(manager.loadedExtensions.isEmpty)
    }

    @Test("loadExtension on macOS < 15.4 throws unavailableOnThisOSVersion")
    @MainActor func loadThrowsOnOldOS() async {
        // Only testable if running on macOS 14; on 15.4+ the error won't be thrown.
        guard #unavailable(macOS 15.4) else { return }

        let manager = ExtensionManager()
        let url = URL(fileURLWithPath: "/tmp/fake-ext")
        do {
            try await manager.loadExtension(from: url)
            Issue.record("Expected throw on macOS < 15.4")
        } catch ExtensionManagerError.unavailableOnThisOSVersion {
            // Expected
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }
}

// MARK: - Test helpers

/// Inject an `ExtensionInfo` directly into the manager's published array so
/// enable/disable tests don't need a real extension bundle on disk.
@MainActor
private func injectFakeExtension(into manager: ExtensionManager, id: String, enabled: Bool) {
    let info = ExtensionInfo(
        id: id,
        name: "Fake Extension",
        version: "0.1",
        isEnabled: enabled,
        extensionURL: URL(fileURLWithPath: "/tmp/\(id)")
    )
    manager._testInject(info)
}
