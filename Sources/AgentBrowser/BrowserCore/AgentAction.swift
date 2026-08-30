import Foundation

struct AgentAction: Identifiable, Sendable, Codable, Hashable {
    let id: UUID
    let agentID: String
    let tabID: UUID
    let method: String       // "page.click", "page.read", etc.
    var description: String  // human-readable: "Clicking 'Add to Cart'"
    let startedAt: Date
    var status: ActionStatus
    var completedAt: Date?

    init(agentID: String, tabID: UUID, method: String, description: String = "") {
        self.id = UUID()
        self.agentID = agentID
        self.tabID = tabID
        self.method = method
        self.description = description.isEmpty ? method : description
        self.startedAt = Date()
        self.status = .inFlight
        self.completedAt = nil
    }

    var duration: TimeInterval {
        (completedAt ?? Date()).timeIntervalSince(startedAt)
    }
}

enum ActionStatus: String, Sendable, Codable, Hashable {
    case inFlight
    case completed
    case failed
    case overridden  // human took over
}
