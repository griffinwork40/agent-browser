// GlassSurface.swift
// A material-backed container view that respects the Reduce Transparency
// accessibility setting and optionally adds a drop shadow.

import SwiftUI

/// A surface that applies a vibrancy material background to its content.
///
/// - When `accessibilityReduceTransparency` is on, falls back to an
///   opaque `NSColor.windowBackgroundColor` fill so content remains legible.
/// - Set `elevation: true` to add a subtle drop shadow (e.g. floating panels).
struct GlassSurface<Content: View>: View {

    let material: Material
    let radius: CGFloat
    let elevation: Bool
    @ViewBuilder let content: Content

    @Environment(\.accessibilityReduceTransparency)
    private var reduceTransparency

    init(
        material: Material = .regularMaterial,
        radius: CGFloat = Radius.medium,
        elevation: Bool = false,
        @ViewBuilder content: () -> Content
    ) {
        self.material = material
        self.radius = radius
        self.elevation = elevation
        self.content = content()
    }

    var body: some View {
        content
            .background {
                if reduceTransparency {
                    Color(nsColor: .windowBackgroundColor)
                } else {
                    Rectangle().fill(material)
                }
            }
            .clipShape(.rect(cornerRadius: radius))
            .shadow(
                color: elevation ? Color.black.opacity(0.14) : .clear,
                radius: elevation ? 12 : 0,
                x: 0,
                y: elevation ? 4 : 0
            )
    }
}

// MARK: - Previews

#if DEBUG
#Preview("Light — elevated") {
    GlassSurface(elevation: true) {
        VStack(spacing: Spacing.px8) {
            Text("Elevated Glass").font(Typography.title)
            Text("Secondary line").font(Typography.caption)
        }
        .padding(Spacing.px16)
    }
    .padding(Spacing.px32)
}

#Preview("Dark — no elevation") {
    GlassSurface {
        Text("No shadow").font(Typography.body).padding(Spacing.px12)
    }
    .padding(Spacing.px32)
    .preferredColorScheme(.dark)
}
#endif
