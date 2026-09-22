import Foundation
import GRDB

// MARK: - HistoryEntry

/// A single browsing history record persisted in the `historyEntry` table.
///
/// The `rowid` field is the SQLite auto-increment key used by the FTS5
/// external-content index; it is `nil` before the first insert.
/// The `id` column holds the stable UUID identity used by all callers.
struct HistoryEntry: Identifiable, Codable, Sendable {
    /// Auto-increment primary key used by FTS5 content sync. Nil before insert.
    var rowid: Int64?
    /// Stable UUID identity for the entry.
    let id: UUID
    /// Visited URL — stored as its absolute-string representation via Codable.
    let url: URL
    /// Page title at time of visit.
    var title: String
    /// Wall-clock time of the visit.
    let visitedAt: Date

    init(
        id: UUID = UUID(),
        url: URL,
        title: String,
        visitedAt: Date = Date()
    ) {
        self.rowid = nil
        self.id = id
        self.url = url
        self.title = title
        self.visitedAt = visitedAt
    }
}

// MARK: GRDB conformances

extension HistoryEntry: FetchableRecord, PersistableRecord {
    static let databaseTableName = "historyEntry"

    /// Store UUIDs as uppercase text strings to match the `.text` column type.
    static func databaseUUIDEncodingStrategy(for column: String) -> DatabaseUUIDEncodingStrategy {
        .uppercaseString
    }

    /// Tell GRDB which column carries the auto-increment rowid.
    static var databaseSelection: [any SQLSelectable] {
        [AllColumns()]
    }

    mutating func didInsert(_ inserted: InsertionSuccess) {
        rowid = inserted.rowID
    }

    /// Named columns for type-safe query construction.
    enum Columns {
        static let rowid    = Column("rowid")
        static let id       = Column("id")
        static let url      = Column("url")
        static let title    = Column("title")
        static let visitedAt = Column("visitedAt")
    }
}

// MARK: - HistoryStore

/// Persists browsing history in a GRDB SQLite database with FTS5 full-text search.
///
/// Actor isolation protects concurrent call sites; GRDB's pool manages its own
/// internal concurrency for reads and writes.
actor HistoryStore {
    private let dbWriter: any DatabaseWriter
    private static let maxEntries = 10_000

    // MARK: - Init

    /// Primary init: supplied by `PersistenceCoordinator` via `DatabaseManager`.
    init(dbWriter: any DatabaseWriter) {
        self.dbWriter = dbWriter
    }

    /// Convenience init for the legacy `PersistenceCoordinator` fallback path.
    ///
    /// Opens a `DatabasePool` for `history.db` inside `dataDirectory` and runs
    /// the history migrator (including FTS5 setup).
    init(dataDirectory: URL) {
        do {
            try FileManager.default.createDirectory(
                at: dataDirectory, withIntermediateDirectories: true)
            let pool = try DatabasePool(
                path: dataDirectory.appendingPathComponent("history.db").path)
            try DatabaseSetup.historyMigrator.migrate(pool)
            self.dbWriter = pool
        } catch {
            fputs("HistoryStore(dataDirectory:) failed: \(error)\n", stderr)
            let queue = try! DatabaseQueue()
            try! DatabaseSetup.historyMigrator.migrate(queue)
            self.dbWriter = queue
        }
    }

    // MARK: - Write

    /// Records a new page visit. Trims the table to `maxEntries` if needed.
    func addEntry(url: URL, title: String) {
        let entry = HistoryEntry(url: url, title: title)
        do {
            _ = try dbWriter.write { db in
                var mutable = entry  // var required by MutablePersistableRecord.insert(inout)
                try mutable.insert(db)

                // Keep only the most recent maxEntries rows.
                let count = try HistoryEntry.fetchCount(db)
                if count > Self.maxEntries {
                    let excess = count - Self.maxEntries
                    try db.execute(
                        sql: """
                        DELETE FROM historyEntry WHERE rowid IN (
                            SELECT rowid FROM historyEntry
                            ORDER BY visitedAt ASC LIMIT ?
                        )
                        """,
                        arguments: [excess]
                    )
                }
            }
        } catch {
            fputs("HistoryStore.addEntry: \(error)\n", stderr)
        }
    }

    /// Deletes all history rows (FTS index is cleared via the delete trigger).
    func clearAll() {
        do {
            _ = try dbWriter.write { db in
                try HistoryEntry.deleteAll(db)
            }
        } catch {
            fputs("HistoryStore.clearAll: \(error)\n", stderr)
        }
    }

    // MARK: - Read

    /// Full-text search over title and URL using FTS5.
    /// Returns up to 50 results ordered by recency.
    func search(query: String) -> [HistoryEntry] {
        let escaped = fts5Escaped(query)
        guard !escaped.isEmpty else { return [] }
        do {
            return try dbWriter.read { db in
                // Append wildcard for prefix matching on the last token.
                let pattern = escaped + "*"
                let sql = """
                    SELECT historyEntry.*
                    FROM historyEntry
                    JOIN historyFTS ON historyFTS.rowid = historyEntry.rowid
                    WHERE historyFTS MATCH ?
                    ORDER BY historyEntry.visitedAt DESC
                    LIMIT 50
                    """
                return try HistoryEntry.fetchAll(db, sql: sql, arguments: [pattern])
            }
        } catch {
            fputs("HistoryStore.search: \(error)\n", stderr)
            return []
        }
    }

    /// Returns the most recent entries, up to `limit`.
    func recentEntries(limit: Int = 50) -> [HistoryEntry] {
        do {
            return try dbWriter.read { db in
                try HistoryEntry
                    .order(HistoryEntry.Columns.visitedAt.desc)
                    .limit(limit)
                    .fetchAll(db)
            }
        } catch {
            fputs("HistoryStore.recentEntries: \(error)\n", stderr)
            return []
        }
    }

    // MARK: - Private helpers

    /// Produces a safe FTS5 query string.
    ///
    /// Each whitespace-separated token is double-quoted to prevent FTS5 from
    /// interpreting internal punctuation as operators. The caller appends `*`
    /// after the escaped string for prefix matching.
    private func fts5Escaped(_ query: String) -> String {
        query
            .replacingOccurrences(of: "\"", with: "")   // strip embedded quotes
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: " ")
            .filter { !$0.isEmpty }
            .map { "\"\($0)\"" }
            .joined(separator: " ")
    }
}
