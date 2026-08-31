import Foundation
import Testing
@testable import AgentBrowser

/// Tests for passkey detection signals in AuthDetection and
/// the handoff state machine wiring in PasskeyHandoff.
@Suite("Passkey Detection & Handoff")
struct PasskeyDetectionTests {

    // MARK: - AuthStatusResult Classification

    @Test("passkey_heading signal produces passkey_required status")
    func passkeyHeadingClassification() {
        let dict: [String: Any] = [
            "status": "passkey_required",
            "url": "https://accounts.google.com/challenge/pk/presend",
            "title": "Use your passkey to confirm it's really you",
            "signals": [
                ["type": "passkey_heading", "detail": "use your passkey to confirm it's really you"],
                ["type": "url_pattern", "detail": "/challenge"]
            ]
        ]
        let result = AuthStatusResult(from: dict)
        #expect(result.status == "passkey_required")
        #expect(result.signals.count == 2)
        #expect(result.signals[0]["type"] == "passkey_heading")
    }

    @Test("passkey_url signal produces passkey_required status")
    func passkeyUrlClassification() {
        let dict: [String: Any] = [
            "status": "passkey_required",
            "url": "https://accounts.google.com/challenge/pk/presend",
            "title": "Sign in",
            "signals": [["type": "passkey_url", "detail": "/challenge/pk/"]]
        ]
        let result = AuthStatusResult(from: dict)
        #expect(result.status == "passkey_required")
    }

    @Test("passkey_button signal produces passkey_required status")
    func passkeyButtonClassification() {
        let dict: [String: Any] = [
            "status": "passkey_required",
            "url": "https://login.example.com/auth",
            "title": "Sign in",
            "signals": [["type": "passkey_button", "detail": "use a passkey"]]
        ]
        let result = AuthStatusResult(from: dict)
        #expect(result.status == "passkey_required")
    }

    @Test("AuthStatusResult sanitizes title for passkey pages")
    func sanitizePasskeyTitle() {
        let dict: [String: Any] = [
            "status": "passkey_required",
            "url": "https://example.com",
            "title": "Use your passkey\n\rto sign in\t",
            "signals": [["type": "passkey_heading", "detail": "test"]]
        ]
        let result = AuthStatusResult(from: dict)
        // Control chars stripped
        #expect(!result.title.contains("\n"))
        #expect(!result.title.contains("\r"))
        #expect(!result.title.contains("\t"))
    }

    // MARK: - Handoff State Machine (via TakeoverHandler)

    @Test("requestAuth + authCompleted round-trip through TakeoverHandler")
    @MainActor func handoffRoundTrip() {
        let handler = TakeoverHandler()
        let tabID = UUID()

        // Start agent
        handler.beginAgentAction(tabID: tabID, agentID: "mcp-agent")
        #expect(handler.controlState(for: tabID).state == .agentActive)

        // Request handoff
        handler.requestAuth(tabID: tabID, reason: "passkey_required")
        let state = handler.controlState(for: tabID)
        #expect(state.state == .awaitingAuth)
        #expect(state.activeAgentID == "mcp-agent")
        #expect(handler.awaitingAuthTabs.contains(tabID))
        #expect(state.authReason == "passkey_required")

        // Complete handoff
        handler.authCompleted(tabID: tabID)
        #expect(handler.controlState(for: tabID).state == .agentActive)
        #expect(!handler.awaitingAuthTabs.contains(tabID))
        #expect(handler.controlState(for: tabID).authReason == nil)
    }

    @Test("requestAuth from idle is no-op")
    @MainActor func requestAuthFromIdle() {
        let handler = TakeoverHandler()
        let tabID = UUID()
        handler.requestAuth(tabID: tabID)
        #expect(handler.controlState(for: tabID).state == .idle)
    }

    @Test("authCompleted from non-awaitingAuth is no-op")
    @MainActor func authCompletedWhenNotAwaiting() {
        let handler = TakeoverHandler()
        let tabID = UUID()
        handler.beginAgentAction(tabID: tabID, agentID: "agent-1")
        handler.authCompleted(tabID: tabID)
        #expect(handler.controlState(for: tabID).state == .agentActive)
    }

    @Test("agentFailed from awaitingAuth transitions to error")
    @MainActor func agentFailedDuringHandoff() {
        let handler = TakeoverHandler()
        let tabID = UUID()
        handler.beginAgentAction(tabID: tabID, agentID: "agent-1")
        handler.requestAuth(tabID: tabID)

        let state = handler.controlState(for: tabID)
        state.agentFailed()

        #expect(state.state == .error)
        #expect(state.authReason == nil)
    }

    @Test("multiple tabs can be in awaitingAuth simultaneously")
    @MainActor func multipleTabsAwaiting() {
        let handler = TakeoverHandler()
        let tab1 = UUID()
        let tab2 = UUID()

        handler.beginAgentAction(tabID: tab1, agentID: "agent-1")
        handler.requestAuth(tabID: tab1)
        handler.beginAgentAction(tabID: tab2, agentID: "agent-2")
        handler.requestAuth(tabID: tab2)

        #expect(handler.awaitingAuthTabs.count == 2)
        #expect(handler.awaitingAuthTabs.contains(tab1))
        #expect(handler.awaitingAuthTabs.contains(tab2))

        // Complete one
        handler.authCompleted(tabID: tab1)
        #expect(handler.awaitingAuthTabs.count == 1)
        #expect(!handler.awaitingAuthTabs.contains(tab1))
        #expect(handler.awaitingAuthTabs.contains(tab2))
    }

    // MARK: - HandoffResult type

    @Test("HandoffResult encodes correctly")
    func handoffResultEncoding() throws {
        let result = HandoffResult(
            ok: true,
            tabId: "tab-123",
            state: "awaiting_auth",
            reason: "passkey_required",
            message: "Agent paused."
        )
        let data = try JSONEncoder().encode(result)
        let decoded = try JSONDecoder().decode(HandoffResult.self, from: data)
        #expect(decoded.ok == true)
        #expect(decoded.tabId == "tab-123")
        #expect(decoded.state == "awaiting_auth")
        #expect(decoded.reason == "passkey_required")
    }

    @Test("HandoffStatusResult encodes correctly")
    func handoffStatusResultEncoding() throws {
        let result = HandoffStatusResult(
            tabId: "tab-456",
            controlState: "awaitingAuth",
            activeAgentId: "agent-1",
            authReason: "biometric"
        )
        let data = try JSONEncoder().encode(result)
        let decoded = try JSONDecoder().decode(HandoffStatusResult.self, from: data)
        #expect(decoded.controlState == "awaitingAuth")
        #expect(decoded.activeAgentId == "agent-1")
        #expect(decoded.authReason == "biometric")
    }
}
