import AppKit
import WebKit
import Security
import LocalAuthentication

// MARK: - Keychain Credential Lookup + Atomic DOM Fill
//
// Option F: Scoped Keychain + Human-Gated Dispatch.
// The credential is retrieved from the macOS Keychain via SecItemCopyMatching
// and injected directly into the WKWebView via JavaScript -- the secret never
// appears in any HTTP response, MCP payload, or model context window.
//
// The OS displays a native permission dialog before returning the credential
// (kSecUseAuthenticationContext = LAContext with interactionNotAllowed = false),
// so the OS displays a native Touch ID / password dialog before returning the credential.

extension BrowserAutomationService {

    // MARK: - Public API

    /// Fill a form field with a credential from the macOS Keychain.
    /// The credential is looked up and injected directly into the DOM via the
    /// JS bridge. It is never included in any response payload or model context.
    /// Note: Swift `String` provides no deterministic secure-erase guarantee;
    /// the credential value resides in process memory until ARC reclaims it.
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

        // Step 1: Look up the credential from the Keychain OFF the main thread.
        // SecItemCopyMatching with interactionNotAllowed=false blocks until the
        // user responds to Touch ID / password dialog -- must not freeze the UI.
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

            // Step 2: Inject the credential directly into the DOM via the JS bridge.
            // Use callAsyncJavaScript with structured arguments so the credential is
            // passed as a data binding, never interpolated into JS source code.
            // WKWebView calls must happen on the main thread.
            let script = "return window.__agentBrowser.fill(elementId, value)"
            DispatchQueue.main.async {
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

        // Run keychainLookup off the main thread -- SecItemCopyMatching with
        // interactionNotAllowed=false blocks until user responds to the OS dialog.
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

        // Use callAsyncJavaScript with structured arguments so the credential is
        // passed as a data binding, never interpolated into JS source code.
        let script = "return window.__agentBrowser.fill(elementId, value)"
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

    // MARK: - Keychain Lookup

    /// Look up a credential from the macOS Keychain.
    /// Returns the credential string or nil + error message.
    /// The OS will display a native permission dialog before returning.
    ///
    /// This query intentionally does NOT restrict `kSecAttrAccessGroup`, which means
    /// it searches across all keychain groups accessible to this process. This is by
    /// design: the OS shows a native Touch ID / password dialog for each access,
    /// and that permission dialog serves as the access-control boundary — not
    /// app-scoped keychain group filtering. Restricting to a single group would
    /// silently exclude credentials stored by the browser or password manager.
    ///
    /// - Parameters:
    ///   - domain: The server/domain to scope the keychain query.
    ///   - account: Optional account name to pin the query to a specific entry.
    ///     For `.username` lookups where `account` is nil and multiple entries exist
    ///     for the domain, pass `account` from a prior `keychainAccounts` call;
    ///     omitting it returns one entry non-deterministically (OS-defined order).
    ///   - type: Whether to retrieve the password data or the account name.
    private func keychainLookup(
        domain: String,
        account: String?,
        type: KeychainCredentialType
    ) -> (value: String?, error: String?) {
        // LAContext allows the OS to show the auth UI (Touch ID / password dialog)
        let context = LAContext()
        context.interactionNotAllowed = false

        // Base attributes shared by both paths.
        var base: [String: Any] = [
            kSecClass as String: kSecClassInternetPassword,
            kSecAttrServer as String: domain,
            kSecUseAuthenticationContext as String: context,
        ]
        if let account {
            base[kSecAttrAccount as String] = account
        }

        // Build a type-specific query rather than mutating a shared dict.
        let query: [String: Any]
        switch type {
        case .password:
            // Return raw password bytes; decode as UTF-8 below.
            query = base.merging([
                kSecReturnData as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne,
            ]) { _, new in new }

        case .username:
            // Return attributes (kSecAttrAccount) only -- never request password data.
            // kSecMatchLimitOne is intentional: when account==nil and multiple entries
            // exist for the domain the OS picks one non-deterministically. Callers that
            // need a specific account should pass one (sourced from keychainAccounts).
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

    /// List available accounts for a domain (no passwords returned).
    /// Used by auth.accounts to let the agent know which accounts exist.
    /// Uses interactionNotAllowed = true because this reads only metadata
    /// (account names, not secrets) — no auth UI is needed or appropriate.
    /// If some items are interaction-protected, errSecInteractionNotAllowed is
    /// handled gracefully by returning whatever accounts were accessible.
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

        if status == errSecItemNotFound {
            return ([], nil)
        }

        // If interaction is required for protected items, return what we got.
        // A nil result here just means no unprotected attributes were accessible.
        if status == errSecInteractionNotAllowed {
            return ([], nil)
        }

        guard status == errSecSuccess else {
            return (nil, keychainErrorMessage(status))
        }

        guard let items = result as? [[String: Any]] else {
            return ([], nil)
        }

        let accounts = items.compactMap { $0[kSecAttrAccount as String] as? String }
        // Deduplicate (same account may have multiple entries)
        return (Array(Set(accounts)).sorted(), nil)
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
