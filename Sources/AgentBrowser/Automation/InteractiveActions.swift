import AppKit
import WebKit

// MARK: - Action Execution & Wait Primitives
//
// Implementation of click/fill/press/select actions and wait polling.
// Separated from InteractiveAutomation.swift for the 350 LOC rule.

extension BrowserAutomationService {

    // MARK: - Action Execution (Callback)

    func actionCallback(
        id: String, elementId: String, action: String,
        jsArgs: String = "", completion: @escaping (AgentResponse) -> Void
    ) {
        let escapedId = escapeJSString(elementId)
        let args = jsArgs.isEmpty ? "'\(escapedId)'" : "'\(escapedId)', \(jsArgs)"
        // JS functions already return JSON.stringify'd results -- do NOT double-stringify
        let script = "window.__agentBrowser.\(action)(\(args))"
        runActionScript(id: id, elementId: elementId, action: action, script: script, completion: completion)
    }

    func runActionScript(
        id: String, elementId: String?, action: String,
        script: String, completion: @escaping (AgentResponse) -> Void
    ) {
        guard let tab = resolveTab(id) else {
            completion(.failure(code: ErrorCode.tabNotFound, message: "No tab with id: \(id)")); return
        }
        let tabID = tab.id.uuidString
        tab.webView.evaluateJavaScript(script) { result, error in
            DispatchQueue.main.async {
                if let error {
                    completion(.failure(code: ErrorCode.javaScriptError, message: error.localizedDescription)); return
                }
                completion(Self.parseActionResult(raw: result, tabID: tabID, elementId: elementId, action: action))
            }
        }
    }

    // MARK: - Action Execution (Async)

    func asyncActionResponse(id: String, elementId: String?, action: String, value: String?) async -> AgentResponse {
        guard let tab = resolveTab(id) else {
            return .failure(code: ErrorCode.tabNotFound, message: "No tab with id: \(id)")
        }

        let script: String
        switch action {
        case "click":
            guard let elId = elementId else {
                return .failure(code: ErrorCode.invalidParams, message: "Missing 'elementId'")
            }
            script = "window.__agentBrowser.click('\(escapeJSString(elId))')"
        case "fill":
            guard let elId = elementId else {
                return .failure(code: ErrorCode.invalidParams, message: "Missing 'elementId'")
            }
            let v = escapeJSString(value ?? "")
            script = "window.__agentBrowser.fill('\(escapeJSString(elId))', '\(v)')"
        case "press":
            let handleArg = elementId.map { "'\(escapeJSString($0))'" } ?? "null"
            script = "window.__agentBrowser.press(\(handleArg), '\(escapeJSString(value ?? ""))')"
        case "select":
            guard let elId = elementId else {
                return .failure(code: ErrorCode.invalidParams, message: "Missing 'elementId'")
            }
            let v = escapeJSString(value ?? "")
            script = "window.__agentBrowser.select('\(escapeJSString(elId))', '\(v)')"
        default:
            return .failure(code: ErrorCode.unknownMethod, message: "Unknown action: \(action)")
        }

        do {
            let raw = try await evalJSOnTab(tab, script: script)
            return Self.parseActionResult(raw: raw, tabID: tab.id.uuidString, elementId: elementId, action: action)
        } catch {
            return .failure(code: ErrorCode.javaScriptError, message: error.localizedDescription)
        }
    }

