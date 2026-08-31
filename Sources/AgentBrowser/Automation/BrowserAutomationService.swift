import AppKit
import WebKit

/// Transport-independent automation API over live browser tabs.
///
/// This is the single point of entry for any external control surface
/// (HTTP server, CLI, MCP, XPC). It operates on the SAME live WKWebView
/// instances the human is using. No headless browser. No duplicate sessions.
///
/// All methods are @MainActor because WKWebView operations must run on main.
///
/// Implementation is split across extension files:
/// - `TabOperations.swift`         -- tabs.list, tabs.get, tabs.open
/// - `PageOperations.swift`        -- page.read, page.eval, page.screenshot
/// - `InteractiveAutomation.swift` -- page.inspect, page.click, page.fill, page.press, page.select, page.wait
/// - `InteractiveActions.swift`    -- action execution & wait primitives
/// - `AuthRouting.swift`           -- auth.status, auth.accounts, auth.fillFromKeychain, auth.requestHandoff
/// - `KeychainFill.swift`          -- Keychain credential lookup & fill
/// - `PasskeyHandoff.swift`        -- Passkey/WebAuthn human-handoff
@MainActor
final class BrowserAutomationService {
    let tabManager: TabManager
    private(set) var takeoverHandler: TakeoverHandler

    init(tabManager: TabManager, takeoverHandler: TakeoverHandler) {
        self.tabManager = tabManager
        self.takeoverHandler = takeoverHandler
    }

    // MARK: - Callback-based Dispatch (for HTTP server)

    /// Dispatch via completion handler. Avoids async/await so the main run loop
    /// stays free for WKWebView's evaluateJavaScript callbacks. This is the
    /// primary entry point for the HTTP server.
    func dispatchWithCallback(_ request: AgentRequest, completion: @escaping (AgentResponse) -> Void) {
        guard request.version == 1 else {
            completion(.failure(code: ErrorCode.badRequest, message: "Unsupported protocol version: \(request.version)"))
            return
        }

        let params = request.params?.mapValues(\.value) ?? [:]

        switch request.method {
        // Tab operations
        case "tabs.list":
            completion(.success(listTabs()))
        case "tabs.get":
            guard let id = params["id"] as? String else {
                completion(.failure(code: ErrorCode.invalidParams, message: "Missing 'id' parameter")); return
            }
            completion(getTabResponse(id: id))
        case "tabs.open":
            guard let url = params["url"] as? String else {
                completion(.failure(code: ErrorCode.invalidParams, message: "Missing 'url' parameter")); return
            }
            completion(openURLResponse(url))

        // Page operations (async -- use callback-based WKWebView APIs)
        case "page.read":
            guard let id = params["id"] as? String else {
                completion(.failure(code: ErrorCode.invalidParams, message: "Missing 'id' parameter")); return
            }
            let format = params["format"] as? String ?? "markdown"
            let mode = params["mode"] as? String
            let query = params["query"] as? String
            let budget = params["budget"] as? Int
            readPageCallback(id: id, format: format, mode: mode, query: query, budget: budget, completion: completion)
        case "page.eval":
            guard let id = params["id"] as? String, let script = params["script"] as? String else {
                completion(.failure(code: ErrorCode.invalidParams, message: "Missing 'id' or 'script' parameter")); return
            }
            evalJSCallback(id: id, script: script, completion: completion)
        case "page.screenshot":
            guard let id = params["id"] as? String else {
                completion(.failure(code: ErrorCode.invalidParams, message: "Missing 'id' parameter")); return
            }
            screenshotCallback(id: id, completion: completion)

        case "__bad_request__":
            completion(.failure(code: ErrorCode.badRequest, message: "Invalid AgentRequest JSON"))
        default:
            // Try interactive automation methods (inspect, click, fill, press, select, wait)
            if routeInteractive(request.method, params: params, completion: completion) { return }
            completion(.failure(code: ErrorCode.unknownMethod, message: "Unknown method: \(request.method)"))
        }
    }

    // MARK: - Async Dispatch (for tests and future MCP)

    /// Dispatch a structured protocol request. Returns a structured response.
    func dispatch(_ request: AgentRequest) async -> AgentResponse {
        guard request.version == 1 else {
            return .failure(code: ErrorCode.badRequest, message: "Unsupported protocol version: \(request.version)")
        }

        let params = request.params?.mapValues(\.value) ?? [:]

        switch request.method {
        // Tab operations
        case "tabs.list":
            return .success(listTabs())

        case "tabs.get":
            guard let id = params["id"] as? String else {
                return .failure(code: ErrorCode.invalidParams, message: "Missing 'id' parameter")
            }
            return getTabResponse(id: id)

        case "tabs.open":
            guard let url = params["url"] as? String else {
                return .failure(code: ErrorCode.invalidParams, message: "Missing 'url' parameter")
            }
            return openURLResponse(url)

        // Page operations
        case "page.read":
            guard let id = params["id"] as? String else {
                return .failure(code: ErrorCode.invalidParams, message: "Missing 'id' parameter")
            }
            let format = params["format"] as? String ?? "markdown"
            let mode = params["mode"] as? String
            let query = params["query"] as? String
            let budget = params["budget"] as? Int
            return await readPageResponse(id: id, format: format, mode: mode, query: query, budget: budget)

        case "page.eval":
            guard let id = params["id"] as? String,
                  let script = params["script"] as? String else {
                return .failure(code: ErrorCode.invalidParams, message: "Missing 'id' or 'script' parameter")
            }
            return await evalJSResponse(id: id, script: script)

        case "page.screenshot":
            guard let id = params["id"] as? String else {
                return .failure(code: ErrorCode.invalidParams, message: "Missing 'id' parameter")
            }
            return await screenshotResponse(id: id)

        default:
            // Try interactive automation methods (inspect, click, fill, press, select, wait)
            if let response = await routeInteractiveAsync(request.method, params: params) {
                return response
            }
            return .failure(code: ErrorCode.unknownMethod, message: "Unknown method: \(request.method)")
        }
    }

    // MARK: - Shared Helpers

    func resolveTab(_ id: String) -> BrowserTab? {
        guard let uuid = UUID(uuidString: id) else { return nil }
        return tabManager.tab(for: uuid)
    }

    /// Evaluate JS using the callback API (NOT the async overload which crashes on void returns).
    /// Includes a 10-second timeout to prevent indefinite hangs when the WKWebView is in a
    /// state that prevents callback delivery (zero frame, not in hierarchy, process suspended).
    func evaluateJS(on webView: WKWebView, script: String) async throws -> Any? {
#if DEBUG
        print("[evaluateJS] Starting eval, frame=\(webView.frame), superview=\(webView.superview != nil)")
#endif
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Any?, Error>) in
#if DEBUG
            print("[evaluateJS] About to call evaluateJavaScript")
#endif
            webView.evaluateJavaScript(script) { result, error in
#if DEBUG
                print("[evaluateJS] Callback received: result=\(String(describing: result)), error=\(String(describing: error))")
#endif
                if let error {
                    cont.resume(throwing: error)
                } else {
                    cont.resume(returning: result)
                }
            }
#if DEBUG
            print("[evaluateJS] evaluateJavaScript called, waiting for callback")
#endif
        }
    }
}
