// TabRowView.swift
// A single tab row in the sidebar. Uses DesignSystem tokens throughout.
// Renders: favicon circle, title + host, hover-revealed close button.

import SwiftUI

struct TabRowView: View {

    let tab: BrowserTab        // @Observable — SwiftUI auto-tracks title/url/isLoading
    let isSelected: Bool
    let profileColorName: String?
    let onSelect: () -> Void
    let onClose: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: Spacing.px8) {
                faviconView

                VStack(alignment: .leading, spacing: 1) {
                    Text(tab.title)
                        .font(Typography.body)
                        .lineLimit(1)
                        .truncationMode(.tail)

                    if let host = tab.url?.host {
                        Text(host)
                            .font(Typography.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }

                Spacer(minLength: Spacing.px4)

                // Close button appears on hover or when row is selected
                if isHovered || isSelected {
                    IconButton(
                        systemImage: "xmark",
                        label: "Close tab",
                        size: ControlSize.iconButtonSmall,
                        action: onClose
                    )
                    .transition(.opacity)
                }
            }
            .padding(.horizontal, Spacing.px8)
            .padding(.vertical, Spacing.px6)
            .frame(height: ControlSize.tabRowHeight)
            .background(rowBackground, in: .rect(cornerRadius: Radius.small))
        }
        .buttonStyle(.plain)
        .onHover { hovered in
            withAnimation(.easeInOut(duration: Motion.micro)) {
                isHovered = hovered
            }
        }
        .accessibilityLabel(tab.title)
        .accessibilityValue(tab.url?.absoluteString ?? "")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .animation(.easeInOut(duration: Motion.micro), value: isSelected)
    }

    // MARK: - Favicon

    /// Colored circle with the first letter of the domain.
    /// Shows a spinner while loading; will be replaced with real favicon loading later.
    /// When `profileColorName` is set, a 1.5pt colored ring is drawn around the circle.
    private var faviconView: some View {
        ZStack {
            // Profile color ring — only shown when the tab belongs to a named profile
            if let colorName = profileColorName {
                Circle()
                    .stroke(resolvedProfileColor(colorName), lineWidth: 1.5)
                    .frame(width: 20, height: 20)
            }

            Circle()
                .fill(isSelected ? Color.accentColor : Color.secondary.opacity(0.3))
                .frame(width: 16, height: 16)

            if tab.isLoading {
                ProgressView()
                    .scaleEffect(0.4)
                    .frame(width: 16, height: 16)
            } else {
                let letter = String((tab.url?.host ?? tab.title).prefix(1)).uppercased()
                Text(letter)
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(isSelected ? .white : .primary)
            }
        }
        .frame(width: 20, height: 20)
    }

    // MARK: - Profile color helper

    /// Maps a profile colorName string (from ProfileRecord) to a SwiftUI Color.
    /// Mirrors the palette defined in ProfileRecord.defaultColors.
    private func resolvedProfileColor(_ name: String) -> Color {
        switch name {
        case "blue":   return .blue
        case "indigo": return .indigo
        case "purple": return .purple
        case "pink":   return .pink
        case "red":    return .red
        case "orange": return .orange
        case "yellow": return .yellow
        case "green":  return .green
        case "teal":   return .teal
        case "cyan":   return .cyan
        default:       return .gray
        }
    }

    // MARK: - Background

    private var rowBackground: some ShapeStyle {
        if isSelected { return AnyShapeStyle(Color.accentColor.opacity(0.15)) }
        if isHovered  { return AnyShapeStyle(Color.primary.opacity(Opacity.subtle)) }
        return AnyShapeStyle(.clear)
    }
}
