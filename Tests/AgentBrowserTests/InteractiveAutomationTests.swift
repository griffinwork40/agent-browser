import Testing
@testable import AgentBrowser

/// Tests for the interactive automation layer (inspect, click, fill, press, select, wait).
///
/// These test protocol routing, parameter validation, error codes, and response shapes.
/// DOM-dependent operations (actual inspect/click on a real page) require WKWebView and
/// are validated in integration tests, not here.
@Suite("Interactive Automation")
@MainActor
struct InteractiveAutomationTests {

    private func makeService() -> (TabManager, BrowserAutomationService) {
        let tm = TabManager()
        let svc = BrowserAutomationService(tabManager: tm)
        return (tm, svc)
    }

    // MARK: - page.inspect

    @Test("page.inspect requires id parameter")
    func inspectMissingId() async {
        let (_, svc) = makeService()
        let resp = await svc.dispatch(AgentRequest(method: "page.inspect"))
        #expect(!resp.ok)
        #expect(resp.error?.code == ErrorCode.invalidParams)
    }

    @Test("page.inspect returns TAB_NOT_FOUND for bad id")
    func inspectBadTab() async {
        let (_, svc) = makeService()
        let resp = await svc.dispatch(AgentRequest(method: "page.inspect", params: [
            "id": AnyCodable("00000000-0000-0000-0000-000000000000")
        ]))
        #expect(!resp.ok)
        #expect(resp.error?.code == ErrorCode.tabNotFound)
    }

    // MARK: - page.click

    @Test("page.click requires id and elementId")
    func clickMissingParams() async {
        let (_, svc) = makeService()
        let resp = await svc.dispatch(AgentRequest(method: "page.click", params: [
            "id": AnyCodable("some-id")
        ]))
        #expect(!resp.ok)
        #expect(resp.error?.code == ErrorCode.invalidParams)
    }

    @Test("page.click returns TAB_NOT_FOUND for bad id")
    func clickBadTab() async {
        let (_, svc) = makeService()
        let resp = await svc.dispatch(AgentRequest(method: "page.click", params: [
            "id": AnyCodable("00000000-0000-0000-0000-000000000000"),
            "elementId": AnyCodable("el_abc123")
        ]))
        #expect(!resp.ok)
        #expect(resp.error?.code == ErrorCode.tabNotFound)
    }

    // MARK: - page.fill

    @Test("page.fill requires id, elementId, and value")
    func fillMissingParams() async {
        let (_, svc) = makeService()
        // Missing value param -> INVALID_PARAMS (checked before tab resolution)
        let resp = await svc.dispatch(AgentRequest(method: "page.fill", params: [
            "id": AnyCodable("00000000-0000-0000-0000-000000000000"),
            "elementId": AnyCodable("el_abc123")
        ]))
        #expect(!resp.ok)
        #expect(resp.error?.code == ErrorCode.invalidParams)
    }

    @Test("page.fill returns TAB_NOT_FOUND for bad id")
    func fillBadTab() async {
        let (_, svc) = makeService()
        let resp = await svc.dispatch(AgentRequest(method: "page.fill", params: [
            "id": AnyCodable("00000000-0000-0000-0000-000000000000"),
            "elementId": AnyCodable("el_abc123"),
            "value": AnyCodable("test")
        ]))
        #expect(!resp.ok)
        #expect(resp.error?.code == ErrorCode.tabNotFound)
    }

    // MARK: - page.press

    @Test("page.press requires id and key")
    func pressMissingKey() async {
        let (_, svc) = makeService()
        // Missing key param -> INVALID_PARAMS (checked before tab resolution)
        let resp = await svc.dispatch(AgentRequest(method: "page.press", params: [
            "id": AnyCodable("00000000-0000-0000-0000-000000000000")
        ]))
        #expect(!resp.ok)
        #expect(resp.error?.code == ErrorCode.invalidParams)
    }

    @Test("page.press allows missing elementId (targets activeElement)")
    func pressMissingElementId() async {
        let (_, svc) = makeService()
        let resp = await svc.dispatch(AgentRequest(method: "page.press", params: [
            "id": AnyCodable("00000000-0000-0000-0000-000000000000"),
            "key": AnyCodable("Enter")
        ]))
        // Should fail with TAB_NOT_FOUND, not INVALID_PARAMS
        #expect(!resp.ok)
        #expect(resp.error?.code == ErrorCode.tabNotFound)
    }

    // MARK: - page.select

    @Test("page.select requires all params")
    func selectMissingParams() async {
        let (_, svc) = makeService()
        // Missing value param -> INVALID_PARAMS
        let resp = await svc.dispatch(AgentRequest(method: "page.select", params: [
            "id": AnyCodable("00000000-0000-0000-0000-000000000000"),
            "elementId": AnyCodable("el_abc123")
        ]))
        #expect(!resp.ok)
        #expect(resp.error?.code == ErrorCode.invalidParams)
    }

    // MARK: - page.wait

    @Test("page.wait requires id")
    func waitMissingId() async {
        let (_, svc) = makeService()
        let resp = await svc.dispatch(AgentRequest(method: "page.wait"))
        #expect(!resp.ok)
        #expect(resp.error?.code == ErrorCode.invalidParams)
    }

