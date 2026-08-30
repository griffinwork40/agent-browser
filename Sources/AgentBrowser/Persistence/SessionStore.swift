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

    let tabs: [TabSnapshot]
    let selectedTabID: UUID?
    let savedAt: Date
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
