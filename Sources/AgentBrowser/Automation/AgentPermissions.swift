import Foundation

// MARK: - AgentPermissionSet

/// Read/write/click capability restrictions for a single agent.
/// nil allowedDomains means all domains are permitted.
struct AgentPermissionSet: Codable, Sendable {
    var canRead: Bool
    var canWrite: Bool
    var canClick: Bool
    var canNavigate: Bool
    var canEval: Bool
    /// Allows this agent to call `agent.permissions.set` (promote/restrict other agents).
    /// Only agents with canAdmin=true may mutate the permission store.
    var canAdmin: Bool
    /// Domain allowlist. nil = unrestricted. Non-nil = only these hostnames allowed.
    var allowedDomains: [String]?

    // MARK: - Presets

    /// Full access: all capabilities, no domain restrictions.
    static let full = AgentPermissionSet(
        canRead: true, canWrite: true, canClick: true,
        canNavigate: true, canEval: true, canAdmin: true, allowedDomains: nil
    )

    /// Read-only: can inspect/screenshot/read but not mutate.
    static let readOnly = AgentPermissionSet(
        canRead: true, canWrite: false, canClick: false,
        canNavigate: false, canEval: false, canAdmin: false, allowedDomains: nil
    )

    /// Everything except eval (safe for untrusted script execution).
    static let noEval = AgentPermissionSet(
        canRead: true, canWrite: true, canClick: true,
        canNavigate: true, canEval: false, canAdmin: false, allowedDomains: nil
    )
}

// MARK: - PermissionError

/// Wraps a human-readable permission-denied message so it can be used in `Result<Void, Error>`.
struct PermissionError: Error {
    let message: String
}

// MARK: - AgentPermissionStore

/// Stores per-agent permission sets, keyed by agentID.
/// Defaults to .full for any unknown agent.
@MainActor
final class AgentPermissionStore {
    private var permissions: [String: AgentPermissionSet] = [:]

    // MARK: - Mutation

    func setPermissions(for agentID: String, _ perms: AgentPermissionSet) {
        permissions[agentID] = perms
    }

    func removePermissions(for agentID: String) {
        permissions.removeValue(forKey: agentID)
    }

    // MARK: - Query

    func permissions(for agentID: String) -> AgentPermissionSet {
        permissions[agentID] ?? .full
    }

    // MARK: - Permission Check

    /// Returns .success(()) if the agent is permitted to call this method,
    /// or .failure(PermissionError) describing the denied capability.
    ///
    /// Capability checks run first; domain enforcement follows for navigation methods.
    func checkPermission(agentID: String, method: String, url: String? = nil) -> Result<Void, PermissionError> {
        let perms = permissions(for: agentID)

        switch method {
        // Read capability
        case "page.read", "page.screenshot", "page.inspect", "tabs.list", "tabs.get":
            guard perms.canRead else {
                return .failure(PermissionError(message: "Agent '\(agentID)' lacks canRead for '\(method)'"))
            }

        // Click/fill/interact capability
        case "page.click", "page.fill", "page.press", "page.select", "page.wait":
            guard perms.canClick else {
                return .failure(PermissionError(message: "Agent '\(agentID)' lacks canClick for '\(method)'"))
            }

        // Eval capability
        case "page.eval":
            guard perms.canEval else {
                return .failure(PermissionError(message: "Agent '\(agentID)' lacks canEval for '\(method)'"))
            }

        // Navigate capability — also enforce domain allowlist when present
        case "tabs.open", "tabs.navigate", "page.back", "page.forward", "page.reload":
            guard perms.canNavigate else {
                return .failure(PermissionError(message: "Agent '\(agentID)' lacks canNavigate for '\(method)'"))
            }
            if let domains = perms.allowedDomains, let urlString = url {
                guard let host = URL(string: urlString)?.host,
                      domains.contains(where: { host == $0 || host.hasSuffix(".\($0)") }) else {
                    let target = url ?? "(no URL)"
                    return .failure(PermissionError(
                        message: "Agent '\(agentID)' domain not in allowlist for '\(method)': \(target)"
                    ))
                }
            }

        // Write capability (non-navigation mutations)
        case "tabs.close", "tabs.switch":
            guard perms.canWrite else {
                return .failure(PermissionError(message: "Agent '\(agentID)' lacks canWrite for '\(method)'"))
            }

        // agent.permissions.get — always allowed (self-query, read-only)
        case "agent.permissions.get":
            break

        // agent.permissions.set — requires canAdmin to prevent privilege escalation
        case "agent.permissions.set":
            guard perms.canAdmin else {
                return .failure(PermissionError(
                    message: "Agent '\(agentID)' lacks canAdmin; cannot call '\(method)'"
                ))
            }

        // Auth methods require read at minimum
        case let m where m.hasPrefix("auth."):
            guard perms.canRead else {
                return .failure(PermissionError(message: "Agent '\(agentID)' lacks canRead for '\(method)'"))
            }

        default:
            break
        }

        return .success(())
    }
}
