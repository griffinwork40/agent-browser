// CommandField.swift
// A pill-shaped text field that works as address bar, search input, or
// command palette trigger. Includes optional leading icon and a clear button.

import SwiftUI

/// A pill-shaped input field suitable for URL entry, search, or commands.
///
/// - Shows a leading SF Symbol icon when `leadingIcon` is set.
/// - Displays an `×` clear button whenever there is non-empty text.
/// - `onSubmit` fires when the user presses Return.
/// - `onCancel` fires when the user presses Escape (and the field is focused).
struct CommandField: View {

    @Binding var text: String
    let placeholder: String
    var leadingIcon: String?
    var onSubmit: ((String) -> Void)?
    var onCancel: (() -> Void)?

    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: Spacing.px6) {
            // Optional leading icon
            if let icon = leadingIcon {
                Image(systemName: icon)
                    .font(.system(size: 13))
                    .foregroundStyle(Color.secondary)
                    .frame(width: 16)
            }

            // Core text input
            TextField(placeholder, text: $text)
                .font(Typography.mono)
                .textFieldStyle(.plain)
                .focused($isFocused)
                .onSubmit {
                    onSubmit?(text)
                }

            // Clear button — only visible when there is text
            if !text.isEmpty {
                IconButton(
                    systemImage: "xmark.circle.fill",
                    label: "Clear",
                    size: 18
                ) {
                    text = ""
                    isFocused = true
                }
                .foregroundStyle(Color.secondary)
                .transition(.opacity.animation(.easeInOut(duration: Motion.micro)))
            }
        }
        .padding(.horizontal, Spacing.px12)
        .padding(.vertical, Spacing.px6)
        .background(
            .regularMaterial,
            in: .rect(cornerRadius: Radius.pill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Radius.pill)
                .strokeBorder(
                    isFocused
                        ? Color.accentColor.opacity(0.6)
                        : Color.primary.opacity(Opacity.divider),
                    lineWidth: 1
                )
        )
        // Escape key → cancel
        .onKeyPress(.escape) {
            onCancel?()
            isFocused = false
            return .handled
        }
        .animation(.easeInOut(duration: Motion.micro), value: text.isEmpty)
        .animation(.easeInOut(duration: Motion.micro), value: isFocused)
    }
}

// MARK: - Previews

#if DEBUG
struct CommandField_Previews: PreviewProvider {
    struct Wrapper: View {
        @State private var url = "https://example.com"
        @State private var empty = ""

        var body: some View {
            VStack(spacing: Spacing.px16) {
                CommandField(
                    text: $url,
                    placeholder: "Search or enter address",
                    leadingIcon: "lock.fill"
                ) { submitted in
                    print("Submitted:", submitted)
                } onCancel: {
                    print("Cancelled")
                }

                CommandField(
                    text: $empty,
                    placeholder: "Search tabs…"
                )
            }
            .frame(width: 480)
            .padding(Spacing.px24)
        }
    }

    static var previews: some View {
        Wrapper()
    }
}
#endif
