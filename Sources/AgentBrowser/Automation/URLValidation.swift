import Foundation

// MARK: - Shared URL Validation
//
// Extracted from TabOperations.openURLResponse and NavigationOperations.navigateResponse.
// Both callers apply identical normalisation + scheme-guard logic, so this is the
// single source of truth.

extension BrowserAutomationService {

    /// Normalise a raw URL string and verify it is a safe http/https URL.
    ///
    /// - Parameter urlString: The caller-supplied string (may omit scheme).
    /// - Returns: `.success(URL)` with the resolved URL, or `.failure(AgentErrorDetail)`
    ///   which callers convert to an `AgentResponse` via `.failure(code: detail.code, message: detail.message)`.
    ///
    /// Normalisation rules:
    /// 1. If the string has no scheme and looks like a hostname (contains `.`, no spaces),
    ///    prepend `https://`.
    /// 2. Reject anything that still cannot be parsed by `URL(string:)`.
    /// 3. Reject non-http(s) schemes to prevent `file://` and `javascript:` injection.
    func validateAndResolveURL(_ urlString: String) -> Result<URL, AgentErrorDetail> {
        var resolved = urlString

        if URL(string: resolved)?.scheme == nil {
            if resolved.contains(".") && !resolved.contains(" ") {
                resolved = "https://\(resolved)"
            } else {
                return .failure(AgentErrorDetail(code: ErrorCode.invalidURL, message: "Cannot parse URL: \(urlString)"))
            }
        }

        guard let url = URL(string: resolved) else {
            return .failure(AgentErrorDetail(code: ErrorCode.invalidURL, message: "Cannot parse URL: \(urlString)"))
        }

        // Reject non-http(s) schemes (e.g. file://, javascript:) to prevent
        // the agent API from being used as a local-file or JS-injection vector.
        guard ["http", "https"].contains(url.scheme?.lowercased()) else {
            return .failure(AgentErrorDetail(code: ErrorCode.invalidURL, message: "Unsupported URL scheme: \(url.scheme ?? "none")"))
        }

        return .success(url)
    }
}
