// BrowserWindowController+AgentUI.swift
// Wires the ControlStatusView — a thin status bar shown between the toolbar
// and web content when the active tab is under agent control.

import AppKit
import SwiftUI

extension BrowserWindowController {

    // MARK: - Setup

    /// Creates the hosting controller for `ControlStatusView`, embeds it in
    /// `webContentView`, and lays out the status strip below the toolbar.
    ///
    /// Call once from `init`, after `setupLayout()`.
    func setupAgentStatusBar() {
        let hc = NSHostingController(rootView: agentStatusBarView())
        controlStatusHostingController = hc

        let hostView = hc.view
        hostView.translatesAutoresizingMaskIntoConstraints = false
        // Insert above the web content but within webContentView's coordinate space
        webContentView.addSubview(hostView)

        controlStatusTopConstraint = hostView.topAnchor.constraint(
            equalTo: webContentView.topAnchor
        )
        controlStatusHeightConstraint = hostView.heightAnchor.constraint(equalToConstant: 0)

        NSLayoutConstraint.activate([
            controlStatusTopConstraint!,
            controlStatusHeightConstraint!,
            hostView.leadingAnchor.constraint(equalTo: webContentView.leadingAnchor),
            hostView.trailingAnchor.constraint(equalTo: webContentView.trailingAnchor),
        ])

        // Adjust the web view so it starts below the status bar
        controlStatusHeightObservation = hc.observe(\.preferredContentSize) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.updateWebViewTopInset() }
        }
    }

    // MARK: - Update

    /// Called whenever the active tab changes or agent state might have changed.
    /// Shows or hides the `ControlStatusView` based on whether the active tab is
    /// agent-controlled according to `TakeoverHandler`.
    func updateAgentStatusBar() {
        guard let store = agentActivityStore else {
            hideAgentStatusBar()
            return
        }
        guard let activeTab = tabManager.activeTab else {
            hideAgentStatusBar()
            return
        }

        let tabID = activeTab.id
        let isAgentControlled = store.isTabAgentControlled(tabID)

        if isAgentControlled {
            controlStatusHostingController?.rootView = agentStatusBarView()
            showAgentStatusBar()
        } else {
            hideAgentStatusBar()
        }
    }

    // MARK: - Private helpers

    private func agentStatusBarView() -> AnyView {
        guard
            let store = agentActivityStore,
            let tabID = tabManager.activeTab?.id,
            let agent = store.activeAgentForTab(tabID),
            let action = store.actionsForTab(tabID).first
        else {
            return AnyView(EmptyView())
        }

        return AnyView(
            ControlStatusView(
                agentName: agent.displayName,
                actionDescription: action.description,
                agentColorIndex: agent.colorIndex,
                onTakeControl: { [weak self] in
                    guard let self, let tid = self.tabManager.activeTab?.id else { return }
                    self.takeoverHandler?.processHumanEvent(tabID: tid, trigger: .explicit)
                    self.updateAgentStatusBar()
                }
            )
        )
    }

    private func showAgentStatusBar() {
        guard let hc = controlStatusHostingController else { return }
        // Preferred height is determined by ControlStatusView's intrinsic layout;
        // fall back to a sensible default so the bar is always visible.
        let naturalHeight = hc.preferredContentSize.height
        let barHeight = naturalHeight > 0 ? naturalHeight : 28.0

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = Motion.standard
            ctx.allowsImplicitAnimation = true
            controlStatusHeightConstraint?.constant = barHeight
            hc.view.isHidden = false
            updateWebViewTopInset()
            webContentView.layoutSubtreeIfNeeded()
        }
    }

    private func hideAgentStatusBar() {
        guard let hc = controlStatusHostingController else { return }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = Motion.standard
            ctx.allowsImplicitAnimation = true
            controlStatusHeightConstraint?.constant = 0
            hc.view.isHidden = true
            updateWebViewTopInset()
            webContentView.layoutSubtreeIfNeeded()
        }
    }

    /// Shifts the active WKWebView's top constraint to sit below the status bar.
    private func updateWebViewTopInset() {
        guard let tabID = tabManager.activeTab?.id,
              let tab = tabManager.tab(for: tabID) else { return }
        let barHeight = controlStatusHeightConstraint?.constant ?? 0
        let wv = tab.webView
        // Find the existing top constraint pinning wv to webContentView.topAnchor
        // and update its constant so the web content slides down.
        for constraint in webContentView.constraints
        where constraint.firstAnchor == wv.topAnchor
           || constraint.secondAnchor == wv.topAnchor {
            constraint.constant = barHeight
        }
    }
}