    @Test("page.wait returns TAB_NOT_FOUND for bad id")
    func waitBadTab() async {
        let (_, svc) = makeService()
        let resp = await svc.dispatch(AgentRequest(method: "page.wait", params: [
            "id": AnyCodable("00000000-0000-0000-0000-000000000000"),
            "condition": AnyCodable("load")
        ]))
        #expect(!resp.ok)
        #expect(resp.error?.code == ErrorCode.tabNotFound)
    }

    // MARK: - Error Code Mapping

    @Test("JS error codes map to protocol error codes")
    func errorCodeMapping() {
        #expect(BrowserAutomationService.mapJSErrorCode("ELEMENT_NOT_FOUND") == ErrorCode.elementNotFound)
        #expect(BrowserAutomationService.mapJSErrorCode("ELEMENT_STALE") == ErrorCode.elementStale)
        #expect(BrowserAutomationService.mapJSErrorCode("ELEMENT_NOT_VISIBLE") == ErrorCode.elementNotInteractable)
        #expect(BrowserAutomationService.mapJSErrorCode("ELEMENT_DISABLED") == ErrorCode.elementNotInteractable)
        #expect(BrowserAutomationService.mapJSErrorCode("UNSUPPORTED_ELEMENT") == ErrorCode.unsupportedElement)
        #expect(BrowserAutomationService.mapJSErrorCode("WAIT_TIMEOUT") == ErrorCode.waitTimeout)
        #expect(BrowserAutomationService.mapJSErrorCode("SOMETHING_ELSE") == ErrorCode.javaScriptError)
    }

    // MARK: - Response Parsing

    @Test("parseInspectResult handles valid JSON")
    func parseInspect() {
        let json = """
        {"generation":1,"url":"https://example.com","title":"Test","elements":[{"id":"el_abc123","tag":"button","role":"button","name":"Submit","text":"Submit","visible":true}]}
        """
        let resp = BrowserAutomationService.parseInspectResult(
            raw: json, tabID: "test-tab", title: "Test", url: "https://example.com"
        )
        #expect(resp.ok)
    }

    @Test("parseInspectResult handles bridge error")
    func parseInspectError() {
        let json = "{\"error\":\"BRIDGE_NOT_LOADED\"}"
        let resp = BrowserAutomationService.parseInspectResult(
            raw: json, tabID: "test-tab", title: "Test", url: nil
        )
        #expect(!resp.ok)
    }

    @Test("parseActionResult returns success for ok result")
    func parseActionOK() {
        let json = "{\"ok\":true}"
        let resp = BrowserAutomationService.parseActionResult(
            raw: json, tabID: "test-tab", elementId: "el_123", action: "click"
        )
        #expect(resp.ok)
    }

    @Test("parseActionResult maps JS error codes")
    func parseActionError() {
        let json = "{\"error\":\"ELEMENT_NOT_FOUND\"}"
        let resp = BrowserAutomationService.parseActionResult(
            raw: json, tabID: "test-tab", elementId: "el_123", action: "click"
        )
        #expect(!resp.ok)
        #expect(resp.error?.code == ErrorCode.elementNotFound)
    }

    @Test("parseWaitError returns nil for success")
    func parseWaitOK() {
        let json = "{\"ok\":true}"
        let err = BrowserAutomationService.parseWaitError(raw: json)
        #expect(err == nil)
    }

    @Test("parseWaitError extracts error string")
    func parseWaitErr() {
        let json = "{\"error\":\"WAIT_TIMEOUT\"}"
        let err = BrowserAutomationService.parseWaitError(raw: json)
        #expect(err == "WAIT_TIMEOUT")
    }

    // MARK: - Wait Condition Building

    @Test("buildWaitCondition routes selector-like values to selector")
    func waitConditionSelector() {
        let cond = BrowserAutomationService.buildWaitCondition(value: "#search")
        #expect(cond.contains("selector"))
    }

    @Test("buildWaitCondition routes plain text to text")
    func waitConditionText() {
        let cond = BrowserAutomationService.buildWaitCondition(value: "Sign in")
        #expect(cond.contains("text"))
    }

    @Test("buildWaitCondition handles nil value")
    func waitConditionNil() {
        let cond = BrowserAutomationService.buildWaitCondition(value: nil)
        #expect(cond == "{}")
    }

    // MARK: - New Error Codes Exist

    @Test("New error codes are defined in ErrorCode")
    func newErrorCodes() {
        #expect(ErrorCode.elementNotFound == "ELEMENT_NOT_FOUND")
        #expect(ErrorCode.elementStale == "ELEMENT_STALE")
        #expect(ErrorCode.elementNotInteractable == "ELEMENT_NOT_INTERACTABLE")
        #expect(ErrorCode.unsupportedElement == "UNSUPPORTED_ELEMENT")
        #expect(ErrorCode.waitTimeout == "WAIT_TIMEOUT")
        #expect(ErrorCode.navigationFailed == "NAVIGATION_FAILED")
        #expect(ErrorCode.invalidArgument == "INVALID_ARGUMENT")
    }
}
