// TabSidebarView.swift
// The full vertical sidebar: header → divider → scrollable tab list.
// Pinned tabs section is wired but renders nothing until pinned tabs exist.

import SwiftUI

struct TabSidebarView: View {

    let tabs: [BrowserTab]
    let selectedTabID: UUID?
    let onSelect: (BrowserTab) -> Void
    let onClose: (BrowserTab) -> Void
    let onNewTab: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            SidebarHeaderView(tabCount: tabs.count, onNewTab: onNewTab)

            Divider()
                .opacity(Opacity.divider)

            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(spacing: Spacing.px2) {
                    // Pinned section — no-ops until pinnedTabs is populated
                    PinnedTabsSection(
                        pinnedTabs: [],
                        selectedTabID: selectedTabID,
                        onSelect: onSelect
                    )

                    // All open tabs
                    ForEach(tabs) { tab in
                        TabRowView(
                            tab: tab,
                            isSelected: tab.id == selectedTabID,
                            onSelect: { onSelect(tab) },
                            onClose: { onClose(tab) }
                        )
                    }
                }
                .padding(.horizontal, Spacing.px6)
                .padding(.vertical, Spacing.px6)
            }
        }
        .frame(width: ControlSize.sidebarWidth)
        .background(.bar)          // sidebar material — adapts light/dark automatically
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Tab Sidebar")
    }
}
