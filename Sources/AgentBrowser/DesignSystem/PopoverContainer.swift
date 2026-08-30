// PopoverContainer.swift
// A floating card with an optional header, scrollable body, and optional
// footer. Used for command-palette panels, agent-activity popovers, etc.

import SwiftUI

/// A self-contained floating panel layout.
///
/// - `title`: If provided, renders a header row with the title and a
///   dismissal close button via the `onDismiss` environment action.
/// - `bodyContent`: Placed inside a `ScrollView`; can be any SwiftUI view.
/// - `footer`: Optional footer pinned below the scroll area.
/// - Material background with `Radius.large` corner clip.
///
/// Use the convenience init (see extension below) when no footer is needed.
struct PopoverContainer<Body: View, Footer: View>: View {

    var title: String?
    var width: CGFloat = 280
    @ViewBuilder let bodyContent: Body
    @ViewBuilder let footer: Footer

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        GlassSurface(
            material: .thickMaterial,
            radius: Radius.large,
            elevation: true
        ) {
            VStack(spacing: 0) {
                // Header
                if let title {
                    HStack {
                        Text(title)
                            .font(Typography.title)
                            .foregroundStyle(Color.primary)

                        Spacer()

                        IconButton(
                            systemImage: "xmark",
                            label: "Close",
                            size: ControlSize.iconButtonSmall
                        ) {
                            dismiss()
                        }
                    }
                    .padding(.horizontal, Spacing.px16)
                    .padding(.vertical, Spacing.px12)

                    Divider()
                        .opacity(Opacity.divider)
                }

                // Scrollable body
                ScrollView(.vertical, showsIndicators: false) {
                    bodyContent
                }

                // Footer (only rendered when Footer != EmptyView)
                if Footer.self != EmptyView.self {
                    Divider()
                        .opacity(Opacity.divider)

                    footer
                        .padding(.horizontal, Spacing.px16)
                        .padding(.vertical, Spacing.px8)
                }
            }
        }
        .frame(width: width)
    }
}

// MARK: - Convenience init (no footer)

extension PopoverContainer where Footer == EmptyView {
    /// Creates a popover container with no footer section.
    init(
        title: String? = nil,
        width: CGFloat = 280,
        @ViewBuilder bodyContent: () -> Body
    ) {
        self.title = title
        self.width = width
        self.bodyContent = bodyContent()
        self.footer = EmptyView()
    }
}

// MARK: - Previews

#if DEBUG
#Preview("With title and footer") {
    PopoverContainer(title: "Agent Activity", width: 300) {
        VStack(alignment: .leading, spacing: Spacing.px8) {
            ForEach(0..<5, id: \.self) { i in
                HStack {
                    StatusIndicator(status: i == 1 ? .active : .idle)
                    Text("Task \(i + 1)").font(Typography.body)
                    Spacer()
                    Text("2s ago").font(Typography.caption).foregroundStyle(.secondary)
                }
                .padding(.horizontal, Spacing.px16)
                .padding(.vertical, Spacing.px4)
            }
        }
        .padding(.vertical, Spacing.px8)
    } footer: {
        HStack {
            Spacer()
            Button("View All") {}
                .font(Typography.label)
        }
    }
    .padding(Spacing.px32)
}

#Preview("No title, no footer") {
    PopoverContainer(width: 260) {
        Text("Simple content")
            .font(Typography.body)
            .padding(Spacing.px16)
    }
    .padding(Spacing.px32)
    .preferredColorScheme(.dark)
}
#endif
