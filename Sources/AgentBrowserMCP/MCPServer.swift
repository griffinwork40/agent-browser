import Foundation

/// MCP server implementing JSON-RPC 2.0 over stdio.
/// Handles initialize handshake, tools/list, and tools/call.
/// All browser operations are delegated to the running Agent Browser via HTTP.
final class MCPServer {

    private let tools = MCPTools()
    private var initialized = false

    func run() {
        // Read JSON-RPC messages line-by-line from stdin
        while let line = readLine(strippingNewline: true) {
            guard !line.isEmpty else { continue }
            guard let data = line.data(using: .utf8),
                  let msg = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                sendError(id: nil, code: -32700, message: "Parse error")
                continue
            }
            handleMessage(msg)
        }
    }

    // MARK: - Message Dispatch

    private func handleMessage(_ msg: [String: Any]) {
        let method = msg["method"] as? String
        let id = msg["id"]  // may be Int, String, or nil (notification)

        // Notifications (no id) -- handle silently
        if id == nil {
            if method == "notifications/initialized" { initialized = true }
            return
        }

        guard let method else {
            sendError(id: id, code: -32600, message: "Invalid Request: missing method")
            return
        }

        switch method {
        case "initialize":
            handleInitialize(id: id, params: msg["params"] as? [String: Any] ?? [:])
        case "tools/list":
            handleToolsList(id: id)
        case "tools/call":
            handleToolsCall(id: id, params: msg["params"] as? [String: Any] ?? [:])
        case "ping":
            sendResult(id: id, result: [:] as [String: Any])
        default:
            sendError(id: id, code: -32601, message: "Method not found: \(method)")
        }
    }

    // MARK: - Initialize

    private func handleInitialize(id: Any?, params: [String: Any]) {
        let result: [String: Any] = [
            "protocolVersion": "2025-11-25",
            "capabilities": [
                "tools": ["listChanged": false]
            ],
            "serverInfo": [
                "name": "agent-browser-mcp",
                "version": "0.3.0"
            ]
        ]
        sendResult(id: id, result: result)
    }

    // MARK: - Tools

    private func handleToolsList(id: Any?) {
        sendResult(id: id, result: ["tools": tools.definitions()])
    }

    private func handleToolsCall(id: Any?, params: [String: Any]) {
        guard let name = params["name"] as? String else {
            sendError(id: id, code: -32602, message: "Missing tool name")
            return
        }
        let args = params["arguments"] as? [String: Any] ?? [:]
        let (content, isError) = tools.call(name: name, arguments: args)
        let result: [String: Any] = ["content": content, "isError": isError]
        sendResult(id: id, result: result)
    }

    // MARK: - JSON-RPC Response Writers

    private func sendResult(id: Any?, result: Any) {
        var response: [String: Any] = ["jsonrpc": "2.0", "result": result]
        if let id { response["id"] = id }
        writeJSON(response)
    }

    func sendError(id: Any?, code: Int, message: String) {
        var response: [String: Any] = [
            "jsonrpc": "2.0",
            "error": ["code": code, "message": message]
        ]
        if let id { response["id"] = id }
        writeJSON(response)
    }

    private func writeJSON(_ obj: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]),
              var str = String(data: data, encoding: .utf8) else { return }
        // JSON-RPC over stdio: one JSON object per line, no embedded newlines
        str = str.replacingOccurrences(of: "\n", with: "")
        print(str)
        fflush(stdout)
    }
}
