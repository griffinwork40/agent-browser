// IconButton.swift
// A plain SF Symbol button with hover-state highlight, accessibility support,
// and a disabled-opacity fallback.

import SwiftUI

/// A single icon button using SF Symbols.
///
/// Renders a symbol centred in a fixed square hit-target. On hover the
/// background fills with a subtle primary-color tint; disabled state fades
/// the entire control to `Opacity.disabled`.
struct IconButton: View {

    let systemImage: String
    /// VoiceOver accessibility label and tooltip text.
    let label: String
    var size: CGFloat = ControlSize.iconButtonRegular
    var isEnabled: Bool = true
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                // Glyph at ~50% of the button frame feels balanced.
                .font(.system(size: size * 0.5))
                .frame(width: size, height: size)
                // Extend tap/click target to the full frame.
                .contentShape(.rect)
                .background(
                    isHovered
                        ? Color.primary.opacity(Opacity.subtle)
                        : .clear,
                    in: .rect(cornerRadius: Radius.small)
                )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1.0 : Opacity.disabled)
        .accessibilityLabel(label)
        .help(label)
        .animation(.easeInOut(duration: Motion.micro), value: isHovered)
    }
}

// MARK: - Previews

#if DEBUG
#Preview("Icon buttons") {
    HStack(spacing: Spacing.px8) {
        IconButton(systemImage: "chevron.left", label: "Back") {}
        IconButton(systemImage: "chevron.right", label: "Forward") {}
        IconButton(systemImage: "arrow.clockwise", label: "Reload") {}
        IconButton(
            systemImage: "xmark",
            label: "Close",
            size: ControlSize.iconButtonSmall,
            isEnabled: false
        ) {}
    }
    .padding(Spacing.px16)
}
#endif
