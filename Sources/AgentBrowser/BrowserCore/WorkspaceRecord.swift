import Foundation

/// A named, color-coded grouping of tabs.
///
/// Workspaces are durable (Codable) and can survive session restart.
/// The `colorName` is a string token (e.g. "blue", "red", "green") that
/// the UI layer maps to a concrete color — keeping this type framework-free.
struct WorkspaceRecord: Identifiable, Sendable, Codable, Hashable {
    let id: UUID
    var name: String
    /// System color name token. UI layer maps this to NSColor / Color.
    var colorName: String
    /// Ordered list of tab IDs belonging to this workspace.
    var tabIDs: [UUID]
    let createdAt: Date

    init(
        id: UUID = UUID(),
        name: String,
        colorName: String = "blue",
        tabIDs: [UUID] = [],
        createdAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.colorName = colorName
        self.tabIDs = tabIDs
        self.createdAt = createdAt
    }

    // MARK: - Convenience

    /// True when this workspace contains the given tab.
    func contains(tabID: UUID) -> Bool {
        tabIDs.contains(tabID)
    }

    /// Returns a copy with the tab appended (if not already present).
    func adding(tabID: UUID) -> WorkspaceRecord {
        guard !tabIDs.contains(tabID) else { return self }
        var copy = self
        copy.tabIDs.append(tabID)
        return copy
    }

    /// Returns a copy with the tab removed.
    func removing(tabID: UUID) -> WorkspaceRecord {
        var copy = self
        copy.tabIDs.removeAll { $0 == tabID }
        return copy
    }
}
