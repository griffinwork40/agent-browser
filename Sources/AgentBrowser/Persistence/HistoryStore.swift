import Foundation

// MARK: - HistoryEntry

/// A single browsing history record.
struct HistoryEntry: Identifiable, Codable, Sendable {
    let id: UUID
    let url: URL
    var title: String
    let visitedAt: Date

    init(
        id: UUID = UUID(),
        url: URL,
        title: String,
        visitedAt: Date = Date()
    ) {
        self.id = id
        self.url = url
        self.title = title
        self.visitedAt = visitedAt
    }
}

// MARK: - HistoryStore

/// Stores browsing history as a JSON array, capped at `maxEntries`.
///
/// Newest entries are stored at index 0. Writes are atomic so a crash
/// during save will not corrupt the file.
actor HistoryStore {
    private var entries: [HistoryEntry] = []
    private let maxEntries = 10_000
    private let fileURL: URL

    init(dataDirectory: URL) {
        self.fileURL = dataDirectory.appendingPathComponent("history.json")
        self.entries = Self.load(from: fileURL) ?? []
    }

    // MARK: - Write

    /// Prepends a new visit record and persists immediately.
    func addEntry(url: URL, title: String) {
        let entry = HistoryEntry(url: url, title: title)
        entries.insert(entry, at: 0)
        if entries.count > maxEntries {
            entries.removeLast(entries.count - maxEntries)
        }
        save()
    }

    /// Removes all history entries and deletes the backing file.
    func clearAll() {
        entries = []
        try? FileManager.default.removeItem(at: fileURL)
    }

    // MARK: - Read

    /// Returns all entries whose title or URL contains `query` (case-insensitive).
    func search(query: String) -> [HistoryEntry] {
        let lowered = query.lowercased()
        return entries.filter {
            $0.title.lowercased().contains(lowered)
                || $0.url.absoluteString.lowercased().contains(lowered)
        }
    }

    /// Returns the most recent entries, up to `limit`.
    func recentEntries(limit: Int = 50) -> [HistoryEntry] {
        Array(entries.prefix(limit))
    }

    // MARK: - Private persistence

    private func save() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    private static func load(from url: URL) -> [HistoryEntry]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode([HistoryEntry].self, from: data)
    }
}
