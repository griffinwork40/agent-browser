import AppKit
import WebKit

// MARK: - Interactive Automation Types & Routing
//
// Extension of BrowserAutomationService for inspect, click, fill, press, select, wait.
// Uses the automation-bridge.js injected into every page for DOM operations.
//
// Concurrency: callback-based dispatch for HTTP, async for tests/MCP.

extension BrowserAutomationService {

    // MARK: - Data Types

    struct InspectResult: Codable, Sendable {
        let id: String
        let url: String?
        let title: String
        let generation: Int
        let elementCount: Int
        let elements: [[String: AnyCodable]]
    }

    struct ActionResult: Codable, Sendable {
        let ok: Bool
        let id: String
        let elementId: String?
        let action: String
        let error: String?
        let detail: String?
    }

    struct WaitResult: Codable, Sendable {
        let ok: Bool
        let id: String
        let condition: String
        let elapsed: Double
        let error: String?
    }

    // MARK: - Callback Routing

    /// Route interactive methods. Returns true if handled.
    func routeInteractive(
        _ method: String, params: [String: Any],
        completion: @escaping (AgentResponse) -> Void
    ) -> Bool {
        switch method {
        case "page.inspect":
            guard let id = params["id"] as? String else {
                completion(.failure(code: ErrorCode.invalidParams, message: "Missing 'id'")); return true
            }
            inspectCallback(id: id, completion: completion)
            return true

        case "page.click":
            guard let id = params["id"] as? String, let elId = params["elementId"] as? String else {
                completion(.failure(code: ErrorCode.invalidParams, message: "Missing 'id' or 'elementId'")); return true
            }
            actionCallback(id: id, elementId: elId, action: "click", completion: completion)
            return true

        case "page.fill":
            guard let id = params["id"] as? String, let elId = params["elementId"] as? String,
                  let value = params["value"] as? String else {
                completion(.failure(code: ErrorCode.invalidParams, message: "Missing 'id', 'elementId', or 'value'")); return true
            }
            let escaped = escapeJSString(value)
            actionCallback(id: id, elementId: elId, action: "fill", jsArgs: "'\(escaped)'", completion: completion)
            return true

        case "page.press":
            guard let id = params["id"] as? String, let key = params["key"] as? String else {
                completion(.failure(code: ErrorCode.invalidParams, message: "Missing 'id' or 'key'")); return true
            }
            let elId = params["elementId"] as? String
            let handleArg = elId.map { "'\(escapeJSString($0))'" } ?? "null"
            let script = "window.__agentBrowser.press(\(handleArg), '\(escapeJSString(key))')"
            runActionScript(id: id, elementId: elId, action: "press", script: script, completion: completion)
            return true

        case "page.select":
            guard let id = params["id"] as? String, let elId = params["elementId"] as? String,
                  let value = params["value"] as? String else {
                completion(.failure(code: ErrorCode.invalidParams, message: "Missing 'id', 'elementId', or 'value'")); return true
            }
            actionCallback(id: id, elementId: elId, action: "select", jsArgs: "'\(escapeJSString(value))'", completion: completion)
            return true

        case "page.wait":
            guard let id = params["id"] as? String else {
                completion(.failure(code: ErrorCode.invalidParams, message: "Missing 'id'")); return true
            }
            let condition = params["condition"] as? String ?? "load"
            let value = params["value"] as? String
            let timeout = (params["timeout"] as? Double) ?? Double(params["timeout"] as? Int ?? 10)
            waitCallback(id: id, condition: condition, value: value, timeout: timeout, completion: completion)
            return true

        default:
            return false
        }
    }

    // MARK: - Async Routing

    /// Route interactive methods. Returns nil if not handled.
    func routeInteractiveAsync(_ method: String, params: [String: Any]) async -> AgentResponse? {
        switch method {
        case "page.inspect":
            guard let id = params["id"] as? String else {
                return .failure(code: ErrorCode.invalidParams, message: "Missing 'id'")
            }
            return await inspectResponse(id: id)

        case "page.click":
            guard let id = params["id"] as? String, let elId = params["elementId"] as? String else {
                return .failure(code: ErrorCode.invalidParams, message: "Missing 'id' or 'elementId'")
            }
            return await asyncActionResponse(id: id, elementId: elId, action: "click", value: nil)

        case "page.fill":
            guard let id = params["id"] as? String, let elId = params["elementId"] as? String,
                  let value = params["value"] as? String else {
                return .failure(code: ErrorCode.invalidParams, message: "Missing 'id', 'elementId', or 'value'")
            }
            return await asyncActionResponse(id: id, elementId: elId, action: "fill", value: value)

        case "page.press":
            guard let id = params["id"] as? String, let key = params["key"] as? String else {
                return .failure(code: ErrorCode.invalidParams, message: "Missing 'id' or 'key'")
            }
            let elId = params["elementId"] as? String
            return await asyncActionResponse(id: id, elementId: elId, action: "press", value: key)

        case "page.select":
            guard let id = params["id"] as? String, let elId = params["elementId"] as? String,
                  let value = params["value"] as? String else {
                return .failure(code: ErrorCode.invalidParams, message: "Missing 'id', 'elementId', or 'value'")
            }
            return await asyncActionResponse(id: id, elementId: elId, action: "select", value: value)

        case "page.wait":
            guard let id = params["id"] as? String else {
                return .failure(code: ErrorCode.invalidParams, message: "Missing 'id'")
            }
            let condition = params["condition"] as? String ?? "load"
            let value = params["value"] as? String
            let timeout = (params["timeout"] as? Double) ?? Double(params["timeout"] as? Int ?? 10)
            return await waitResponse(id: id, condition: condition, value: value, timeout: timeout)

        default:
            return nil
        }
    }

