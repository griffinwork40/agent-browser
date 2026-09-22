import Foundation
import GRDB

// MARK: - DatabaseSetup

/// Holds the two GRDB migrators — one per database file.
enum DatabaseSetup {

    // MARK: - History (history.db)

    static var historyMigrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1-history") { db in
            // Main history table.
            // Uses an explicit auto-increment primary key (rowid) so that the
            // FTS5 external-content triggers can reference it reliably.
            // The UUID identity lives in the `id` column with a UNIQUE constraint.
            try db.create(table: "historyEntry") { t in
                t.autoIncrementedPrimaryKey("rowid")
                t.column("id", .text).notNull().unique()
                t.column("url", .text).notNull()
                t.column("title", .text).notNull().defaults(to: "")
                t.column("visitedAt", .datetime).notNull()
            }
            try db.create(
                index: "idx_history_visitedAt",
                on: "historyEntry",
                columns: ["visitedAt"]
            )

            // FTS5 virtual table: external-content referencing historyEntry.
            // rowid in historyFTS maps to rowid in historyEntry.
            try db.execute(sql: """
                CREATE VIRTUAL TABLE historyFTS USING fts5(
                    title, url,
                    content='historyEntry',
                    content_rowid='rowid'
                )
            """)

            // Triggers that keep the FTS index in sync with historyEntry.
            try db.execute(sql: """
                CREATE TRIGGER historyFTS_ai
                AFTER INSERT ON historyEntry BEGIN
                    INSERT INTO historyFTS(rowid, title, url)
                    VALUES (new.rowid, new.title, new.url);
                END
            """)
            try db.execute(sql: """
                CREATE TRIGGER historyFTS_ad
                AFTER DELETE ON historyEntry BEGIN
                    INSERT INTO historyFTS(historyFTS, rowid, title, url)
                    VALUES ('delete', old.rowid, old.title, old.url);
                END
            """)
            try db.execute(sql: """
                CREATE TRIGGER historyFTS_au
                AFTER UPDATE ON historyEntry BEGIN
                    INSERT INTO historyFTS(historyFTS, rowid, title, url)
                    VALUES ('delete', old.rowid, old.title, old.url);
                    INSERT INTO historyFTS(rowid, title, url)
                    VALUES (new.rowid, new.title, new.url);
                END
            """)
        }

        return migrator
    }

    // MARK: - Browser (browser.db)

    static var browserMigrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1-browser") { db in
            // Bookmarks table. UUID stored as TEXT primary key.
            try db.create(table: "bookmark") { t in
                t.primaryKey("id", .text).notNull()
                t.column("url", .text).notNull()
                t.column("title", .text).notNull().defaults(to: "")
                t.column("folderName", .text)
                t.column("createdAt", .datetime).notNull()
            }

            // Single-row session snapshot.
            // The `key` column is always the literal string "current".
            // INSERT OR REPLACE is used for upsert semantics.
            try db.create(table: "browserSession") { t in
                t.primaryKey("key", .text).notNull()
                t.column("snapshotJSON", .text).notNull()
                t.column("savedAt", .datetime).notNull()
            }
        }

        return migrator
    }
}
