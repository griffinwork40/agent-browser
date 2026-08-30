import Foundation
import Observation

@Observable @MainActor
final class TakeoverHandler {
    private var tabStates: [UUID: TabControlState] = [:]

    /// Get or create the control state for a tab
    func controlState(for tabID: UUID) -> TabControlState {
        if let existing = tabStates[tabID] {
            return existing
        }
        let state = TabControlState(tabID: tabID)
        tabStates[tabID] = state
        return state
    }

    /// Remove control state when tab is closed
    func removeTab(_ tabID: UUID) {
        tabStates.removeValue(forKey: tabID)
    }

    /// Process a human interaction event on a tab.
    /// Returns true if takeover was triggered.
    @discardableResult
    func processHumanEvent(tabID: UUID, trigger: InterruptTrigger) -> Bool {
        let state = controlState(for: tabID)
        guard state.state == .agentActive else { return false }
        guard TabControlState.shouldTriggerTakeover(trigger) else { return false }
        state.humanInterrupts(trigger: trigger)
        return true
    }

    /// Check if an agent can start an action on a tab
    func canAgentAct(on tabID: UUID) -> Bool {
        let state = controlState(for: tabID)
        return state.state == .idle
    }

    /// Begin agent action on a tab; returns false if tab is not available
    @discardableResult
    func beginAgentAction(tabID: UUID, agentID: String) -> Bool {
        let state = controlState(for: tabID)
        return state.agentBegins(agentID: agentID)
    }

    /// Complete agent action on a tab
    func completeAgentAction(tabID: UUID) {
        controlState(for: tabID).agentCompletes()
    }

    /// Resume agent on a tab after human took control
    func resumeAgent(tabID: UUID) {
        controlState(for: tabID).humanResumes()
    }

    /// End all agent activity on a tab
    func endAgent(tabID: UUID) {
        controlState(for: tabID).humanEnds()
    }

    /// All tabs currently under agent control
    var agentControlledTabs: [UUID] {
        tabStates.filter { $0.value.state == .agentActive }.map { $0.key }
    }

    /// All tabs where human has taken over
    var humanOwnedTabs: [UUID] {
        tabStates.filter { $0.value.state == .humanOwns }.map { $0.key }
    }
}
