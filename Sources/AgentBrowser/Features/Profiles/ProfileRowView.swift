// ProfileRowView.swift
// A single profile row for the profile picker list.
// Shows: colored avatar circle with initial, profile name, email (if set),
// and a checkmark when this is the active profile.

import SwiftUI

struct ProfileRowView: View {

    let profile: ProfileRecord
    let isActive: Bool
    let onSelect: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: Spacing.px8) {
                avatarCircle

                VStack(alignment: .leading, spacing: 1) {
                    Text(profile.name)
                        .font(isActive ? .system(size: 13, weight: .semibold) : Typography.body)
                        .lineLimit(1)
                        .truncationMode(.tail)

                    if let email = profile.email {
                        Text(email)
                            .font(Typography.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }

                Spacer(minLength: Spacing.px4)

                if isActive {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
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
        .accessibilityLabel(profile.name)
        .accessibilityValue(profile.email ?? "")
        .accessibilityAddTraits(isActive ? .isSelected : [])
        .animation(.easeInOut(duration: Motion.micro), value: isActive)
    }

    // MARK: - Avatar

    private var avatarCircle: some View {
        ZStack {
            Circle()
                .fill(ProfileColor.color(for: profile.colorName))
                .frame(width: 22, height: 22)
                .overlay(
                    Circle()
                        .strokeBorder(Color.white.opacity(isActive ? 0.8 : 0), lineWidth: 1.5)
                )

            Text(String(profile.name.prefix(1)).uppercased())
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.white)
        }
        .frame(width: 22, height: 22)
    }

    // MARK: - Background

    private var rowBackground: some ShapeStyle {
        if isActive  { return AnyShapeStyle(Color.accentColor.opacity(0.12)) }
        if isHovered { return AnyShapeStyle(Color.primary.opacity(Opacity.subtle)) }
        return AnyShapeStyle(.clear)
    }
}
