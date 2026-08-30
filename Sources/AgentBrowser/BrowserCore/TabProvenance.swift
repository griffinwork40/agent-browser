import Foundation

/// Records who (human or which agent) created a tab.
///
/// The `restored` case flattens original provenance fields to avoid
/// nested-Self encoding complexity while preserving enough data for
/// display and filtering.
enum TabProvenance: Sendable, Codable, Hashable {
    /// Tab opened by a human user.
    case human

    /// Tab opened programmatically by an agent.
    ///
    /// - Parameters:
    ///   - agentID: Stable identifier for the agent type or instance.
    ///   - sessionTag: The agent session that requested the tab (for grouping).
    ///   - requestedAt: Wall-clock time the request was issued.
    case agent(agentID: String, sessionTag: String, requestedAt: Date)

    /// Tab recreated from a persisted session.
    ///
    /// - Parameters:
    ///   - originalAgentID: Non-nil if the original tab was agent-created.
    ///   - originalSessionTag: The session tag from the original agent request, if any.
    case restored(originalAgentID: String?, originalSessionTag: String?)

    /// Whether this tab was created (originally) by an agent.
    var isAgentCreated: Bool {
        switch self {
        case .human: return false
        case .agent: return true
        case .restored(let agentID, _): return agentID != nil
        }
    }

    /// The agent ID, if one exists for this provenance.
    var agentID: String? {
        switch self {
        case .human: return nil
        case .agent(let id, _, _): return id
        case .restored(let id, _): return id
        }
    }
}
