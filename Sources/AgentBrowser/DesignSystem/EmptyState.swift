// EmptyState.swift
// Centred placeholder view for empty containers (no tabs, no history, etc.)

import SwiftUI

/// A vertically-centred placeholder for empty lists and panels.
///
/// Shows an SF Symbol icon, a large title, a secondary message, and an
/// optional action button. All text adapts to dark/light mode via semantic
/// foreground styles.
struct EmptyState: View {

    let systemImage: String
    let title: String
    let message: String
    var actionLabel: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: Spacing.px16) {
            Spacer()

            Image(systemName: systemImage)
                .font(.system(size: 44, weight: .thin))
                .foregroundStyle(Color.secondary)
                .accessibilityHidden(true)  // Decorative — title carries meaning.

            VStack(spacing: Spacing.px6) {
                Text(title)
                    .font(Typography.displayLarge)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(Color.primary)

                Text(message)
                    .font(Typography.body)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(Color.secondary)
                    .frame(maxWidth: 280)
            }

            if let label = actionLabel, let handler = action {
                Button(label, action: handler)
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
                    .padding(.top, Spacing.px8)
            }

            Spacer()
        }
        .padding(Spacing.px32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Previews

#if DEBUG
#Preview("With action") {
    EmptyState(
        systemImage: "tray",
        title: "No Tabs Open",
        message: "Open a URL or use the command palette to get started.",
        actionLabel: "New Tab"
    ) {
        print("New tab tapped")
    }
    .frame(width: 360, height: 400)
}

#Preview("No action") {
    EmptyState(
        systemImage: "magnifyingglass",
        title: "No Results",
        message: "Try a different search term."
    )
    .frame(width: 360, height: 300)
    .preferredColorScheme(.dark)
}
#endif
