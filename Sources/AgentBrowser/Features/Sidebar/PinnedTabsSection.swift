// PinnedTabsSection.swift
// Placeholder section for pinned / favorite tabs.
// Renders nothing when pinnedTabs is empty (current V1 state).
// Wired up to the full pin model in a later milestone.

import SwiftUI

struct PinnedTabsSection: View {

    let pinnedTabs: [BrowserTab]   // empty for V1
    let selectedTabID: UUID?
    let onSelect: (BrowserTab) -> Void

    var body: some View {
        if !pinnedTabs.isEmpty {
            Section {
                ForEach(pinnedTabs) { tab in
                    TabRowView(
                        tab: tab,
                        isSelected: tab.id == selectedTabID,
                        profileColorName: nil,
                        onSelect: { onSelect(tab) },
                        onClose: {}   // pinned tabs cannot be closed from sidebar
                    )
                }
            } header: {
                Text("Pinned")
                    .font(Typography.label)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, Spacing.px12)
                    .padding(.vertical, Spacing.px4)
            }
        }
    }
}
