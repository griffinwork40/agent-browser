import AppKit
import WebKit
import Security
import LocalAuthentication

// MARK: - Keychain Credential Lookup + Atomic DOM Fill
//
// Option F: Scoped Keychain + Human-Gated Dispatch.
// Credential retrieved via SecItemCopyMatching, injected into the WKWebView via JS.
// Never appears in any HTTP response, MCP payload, or model context window.
// OS shows a native Touch ID / password dialog before returning the credential.

extension BrowserAutomationService {

    // MARK: - Public API

    /// Fill a form field from the Keychain. Credential is never in any response payload.
    /// Note: Swift String provides no deterministic secure-erase; value lives in ARC memory.
    func fillFromKeychainCallback(
        tabId: String,
        elementId: String,
        domain: String,
        credentialType: KeychainCredentialType,
        account: String?,
        completion: @escaping (AgentResponse) -> Void
    ) {
        guard let tab = resolveTab(tabId) else {
            completion(.failure(code: ErrorCode.tabNotFound, message: "No tab with id: \(tabId)"))
            return
        }

        // Step 1: Keychain lookup off main thread — SecItemCopyMatching blocks on OS dialog.
        DispatchQueue.global(qos: .userInitiated).async {
            let lookup = self.keychainLookup(
                domain: domain,
                account: account,
                type: credentialType
            )

            if let error = lookup.error {
                DispatchQueue.main.async {
                    completion(.failure(code: ErrorCode.keychainError, message: error))
                }
                return
            }

            guard let credential = lookup.value else {
                DispatchQueue.main.async {
                    completion(.failure(code: ErrorCode.keychainError, message: "No credential found"))
                }
                return
            }

            // Step 2: Inject via JS bridge on main thread.
            // markKeychainFilled suppresses previousValue for this element (A5).
            let script = """
                window.__agentBrowser.markKeychainFilled(elementId);
                return window.__agentBrowser.fill(elementId, value)
                """
            DispatchQueue.main.async {
                // A4: verify origin before injection; fail closed on nil URL.
                guard let currentURL = tab.url else {
                    completion(.failure(
                        code: ErrorCode.navigationError,
                        message: "Tab has no committed URL; fill cancelled (A4)"
                    ))
                    return
                }
                guard Self.hostMatches(currentURL: currentURL, requestedDomain: domain) else {
                    completion(.failure(
                        code: ErrorCode.navigationError,
                        message: "Tab navigated to a different origin; fill cancelled (A4)"
                    ))
                    return
                }
                tab.webView.callAsyncJavaScript(
                    script,
                    arguments: ["elementId": elementId, "value": credential],
                    in: nil,
                    in: .world(name: "AgentBridge")
                ) { resultOrError in
                    DispatchQueue.main.async {
                        switch resultOrError {
                        case .failure(let error):
                            completion(.failure(
                                code: ErrorCode.javaScriptError,
                                message: error.localizedDescription
                            ))
                        case .success(let raw):
                            let response = Self.parseActionResult(
                                raw: raw,
                                tabID: tab.id.uuidString,
                                elementId: elementId,
                                action: "fillFromKeychain"
                            )
                            completion(response)
                        }
                    }
                }
            }
        }
    }

