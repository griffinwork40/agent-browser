import Foundation
import Network

/// HTTP server on 127.0.0.1 exposing BrowserAutomationService.
/// Transport layer only -- all browser logic lives in BrowserAutomationService.
///
/// Security:
/// - Loopback-only binding. No network exposure.
/// - Bearer token auth on all endpoints except /health.
/// - Host header validation prevents DNS rebinding.
/// - Connection descriptor at ~/.config/agent-browser/connection.json (mode 0600).
final class AgentHTTPServer {
    private let automationService: BrowserAutomationService
    private var listener: NWListener?
    private let requestedPort: UInt16
    let token: String
    private(set) var boundPort: UInt16 = 0

    /// Maximum allowed request body size (8 MiB). Requests exceeding this
    /// are rejected with 413 before the body is fully buffered.
    private static let maxBodySize = 8 * 1024 * 1024

    init(automationService: BrowserAutomationService, port: UInt16 = 8833) {
        self.automationService = automationService
        self.requestedPort = port
        self.token = Self.generateToken()
    }

    func start() { tryBind(port: requestedPort, attempt: 0) }

    func stop() {
        listener?.cancel()
        listener = nil
        removeConnectionDescriptor()
    }

    private func tryBind(port: UInt16, attempt: Int) {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port)!)
        params.allowLocalEndpointReuse = true

        do {
            let l = try NWListener(using: params)
            self.listener = l
            l.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    self.boundPort = port
                    self.writeConnectionDescriptor()
                    print("[AgentHTTPServer] Listening on http://127.0.0.1:\(port)")
                case .failed:
                    self.listener?.cancel()
                    if attempt < 10 { self.tryBind(port: port + 1, attempt: attempt + 1) }
                default: break
                }
            }
            l.newConnectionHandler = { [weak self] conn in self?.handleConnection(conn) }
            l.start(queue: .main)
        } catch {
            if attempt < 10 { tryBind(port: port + 1, attempt: attempt + 1) }
        }
    }

    private func handleConnection(_ conn: NWConnection) {
        conn.start(queue: .main)
        conn.receive(minimumIncompleteLength: 1, maximumLength: 1_048_576) { [weak self] data, _, _, _ in
            guard let self, let data else { conn.cancel(); return }
            // URLSession and other HTTP clients may split headers and body
            // across TCP segments. Buffer until the full body arrives.
            self.bufferUntilComplete(conn, accumulated: data)
        }
    }

    /// Buffer HTTP data until Content-Length body bytes are received.
    private func bufferUntilComplete(_ conn: NWConnection, accumulated: Data) {
        // Reject oversized payloads before buffering more data.
        if accumulated.count > Self.maxBodySize {
            sendHTTP(conn, status: 413, contentType: "application/json",
                     body: Data(#"{"error":"Request body exceeds 8 MiB limit"}"#.utf8))
            return
        }
        guard let raw = String(data: accumulated, encoding: .utf8) else {
            conn.cancel(); return
        }
        // Check if we have the full body based on Content-Length
        if let headerEnd = raw.range(of: "\r\n\r\n") {
            let headerPart = raw[raw.startIndex..<headerEnd.lowerBound]
            let bodyStart = accumulated.count - raw[headerEnd.upperBound...].utf8.count
            if let clLine = headerPart.split(separator: "\r\n")
                .first(where: { $0.lowercased().hasPrefix("content-length:") }),
               let cl = Int(clLine.split(separator: ":")[1].trimmingCharacters(in: .whitespaces)) {
                // Reject if the declared Content-Length itself exceeds the cap.
                if cl > Self.maxBodySize {
                    sendHTTP(conn, status: 413, contentType: "application/json",
                             body: Data(#"{"error":"Request body exceeds 8 MiB limit"}"#.utf8))
                    return
                }
                let bodyReceived = accumulated.count - bodyStart
                if bodyReceived < cl {
                    // Need more data
                    conn.receive(minimumIncompleteLength: 1, maximumLength: 1_048_576) { [weak self] data, _, _, _ in
                        guard let self, let data else { conn.cancel(); return }
                        self.bufferUntilComplete(conn, accumulated: accumulated + data)
                    }
                    return
                }
            }
        }
        routeAndRespond(conn, raw: raw)
    }

    // MARK: - Route and Respond

    /// Parse, authenticate, route, and respond. Runs on main queue (from NWListener).
    /// Async operations (eval, read, screenshot) use evaluateJavaScript's callback API
    /// through the automation service, which dispatches results via a completion handler.
    private func routeAndRespond(_ conn: NWConnection, raw: String) {
        let (method, path, headers) = parseRequestLine(raw)

        // Host validation — reject requests that are missing the Host header or
        // whose Host doesn't match the loopback allowlist (prevents DNS rebinding).
        let allowedHosts: Set<String> = [
            "127.0.0.1:\(boundPort)", "localhost:\(boundPort)",
            "127.0.0.1", "localhost"
        ]
        guard let host = headers["host"]?.lowercased(), allowedHosts.contains(host) else {
            respond(conn, AgentResponse.failure(code: "FORBIDDEN", message: "Invalid Host")); return
        }

        // CORS protection — reject any cross-origin request. A browser-based page
        // sending fetch() to the local API will include an Origin header; rejecting
        // it prevents CSRF attacks from pages loaded in the browser itself.
        if let origin = headers["origin"], !origin.isEmpty {
            sendHTTP(conn, status: 403, contentType: "application/json",
                     body: Data(#"{"error":"FORBIDDEN","message":"Cross-origin requests are not allowed"}"#.utf8))
            return
        }

        // Health (no auth)
        if path == "/health" {
            respondRaw(conn, status: 200, json: ["status": "ok", "browser": "Agent Browser", "version": "0.3.0"]); return
        }

        // Auth
        guard (headers["authorization"] ?? "") == "Bearer \(token)" else {
            respond(conn, AgentResponse.failure(code: "UNAUTHORIZED", message: "Invalid or missing token")); return
        }

        // Build the AgentRequest from either POST /agent or REST routes
        let body = extractJSONBody(from: raw)
        let request = buildRequest(method: method, path: path, body: body)

        guard let request else {
            respond(conn, AgentResponse.failure(code: ErrorCode.unknownMethod, message: "Not found: \(method) \(path)")); return
        }

        // We're on the main queue (NWListener runs on .main). Use assumeIsolated
        // to call the @MainActor automation service. The callback-based dispatch
        // avoids async/await, keeping the run loop free for WKWebView callbacks.
        MainActor.assumeIsolated {
            self.automationService.dispatchWithCallback(request) { [weak self] response in
                self?.respond(conn, response)
            }
        }
    }

    private func buildRequest(method: String, path: String, body: [String: Any]?) -> AgentRequest? {
        // Structured protocol: POST /agent
        if method == "POST" && path == "/agent" {
            guard let body,
                  let data = try? JSONSerialization.data(withJSONObject: body),
                  let req = try? JSONDecoder().decode(AgentRequest.self, from: data) else {
                return AgentRequest(method: "__bad_request__")
            }
            return req
        }

        // REST convenience routes
        let segs = path.split(separator: "/").map(String.init)

        if method == "GET" && segs == ["api", "tabs"] {
            return AgentRequest(method: "tabs.list")
        }
        if method == "POST" && segs == ["api", "tabs"] {
            let url = body?["url"] as? String ?? ""
            return AgentRequest(method: "tabs.open", params: ["url": AnyCodable(url)])
        }
        if segs.count >= 3 && segs[0] == "api" && segs[1] == "tabs" {
            let tabID = segs[2]
            let action = segs.count > 3 ? segs[3] : nil
            switch (method, action) {
            case ("GET", nil):
                return AgentRequest(method: "tabs.get", params: ["id": AnyCodable(tabID)])
            case (_, "read"):
                let fmt = body?["format"] as? String ?? "markdown"
                return AgentRequest(method: "page.read", params: ["id": AnyCodable(tabID), "format": AnyCodable(fmt)])
            case ("POST", "js"):
                let script = body?["script"] as? String ?? ""
                return AgentRequest(method: "page.eval", params: ["id": AnyCodable(tabID), "script": AnyCodable(script)])
            case ("GET", "screenshot"):
                return AgentRequest(method: "page.screenshot", params: ["id": AnyCodable(tabID)])
            case (_, "inspect"):
                return AgentRequest(method: "page.inspect", params: ["id": AnyCodable(tabID)])
            case ("POST", "click"):
                let elId = body?["elementId"] as? String ?? ""
                return AgentRequest(method: "page.click", params: ["id": AnyCodable(tabID), "elementId": AnyCodable(elId)])
            case ("POST", "fill"):
                let elId = body?["elementId"] as? String ?? ""
                let val = body?["value"] as? String ?? ""
                return AgentRequest(method: "page.fill", params: ["id": AnyCodable(tabID), "elementId": AnyCodable(elId), "value": AnyCodable(val)])
            case ("POST", "press"):
                let elId = body?["elementId"] as? String
                let key = body?["key"] as? String ?? ""
                var p: [String: AnyCodable] = ["id": AnyCodable(tabID), "key": AnyCodable(key)]
                if let elId { p["elementId"] = AnyCodable(elId) }
                return AgentRequest(method: "page.press", params: p)
            case ("POST", "select"):
                let elId = body?["elementId"] as? String ?? ""
                let val = body?["value"] as? String ?? ""
                return AgentRequest(method: "page.select", params: ["id": AnyCodable(tabID), "elementId": AnyCodable(elId), "value": AnyCodable(val)])
            case ("POST", "wait"):
                let cond = body?["condition"] as? String ?? "load"
                let val = body?["value"] as? String
                let timeout = body?["timeout"] as? Double ?? 10.0
                var p: [String: AnyCodable] = ["id": AnyCodable(tabID), "condition": AnyCodable(cond), "timeout": AnyCodable(timeout)]
                if let val { p["value"] = AnyCodable(val) }
                return AgentRequest(method: "page.wait", params: p)
            default:
                return nil
            }
        }
        return nil
    }

    // MARK: - Response

    private func respond(_ conn: NWConnection, _ resp: AgentResponse) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(resp) else { conn.cancel(); return }
        sendHTTP(conn, status: resp.ok ? 200 : 400, contentType: "application/json", body: data)
    }

    private func respondRaw(_ conn: NWConnection, status: Int, json: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]) else {
            conn.cancel(); return
        }
        sendHTTP(conn, status: status, contentType: "application/json", body: data)
    }

    private func sendHTTP(_ conn: NWConnection, status: Int, contentType: String, body: Data) {
        let text: String = switch status {
        case 200: "OK"; case 201: "Created"; case 400: "Bad Request"
        case 401: "Unauthorized"; case 403: "Forbidden"; case 404: "Not Found"
        case 413: "Payload Too Large"
        default: "Error"
        }
        var header = "HTTP/1.1 \(status) \(text)\r\nContent-Type: \(contentType)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        var responseData = Data(header.utf8)
        responseData.append(body)
        conn.send(content: responseData, completion: .contentProcessed { _ in conn.cancel() })
    }

    // MARK: - Parsing

    private func parseRequestLine(_ raw: String) -> (String, String, [String: String]) {
        var headers: [String: String] = [:]
        let lines = raw.components(separatedBy: "\r\n")
        let parts = (lines.first ?? "").split(separator: " ")
        let method = parts.count > 0 ? String(parts[0]) : ""
        let path = parts.count > 1 ? String(parts[1]) : ""
        for line in lines.dropFirst() {
            if line.isEmpty { break }
            if let c = line.firstIndex(of: ":") {
                headers[String(line[..<c]).trimmingCharacters(in: .whitespaces).lowercased()] =
                    String(line[line.index(after: c)...]).trimmingCharacters(in: .whitespaces)
            }
        }
        return (method, path, headers)
    }

    private func extractJSONBody(from raw: String) -> [String: Any]? {
        guard let r = raw.range(of: "\r\n\r\n") else { return nil }
        let s = String(raw[r.upperBound...])
        guard !s.isEmpty, let d = s.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: d) as? [String: Any]
    }

    // MARK: - Token / Descriptor

    private static func generateToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    private func writeConnectionDescriptor() {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/agent-browser")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let desc: [String: Any] = ["url": "http://127.0.0.1:\(boundPort)", "token": token,
                                    "pid": ProcessInfo.processInfo.processIdentifier, "version": "0.3.0"]
        let finalPath = dir.appendingPathComponent("connection.json")
        guard let data = try? JSONSerialization.data(withJSONObject: desc, options: [.prettyPrinted, .sortedKeys]) else { return }
        // Write to a temp file with mode 0600 set BEFORE rename so there is no
        // window where the file exists world-readable (TOCTOU fix).
        let tmpPath = dir.appendingPathComponent(".connection.json.tmp")
        let attributes: [FileAttributeKey: Any] = [.posixPermissions: 0o600]
        FileManager.default.createFile(atPath: tmpPath.path, contents: data, attributes: attributes)
        try? FileManager.default.removeItem(at: finalPath)
        try? FileManager.default.moveItem(at: tmpPath, to: finalPath)
    }

    private func removeConnectionDescriptor() {
        try? FileManager.default.removeItem(at: FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/agent-browser/connection.json"))
    }
}
