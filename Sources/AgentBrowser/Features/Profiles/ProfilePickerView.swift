// ProfilePickerView.swift
// Sidebar footer that shows the active profile and expands to a profile list.
// Collapsed: colored avatar + profile name + chevron.
// Expanded: list of all profiles (ProfileRowView) + "Add Profile" button.

import SwiftUI

struct ProfilePickerView: View {

    let profiles: [ProfileRecord]
    let activeProfileID: UUID
    let onSwitchProfile: (UUID) -> Void
    let onCreateProfile: () -> Void

    @State private var isExpanded = false

    private var activeProfile: ProfileRecord? {
        profiles.first { $0.id == activeProfileID }
    }

    var body: some View {
        VStack(spacing: 0) {
            if isExpanded {
                profileList
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            collapseToggle
        }
        .animation(.easeInOut(duration: Motion.standard), value: isExpanded)
        .padding(.horizontal, Spacing.px6)
        .padding(.bottom, Spacing.px6)
    }

    // MARK: - Collapsed / Toggle Row

    private var collapseToggle: some View {
        Button {
            withAnimation(.easeInOut(duration: Motion.standard)) {
                isExpanded.toggle()
            }
        } label: {
            GlassSurface(material: .ultraThinMaterial, radius: Radius.small) {
                HStack(spacing: Spacing.px8) {
                    if let profile = activeProfile {
                        avatarCircle(for: profile, size: 22)
                        Text(profile.name)
                            .font(.system(size: 13, weight: .medium))
                            .lineLimit(1)
                            .truncationMode(.tail)
                    } else {
                        Image(systemName: "person.circle")
                            .foregroundStyle(.secondary)
                        Text("No Profile")
                            .font(Typography.body)
                            .foregroundStyle(.secondary)
                    }

                    Spacer(minLength: Spacing.px4)

                    Image(systemName: isExpanded ? "chevron.down" : "chevron.up")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, Spacing.px8)
                .frame(height: ControlSize.tabRowHeight)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(activeProfile.map { "Active profile: \($0.name)" } ?? "Profile picker")
        .accessibilityHint(isExpanded ? "Collapse profile list" : "Expand profile list")
    }

    // MARK: - Expanded List

    private var profileList: some View {
        VStack(spacing: Spacing.px2) {
            ForEach(profiles) { profile in
                ProfileRowView(
                    profile: profile,
                    isActive: profile.id == activeProfileID,
                    onSelect: {
                        onSwitchProfile(profile.id)
                        withAnimation(.easeInOut(duration: Motion.standard)) {
                            isExpanded = false
                        }
                    }
                )
            }

            Divider()
                .opacity(Opacity.divider)
                .padding(.vertical, Spacing.px4)

            HStack {
                IconButton(
                    systemImage: "plus",
                    label: "Add Profile",
                    size: ControlSize.iconButtonSmall,
                    action: {
                        onCreateProfile()
                        withAnimation(.easeInOut(duration: Motion.standard)) {
                            isExpanded = false
                        }
                    }
                )
                Text("Add Profile")
                    .font(Typography.body)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, Spacing.px4)
        }
        .padding(.top, Spacing.px4)
    }

    // MARK: - Avatar helper

    private func avatarCircle(for profile: ProfileRecord, size: CGFloat) -> some View {
        ZStack {
            Circle()
                .fill(ProfileColor.color(for: profile.colorName))
                .frame(width: size, height: size)
            Text(String(profile.name.prefix(1)).uppercased())
                .font(.system(size: size * 0.5, weight: .bold))
                .foregroundStyle(.white)
        }
    }
}
