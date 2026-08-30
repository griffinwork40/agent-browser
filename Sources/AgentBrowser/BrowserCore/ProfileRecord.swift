import Foundation

/// Pure domain identity for a browser profile.
/// Maps 1:1 to a WKWebsiteDataStore via its UUID.
/// No WebKit/AppKit imports — safe to use from any layer.
struct ProfileRecord: Identifiable, Sendable, Codable, Hashable {
    let id: UUID
    var name: String
    var colorName: String  // matches WorkspaceRecord convention
    var email: String?     // populated after Google sign-in
    var avatarURL: URL?    // cached Google profile photo
    let createdAt: Date

    /// Palette of profile colors, cycling on assignment.
    static let defaultColors = [
        "blue", "green", "orange", "purple", "red",
        "teal", "pink", "indigo", "brown", "mint"
    ]

    init(
        id: UUID = UUID(),
        name: String = "Profile",
        colorName: String = "blue",
        email: String? = nil,
        avatarURL: URL? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.colorName = colorName
        self.email = email
        self.avatarURL = avatarURL
        self.createdAt = createdAt
    }
}
