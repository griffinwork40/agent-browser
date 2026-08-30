// ProvenanceBadge.swift
// Small icon overlaid on a tab row to distinguish how the tab was created.
// Human tabs show nothing; agent and restored tabs show a subtle SF Symbol.

import SwiftUI

struct ProvenanceBadge: View {

    let provenance: TabProvenance

    var body: some View {
        switch provenance {
        case .human:
            EmptyView()

        case .agent:
            badge(systemName: "cpu")

        case .restored:
            badge(systemName: "clock.arrow.circlepath")
        }
    }

    // MARK: - Private helpers

    @ViewBuilder
    private func badge(systemName: String) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 9))
            .foregroundStyle(.secondary)
            .opacity(Opacity.secondary)
            .help(helpText)
            .accessibilityLabel(accessibilityText)
    }

    private var helpText: String {
        switch provenance {
        case .human:
            return ""
        case .agent(let agentID, _, _):
            return "Created by agent \(agentID)"
        case .restored(let originalAgentID, _):
            if let id = originalAgentID {
                return "Restored — originally created by agent \(id)"
            }
            return "Restored from previous session"
        }
    }

    private var accessibilityText: String { helpText }
}

// MARK: - Preview

#Preview("Provenance variants") {
    HStack(spacing: 20) {
        VStack {
            ProvenanceBadge(provenance: .human)
                .frame(width: 20, height: 20)
                .border(.gray.opacity(0.3))
            Text("human").font(Typography.caption)
        }
        VStack {
            ProvenanceBadge(provenance: .agent(agentID: "claude", sessionTag: "s1", requestedAt: .now))
                .frame(width: 20, height: 20)
            Text("agent").font(Typography.caption)
        }
        VStack {
            ProvenanceBadge(provenance: .restored(originalAgentID: nil, originalSessionTag: nil))
                .frame(width: 20, height: 20)
            Text("restored").font(Typography.caption)
        }
        VStack {
            ProvenanceBadge(provenance: .restored(originalAgentID: "claude", originalSessionTag: "s1"))
                .frame(width: 20, height: 20)
            Text("restored\n(agent)").font(Typography.caption).multilineTextAlignment(.center)
        }
    }
    .padding()
}
