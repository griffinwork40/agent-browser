import Foundation
import Observation

@Observable @MainActor
final class AgentRegistry {
    private(set) var registeredTokens: [String: String] = [:]  // token -> agentID
    private let activityStore: AgentActivityStore

    init(activityStore: AgentActivityStore) {
        self.activityStore = activityStore
    }

    func validateToken(_ token: String) -> String? {
        registeredTokens[token]
    }

    func registerToken(_ token: String, agentID: String, displayName: String? = nil) {
        registeredTokens[token] = agentID
        _ = activityStore.registerAgent(id: agentID, displayName: displayName)
    }

    func revokeToken(_ token: String) {
        if let agentID = registeredTokens.removeValue(forKey: token) {
            activityStore.disconnectAgent(id: agentID)
        }
    }

    func agentIDForToken(_ token: String) -> String? {
        registeredTokens[token]
    }
}
