import Testing
import Foundation
@testable import AgentBrowser

/// Tests for BrowserAutomationService dispatch routing and error handling.
///
/// These tests exercise the dispatch layer, error codes, and URL validation
/// WITHOUT requiring page loads or network. WKWebView is instantiated but
/// we only test operations that don't need rendered content (list, get, open,
/// invalid-tab, unknown-method, bad-version).
///
/// Operations that require rendered content (read, eval, screenshot) are
/// validated via the end-to-end integration test against a running browser.
@Suite("AutomationService")
struct AutomationServiceTests {

    // MARK: - Helpers

    @MainActor
    private func makeService() -> (TabManager, BrowserAutomationService) {
        let tm = TabManager()
        let svc = BrowserAutomationService(tabManager: tm)
        return (tm, svc)
    }

    // MARK: - tabs.list

    @Test("tabs.list returns empty for no tabs")
    @MainActor func listEmpty() async {
        let (_, svc) = makeService()
        let resp = await svc.dispatch(AgentRequest(method: "tabs.list"))

        #expect(resp.ok == true)
        // Result should be an array
        if let arr = resp.result?.value as? [Any] {
            #expect(arr.isEmpty)
        }
    }

    @Test("tabs.list returns all tabs with correct fields")
    @MainActor func listTabs() async {
        let (tm, svc) = makeService()
        let t1 = tm.createTab()
        _ = tm.createTab()
        tm.select(tab: t1)

        let resp = await svc.dispatch(AgentRequest(method: "tabs.list"))
        #expect(resp.ok == true)

        if let arr = resp.result?.value as? [Any] {
            #expect(arr.count == 2)
        }
    }

    // MARK: - tabs.get

    @Test("tabs.get returns details for valid tab")
    @MainActor func getValidTab() async {
        let (tm, svc) = makeService()
        let tab = tm.createTab()
        tm.select(tab: tab)

        let resp = await svc.dispatch(AgentRequest(
            method: "tabs.get",
            params: ["id": AnyCodable(tab.id.uuidString)]
        ))

        #expect(resp.ok == true)
        if let dict = resp.result?.value as? [String: Any] {
            #expect(dict["id"] as? String == tab.id.uuidString)
            #expect(dict["isActive"] as? Bool == true)  // changed from Int to Bool
        }
    }

    @Test("tabs.get returns TAB_NOT_FOUND for invalid ID")
    @MainActor func getInvalidTab() async {
        let (_, svc) = makeService()
        _ = AgentRequest(method: "tabs.get", params: ["id": AnyCodable("bogus")])

        let resp = await svc.dispatch(AgentRequest(
            method: "tabs.get",
            params: ["id": AnyCodable("00000000-0000-0000-0000-000000000000")]
        ))

        #expect(resp.ok == false)
        #expect(resp.error?.code == ErrorCode.tabNotFound)
    }

    @Test("tabs.get returns INVALID_PARAMS when id missing")
    @MainActor func getMissingParam() async {
        let (_, svc) = makeService()
        let resp = await svc.dispatch(AgentRequest(method: "tabs.get"))

        #expect(resp.ok == false)
        #expect(resp.error?.code == ErrorCode.invalidParams)
    }

    // MARK: - tabs.open

    @Test("tabs.open creates a tab and returns its ID")
    @MainActor func openURL() async {
        let (tm, svc) = makeService()

        let resp = await svc.dispatch(AgentRequest(
            method: "tabs.open",
            params: ["url": AnyCodable("https://example.com")]
        ))

        #expect(resp.ok == true)
        #expect(tm.tabs.count == 1)

        if let dict = resp.result?.value as? [String: Any] {
            #expect(dict["url"] as? String == "https://example.com")
            #expect(dict["id"] as? String != nil)
        }
    }

    @Test("tabs.open adds https:// to bare domains")
    @MainActor func openBareDomain() async {
        let (tm, svc) = makeService()

        let resp = await svc.dispatch(AgentRequest(
            method: "tabs.open",
            params: ["url": AnyCodable("example.com")]
        ))

        #expect(resp.ok == true)
        #expect(tm.tabs.count == 1)
        if let dict = resp.result?.value as? [String: Any] {
            #expect(dict["url"] as? String == "https://example.com")
        }
    }

    @Test("tabs.open returns INVALID_URL for garbage input")
    @MainActor func openInvalidURL() async {
        let (_, svc) = makeService()

        let resp = await svc.dispatch(AgentRequest(
            method: "tabs.open",
            params: ["url": AnyCodable("not a url at all")]
        ))

        #expect(resp.ok == false)
        #expect(resp.error?.code == ErrorCode.invalidURL)
    }

    @Test("tabs.open returns INVALID_PARAMS when url missing")
    @MainActor func openMissingURL() async {
        let (_, svc) = makeService()
        let resp = await svc.dispatch(AgentRequest(method: "tabs.open"))

        #expect(resp.ok == false)
        #expect(resp.error?.code == ErrorCode.invalidParams)
    }

    // MARK: - Unknown method

    @Test("Unknown method returns UNKNOWN_METHOD")
    @MainActor func unknownMethod() async {
        let (_, svc) = makeService()
        let resp = await svc.dispatch(AgentRequest(method: "tabs.dance"))

        #expect(resp.ok == false)
        #expect(resp.error?.code == ErrorCode.unknownMethod)
    }

    // MARK: - Bad version

    @Test("Wrong protocol version returns BAD_REQUEST")
    @MainActor func badVersion() async {
        let (_, svc) = makeService()

        // Construct a request with version 99
        let json = """
        {"version": 99, "method": "tabs.list"}
        """
        let data = Data(json.utf8)
        let req = try! JSONDecoder().decode(AgentRequest.self, from: data)

        let resp = await svc.dispatch(req)
        #expect(resp.ok == false)
        #expect(resp.error?.code == ErrorCode.badRequest)
    }

    // MARK: - Closed Tab

    @Test("Operations on a closed tab return TAB_NOT_FOUND")
    @MainActor func closedTabOps() async {
        let (tm, svc) = makeService()
        let tab = tm.createTab()
        let id = tab.id.uuidString

        tm.closeTab(tab)

        // get
        let getResp = await svc.dispatch(AgentRequest(
            method: "tabs.get", params: ["id": AnyCodable(id)]
        ))
        #expect(getResp.ok == false)
        #expect(getResp.error?.code == ErrorCode.tabNotFound)

        // read
        let readResp = await svc.dispatch(AgentRequest(
            method: "page.read", params: ["id": AnyCodable(id)]
        ))
        #expect(readResp.ok == false)
        #expect(readResp.error?.code == ErrorCode.tabNotFound)

        // eval
        let evalResp = await svc.dispatch(AgentRequest(
            method: "page.eval", params: ["id": AnyCodable(id), "script": AnyCodable("1+1")]
        ))
        #expect(evalResp.ok == false)
        #expect(evalResp.error?.code == ErrorCode.tabNotFound)

        // screenshot
        let ssResp = await svc.dispatch(AgentRequest(
            method: "page.screenshot", params: ["id": AnyCodable(id)]
        ))
        #expect(ssResp.ok == false)
        #expect(ssResp.error?.code == ErrorCode.tabNotFound)
    }
}
