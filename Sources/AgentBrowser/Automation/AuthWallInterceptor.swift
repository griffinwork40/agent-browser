import AppKit
import WebKit

// MARK: - Auth Wall Interceptor
//
// Provides automatic auth-wall detection that runs BEFORE page interactions
// (browser_read, browser_inspect, browser_click). When an auth wall is detected:
//   1. The tab transitions to awaitingAuth automatically (no agent call needed).
//   2. An AUTH_REQUIRED error is returned with the detection signals.
//   3. Telemetry is recorded.
//
// Session-expiry detection runs after navigation completes. If the tab was
// previously on an authenticated page and ends up on a login URL, we surface
// a `session_expired` status to the agent.
//
// Non-goals (per Issue #15): credential filling, passkey/WebAuthn interception.

// MARK: - Auth-Required Error Result

/// Structured error payload returned when an auth wall is intercepted.
struct AuthRequiredError: Codable, Sendable {
    let tabId: String
    let authStatus: String        // login_required | session_expired | mfa_required |
                                  // captcha_blocked | paywall | passkey_required
    let url: String
    let title: String
    let signals: [[String: String]]
    let message: String
}

// MARK: - Auth-Wall States Tracked Per Tab
// Note: ErrorCode.authRequired ("AUTH_REQUIRED") is declared in KeychainFill.swift.

/// Lightweight per-tab auth tracking. Held inside AuthWallInterceptor.
struct AuthWallTabState: Sendable {
    /// Whether the tab was last seen on an authenticated page.
    var wasAuthenticated: Bool = false
    /// The URL of the last confirmed-authenticated page.
    var lastAuthenticatedURL: URL?
}

// MARK: - Interceptor

extension BrowserAutomationService {

    // MARK: - Pre-Interaction Check

    /// Run a lightweight auth check before a page interaction.
    ///
    /// If the page is an auth wall:
    ///   - Transitions the tab to `.awaitingAuth` (if the agent is `.agentActive`).
    ///   - Records telemetry.
    ///   - Returns a `.failure(AUTH_REQUIRED, …)` response.
    ///
    /// If the page is clean, returns `nil` and the caller proceeds normally.
    func checkAuthWallBeforeInteraction(
        tab: BrowserTab, operation: String
    ) async -> AgentResponse? {
        // Run the detection script.
        let authResult: AuthStatusResult
        switch await runAuthDetection(on: tab) {
        case .failure:
            // Detection failed (JS error, bridge not loaded, etc.) — let the
            // caller proceed. We never block on a detection failure.
            return nil
        case .success(let r):
            authResult = r
        }

        // "authenticated" and "unknown" pass through.
        let blockedStatuses: Set<String> = [
            "login_required", "session_expired", "mfa_required",
            "captcha_blocked", "paywall", "passkey_required"
        ]
        guard blockedStatuses.contains(authResult.status) else {
            // Page is clean — update the "was authenticated" marker.
            AuthWallInterceptorState.shared.markAuthenticated(tabID: tab.id, url: tab.url)
            return nil
        }

        // Auth wall detected — record telemetry.
        AuthWallTelemetry.shared.recordWall(url: tab.url, status: authResult.status)

        // Transition to awaitingAuth if the agent is currently active.
        let controlState = takeoverHandler.controlState(for: tab.id)
        if controlState.state == .agentActive {
            let reason = "\(authResult.status) detected automatically before \(operation)"
            takeoverHandler.requestAuth(tabID: tab.id, reason: reason)
        }

        let payload = AuthRequiredError(
            tabId: tab.id.uuidString,
            authStatus: authResult.status,
            url: authResult.url,
            title: authResult.title,
            signals: authResult.signals,
            message: authWallMessage(status: authResult.status, operation: operation)
        )
        return .failure(code: ErrorCode.authRequired, message: payload.message)
    }

    // MARK: - Session-Expiry Detection

