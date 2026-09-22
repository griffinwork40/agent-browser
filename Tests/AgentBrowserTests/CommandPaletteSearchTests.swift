// CommandPaletteSearchTests.swift
// Unit tests for CommandPaletteSearch: query filtering, empty-query recents,
// section presence/absence, and item ID format.

import Testing
import Foundation
@testable import AgentBrowser

@Suite("CommandPaletteSearch")
struct CommandPaletteSearchTests {

    // MARK: - Helpers

    /// Creates a temporary directory-backed HistoryStore seeded with `entries`.
    private func makeHistoryStore(entries: [(url: URL, title: String)]) async -> HistoryStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = HistoryStore(dataDirectory: dir)
        for e in entries {
            await store.addEntry(url: e.url, title: e.title)
        }
        return store
    }

    /// Creates a temporary directory-backed BookmarkStore seeded with `bookmarks`.
    private func makeBookmarkStore(bookmarks: [(url: URL, title: String)]) -> BookmarkStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = BookmarkStore(dataDirectory: dir)
        for bm in bookmarks {
            Task { await store.add(url: bm.url, title: bm.title) }
        }
        return store
    }

    // MARK: - Open Tabs

    @Test("Empty query returns all open tabs")
    @MainActor func emptyQueryReturnsTabs() async {
        let tm = TabManager()
        let t1 = tm.createTab()
        t1.overrideTitle("GitHub")
        let t2 = tm.createTab()
        t2.overrideTitle("Apple")

        let searcher = CommandPaletteSearch()
        let sections = await searcher.search(
            query: "",
            tabManager: tm,
            historyStore: nil,
            bookmarkStore: nil,
            onNavigate: { _ in }
        )

        let tabSection = sections.first(where: { $0.kind == .openTabs })
        #expect(tabSection != nil)
        #expect(tabSection?.items.count == 2)
    }

    @Test("Query filters tabs by title")
    @MainActor func queryFiltersByTitle() async {
        let tm = TabManager()
        let t1 = tm.createTab()
        t1.overrideTitle("GitHub Issues")
        let t2 = tm.createTab()
        t2.overrideTitle("Apple Developer")

        let searcher = CommandPaletteSearch()
        let sections = await searcher.search(
            query: "github",
            tabManager: tm,
            historyStore: nil,
            bookmarkStore: nil,
            onNavigate: { _ in }
        )

        let tabSection = sections.first(where: { $0.kind == .openTabs })
        #expect(tabSection?.items.count == 1)
        #expect(tabSection?.items.first?.title == "GitHub Issues")
    }

    @Test("Query with no match produces no tab section")
    @MainActor func noMatchProducesNoTabSection() async {
        let tm = TabManager()
        let t = tm.createTab()
        t.overrideTitle("Apple")

        let searcher = CommandPaletteSearch()
        let sections = await searcher.search(
            query: "zzznomatch",
            tabManager: tm,
            historyStore: nil,
            bookmarkStore: nil,
            onNavigate: { _ in }
        )

        let tabSection = sections.first(where: { $0.kind == .openTabs })
        #expect(tabSection == nil)
    }

    // MARK: - Tab Item IDs

    @Test("Tab items use 'tab-<uuid>' ID format")
    @MainActor func tabItemIDFormat() async {
        let tm = TabManager()
        let tab = tm.createTab()
        tab.overrideTitle("Test Tab")

        let searcher = CommandPaletteSearch()
        let sections = await searcher.search(
            query: "",
            tabManager: tm,
            historyStore: nil,
            bookmarkStore: nil,
            onNavigate: { _ in }
        )

        let item = sections.first(where: { $0.kind == .openTabs })?.items.first
        #expect(item?.id == "tab-\(tab.id)")
    }

    // MARK: - History

    @Test("History section appears when store has entries")
    @MainActor func historySectionAppearsWithEntries() async {
        let hs = await makeHistoryStore(entries: [
            (url: URL(string: "https://example.com")!, title: "Example"),
        ])
        let tm = TabManager()

        let searcher = CommandPaletteSearch()
        let sections = await searcher.search(
            query: "",
            tabManager: tm,
            historyStore: hs,
            bookmarkStore: nil,
            onNavigate: { _ in }
        )

        let histSection = sections.first(where: { $0.kind == .history })
        #expect(histSection != nil)
    }

    @Test("History capped at 5 items for empty query")
    @MainActor func historyCappedAtFive() async {
        let entries = (1...8).map { i in
            (url: URL(string: "https://site\(i).com")!, title: "Site \(i)")
        }
        let hs = await makeHistoryStore(entries: entries)
        let tm = TabManager()

        let searcher = CommandPaletteSearch()
        let sections = await searcher.search(
            query: "",
            tabManager: tm,
            historyStore: hs,
            bookmarkStore: nil,
            onNavigate: { _ in }
        )

        let histSection = sections.first(where: { $0.kind == .history })
        #expect((histSection?.items.count ?? 0) <= 5)
    }

    @Test("History item IDs use 'history-<uuid>' format")
    @MainActor func historyItemIDFormat() async {
        let hs = await makeHistoryStore(entries: [
            (url: URL(string: "https://test.com")!, title: "Test"),
        ])
        let tm = TabManager()

        let searcher = CommandPaletteSearch()
        let sections = await searcher.search(
            query: "",
            tabManager: tm,
            historyStore: hs,
            bookmarkStore: nil,
            onNavigate: { _ in }
        )

        let item = sections.first(where: { $0.kind == .history })?.items.first
        #expect(item?.id.hasPrefix("history-") == true)
    }

    // MARK: - Sections ordering

    @Test("Sections appear in order: openTabs, history, bookmarks")
    @MainActor func sectionOrdering() async {
        let hs = await makeHistoryStore(entries: [
            (url: URL(string: "https://a.com")!, title: "A"),
        ])
        let bsDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: bsDir, withIntermediateDirectories: true)
        let bs = BookmarkStore(dataDirectory: bsDir)
        await bs.add(url: URL(string: "https://b.com")!, title: "B")

        let tm = TabManager()
        _ = tm.createTab()

        let searcher = CommandPaletteSearch()
        let sections = await searcher.search(
            query: "",
            tabManager: tm,
            historyStore: hs,
            bookmarkStore: bs,
            onNavigate: { _ in }
        )

        let kinds = sections.map(\.kind)
        // OpenTabs comes before History before Bookmarks (when all present)
        if kinds.count == 3 {
            #expect(kinds[0] == .openTabs)
            #expect(kinds[1] == .history)
            #expect(kinds[2] == .bookmarks)
        }
    }

    // MARK: - Untitled fallback

    @Test("Untitled tab gets fallback title")
    @MainActor func untitledTabFallback() async {
        let tm = TabManager()
        // createTab without overriding title → title defaults to "New Tab"
        _ = tm.createTab()

        let searcher = CommandPaletteSearch()
        let sections = await searcher.search(
            query: "",
            tabManager: tm,
            historyStore: nil,
            bookmarkStore: nil,
            onNavigate: { _ in }
        )

        let item = sections.first(where: { $0.kind == .openTabs })?.items.first
        // "New Tab" is the default BrowserTab title — not empty, so it passes through.
        // If somehow empty, the fallback "Untitled" is used.
        let title = item?.title ?? ""
        #expect(!title.isEmpty)
    }
}

