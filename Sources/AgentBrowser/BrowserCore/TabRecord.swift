import Foundation

/// Pure domain identity for a browser tab.
/// No AppKit, WebKit, or SwiftUI imports — safe to use from any layer.
struct TabRecord: Identifiable, Sendable, Codable, Hashable {
    let id: UUID
    let createdAt: Date
    var provenance: TabProvenance
    var lifecycleState: TabLifecycle
    var groupID: UUID?
    var isPinned: Bool
    var isPrivate: Bool
    /// The profile this tab belongs to. Defaults to a placeholder UUID;
    /// TabManager always overwrites this with the active profile's ID at creation.
    var profileID: UUID

    init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        provenance: TabProvenance = .human,
        lifecycleState: TabLifecycle = .empty,
        groupID: UUID? = nil,
        isPinned: Bool = false,
        isPrivate: Bool = false,
        profileID: UUID = UUID()
    ) {
        self.id = id
        self.createdAt = createdAt
        self.provenance = provenance
        self.lifecycleState = lifecycleState
        self.groupID = groupID
        self.isPinned = isPinned
        self.isPrivate = isPrivate
        self.profileID = profileID
    }
}
