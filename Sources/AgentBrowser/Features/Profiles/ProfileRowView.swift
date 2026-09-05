// ProfileRowView.swift
// A single profile row for the profile picker list.
// Shows: colored avatar circle with initial, profile name, email (if set),
// and a checkmark when this is the active profile.

import SwiftUI

struct ProfileRowView: View {

    let profile: ProfileRecord
    let isActive: Bool
    let onSelect: () -> Void
    /// When non-nil, a rename pencil button appears on hover. Returns `false` for
    /// invalid (empty / duplicate) names; the field briefly shows an error tint.
    var onRename: ((String) -> Bool)?

    @State private var isHovered = false
    @State private var isRenaming = false
    @State private var renameText = ""
    @State private var renameError = false

    var body: some View {
        if isRenaming {
            renameField
        } else {
            rowButton
        }
    }

    // MARK: - Normal row

    private var rowButton: some View {
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

                if isHovered, onRename != nil {
                    Button {
                        renameText = profile.name
                        renameError = false
                        isRenaming = true
                    } label: {
                        Image(systemName: "pencil")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Rename \(profile.name)")
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
        .animation(.easeInOut(duration: Motion.micro), value: isHovered)
    }

    // MARK: - Rename field

    private var renameField: some View {
        HStack(spacing: Spacing.px4) {
            TextField("Profile name", text: $renameText)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .padding(.horizontal, Spacing.px8)
                .frame(height: ControlSize.tabRowHeight)
                .background(
                    RoundedRectangle(cornerRadius: Radius.small)
                        .strokeBorder(renameError ? Color.red : Color.accentColor, lineWidth: 1)
                )
                .onSubmit { commitRename() }
                .onExitCommand { isRenaming = false }
                .accessibilityLabel("Rename profile")

            Button(action: commitRename) {
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Confirm rename")

            Button { isRenaming = false } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Cancel rename")
        }
        .padding(.horizontal, Spacing.px4)
        .frame(height: ControlSize.tabRowHeight)
    }

    // MARK: - Commit

    private func commitRename() {
        guard let handler = onRename else { isRenaming = false; return }
        if handler(renameText) {
            isRenaming = false
        } else {
            renameError = true
            // Clear error tint after a short delay.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                renameError = false
            }
        }
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
