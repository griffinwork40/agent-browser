// ContentSearchEngine.swift
// Searches text content across all open browser tabs using JavaScript evaluation.
// Returns snippets with context around each match, capped for performance.

import Foundation
import WebKit

// MARK: - Result Model

/// A single search match found in a tab's text content.
struct ContentSearchResult: Identifiable {
    let id: UUID = UUID()
    let tabID: UUID
    let tabTitle: String
    let url: URL?
    let snippet: String
    /// The range of the match within the snippet string (not the page text).
    let matchRange: Range<String.Index>
}

// MARK: - Engine

/// Searches the text content of all open tabs for a given query string.
///
/// For each tab, evaluates `document.body.innerText` via JavaScript, then
/// locates all case-insensitive occurrences of the query. Each match is
/// returned as a `ContentSearchResult` with 50 chars of context on each side.
///
/// Caps: 5 results per tab, 50 total across all tabs.
@MainActor final class ContentSearchEngine {

    // MARK: - Constants

    private enum Limits {
        static let maxMatchesPerTab = 5
        static let maxTotalResults  = 50
        static let contextRadius    = 50   // chars before/after the match
    }

    // MARK: - Public API

    /// Search all tabs for `query`. Returns an empty array if `query` is empty.
    /// Each tab is queried concurrently via `async let`.
    func searchAllTabs(query: String, tabs: [BrowserTab]) async -> [ContentSearchResult] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return [] }

        var results: [ContentSearchResult] = []

        // Iterate over tabs sequentially to avoid hammering WKWebView concurrently.
        // WKWebView's evaluateJavaScript is safe to call on MainActor but not
        // thread-safe to call from multiple concurrent tasks simultaneously.
        for tab in tabs {
            guard results.count < Limits.maxTotalResults else { break }
            let remaining = Limits.maxTotalResults - results.count
            let tabResults = await searchTab(tab, query: trimmed, limit: min(Limits.maxMatchesPerTab, remaining))
            results.append(contentsOf: tabResults)
        }

        return results
    }

    // MARK: - Per-Tab Search

    private func searchTab(_ tab: BrowserTab, query: String, limit: Int) async -> [ContentSearchResult] {
        let pageText: String
        do {
            pageText = try await extractText(from: tab.webView)
        } catch {
            return []   // tab may be loading, blank, or restricted — skip silently
        }

        guard !pageText.isEmpty else { return [] }

        return findMatches(in: pageText, query: query, limit: limit, tab: tab)
    }

    /// Evaluates `document.body.innerText` in the web view.
    private func extractText(from webView: WKWebView) async throws -> String {
        return try await withCheckedThrowingContinuation { continuation in
            webView.evaluateJavaScript("document.body ? document.body.innerText : ''") { result, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: (result as? String) ?? "")
                }
            }
        }
    }

    // MARK: - Match Extraction

    private func findMatches(
        in text: String,
        query: String,
        limit: Int,
        tab: BrowserTab
    ) -> [ContentSearchResult] {
        var results: [ContentSearchResult] = []
        var searchStart = text.startIndex

        while results.count < limit,
              let matchRange = text.range(of: query, options: .caseInsensitive, range: searchStart..<text.endIndex) {

            let snippet = buildSnippet(text: text, matchRange: matchRange)
            results.append(ContentSearchResult(
                tabID: tab.id,
                tabTitle: tab.title,
                url: tab.url,
                snippet: snippet.text,
                matchRange: snippet.localRange
            ))

            // Advance past current match to find the next one
            searchStart = matchRange.upperBound
            if searchStart >= text.endIndex { break }
        }

        return results
    }

    // MARK: - Snippet Builder

    private struct SnippetResult {
        let text: String
        let localRange: Range<String.Index>
    }

    /// Extracts a snippet of ±50 chars around `matchRange` in `text`.
    /// Returns a `SnippetResult` with the new local range within the snippet.
    private func buildSnippet(text: String, matchRange: Range<String.Index>) -> SnippetResult {
        let radius = Limits.contextRadius

        // Compute snippet start (back off `radius` chars before match)
        let snippetStart: String.Index = {
            var idx = matchRange.lowerBound
            var steps = 0
            while idx > text.startIndex, steps < radius {
                idx = text.index(before: idx)
                steps += 1
            }
            return idx
        }()

        // Compute snippet end (advance `radius` chars after match)
        let snippetEnd: String.Index = {
            var idx = matchRange.upperBound
            var steps = 0
            while idx < text.endIndex, steps < radius {
                idx = text.index(after: idx)
                steps += 1
            }
            return idx
        }()

        let snippet = String(text[snippetStart..<snippetEnd])

        // Re-locate the match within the snippet string
        let offsetToStart = text.distance(from: snippetStart, to: matchRange.lowerBound)
        let offsetToEnd   = text.distance(from: snippetStart, to: matchRange.upperBound)

        let localStart = snippet.index(snippet.startIndex, offsetBy: offsetToStart, limitedBy: snippet.endIndex) ?? snippet.startIndex
        let localEnd   = snippet.index(snippet.startIndex, offsetBy: offsetToEnd,   limitedBy: snippet.endIndex) ?? snippet.endIndex

        return SnippetResult(text: snippet, localRange: localStart..<localEnd)
    }
}
