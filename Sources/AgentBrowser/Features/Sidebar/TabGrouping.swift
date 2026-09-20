// TabGrouping.swift
// Groups agent-created tabs by sessionTag for clustered display in the sidebar.
// Human tabs pass through as ungrouped items. Stable ordering is preserved.

import Foundation

// MARK: - TabGroup

/// A cluster of agent-created tabs that share the same sessionTag.
struct TabGroup: Identifiable {
    /// Stable ID — the sessionTag itself.
    let id: String          // sessionTag
    let agentID: String
    var tabs: [BrowserTab]
    var isCollapsed: Bool = false

    /// Display title: truncates long session tags at 20 chars.
    var displayTitle: String {
        id.count > 20 ? String(id.prefix(20)) + "…" : id
    }
}

// MARK: - TabGroupOrTab

/// Either a collapsed group header or a lone ungrouped tab row.
@MainActor
enum TabGroupOrTab {
    case group(TabGroup)
    case ungrouped(BrowserTab)

    /// Stable string identifier for `ForEach`.
    /// Safe because `TabGroupOrTab` itself is `@MainActor`.
    var id: String {
        switch self {
        case .group(let g):      return "group:\(g.id)"
        case .ungrouped(let t):  return "tab:\(t.id.uuidString)"
        }
    }
}

// MARK: - Grouping logic

/// Organises a flat tab list into groups (by sessionTag) and lone human tabs.
///
/// Algorithm:
/// 1. Walk `tabs` in order, preserving original insertion order.
/// 2. Human tabs emit `.ungrouped` immediately.
/// 3. Agent tabs accumulate into a group keyed by sessionTag; groups are
///    emitted in the position of the *first* tab in that group.
/// 4. Restored tabs with a tag behave like agent tabs; those without are ungrouped.
///
/// - Parameter tabs: The flat tab list from `TabManager.tabs`.
/// - Returns: Ordered array of group headers or lone tab items.
@MainActor
func groupTabs(_ tabs: [BrowserTab]) -> [TabGroupOrTab] {
    // Ordered dictionary approach: track insertion order of groups.
    var groupMap: [String: TabGroup] = [:]      // sessionTag → accumulated group
    var order: [String] = []                    // sessionTag insertion order
    var result: [TabGroupOrTab] = []

    for tab in tabs {
        switch sessionTagAndAgentID(for: tab) {
        case let (tag?, agentID?):
            // Agent tab — merge into its group.
            if groupMap[tag] == nil {
                groupMap[tag] = TabGroup(id: tag, agentID: agentID, tabs: [])
                order.append(tag)
                // Emit a placeholder token (index in result) for this group.
                result.append(.group(TabGroup(id: tag, agentID: agentID, tabs: [])))
            }
            groupMap[tag]!.tabs.append(tab)

        default:
            // Human tab or restored-without-tag — emit directly.
            result.append(.ungrouped(tab))
        }
    }

    // Back-fill populated groups into the result at their placeholder positions.
    return result.map { item in
        guard case .group(let placeholder) = item else { return item }
        if let populated = groupMap[placeholder.id] {
            return .group(populated)
        }
        return item
    }
}

// MARK: - Helpers

/// Extracts the (sessionTag, agentID) pair for grouping, if any.
private func sessionTagAndAgentID(for tab: BrowserTab) -> (String?, String?) {
    switch tab.record.provenance {
    case .agent(let agentID, let sessionTag, _):
        return (sessionTag, agentID)
    case .restored(let originalAgentID, let originalSessionTag):
        return (originalSessionTag, originalAgentID)
    case .human:
        return (nil, nil)
    }
}
