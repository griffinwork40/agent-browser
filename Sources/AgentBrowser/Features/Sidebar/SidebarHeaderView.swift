// SidebarHeaderView.swift
// Header strip above the tab list: "Tabs" label, count badge, connected-agent
// badge, and new-tab button.

import SwiftUI

struct SidebarHeaderView: View {

    let tabCount: Int
    /// Number of currently-connected (non-disconnected) agents.
    /// When zero, no agent badge is rendered.
    let connectedAgentCount: Int
    let onNewTab: () -> Void

    var body: some View {
        HStack(spacing: Spacing.px6) {
            Text("Tabs")
                .font(Typography.label)
                .foregroundStyle(.secondary)

            ActivityBadge(style: .count(tabCount), color: .secondary)

            // Connected-agent badge — only shown when at least one agent is live
            if connectedAgentCount > 0 {
                ActivityBadge(style: .count(connectedAgentCount), color: .blue)
                    .help("\(connectedAgentCount) agent\(connectedAgentCount == 1 ? "" : "s") connected")
                    .accessibilityLabel("\(connectedAgentCount) connected agent\(connectedAgentCount == 1 ? "" : "s")")
                    .transition(.scale.combined(with: .opacity))
            }

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
        .animation(.easeInOut(duration: Motion.micro), value: connectedAgentCount)
    }
}
