// ContentSearchResultRow.swift
// A single row in the content search results list.
// Displays the tab title, URL, and snippet with the matched text in bold.

import SwiftUI

struct ContentSearchResultRow: View {

    let result: ContentSearchResult

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.px2) {
            // Tab identity header
            HStack(spacing: Spacing.px4) {
                Image(systemName: "doc.text")
                    .font(.system(size: 10))
                    .foregroundStyle(Color.accentColor)

                Text(result.tabTitle)
                    .font(Typography.label)
                    .foregroundStyle(Color.primary)
                    .lineLimit(1)

                if let url = result.url {
                    Text("—")
                        .font(Typography.caption)
                        .foregroundStyle(Color.secondary)

                    Text(url.host ?? url.absoluteString)
                        .font(Typography.caption)
                        .foregroundStyle(Color.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }

            // Snippet with highlighted match
            snippetText
                .font(Typography.caption)
                .foregroundStyle(Color.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, Spacing.px12)
        .padding(.vertical, Spacing.px8)
        .contentShape(Rectangle())
    }

    // MARK: - Highlighted Snippet

    /// Builds an `AttributedString` with the matched portion rendered in bold.
    private var snippetText: Text {
        guard result.matchRange.lowerBound < result.snippet.endIndex,
              result.matchRange.upperBound <= result.snippet.endIndex else {
            return Text(result.snippet)
        }

        let before   = String(result.snippet[result.snippet.startIndex..<result.matchRange.lowerBound])
        let matched  = String(result.snippet[result.matchRange])
        let after    = String(result.snippet[result.matchRange.upperBound...])

        return Text(before) + Text(matched).bold().foregroundColor(.primary) + Text(after)
    }
}

// MARK: - Preview

#if DEBUG
#Preview("Result row") {
    let snippet = "The quick brown fox jumps over the lazy dog"
    let lo = snippet.range(of: "fox")!
    let result = ContentSearchResult(
        tabID: UUID(),
        tabTitle: "Example Page",
        url: URL(string: "https://example.com"),
        snippet: snippet,
        matchRange: lo
    )
    return ContentSearchResultRow(result: result)
        .frame(width: 440)
        .padding(8)
}
#endif
