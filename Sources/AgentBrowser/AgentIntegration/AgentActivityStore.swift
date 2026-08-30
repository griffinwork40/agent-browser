import Foundation
import Observation

@Observable @MainActor
final class AgentActivityStore {
    private(set) var connections: [AgentConnection] = []
    private(set) var activeActions: [AgentAction] = []   // currently in-flight
    private(set) var recentActions: [AgentAction] = []   // completed, capped at 100

    private let maxRecentActions = 100
    private var nextColorIndex = 0

    // MARK: - Connection Management

    func registerAgent(id: String, displayName: String? = nil) -> AgentConnection {
        if let existing = connections.first(where: { $0.id == id && $0.status != .disconnected }) {
            return existing
        }
        let connection = AgentConnection(id: id, displayName: displayName, colorIndex: nextColorIndex % 6)
        nextColorIndex += 1
        connections.append(connection)
        return connection
    }

    func disconnectAgent(id: String) {
        if let index = connections.firstIndex(where: { $0.id == id }) {
            connections[index].status = .disconnected
        }
    }

    func updateLastSeen(agentID: String) {
        if let index = connections.firstIndex(where: { $0.id == agentID }) {
            connections[index].lastSeenAt = Date()
        }
    }

    // MARK: - Action Tracking

    func beginAction(agentID: String, tabID: UUID, method: String, description: String = "") -> AgentAction {
        let action = AgentAction(agentID: agentID, tabID: tabID, method: method, description: description)
        activeActions.append(action)

        // Mark agent as active
        if let index = connections.firstIndex(where: { $0.id == agentID }) {
            connections[index].status = .active
        }

        updateLastSeen(agentID: agentID)
        return action
    }

    func completeAction(id: UUID, status: ActionStatus = .completed) {
        guard let index = activeActions.firstIndex(where: { $0.id == id }) else { return }
        var action = activeActions.remove(at: index)
        action.status = status
        action.completedAt = Date()
        recentActions.insert(action, at: 0)
        if recentActions.count > maxRecentActions {
            recentActions.removeLast(recentActions.count - maxRecentActions)
        }

        // If no more active actions for this agent, mark idle
        let agentID = action.agentID
        if !activeActions.contains(where: { $0.agentID == agentID }) {
            if let idx = connections.firstIndex(where: { $0.id == agentID }) {
                connections[idx].status = .idle
            }
        }
    }

    // MARK: - Queries

    func actionsForTab(_ tabID: UUID) -> [AgentAction] {
        activeActions.filter { $0.tabID == tabID }
    }

    func isTabAgentControlled(_ tabID: UUID) -> Bool {
        activeActions.contains { $0.tabID == tabID }
    }

    func activeAgentForTab(_ tabID: UUID) -> AgentConnection? {
        guard let action = activeActions.first(where: { $0.tabID == tabID }) else { return nil }
        return connections.first { $0.id == action.agentID }
    }

    func connectedAgents() -> [AgentConnection] {
        connections.filter { $0.status != .disconnected }
    }
}
