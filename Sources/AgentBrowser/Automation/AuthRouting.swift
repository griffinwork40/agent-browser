import AppKit
import WebKit

// MARK: - Auth Method Routing
//
// Routes auth.status, auth.accounts, and auth.fillFromKeychain methods.
// Separated from InteractiveAutomation.swift for the 350 LOC rule.

extension BrowserAutomationService {

    // MARK: - Callback Routing

    /// Route auth methods. Returns true if handled.
    func routeAuth(
        _ method: String, params: [String: Any],
        completion: @escaping (AgentResponse) -> Void
    ) -> Bool {
        switch method {
        case "auth.status":
            guard let id = params["id"] as? String else {
                completion(.failure(code: ErrorCode.invalidParams, message: "Missing 'id'"))
                return true
            }
            authStatusCallback(tabId: id, completion: completion)
            return true

        case "auth.accounts":
            guard let domain = params["domain"] as? String else {
                completion(.failure(code: ErrorCode.invalidParams, message: "Missing 'domain'"))
                return true
            }
            let result = keychainAccounts(domain: domain)
            if let error = result.error {
                completion(.failure(code: ErrorCode.keychainError, message: error))
            } else {
                completion(.success(KeychainAccountsResult(
                    domain: domain, accounts: result.accounts ?? []
                )))
            }
            return true

        case "auth.fillFromKeychain":
            guard let id = params["id"] as? String,
                  let elId = params["elementId"] as? String,
                  let domain = params["domain"] as? String else {
                completion(.failure(
                    code: ErrorCode.invalidParams,
                    message: "Missing 'id', 'elementId', or 'domain'"
                ))
                return true
            }
            let credType = KeychainCredentialType(
                rawValue: params["type"] as? String ?? "password"
            ) ?? .password
            let account = params["account"] as? String
            fillFromKeychainCallback(
                tabId: id, elementId: elId, domain: domain,
                credentialType: credType, account: account,
                completion: completion
            )
            return true

        default:
            return false
        }
    }

    // MARK: - Async Routing

    /// Route auth methods (async). Returns nil if not handled.
    func routeAuthAsync(
        _ method: String, params: [String: Any]
    ) async -> AgentResponse? {
        switch method {
        case "auth.status":
            guard let id = params["id"] as? String else {
                return .failure(code: ErrorCode.invalidParams, message: "Missing 'id'")
            }
            return await authStatusResponse(tabId: id)

        case "auth.accounts":
            guard let domain = params["domain"] as? String else {
                return .failure(code: ErrorCode.invalidParams, message: "Missing 'domain'")
            }
            let result = keychainAccounts(domain: domain)
            if let error = result.error {
                return .failure(code: ErrorCode.keychainError, message: error)
            } else {
                return .success(KeychainAccountsResult(
                    domain: domain, accounts: result.accounts ?? []
                ))
            }

        case "auth.fillFromKeychain":
            guard let id = params["id"] as? String,
                  let elId = params["elementId"] as? String,
                  let domain = params["domain"] as? String else {
                return .failure(
                    code: ErrorCode.invalidParams,
                    message: "Missing 'id', 'elementId', or 'domain'"
                )
            }
            let credType = KeychainCredentialType(
                rawValue: params["type"] as? String ?? "password"
            ) ?? .password
            let account = params["account"] as? String
            return await fillFromKeychainResponse(
                tabId: id, elementId: elId, domain: domain,
                credentialType: credType, account: account
            )

        default:
            return nil
        }
    }
}
