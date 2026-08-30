// StatusIndicator.swift
// A small colored dot that communicates discrete agent/tab states.
// Animated pulse on .active when accessibility allows it.

import SwiftUI

// MARK: - Status Model

/// Discrete states surfaced by the indicator.
enum IndicatorStatus: String, Sendable {
    case idle    = "idle"
    case active  = "active"
    case waiting = "waiting"
    case error   = "error"
    case success = "success"
}

// MARK: - View

/// A small filled circle whose color encodes an `IndicatorStatus`.
///
/// When `animated` is `true` and the status is `.active`, the dot pulses
/// with a repeating opacity animation — suppressed when the user has enabled
/// Reduce Motion.
struct StatusIndicator: View {

    let status: IndicatorStatus
    var animated: Bool = true
    var size: CGFloat = 8

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulsing = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .opacity(shouldPulse ? (pulsing ? 0.3 : 1.0) : 1.0)
            .onAppear {
                guard shouldPulse else { return }
                withAnimation(
                    .easeInOut(duration: 0.9)
                        .repeatForever(autoreverses: true)
                ) {
                    pulsing = true
                }
            }
            .onChange(of: status) { _, _ in
                // Reset animation when status changes.
                pulsing = false
                guard shouldPulse else { return }
                withAnimation(
                    .easeInOut(duration: 0.9)
                        .repeatForever(autoreverses: true)
                ) {
                    pulsing = true
                }
            }
            .onChange(of: reduceMotion) { _, _ in
                pulsing = false
            }
            .accessibilityLabel(accessibilityDescription)
            .accessibilityHidden(false)
    }

    // MARK: Helpers

    private var shouldPulse: Bool {
        animated && status == .active && !reduceMotion
    }

    private var color: Color {
        switch status {
        case .idle:    return Color.secondary
        case .active:  return Color.green
        case .waiting: return Color.orange
        case .error:   return Color.red
        case .success: return Color.green
        }
    }

    private var accessibilityDescription: String {
        switch status {
        case .idle:    return "Idle"
        case .active:  return "Active"
        case .waiting: return "Waiting"
        case .error:   return "Error"
        case .success: return "Success"
        }
    }
}

// MARK: - Previews

#if DEBUG
#Preview("All states") {
    HStack(spacing: Spacing.px16) {
        ForEach([
            IndicatorStatus.idle,
            .active,
            .waiting,
            .error,
            .success
        ], id: \.rawValue) { status in
            VStack(spacing: Spacing.px4) {
                StatusIndicator(status: status)
                Text(status.rawValue)
                    .font(Typography.caption)
            }
        }
    }
    .padding(Spacing.px24)
}
#endif
