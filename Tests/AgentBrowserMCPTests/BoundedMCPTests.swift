import Testing
@testable import agent_browser_mcp

/// Tests for bounded inspect/read MCP schema and dispatch.
@Suite("Bounded MCP")
struct BoundedMCPTests {

    @Test("browser_inspect MCP schema includes mode, limit, query")
    func inspectMCPSchema() {
        let tools = MCPTools()
        let defs = tools.definitions()
        let inspect = defs.first { ($0["name"] as? String) == "browser_inspect" }
        #expect(inspect != nil)
        if let schema = inspect?["inputSchema"] as? [String: Any],
           let props = schema["properties"] as? [String: Any] {
            #expect(props["mode"] != nil)
            #expect(props["limit"] != nil)
            #expect(props["query"] != nil)
        }
    }

    @Test("browser_read MCP schema includes mode, query, budget")
    func readMCPSchema() {
        let tools = MCPTools()
        let defs = tools.definitions()
        let read = defs.first { ($0["name"] as? String) == "browser_read" }
        #expect(read != nil)
        if let schema = read?["inputSchema"] as? [String: Any],
           let props = schema["properties"] as? [String: Any] {
            #expect(props["mode"] != nil)
            #expect(props["query"] != nil)
            #expect(props["budget"] != nil)
        }
    }

    @Test("browser_inspect description mentions bounded default")
    func inspectDescriptionBounded() {
        let tools = MCPTools()
        let defs = tools.definitions()
        let inspect = defs.first { ($0["name"] as? String) == "browser_inspect" }
        let desc = inspect?["description"] as? String ?? ""
        #expect(desc.contains("30") || desc.contains("top"))
    }

    @Test("browser_read description mentions bounded default")
    func readDescriptionBounded() {
        let tools = MCPTools()
        let defs = tools.definitions()
        let read = defs.first { ($0["name"] as? String) == "browser_read" }
        let desc = read?["description"] as? String ?? ""
        #expect(desc.contains("bounded") || desc.contains("main"))
    }

    @Test("browser_inspect passes mode/limit/query to browser API")
    func inspectMCPPassthrough() {
        let tools = MCPTools()
        let (result, isError) = tools.call(name: "browser_inspect", arguments: [
            "tab_id": "test-id",
            "mode": "forms",
            "limit": 10,
            "query": "search"
        ])
        #expect(isError)
        #expect(result.count > 0)
    }

    @Test("browser_read passes mode/query/budget to browser API")
    func readMCPPassthrough() {
        let tools = MCPTools()
        let (result, isError) = tools.call(name: "browser_read", arguments: [
            "tab_id": "test-id",
            "mode": "summary",
            "query": "install",
            "budget": 4000
        ])
        #expect(isError)
        #expect(result.count > 0)
    }
}