    static func parseActionResult(raw: Any?, tabID: String, elementId: String?, action: String) -> AgentResponse {
        guard let jsonString = raw as? String,
              let data = jsonString.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .failure(code: ErrorCode.javaScriptError, message: "Failed to parse \(action) result")
        }
        if let err = dict["error"] as? String {
            return .failure(code: mapJSErrorCode(err), message: err)
        }
        return .success(ActionResult(
            ok: true, id: tabID, elementId: elementId, action: action,
            error: nil, detail: dict["previousValue"] as? String
        ))
    }

    // MARK: - Wait (Callback)

    func waitCallback(
        id: String, condition: String, value: String?,
        timeout: Double, completion: @escaping (AgentResponse) -> Void
    ) {
        guard let tab = resolveTab(id) else {
            completion(.failure(code: ErrorCode.tabNotFound, message: "No tab with id: \(id)")); return
        }
        let start = CFAbsoluteTimeGetCurrent()
        let tabID = tab.id.uuidString

        switch condition {
        case "url":
            pollURL(tab: tab, pattern: value ?? "", timeout: timeout, start: start) { elapsed, err in
                DispatchQueue.main.async {
                    completion(.success(WaitResult(ok: err == nil, id: tabID, condition: "url", elapsed: elapsed, error: err)))
                }
            }
        case "text":
            let escaped = escapeJSString(value ?? "")
            let script = "JSON.stringify(window.__agentBrowser.waitForText('\(escaped)', \(Int(timeout * 1000))))"
            tab.webView.evaluateJavaScript(script) { result, error in
                DispatchQueue.main.async {
                    let elapsed = CFAbsoluteTimeGetCurrent() - start
                    if let error {
                        completion(.failure(code: ErrorCode.javaScriptError, message: error.localizedDescription)); return
                    }
                    let err = Self.parseWaitError(raw: result)
                    completion(.success(WaitResult(ok: err == nil, id: tabID, condition: "text", elapsed: elapsed, error: err)))
                }
            }
        case "element":
            let condJSON = Self.buildWaitCondition(value: value)
            let script = "JSON.stringify(window.__agentBrowser.waitForElement(\(condJSON), \(Int(timeout * 1000))))"
            tab.webView.evaluateJavaScript(script) { result, error in
                DispatchQueue.main.async {
                    let elapsed = CFAbsoluteTimeGetCurrent() - start
                    if let error {
                        completion(.failure(code: ErrorCode.javaScriptError, message: error.localizedDescription)); return
                    }
                    let err = Self.parseWaitError(raw: result)
                    completion(.success(WaitResult(ok: err == nil, id: tabID, condition: "element", elapsed: elapsed, error: err)))
                }
            }
        default: // "load"
            pollLoading(tab: tab, timeout: timeout, start: start) { elapsed, err in
                DispatchQueue.main.async {
                    completion(.success(WaitResult(ok: err == nil, id: tabID, condition: "load", elapsed: elapsed, error: err)))
                }
            }
        }
    }

    // MARK: - Wait (Async)

    func waitResponse(id: String, condition: String, value: String?, timeout: Double) async -> AgentResponse {
        guard let tab = resolveTab(id) else {
            return .failure(code: ErrorCode.tabNotFound, message: "No tab with id: \(id)")
        }
        let start = CFAbsoluteTimeGetCurrent()
        let tabID = tab.id.uuidString

        switch condition {
        case "url":
            let (elapsed, err) = await withCheckedContinuation { cont in
                pollURL(tab: tab, pattern: value ?? "", timeout: timeout, start: start) { e, err in
                    cont.resume(returning: (e, err))
                }
            }
            return .success(WaitResult(ok: err == nil, id: tabID, condition: "url", elapsed: elapsed, error: err))
        case "load":
            let (elapsed, err) = await withCheckedContinuation { cont in
                pollLoading(tab: tab, timeout: timeout, start: start) { e, err in
                    cont.resume(returning: (e, err))
                }
            }
            return .success(WaitResult(ok: err == nil, id: tabID, condition: "load", elapsed: elapsed, error: err))
        default:
            // text/element use JS-side polling
            let script: String
            if condition == "text" {
                script = "JSON.stringify(window.__agentBrowser.waitForText('\(escapeJSString(value ?? ""))', \(Int(timeout * 1000))))"
            } else {
                let cond = Self.buildWaitCondition(value: value)
                script = "JSON.stringify(window.__agentBrowser.waitForElement(\(cond), \(Int(timeout * 1000))))"
            }
            do {
                let raw = try await evalJSOnTab(tab, script: script)
                let elapsed = CFAbsoluteTimeGetCurrent() - start
                let err = Self.parseWaitError(raw: raw)
                return .success(WaitResult(ok: err == nil, id: tabID, condition: condition, elapsed: elapsed, error: err))
            } catch {
                return .failure(code: ErrorCode.javaScriptError, message: error.localizedDescription)
            }
        }
    }

    // MARK: - Polling Helpers

    private func pollURL(tab: BrowserTab, pattern: String, timeout: Double, start: CFAbsoluteTime,
                         completion: @escaping (Double, String?) -> Void) {
        let elapsed = CFAbsoluteTimeGetCurrent() - start
        if elapsed >= timeout {
            completion(elapsed, "WAIT_TIMEOUT: URL did not match '\(pattern)' within \(timeout)s"); return
        }
        if (tab.url?.absoluteString ?? "").contains(pattern) || pattern.isEmpty {
            completion(elapsed, nil); return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.pollURL(tab: tab, pattern: pattern, timeout: timeout, start: start, completion: completion)
        }
    }

    private func pollLoading(tab: BrowserTab, timeout: Double, start: CFAbsoluteTime,
                             completion: @escaping (Double, String?) -> Void) {
        let elapsed = CFAbsoluteTimeGetCurrent() - start
        if elapsed >= timeout {
            completion(elapsed, "WAIT_TIMEOUT: Page did not finish loading within \(timeout)s"); return
        }
        if !tab.isLoading { completion(elapsed, nil); return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.pollLoading(tab: tab, timeout: timeout, start: start, completion: completion)
        }
    }

    // MARK: - Wait Parsing Helpers

    static func parseWaitError(raw: Any?) -> String? {
        guard let jsonString = raw as? String,
              let data = jsonString.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return dict["error"] as? String
    }

    static func buildWaitCondition(value: String?) -> String {
        guard let value, !value.isEmpty else { return "{}" }
        if value.hasPrefix(".") || value.hasPrefix("#") || value.hasPrefix("[") {
            return "{\"selector\":\"\(value.replacingOccurrences(of: "\"", with: "\\\""))\"}"
        }
        return "{\"text\":\"\(value.replacingOccurrences(of: "\"", with: "\\\""))\"}"
    }
}
