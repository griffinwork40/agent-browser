import XCTest
import GRDB
@testable import AgentBrowser

// MARK: - GRDBPersistenceTests
//
// Covers HistoryStore, BookmarkStore, and the DatabaseManager in-memory path.
// All tests use DatabaseManager.makeInMemory() for a clean, fast, isolated DB.
//
// Sessions-related GRDB coverage is handled by the existing
// SessionStorePersistenceTests, which exercise the DatabasePool path via
// SessionStore(dataDirectory:).

final class GRDBPersistenceTests: XCTestCase {

    // MARK: - Helpers

    /// Fresh in-memory DatabaseManager for a single test.
    private func makeDB() throws -> DatabaseManager {
        try DatabaseManager.makeInMemory()
    }

    // MARK: - HistoryStore: basic CRUD

    func testHistory_addAndRetrieve() async throws {
        let db = try makeDB()
        let store = HistoryStore(dbWriter: db.historyWriter)

        let url = URL(string: "https://example.com")!
        await store.addEntry(url: url, title: "Example")

        let recent = await store.recentEntries(limit: 10)
        XCTAssertEqual(recent.count, 1)
        XCTAssertEqual(recent.first?.url, url)
        XCTAssertEqual(recent.first?.title, "Example")
    }

    func testHistory_recentEntriesOrderedByRecency() async throws {
        let db = try makeDB()
        let store = HistoryStore(dbWriter: db.historyWriter)

        let urls = [
            URL(string: "https://first.example")!,
            URL(string: "https://second.example")!,
            URL(string: "https://third.example")!,
        ]
        for url in urls {
            await store.addEntry(url: url, title: url.host!)
        }

        let recent = await store.recentEntries(limit: 5)
        // Most recently inserted comes first.
        XCTAssertEqual(recent.first?.url, urls.last)
        XCTAssertEqual(recent.count, 3)
    }

    func testHistory_clearAll() async throws {
        let db = try makeDB()
        let store = HistoryStore(dbWriter: db.historyWriter)

        await store.addEntry(url: URL(string: "https://a.com")!, title: "A")
        await store.addEntry(url: URL(string: "https://b.com")!, title: "B")
        await store.clearAll()

        let recent = await store.recentEntries(limit: 10)
        XCTAssertTrue(recent.isEmpty, "clearAll must remove all history entries")
    }

    // MARK: - HistoryStore: FTS5 search

