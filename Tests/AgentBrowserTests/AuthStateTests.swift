import Foundation
import Testing
@testable import AgentBrowser

/// Tests for awaitingAuth state transitions and TakeoverHandler auth methods.
@Suite("Auth State Machine")
struct AuthStateTests {

    // MARK: - TabControlState Auth Transitions

    @Test("awaitAuth transitions from agentActive to awaitingAuth")
    @MainActor func awaitAuthFromAgentActive() {
        let state = TabControlState(tabID: UUID())
        state.agentBegins(agentID: "agent-1")
        state.awaitAuth(reason: "Login required")
        #expect(state.state == .awaitingAuth)
        #expect(state.activeAgentID == "agent-1")  // agent still associated
        #expect(state.authReason == "Login required")
    }

    @Test("awaitAuth ignored when idle -- no agent to hand off to")
    @MainActor func awaitAuthIgnoredWhenIdle() {
        let state = TabControlState(tabID: UUID())
        state.awaitAuth(reason: "Login required")
        #expect(state.state == .idle)
        #expect(state.activeAgentID == nil)
        #expect(state.authReason == nil)
    }

    @Test("awaitAuth ignored when humanOwns")
    @MainActor func awaitAuthIgnoredWhenHumanOwns() {
        let state = TabControlState(tabID: UUID())
        state.agentBegins(agentID: "agent-1")
        state.humanInterrupts(trigger: .click)
        state.agentCompletes()  // -> humanOwns
        state.awaitAuth(reason: "Login required")
        #expect(state.state == .humanOwns)
    }

    @Test("humanResumes from awaitingAuth transitions to agentActive and clears reason")
    @MainActor func humanResumesFromAwaitingAuth() {
        let state = TabControlState(tabID: UUID())
        state.agentBegins(agentID: "agent-1")
        state.awaitAuth(reason: "2FA")
        state.humanResumes()
        #expect(state.state == .agentActive)
        #expect(state.authReason == nil)
        #expect(state.activeAgentID == "agent-1")  // agent still valid
    }

    @Test("humanEnds from awaitingAuth clears authReason")
    @MainActor func humanEndsFromAwaitingAuth() {
        let state = TabControlState(tabID: UUID())
        state.agentBegins(agentID: "agent-1")
        state.awaitAuth(reason: "OAuth required")
        state.humanEnds()
        #expect(state.state == .idle)
        #expect(state.authReason == nil)
        #expect(state.activeAgentID == nil)
    }

    @Test("awaitAuth with nil reason stores nil")
    @MainActor func awaitAuthNilReason() {
        let state = TabControlState(tabID: UUID())
        state.agentBegins(agentID: "agent-1")
        state.awaitAuth()
        #expect(state.state == .awaitingAuth)
        #expect(state.authReason == nil)
    }

    // MARK: - TakeoverHandler Auth Methods

    @Test("requestAuth transitions tab to awaitingAuth")
    @MainActor func handlerRequestAuth() {
        let handler = TakeoverHandler()
        let tabID = UUID()
        handler.beginAgentAction(tabID: tabID, agentID: "agent-1")
        handler.requestAuth(tabID: tabID)
        let state = handler.controlState(for: tabID)
        #expect(state.state == .awaitingAuth)
    }

    @Test("authCompleted resumes agent from awaitingAuth")
    @MainActor func handlerAuthCompleted() {
        let handler = TakeoverHandler()
        let tabID = UUID()
        handler.beginAgentAction(tabID: tabID, agentID: "agent-1")
        handler.requestAuth(tabID: tabID)
        handler.authCompleted(tabID: tabID)
        let state = handler.controlState(for: tabID)
        #expect(state.state == .agentActive)
    }

    @Test("authCompleted is no-op when not awaitingAuth")
    @MainActor func handlerAuthCompletedNoOp() {
        let handler = TakeoverHandler()
        let tabID = UUID()
        handler.beginAgentAction(tabID: tabID, agentID: "agent-1")
        handler.authCompleted(tabID: tabID)
        let state = handler.controlState(for: tabID)
        #expect(state.state == .agentActive)  // unchanged
    }

    @Test("awaitingAuthTabs lists tabs in awaitingAuth state")
    @MainActor func handlerAwaitingAuthTabs() {
        let handler = TakeoverHandler()
        let tabID = UUID()
        handler.beginAgentAction(tabID: tabID, agentID: "agent-1")
        handler.requestAuth(tabID: tabID)
        #expect(handler.awaitingAuthTabs.contains(tabID))
        #expect(!handler.agentControlledTabs.contains(tabID))
    }

    @Test("requestAuth from idle is no-op after guard tightening")
    @MainActor func handlerRequestAuthFromIdleNoOp() {
        let handler = TakeoverHandler()
        let tabID = UUID()
        // Tab is idle (no agent started)
        handler.requestAuth(tabID: tabID)
        let state = handler.controlState(for: tabID)
        #expect(state.state == .idle)  // must remain idle
    }

    // MARK: - agentCompletes / agentFailed from awaitingAuth (items 5 & 6)

    @Test("agentCompletes from awaitingAuth transitions to idle and clears auth fields")
    @MainActor func agentCompletesFromAwaitingAuth() {
        let state = TabControlState(tabID: UUID())
        state.agentBegins(agentID: "agent-1")
        state.awaitAuth(reason: "Login required")
        #expect(state.state == .awaitingAuth)

        state.agentCompletes()

        #expect(state.state == .idle)
        #expect(state.authReason == nil)
        #expect(state.activeAgentID == nil)
    }

    @Test("agentFailed from awaitingAuth transitions to error and clears authReason")
    @MainActor func agentFailedFromAwaitingAuth() {
        let state = TabControlState(tabID: UUID())
        state.agentBegins(agentID: "agent-1")
        state.awaitAuth(reason: "Auth timed out")
        #expect(state.state == .awaitingAuth)

        state.agentFailed()

        #expect(state.state == .error)
        #expect(state.authReason == nil)
    }
}
