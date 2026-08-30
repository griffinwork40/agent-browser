// ToolbarSurface.swift
// A full-width horizontal bar for toolbars and address bars.
// Material background degrades to opaque when Reduce Transparency is on.

import SwiftUI

/// A full-width surface intended for the browser toolbar.
///
/// - Applies `.bar` material by default, which is optimised for HUD-style
///   bars that sit at a window edge.
/// - When `accessibilityReduceTransparency` is on, falls back to an opaque
///   `NSColor.windowBackgroundColor` fill.
/// - Content is laid out in an HStack with horizontal padding.
struct ToolbarSurface<Content: View>: View {

    var height: CGFloat = ControlSize.toolbarHeight
    @ViewBuilder let content: Content

    @Environment(\.accessibilityReduceTransparency)
    private var reduceTransparency

    var body: some View {
        HStack(spacing: Spacing.px8) {
            content
        }
        .padding(.horizontal, Spacing.px12)
        .frame(maxWidth: .infinity)
        .frame(height: height)
        .background {
            if reduceTransparency {
                Color(nsColor: .windowBackgroundColor)
            } else {
                Rectangle().fill(.bar)
            }
        }
    }
}

// MARK: - Previews

#if DEBUG
#Preview("Toolbar surface — light") {
    VStack(spacing: 0) {
        ToolbarSurface {
            IconButton(systemImage: "chevron.left", label: "Back") {}
            IconButton(systemImage: "chevron.right", label: "Forward") {}
            IconButton(systemImage: "arrow.clockwise", label: "Reload") {}

            CommandField(
                text: .constant("https://example.com"),
                placeholder: "Search or enter address",
                leadingIcon: "lock.fill"
            )

            IconButton(systemImage: "sidebar.right", label: "Toggle Sidebar") {}
        }

        Color.primary.opacity(0.05)
            .frame(height: 300)
    }
    .frame(width: 640)
}

#Preview("Toolbar surface — dark") {
    ToolbarSurface {
        IconButton(systemImage: "chevron.left", label: "Back") {}
        CommandField(
            text: .constant(""),
            placeholder: "Search tabs…"
        )
    }
    .frame(width: 480)
    .preferredColorScheme(.dark)
}
#endif
