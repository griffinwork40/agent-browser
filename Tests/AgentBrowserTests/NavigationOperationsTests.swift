import Testing
import Foundation
@testable import AgentBrowser

/// Tests for the Phase 2 navigation and tab-management methods:
///   tabs.close, tabs.switch, tabs.navigate, page.back, page.forward, page.reload
///
/// These test dispatch routing, error codes, and URL validation WITHOUT requiring
/// page loads or network. Operations that require rendered content are tested via
/// the end-to-end integration test against a running browser.
@Suite("NavigationOperations")
struct NavigationOperationsTests {

    // MARK: - Helpers

    @MainActor
    private func makeService() -> (TabManager, BrowserAutomationService) {
        let tm = TabManager()
        let svc = BrowserAutomationService(tabManager: tm, takeoverHandler: TakeoverHandler())
        return (tm, svc)
    }

    // MARK: - tabs.close

    @Test("tabs.close removes the tab and returns closed:true")
    @MainActor func closeTab() async {
        let (tm, svc) = makeService()
        let tab = tm.createTab()
        let id = tab.id.uuidString

        let resp = await svc.dispatch(AgentRequest(
            method: "tabs.close",
            params: ["id": AnyCodable(id)]
        ))

        #expect(resp.ok == true)
        #expect(tm.tabs.isEmpty)
        if let dict = resp.result?.value as? [String: Any] {
            #expect(dict["closed"] as? Bool == true)
            #expect(dict["id"] as? String == id)
        }
    }

    @Test("tabs.close returns TAB_NOT_FOUND for unknown ID")
    @MainActor func closeTabMissing() async {
        let (_, svc) = makeService()
        let resp = await svc.dispatch(AgentRequest(
            method: "tabs.close",
            params: ["id": AnyCodable("00000000-0000-0000-0000-000000000000")]
        ))
        #expect(resp.ok == false)
        #expect(resp.error?.code == ErrorCode.tabNotFound)
    }

    @Test("tabs.close returns INVALID_PARAMS when id missing")
    @MainActor func closeMissingParam() async {
        let (_, svc) = makeService()
        let resp = await svc.dispatch(AgentRequest(method: "tabs.close"))
        #expect(resp.ok == false)
        #expect(resp.error?.code == ErrorCode.invalidParams)
    }

    // MARK: - tabs.switch

    @Test("tabs.switch selects the tab and returns TabDetail with isActive=true")
    @MainActor func switchTab() async {
        let (tm, svc) = makeService()
        let t1 = tm.createTab()
        let t2 = tm.createTab()
        tm.select(tab: t1) // start on t1

        let resp = await svc.dispatch(AgentRequest(
            method: "tabs.switch",
            params: ["id": AnyCodable(t2.id.uuidString)]
        ))

        #expect(resp.ok == true)
        #expect(tm.activeTab?.id == t2.id)
        if let dict = resp.result?.value as? [String: Any] {
            #expect(dict["isActive"] as? Bool == true)
            #expect(dict["id"] as? String == t2.id.uuidString)
        }
    }

    @Test("tabs.switch returns TAB_NOT_FOUND for unknown ID")
    @MainActor func switchTabMissing() async {
        let (_, svc) = makeService()
        let resp = await svc.dispatch(AgentRequest(
            method: "tabs.switch",
            params: ["id": AnyCodable("00000000-0000-0000-0000-000000000000")]
        ))
        #expect(resp.ok == false)
        #expect(resp.error?.code == ErrorCode.tabNotFound)
    }

    // MARK: - tabs.navigate

    @Test("tabs.navigate returns INVALID_URL for file:// scheme")
    @MainActor func navigateBlocksFileScheme() async {
        let (tm, svc) = makeService()
        let tab = tm.createTab()

        let resp = await svc.dispatch(AgentRequest(
            method: "tabs.navigate",
            params: ["id": AnyCodable(tab.id.uuidString), "url": AnyCodable("file:///etc/passwd")]
        ))
        #expect(resp.ok == false)
        #expect(resp.error?.code == ErrorCode.invalidURL)
    }

