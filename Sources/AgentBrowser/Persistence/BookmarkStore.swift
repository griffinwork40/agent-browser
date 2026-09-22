import Foundation
import GRDB

// MARK: - Bookmark

/// A saved URL with optional folder grouping, persisted in the `bookmark` table.
struct Bookmark: Identifiable, Codable, Sendable, Hashable {
    let id: UUID
    let url: URL
    var title: String
    /// Optional folder label for logical grouping (flat, not hierarchical).
    var folderName: String?
    let createdAt: Date

    init(
        id: UUID = UUID(),
        url: URL,
        title: String,
        folderName: String? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.url = url
        self.title = title
        self.folderName = folderName
        self.createdAt = createdAt
    }
}

// MARK: GRDB conformances

extension Bookmark: FetchableRecord, PersistableRecord {
    static let databaseTableName = "bookmark"

    /// Store UUIDs as uppercase text strings to match the `.text` column type
    /// and enable straightforward key-based lookups.
    static func databaseUUIDEncodingStrategy(for column: String) -> DatabaseUUIDEncodingStrategy {
        .uppercaseString
    }

    enum Columns {
        static let id         = Column("id")
        static let url        = Column("url")
        static let title      = Column("title")
        static let folderName = Column("folderName")
        static let createdAt  = Column("createdAt")
    }
}

// MARK: - BookmarkStore

/// Stores bookmarks as rows in a SQLite table, partitioned into named folders.
///
/// Folders are implicit — they exist whenever at least one bookmark carries
/// that `folderName`. Deleting the last bookmark in a folder removes the folder.
actor BookmarkStore {
    private let dbWriter: any DatabaseWriter

    // MARK: - Init

    /// Primary init: supplied by `PersistenceCoordinator` via `DatabaseManager`.
    init(dbWriter: any DatabaseWriter) {
        self.dbWriter = dbWriter
    }

    /// Convenience init for the legacy `PersistenceCoordinator` fallback path.
    ///
    /// Opens a `DatabasePool` for `browser.db` inside `dataDirectory` and runs
    /// the browser migrator.
    init(dataDirectory: URL) {
        do {
            try FileManager.default.createDirectory(
                at: dataDirectory, withIntermediateDirectories: true)
            let pool = try DatabasePool(
                path: dataDirectory.appendingPathComponent("browser.db").path)
            try DatabaseSetup.browserMigrator.migrate(pool)
            self.dbWriter = pool
        } catch {
            fputs("BookmarkStore(dataDirectory:) failed: \(error)\n", stderr)
            let queue = try! DatabaseQueue()
            try! DatabaseSetup.browserMigrator.migrate(queue)
            self.dbWriter = queue
        }
    }

    // MARK: - Write

    /// Creates and persists a new bookmark. Returns the stored value.
    @discardableResult
    func add(url: URL, title: String, folderName: String? = nil) -> Bookmark {
        let bookmark = Bookmark(url: url, title: title, folderName: folderName)
        do {
            try dbWriter.write { db in
                try bookmark.insert(db)
            }
        } catch {
            fputs("BookmarkStore.add: \(error)\n", stderr)
        }
        return bookmark
    }

    /// Removes a bookmark by its stable UUID.
    func remove(id: UUID) {
        do {
            _ = try dbWriter.write { db in
                try Bookmark.deleteOne(db, key: id.uuidString)
            }
        } catch {
            fputs("BookmarkStore.remove: \(error)\n", stderr)
        }
    }

    /// Updates the title of an existing bookmark in-place.
    func updateTitle(_ title: String, for id: UUID) {
        do {
            try dbWriter.write { db in
                try db.execute(
                    sql: "UPDATE bookmark SET title = ? WHERE id = ?",
                    arguments: [title, id.uuidString]
                )
            }
        } catch {
            fputs("BookmarkStore.updateTitle: \(error)\n", stderr)
        }
    }

    /// Moves a bookmark into a folder (or clears its folder when `nil`).
    func setFolder(_ folderName: String?, for id: UUID) {
        do {
            try dbWriter.write { db in
                try db.execute(
                    sql: "UPDATE bookmark SET folderName = ? WHERE id = ?",
                    arguments: [folderName, id.uuidString]
                )
            }
        } catch {
            fputs("BookmarkStore.setFolder: \(error)\n", stderr)
        }
    }

    // MARK: - Read

    /// All stored bookmarks in insertion order.
    func all() -> [Bookmark] {
        (try? dbWriter.read { db in
            try Bookmark.order(Bookmark.Columns.createdAt.asc).fetchAll(db)
        }) ?? []
    }

    /// Bookmarks belonging to `folderName`, in insertion order.
    func bookmarks(inFolder folderName: String) -> [Bookmark] {
        (try? dbWriter.read { db in
            try Bookmark
                .filter(Bookmark.Columns.folderName == folderName)
                .order(Bookmark.Columns.createdAt.asc)
                .fetchAll(db)
        }) ?? []
    }

    /// Sorted list of all folder names that have at least one bookmark.
    func folders() -> [String] {
        let names: [String?] = (try? dbWriter.read { db in
            try Row.fetchAll(db, sql: """
                SELECT DISTINCT folderName
                FROM bookmark
                WHERE folderName IS NOT NULL
                ORDER BY folderName ASC
            """).map { $0["folderName"] }
        }) ?? []
        return names.compactMap { $0 }
    }

    /// Returns `true` if the given URL is already bookmarked.
    func contains(url: URL) -> Bool {
        let urlString = url.absoluteString
        return (try? dbWriter.read { db in
            try Bookmark
                .filter(Bookmark.Columns.url == urlString)
                .fetchCount(db) > 0
        }) ?? false
    }
}
