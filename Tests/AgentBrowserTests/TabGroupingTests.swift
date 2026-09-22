// TabGroupingTests.swift
// Unit tests for the tab-grouping logic in TabGrouping.swift.
// All tests run on @MainActor without a display server.

import Testing
import Foundation
@testable import AgentBrowser

@Suite("TabGrouping")
struct TabGroupingTests {

    // MARK: - Helpers

    /// Creates a BrowserTab with .human provenance.
    @MainActor
    private func humanTab() -> BrowserTab {
        let record = TabRecord(provenance: .human)
        return BrowserTab(record: record)
    }

    /// Creates a BrowserTab with .agent provenance.
    @MainActor
    private func agentTab(agentID: String, sessionTag: String) -> BrowserTab {
        let record = TabRecord(
            provenance: .agent(agentID: agentID, sessionTag: sessionTag, requestedAt: Date())
        )
        return BrowserTab(record: record)
    }

    /// Creates a BrowserTab with .restored provenance.
    @MainActor
    private func restoredTab(agentID: String?, sessionTag: String?) -> BrowserTab {
        let record = TabRecord(
            provenance: .restored(originalAgentID: agentID, originalSessionTag: sessionTag)
        )
        return BrowserTab(record: record)
    }

    // MARK: - Empty input

    @Test("Empty tab list returns empty result")
    @MainActor func emptyTabList() {
        let result = groupTabs([])
        #expect(result.isEmpty)
    }

    // MARK: - Human tabs are ungrouped

    @Test("Single human tab emits ungrouped item")
    @MainActor func singleHumanTab() {
        let tab = humanTab()
        let result = groupTabs([tab])

        #expect(result.count == 1)
        guard case .ungrouped(let t) = result[0] else {
            Issue.record("Expected ungrouped, got group")
            return
        }
        #expect(t.id == tab.id)
    }

    @Test("Multiple human tabs all appear as ungrouped")
    @MainActor func multipleHumanTabs() {
        let tabs = [humanTab(), humanTab(), humanTab()]
        let result = groupTabs(tabs)

        #expect(result.count == 3)
        for item in result {
            guard case .ungrouped = item else {
                Issue.record("Expected ungrouped item")
                return
            }
        }
    }

    // MARK: - Agent tabs are grouped by sessionTag

    @Test("Two agent tabs with the same sessionTag produce one group")
    @MainActor func agentTabsGroupedByTag() {
        let t1 = agentTab(agentID: "agent-1", sessionTag: "session-A")
        let t2 = agentTab(agentID: "agent-1", sessionTag: "session-A")
        let result = groupTabs([t1, t2])

        #expect(result.count == 1)
        guard case .group(let group) = result[0] else {
            Issue.record("Expected group, got ungrouped")
            return
        }
        #expect(group.id == "session-A")
        #expect(group.tabs.count == 2)
        #expect(group.tabs[0].id == t1.id)
        #expect(group.tabs[1].id == t2.id)
    }

    @Test("Agent tabs with different sessionTags produce separate groups")
    @MainActor func agentTabsDifferentTags() {
        let t1 = agentTab(agentID: "agent-1", sessionTag: "session-A")
        let t2 = agentTab(agentID: "agent-1", sessionTag: "session-B")
        let result = groupTabs([t1, t2])

        #expect(result.count == 2)
        guard case .group(let gA) = result[0] else {
            Issue.record("Expected group at index 0")
            return
        }
        guard case .group(let gB) = result[1] else {
            Issue.record("Expected group at index 1")
            return
        }
        #expect(gA.id == "session-A")
        #expect(gB.id == "session-B")
        #expect(gA.tabs.count == 1)
        #expect(gB.tabs.count == 1)
    }

    @Test("Group agentID comes from the first tab's agentID")
    @MainActor func groupAgentID() {
        let t1 = agentTab(agentID: "my-agent", sessionTag: "sess-1")
        let t2 = agentTab(agentID: "my-agent", sessionTag: "sess-1")
        let result = groupTabs([t1, t2])

        guard case .group(let group) = result[0] else {
            Issue.record("Expected group")
            return
        }
        #expect(group.agentID == "my-agent")
    }

    // MARK: - Mixed tabs preserve order

