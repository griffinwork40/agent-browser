// SidebarHeaderView.swift
// Header strip above the tab list: "Tabs" label, count badge, new-tab button.

import SwiftUI

struct SidebarHeaderView: View {

    let tabCount: Int
    let onNewTab: () -> Void

    var body: some View {
        HStack(spacing: Spacing.px6) {
            Text("Tabs")
                .font(Typography.label)
                .foregroundStyle(.secondary)

            ActivityBadge(style: .count(tabCount), color: .secondary)

            Spacer()

            IconButton(
                systemImage: "plus",
                label: "New Tab",
                size: ControlSize.iconButtonSmall,
                action: onNewTab
            )
        }
        .padding(.horizontal, Spacing.px12)
        .padding(.vertical, Spacing.px8)
    }
}
