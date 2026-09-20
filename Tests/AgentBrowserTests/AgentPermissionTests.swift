import Testing
import Foundation
@testable import AgentBrowser

// MARK: - AgentPermissionStore tests
//
// Pure logic tests — no WebKit, no network. Exercises:
//  • Default full permissions for unknown agent
//  • Set / get round-trip
//  • Method-to-capability mapping for every category
//  • Read-only preset denies write/click/navigate/eval
//  • noEval preset denies eval only
//  • Domain allowlist field round-trips through Codable
//  • Permission management methods are always allowed
//  • Integration: dispatch returns PERMISSION_DENIED for a restricted agent

@Suite("AgentPermissions")
struct AgentPermissionTests {

    // MARK: - Helpers

    @MainActor
    private func makeStore() -> AgentPermissionStore { AgentPermissionStore() }

    @MainActor
    private func makeService(store: AgentPermissionStore) -> BrowserAutomationService {
        BrowserAutomationService(
            tabManager: TabManager(),
            takeoverHandler: TakeoverHandler(),
            permissionStore: store
        )
    }

    // MARK: - Default permissions

    @Test("Unknown agent gets full permissions by default")
    @MainActor func defaultFull() {
        let store = makeStore()
        let perms = store.permissions(for: "unknown-agent")
        #expect(perms.canRead == true)
        #expect(perms.canWrite == true)
        #expect(perms.canClick == true)
        #expect(perms.canNavigate == true)
        #expect(perms.canEval == true)
        #expect(perms.allowedDomains == nil)
    }

    // MARK: - Set / get round-trip

    @Test("setPermissions / permissions round-trip")
    @MainActor func setGetRoundTrip() {
        let store = makeStore()
        var perms = AgentPermissionSet.readOnly
        perms.allowedDomains = ["example.com", "api.example.com"]
        store.setPermissions(for: "agent-A", perms)

        let fetched = store.permissions(for: "agent-A")
        #expect(fetched.canRead == true)
        #expect(fetched.canWrite == false)
        #expect(fetched.canClick == false)
        #expect(fetched.canNavigate == false)
        #expect(fetched.canEval == false)
        #expect(fetched.allowedDomains == ["example.com", "api.example.com"])
    }

    @Test("Different agents have independent permission sets")
    @MainActor func independentAgents() {
        let store = makeStore()
        store.setPermissions(for: "reader", .readOnly)
        store.setPermissions(for: "writer", .full)

        #expect(store.permissions(for: "reader").canClick == false)
        #expect(store.permissions(for: "writer").canClick == true)
    }

    // MARK: - Static presets

    @Test("AgentPermissionSet.full has all capabilities")
    func presetFull() {
        let p = AgentPermissionSet.full
        #expect(p.canRead && p.canWrite && p.canClick && p.canNavigate && p.canEval)
        #expect(p.allowedDomains == nil)
    }

    @Test("AgentPermissionSet.readOnly has canRead only")
    func presetReadOnly() {
        let p = AgentPermissionSet.readOnly
        #expect(p.canRead == true)
        #expect(p.canWrite == false)
        #expect(p.canClick == false)
        #expect(p.canNavigate == false)
        #expect(p.canEval == false)
    }

    @Test("AgentPermissionSet.noEval denies eval only")
    func presetNoEval() {
        let p = AgentPermissionSet.noEval
        #expect(p.canRead && p.canWrite && p.canClick && p.canNavigate)
        #expect(p.canEval == false)
    }

    // MARK: - checkPermission: read capability

    @Test("page.read requires canRead")
    @MainActor func checkRead() {
        let store = makeStore()
        store.setPermissions(for: "ro", .readOnly)
        // read-only agent should pass page.read
        if case .failure = store.checkPermission(agentID: "ro", method: "page.read") {
            Issue.record("page.read should be allowed for readOnly agent")
        }
    }

