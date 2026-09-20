// TabSidebarView.swift
// The full vertical sidebar: header → divider → scrollable tab list → profile picker.
// Agent tabs are auto-grouped by sessionTag with collapsible cluster headers.
// Pinned tabs section is wired but renders nothing until pinned tabs exist.

import SwiftUI

struct TabSidebarView: View {

    let tabs: [BrowserTab]
    let selectedTabID: UUID?
    /// Maps profileID → colorName so each row can show the right ring color.
    /// Built by BrowserWindowController from ProfileManager.profiles.
    let profileColors: [UUID: String]
    let onSelect: (BrowserTab) -> Void
    let onClose: (BrowserTab) -> Void
    let onNewTab: () -> Void

    let profiles: [ProfileRecord]
    let activeProfileID: UUID
    let onSwitchProfile: (UUID) -> Void
    let onCreateProfile: () -> Void
    var onRenameProfile: ((UUID, String) -> Bool)?

    /// Tracks which groups are currently collapsed; keyed by sessionTag (group.id).
    @State private var collapsedGroups: Set<String> = []

    var body: some View {
        // GlassSurface with radius:0 because the sidebar is flush to the window
        // edge. It also handles Reduce Transparency by falling back to an opaque
        // windowBackgroundColor fill automatically.
        GlassSurface(material: .bar, radius: 0) {
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

                        // Grouped + ungrouped tabs
                        ForEach(groupTabs(tabs), id: \.id) { item in
                            switch item {
                            case .group(let group):
                                groupedSection(group)

                            case .ungrouped(let tab):
                                TabRowView(
                                    tab: tab,
                                    isSelected: tab.id == selectedTabID,
                                    profileColorName: profileColors[tab.record.profileID],
                                    onSelect: { onSelect(tab) },
                                    onClose: { onClose(tab) }
                                )
                            }
                        }
                    }
                    .padding(.horizontal, Spacing.px6)
                    .padding(.vertical, Spacing.px6)
                }

                Divider()
                    .opacity(Opacity.divider)

                ProfilePickerView(
                    profiles: profiles,
                    activeProfileID: activeProfileID,
                    onSwitchProfile: onSwitchProfile,
                    onCreateProfile: onCreateProfile,
                    onRenameProfile: onRenameProfile
                )
            }
            .frame(width: ControlSize.sidebarWidth)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Tab Sidebar")
    }

    // MARK: - Group section

    @ViewBuilder
    private func groupedSection(_ group: TabGroup) -> some View {
        let collapsed = collapsedGroups.contains(group.id)

        TabGroupHeaderView(
            group: group,
            isCollapsed: collapsed,
            onToggle: {
                withAnimation(.easeInOut(duration: Motion.standard)) {
                    if collapsed {
                        collapsedGroups.remove(group.id)
                    } else {
                        collapsedGroups.insert(group.id)
                    }
                }
            }
        )

        if !collapsed {
            ForEach(group.tabs) { tab in
                TabRowView(
                    tab: tab,
                    isSelected: tab.id == selectedTabID,
                    profileColorName: profileColors[tab.record.profileID],
                    onSelect: { onSelect(tab) },
                    onClose: { onClose(tab) }
                )
                // Indent grouped tabs slightly to visually nest under the header
                .padding(.leading, Spacing.px12)
            }
        }
    }
}
