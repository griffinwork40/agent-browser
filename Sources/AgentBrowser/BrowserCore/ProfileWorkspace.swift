import Foundation

/// Serialisable snapshot of a profile's tab workspace.
///
/// Stored per-profile inside `SessionSnapshot.workspaces` so each profile
/// independently remembers its tab set, selection, and closed-tab history.
/// Value-type; `@MainActor` mutation occurs in callers (BrowserWindowController).
struct ProfileWorkspace: Codable, Sendable {

    // MARK: - Types

    /// Minimal per-tab state needed to recreate a tab on next launch.
    struct TabEntry: Codable, Sendable, Identifiable, Equatable {
        let id: UUID
        let urlString: String?
        let title: String
        let provenance: TabProvenance
        let profileID: UUID

        var url: URL? { urlString.flatMap(URL.init(string:)) }

        init(
            id: UUID,
            urlString: String?,
            title: String,
            provenance: TabProvenance,
            profileID: UUID
        ) {
            self.id = id
            self.urlString = urlString
            self.title = title
            self.provenance = provenance
            self.profileID = profileID
        }

        /// Build from a `SessionSnapshot.TabSnapshot`.
        init(_ snap: SessionSnapshot.TabSnapshot) {
            self.id = snap.id
            self.urlString = snap.urlString
            self.title = snap.title
            self.provenance = snap.provenance
            self.profileID = snap.profileID
        }

        /// Convert back to a `SessionSnapshot.TabSnapshot`.
        var asTabSnapshot: SessionSnapshot.TabSnapshot {
            SessionSnapshot.TabSnapshot(
                id: id,
                urlString: urlString,
                title: title,
                provenance: provenance,
                profileID: profileID
            )
        }
    }

    // MARK: - Properties

    let profileID: UUID
    /// Ordered tabs belonging to this profile.
    var tabs: [TabEntry]
    /// Selected tab ID; nil if the workspace is empty.
    var selectedTabID: UUID?
    /// Closed-tab history (most recent first), capped at `maxClosedHistory`.
    var closedTabHistory: [TabEntry]

    static let maxClosedHistory = 25

    // MARK: - Init

    init(
        profileID: UUID,
        tabs: [TabEntry] = [],
        selectedTabID: UUID? = nil,
        closedTabHistory: [TabEntry] = []
    ) {
        self.profileID = profileID
        self.tabs = tabs
        self.selectedTabID = selectedTabID
        self.closedTabHistory = Array(closedTabHistory.prefix(Self.maxClosedHistory))
    }

    // MARK: - Convenience

    var isEmpty: Bool { tabs.isEmpty }

    /// Returns an empty workspace for the given profile (first-launch state).
    static func empty(for profileID: UUID) -> ProfileWorkspace {
        ProfileWorkspace(profileID: profileID)
    }

    /// Append a closed tab to history (capped).
    func addingClosed(_ entry: TabEntry) -> ProfileWorkspace {
        var copy = self
        copy.closedTabHistory.insert(entry, at: 0)
        if copy.closedTabHistory.count > Self.maxClosedHistory {
            copy.closedTabHistory.removeLast(copy.closedTabHistory.count - Self.maxClosedHistory)
        }
        return copy
    }
}

// MARK: - Equatable

extension ProfileWorkspace: Equatable {
    static func == (lhs: ProfileWorkspace, rhs: ProfileWorkspace) -> Bool {
        lhs.profileID == rhs.profileID &&
        lhs.tabs == rhs.tabs &&
        lhs.selectedTabID == rhs.selectedTabID &&
        lhs.closedTabHistory == rhs.closedTabHistory
    }
}