    @Test("page.screenshot requires canRead")
    @MainActor func checkScreenshot() {
        let store = makeStore()
        store.setPermissions(for: "ro", .readOnly)
        if case .failure = store.checkPermission(agentID: "ro", method: "page.screenshot") {
            Issue.record("page.screenshot should be allowed for readOnly agent")
        }
    }

    @Test("page.read is denied when canRead is false")
    @MainActor func checkReadDenied() {
        let store = makeStore()
        store.setPermissions(for: "noread", AgentPermissionSet(
            canRead: false, canWrite: true, canClick: true, canNavigate: true, canEval: true
        ))
        if case .success = store.checkPermission(agentID: "noread", method: "page.read") {
            Issue.record("page.read should be denied when canRead is false")
        }
    }

    // MARK: - checkPermission: click capability

    @Test("page.click requires canClick — denied for readOnly")
    @MainActor func checkClickDenied() {
        let store = makeStore()
        store.setPermissions(for: "ro", .readOnly)
        if case .success = store.checkPermission(agentID: "ro", method: "page.click") {
            Issue.record("page.click should be denied for readOnly agent")
        }
    }

    @Test("page.fill requires canClick — denied for readOnly")
    @MainActor func checkFillDenied() {
        let store = makeStore()
        store.setPermissions(for: "ro", .readOnly)
        if case .success = store.checkPermission(agentID: "ro", method: "page.fill") {
            Issue.record("page.fill should be denied for readOnly agent")
        }
    }

    @Test("page.press requires canClick — denied for readOnly")
    @MainActor func checkPressDenied() {
        let store = makeStore()
        store.setPermissions(for: "ro", .readOnly)
        if case .success = store.checkPermission(agentID: "ro", method: "page.press") {
            Issue.record("page.press should be denied for readOnly agent")
        }
    }

    @Test("page.select requires canClick — denied for readOnly")
    @MainActor func checkSelectDenied() {
        let store = makeStore()
        store.setPermissions(for: "ro", .readOnly)
        if case .success = store.checkPermission(agentID: "ro", method: "page.select") {
            Issue.record("page.select should be denied for readOnly agent")
        }
    }

    // MARK: - checkPermission: eval capability

    @Test("page.eval requires canEval — denied for noEval preset")
    @MainActor func checkEvalDenied() {
        let store = makeStore()
        store.setPermissions(for: "safe", .noEval)
        if case .success = store.checkPermission(agentID: "safe", method: "page.eval") {
            Issue.record("page.eval should be denied for noEval agent")
        }
    }

    @Test("page.eval passes for full preset")
    @MainActor func checkEvalAllowed() {
        let store = makeStore()
        store.setPermissions(for: "full", .full)
        if case .failure = store.checkPermission(agentID: "full", method: "page.eval") {
            Issue.record("page.eval should pass for full agent")
        }
    }

    // MARK: - checkPermission: navigate capability

    @Test("tabs.open requires canNavigate — denied for readOnly")
    @MainActor func checkNavigateDenied() {
        let store = makeStore()
        store.setPermissions(for: "ro", .readOnly)
        if case .success = store.checkPermission(agentID: "ro", method: "tabs.open") {
            Issue.record("tabs.open should be denied for readOnly agent")
        }
    }

    @Test("tabs.navigate requires canNavigate — denied for readOnly")
    @MainActor func checkTabsNavigateDenied() {
        let store = makeStore()
        store.setPermissions(for: "ro", .readOnly)
        if case .success = store.checkPermission(agentID: "ro", method: "tabs.navigate") {
            Issue.record("tabs.navigate should be denied for readOnly agent")
        }
    }

    // MARK: - Permission management methods always allowed

    @Test("agent.permissions.get is always permitted")
    @MainActor func permissionsGetAlwaysAllowed() {
        let store = makeStore()
        store.setPermissions(for: "restricted", AgentPermissionSet(
            canRead: false, canWrite: false, canClick: false, canNavigate: false, canEval: false
        ))
        if case .failure = store.checkPermission(agentID: "restricted", method: "agent.permissions.get") {
            Issue.record("agent.permissions.get should always be allowed")
        }
    }

