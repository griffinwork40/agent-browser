import Testing
import Foundation
@testable import AgentBrowser

/// Tests for bounded inspect and read output (token efficiency).
@Suite("Bounded Output")
@MainActor
struct BoundedOutputTests {

    private func makeService() -> (TabManager, BrowserAutomationService) {
        let tm = TabManager()
        let svc = BrowserAutomationService(tabManager: tm)
        return (tm, svc)
    }

    // MARK: - Inspect: Parameter Routing

    @Test("page.inspect accepts mode parameter")
    func inspectModeParam() async {
        let (_, svc) = makeService()
        // With mode=forms, should fail with TAB_NOT_FOUND (params parsed correctly)
        let resp = await svc.dispatch(AgentRequest(method: "page.inspect", params: [
            "id": AnyCodable("00000000-0000-0000-0000-000000000000"),
            "mode": AnyCodable("forms")
        ]))
        #expect(!resp.ok)
        #expect(resp.error?.code == ErrorCode.tabNotFound)
    }

    @Test("page.inspect accepts limit parameter")
    func inspectLimitParam() async {
        let (_, svc) = makeService()
        let resp = await svc.dispatch(AgentRequest(method: "page.inspect", params: [
            "id": AnyCodable("00000000-0000-0000-0000-000000000000"),
            "limit": AnyCodable(10)
        ]))
        #expect(!resp.ok)
        #expect(resp.error?.code == ErrorCode.tabNotFound)
    }

    @Test("page.inspect accepts query parameter")
    func inspectQueryParam() async {
        let (_, svc) = makeService()
        let resp = await svc.dispatch(AgentRequest(method: "page.inspect", params: [
            "id": AnyCodable("00000000-0000-0000-0000-000000000000"),
            "query": AnyCodable("search")
        ]))
        #expect(!resp.ok)
        #expect(resp.error?.code == ErrorCode.tabNotFound)
    }

    @Test("page.inspect accepts all params together")
    func inspectAllParams() async {
        let (_, svc) = makeService()
        let resp = await svc.dispatch(AgentRequest(method: "page.inspect", params: [
            "id": AnyCodable("00000000-0000-0000-0000-000000000000"),
            "mode": AnyCodable("navigation"),
            "limit": AnyCodable(5),
            "query": AnyCodable("docs")
        ]))
        #expect(!resp.ok)
        #expect(resp.error?.code == ErrorCode.tabNotFound)
    }

    // MARK: - Inspect: Response Parsing

    @Test("parseInspectResult includes bounded metadata")
    func parseInspectBounded() {
        let json = """
        {"generation":1,"url":"https://example.com","title":"Test","returned":5,"totalInteractive":100,"truncated":true,"mode":"interactive","elements":[{"id":"el_abc123","tag":"button","name":"Submit"}]}
        """
        let resp = BrowserAutomationService.parseInspectResult(
            raw: json, tabID: "test-tab", title: "Test", url: "https://example.com"
        )
        #expect(resp.ok)
        // Verify the response contains the bounded metadata
        if let data = try? JSONEncoder().encode(resp.result),
           let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            #expect(dict["returned"] as? Int == 5)
            #expect(dict["totalInteractive"] as? Int == 100)
            #expect(dict["truncated"] as? Bool == true)
            #expect(dict["mode"] as? String == "interactive")
        }
    }

    @Test("parseInspectResult defaults mode to interactive")
    func parseInspectDefaultMode() {
        let json = """
        {"generation":1,"url":"https://example.com","title":"Test","elements":[]}
        """
        let resp = BrowserAutomationService.parseInspectResult(
            raw: json, tabID: "test-tab", title: "Test", url: "https://example.com"
        )
        #expect(resp.ok)
        if let data = try? JSONEncoder().encode(resp.result),
           let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            #expect(dict["mode"] as? String == "interactive")
            #expect(dict["truncated"] as? Bool == false)
        }
    }

    // MARK: - Read: Parameter Routing

    @Test("page.read accepts mode parameter")
    func readModeParam() async {
        let (_, svc) = makeService()
        let resp = await svc.dispatch(AgentRequest(method: "page.read", params: [
            "id": AnyCodable("00000000-0000-0000-0000-000000000000"),
            "mode": AnyCodable("summary")
        ]))
        #expect(!resp.ok)
        #expect(resp.error?.code == ErrorCode.tabNotFound)
    }

    @Test("page.read accepts query parameter")
    func readQueryParam() async {
        let (_, svc) = makeService()
        let resp = await svc.dispatch(AgentRequest(method: "page.read", params: [
            "id": AnyCodable("00000000-0000-0000-0000-000000000000"),
            "query": AnyCodable("installation")
        ]))
        #expect(!resp.ok)
        #expect(resp.error?.code == ErrorCode.tabNotFound)
    }

    @Test("page.read accepts budget parameter")
    func readBudgetParam() async {
        let (_, svc) = makeService()
        let resp = await svc.dispatch(AgentRequest(method: "page.read", params: [
            "id": AnyCodable("00000000-0000-0000-0000-000000000000"),
            "budget": AnyCodable(4000)
        ]))
        #expect(!resp.ok)
        #expect(resp.error?.code == ErrorCode.tabNotFound)
    }

    @Test("page.read accepts mode=full for uncapped output")
    func readFullMode() async {
        let (_, svc) = makeService()
        let resp = await svc.dispatch(AgentRequest(method: "page.read", params: [
            "id": AnyCodable("00000000-0000-0000-0000-000000000000"),
            "mode": AnyCodable("full")
        ]))
        #expect(!resp.ok)
        #expect(resp.error?.code == ErrorCode.tabNotFound)
    }

    // MARK: - ContentExtraction

    @Test("ReadMode initializes from valid strings")
    func readModeInit() {
        #expect(ContentExtraction.ReadMode(rawValue: "summary") == .summary)
        #expect(ContentExtraction.ReadMode(rawValue: "main") == .main)
        #expect(ContentExtraction.ReadMode(rawValue: "full") == .full)
        #expect(ContentExtraction.ReadMode(rawValue: "text") == .text)
        #expect(ContentExtraction.ReadMode(rawValue: "html") == .html)
    }

    @Test("ReadMode returns nil for invalid strings")
    func readModeInvalid() {
        #expect(ContentExtraction.ReadMode(rawValue: "invalid") == nil)
        #expect(ContentExtraction.ReadMode(rawValue: "") == nil)
    }

    @Test("Default budgets are reasonable")
    func defaultBudgets() {
        #expect(ContentExtraction.defaultBudget(for: .summary) > 0)
        #expect(ContentExtraction.defaultBudget(for: .summary) <= 8000)
        #expect(ContentExtraction.defaultBudget(for: .main) > 0)
        #expect(ContentExtraction.defaultBudget(for: .main) <= 20000)
        #expect(ContentExtraction.defaultBudget(for: .full) == 0)
    }

    @Test("Summary budget is smaller than main budget")
    func budgetOrdering() {
        #expect(ContentExtraction.defaultBudget(for: .summary) < ContentExtraction.defaultBudget(for: .main))
    }

}
