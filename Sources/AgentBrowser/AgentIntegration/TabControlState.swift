import Foundation
import Observation

enum ControlState: String, Sendable, Codable {
    case idle          // no agent activity
    case agentActive   // agent performing action
    case interrupting  // human touched, agent completing atomic action
    case humanOwns     // human took over, agent paused
    case error         // agent action failed
}

enum InterruptTrigger: String, Sendable {
    case click         // human clicked in page
    case type          // human typed in page
    case navigate      // human navigated (address bar)
    case contextMenu   // human right-clicked
    case explicit      // Take Control button
}

@Observable @MainActor
final class TabControlState: Identifiable {
    let tabID: UUID
    private(set) var state: ControlState = .idle
    private(set) var activeAgentID: String?
    private(set) var lastTransitionAt: Date = Date()
    private(set) var interruptTrigger: InterruptTrigger?

    init(tabID: UUID) {
        self.tabID = tabID
    }

    var id: UUID { tabID }

    // MARK: - Transitions

    /// Agent begins an action on this tab
    @discardableResult
    func agentBegins(agentID: String) -> Bool {
        guard state == .idle else { return false }
        activeAgentID = agentID
        transition(to: .agentActive)
        return true
    }

    /// Agent completes its action normally
    func agentCompletes() {
        guard state == .agentActive || state == .interrupting else { return }
        if state == .interrupting {
            // Was interrupted; hand off to human
            interruptTrigger = nil
            transition(to: .humanOwns)
        } else {
            activeAgentID = nil
            transition(to: .idle)
        }
    }

    /// Agent action failed
    func agentFailed() {
        guard state == .agentActive || state == .interrupting else { return }
        activeAgentID = nil
        transition(to: .error)
    }

    /// Human touches the tab (click, type, navigate)
    func humanInterrupts(trigger: InterruptTrigger) {
        guard state == .agentActive else { return }
        interruptTrigger = trigger
        transition(to: .interrupting)
    }

    /// Human explicitly resumes agent
    func humanResumes() {
        guard state == .humanOwns else { return }
        transition(to: .agentActive)
    }

    /// Human ends the agent task entirely
    func humanEnds() {
        activeAgentID = nil
        interruptTrigger = nil
        transition(to: .idle)
    }

    /// Error acknowledged or timed out
    func acknowledgeError() {
        guard state == .error else { return }
        activeAgentID = nil
        transition(to: .idle)
    }

    /// Check if a human action type should trigger takeover
    static func shouldTriggerTakeover(_ action: InterruptTrigger) -> Bool {
        switch action {
        case .click, .type, .navigate, .contextMenu, .explicit:
            return true
        }
    }

    // MARK: - Private

    private func transition(to newState: ControlState) {
        state = newState
        lastTransitionAt = Date()
    }
}
