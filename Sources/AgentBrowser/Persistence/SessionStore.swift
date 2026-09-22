import Foundation
import GRDB

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
        return Dictionary(uniqueKeysWithValues: grouped.map { (pid, entries) in
            let selected: UUID? = (pid == activeProfileID) ? selectedTabID : nil
            return (pid, ProfileWorkspace(profileID: pid, tabs: entries, selectedTabID: selected))
        })
    }
}

// MARK: - SessionStore

/// Persists and restores a single browser session.
///
/// The entire `SessionSnapshot` is JSON-encoded and stored as a single row in the
/// `browserSession` table (key = "current"). This approach preserves the existing
/// Codable snapshot format unchanged — callers and existing tests need no changes.
///
/// When the backing database cannot be opened (e.g. the directory does not exist),
/// `dbWriter` is `nil` and every write returns `false`, matching the error
/// behaviour of the previous JSON-based implementation.
actor SessionStore {
    /// Non-nil for a healthy store; nil when the database could not be opened.
    private let dbWriter: (any DatabaseWriter)?

    // MARK: - Init

    /// Primary init: supplied by `PersistenceCoordinator` via `DatabaseManager`.
    init(dbWriter: any DatabaseWriter) {
        self.dbWriter = dbWriter
    }

    /// Convenience init for tests and the legacy `PersistenceCoordinator.setUp()` path.
    ///
    /// Opens a `DatabasePool` for `browser.db` inside `dataDirectory` and runs the
    /// browser migrator.  When `dataDirectory` does not exist (or is not writable),
    /// the `DatabasePool` open fails and `dbWriter` is stored as `nil`; subsequent
    /// writes return `false`, preserving the same observable behaviour as the
    /// previous JSON-based store on an unwritable path.
    init(dataDirectory: URL) {
        // Note: we do NOT call createDirectory here so that a non-existent
        // directory causes DatabasePool to fail — which lets saveWorkspaces
        // return `false`, matching the contract expected by existing tests.
        do {
            let pool = try DatabasePool(
                path: dataDirectory.appendingPathComponent("browser.db").path)
            try DatabaseSetup.browserMigrator.migrate(pool)
            self.dbWriter = pool
        } catch {
            fputs("SessionStore(dataDirectory:) could not open DB: \(error)\n", stderr)
            self.dbWriter = nil
        }
    }

    // MARK: - Write

    /// Atomically writes the current tab set to the database.
    func save(tabs: [SessionSnapshot.TabSnapshot], selectedTabID: UUID?) {
        let snapshot = SessionSnapshot(
            tabs: tabs,
            selectedTabID: selectedTabID,
            savedAt: Date()
        )
        guard let jsonString = encode(snapshot), let db = dbWriter else { return }
        do {
            try db.write { connection in
                try connection.execute(
                    sql: """
                    INSERT OR REPLACE INTO browserSession (key, snapshotJSON, savedAt)
                    VALUES ('current', ?, ?)
                    """,
                    arguments: [jsonString, Date()]
                )
            }
        } catch {
            fputs("SessionStore.save: \(error)\n", stderr)
        }
    }

    /// Atomically writes per-profile workspaces alongside the backward-compatible
    /// legacy flat `tabs` array (populated from the active profile's workspace).
    ///
    /// - Returns: `true` if the write succeeded; `false` on encode or DB error.
    @discardableResult
    func saveWorkspaces(
        _ workspaces: [UUID: ProfileWorkspace],
        activeProfileID: UUID
    ) -> Bool {
        guard let db = dbWriter else { return false }

        let active = workspaces[activeProfileID]
        let legacyTabs: [SessionSnapshot.TabSnapshot] = (active?.tabs ?? [])
            .map(\.asTabSnapshot)
        let legacySelected = active?.selectedTabID

        let coded = Dictionary(
            uniqueKeysWithValues: workspaces.map { (k, v) in (k.uuidString, v) }
        )
        var snapshot = SessionSnapshot(
            tabs: legacyTabs,
            selectedTabID: legacySelected,
            savedAt: Date()
        )
        snapshot.workspaces = coded

        guard let jsonString = encode(snapshot) else { return false }
        do {
            try db.write { connection in
                try connection.execute(
                    sql: """
                    INSERT OR REPLACE INTO browserSession (key, snapshotJSON, savedAt)
                    VALUES ('current', ?, ?)
                    """,
                    arguments: [jsonString, Date()]
                )
            }
            return true
        } catch {
            fputs("SessionStore: workspace write failed: \(error)\n", stderr)
            return false
        }
    }

    /// Deletes the saved session row (e.g. after a fresh-start launch).
    func clear() {
        guard let db = dbWriter else { return }
        do {
            try db.write { connection in
                try connection.execute(
                    sql: "DELETE FROM browserSession WHERE key = 'current'"
                )
            }
        } catch {
            fputs("SessionStore.clear: \(error)\n", stderr)
        }
    }

    // MARK: - Read

    /// Returns the most recently saved snapshot, or nil if none exists.
    func restore() -> SessionSnapshot? {
        guard let db = dbWriter else { return nil }
        do {
            return try db.read { connection in
                guard let row = try Row.fetchOne(
                    connection,
                    sql: "SELECT snapshotJSON FROM browserSession WHERE key = 'current'"
                ) else { return nil }
                let jsonString: String = row["snapshotJSON"]
                guard let data = jsonString.data(using: .utf8) else { return nil }
                return try JSONDecoder().decode(SessionSnapshot.self, from: data)
            }
        } catch {
            fputs("SessionStore.restore: \(error)\n", stderr)
            return nil
        }
    }

    // MARK: - Private helpers

    private func encode(_ snapshot: SessionSnapshot) -> String? {
        guard let data = try? JSONEncoder().encode(snapshot),
              let str = String(data: data, encoding: .utf8) else {
            fputs("SessionStore: JSON encode failed\n", stderr)
            return nil
        }
        return str
    }
}
