import Foundation
import WebKit
import Observation

/// Manages browser profiles: CRUD, active profile tracking, and per-profile
/// WKWebViewConfiguration / WKWebsiteDataStore factories.
///
/// Each profile gets its own WKWebsiteDataStore (cookies, cache, local storage)
/// via `WKWebsiteDataStore(forIdentifier:)`, so profiles are fully isolated.
@Observable @MainActor
final class ProfileManager {
    private(set) var profiles: [ProfileRecord] = []
    private(set) var activeProfileID: UUID

    /// Persisted to Application Support/AgentBrowser/profiles.json
    private let storageURL: URL

    /// Cached data stores — created lazily, reused across calls.
    private var dataStores: [UUID: WKWebsiteDataStore] = [:]

    /// Production initialiser. Persists to Application Support/AgentBrowser/profiles.json.
    convenience init() {
        let appSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("AgentBrowser", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.init(storageURL: dir.appendingPathComponent("profiles.json"))
    }

    /// Designated initialiser. Accepts an explicit storage URL so tests can
    /// supply a temp-directory path and avoid sharing on-disk state.
    init(storageURL: URL) {
        self.storageURL = storageURL
        try? FileManager.default.createDirectory(at: storageURL.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)

        // Load saved profiles or seed with the default.
        if let data = try? Data(contentsOf: storageURL),
           let saved = try? JSONDecoder().decode([ProfileRecord].self, from: data),
           !saved.isEmpty {
            profiles = saved
            activeProfileID = saved[0].id
        } else {
            let defaultProfile = ProfileRecord(name: "Default", colorName: "blue")
            profiles = [defaultProfile]
            activeProfileID = defaultProfile.id
            save()
        }
    }

    // MARK: - Accessors

    var activeProfile: ProfileRecord? {
        profiles.first { $0.id == activeProfileID }
    }

    // MARK: - Data Store / Configuration

    func dataStore(for profileID: UUID) -> WKWebsiteDataStore {
        if let cached = dataStores[profileID] { return cached }
        let store = WKWebsiteDataStore(forIdentifier: profileID)
        dataStores[profileID] = store
        return store
    }

    func makeConfiguration(for profileID: UUID) -> WKWebViewConfiguration {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = dataStore(for: profileID)
        config.preferences.isElementFullscreenEnabled = true
        config.mediaTypesRequiringUserActionForPlayback = []
        config.allowsAirPlayForMediaPlayback = true

        // Relevance helpers must be injected first so AB._scoreElement etc. are
        // available when the main bridge initialises element collection.
        if let relevanceJS = loadScript(named: "automation-bridge-relevance") {
            let relevanceScript = WKUserScript(
                source: relevanceJS,
                injectionTime: .atDocumentEnd,
                forMainFrameOnly: true,
                in: .world(name: "AgentBridge")
            )
            config.userContentController.addUserScript(relevanceScript)
        }
        if let bridgeJS = loadAutomationBridge() {
            let script = WKUserScript(
                source: bridgeJS,
                injectionTime: .atDocumentEnd,
                forMainFrameOnly: true,
                in: .world(name: "AgentBridge")
            )
            config.userContentController.addUserScript(script)
        }
        return config
    }

    // MARK: - CRUD

    @discardableResult
    func createProfile(name: String) -> ProfileRecord {
        let colorIndex = profiles.count % ProfileRecord.defaultColors.count
        let color = ProfileRecord.defaultColors[colorIndex]
        let profile = ProfileRecord(name: name, colorName: color)
        profiles.append(profile)
        save()
        return profile
    }

    func switchTo(profileID: UUID) {
        guard profiles.contains(where: { $0.id == profileID }) else { return }
        activeProfileID = profileID
        save()
    }

    func updateProfile(_ updated: ProfileRecord) {
        guard let index = profiles.firstIndex(where: { $0.id == updated.id }) else { return }
        profiles[index] = updated
        save()
    }

    // MARK: - Rename

    /// Rename a profile, enforcing non-empty and unique names.
    ///
    /// - Returns: `true` on success, `false` if validation fails.
    @discardableResult
    func renameProfile(id: UUID, to newName: String) -> Bool {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        // Duplicate-name check: allow the same profile to keep its name.
        let isDuplicate = profiles.contains { $0.name == trimmed && $0.id != id }
        guard !isDuplicate else { return false }
        guard var profile = profiles.first(where: { $0.id == id }) else { return false }
        profile.name = trimmed
        updateProfile(profile)
        return true
    }

    // MARK: - Validation

    /// Returns `true` when `name` is available (non-empty, not taken by another profile).
    func isNameAvailable(_ name: String, excludingID: UUID? = nil) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return !profiles.contains { $0.name == trimmed && $0.id != excludingID }
    }

    func deleteProfile(id: UUID) async {
        guard profiles.count > 1 else { return }  // always keep at least one
        profiles.removeAll { $0.id == id }
        dataStores.removeValue(forKey: id)
        if activeProfileID == id {
            activeProfileID = profiles[0].id
        }
        save()
        try? await WKWebsiteDataStore.remove(forIdentifier: id)
    }

    // MARK: - Persistence

    private func save() {
        guard let data = try? JSONEncoder().encode(profiles) else { return }
        try? data.write(to: storageURL, options: .atomic)
    }

    // MARK: - Automation Bridge

    /// Load a named JS file from UserScripts (bundle or dev fallback).
    private func loadScript(named name: String) -> String? {
        if let url = Bundle.module.url(forResource: name, withExtension: "js",
                                        subdirectory: "UserScripts") {
            return try? String(contentsOf: url, encoding: .utf8)
        }
        if let url = Bundle.main.url(forResource: name, withExtension: "js") {
            return try? String(contentsOf: url, encoding: .utf8)
        }
#if DEBUG
        let devPaths = [
            "Sources/AgentBrowser/WebKit/UserScripts/\(name).js",
            "../Sources/AgentBrowser/WebKit/UserScripts/\(name).js",
        ]
        for path in devPaths {
            if FileManager.default.fileExists(atPath: path) {
                return try? String(contentsOfFile: path, encoding: .utf8)
            }
        }
#endif
        print("[ProfileManager] Warning: \(name).js not found")
        return nil
    }

    private func loadAutomationBridge() -> String? {
        loadScript(named: "automation-bridge")
    }
}
