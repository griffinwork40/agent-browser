// SidebarItem.swift
// A selectable list row for the sidebar: leading slot, label, optional
// trailing slot. Carries hover and selection state visually.

import SwiftUI

/// A generic selectable sidebar row.
///
/// - `Leading`: arbitrary view rendered before the label (icon, favicon, etc.)
/// - `Trailing`: arbitrary view rendered after the label (badge, close btn, etc.)
/// - Uses `AnyShapeStyle` internally so the background can switch between
///   three distinct values (selected / hover / clear) without a type-erase issue.
struct SidebarItem<Leading: View, Trailing: View>: View {

    let isSelected: Bool
    @ViewBuilder let leading: Leading
    let label: String
    @ViewBuilder let trailing: Trailing
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: Spacing.px8) {
                leading
                Text(label)
                    .font(Typography.body)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: Spacing.px4)
                trailing
            }
            .padding(.horizontal, Spacing.px8)
            .padding(.vertical, Spacing.px6)
            .frame(minHeight: ControlSize.tabRowHeight - Spacing.px8)
            .background(rowBackground, in: .rect(cornerRadius: Radius.small))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .accessibilityLabel(label)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .animation(.easeInOut(duration: Motion.micro), value: isHovered)
        .animation(.easeInOut(duration: Motion.micro), value: isSelected)
    }

    // MARK: Background

    private var rowBackground: some ShapeStyle {
        if isSelected {
            return AnyShapeStyle(Color.accentColor.opacity(0.15))
        }
        if isHovered {
            return AnyShapeStyle(Color.primary.opacity(Opacity.subtle))
        }
        return AnyShapeStyle(.clear)
    }
}

// MARK: - Convenience init (no trailing view)

extension SidebarItem where Trailing == EmptyView {
    /// Creates a sidebar item with no trailing content.
    init(
        isSelected: Bool,
        label: String,
        action: @escaping () -> Void,
        @ViewBuilder leading: () -> Leading
    ) {
        self.isSelected = isSelected
        self.leading = leading()
        self.label = label
        self.trailing = EmptyView()
        self.action = action
    }
}

// MARK: - Previews

#if DEBUG
#Preview("Sidebar items") {
    VStack(spacing: 0) {
        // Convenience init (no trailing)
        SidebarItem(isSelected: true, label: "Selected Tab", action: {}) {
            Image(systemName: "globe")
                .foregroundStyle(Color.accentColor)
        }
        // Primary init with trailing badge
        SidebarItem(
            isSelected: false,
            leading: { Image(systemName: "doc") },
            label: "Unselected Tab",
            trailing: { ActivityBadge(style: .count(3)) },
            action: {}
        )
        // Convenience init — long title
        SidebarItem(isSelected: false, label: "Long title that definitely overflows the sidebar width", action: {}) {
            Image(systemName: "star.fill")
                .foregroundStyle(.yellow)
        }
    }
    .frame(width: ControlSize.sidebarWidth)
    .padding(Spacing.px4)
}
#endif
