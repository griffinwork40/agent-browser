import Foundation

// MARK: - SessionSnapshot

/// A point-in-time capture of every open tab and which tab was active.
struct SessionSnapshot: Codable, Sendable {

    // MARK: TabSnapshot

    /// Minimal per-tab state needed to recreate a tab on next launch.
    struct TabSnapshot: Codable, Sendable {
        /// Stable tab identity — preserved across restore so provenance links hold.
        let id: UUID
        /// Last-committed URL, stored as a plain String because `URL` Codable
        /// encoding round-trips fine but nil is more expressive as an Optional String.
        let urlString: String?
        /// Last-known page title (may be empty for new/blank tabs).
        let title: String
        /// Who created this tab originally (human or agent).
        let provenance: TabProvenance
        /// Which profile this tab belongs to. Defaults to a new UUID for snapshots
        /// written before multi-profile support; restored tabs will use the active profile.
        let profileID: UUID

        init(
            id: UUID,
            urlString: String?,
            title: String,
            provenance: TabProvenance,
            profileID: UUID = UUID()
        ) {
            self.id = id
            self.urlString = urlString
            self.title = title
            self.provenance = provenance
            self.profileID = profileID
        }

        /// Convenience accessor that re-hydrates the URL.
        var url: URL? {
            urlString.flatMap(URL.init(string:))
        }
    }

    // MARK: Snapshot root

    var tabs: [TabSnapshot]
    var selectedTabID: UUID?
    var savedAt: Date

    /// Per-profile workspace snapshots. Added in v2; absent in legacy files.
    /// Keyed by profile UUID string (Codable requires String keys in Dicts).
    var workspaces: [String: ProfileWorkspace]?

    // MARK: - Profile workspace helpers

    /// Returns the workspace for `profileID`, or nil if none has been saved.
    func workspace(for profileID: UUID) -> ProfileWorkspace? {
        workspaces?[profileID.uuidString]
    }

    /// Returns all workspaces built from the legacy flat `tabs` array,
    /// grouped by each tab's `profileID`. Used when `workspaces` is absent.
    func migratedWorkspaces(activeProfileID: UUID) -> [UUID: ProfileWorkspace] {
        var grouped: [UUID: [ProfileWorkspace.TabEntry]] = [:]
        for tab in tabs {
            let entry = ProfileWorkspace.TabEntry(tab)
            grouped[tab.profileID, default: []].append(entry)
        }
        return grouped.mapValues { entries in
            let pid = entries.first!.profileID
            let selected: UUID? = (pid == activeProfileID) ? selectedTabID : nil
            return ProfileWorkspace(profileID: pid, tabs: entries, selectedTabID: selected)
        }
    }
}

// MARK: - SessionStore

/// Persists and restores a single browser session as a JSON file.
///
/// There is intentionally only one session slot (the last-used session).
/// Named session history can be layered on top later.
actor SessionStore {
    private let fileURL: URL

    init(dataDirectory: URL) {
        self.fileURL = dataDirectory.appendingPathComponent("session.json")
    }

    // MARK: - Write

    /// Atomically writes the current tab set to disk.
    func save(tabs: [SessionSnapshot.TabSnapshot], selectedTabID: UUID?) {
        let snapshot = SessionSnapshot(
            tabs: tabs,
            selectedTabID: selectedTabID,
            savedAt: Date()
        )
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    /// Atomically writes per-profile workspaces to disk alongside the legacy flat array.
    ///
    /// The legacy `tabs` + `selectedTabID` fields are populated from `activeWorkspace`
    /// so that any reader without workspace support still sees a usable session.
    ///
    /// - Returns: `true` if the write succeeded; `false` if encode or write failed.
    ///   Callers on the quit path should treat `false` as a write failure and may
    ///   log or surface the error before allowing termination to proceed.
    @discardableResult
    func saveWorkspaces(
        _ workspaces: [UUID: ProfileWorkspace],
        activeProfileID: UUID
    ) -> Bool {
        let active = workspaces[activeProfileID]
        let legacyTabs: [SessionSnapshot.TabSnapshot] = (active?.tabs ?? [])
            .map(\.asTabSnapshot)
        let legacySelected = active?.selectedTabID

        // String-keyed dict for Codable conformance.
        let coded = Dictionary(uniqueKeysWithValues:
            workspaces.map { (k, v) in (k.uuidString, v) }
        )
        var snapshot = SessionSnapshot(
            tabs: legacyTabs,
            selectedTabID: legacySelected,
            savedAt: Date()
        )
        snapshot.workspaces = coded
        guard let data = try? JSONEncoder().encode(snapshot) else { return false }
        do {
            try data.write(to: fileURL, options: .atomic)
            return true
        } catch {
            // Surface write failures via stderr so crash logs and test assertions
            // can detect them. Silent swallowing was the prior behaviour; callers
            // that do not check the return value are unaffected.
            fputs("SessionStore: workspace write failed: \(error)\n", stderr)
            return false
        }
    }

    /// Deletes the saved session file (e.g. after a fresh-start launch).
    func clear() {
        try? FileManager.default.removeItem(at: fileURL)
    }

    // MARK: - Read

    /// Returns the most recently saved snapshot, or nil if none exists.
    func restore() -> SessionSnapshot? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(SessionSnapshot.self, from: data)
    }
}
