import Foundation
import Network

/// HTTP server on 127.0.0.1 that exposes BrowserAutomationService via the
/// versioned AgentRequest/AgentResponse protocol.
///
/// Transport layer only -- all browser logic lives in BrowserAutomationService.
///
/// Security model:
/// - Binds to loopback only (127.0.0.1). External machines cannot connect.
/// - Bearer token authentication on all endpoints except /health.
/// - Host header validation prevents DNS rebinding attacks.
/// - Token generated per-launch via SecRandomCopyBytes (32 bytes, base64url).
/// - Connection descriptor at ~/.config/agent-browser/connection.json (mode 0600).
///
/// Trust boundary: any local process running as the current user that can read
/// the connection descriptor can control the browser. This is the same trust
/// boundary as the user's filesystem. A more granular per-agent permission
/// model is a future addition.
final class AgentHTTPServer {
    private let automationService: BrowserAutomationService
    private var listener: NWListener?
    private let requestedPort: UInt16
    let token: String

    private(set) var boundPort: UInt16 = 0

    init(automationService: BrowserAutomationService, port: UInt16 = 8833) {
        self.automationService = automationService
        self.requestedPort = port
        self.token = Self.generateToken()
    }

    // MARK: - Lifecycle

    func start() {
        tryBind(port: requestedPort, attempt: 0)
    }

    func stop() {
        listener?.cancel()
        listener = nil
        removeConnectionDescriptor()
    }

    private func tryBind(port: UInt16, attempt: Int) {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = NWEndpoint.hostPort(
            host: .ipv4(.loopback),
            port: NWEndpoint.Port(rawValue: port)!
        )
        params.allowLocalEndpointReuse = true

        do {
            let newListener = try NWListener(using: params)
            self.listener = newListener

            newListener.stateUpdateHandler = { [weak self] state in
                DispatchQueue.main.async {
                    guard let self else { return }
                    switch state {
                    case .ready:
                        self.boundPort = port
                        self.writeConnectionDescriptor()
                        print("[AgentHTTPServer] Listening on http://127.0.0.1:\(port)")
                    case .failed(let error):
                        print("[AgentHTTPServer] Failed on port \(port): \(error)")
                        self.listener?.cancel()
                        if attempt < 10 {
                            self.tryBind(port: port + 1, attempt: attempt + 1)
                        }
                    default: break
                    }
                }
            }

            newListener.newConnectionHandler = { [weak self] connection in
                DispatchQueue.main.async {
                    self?.handleConnection(connection)
                }
            }

            newListener.start(queue: .main)
        } catch {
            print("[AgentHTTPServer] Failed to create listener: \(error)")
            if attempt < 10 {
                tryBind(port: port + 1, attempt: attempt + 1)
            }
        }
    }

    // MARK: - Connection Handling

