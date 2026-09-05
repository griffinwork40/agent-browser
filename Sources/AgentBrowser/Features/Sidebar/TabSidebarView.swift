// TabSidebarView.swift
// The full vertical sidebar: header → divider → scrollable tab list → profile picker.
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

                        // All open tabs
                        ForEach(tabs) { tab in
                            TabRowView(
                                tab: tab,
                                isSelected: tab.id == selectedTabID,
                                profileColorName: profileColors[tab.record.profileID],
                                onSelect: { onSelect(tab) },
                                onClose: { onClose(tab) }
                            )
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
}
