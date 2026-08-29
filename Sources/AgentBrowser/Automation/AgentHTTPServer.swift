import Foundation
import Network

/// Minimal HTTP server on 127.0.0.1 that exposes BrowserAutomationService
/// to external processes (CLI tools, MCP clients, coding agents).
///
/// Uses Network.framework's NWListener -- zero third-party dependencies.
/// Binds to loopback only; external machines cannot connect.
final class AgentHTTPServer {
    private let automationService: BrowserAutomationService
    private var listener: NWListener?
    private let requestedPort: UInt16
    let token: String

    /// Actual port after binding (may differ from requested if fallback was needed).
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
                        print("[AgentHTTPServer] Token: \(self.token)")
                    case .failed(let error):
                        print("[AgentHTTPServer] Failed on port \(port): \(error)")
                        self.listener?.cancel()
                        if attempt < 10 {
                            self.tryBind(port: port + 1, attempt: attempt + 1)
                        }
                    default:
                        break
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

        connection.receive(minimumIncompleteLength: 1, maximumLength: 1_048_576) { [weak self] data, _, _, error in
            DispatchQueue.main.async {
                guard let self, let data else {
                    connection.cancel()
                    return
                }

                guard let requestString = String(data: data, encoding: .utf8) else {
                    self.sendResponse(connection, status: 400, body: ["error": "Invalid request"])
                    return
                }

                self.routeRequest(connection, raw: requestString)
            }
        }
    }

    // MARK: - Routing

    private func routeRequest(_ connection: NWConnection, raw: String) {
        let lines = raw.split(separator: "\r\n", maxSplits: 1)
        guard let requestLine = lines.first else {
            sendResponse(connection, status: 400, body: ["error": "Empty request"])
            return
        }

        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else {
            sendResponse(connection, status: 400, body: ["error": "Malformed request line"])
            return
        }

        let method = String(parts[0])
        let path = String(parts[1])
        let headers = parseHeaders(raw)

        // Security: validate Host header (DNS rebinding defense)
        if let host = headers["host"] {
            let allowed = [
                "127.0.0.1:\(boundPort)", "localhost:\(boundPort)",
                "127.0.0.1", "localhost"
            ]
            if !allowed.contains(host.lowercased()) {
                sendResponse(connection, status: 403, body: ["error": "Forbidden: invalid Host header"])
                return
            }
        }

        // Security: validate bearer token (skip for /health)
        if path != "/health" {
            let authHeader = headers["authorization"] ?? ""
            if authHeader != "Bearer \(token)" {
                sendResponse(connection, status: 401, body: ["error": "Unauthorized"])
                return
            }
        }

        let jsonBody = extractJSONBody(from: raw)

        // All automation calls must happen on @MainActor
        Task { @MainActor in
            await self.dispatch(connection, method: method, path: path, body: jsonBody)
        }
    }

    @MainActor
    private func dispatch(_ connection: NWConnection, method: String, path: String, body: [String: Any]?) async {
        switch (method, path) {

        case ("GET", "/health"):
            sendResponse(connection, status: 200, body: [
                "status": "ok",
                "browser": "Agent Browser",
                "tabs": automationService.listTabs().count
            ])

        case ("GET", "/api/tabs"):
            sendCodableResponse(connection, status: 200, value: automationService.listTabs())

        case ("GET", _) where path.hasPrefix("/api/tabs/") && !path.contains("/read") && !path.contains("/js") && !path.contains("/screenshot"):
            let tabID = String(path.dropFirst("/api/tabs/".count))
            do {
                let detail = try automationService.getTab(id: tabID)
                sendCodableResponse(connection, status: 200, value: detail)
            } catch {
                sendResponse(connection, status: 404, body: ["error": error.localizedDescription])
            }

        case ("POST", "/api/tabs"):
            guard let urlString = body?["url"] as? String else {
                sendResponse(connection, status: 400, body: ["error": "Missing 'url' in request body"])
                return
            }
            do {
                let result = try automationService.openURL(urlString)
                sendCodableResponse(connection, status: 201, value: result)
            } catch {
                sendResponse(connection, status: 400, body: ["error": error.localizedDescription])
            }

        case (_, _) where path.hasSuffix("/read"):
            let tabID = extractTabID(from: path, suffix: "/read")
            let includeHTML = (body?["html"] as? Bool) ?? false
            do {
                let content = try await automationService.readPage(id: tabID, includeHTML: includeHTML)
                sendCodableResponse(connection, status: 200, value: content)
            } catch {
                sendResponse(connection, status: 404, body: ["error": error.localizedDescription])
            }

        case ("POST", _) where path.hasSuffix("/js"):
            let tabID = extractTabID(from: path, suffix: "/js")
            guard let script = body?["script"] as? String else {
                sendResponse(connection, status: 400, body: ["error": "Missing 'script' in request body"])
                return
            }
            do {
                let result = try await automationService.executeJavaScript(id: tabID, script: script)
                sendCodableResponse(connection, status: 200, value: result)
            } catch {
                sendResponse(connection, status: 500, body: ["error": error.localizedDescription])
            }

        case ("GET", _) where path.hasSuffix("/screenshot"):
            let tabID = extractTabID(from: path, suffix: "/screenshot")
            do {
                let result = try await automationService.screenshot(id: tabID)
                sendPNGResponse(connection, data: result.pngData)
            } catch {
                sendResponse(connection, status: 404, body: ["error": error.localizedDescription])
            }

        default:
            sendResponse(connection, status: 404, body: ["error": "Not found: \(method) \(path)"])
        }
    }

    // MARK: - HTTP Response Helpers

    private func sendResponse(_ connection: NWConnection, status: Int, body: [String: Any]) {
        guard let jsonData = try? JSONSerialization.data(withJSONObject: body, options: [.prettyPrinted, .sortedKeys]) else {
            connection.cancel()
            return
        }
        sendRawResponse(connection, status: status, contentType: "application/json", body: jsonData)
    }

    private func sendCodableResponse<T: Encodable>(_ connection: NWConnection, status: Int, value: T) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let jsonData = try? encoder.encode(value) else {
            sendResponse(connection, status: 500, body: ["error": "Failed to encode response"])
            return
        }
        sendRawResponse(connection, status: status, contentType: "application/json", body: jsonData)
    }

    private func sendPNGResponse(_ connection: NWConnection, data: Data) {
        sendRawResponse(connection, status: 200, contentType: "image/png", body: data)
    }

    private func sendRawResponse(_ connection: NWConnection, status: Int, contentType: String, body: Data) {
        let statusText: String
        switch status {
        case 200: statusText = "OK"
        case 201: statusText = "Created"
        case 400: statusText = "Bad Request"
        case 401: statusText = "Unauthorized"
        case 403: statusText = "Forbidden"
        case 404: statusText = "Not Found"
        case 500: statusText = "Internal Server Error"
        default: statusText = "Unknown"
        }

        var header = "HTTP/1.1 \(status) \(statusText)\r\n"
        header += "Content-Type: \(contentType)\r\n"
        header += "Content-Length: \(body.count)\r\n"
        header += "Connection: close\r\n"
        header += "\r\n"

        var responseData = Data(header.utf8)
        responseData.append(body)

        connection.send(content: responseData, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    // MARK: - Parsing Helpers

    private func parseHeaders(_ raw: String) -> [String: String] {
        var headers: [String: String] = [:]
        let lines = raw.components(separatedBy: "\r\n")
        for line in lines.dropFirst() {
            if line.isEmpty { break }
            if let colonIndex = line.firstIndex(of: ":") {
                let key = String(line[line.startIndex..<colonIndex]).trimmingCharacters(in: .whitespaces).lowercased()
                let value = String(line[line.index(after: colonIndex)...]).trimmingCharacters(in: .whitespaces)
                headers[key] = value
            }
        }
        return headers
    }

    private func extractJSONBody(from raw: String) -> [String: Any]? {
        guard let range = raw.range(of: "\r\n\r\n") else { return nil }
        let bodyString = String(raw[range.upperBound...])
        guard !bodyString.isEmpty,
              let data = bodyString.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return json
    }

    private func extractTabID(from path: String, suffix: String) -> String {
        var cleaned = path
        if cleaned.hasPrefix("/api/tabs/") {
            cleaned = String(cleaned.dropFirst("/api/tabs/".count))
        }
        if cleaned.hasSuffix(suffix) {
            cleaned = String(cleaned.dropLast(suffix.count))
        }
        return cleaned
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
            "version": "0.1.0"
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
