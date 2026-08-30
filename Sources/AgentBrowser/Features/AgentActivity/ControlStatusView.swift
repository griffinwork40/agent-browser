// ControlStatusView.swift
// Thin status bar shown beneath the toolbar when an agent is active on
// the currently-focused tab. Displays agent identity, current action, and
// a "Take Control" button to hand off to the human.

import SwiftUI

struct ControlStatusView: View {

    let agentName: String
    let actionDescription: String
    let agentColorIndex: Int
    let onTakeControl: () -> Void

    var body: some View {
        HStack(spacing: Spacing.px8) {
            presenceDot
            agentLabel
            actionLabel
            Spacer()
            takeControlButton
        }
        .padding(.horizontal, Spacing.px12)
        .padding(.vertical, Spacing.px4)
        .background(.bar)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Agent \(agentName) is active. \(actionDescription)")
    }

    // MARK: - Sub-views

    private var presenceDot: some View {
        Circle()
            .fill(AgentIndicator.agentColors[agentColorIndex % AgentIndicator.agentColors.count])
            .frame(width: 6, height: 6)
    }

    private var agentLabel: some View {
        Text(agentName)
            .font(Typography.label)
            .foregroundStyle(.secondary)
    }

    private var actionLabel: some View {
        Text(actionDescription)
            .font(Typography.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
    }

    private var takeControlButton: some View {
        Button("Take Control", action: onTakeControl)
            .buttonStyle(.bordered)
            .controlSize(.small)
    }
}

// MARK: - Preview

#Preview("Agent active") {
    VStack(spacing: 0) {
        // Simulated toolbar placeholder
        Rectangle()
            .fill(Color(.windowBackgroundColor))
            .frame(height: 52)
            .overlay(Text("[ toolbar ]").font(Typography.caption).foregroundStyle(.secondary))

        ControlStatusView(
            agentName: "Claude",
            actionDescription: "Clicking 'Add to Cart' on product page",
            agentColorIndex: 0,
            onTakeControl: { }
        )

        Rectangle()
            .fill(Color(.textBackgroundColor))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(Text("[ web content ]").foregroundStyle(.secondary))
    }
    .frame(width: 800, height: 200)
}

#Preview("Long description truncation") {
    ControlStatusView(
        agentName: "GPT-4o",
        actionDescription: "Filling out the shipping address form with information extracted from user preferences and prior session data",
        agentColorIndex: 2,
        onTakeControl: { }
    )
    .frame(width: 600)
}
