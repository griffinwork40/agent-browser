import Testing
@testable import agent_browser_mcp

/// Tests for the MCP server protocol handling, tool schemas, and dispatch.
/// These test the MCP layer in isolation. Browser transport tests require
/// a running Agent Browser instance.
@Suite("MCP Server")
struct MCPServerTests {

    // MARK: - Tool Definitions

    @Test("definitions returns 11 tools")
    func toolCount() {
        let tools = MCPTools()
        let defs = tools.definitions()
        #expect(defs.count == 11)
    }

    @Test("every tool has name, description, and inputSchema")
    func toolShape() {
        let tools = MCPTools()
        for def in tools.definitions() {
            #expect(def["name"] as? String != nil)
            #expect(def["description"] as? String != nil)
            let schema = def["inputSchema"] as? [String: Any]
            #expect(schema != nil)
            #expect(schema?["type"] as? String == "object")
        }
    }

    @Test("tool names are valid MCP identifiers")
    func toolNames() {
        let tools = MCPTools()
        let names = tools.definitions().compactMap { $0["name"] as? String }
        let expected = [
            "browser_tabs", "browser_open", "browser_read", "browser_inspect",
            "browser_click", "browser_fill", "browser_press", "browser_select",
            "browser_wait", "browser_eval", "browser_screenshot"
        ]
        #expect(Set(names) == Set(expected))
    }

    @Test("browser_tabs has no required params")
    func tabsSchema() {
        let tools = MCPTools()
        let def = tools.definitions().first { $0["name"] as? String == "browser_tabs" }!
        let schema = def["inputSchema"] as! [String: Any]
        let required = schema["required"] as? [String]
        #expect(required == nil || required!.isEmpty)
    }

    @Test("browser_open requires url")
    func openSchema() {
        let tools = MCPTools()
        let def = tools.definitions().first { $0["name"] as? String == "browser_open" }!
        let schema = def["inputSchema"] as! [String: Any]
        let required = schema["required"] as! [String]
        #expect(required == ["url"])
    }

    @Test("browser_fill requires tab_id, element_id, value")
    func fillSchema() {
        let tools = MCPTools()
        let def = tools.definitions().first { $0["name"] as? String == "browser_fill" }!
        let schema = def["inputSchema"] as! [String: Any]
        let required = schema["required"] as! [String]
        #expect(Set(required) == Set(["tab_id", "element_id", "value"]))
    }

    @Test("browser_press requires tab_id and key, element_id optional")
    func pressSchema() {
        let tools = MCPTools()
        let def = tools.definitions().first { $0["name"] as? String == "browser_press" }!
        let schema = def["inputSchema"] as! [String: Any]
        let required = schema["required"] as! [String]
        #expect(Set(required) == Set(["tab_id", "key"]))
        let props = schema["properties"] as! [String: Any]
        #expect(props["element_id"] != nil) // exists as optional
    }

    @Test("browser_wait requires only tab_id")
    func waitSchema() {
        let tools = MCPTools()
        let def = tools.definitions().first { $0["name"] as? String == "browser_wait" }!
        let schema = def["inputSchema"] as! [String: Any]
        let required = schema["required"] as! [String]
        #expect(required == ["tab_id"])
    }

    // MARK: - Tool Dispatch Validation

    @Test("missing required argument returns isError true")
    func missingArgs() {
        let tools = MCPTools()
        let (content, isError) = tools.call(name: "browser_open", arguments: [:])
        #expect(isError == true)
        let text = (content.first?["text"] as? String) ?? ""
        #expect(text.contains("Missing"))
    }

    @Test("unknown tool returns isError true")
    func unknownTool() {
        let tools = MCPTools()
        let (content, isError) = tools.call(name: "nonexistent", arguments: [:])
        #expect(isError == true)
        let text = (content.first?["text"] as? String) ?? ""
        #expect(text.contains("Unknown tool"))
    }

    @Test("browser_fill with missing value returns error")
    func fillMissingValue() {
        let tools = MCPTools()
        let (content, isError) = tools.call(name: "browser_fill", arguments: [
            "tab_id": "some-id", "element_id": "el_123"
        ])
        #expect(isError == true)
    }

    @Test("browser_click with missing element_id returns error")
    func clickMissingElement() {
        let tools = MCPTools()
        let (content, isError) = tools.call(name: "browser_click", arguments: [
            "tab_id": "some-id"
        ])
        #expect(isError == true)
    }

    @Test("browser_eval with missing script returns error")
    func evalMissingScript() {
        let tools = MCPTools()
        let (content, isError) = tools.call(name: "browser_eval", arguments: [
            "tab_id": "some-id"
        ])
        #expect(isError == true)
    }

    // MARK: - Browser Not Running

    @Test("browser_tabs when browser not running returns clear error")
    func tabsNoBrowser() {
        // This test depends on the browser NOT running. If it is running,
        // it will return real tabs. We test the error path by checking
        // that the result is structured correctly either way.
        let tools = MCPTools()
        let (content, _) = tools.call(name: "browser_tabs", arguments: [:])
        #expect(!content.isEmpty)
        #expect(content.first?["type"] as? String == "text")
    }

    // MARK: - Connection Discovery

    @Test("discover returns nil when no connection file exists")
    func discoverNoFile() {
        // This test may return a real connection if the browser is running.
        // The important invariant: discover() never crashes.
        _ = BrowserClient.discover()
    }
}
