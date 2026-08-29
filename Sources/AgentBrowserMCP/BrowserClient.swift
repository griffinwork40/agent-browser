import Foundation

/// HTTP client for the running Agent Browser instance.
/// Discovers connection info from ~/.config/agent-browser/connection.json.
/// All calls go through POST /agent with Bearer token auth.
struct BrowserClient {

    struct ConnectionInfo {
        let url: String
        let token: String
        let pid: Int
    }

    /// Discover the running browser from the connection descriptor.
    /// Returns nil if the browser is not running or the descriptor is stale.
    static func discover() -> ConnectionInfo? {
        let path = NSString("~/.config/agent-browser/connection.json").expandingTildeInPath
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let url = dict["url"] as? String,
              let token = dict["token"] as? String,
              let pid = dict["pid"] as? Int else {
            return nil
        }
        // Verify the process is alive
        if kill(Int32(pid), 0) != 0 { return nil }
        return ConnectionInfo(url: url, token: token, pid: pid)
    }

    /// Call a browser automation method synchronously.
    /// Returns (result dict, error string or nil).
    static func call(method: String, params: [String: Any] = [:]) -> (Any?, String?) {
        guard let conn = discover() else {
            return (nil, "Agent Browser is not running. Launch Agent Browser first.")
        }

        let body: [String: Any] = [
            "version": 1,
            "method": method,
            "params": params
        ]

        guard let bodyData = try? JSONSerialization.data(withJSONObject: body),
              let url = URL(string: "\(conn.url)/agent") else {
            return (nil, "Failed to construct request")
        }

        // Extract host for DNS rebinding defense
        let host = url.host.map { h in
            url.port.map { "\(h):\($0)" } ?? h
        } ?? "127.0.0.1:8833"

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = bodyData
        request.setValue("Bearer \(conn.token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(host, forHTTPHeaderField: "Host")
        request.timeoutInterval = 30

        let semaphore = DispatchSemaphore(value: 0)
        var responseData: Data?
        var responseError: Error?

        let task = URLSession.shared.dataTask(with: request) { data, _, error in
            responseData = data
            responseError = error
            semaphore.signal()
        }
        task.resume()
        semaphore.wait()

        if let error = responseError {
            return (nil, "HTTP error: \(error.localizedDescription)")
        }
        guard let data = responseData,
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return (nil, "Failed to parse browser response")
        }

        let ok = dict["ok"] as? Bool ?? false
        if ok {
            return (dict["result"], nil)
        } else {
            let errorDict = dict["error"] as? [String: Any]
            let code = errorDict?["code"] as? String ?? "UNKNOWN"
            let message = errorDict?["message"] as? String ?? "Unknown error"
            return (nil, "\(code): \(message)")
        }
    }
}