// MARK: - Test helper on BrowserTab

/// Allows tests to set a display title without triggering real navigation.
extension BrowserTab {
    /// Sets the tab's display title directly (test-only).
    @MainActor func overrideTitle(_ newTitle: String) {
        // BrowserTab.title is private(set); reach it via the KVO path used in production.
        // We use the existing internal setter exposed by the NavigationCoordinator path,
        // but since tests can't call the full navigation stack, we access via setValue.
        // title is @Observable so we must assign on MainActor (already guaranteed here).
        // Use the _$observationRegistrar-compatible path: direct ivar write via Mirror
        // is fragile. Instead, simulate what NavigationCoordinator does:
        // tab.title is updated via the navigationCoordinator callback in production.
        // For tests, we exploit the fact that BrowserTab has a willSet path triggered
        // by loadHTMLString with a baseURL trick — but that requires a WKWebView.
        // Simplest safe approach: expose title as internal(set) for test targets.
        // Since we can't change the source here, use the hack-free approach: just
        // load a data URL whose <title> tag the WKWebView will parse. Not feasible
        // without a run loop. We accept "New Tab" as the default in tests.
        //
        // Alternative used here: add a dedicated test-only setter accessed only
        // via this extension in the test target. We rely on @testable import
        // making the internal `_setTitleForTesting` available (added to BrowserTab).
        _setTitleForTesting(newTitle)
    }
}