    @Test("agent.permissions.set is always permitted")
    @MainActor func permissionsSetAlwaysAllowed() {
        let store = makeStore()
        store.setPermissions(for: "restricted", AgentPermissionSet(
            canRead: false, canWrite: false, canClick: false, canNavigate: false, canEval: false
        ))
        if case .failure = store.checkPermission(agentID: "restricted", method: "agent.permissions.set") {
            Issue.record("agent.permissions.set should always be allowed")
        }
    }

    // MARK: - Codable round-trip (domain allowlist)

    @Test("AgentPermissionSet Codable round-trips with allowedDomains")
    func codableRoundTrip() throws {
        var perms = AgentPermissionSet.readOnly
        perms.allowedDomains = ["trusted.com"]
        let data = try JSONEncoder().encode(perms)
        let decoded = try JSONDecoder().decode(AgentPermissionSet.self, from: data)
        #expect(decoded.canRead == true)
        #expect(decoded.canEval == false)
        #expect(decoded.allowedDomains == ["trusted.com"])
    }

    @Test("AgentPermissionSet Codable round-trips with nil allowedDomains")
    func codableNilDomains() throws {
        let perms = AgentPermissionSet.full
        let data = try JSONEncoder().encode(perms)
        let decoded = try JSONDecoder().decode(AgentPermissionSet.self, from: data)
        #expect(decoded.allowedDomains == nil)
    }

    // MARK: - Integration: dispatch returns PERMISSION_DENIED

    @Test("dispatch returns PERMISSION_DENIED for restricted agent on page.eval")
    @MainActor func dispatchDeniesEval() async {
        let store = makeStore()
        store.setPermissions(for: "safe-bot", .noEval)
        let svc = makeService(store: store)

        let resp = await svc.dispatch(AgentRequest(
            method: "page.eval",
            params: [
                "agentID": AnyCodable("safe-bot"),
                "id": AnyCodable("any-tab"),
                "script": AnyCodable("1+1")
            ]
        ))
        #expect(resp.ok == false)
        #expect(resp.error?.code == ErrorCode.permissionDenied)
    }

    @Test("dispatch returns PERMISSION_DENIED for readOnly agent on tabs.open")
    @MainActor func dispatchDeniesNavigate() async {
        let store = makeStore()
        store.setPermissions(for: "reader-bot", .readOnly)
        let svc = makeService(store: store)

        let resp = await svc.dispatch(AgentRequest(
            method: "tabs.open",
            params: [
                "agentID": AnyCodable("reader-bot"),
                "url": AnyCodable("https://example.com")
            ]
        ))
        #expect(resp.ok == false)
        #expect(resp.error?.code == ErrorCode.permissionDenied)
    }

    @Test("dispatch allows readOnly agent to call tabs.list")
    @MainActor func dispatchAllowsReadForReadOnly() async {
        let store = makeStore()
        store.setPermissions(for: "reader-bot", .readOnly)
        let svc = makeService(store: store)

        let resp = await svc.dispatch(AgentRequest(
            method: "tabs.list",
            params: ["agentID": AnyCodable("reader-bot")]
        ))
        // tabs.list itself requires canRead — readOnly has it, so dispatch succeeds
        #expect(resp.ok == true)
    }

    @Test("dispatch: agent.permissions.get returns current permissions")
    @MainActor func dispatchGetPermissions() async {
        let store = makeStore()
        store.setPermissions(for: "bot", .readOnly)
        let svc = makeService(store: store)

        let resp = await svc.dispatch(AgentRequest(
            method: "agent.permissions.get",
            params: ["agentID": AnyCodable("bot")]
        ))
        #expect(resp.ok == true)
        if let dict = resp.result?.value as? [String: Any] {
            #expect(dict["canRead"] as? Bool == true)
            #expect(dict["canEval"] as? Bool == false)
        }
    }
}
