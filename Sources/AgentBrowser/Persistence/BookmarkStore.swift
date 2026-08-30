import Foundation

// MARK: - Bookmark

/// A saved URL with optional folder grouping.
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

// MARK: - BookmarkStore

/// Stores bookmarks as a flat JSON array, partitioned into named folders.
///
/// Folders are implicit — they exist whenever at least one bookmark carries
/// that `folderName`. Deleting the last bookmark in a folder removes the folder.
actor BookmarkStore {
    private var bookmarks: [Bookmark] = []
    private let fileURL: URL

    init(dataDirectory: URL) {
        self.fileURL = dataDirectory.appendingPathComponent("bookmarks.json")
        self.bookmarks = Self.load(from: fileURL) ?? []
    }

    // MARK: - Write

    /// Creates and persists a new bookmark. Returns the stored value.
    @discardableResult
    func add(url: URL, title: String, folderName: String? = nil) -> Bookmark {
        let bookmark = Bookmark(url: url, title: title, folderName: folderName)
        bookmarks.append(bookmark)
        save()
        return bookmark
    }

    /// Removes a bookmark by its stable ID.
    func remove(id: UUID) {
        bookmarks.removeAll { $0.id == id }
        save()
    }

    /// Updates the title of an existing bookmark in-place.
    func updateTitle(_ title: String, for id: UUID) {
        guard let idx = bookmarks.firstIndex(where: { $0.id == id }) else { return }
        bookmarks[idx].title = title
        save()
    }

    /// Moves a bookmark into a folder (or clears its folder when `nil`).
    func setFolder(_ folderName: String?, for id: UUID) {
        guard let idx = bookmarks.firstIndex(where: { $0.id == id }) else { return }
        bookmarks[idx].folderName = folderName
        save()
    }

    // MARK: - Read

    /// All stored bookmarks in insertion order.
    func all() -> [Bookmark] { bookmarks }

    /// Bookmarks belonging to `folderName`, in insertion order.
    func bookmarks(inFolder folderName: String) -> [Bookmark] {
        bookmarks.filter { $0.folderName == folderName }
    }

    /// Sorted list of all folder names that have at least one bookmark.
    func folders() -> [String] {
        Array(Set(bookmarks.compactMap { $0.folderName })).sorted()
    }

    /// Returns true if the given URL is already bookmarked.
    func contains(url: URL) -> Bool {
        bookmarks.contains { $0.url == url }
    }

    // MARK: - Private persistence

    private func save() {
        guard let data = try? JSONEncoder().encode(bookmarks) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    private static func load(from url: URL) -> [Bookmark]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode([Bookmark].self, from: data)
    }
}
