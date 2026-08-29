import Testing
import Foundation
@testable import AgentBrowser

/// Tests for TabManager: tab identity, lifecycle, selection, lookup.
/// These run without a display server because TabManager + BrowserTab
/// can be instantiated on @MainActor without rendering.
@Suite("TabManager")
struct TabManagerTests {

    // MARK: - Tab Identity

    @Test("Tab IDs are UUIDs, unique, and stable")
    @MainActor func tabIdentity() {
        let tm = TabManager()
        let t1 = tm.createTab()
        let t2 = tm.createTab()

        // UUIDs are non-empty and parseable
        #expect(UUID(uuidString: t1.id.uuidString) != nil)
        #expect(UUID(uuidString: t2.id.uuidString) != nil)

        // Different tabs have different IDs
        #expect(t1.id != t2.id)

        // ID is stable across accesses
        let idFirst = t1.id
        let idSecond = t1.id
        #expect(idFirst == idSecond)
    }

    @Test("Closed tab ID no longer resolves")
    @MainActor func closedTabInvalidation() {
        let tm = TabManager()
        let tab = tm.createTab()
        let id = tab.id

        // Resolves while alive
        #expect(tm.tab(for: id) != nil)

        // Close it
        let closed = tm.closeTab(tab)
        #expect(closed == true)

        // No longer resolves
        #expect(tm.tab(for: id) == nil)
    }

    @Test("Tab IDs never collide after close/create cycles")
    @MainActor func noIDReuse() {
        let tm = TabManager()
        var seenIDs = Set<UUID>()

        for _ in 0..<20 {
            let tab = tm.createTab()
            #expect(!seenIDs.contains(tab.id), "UUID collision detected")
            seenIDs.insert(tab.id)
            tm.closeTab(tab)
        }

        #expect(seenIDs.count == 20)
    }

    // MARK: - List Tabs

    @Test("List tabs returns all open tabs in order")
    @MainActor func listTabs() {
        let tm = TabManager()
        #expect(tm.tabs.isEmpty)

        let t1 = tm.createTab()
        let t2 = tm.createTab()
        let t3 = tm.createTab()

        #expect(tm.tabs.count == 3)
        #expect(tm.tabs[0].id == t1.id)
        #expect(tm.tabs[1].id == t2.id)
        #expect(tm.tabs[2].id == t3.id)
    }

    @Test("List reflects removal immediately")
    @MainActor func listAfterClose() {
        let tm = TabManager()
        let t1 = tm.createTab()
        let t2 = tm.createTab()
        let t3 = tm.createTab()

        tm.closeTab(t2)

        #expect(tm.tabs.count == 2)
        #expect(tm.tabs[0].id == t1.id)
        #expect(tm.tabs[1].id == t3.id)
    }

    // MARK: - Invalid Tab ID

    @Test("Lookup with random UUID returns nil")
    @MainActor func invalidTabLookup() {
        let tm = TabManager()
        _ = tm.createTab()

        let bogus = UUID()
        #expect(tm.tab(for: bogus) == nil)
    }

    // MARK: - Selection

    @Test("Active tab tracks selection")
    @MainActor func activeTab() {
        let tm = TabManager()
        let t1 = tm.createTab()
        let t2 = tm.createTab()

        tm.select(tab: t1)
        #expect(tm.activeTab?.id == t1.id)

        tm.select(tab: t2)
        #expect(tm.activeTab?.id == t2.id)
    }

    @Test("Closing selected tab adjusts index")
    @MainActor func closeSelectedTab() {
        let tm = TabManager()
        let t1 = tm.createTab()
        let t2 = tm.createTab()
        let t3 = tm.createTab()

        tm.select(tab: t2) // select middle tab
        tm.closeTab(t2)

        // Should select the tab that was after t2 (now at the same index)
        // or the last tab if t2 was last
        #expect(tm.activeTab != nil)
        #expect(tm.activeTab?.id != t2.id) // definitely not the closed one
    }

    @Test("Closing all tabs leaves no active tab")
    @MainActor func closeAllTabs() {
        let tm = TabManager()
        let t1 = tm.createTab()
        tm.select(tab: t1)
        tm.closeTab(t1)

        #expect(tm.tabs.isEmpty)
        #expect(tm.activeTab == nil)
    }

    @Test("Selection callback fires on selection change")
    @MainActor func selectionCallback() {
        let tm = TabManager()
        let t1 = tm.createTab()
        let t2 = tm.createTab()

        var callbackCount = 0
        tm.onSelectionChanged = { callbackCount += 1 }

        tm.select(tab: t1)
        tm.select(tab: t2)
        tm.selectTab(at: 0)

        #expect(callbackCount == 3)
    }

    // MARK: - Tab Cycling

    @Test("Next/previous tab wraps around")
    @MainActor func tabCycling() {
        let tm = TabManager()
        let t1 = tm.createTab()
        let t2 = tm.createTab()
        let t3 = tm.createTab()

        tm.select(tab: t1) // index 0
        tm.selectNextTab()
        #expect(tm.activeTab?.id == t2.id) // index 1

        tm.selectNextTab()
        #expect(tm.activeTab?.id == t3.id) // index 2

        tm.selectNextTab()
        #expect(tm.activeTab?.id == t1.id) // wrapped to 0

        tm.selectPreviousTab()
        #expect(tm.activeTab?.id == t3.id) // wrapped to 2
    }

    // MARK: - Close returns false for unknown tab

    @Test("Closing a tab not in the manager returns false")
    @MainActor func closeUnknownTab() {
        let tm = TabManager()
        _ = tm.createTab()

        let orphan = BrowserTab()
        #expect(tm.closeTab(orphan) == false)
    }
}
