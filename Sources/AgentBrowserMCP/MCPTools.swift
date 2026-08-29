import Foundation

/// MCP tool definitions and dispatch for Agent Browser.
/// Each tool maps directly to an existing browser automation method.
/// No browser logic is duplicated here -- all operations go through BrowserClient.
struct MCPTools {

    /// Return MCP tool definitions with JSON schemas.
    func definitions() -> [[String: Any]] {
        [
            tool("browser_tabs",
                 desc: "List all open tabs in Agent Browser. Returns tab IDs, titles, URLs, and loading state.",
                 props: [:]),

            tool("browser_open",
                 desc: "Open a URL in a new Agent Browser tab. The tab is visible in the GUI.",
                 props: ["url": prop("string", "URL to open")],
                 required: ["url"]),

            tool("browser_read",
                 desc: "Read the current live page content from a tab. Returns the rendered DOM content, not cached HTML. Works on authenticated pages and SPAs.",
                 props: [
                    "tab_id": prop("string", "Tab ID from browser_tabs"),
                    "format": prop("string", "Output format: 'markdown' (default), 'text', or 'html'")
                 ],
                 required: ["tab_id"]),

            tool("browser_inspect",
                 desc: "Inspect interactive elements on a live page. Returns semantic element handles (el_XXXXXX) with accessible names, roles, and state. Use these handles with browser_click, browser_fill, browser_press. Handles become stale after navigation -- re-inspect if the page changes.",
                 props: ["tab_id": prop("string", "Tab ID from browser_tabs")],
                 required: ["tab_id"]),

            tool("browser_click",
                 desc: "Click an interactive element in the browser. The click is visible in the GUI. Use element IDs from browser_inspect.",
                 props: [
                    "tab_id": prop("string", "Tab ID from browser_tabs"),
                    "element_id": prop("string", "Element handle from browser_inspect (e.g. 'el_a1b2c3')")
                 ],
                 required: ["tab_id", "element_id"]),

            tool("browser_fill",
                 desc: "Fill a text input or textarea with a value. Works with React/Vue/Angular controlled inputs. The change is visible in the GUI.",
                 props: [
                    "tab_id": prop("string", "Tab ID from browser_tabs"),
                    "element_id": prop("string", "Element handle from browser_inspect"),
                    "value": prop("string", "Text to enter into the field")
                 ],
                 required: ["tab_id", "element_id", "value"]),

            tool("browser_press",
                 desc: "Press a keyboard key. Supported: Enter, Escape, Tab, Backspace, Delete, ArrowUp/Down/Left/Right, Home, End, PageUp, PageDown, Space.",
                 props: [
                    "tab_id": prop("string", "Tab ID from browser_tabs"),
                    "key": prop("string", "Key name (e.g. 'Enter', 'Tab', 'Escape')"),
                    "element_id": prop("string", "Optional element handle. If omitted, key is sent to the focused element.")
                 ],
                 required: ["tab_id", "key"]),

            tool("browser_select",
                 desc: "Select an option in a dropdown (<select>) element.",
                 props: [
                    "tab_id": prop("string", "Tab ID from browser_tabs"),
                    "element_id": prop("string", "Element handle of the <select> element"),
                    "value": prop("string", "Option value to select")
                 ],
                 required: ["tab_id", "element_id", "value"]),

            tool("browser_wait",
                 desc: "Wait for a page condition. Use after navigation or form submission.",
                 props: [
                    "tab_id": prop("string", "Tab ID from browser_tabs"),
                    "condition": prop("string", "'load' (default), 'url', 'text', or 'element'"),
                    "value": prop("string", "For 'url': substring to match. For 'text': text to appear. For 'element': CSS selector or text."),
                    "timeout": prop("number", "Timeout in seconds (default: 10)")
                 ],
                 required: ["tab_id"]),

            tool("browser_eval",
                 desc: "Execute JavaScript in a tab. PRIVILEGED: can access authenticated sessions, modify DOM, and trigger actions. The script runs in the exact live tab visible to the user.",
                 props: [
                    "tab_id": prop("string", "Tab ID from browser_tabs"),
                    "script": prop("string", "JavaScript to execute. Use 'return' for a value.")
                 ],
                 required: ["tab_id", "script"]),

            tool("browser_screenshot",
                 desc: "Capture a screenshot of a tab as PNG. Returns the image directly.",
                 props: ["tab_id": prop("string", "Tab ID from browser_tabs")],
                 required: ["tab_id"]),
        ]
    }