    @Test("Human tabs before agent group appear first")
    @MainActor func humanBeforeGroup() {
        let h1 = humanTab()
        let a1 = agentTab(agentID: "ag", sessionTag: "s1")
        let a2 = agentTab(agentID: "ag", sessionTag: "s1")
        let result = groupTabs([h1, a1, a2])

        #expect(result.count == 2)
        guard case .ungrouped(let t) = result[0] else {
            Issue.record("Expected ungrouped at index 0")
            return
        }
        #expect(t.id == h1.id)
        guard case .group(let g) = result[1] else {
            Issue.record("Expected group at index 1")
            return
        }
        #expect(g.tabs.count == 2)
    }

    @Test("Human tabs after agent group appear after group")
    @MainActor func humanAfterGroup() {
        let a1 = agentTab(agentID: "ag", sessionTag: "s1")
        let h1 = humanTab()
        let result = groupTabs([a1, h1])

        #expect(result.count == 2)
        guard case .group = result[0] else {
            Issue.record("Expected group at index 0")
            return
        }
        guard case .ungrouped = result[1] else {
            Issue.record("Expected ungrouped at index 1")
            return
        }
    }

    @Test("Interleaved human tabs and multiple groups preserve order")
    @MainActor func interleavedMixed() {
        let h1 = humanTab()
        let a1 = agentTab(agentID: "ag", sessionTag: "s1")
        let h2 = humanTab()
        let a2 = agentTab(agentID: "ag", sessionTag: "s2")
        let a3 = agentTab(agentID: "ag", sessionTag: "s1") // extends group s1

        // order: h1, a1(s1), h2, a2(s2), a3(s1→merged into s1 group)
        let result = groupTabs([h1, a1, h2, a2, a3])

        // Expected: ungrouped(h1), group(s1, 2 tabs), ungrouped(h2), group(s2, 1 tab)
        #expect(result.count == 4)

        if case .ungrouped(let t) = result[0] { #expect(t.id == h1.id) }
        else { Issue.record("index 0 should be ungrouped h1") }

        if case .group(let g) = result[1] {
            #expect(g.id == "s1")
            #expect(g.tabs.count == 2)
        } else { Issue.record("index 1 should be group s1") }

        if case .ungrouped(let t) = result[2] { #expect(t.id == h2.id) }
        else { Issue.record("index 2 should be ungrouped h2") }

        if case .group(let g) = result[3] {
            #expect(g.id == "s2")
            #expect(g.tabs.count == 1)
        } else { Issue.record("index 3 should be group s2") }
    }

    // MARK: - Restored tabs

    @Test("Restored tab with sessionTag is grouped")
    @MainActor func restoredTabWithTag() {
        let rt = restoredTab(agentID: "ag", sessionTag: "restored-sess")
        let result = groupTabs([rt])

        #expect(result.count == 1)
        guard case .group(let g) = result[0] else {
            Issue.record("Expected group for restored tab with tag")
            return
        }
        #expect(g.id == "restored-sess")
        #expect(g.tabs.count == 1)
    }

    @Test("Restored tab without sessionTag is ungrouped")
    @MainActor func restoredTabWithoutTag() {
        let rt = restoredTab(agentID: nil, sessionTag: nil)
        let result = groupTabs([rt])

        #expect(result.count == 1)
        guard case .ungrouped = result[0] else {
            Issue.record("Expected ungrouped for restored tab with no tag")
            return
        }
    }

    // MARK: - TabGroup display title

    @Test("Short session tag is displayed as-is")
    func shortTagDisplayTitle() {
        let group = TabGroup(id: "short", agentID: "ag", tabs: [])
        #expect(group.displayTitle == "short")
    }

    @Test("Long session tag is truncated at 20 chars with ellipsis")
    func longTagDisplayTitle() {
        let longTag = "this-is-a-very-long-session-tag-name"
        let group = TabGroup(id: longTag, agentID: "ag", tabs: [])
        #expect(group.displayTitle.count <= 21) // 20 + "…"
        #expect(group.displayTitle.hasSuffix("…"))
    }

    // MARK: - TabGroupOrTab identifiers

    @Test("Group item has stable id prefixed with 'group:'")
    @MainActor func groupItemID() {
        let group = TabGroup(id: "sess-xyz", agentID: "ag", tabs: [])
        let item = TabGroupOrTab.group(group)
        #expect(item.id == "group:sess-xyz")
    }

    @Test("Ungrouped item has stable id prefixed with 'tab:'")
    @MainActor func ungroupedItemID() {
        let tab = humanTab()
        let item = TabGroupOrTab.ungrouped(tab)
        #expect(item.id == "tab:\(tab.id.uuidString)")
    }
}
