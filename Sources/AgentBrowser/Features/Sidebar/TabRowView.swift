// TabRowView.swift
// A single tab row in the sidebar. Uses DesignSystem tokens throughout.
// Renders: favicon circle, title + host, hover-revealed close button,
// thumbnail popover after a 500ms hover delay, agent indicator strip (left),
// and a provenance badge next to the favicon.
import SwiftUI

struct TabRowView: View {

    let tab: BrowserTab        // @Observable — SwiftUI auto-tracks title/url/isLoading
    let isSelected: Bool
    let profileColorName: String?
    let thumbnailCache: TabThumbnailCache
    let onSelect: () -> Void
    let onClose: () -> Void

    /// Agent data source — passed directly so the row stays a pure value-type view.
    var agentActivityStore: AgentActivityStore?

    @State private var isHovered = false
    @State private var isShowingActivityPopover = false

    // MARK: - Thumbnail popover state

    @State private var showPopover   = false
    @State private var thumbnail: NSImage?
    @State private var hoverTimer: Timer?

    var body: some View {
        HStack(spacing: 0) {
            // Left-edge agent indicator strip (3 pt wide, full row height)
            agentIndicatorStrip

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
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showPopover, arrowEdge: .trailing) {
            TabThumbnailPopover(tab: tab, thumbnail: thumbnail)
        }
        .onHover { hovered in
            withAnimation(.easeInOut(duration: Motion.micro)) {
                isHovered = hovered
            }
            handleHover(hovered)
        }
        .onDisappear {
            hoverTimer?.invalidate()
            hoverTimer = nil
        }
        .accessibilityLabel(tab.title)
        .accessibilityValue(tab.url?.absoluteString ?? "")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .animation(.easeInOut(duration: Motion.micro), value: isSelected)
        .popover(isPresented: $isShowingActivityPopover, arrowEdge: .leading) {
            activityPopoverContent
        }
    }

    // MARK: - Agent Indicator Strip

    /// 3 pt colored left border; tapping it opens the activity popover.
    @ViewBuilder
    private var agentIndicatorStrip: some View {
        let state = agentActivityState
        if state != .idle {
            AgentIndicator(state: state, agentColorIndex: agentColorIndex)
                .frame(width: 3, height: ControlSize.tabRowHeight)
                .onTapGesture { isShowingActivityPopover = true }
        } else {
            // Reserve the 3 pt column so the row width stays stable.
            Color.clear.frame(width: 3, height: ControlSize.tabRowHeight)
        }
    }

    // MARK: - Hover / popover logic

    private func handleHover(_ hovered: Bool) {
        if hovered {
            // Start a 500ms delay before showing the popover.
            hoverTimer?.invalidate()
            hoverTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { _ in
                Task { @MainActor in
                    // Prefetch the thumbnail while waiting — result lands before popover opens.
                    thumbnail = await thumbnailCache.thumbnail(for: tab)
                    showPopover = true
                }
            }
        } else {
            // Cancel timer and dismiss popover immediately on mouse-out.
            hoverTimer?.invalidate()
            hoverTimer = nil
            showPopover = false
        }
    }

    // MARK: - Favicon

    /// Colored circle with the first letter of the domain.
    /// Shows a spinner while loading. A `ProvenanceBadge` appears in the
    /// bottom-right corner when the tab was created by an agent.
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

            // Provenance badge: bottom-right overlay on the favicon circle
            ProvenanceBadge(provenance: tab.record.provenance)
                .frame(width: 10, height: 10)
                .offset(x: 6, y: 6)
        }
        .frame(width: 20, height: 20)
    }

    // MARK: - Activity Popover Content

    @ViewBuilder
    private var activityPopoverContent: some View {
        if let store = agentActivityStore,
           let agent = store.activeAgentForTab(tab.id) {
            let tabActions = store.actionsForTab(tab.id)
            let recent = store.recentActions.filter { $0.tabID == tab.id }
            let actions = Array((tabActions + recent).prefix(20))
            AgentActivityPopover(
                agentName: agent.displayName,
                agentColorIndex: agent.colorIndex,
                actions: actions,
                onPause:  nil,
                onResume: nil,
                onEnd:    nil
            )
        }
    }

    // MARK: - Agent State Helpers

    private var agentActivityState: AgentActivityState {
        guard let store = agentActivityStore else { return .idle }
        if store.isTabAgentControlled(tab.id) { return .working }
        return .idle
    }

    private var agentColorIndex: Int {
        agentActivityStore?.activeAgentForTab(tab.id)?.colorIndex ?? 0
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