    /// Called after navigation completes. Checks whether we have transitioned from
    /// an authenticated page to an auth wall (session expired / redirect).
    ///
    /// If detected, transitions to `.awaitingAuth` and records telemetry.
    func checkSessionExpiryAfterNavigation(tab: BrowserTab) async {
        // Only check if we were previously on an authenticated page.
        guard AuthWallInterceptorState.shared.wasAuthenticated(tabID: tab.id) else { return }

        let authResult: AuthStatusResult
        switch await runAuthDetection(on: tab) {
        case .failure:
            return  // Detection failed — don't treat as expiry.
        case .success(let r):
            authResult = r
        }

        // Session-expiry heuristic: was authenticated, now on a login page.
        let sessionExpiredStatuses: Set<String> = ["login_required", "session_expired"]
        guard sessionExpiredStatuses.contains(authResult.status) else {
            // Still (or newly) authenticated — update marker.
            if authResult.status == "authenticated" {
                AuthWallInterceptorState.shared.markAuthenticated(tabID: tab.id, url: tab.url)
            }
            return
        }

        // Session expiry confirmed.
        AuthWallTelemetry.shared.recordWall(url: tab.url, status: "session_expired")
        AuthWallInterceptorState.shared.clearAuthenticated(tabID: tab.id)

        // Transition to awaitingAuth if agent is active.
        let controlState = takeoverHandler.controlState(for: tab.id)
        if controlState.state == .agentActive {
            takeoverHandler.requestAuth(
                tabID: tab.id,
                reason: "session_expired: redirected from authenticated content to auth wall"
            )
        }
    }

    // MARK: - Private Helpers

    /// Run auth detection on a tab and return a typed result.
    private func runAuthDetection(
        on tab: BrowserTab
    ) async -> Result<AuthStatusResult, Error> {
        do {
            let raw = try await evalJSOnTabInBridgeWorld(tab, script: Self.authDetectionScript)
            guard let jsonString = raw as? String,
                  let data = jsonString.data(using: .utf8),
                  let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                struct ParseError: Error {}
                return .failure(ParseError())
            }
            return .success(AuthStatusResult(from: dict))
        } catch {
            return .failure(error)
        }
    }

    /// Human-readable message included in the AUTH_REQUIRED error.
    private func authWallMessage(status: String, operation: String) -> String {
        switch status {
        case "login_required":
            return "Page requires login. \(operation.capitalized) blocked. "
                + "Human should authenticate in the browser, then call browser_auth_completed."
        case "session_expired":
            return "Session expired — redirected to login page. \(operation.capitalized) blocked. "
                + "Human should re-authenticate, then call browser_auth_completed."
        case "mfa_required":
            return "MFA required. \(operation.capitalized) blocked. "
                + "Human should complete the MFA challenge, then call browser_auth_completed."
        case "captcha_blocked":
            return "CAPTCHA detected. \(operation.capitalized) blocked. "
                + "Human should solve the CAPTCHA, then call browser_auth_completed."
        case "paywall":
            return "Paywall detected. \(operation.capitalized) blocked. "
                + "Human should handle subscription access, then call browser_auth_completed."
        case "passkey_required":
            return "Passkey / WebAuthn required. \(operation.capitalized) blocked. "
                + "Human should complete the passkey ceremony, then call browser_auth_completed."
        default:
            return "Auth wall detected (\(status)). \(operation.capitalized) blocked. "
                + "Human should authenticate, then call browser_auth_completed."
        }
    }
}

// MARK: - Per-Tab Auth State (shared across the interceptor)

/// Singleton holding lightweight per-tab auth-wall tracking.
/// @MainActor because all access is from the automation service.
@MainActor
final class AuthWallInterceptorState {
    static let shared = AuthWallInterceptorState()

    private var tabStates: [UUID: AuthWallTabState] = [:]

    func wasAuthenticated(tabID: UUID) -> Bool {
        tabStates[tabID]?.wasAuthenticated ?? false
    }

    func markAuthenticated(tabID: UUID, url: URL?) {
        var state = tabStates[tabID] ?? AuthWallTabState()
        state.wasAuthenticated = true
        state.lastAuthenticatedURL = url
        tabStates[tabID] = state
    }

    func clearAuthenticated(tabID: UUID) {
        tabStates[tabID]?.wasAuthenticated = false
    }

    func removeTab(tabID: UUID) {
        tabStates.removeValue(forKey: tabID)
    }
}