    // MARK: - Inspect Implementation

    func inspectCallback(id: String, completion: @escaping (AgentResponse) -> Void) {
        guard let tab = resolveTab(id) else {
            completion(.failure(code: ErrorCode.tabNotFound, message: "No tab with id: \(id)")); return
        }
        // inspect() already returns a JSON string -- do NOT double-stringify
        let script = "window.__agentBrowser ? window.__agentBrowser.inspect() : JSON.stringify({error:'BRIDGE_NOT_LOADED'})"
        let tabID = tab.id.uuidString
        let tabTitle = tab.title
        let tabURL = tab.url?.absoluteString

        // The bridge lives in the isolated AgentBridge content world.
        tab.webView.evaluateJavaScript(script, in: nil, in: .world(name: "AgentBridge")) { resultOrError in
            DispatchQueue.main.async {
                switch resultOrError {
                case .failure(let error):
                    completion(.failure(code: ErrorCode.javaScriptError, message: error.localizedDescription))
                case .success(let result):
                    completion(Self.parseInspectResult(raw: result, tabID: tabID, title: tabTitle, url: tabURL))
                }
            }
        }
    }

    private func inspectResponse(id: String) async -> AgentResponse {
        guard let tab = resolveTab(id) else {
            return .failure(code: ErrorCode.tabNotFound, message: "No tab with id: \(id)")
        }
        let script = "window.__agentBrowser ? window.__agentBrowser.inspect() : JSON.stringify({error:'BRIDGE_NOT_LOADED'})"
        do {
            let raw = try await evalJSOnTabInBridgeWorld(tab, script: script)
            return Self.parseInspectResult(raw: raw, tabID: tab.id.uuidString, title: tab.title, url: tab.url?.absoluteString)
        } catch {
            return .failure(code: ErrorCode.javaScriptError, message: error.localizedDescription)
        }
    }

    static func parseInspectResult(raw: Any?, tabID: String, title: String, url: String?) -> AgentResponse {
        guard let jsonString = raw as? String,
              let data = jsonString.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .failure(code: ErrorCode.extractionFailed, message: "Failed to parse inspect result")
        }
        if let err = dict["error"] as? String {
            return .failure(code: ErrorCode.javaScriptError, message: err)
        }
        let generation = dict["generation"] as? Int ?? 0
        let elements = dict["elements"] as? [[String: Any]] ?? []
        let mapped = elements.map { el in el.mapValues { AnyCodable($0) } }
        return .success(InspectResult(
            id: tabID, url: url, title: title,
            generation: generation, elementCount: mapped.count, elements: mapped
        ))
    }

    // MARK: - Shared JS Helpers

    /// Evaluate JS in the default (page content) world.
    func evalJSOnTab(_ tab: BrowserTab, script: String) async throws -> Any? {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Any?, Error>) in
            tab.webView.evaluateJavaScript(script) { result, error in
                if let error { cont.resume(throwing: error) }
                else { cont.resume(returning: result) }
            }
        }
    }

    /// Evaluate JS in the isolated AgentBridge content world (for bridge calls).
    func evalJSOnTabInBridgeWorld(_ tab: BrowserTab, script: String) async throws -> Any? {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Any?, Error>) in
            tab.webView.evaluateJavaScript(script, in: nil, in: .world(name: "AgentBridge")) { result in
                switch result {
                case .failure(let error): cont.resume(throwing: error)
                case .success(let value): cont.resume(returning: value)
                }
            }
        }
    }

    func escapeJSString(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
         .replacingOccurrences(of: "'", with: "\\'")
         .replacingOccurrences(of: "\n", with: "\\n")
         .replacingOccurrences(of: "\r", with: "\\r")
    }

    static func mapJSErrorCode(_ error: String) -> String {
        switch error {
        case "ELEMENT_NOT_FOUND": return ErrorCode.elementNotFound
        case "ELEMENT_STALE": return ErrorCode.elementStale
        case "ELEMENT_NOT_VISIBLE", "ELEMENT_DISABLED", "ELEMENT_NOT_INTERACTABLE":
            return ErrorCode.elementNotInteractable
        case "UNSUPPORTED_ELEMENT": return ErrorCode.unsupportedElement
        case "WAIT_TIMEOUT": return ErrorCode.waitTimeout
        default: return ErrorCode.javaScriptError
        }
    }
}
