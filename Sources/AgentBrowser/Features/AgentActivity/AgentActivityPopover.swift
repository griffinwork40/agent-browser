// AgentActivityPopover.swift
// Click-to-expand detail popover showing the agent's current and recent
// actions on a tab, plus pause / resume / end controls.

import SwiftUI

struct AgentActivityPopover: View {

    let agentName: String
    let agentColorIndex: Int
    /// Active + recent actions for this tab, newest last.
    let actions: [AgentAction]

    var onPause:  (() -> Void)?
    var onResume: (() -> Void)?
    var onEnd:    (() -> Void)?

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.px12) {
            headerRow
            Divider()
            actionSection
            Divider()
            controlRow
        }
        .padding(Spacing.px16)
        .frame(width: 280)
    }

    // MARK: - Sections

    private var headerRow: some View {
        HStack(spacing: Spacing.px8) {
            Circle()
                .fill(agentColor)
                .frame(width: 8, height: 8)
            Text(agentName)
                .font(Typography.title)
            Spacer()
        }
    }

    private var actionSection: some View {
        Group {
            if actions.isEmpty {
                Text("No recent actions")
                    .font(Typography.caption)
                    .foregroundStyle(.secondary)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: Spacing.px6) {
                        ForEach(actions) { action in
                            actionRow(action)
                        }
                    }
                }
                .frame(maxHeight: 200)
            }
        }
    }

    private var controlRow: some View {
        HStack(spacing: Spacing.px8) {
            if let onPause {
                Button("Pause", action: onPause)
            }
            if let onResume {
                Button("Resume", action: onResume)
            }
            if let onEnd {
                Button("End", role: .destructive, action: onEnd)
            }
            Spacer()
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }

    // MARK: - Action row

    private func actionRow(_ action: AgentAction) -> some View {
        HStack(spacing: Spacing.px8) {
            statusDot(action.status)
            VStack(alignment: .leading, spacing: 1) {
                Text(action.description)
                    .font(Typography.body)
                    .lineLimit(1)
                Text(action.method)
                    .font(Typography.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(formattedDuration(action.duration))
                .font(Typography.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func statusDot(_ status: ActionStatus) -> some View {
        Circle()
            .fill(dotColor(for: status))
            .frame(width: 6, height: 6)
    }

    // MARK: - Private helpers

    private var agentColor: Color {
        AgentIndicator.agentColors[agentColorIndex % AgentIndicator.agentColors.count]
    }

    private func dotColor(for status: ActionStatus) -> Color {
        switch status {
        case .inFlight:   return .blue
        case .completed:  return .green
        case .failed:     return .red
        case .overridden: return .orange
        }
    }

    private func formattedDuration(_ seconds: TimeInterval) -> String {
        if seconds < 1  { return "<1s" }
        if seconds < 60 { return String(format: "%.0fs", seconds) }
        return String(format: "%.0fm", seconds / 60)
    }
}

// MARK: - Preview

#Preview("With actions") {
    let sampleActions: [AgentAction] = {
        var completed = AgentAction(agentID: "claude", tabID: UUID(), method: "page.read",    description: "Reading product details")
        completed.status = .completed
        completed.completedAt = Date(timeIntervalSinceNow: -4)

        let inFlight = AgentAction(agentID: "claude", tabID: UUID(), method: "page.click",   description: "Clicking 'Add to Cart'")

        var failed = AgentAction(agentID: "claude", tabID: UUID(), method: "page.type",     description: "Filling checkout form")
        failed.status = .failed
        failed.completedAt = Date()

        return [completed, inFlight, failed]
    }()

    AgentActivityPopover(
        agentName: "Claude",
        agentColorIndex: 0,
        actions: sampleActions,
        onPause:  { },
        onResume: nil,
        onEnd:    { }
    )
    .padding()
}

#Preview("Empty") {
    AgentActivityPopover(
        agentName: "GPT-4o",
        agentColorIndex: 1,
        actions: [],
        onPause: nil,
        onResume: { },
        onEnd:    { }
    )
    .padding()
}
