// SidebarHeaderView.swift
// Header strip above the tab list: "Tabs" label, count badge, new-tab button.
// Shows a connected-agent count badge when agents are connected.

import SwiftUI

struct SidebarHeaderView: View {

    let tabCount: Int
    let onNewTab: () -> Void

    @Environment(AgentActivityStore.self) private var activityStore

    var body: some View {
        HStack(spacing: Spacing.px6) {
            Text("Tabs")
                .font(Typography.label)
                .foregroundStyle(.secondary)

            ActivityBadge(style: .count(tabCount), color: .secondary)

            // Agent connection badge — only visible when ≥1 agent is connected
            let connectedCount = activityStore.connectedAgents().count
            if connectedCount > 0 {
                ActivityBadge(style: .count(connectedCount), color: .blue)
                    .help("\(connectedCount) agent\(connectedCount == 1 ? "" : "s") connected")
                    .accessibilityLabel("\(connectedCount) connected agent\(connectedCount == 1 ? "" : "s")")
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
        .animation(.easeInOut(duration: Motion.micro), value: activityStore.connectedAgents().count)
    }
}
