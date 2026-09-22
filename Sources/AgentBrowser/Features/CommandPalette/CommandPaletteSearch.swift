// CommandPaletteSearch.swift
// Data types and async search logic for the command palette.

import Foundation

// MARK: - Section Kind

enum PaletteSectionKind: String, Hashable {
    case openTabs  = "Open Tabs"
    case history   = "History"
    case bookmarks = "Bookmarks"
}

// MARK: - Item

/// A single result row in the palette.  Action is excluded from equality because
/// closures are not `Equatable`; identity is provided by `id`.
struct PaletteItem: Identifiable {
    let id: String          // "tab-<uuid>", "history-<uuid>", "bookmark-<uuid>"
    let icon: String        // SF Symbol name
    let title: String
    let subtitle: String
    let action: @MainActor () -> Void
}

// MARK: - Section

struct PaletteSection: Identifiable {
    let kind: PaletteSectionKind
    var id: String { kind.rawValue }
    var items: [PaletteItem]
}

// MARK: - Search

/// Produces a list of `PaletteSection` values given the current query string.
/// All three sources (open tabs, history, bookmarks) are queried each time;
/// empty sections are omitted from the result.
@MainActor
final class CommandPaletteSearch {

    func search(
        query: String,
        tabManager: TabManager,
        historyStore: HistoryStore?,
        bookmarkStore: BookmarkStore?,
        onNavigate: @escaping @MainActor (URL) -> Void
    ) async -> [PaletteSection] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var sections: [PaletteSection] = []

        // ── Open tabs ────────────────────────────────────────────────────────
        let matchingTabs: [BrowserTab]
        if trimmed.isEmpty {
            matchingTabs = Array(tabManager.tabs)
        } else {
            matchingTabs = tabManager.tabs.filter {
                $0.title.lowercased().contains(trimmed) ||
                ($0.url?.absoluteString.lowercased().contains(trimmed) ?? false)
            }
        }
        if !matchingTabs.isEmpty {
            sections.append(PaletteSection(
                kind: .openTabs,
                items: matchingTabs.map { tab in
                    PaletteItem(
                        id: "tab-\(tab.id)",
                        icon: "globe",
                        title: tab.title.isEmpty ? "Untitled" : tab.title,
                        subtitle: tab.url?.absoluteString ?? "",
                        action: { [weak tabManager] in tabManager?.select(tab: tab) }
                    )
                }
            ))
        }

        // ── History (top 5) ──────────────────────────────────────────────────
        if let store = historyStore {
            let entries: [HistoryEntry]
            if trimmed.isEmpty {
                entries = await store.recentEntries(limit: 5)
            } else {
                let all = await store.search(query: query)
                entries = Array(all.prefix(5))
            }
            if !entries.isEmpty {
                sections.append(PaletteSection(
                    kind: .history,
                    items: entries.map { entry in
                        PaletteItem(
                            id: "history-\(entry.id)",
                            icon: "clock",
                            title: entry.title.isEmpty ? "Untitled" : entry.title,
                            subtitle: entry.url.absoluteString,
                            action: { onNavigate(entry.url) }
                        )
                    }
                ))
            }
        }

        // ── Bookmarks (top 5) ────────────────────────────────────────────────
        if let store = bookmarkStore {
            let all = await store.all()
            let matching: [Bookmark]
            if trimmed.isEmpty {
                matching = Array(all.prefix(5))
            } else {
                matching = all.filter {
                    $0.title.lowercased().contains(trimmed) ||
                    $0.url.absoluteString.lowercased().contains(trimmed)
                }.prefix(5).map { $0 }
            }
            if !matching.isEmpty {
                sections.append(PaletteSection(
                    kind: .bookmarks,
                    items: matching.map { bm in
                        PaletteItem(
                            id: "bookmark-\(bm.id)",
                            icon: "star.fill",
                            title: bm.title.isEmpty ? "Untitled" : bm.title,
                            subtitle: bm.url.absoluteString,
                            action: { onNavigate(bm.url) }
                        )
                    }
                ))
            }
        }

        return sections
    }
}
