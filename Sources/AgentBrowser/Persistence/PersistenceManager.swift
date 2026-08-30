import Foundation

/// Central coordinator for all on-disk persistence.
///
/// Creates and vends the app's Application Support directory.
/// All stores (HistoryStore, SessionStore, BookmarkStore) are initialized
/// with the `dataDirectory` URL rather than constructing paths themselves.
actor PersistenceManager {
    static let shared = PersistenceManager()

    /// Root directory: ~/Library/Application Support/AgentBrowser/
    let dataDirectory: URL

    private init() {
        let appSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!
        dataDirectory = appSupport.appendingPathComponent("AgentBrowser", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: dataDirectory,
            withIntermediateDirectories: true
        )
    }

    /// Returns the full URL for a file stored inside the app data directory.
    func url(for filename: String) -> URL {
        dataDirectory.appendingPathComponent(filename)
    }
}
