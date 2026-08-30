import Foundation

/// Browser call helpers for MCPTools.
/// Converts browser API responses into MCP tool result content arrays.
extension MCPTools {

    /// Generic browser call: serialize result as JSON text.
    func callBrowser(method: String, params: [String: Any] = [:]) -> ([[String: Any]], Bool) {
        let (result, error) = BrowserClient.call(method: method, params: params)
        if let error { return toolError(error) }
        guard let result else { return textContent("OK") }
        return textContent(jsonString(result))
    }

    /// Read: extract content field for cleaner output.
    func callBrowserRead(params: [String: Any]) -> ([[String: Any]], Bool) {
        let (result, error) = BrowserClient.call(method: "page.read", params: params)
        if let error { return toolError(error) }
        guard let dict = result as? [String: Any] else { return toolError("Unexpected response") }
        let title = dict["title"] as? String ?? ""
        let url = dict["url"] as? String ?? ""
        let content = dict["content"] as? String ?? ""
        let mode = dict["mode"] as? String
        let characters = dict["characters"] as? Int ?? content.count
        let truncated = dict["truncated"] as? Bool ?? false

        var header = "# \(title)\nURL: \(url)"
        if let mode { header += "\nMode: \(mode)" }
        header += "\nCharacters: \(characters)"
        if truncated { header += " (truncated)" }
        header += "\n\n"

        let text = header + content
        return textContent(text)
    }

    /// Inspect: format elements for agent readability.
    func callBrowserInspect(params: [String: Any]) -> ([[String: Any]], Bool) {
        let (result, error) = BrowserClient.call(method: "page.inspect", params: params)
        if let error { return toolError(error) }
        guard let dict = result as? [String: Any] else { return toolError("Unexpected response") }

        let title = dict["title"] as? String ?? ""
        let url = dict["url"] as? String ?? ""
        let returned = dict["returned"] as? Int ?? 0
        let total = dict["totalInteractive"] as? Int ?? 0
        let truncated = dict["truncated"] as? Bool ?? false
        let mode = dict["mode"] as? String ?? "interactive"
        let elements = dict["elements"] as? [[String: Any]] ?? []

        var lines = [
            "Page: \(title)",
            "URL: \(url)",
            "Elements: \(returned) of \(total)\(truncated ? " (showing top \(returned))" : "")",
            "Mode: \(mode)",
            ""
        ]

        for el in elements {
            let id = el["id"] as? String ?? "?"
            let tag = el["tag"] as? String ?? "?"
            let role = el["role"] as? String ?? ""
            let name = el["name"] as? String ?? ""
            let text = (el["text"] as? String ?? "")
            let truncText = text.count > 60 ? String(text.prefix(60)) + "..." : text
            let ph = el["placeholder"] as? String ?? ""
            let inputType = el["inputType"] as? String ?? ""
            let href = el["href"] as? String ?? ""
            let disabled = el["disabled"] as? Bool ?? false
            let value = el["value"] as? String ?? ""

            var parts = [id, tag]
            if !role.isEmpty { parts.append("role=\(role)") }
            let label = !name.isEmpty ? name : (!truncText.isEmpty ? truncText : ph)
            if !label.isEmpty { parts.append("\"\(label)\"") }
            if !inputType.isEmpty { parts.append("type=\(inputType)") }
            if !value.isEmpty { parts.append("value=\"\(value)\"") }
            if !href.isEmpty { parts.append("href=\(String(href.prefix(80)))") }
            if disabled { parts.append("[disabled]") }
            lines.append(parts.joined(separator: "  "))
        }
        return textContent(lines.joined(separator: "\n"))
    }

    /// Screenshot: return as MCP image content.
    func callBrowserScreenshot(params: [String: Any]) -> ([[String: Any]], Bool) {
        let (result, error) = BrowserClient.call(method: "page.screenshot", params: params)
        if let error { return toolError(error) }
        guard let dict = result as? [String: Any],
              let base64 = dict["data"] as? String,
              let width = dict["width"] as? Int,
              let height = dict["height"] as? Int else {
            return toolError("Failed to capture screenshot")
        }
        let content: [[String: Any]] = [
            ["type": "text", "text": "Screenshot: \(width)x\(height) PNG"],
            ["type": "image", "data": base64, "mimeType": "image/png"]
        ]
        return (content, false)
    }

    /// Fill from Keychain: the response must NEVER contain the credential.
    /// The browser host does the Keychain lookup + DOM fill atomically.
    /// We only report success/failure to the MCP client.
    func callBrowserFillFromKeychain(params: [String: Any]) -> ([[String: Any]], Bool) {
        let (result, error) = BrowserClient.call(method: "auth.fillFromKeychain", params: params)
        if let error { return toolError(error) }
        guard let dict = result as? [String: Any] else { return toolError("Unexpected response") }

        // Strip any credential data that might leak through -- only pass safe fields
        let elementId = dict["elementId"] as? String
        let domain = params["domain"] as? String ?? ""
        let type = params["type"] as? String ?? "password"

        if let err = dict["error"] as? String {
            return textContent("Failed to fill \(type) for \(domain): \(err)")
        }

        var msg = "Filled \(type) field"
        if let elementId { msg += " (\(elementId))" }
        msg += " from Keychain for \(domain)"
        msg += " -- credential was injected directly into the page (not shown here)"
        return textContent(msg)
    }

    // MARK: - Internal Helpers

    private func toolError(_ message: String) -> ([[String: Any]], Bool) {
        ([["type": "text", "text": message]], true)
    }

    private func textContent(_ text: String) -> ([[String: Any]], Bool) {
        ([["type": "text", "text": text]], false)
    }

    private func jsonString(_ value: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]),
              let str = String(data: data, encoding: .utf8) else {
            return String(describing: value)
        }
        return str
    }
}
