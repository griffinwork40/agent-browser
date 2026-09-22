import Foundation
import Testing
@testable import AgentBrowser

// MARK: - Auth Wall Interceptor Tests
//
// Tests for automatic auth-wall detection, session-expiry detection,
// and telemetry recording (Issue #15).

@Suite("AuthWallInterceptor")
struct AuthWallInterceptorTests {

    // MARK: - AuthWallTelemetry

    @Test("recordWall increments totalWallsHit")
    @MainActor func telemetryRecordWallIncrements() {
        let telemetry = AuthWallTelemetry()
        let before = telemetry.totalWallsHit

        telemetry.recordWall(url: URL(string: "https://example.com/login"), status: "login_required")

        #expect(telemetry.totalWallsHit == before + 1)
    }

    @Test("recordWall tracks per-domain stats")
    @MainActor func telemetryPerDomainStats() {
        let telemetry = AuthWallTelemetry()
        let url = URL(string: "https://github.com/login")

        telemetry.recordWall(url: url, status: "login_required")

        let stats = telemetry.byDomain["github.com"]
        #expect(stats != nil)
        #expect(stats?.wallsHit == 1)
        #expect(stats?.lastStatus == "login_required")
    }

    @Test("recordCompletion increments completions for correct domain")
    @MainActor func telemetryRecordCompletion() {
        let telemetry = AuthWallTelemetry()
        let url = URL(string: "https://github.com/login")

        telemetry.recordWall(url: url, status: "login_required")
        telemetry.recordCompletion(url: url)

        #expect(telemetry.totalCompletions == 1)
        #expect(telemetry.byDomain["github.com"]?.completions == 1)
    }

    @Test("recordAbandonment increments abandonments for correct domain")
    @MainActor func telemetryRecordAbandonment() {
        let telemetry = AuthWallTelemetry()
        let url = URL(string: "https://example.com/login")

        telemetry.recordWall(url: url, status: "login_required")
        telemetry.recordAbandonment(url: url)

        #expect(telemetry.totalAbandonments == 1)
        #expect(telemetry.byDomain["example.com"]?.abandonments == 1)
    }

    @Test("Multiple walls on same domain accumulate")
    @MainActor func telemetryAccumulateSameDomain() {
        let telemetry = AuthWallTelemetry()
        let url = URL(string: "https://app.stripe.com/login")

        telemetry.recordWall(url: url, status: "login_required")
        telemetry.recordWall(url: url, status: "session_expired")

        #expect(telemetry.totalWallsHit == 2)
        #expect(telemetry.byDomain["stripe.com"]?.wallsHit == 2)
    }

    @Test("recordWall with nil URL uses (unknown) key")
    @MainActor func telemetryNilURL() {
        let telemetry = AuthWallTelemetry()

        telemetry.recordWall(url: nil, status: "login_required")

        #expect(telemetry.byDomain["(unknown)"] != nil)
    }

    @Test("summary reflects aggregated counts")
    @MainActor func telemetrySummary() {
        let telemetry = AuthWallTelemetry()
        telemetry.recordWall(url: URL(string: "https://github.com/login"), status: "login_required")
        telemetry.recordCompletion(url: URL(string: "https://github.com/login"))

        #expect(telemetry.summary.contains("hits=1"))
        #expect(telemetry.summary.contains("completions=1"))
    }

    // MARK: - AuthWallInterceptorState

    @Test("markAuthenticated sets wasAuthenticated to true")
    @MainActor func stateMarkAuthenticated() {
        let state = AuthWallInterceptorState()
        let id = UUID()
        let url = URL(string: "https://example.com/dashboard")

        state.markAuthenticated(tabID: id, url: url)

        #expect(state.wasAuthenticated(tabID: id) == true)
    }

    @Test("clearAuthenticated sets wasAuthenticated to false")
    @MainActor func stateClearAuthenticated() {
        let state = AuthWallInterceptorState()
        let id = UUID()

        state.markAuthenticated(tabID: id, url: URL(string: "https://example.com"))
        state.clearAuthenticated(tabID: id)

        #expect(state.wasAuthenticated(tabID: id) == false)
    }

    @Test("wasAuthenticated returns false for unknown tab")
    @MainActor func stateUnknownTab() {
        let state = AuthWallInterceptorState()
        #expect(state.wasAuthenticated(tabID: UUID()) == false)
    }

    @Test("removeTab makes wasAuthenticated return false")
    @MainActor func stateRemoveTab() {
        let state = AuthWallInterceptorState()
        let id = UUID()

        state.markAuthenticated(tabID: id, url: nil)
        state.removeTab(tabID: id)

        #expect(state.wasAuthenticated(tabID: id) == false)
    }

    // MARK: - AuthRequiredError

    @Test("AuthRequiredError encodes and decodes correctly")
    func authRequiredErrorCodable() throws {
        let error = AuthRequiredError(
            tabId: "test-tab",
            authStatus: "login_required",
            url: "https://example.com/login",
            title: "Login",
            signals: [["type": "url_pattern", "detail": "/login"]],
            message: "Auth wall detected"
        )

        let data = try JSONEncoder().encode(error)
        let decoded = try JSONDecoder().decode(AuthRequiredError.self, from: data)

        #expect(decoded.tabId == "test-tab")
        #expect(decoded.authStatus == "login_required")
        #expect(decoded.url == "https://example.com/login")
        #expect(decoded.title == "Login")
        #expect(decoded.signals.count == 1)
        #expect(decoded.signals[0]["type"] == "url_pattern")
    }

    // MARK: - ErrorCode.authRequired

    @Test("ErrorCode.authRequired constant is AUTH_REQUIRED")
    func errorCodeConstant() {
        #expect(ErrorCode.authRequired == "AUTH_REQUIRED")
    }

    // MARK: - eTLD+1 extraction (via telemetry)

    @Test("eTLD+1 for subdomain.example.com is example.com")
    @MainActor func eTLDSubdomain() {
        let telemetry = AuthWallTelemetry()
        telemetry.recordWall(url: URL(string: "https://app.example.com/login"), status: "login_required")
        #expect(telemetry.byDomain["example.com"] != nil)
    }

    @Test("eTLD+1 for bare hostname falls back to hostname")
    @MainActor func eTLDBareHost() {
        let telemetry = AuthWallTelemetry()
        telemetry.recordWall(url: URL(string: "https://localhost/login"), status: "login_required")
        #expect(telemetry.byDomain["localhost"] != nil)
    }
}
