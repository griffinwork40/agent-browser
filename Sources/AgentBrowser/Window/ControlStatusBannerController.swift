// ControlStatusBannerController.swift
// Manages the ControlStatusView NSHostingController that appears between the
// toolbar and web content when an agent is active on the current tab.
// Kept in its own file to respect BrowserWindowController's 350-LOC budget.

import AppKit
import SwiftUI

/// Thin AppKit wrapper around ControlStatusView.
/// The owning BrowserWindowController calls `update(activeTabID:)` whenever
/// the selected tab changes, and this object shows/hides the banner accordingly.
@MainActor
final class ControlStatusBannerController {

    // MARK: - Public API

    /// The AppKit view to embed between the toolbar container and web content.
    /// Zero-height when no agent is active so layout is unaffected.
    let hostingView: NSView

    // MARK: - Dependencies

    private let activityStore: AgentActivityStore
    private let takeoverHandler: TakeoverHandler

    // MARK: - Internal state

    private var hostingController: NSHostingController<BannerContent>?
    private var currentTabID: UUID?

    // MARK: - Init

    init(activityStore: AgentActivityStore, takeoverHandler: TakeoverHandler) {
        self.activityStore = activityStore
        self.takeoverHandler = takeoverHandler

        let placeholder = NSView()
        placeholder.translatesAutoresizingMaskIntoConstraints = false
        self.hostingView = placeholder
    }

    // MARK: - Update

    /// Called whenever the window's active tab changes.
    func update(activeTabID: UUID?) {
        currentTabID = activeTabID
        refresh()
    }

    /// Re-evaluates whether to show the banner for the stored `currentTabID`.
    /// Safe to call from @Observable change handlers.
    func refresh() {
        guard let tabID = currentTabID else {
            removeBanner()
            return
        }

        let controlState = takeoverHandler.controlState(for: tabID)
        guard controlState.state == .agentActive,
              let agent = activityStore.activeAgentForTab(tabID),
              let action = activityStore.actionsForTab(tabID).first
        else {
            removeBanner()
            return
        }

        showBanner(agentName: agent.displayName,
                   description: action.description.isEmpty ? action.method : action.description,
                   colorIndex: agent.colorIndex,
                   tabID: tabID)
    }

    // MARK: - Private helpers

    private func showBanner(
        agentName: String,
        description: String,
        colorIndex: Int,
        tabID: UUID
    ) {
        let content = BannerContent(
            agentName: agentName,
            actionDescription: description,
            agentColorIndex: colorIndex,
            onTakeControl: { [weak self] in
                self?.takeoverHandler.endAgent(tabID: tabID)
            }
        )

        if let hc = hostingController {
            hc.rootView = content
        } else {
            let hc = NSHostingController(rootView: content)
            hostingController = hc

            let view = hc.view
            view.translatesAutoresizingMaskIntoConstraints = false
            hostingView.addSubview(view)
            NSLayoutConstraint.activate([
                view.topAnchor.constraint(equalTo: hostingView.topAnchor),
                view.bottomAnchor.constraint(equalTo: hostingView.bottomAnchor),
                view.leadingAnchor.constraint(equalTo: hostingView.leadingAnchor),
                view.trailingAnchor.constraint(equalTo: hostingView.trailingAnchor),
            ])
        }
    }

    private func removeBanner() {
        hostingController?.view.removeFromSuperview()
        hostingController = nil
    }
}

// MARK: - SwiftUI content type alias

private typealias BannerContent = ControlStatusView
