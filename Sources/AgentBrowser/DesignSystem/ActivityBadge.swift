// ActivityBadge.swift
// A small inline badge showing a dot, a count, or arbitrary text.
// Counts animate with .numericText() content transition.

import SwiftUI

// MARK: - Badge Style

/// Controls what the badge renders.
enum BadgeStyle: Sendable, Equatable {
    /// A small solid dot — used for "unread" or "has activity" signals.
    case dot
    /// A numeric count — animates with `.numericText()` on change.
    case count(Int)
    /// Arbitrary short text (e.g. "New", "AI").
    case text(String)
}

// MARK: - View

/// A compact badge overlay for tabs, sidebar items, and toolbar actions.
///
/// Dot and text badges render with the accent color. Count badges use
/// `.numericText()` content transitions so number changes animate smoothly.
struct ActivityBadge: View {

    let style: BadgeStyle
    var color: Color = .accentColor

    var body: some View {
        Group {
            switch style {
            case .dot:
                dotBadge

            case .count(let n):
                if n > 0 {
                    countBadge(n)
                }

            case .text(let s):
                textBadge(s)
            }
        }
    }

    // MARK: Sub-views

    private var dotBadge: some View {
        Circle()
            .fill(color)
            .frame(width: 6, height: 6)
    }

    private func countBadge(_ count: Int) -> some View {
        Text(count > 99 ? "99+" : "\(count)")
            .font(Typography.label)
            .foregroundStyle(.white)
            .contentTransition(.numericText(countsDown: false))
            .monospacedDigit()
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .frame(minWidth: 16, minHeight: 16)
            .background(color, in: Capsule())
    }

    private func textBadge(_ text: String) -> some View {
        Text(text)
            .font(Typography.label)
            .foregroundStyle(.white)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .frame(minHeight: 16)
            .background(color, in: Capsule())
    }
}

// MARK: - Previews

#if DEBUG
#Preview("Badge styles") {
    HStack(spacing: Spacing.px16) {
        ActivityBadge(style: .dot)
        ActivityBadge(style: .count(3))
        ActivityBadge(style: .count(99))
        ActivityBadge(style: .count(142))
        ActivityBadge(style: .text("AI"))
        ActivityBadge(style: .text("New"))
    }
    .padding(Spacing.px24)
}
#endif