    func testHistory_ftsSearch_findsTitle() async throws {
        let db = try makeDB()
        let store = HistoryStore(dbWriter: db.historyWriter)

        await store.addEntry(url: URL(string: "https://swift.org")!, title: "Swift Programming Language")
        await store.addEntry(url: URL(string: "https://python.org")!, title: "Python Programming Language")
        await store.addEntry(url: URL(string: "https://rust-lang.org")!, title: "Rust Programming Language")

        let results = await store.search(query: "Swift")
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.title, "Swift Programming Language")
    }

    func testHistory_ftsSearch_findsURL() async throws {
        let db = try makeDB()
        let store = HistoryStore(dbWriter: db.historyWriter)

        await store.addEntry(url: URL(string: "https://github.com/groue/GRDB.swift")!, title: "GRDB")
        await store.addEntry(url: URL(string: "https://swift.org")!, title: "Swift")

        let results = await store.search(query: "groue")
        XCTAssertEqual(results.count, 1)
        XCTAssertTrue(results.first?.url.absoluteString.contains("groue") == true)
    }

    func testHistory_ftsSearch_prefixMatch() async throws {
        let db = try makeDB()
        let store = HistoryStore(dbWriter: db.historyWriter)

        await store.addEntry(url: URL(string: "https://apple.com/developer")!, title: "Apple Developer Documentation")
        await store.addEntry(url: URL(string: "https://applause.com")!, title: "Applause")

        let results = await store.search(query: "Apple")
        XCTAssertFalse(results.isEmpty, "Prefix search must match entries whose title starts with 'Apple'")
    }

    func testHistory_ftsSearch_emptyQueryReturnsEmpty() async throws {
        let db = try makeDB()
        let store = HistoryStore(dbWriter: db.historyWriter)

        await store.addEntry(url: URL(string: "https://example.com")!, title: "Example")

        let results = await store.search(query: "")
        XCTAssertTrue(results.isEmpty, "Empty query must return an empty result set")
    }

    func testHistory_ftsSearch_noMatchReturnsEmpty() async throws {
        let db = try makeDB()
        let store = HistoryStore(dbWriter: db.historyWriter)

        await store.addEntry(url: URL(string: "https://example.com")!, title: "Example")

        let results = await store.search(query: "zzznomatch")
        XCTAssertTrue(results.isEmpty, "Non-matching query must return an empty result set")
    }

    func testHistory_ftsSearch_multiTermQuery() async throws {
        let db = try makeDB()
        let store = HistoryStore(dbWriter: db.historyWriter)

        await store.addEntry(url: URL(string: "https://swift.org")!, title: "Swift Programming")
        await store.addEntry(url: URL(string: "https://other.com")!, title: "Swift Other")

        // Both words present in Swift Programming.
        let results = await store.search(query: "Swift Programming")
        XCTAssertEqual(results.count, 1,
            "Multi-term search must match only entries containing all terms")
        XCTAssertEqual(results.first?.title, "Swift Programming")
    }

    func testHistory_ftsSearch_survivesFTS5SpecialChars() async throws {
        let db = try makeDB()
        let store = HistoryStore(dbWriter: db.historyWriter)

        await store.addEntry(url: URL(string: "https://example.com")!, title: "Example Page")

        // These characters are FTS5 operators — they must not cause a crash.
        let dangerousInputs = ["\"quoted\"", "foo*bar", "foo OR bar", "-exclude", "AND"]
        for input in dangerousInputs {
            let results = await store.search(query: input)
            // Result count is secondary; the call must not throw or crash.
            _ = results
        }
    }

    // MARK: - BookmarkStore: basic CRUD

    func testBookmark_addAndRetrieve() async throws {
        let db = try makeDB()
        let store = BookmarkStore(dbWriter: db.browserWriter)

        let url = URL(string: "https://swift.org")!
        let bookmark = await store.add(url: url, title: "Swift", folderName: nil)

        let all = await store.all()
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all.first?.id, bookmark.id)
        XCTAssertEqual(all.first?.url, url)
        XCTAssertEqual(all.first?.title, "Swift")
    }

    func testBookmark_remove() async throws {
        let db = try makeDB()
        let store = BookmarkStore(dbWriter: db.browserWriter)

        let b1 = await store.add(url: URL(string: "https://a.com")!, title: "A")
        let b2 = await store.add(url: URL(string: "https://b.com")!, title: "B")

        await store.remove(id: b1.id)

        let all = await store.all()
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all.first?.id, b2.id)
    }

    func testBookmark_updateTitle() async throws {
        let db = try makeDB()
        let store = BookmarkStore(dbWriter: db.browserWriter)

        let b = await store.add(url: URL(string: "https://example.com")!, title: "Old")
        await store.updateTitle("New", for: b.id)

        let all = await store.all()
        XCTAssertEqual(all.first?.title, "New")
    }

    func testBookmark_setFolder() async throws {
        let db = try makeDB()
        let store = BookmarkStore(dbWriter: db.browserWriter)

        let b = await store.add(url: URL(string: "https://example.com")!, title: "Example")
        await store.setFolder("Dev", for: b.id)

        let devBookmarks = await store.bookmarks(inFolder: "Dev")
        XCTAssertEqual(devBookmarks.count, 1)
        XCTAssertEqual(devBookmarks.first?.folderName, "Dev")
    }

    func testBookmark_folders_listedAndSorted() async throws {
        let db = try makeDB()
        let store = BookmarkStore(dbWriter: db.browserWriter)

        await store.add(url: URL(string: "https://c.com")!, title: "C", folderName: "Zebra")
        await store.add(url: URL(string: "https://a.com")!, title: "A", folderName: "Alpha")
        await store.add(url: URL(string: "https://b.com")!, title: "B", folderName: "Beta")

        let folders = await store.folders()
        XCTAssertEqual(folders, ["Alpha", "Beta", "Zebra"],
            "folders() must return sorted folder names")
    }

    func testBookmark_containsURL() async throws {
        let db = try makeDB()
        let store = BookmarkStore(dbWriter: db.browserWriter)

        let url = URL(string: "https://example.com")!
        let before = await store.contains(url: url)
        XCTAssertFalse(before)

        await store.add(url: url, title: "Example")
        let after = await store.contains(url: url)
        XCTAssertTrue(after)
    }

    func testBookmark_bookmarksInFolder() async throws {
        let db = try makeDB()
        let store = BookmarkStore(dbWriter: db.browserWriter)

        await store.add(url: URL(string: "https://a.com")!, title: "A", folderName: "Work")
        await store.add(url: URL(string: "https://b.com")!, title: "B", folderName: "Work")
        await store.add(url: URL(string: "https://c.com")!, title: "C", folderName: "Personal")

        let work = await store.bookmarks(inFolder: "Work")
        XCTAssertEqual(work.count, 2)
        XCTAssertTrue(work.allSatisfy { $0.folderName == "Work" })
    }

    // MARK: - DatabaseManager

    func testDatabaseManager_makeInMemory_independentInstances() throws {
        let db1 = try DatabaseManager.makeInMemory()
        let db2 = try DatabaseManager.makeInMemory()

        // Write to db1 — db2 must be unaffected.
        try db1.browserWriter.write { db in
            try db.execute(
                sql: "INSERT INTO bookmark (id, url, title, createdAt) VALUES (?, ?, ?, ?)",
                arguments: [UUID().uuidString, "https://a.com", "A", Date()]
            )
        }

        let count = try db2.browserWriter.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM bookmark") ?? 0
        }
        XCTAssertEqual(count, 0, "In-memory instances must be fully isolated from each other")
    }

    func testDatabaseManager_historyAndBrowserAreDistinctDBs() throws {
        let db = try DatabaseManager.makeInMemory()

        // history.db has historyEntry + historyFTS; browser.db has bookmark + browserSession.
        XCTAssertNoThrow(try db.historyWriter.read { db in
            _ = try Row.fetchOne(db, sql: "SELECT * FROM historyEntry LIMIT 1")
        }, "historyEntry table must exist in the history writer")

        XCTAssertNoThrow(try db.browserWriter.read { db in
            _ = try Row.fetchOne(db, sql: "SELECT * FROM bookmark LIMIT 1")
        }, "bookmark table must exist in the browser writer")
    }
}
