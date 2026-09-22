// ContentSearchView.swift
// SwiftUI view for cross-tab content search (Cmd-Shift-F).
// Renders a search field at top, then results grouped by tab below.
// Clicking a result switches to that tab.

import SwiftUI

struct ContentSearchView: View {

    // MARK: - Dependencies

    let tabs: [BrowserTab]
    let onSelectTab: (UUID) -> Void
    let onDismiss: () -> Void

    // MARK: - State

    @State private var query: String = ""
    @State private var results: [ContentSearchResult] = []
    @State private var isSearching: Bool = false
    @State private var searchTask: Task<Void, Never>? = nil

    private let engine = ContentSearchEngine()

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            searchField
            Divider().opacity(Opacity.divider)
            resultsArea
        }
        .frame(width: 480)
        .background(.ultraThinMaterial)
        .clipShape(.rect(cornerRadius: Radius.large))
    }

    // MARK: - Search Field

    private var searchField: some View {
        HStack(spacing: Spacing.px8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Color.secondary)

            TextField("Search all tabs…", text: $query)
                .font(Typography.body)
                .textFieldStyle(.plain)
                .onSubmit { triggerSearch() }

            if isSearching {
                ProgressView()
                    .scaleEffect(0.6)
                    .frame(width: 16, height: 16)
            } else if !query.isEmpty {
                Button {
                    query = ""
                    results = []
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(Color.secondary)
                }
                .buttonStyle(.plain)
            }

            Button("Done") { onDismiss() }
                .font(Typography.label)
                .keyboardShortcut(.escape, modifiers: [])
        }
        .padding(.horizontal, Spacing.px16)
        .padding(.vertical, Spacing.px12)
        .onChange(of: query) { _, newValue in
            scheduleSearch(query: newValue)
        }
    }

    // MARK: - Results Area

    @ViewBuilder
    private var resultsArea: some View {
        if results.isEmpty && !query.isEmpty && !isSearching {
            emptyState
        } else if results.isEmpty && query.isEmpty {
            promptState
        } else {
            resultsList
        }
    }

    private var promptState: some View {
        HStack {
            Image(systemName: "text.magnifyingglass")
                .foregroundStyle(Color.secondary)
            Text("Type to search across all open tabs")
                .font(Typography.caption)
                .foregroundStyle(Color.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(Spacing.px24)
    }

    private var emptyState: some View {
        HStack {
            Image(systemName: "questionmark.circle")
                .foregroundStyle(Color.secondary)
            Text("No results for \"\(query)\"")
                .font(Typography.caption)
                .foregroundStyle(Color.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(Spacing.px24)
    }

    private var resultsList: some View {
        ScrollView(.vertical, showsIndicators: true) {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(groupedResults, id: \.tabID) { group in
                    tabGroup(group)
                }
            }
            .padding(.vertical, Spacing.px4)
        }
        .frame(maxHeight: 360)
    }

    // MARK: - Tab Grouping

    private struct TabGroup {
        let tabID: UUID
        let tabTitle: String
        let results: [ContentSearchResult]
    }

    private var groupedResults: [TabGroup] {
        var groups: [UUID: TabGroup] = [:]
        var order: [UUID] = []

        for result in results {
            if groups[result.tabID] == nil {
                order.append(result.tabID)
                groups[result.tabID] = TabGroup(
                    tabID: result.tabID,
                    tabTitle: result.tabTitle,
                    results: [result]
                )
            } else {
                groups[result.tabID] = TabGroup(
                    tabID: result.tabID,
                    tabTitle: groups[result.tabID]!.tabTitle,
                    results: groups[result.tabID]!.results + [result]
                )
            }
        }

        return order.compactMap { groups[$0] }
    }

    @ViewBuilder
    private func tabGroup(_ group: TabGroup) -> some View {
        // Tab header
        HStack(spacing: Spacing.px6) {
            Image(systemName: "square.stack")
                .font(.system(size: 10))
                .foregroundStyle(Color.accentColor.opacity(0.8))
            Text(group.tabTitle)
                .font(Typography.label)
                .foregroundStyle(Color.primary.opacity(Opacity.secondary))
            Spacer()
            Text("\(group.results.count) match\(group.results.count == 1 ? "" : "es")")
                .font(Typography.caption)
                .foregroundStyle(Color.secondary)
        }
        .padding(.horizontal, Spacing.px12)
        .padding(.top, Spacing.px8)
        .padding(.bottom, Spacing.px2)

        // Result rows
        ForEach(group.results) { result in
            Button {
                onSelectTab(result.tabID)
                onDismiss()
            } label: {
                ContentSearchResultRow(result: result)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(ContentSearchRowButtonStyle())
        }

        Divider().opacity(Opacity.divider).padding(.horizontal, Spacing.px12)
    }

    // MARK: - Debounced Search

    private func scheduleSearch(query: String) {
        searchTask?.cancel()
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else {
            results = []
            isSearching = false
            return
        }

        searchTask = Task { @MainActor in
            // 300ms debounce — JS evaluation is heavier than a simple filter
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            await runSearch(query: query)
        }
    }

    private func triggerSearch() {
        searchTask?.cancel()
        Task { @MainActor in
            await runSearch(query: query)
        }
    }

    private func runSearch(query: String) async {
        isSearching = true
        results = await engine.searchAllTabs(query: query, tabs: tabs)
        isSearching = false
    }
}

// MARK: - Row Button Style

private struct ContentSearchRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(configuration.isPressed
                ? Color.accentColor.opacity(0.12)
                : Color.clear)
    }
}
