import Foundation

/// Central coordinator for all on-disk persistence.
///
/// Creates and vends the app's Application Support directory.
/// All stores (HistoryStore, SessionStore, BookmarkStore) are initialized
/// with the `dataDirectory` URL rather than constructing paths themselves.
///
/// Per-profile data lives under `profiles/<uuid>/` subdirectories so each
/// profile's history and bookmarks are fully isolated from one another.
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

    /// Returns the per-profile subdirectory for `profileID`, creating it if needed.
    ///
    /// Path: `~/Library/Application Support/AgentBrowser/profiles/<uuid>/`
    func profileDataDirectory(for profileID: UUID) -> URL {
        let dir = dataDirectory
            .appendingPathComponent("profiles", isDirectory: true)
            .appendingPathComponent(profileID.uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
