// TabGroupHeaderView.swift
// Cluster header row rendered above each group of agent tabs.
// Shows: colored agent dot · sessionTag label · tab count badge · chevron.

import SwiftUI

struct TabGroupHeaderView: View {

    let group: TabGroup
    let isCollapsed: Bool
    let onToggle: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: Spacing.px8) {
                // Agent color dot — deterministic hue from agentID hash
                Circle()
                    .fill(agentColor(for: group.agentID))
                    .frame(width: 8, height: 8)

                // Session tag label
                Text(group.displayTitle)
                    .font(Typography.caption)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)

                // Tab count badge
                Text("\(group.tabs.count)")
                    .font(Typography.label)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, Spacing.px4)
                    .padding(.vertical, 1)
                    .background(
                        Color.secondary.opacity(Opacity.subtle * 1.5),
                        in: .rect(cornerRadius: Radius.pill)
                    )

                Spacer(minLength: Spacing.px4)

                // Collapse / expand chevron
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(isCollapsed ? 0 : 90))
                    .animation(.easeInOut(duration: Motion.micro), value: isCollapsed)
            }
            .padding(.horizontal, Spacing.px8)
            .padding(.vertical, Spacing.px4)
            .background(
                isHovered
                    ? AnyShapeStyle(Color.primary.opacity(Opacity.subtle))
                    : AnyShapeStyle(Color.clear),
                in: .rect(cornerRadius: Radius.small)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovered in
            withAnimation(.easeInOut(duration: Motion.micro)) {
                isHovered = hovered
            }
        }
        .accessibilityLabel("\(group.displayTitle) group, \(group.tabs.count) tabs")
        .accessibilityHint(isCollapsed ? "Expand group" : "Collapse group")
        .accessibilityAddTraits(.isButton)
    }

    // MARK: - Agent color

    /// Maps an agentID string to a stable, visually distinct Color.
    /// Uses djb2 hash so the same agentID always maps to the same hue.
    private func agentColor(for agentID: String) -> Color {
        let palette: [Color] = [
            .blue, .indigo, .purple, .pink,
            .orange, .teal, .green, .red,
        ]
        let hash = agentID.unicodeScalars.reduce(5381) { acc, scalar in
            (acc &* 33) &+ Int(scalar.value)
        }
        return palette[abs(hash) % palette.count]
    }
}