    /// Async variant for tests and future MCP.
    func fillFromKeychainResponse(
        tabId: String,
        elementId: String,
        domain: String,
        credentialType: KeychainCredentialType,
        account: String?
    ) async -> AgentResponse {
        guard let tab = resolveTab(tabId) else {
            return .failure(code: ErrorCode.tabNotFound, message: "No tab with id: \(tabId)")
        }

        // Keychain lookup off main thread — blocks on OS dialog.
        let lookup: (value: String?, error: String?) = await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let result = self.keychainLookup(
                    domain: domain,
                    account: account,
                    type: credentialType
                )
                cont.resume(returning: result)
            }
        }

        if let error = lookup.error {
            return .failure(code: ErrorCode.keychainError, message: error)
        }

        guard let credential = lookup.value else {
            return .failure(code: ErrorCode.keychainError, message: "No credential found")
        }

        // A4: verify origin before injection; fail closed on nil URL.
        guard let currentURL = tab.url else {
            return .failure(
                code: ErrorCode.navigationError,
                message: "Tab has no committed URL; fill cancelled (A4)"
            )
        }
        guard Self.hostMatches(currentURL: currentURL, requestedDomain: domain) else {
            return .failure(
                code: ErrorCode.navigationError,
                message: "Tab navigated to a different origin; fill cancelled (A4)"
            )
        }

        // markKeychainFilled suppresses previousValue (A5). Credential passed as
        // a structured argument binding — never interpolated into JS source.
        let script = """
            window.__agentBrowser.markKeychainFilled(elementId);
            return window.__agentBrowser.fill(elementId, value)
            """
        do {
            let raw = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Any?, Error>) in
                tab.webView.callAsyncJavaScript(
                    script,
                    arguments: ["elementId": elementId, "value": credential],
                    in: nil,
                    in: .world(name: "AgentBridge")
                ) { result in
                    switch result {
                    case .failure(let error): cont.resume(throwing: error)
                    case .success(let value): cont.resume(returning: value)
                    }
                }
            }
            return Self.parseActionResult(
                raw: raw,
                tabID: tab.id.uuidString,
                elementId: elementId,
                action: "fillFromKeychain"
            )
        } catch {
            return .failure(
                code: ErrorCode.javaScriptError,
                message: error.localizedDescription
            )
        }
    }

    // MARK: - Origin Validation (A4)

    /// Returns true when the current URL's host is a subdomain-or-equal match
    /// for the requested credential domain.
    ///
    /// Examples:
    ///   currentURL=https://accounts.google.com  domain=google.com  → true
    ///   currentURL=https://evil.com              domain=google.com  → false
    ///   currentURL=https://google.com.evil.com   domain=google.com  → false
    static func hostMatches(currentURL: URL, requestedDomain: String) -> Bool {
        guard let host = currentURL.host else { return false }
        let lHost = host.lowercased()
        let lDomain = requestedDomain.lowercased()
        return lHost == lDomain || lHost.hasSuffix("." + lDomain)
    }

    // MARK: - Keychain Lookup

    /// Look up a credential from the Keychain. OS shows Touch ID / password dialog.
    /// Does not restrict kSecAttrAccessGroup — the OS dialog is the access boundary.
    private func keychainLookup(
        domain: String,
        account: String?,
        type: KeychainCredentialType
    ) -> (value: String?, error: String?) {
        let context = LAContext()
        context.interactionNotAllowed = false
        var base: [String: Any] = [
            kSecClass as String: kSecClassInternetPassword,
            kSecAttrServer as String: domain,
            kSecUseAuthenticationContext as String: context,
        ]
        if let account {
            base[kSecAttrAccount as String] = account
        }

        let query: [String: Any]
        switch type {
        case .password:
            query = base.merging([
                kSecReturnData as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne,
            ]) { _, new in new }

        case .username:
            // kSecMatchLimitOne: non-deterministic when multiple entries exist for domain.
            query = base.merging([
                kSecReturnData as String: false,
                kSecReturnAttributes as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne,
            ]) { _, new in new }
        }

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess else {
            return (nil, keychainErrorMessage(status))
        }

        switch type {
        case .password:
            guard let data = result as? Data,
                  let password = String(data: data, encoding: .utf8) else {
                return (nil, "Failed to decode credential data")
            }
            return (password, nil)
        case .username:
            guard let attrs = result as? [String: Any],
                  let account = attrs[kSecAttrAccount as String] as? String else {
                return (nil, "No account found for domain: \(domain)")
            }
            return (account, nil)
        }
    }

    /// List available accounts for a domain (no passwords). interactionNotAllowed=true
    /// since we only read metadata. Protected items return empty gracefully.
    func keychainAccounts(domain: String) -> (accounts: [String]?, error: String?) {
        let context = LAContext()
        context.interactionNotAllowed = true

        let query: [String: Any] = [
            kSecClass as String: kSecClassInternetPassword,
            kSecAttrServer as String: domain,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecUseAuthenticationContext as String: context,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        if status == errSecItemNotFound { return ([], nil) }
        if status == errSecInteractionNotAllowed { return ([], nil) }

        guard status == errSecSuccess else {
            return (nil, keychainErrorMessage(status))
        }

        guard let items = result as? [[String: Any]] else {
            return ([], nil)
        }

        let accounts = items.compactMap { $0[kSecAttrAccount as String] as? String }
        return (Array(Set(accounts)).sorted(), nil) // deduplicate
    }

    // MARK: - Helpers

    private func keychainErrorMessage(_ status: OSStatus) -> String {
        switch status {
        case errSecItemNotFound:
            return "No credential found for this domain"
        case errSecAuthFailed:
            return "Authentication failed -- user denied access"
        case errSecUserCanceled:
            return "User cancelled the credential dialog"
        case errSecInteractionNotAllowed:
            return "Keychain interaction not allowed (device may be locked)"
        default:
            let msg = SecCopyErrorMessageString(status, nil) as String? ?? "Unknown error"
            return "Keychain error (\(status)): \(msg)"
        }
    }
}

// MARK: - Types

enum KeychainCredentialType: String, Sendable {
    case password
    case username
}

/// Response for auth.accounts -- lists available account names for a domain.
struct KeychainAccountsResult: Codable, Sendable {
    let domain: String
    let accounts: [String]
}

// MARK: - Error Code Extension

extension ErrorCode {
    static let keychainError = "KEYCHAIN_ERROR"
    static let authRequired = "AUTH_REQUIRED"
}