    private func handleConnection(_ connection: NWConnection) {
        connection.start(queue: .main)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1_048_576) { [weak self] data, _, _, _ in
            DispatchQueue.main.async {
                guard let self, let data, let raw = String(data: data, encoding: .utf8) else {
                    connection.cancel()
                    return
                }
                self.routeRequest(connection, raw: raw)
            }
        }
    }

    // MARK: - Routing

    /// Two API surfaces:
    /// 1. POST /agent -- structured protocol (AgentRequest/AgentResponse)
    /// 2. REST endpoints -- convenience for curl/CLI use
    /// Both go through the same BrowserAutomationService.
    private func routeRequest(_ connection: NWConnection, raw: String) {
        let (method, path, headers) = parseRequestLine(raw)

        // Security: Host header validation
        if let host = headers["host"] {
            let allowed = ["127.0.0.1:\(boundPort)", "localhost:\(boundPort)", "127.0.0.1", "localhost"]
            if !allowed.contains(host.lowercased()) {
                sendJSON(connection, status: 403, value: AgentResponse.failure(
                    code: "FORBIDDEN", message: "Invalid Host header"))
                return
            }
        }

        // Health check -- no auth
        if path == "/health" {
            sendJSON(connection, status: 200, value: ["status": "ok", "browser": "Agent Browser", "version": "0.2.0"])
            return
        }

        // Auth check
        let authHeader = headers["authorization"] ?? ""
        guard authHeader == "Bearer \(token)" else {
            sendJSON(connection, status: 401, value: AgentResponse.failure(
                code: "UNAUTHORIZED", message: "Invalid or missing bearer token"))
            return
        }

        let body = extractJSONBody(from: raw)

        Task { @MainActor in
            // Route: structured protocol or REST
            if method == "POST" && path == "/agent" {
                await self.handleStructuredRequest(connection, body: body)
            } else {
                await self.handleRESTRequest(connection, method: method, path: path, body: body)
            }
        }
    }

    // MARK: - Structured Protocol (POST /agent)

    @MainActor
    private func handleStructuredRequest(_ connection: NWConnection, body: [String: Any]?) async {
        guard let body,
              let data = try? JSONSerialization.data(withJSONObject: body),
              let request = try? JSONDecoder().decode(AgentRequest.self, from: data) else {
            sendJSON(connection, status: 400, value: AgentResponse.failure(
                code: ErrorCode.badRequest, message: "Invalid AgentRequest JSON"))
            return
        }

        let response = await automationService.dispatch(request)
        sendJSON(connection, status: response.ok ? 200 : 400, value: response)
    }

    // MARK: - REST Convenience Endpoints

    @MainActor
    private func handleRESTRequest(_ connection: NWConnection, method: String, path: String, body: [String: Any]?) async {
        // Parse path segments: /api/tabs, /api/tabs/:id, /api/tabs/:id/read, etc.
        let segments = path.split(separator: "/").map(String.init)

        // GET /api/tabs
        if method == "GET" && segments == ["api", "tabs"] {
            let resp = await automationService.dispatch(AgentRequest(method: "tabs.list"))
            sendJSON(connection, status: 200, value: resp)
            return
        }

        // POST /api/tabs  {"url": "..."}
        if method == "POST" && segments == ["api", "tabs"] {
            let url = body?["url"] as? String ?? ""
            let resp = await automationService.dispatch(AgentRequest(
                method: "tabs.open", params: ["url": AnyCodable(url)]))
            sendJSON(connection, status: resp.ok ? 201 : 400, value: resp)
            return
        }

        // Routes with tab ID: /api/tabs/:id[/action]
        if segments.count >= 3 && segments[0] == "api" && segments[1] == "tabs" {
            let tabID = segments[2]
            let action = segments.count > 3 ? segments[3] : nil

            switch (method, action) {
            case ("GET", nil):
                let resp = await automationService.dispatch(AgentRequest(
                    method: "tabs.get", params: ["id": AnyCodable(tabID)]))
                sendJSON(connection, status: resp.ok ? 200 : 404, value: resp)

            case (_, "read"):
                let format = body?["format"] as? String ?? "markdown"
                let resp = await automationService.dispatch(AgentRequest(
                    method: "page.read",
                    params: ["id": AnyCodable(tabID), "format": AnyCodable(format)]))
                sendJSON(connection, status: resp.ok ? 200 : 400, value: resp)

            case ("POST", "js"):
                let script = body?["script"] as? String ?? ""
                let resp = await automationService.dispatch(AgentRequest(
                    method: "page.eval",
                    params: ["id": AnyCodable(tabID), "script": AnyCodable(script)]))
                sendJSON(connection, status: resp.ok ? 200 : 400, value: resp)

            case ("GET", "screenshot"):
                let resp = await automationService.dispatch(AgentRequest(
                    method: "page.screenshot", params: ["id": AnyCodable(tabID)]))
                sendJSON(connection, status: resp.ok ? 200 : 400, value: resp)

            default:
                sendJSON(connection, status: 404, value: AgentResponse.failure(
                    code: ErrorCode.unknownMethod, message: "Not found: \(method) \(path)"))
            }
            return
        }

        sendJSON(connection, status: 404, value: AgentResponse.failure(
            code: ErrorCode.unknownMethod, message: "Not found: \(method) \(path)"))
    }

    // MARK: - HTTP Response

    private func sendJSON(_ connection: NWConnection, status: Int, value: some Encodable) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let jsonData = try? encoder.encode(value) else {
            connection.cancel()
            return
        }

        let statusText = Self.httpStatusText(status)
        var header = "HTTP/1.1 \(status) \(statusText)\r\n"
        header += "Content-Type: application/json\r\n"
        header += "Content-Length: \(jsonData.count)\r\n"
        header += "Connection: close\r\n"
        header += "\r\n"

        var data = Data(header.utf8)
        data.append(jsonData)
        connection.send(content: data, completion: .contentProcessed { _ in connection.cancel() })
    }

    // MARK: - Parsing

    private func parseRequestLine(_ raw: String) -> (method: String, path: String, headers: [String: String]) {
        var headers: [String: String] = [:]
        let lines = raw.components(separatedBy: "\r\n")
        guard let first = lines.first else { return ("", "", [:]) }

        let parts = first.split(separator: " ")
        let method = parts.count > 0 ? String(parts[0]) : ""
        let path = parts.count > 1 ? String(parts[1]) : ""

        for line in lines.dropFirst() {
            if line.isEmpty { break }
            if let colon = line.firstIndex(of: ":") {
                let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces).lowercased()
                let val = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
                headers[key] = val
            }
        }
        return (method, path, headers)
    }

    private func extractJSONBody(from raw: String) -> [String: Any]? {
        guard let range = raw.range(of: "\r\n\r\n") else { return nil }
        let bodyString = String(raw[range.upperBound...])
        guard !bodyString.isEmpty,
              let data = bodyString.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return json
    }

    private static func httpStatusText(_ code: Int) -> String {
        switch code {
        case 200: return "OK"
        case 201: return "Created"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 500: return "Internal Server Error"
        default: return "Unknown"
        }
    }

    // MARK: - Token

    private static func generateToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    // MARK: - Connection Descriptor

    private func writeConnectionDescriptor() {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/agent-browser")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let descriptor: [String: Any] = [
            "url": "http://127.0.0.1:\(boundPort)",
            "token": token,
            "pid": ProcessInfo.processInfo.processIdentifier,
            "version": "0.2.0"
        ]

        let path = dir.appendingPathComponent("connection.json")
        if let data = try? JSONSerialization.data(withJSONObject: descriptor, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: path)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
            print("[AgentHTTPServer] Connection descriptor: \(path.path)")
        }
    }

    private func removeConnectionDescriptor() {
        let path = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/agent-browser/connection.json")
        try? FileManager.default.removeItem(at: path)
    }
}
