import AppKit
import WebKit

// MARK: - Passkey / WebAuthn Handoff
//
// Exposes the TakeoverHandler's awaitingAuth state machine to the agent API.
// When an agent detects a passkey or WebAuthn ceremony, it calls
// auth.requestHandoff to pause itself and let the human complete the
// biometric challenge in the live browser. After the human finishes,
// the agent (or auto-detection) calls auth.completeHandoff to resume.
//
// Separated from BrowserAutomationService.swift per the 350 LOC rule.

extension BrowserAutomationService {

    // MARK: - Request Handoff

    /// Agent requests human handoff for authentication.
    /// Transitions the tab to awaitingAuth so the human can complete
    /// passkey/WebAuthn/biometric auth in the live browser.
    func requestHandoffCallback(
        tabId: String,
        reason: String?,
        completion: @escaping (AgentResponse) -> Void
    ) {
        guard let tab = resolveTab(tabId) else {
            completion(.failure(
                code: ErrorCode.tabNotFound,
                message: "No tab with id: \(tabId)"
            ))
            return
        }

        let state = takeoverHandler.controlState(for: tab.id)

        // Must have an active agent to hand off from
        guard state.state == .agentActive else {
            completion(.failure(
                code: ErrorCode.invalidState,
                message: "Tab is not agent-controlled (state: \(state.state.rawValue)). "
                    + "Call browser_open or start an agent action first."
            ))
            return
        }

        takeoverHandler.requestAuth(tabID: tab.id)
        completion(.success(HandoffResult(
            ok: true,
            tabId: tabId,
            state: "awaiting_auth",
            reason: reason,
            message: "Agent paused. Human should complete authentication "
                + "in the browser, then call browser_auth_completed."
        )))
    }

    /// Async variant of requestHandoff.
    func requestHandoffResponse(tabId: String, reason: String?) async -> AgentResponse {
        guard let tab = resolveTab(tabId) else {
            return .failure(
                code: ErrorCode.tabNotFound,
                message: "No tab with id: \(tabId)"
            )
        }

        let state = takeoverHandler.controlState(for: tab.id)
        guard state.state == .agentActive else {
            return .failure(
                code: ErrorCode.invalidState,
                message: "Tab is not agent-controlled (state: \(state.state.rawValue)). "
                    + "Call browser_open or start an agent action first."
            )
        }

        takeoverHandler.requestAuth(tabID: tab.id)
        return .success(HandoffResult(
            ok: true,
            tabId: tabId,
            state: "awaiting_auth",
            reason: reason,
            message: "Agent paused. Human should complete authentication "
                + "in the browser, then call browser_auth_completed."
        ))
    }

    // MARK: - Complete Handoff

    /// Human (or auto-detection) signals that authentication is complete.
    /// Resumes the agent on the tab.
    func completeHandoffCallback(
        tabId: String,
        completion: @escaping (AgentResponse) -> Void
    ) {
        guard let tab = resolveTab(tabId) else {
            completion(.failure(
                code: ErrorCode.tabNotFound,
                message: "No tab with id: \(tabId)"
            ))
            return
        }

        let state = takeoverHandler.controlState(for: tab.id)
        guard state.state == .awaitingAuth else {
            completion(.failure(
                code: ErrorCode.invalidState,
                message: "Tab is not awaiting auth (state: \(state.state.rawValue)). "
                    + "Nothing to resume."
            ))
            return
        }

        takeoverHandler.authCompleted(tabID: tab.id)
        completion(.success(HandoffResult(
            ok: true,
            tabId: tabId,
            state: "agent_active",
            reason: nil,
            message: "Authentication complete. Agent resumed."
        )))
    }

    /// Async variant of completeHandoff.
    func completeHandoffResponse(tabId: String) async -> AgentResponse {
        guard let tab = resolveTab(tabId) else {
            return .failure(
                code: ErrorCode.tabNotFound,
                message: "No tab with id: \(tabId)"
            )
        }

        let state = takeoverHandler.controlState(for: tab.id)
        guard state.state == .awaitingAuth else {
            return .failure(
                code: ErrorCode.invalidState,
                message: "Tab is not awaiting auth (state: \(state.state.rawValue)). "
                    + "Nothing to resume."
            )
        }

        takeoverHandler.authCompleted(tabID: tab.id)
        return .success(HandoffResult(
            ok: true,
            tabId: tabId,
            state: "agent_active",
            reason: nil,
            message: "Authentication complete. Agent resumed."
        ))
    }

    // MARK: - Handoff Status

    /// Check the auth handoff state for a tab.
    func handoffStatusResponse(tabId: String) -> AgentResponse {
        guard let tab = resolveTab(tabId) else {
            return .failure(
                code: ErrorCode.tabNotFound,
                message: "No tab with id: \(tabId)"
            )
        }
        let state = takeoverHandler.controlState(for: tab.id)
        return .success(HandoffStatusResult(
            tabId: tabId,
            controlState: state.state.rawValue,
            activeAgentId: state.activeAgentID,
            authReason: state.authReason
        ))
    }
}

// MARK: - Result Types

struct HandoffResult: Codable, Sendable {
    let ok: Bool
    let tabId: String
    let state: String
    let reason: String?
    let message: String
}

struct HandoffStatusResult: Codable, Sendable {
    let tabId: String
    let controlState: String
    let activeAgentId: String?
    let authReason: String?
}