    /// Dispatch a tool call to the browser API. Returns (content array, isError).
    func call(name: String, arguments args: [String: Any]) -> ([[String: Any]], Bool) {
        switch name {
        case "browser_tabs":
            return callBrowser(method: "tabs.list")
        case "browser_open":
            guard let url = args["url"] as? String else { return toolError("Missing required argument: url") }
            return callBrowser(method: "tabs.open", params: ["url": url])
        case "browser_read":
            guard let tabId = args["tab_id"] as? String else { return toolError("Missing required argument: tab_id") }
            var params: [String: Any] = ["id": tabId]
            if let fmt = args["format"] as? String { params["format"] = fmt }
            return callBrowserRead(params: params)
        case "browser_inspect":
            guard let tabId = args["tab_id"] as? String else { return toolError("Missing required argument: tab_id") }
            return callBrowserInspect(params: ["id": tabId])
        case "browser_click":
            guard let tabId = args["tab_id"] as? String, let elId = args["element_id"] as? String else {
                return toolError("Missing required arguments: tab_id, element_id")
            }
            return callBrowser(method: "page.click", params: ["id": tabId, "elementId": elId])
        case "browser_fill":
            guard let tabId = args["tab_id"] as? String, let elId = args["element_id"] as? String,
                  let value = args["value"] as? String else {
                return toolError("Missing required arguments: tab_id, element_id, value")
            }
            return callBrowser(method: "page.fill", params: ["id": tabId, "elementId": elId, "value": value])
        case "browser_press":
            guard let tabId = args["tab_id"] as? String, let key = args["key"] as? String else {
                return toolError("Missing required arguments: tab_id, key")
            }
            var params: [String: Any] = ["id": tabId, "key": key]
            if let elId = args["element_id"] as? String { params["elementId"] = elId }
            return callBrowser(method: "page.press", params: params)
        case "browser_select":
            guard let tabId = args["tab_id"] as? String, let elId = args["element_id"] as? String,
                  let value = args["value"] as? String else {
                return toolError("Missing required arguments: tab_id, element_id, value")
            }
            return callBrowser(method: "page.select", params: ["id": tabId, "elementId": elId, "value": value])
        case "browser_wait":
            guard let tabId = args["tab_id"] as? String else { return toolError("Missing required argument: tab_id") }
            var params: [String: Any] = ["id": tabId]
            if let cond = args["condition"] as? String { params["condition"] = cond }
            if let val = args["value"] as? String { params["value"] = val }
            if let t = args["timeout"] as? Double { params["timeout"] = t }
            else if let t = args["timeout"] as? Int { params["timeout"] = t }
            return callBrowser(method: "page.wait", params: params)
        case "browser_eval":
            guard let tabId = args["tab_id"] as? String, let script = args["script"] as? String else {
                return toolError("Missing required arguments: tab_id, script")
            }
            return callBrowser(method: "page.eval", params: ["id": tabId, "script": script])
        case "browser_screenshot":
            guard let tabId = args["tab_id"] as? String else { return toolError("Missing required argument: tab_id") }
            return callBrowserScreenshot(params: ["id": tabId])
        default:
            return toolError("Unknown tool: \(name)")
        }
    }

    // MARK: - Helpers

    private func tool(_ name: String, desc: String, props: [String: Any], required: [String] = []) -> [String: Any] {
        var schema: [String: Any] = ["type": "object", "properties": props, "additionalProperties": false]
        if !required.isEmpty { schema["required"] = required }
        return ["name": name, "description": desc, "inputSchema": schema]
    }

    private func prop(_ type: String, _ desc: String) -> [String: Any] {
        ["type": type, "description": desc]
    }

    private func toolError(_ message: String) -> ([[String: Any]], Bool) {
        ([["type": "text", "text": message]], true)
    }

    private func textContent(_ text: String) -> ([[String: Any]], Bool) {
        ([["type": "text", "text": text]], false)
    }
}
