import Foundation
import GRDB

// MARK: - DatabaseManager

/// Opens and migrates the two SQLite databases used by the browser.
///
/// Two separate pools keep the high-write history traffic isolated from
/// bookmarks and sessions:
/// - `historyWriter` → history.db (includes an FTS5 virtual table)
/// - `browserWriter` → browser.db (bookmarks + single-row session snapshot)
///
/// Not an actor — GRDB pools manage their own thread safety internally.
/// In tests, pass in-memory `DatabaseQueue` instances via `makeInMemory()`.
final class DatabaseManager: Sendable {

    let historyWriter: any DatabaseWriter
    let browserWriter: any DatabaseWriter

    // MARK: - Production init

    /// Creates WAL-mode `DatabasePool` instances in the given directory,
    /// then runs all pending migrations on both databases.
    init(directory: URL) throws {
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        historyWriter = try DatabasePool(
            path: directory.appendingPathComponent("history.db").path)
        browserWriter = try DatabasePool(
            path: directory.appendingPathComponent("browser.db").path)
        try Self.runMigrations(history: historyWriter, browser: browserWriter)
    }

    // MARK: - In-memory init for tests

    /// Returns a `DatabaseManager` backed by two in-memory `DatabaseQueue`s.
    /// Each call produces a fresh, independent pair of databases.
    static func makeInMemory() throws -> DatabaseManager {
        let h = try DatabaseQueue()
        let b = try DatabaseQueue()
        return try DatabaseManager(historyWriter: h, browserWriter: b)
    }

    // MARK: - Private

    private init(
        historyWriter: any DatabaseWriter,
        browserWriter: any DatabaseWriter
    ) throws {
        self.historyWriter = historyWriter
        self.browserWriter = browserWriter
        try Self.runMigrations(history: historyWriter, browser: browserWriter)
    }

    private static func runMigrations(
        history: any DatabaseWriter,
        browser: any DatabaseWriter
    ) throws {
        try DatabaseSetup.historyMigrator.migrate(history)
        try DatabaseSetup.browserMigrator.migrate(browser)
    }
}
