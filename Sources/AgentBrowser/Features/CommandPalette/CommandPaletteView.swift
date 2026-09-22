// CommandPaletteView.swift
// SwiftUI root view for the command palette overlay.
// Handles the search field, sectioned results, and full keyboard navigation.

import SwiftUI

struct CommandPaletteView: View {

    // MARK: - Dependencies

    let tabManager: TabManager
    let historyStore: HistoryStore?
    let bookmarkStore: BookmarkStore?
    let onNavigate: @MainActor (URL) -> Void
    let onDismiss: () -> Void

    // MARK: - State

    @State private var searchText: String = ""
    @State private var sections: [PaletteSection] = []
    @State private var selectedIndex: Int = 0
    @State private var searchTask: Task<Void, Never>?

    private let searcher = CommandPaletteSearch()

    // MARK: - Computed

    /// Flattened list of all items across all sections (for index arithmetic).
    private var allItems: [PaletteItem] {
        sections.flatMap(\.items)
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            searchField
            if !allItems.isEmpty {
                Divider().opacity(0.5)
                resultsScrollView
            }
        }
        .frame(width: 560)
        .fixedSize(horizontal: false, vertical: true)
        .task { await runSearch() }          // initial load (empty query → recents)
        .onChange(of: searchText) { _, _ in
            scheduleDebouncedSearch()
        }
    }

    // MARK: - Search Field

    private var searchField: some View {
        HStack(spacing: Spacing.px8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .font(.system(size: 15, weight: .medium))

            TextField("Search tabs, history, bookmarks…", text: $searchText)
                .textFieldStyle(.plain)
                .font(Typography.body)
                .onKeyPress(.upArrow)   { moveSelection(by: -1); return .handled }
                .onKeyPress(.downArrow) { moveSelection(by:  1); return .handled }
                .onKeyPress(.return)    { activateSelected();     return .handled }
                .onKeyPress(.escape)    { onDismiss();            return .handled }

            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, Spacing.px12)
        .padding(.vertical, Spacing.px8)
    }

    // MARK: - Results

    private var resultsScrollView: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(sections) { section in
                        sectionView(section, proxy: proxy)
                    }
                }
                .padding(.horizontal, Spacing.px6)
                .padding(.vertical, Spacing.px4)
            }
            .frame(maxHeight: 360)
            .onChange(of: selectedIndex) { _, newIdx in
                if let item = itemAt(flatIndex: newIdx) {
                    withAnimation(.easeInOut(duration: Motion.micro)) {
                        proxy.scrollTo(item.id, anchor: .center)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func sectionView(_ section: PaletteSection, proxy: ScrollViewProxy) -> some View {
        // Section header
        Text(section.kind.rawValue.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, Spacing.px8)
            .padding(.top, Spacing.px6)
            .padding(.bottom, Spacing.px2)

        // Rows
        ForEach(Array(section.items.enumerated()), id: \.element.id) { _, item in
            PaletteResultRow(item: item, isSelected: isItemSelected(item))
                .id(item.id)
                .onTapGesture {
                    item.action()
                    onDismiss()
                }
        }
    }

    // MARK: - Keyboard Helpers

    private func moveSelection(by delta: Int) {
        guard !allItems.isEmpty else { return }
        let count = allItems.count
        selectedIndex = ((selectedIndex + delta) % count + count) % count
    }

    private func activateSelected() {
        guard let item = itemAt(flatIndex: selectedIndex) else { return }
        item.action()
        onDismiss()
    }

    private func isItemSelected(_ item: PaletteItem) -> Bool {
        itemAt(flatIndex: selectedIndex)?.id == item.id
    }

    private func itemAt(flatIndex idx: Int) -> PaletteItem? {
        guard !allItems.isEmpty, idx >= 0, idx < allItems.count else { return nil }
        return allItems[idx]
    }

    // MARK: - Search

    private func scheduleDebouncedSearch() {
        searchTask?.cancel()
        searchTask = Task {
            try? await Task.sleep(nanoseconds: 150_000_000) // 150 ms debounce
            guard !Task.isCancelled else { return }
            await runSearch()
        }
    }

    @MainActor
    private func runSearch() async {
        let result = await searcher.search(
            query: searchText,
            tabManager: tabManager,
            historyStore: historyStore,
            bookmarkStore: bookmarkStore,
            onNavigate: onNavigate
        )
        sections = result
        // Reset selection when results change; clamp to valid range.
        if selectedIndex >= allItems.count {
            selectedIndex = 0
        }
    }
}
