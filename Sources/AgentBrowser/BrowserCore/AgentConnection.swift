import Foundation

struct AgentConnection: Identifiable, Sendable, Codable, Hashable {
    let id: String  // agentID from API
    var displayName: String
    let connectedAt: Date
    var lastSeenAt: Date
    var status: ConnectionStatus
    var colorIndex: Int  // index into fixed color palette (0-5)

    init(id: String, displayName: String? = nil, colorIndex: Int = 0) {
        self.id = id
        self.displayName = displayName ?? id
        self.connectedAt = Date()
        self.lastSeenAt = Date()
        self.status = .idle
        self.colorIndex = colorIndex
    }
}

enum ConnectionStatus: String, Sendable, Codable, Hashable {
    case active       // currently executing an action
    case idle         // connected, not doing anything
    case disconnected // was connected, now gone
}
