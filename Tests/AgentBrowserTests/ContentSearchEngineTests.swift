// ContentSearchEngineTests.swift
// Tests for ContentSearchEngine: search logic, snippet extraction, result capping.
// Uses mock tab content injected via WKWebView.loadHTMLString so no network is needed.

import Testing
import Foundation
@testable import AgentBrowser

// MARK: - Snippet Helpers (white-box, no WKWebView needed)

/// Access to ContentSearchEngine internals via a test-only subclass/extension isn't
/// available (the engine is `final`), so snippet logic is validated end-to-end through
/// the public `searchAllTabs` API using a mock injector below.

// MARK: - Mock Content Injection

/// Loads HTML into a BrowserTab's webView and waits for the DOM to settle.
@MainActor
private func loadHTML(_ html: String, into tab: BrowserTab) async {
    tab.webView.loadHTMLString(html, baseURL: nil)
    // Poll until WKWebView finishes loading (max ~2 s for local HTML)
    var waited = 0
    while tab.webView.isLoading, waited < 20 {
        try? await Task.sleep(for: .milliseconds(100))
        waited += 1
    }
    // Small extra settle for DOM events
    try? await Task.sleep(for: .milliseconds(50))
}

// MARK: - Suite

@Suite("ContentSearchEngine")
struct ContentSearchEngineTests {

    // MARK: - Basic search

    @Test("Returns empty results for empty query")
    @MainActor func emptyQueryReturnsNothing() async {
        let engine = ContentSearchEngine()
        let tab = BrowserTab()
        await loadHTML("<body><p>Hello world</p></body>", into: tab)

        let results = await engine.searchAllTabs(query: "", tabs: [tab])
        #expect(results.isEmpty)
    }

    @Test("Returns empty results for whitespace-only query")
    @MainActor func whitespaceQueryReturnsNothing() async {
        let engine = ContentSearchEngine()
        let tab = BrowserTab()
        await loadHTML("<body><p>Hello world</p></body>", into: tab)

        let results = await engine.searchAllTabs(query: "   ", tabs: [tab])
        #expect(results.isEmpty)
    }

    @Test("Finds a match in a single tab")
    @MainActor func findsMatchInSingleTab() async {
        let engine = ContentSearchEngine()
        let tab = BrowserTab()
        await loadHTML("<body><p>The quick brown fox jumps over the lazy dog</p></body>", into: tab)

        let results = await engine.searchAllTabs(query: "fox", tabs: [tab])
        #expect(!results.isEmpty)
        #expect(results[0].tabID == tab.id)
    }

    @Test("Search is case-insensitive")
    @MainActor func caseInsensitiveSearch() async {
        let engine = ContentSearchEngine()
        let tab = BrowserTab()
        await loadHTML("<body><p>Hello World</p></body>", into: tab)

        let lower  = await engine.searchAllTabs(query: "hello", tabs: [tab])
        let upper  = await engine.searchAllTabs(query: "HELLO", tabs: [tab])
        let mixed  = await engine.searchAllTabs(query: "hElLo", tabs: [tab])

        #expect(!lower.isEmpty)
        #expect(!upper.isEmpty)
        #expect(!mixed.isEmpty)
    }

    // MARK: - Multi-tab

    @Test("Finds matches across multiple tabs")
    @MainActor func findsAcrossMultipleTabs() async {
        let engine = ContentSearchEngine()

        let tab1 = BrowserTab()
        let tab2 = BrowserTab()
        let tab3 = BrowserTab()

        await loadHTML("<body><p>Swift programming language</p></body>", into: tab1)
        await loadHTML("<body><p>Python programming language</p></body>", into: tab2)
        await loadHTML("<body><p>No match here</p></body>", into: tab3)

        let results = await engine.searchAllTabs(query: "programming", tabs: [tab1, tab2, tab3])

        let tabIDs = Set(results.map(\.tabID))
        #expect(tabIDs.contains(tab1.id))
        #expect(tabIDs.contains(tab2.id))
        #expect(!tabIDs.contains(tab3.id))
    }

    // MARK: - Per-tab cap

    @Test("Caps at 5 results per tab")
    @MainActor func capsAtFivePerTab() async {
        let engine = ContentSearchEngine()
        let tab = BrowserTab()

        // Build a page with 10 occurrences of "target"
        let repeated = Array(repeating: "<p>target word here</p>", count: 10).joined()
        await loadHTML("<body>\(repeated)</body>", into: tab)

        let results = await engine.searchAllTabs(query: "target", tabs: [tab])
        let countForTab = results.filter { $0.tabID == tab.id }.count
        #expect(countForTab <= 5)
    }

    // MARK: - Total cap

    @Test("Caps total results at 50")
    @MainActor func capsTotalResultsAt50() async {
        let engine = ContentSearchEngine()

        // 15 tabs, each with 10 occurrences of "match" → would be 150 without cap
        let tabs: [BrowserTab] = (0..<15).map { _ in BrowserTab() }
        let repeated = Array(repeating: "<p>match found here</p>", count: 10).joined()
        for tab in tabs {
            await loadHTML("<body>\(repeated)</body>", into: tab)
        }

        let results = await engine.searchAllTabs(query: "match", tabs: tabs)
        #expect(results.count <= 50)
    }

    // MARK: - Snippet

    @Test("Snippet contains the matched text")
    @MainActor func snippetContainsMatch() async {
        let engine = ContentSearchEngine()
        let tab = BrowserTab()
        await loadHTML("<body><p>The quick brown fox jumps over the lazy dog</p></body>", into: tab)

        let results = await engine.searchAllTabs(query: "brown fox", tabs: [tab])
        #expect(!results.isEmpty)

        let snippet = results[0].snippet
        let range   = results[0].matchRange
        let matched = String(snippet[range])
        #expect(matched.lowercased() == "brown fox")
    }

    @Test("Match range is valid within snippet")
    @MainActor func matchRangeIsValid() async {
        let engine = ContentSearchEngine()
        let tab = BrowserTab()
        await loadHTML("<body><p>Agents are amazing tools</p></body>", into: tab)

        let results = await engine.searchAllTabs(query: "amazing", tabs: [tab])
        #expect(!results.isEmpty)

        for result in results {
            let range = result.matchRange
            #expect(range.lowerBound >= result.snippet.startIndex)
            #expect(range.upperBound <= result.snippet.endIndex)
        }
    }

    // MARK: - No results

    @Test("No match returns empty array")
    @MainActor func noMatchReturnsEmpty() async {
        let engine = ContentSearchEngine()
        let tab = BrowserTab()
        await loadHTML("<body><p>Hello world</p></body>", into: tab)

        let results = await engine.searchAllTabs(query: "zzz_xyzzy_not_here", tabs: [tab])
        #expect(results.isEmpty)
    }

    @Test("Empty tab list returns empty array")
    @MainActor func emptyTabListReturnsEmpty() async {
        let engine = ContentSearchEngine()
        let results = await engine.searchAllTabs(query: "anything", tabs: [])
        #expect(results.isEmpty)
    }

    // MARK: - Result fields

    @Test("Result carries correct tab metadata")
    @MainActor func resultCarriesTabMetadata() async {
        let engine = ContentSearchEngine()
        let tab = BrowserTab()
        await loadHTML(
            "<html><head><title>My Tab Title</title></head><body><p>search target word</p></body></html>",
            into: tab
        )

        let results = await engine.searchAllTabs(query: "target", tabs: [tab])
        #expect(!results.isEmpty)
        #expect(results[0].tabID == tab.id)
    }
}
