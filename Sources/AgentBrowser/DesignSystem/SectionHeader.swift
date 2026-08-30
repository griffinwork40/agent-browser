// SectionHeader.swift
// A collapsible section label with an optional count badge and a rotating
// chevron that reflects expanded/collapsed state.

import SwiftUI

/// A tappable section header that controls a disclosure state.
///
/// - `title`: Section label text rendered in `Typography.label`.
/// - `isExpanded`: Binding that the header toggles on tap.
/// - `count`: Optional numeric count displayed as an `ActivityBadge`.
/// - Chevron rotates 90° when collapsed → expanded.
/// - Respects Reduce Motion for the rotation animation.
struct SectionHeader: View {

    let title: String
    @Binding var isExpanded: Bool
    var count: Int?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button {
            if reduceMotion {
                isExpanded.toggle()
            } else {
                withAnimation(.easeInOut(duration: Motion.standard)) {
                    isExpanded.toggle()
                }
            }
        } label: {
            HStack(spacing: Spacing.px6) {
                Text(title)
                    .font(Typography.label)
                    .foregroundStyle(Color.secondary)
                    .textCase(.uppercase)

                Spacer()

                if let count, count > 0 {
                    ActivityBadge(style: .count(count), color: .secondary)
                }

                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.secondary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .animation(
                        reduceMotion ? nil : .easeInOut(duration: Motion.standard),
                        value: isExpanded
                    )
            }
            .padding(.horizontal, Spacing.px8)
            .padding(.vertical, Spacing.px4)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityHint(isExpanded ? "Collapse section" : "Expand section")
        .accessibilityAddTraits(.isButton)
    }
}

// MARK: - Previews

#if DEBUG
struct SectionHeader_Previews: PreviewProvider {
    struct Wrapper: View {
        @State private var open1 = true
        @State private var open2 = false

        var body: some View {
            VStack(spacing: 0) {
                SectionHeader(title: "Pinned", isExpanded: $open1, count: 4)

                if open1 {
                    SidebarItem(isSelected: false, label: "Pinned Tab A", action: {}) {
                        Image(systemName: "pin.fill").foregroundStyle(.orange)
                    }
                    SidebarItem(isSelected: true, label: "Pinned Tab B", action: {}) {
                        Image(systemName: "pin.fill").foregroundStyle(.orange)
                    }
                }

                SectionHeader(title: "Open Tabs", isExpanded: $open2, count: 12)

                if open2 {
                    SidebarItem(isSelected: false, label: "Tab 1", action: {}) {
                        Image(systemName: "doc")
                    }
                }
            }
            .frame(width: ControlSize.sidebarWidth)
            .padding(Spacing.px4)
        }
    }

    static var previews: some View {
        Wrapper()
    }
}
#endif