    @Test("tabs.navigate returns INVALID_URL for javascript: scheme")
    @MainActor func navigateBlocksJSScheme() async {
        let (tm, svc) = makeService()
        let tab = tm.createTab()

        let resp = await svc.dispatch(AgentRequest(
            method: "tabs.navigate",
            params: ["id": AnyCodable(tab.id.uuidString), "url": AnyCodable("javascript:alert(1)")]
        ))
        #expect(resp.ok == false)
        #expect(resp.error?.code == ErrorCode.invalidURL)
    }

    @Test("tabs.navigate returns success for valid https URL")
    @MainActor func navigateValidURL() async {
        let (tm, svc) = makeService()
        let tab = tm.createTab()

        let resp = await svc.dispatch(AgentRequest(
            method: "tabs.navigate",
            params: ["id": AnyCodable(tab.id.uuidString), "url": AnyCodable("https://example.com")]
        ))
        #expect(resp.ok == true)
        if let dict = resp.result?.value as? [String: Any] {
            #expect(dict["url"] as? String == "https://example.com")
            #expect(dict["id"] as? String == tab.id.uuidString)
        }
    }

    @Test("tabs.navigate returns TAB_NOT_FOUND for unknown tab")
    @MainActor func navigateMissingTab() async {
        let (_, svc) = makeService()
        let resp = await svc.dispatch(AgentRequest(
            method: "tabs.navigate",
            params: ["id": AnyCodable("00000000-0000-0000-0000-000000000000"),
                     "url": AnyCodable("https://example.com")]
        ))
        #expect(resp.ok == false)
        #expect(resp.error?.code == ErrorCode.tabNotFound)
    }

    // MARK: - page.back

    @Test("page.back returns INVALID_STATE when no history")
    @MainActor func backNoHistory() async {
        let (tm, svc) = makeService()
        let tab = tm.createTab()

        let resp = await svc.dispatch(AgentRequest(
            method: "page.back",
            params: ["id": AnyCodable(tab.id.uuidString)]
        ))
        #expect(resp.ok == false)
        #expect(resp.error?.code == ErrorCode.invalidState)
    }

    @Test("page.back returns TAB_NOT_FOUND for unknown tab")
    @MainActor func backMissingTab() async {
        let (_, svc) = makeService()
        let resp = await svc.dispatch(AgentRequest(
            method: "page.back",
            params: ["id": AnyCodable("00000000-0000-0000-0000-000000000000")]
        ))
        #expect(resp.ok == false)
        #expect(resp.error?.code == ErrorCode.tabNotFound)
    }

    // MARK: - page.forward

    @Test("page.forward returns INVALID_STATE when no forward history")
    @MainActor func forwardNoHistory() async {
        let (tm, svc) = makeService()
        let tab = tm.createTab()

        let resp = await svc.dispatch(AgentRequest(
            method: "page.forward",
            params: ["id": AnyCodable(tab.id.uuidString)]
        ))
        #expect(resp.ok == false)
        #expect(resp.error?.code == ErrorCode.invalidState)
    }

    @Test("page.forward returns TAB_NOT_FOUND for unknown tab")
    @MainActor func forwardMissingTab() async {
        let (_, svc) = makeService()
        let resp = await svc.dispatch(AgentRequest(
            method: "page.forward",
            params: ["id": AnyCodable("00000000-0000-0000-0000-000000000000")]
        ))
        #expect(resp.ok == false)
        #expect(resp.error?.code == ErrorCode.tabNotFound)
    }

    // MARK: - page.reload

    @Test("page.reload returns success with action=reload")
    @MainActor func reloadTab() async {
        let (tm, svc) = makeService()
        let tab = tm.createTab()

        let resp = await svc.dispatch(AgentRequest(
            method: "page.reload",
            params: ["id": AnyCodable(tab.id.uuidString)]
        ))
        #expect(resp.ok == true)
        if let dict = resp.result?.value as? [String: Any] {
            #expect(dict["action"] as? String == "reload")
            #expect(dict["id"] as? String == tab.id.uuidString)
        }
    }

    @Test("page.reload returns TAB_NOT_FOUND for unknown tab")
    @MainActor func reloadMissingTab() async {
        let (_, svc) = makeService()
        let resp = await svc.dispatch(AgentRequest(
            method: "page.reload",
            params: ["id": AnyCodable("00000000-0000-0000-0000-000000000000")]
        ))
        #expect(resp.ok == false)
        #expect(resp.error?.code == ErrorCode.tabNotFound)
    }
}
