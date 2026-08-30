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

        // Step 1: Look up the credential from the Keychain.
        // SecItemCopyMatching will trigger the OS permission dialog.
        let lookup = keychainLookup(
            domain: domain,
            account: account,
            type: credentialType
        )

        if let error = lookup.error {
            completion(.failure(code: ErrorCode.keychainError, message: error))
            return
        }

        guard let credential = lookup.value else {
            completion(.failure(code: ErrorCode.keychainError, message: "No credential found"))
            return
        }

        // Step 2: Inject the credential directly into the DOM via the JS bridge.
        // The credential value is passed into JS and immediately discarded.
        let escapedId = escapeJSString(elementId)
        let escapedValue = escapeJSString(credential)

        let script = "window.__agentBrowser.fill('\(escapedId)', '\(escapedValue)')"

        tab.webView.evaluateJavaScript(
            script, in: nil, in: .world(name: "AgentBridge")
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

        let lookup = keychainLookup(
            domain: domain,
            account: account,
            type: credentialType
        )

        if let error = lookup.error {
            return .failure(code: ErrorCode.keychainError, message: error)
        }

        guard let credential = lookup.value else {
            return .failure(code: ErrorCode.keychainError, message: "No credential found")
        }

        let escapedId = escapeJSString(elementId)
        let escapedValue = escapeJSString(credential)
        let script = "window.__agentBrowser.fill('\(escapedId)', '\(escapedValue)')"

        do {
            let raw = try await evalJSOnTabInBridgeWorld(tab, script: script)
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
    func keychainAccounts(domain: String) -> (accounts: [String]?, error: String?) {
        let context = LAContext()
        context.interactionNotAllowed = false

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
