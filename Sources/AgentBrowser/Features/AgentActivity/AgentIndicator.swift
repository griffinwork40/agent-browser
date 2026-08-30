// AgentIndicator.swift
// Colored left-border strip shown on a tab row to signal agent activity state.

import SwiftUI

// MARK: - State

enum AgentActivityState: Equatable {
    case idle         // no indicator shown
    case working      // agent-color, pulsing
    case needsHuman   // yellow, static
    case done         // green, brief flash
    case error        // red, brief flash
}

// MARK: - View

struct AgentIndicator: View {

    let state: AgentActivityState
    let agentColorIndex: Int

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isPulsing = false

    // Fixed color palette — index wraps via modulo.
    static let agentColors: [Color] = [
        .blue, .purple, .orange, .teal, .pink, .indigo
    ]

    var body: some View {
        if state != .idle {
            Rectangle()
                .fill(indicatorColor)
                .frame(width: 3)
                .opacity(pulseOpacity)
                .onAppear(perform: startPulseIfNeeded)
                .onChange(of: state) { _, newState in
                    isPulsing = false
                    if newState == .working { startPulseIfNeeded() }
                }
                .accessibilityLabel(accessibilityText)
        }
    }

    // MARK: - Private helpers

    private var pulseOpacity: Double {
        guard state == .working && !reduceMotion else { return 1.0 }
        return isPulsing ? 1.0 : 0.5
    }

    private func startPulseIfNeeded() {
        guard state == .working && !reduceMotion else { return }
        withAnimation(
            .easeInOut(duration: 1.0)
            .repeatForever(autoreverses: true)
        ) {
            isPulsing = true
        }
    }

    private var indicatorColor: Color {
        switch state {
        case .idle:       return .clear
        case .working:    return Self.agentColors[agentColorIndex % Self.agentColors.count]
        case .needsHuman: return .yellow
        case .done:       return .green
        case .error:      return .red
        }
    }

    private var accessibilityText: String {
        switch state {
        case .idle:       return ""
        case .working:    return "Agent active"
        case .needsHuman: return "Agent needs your attention"
        case .done:       return "Agent completed"
        case .error:      return "Agent error"
        }
    }
}

// MARK: - Preview

#Preview("All states") {
    HStack(spacing: 16) {
        ForEach(Array([
            AgentActivityState.idle,
            .working,
            .needsHuman,
            .done,
            .error
        ].enumerated()), id: \.offset) { index, state in
            VStack {
                AgentIndicator(state: state, agentColorIndex: index)
                    .frame(height: 40)
                Text(verbatim: "\(state)")
                    .font(Typography.caption)
            }
        }
    }
    .padding()
}
