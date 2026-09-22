// ContentSearchPanel.swift
// Floating NSPanel for cross-tab content search (Cmd-Shift-F).
// Follows the same pattern as other floating panels: vibrancy background,
// non-activating, hides on ESC or focus loss.

import AppKit
import SwiftUI

@MainActor
final class ContentSearchPanel: NSPanel {

    // MARK: - Properties

    private var hostingView: NSHostingView<ContentSearchView>?

    // MARK: - Init

    /// Creates a floating, non-activating content-search panel.
    /// - Parameters:
    ///   - tabs: The current tab list (snapshot at show time).
    ///   - onSelectTab: Called when the user taps a result. Should switch to the tab.
    init(tabs: [BrowserTab], onSelectTab: @escaping (UUID) -> Void) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 48),
            styleMask: [
                .nonactivatingPanel,
                .titled,
                .closable,
                .fullSizeContentView,
                .hudWindow
            ],
            backing: .buffered,
            defer: false
        )

        configure()
        installContentView(tabs: tabs, onSelectTab: onSelectTab)
    }

    // MARK: - Configuration

    private func configure() {
        isFloatingPanel = true
        level = .floating
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isMovableByWindowBackground = true
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        collectionBehavior = [.transient, .ignoresCycle]
    }

    // MARK: - Content

    private func installContentView(tabs: [BrowserTab], onSelectTab: @escaping (UUID) -> Void) {
        let view = ContentSearchView(
            tabs: tabs,
            onSelectTab: onSelectTab,
            onDismiss: { [weak self] in self?.close() }
        )
        let hosting = NSHostingView(rootView: view)
        hosting.translatesAutoresizingMaskIntoConstraints = false
        self.hostingView = hosting

        contentView = hosting

        // Size to fit the SwiftUI content up to the max height
        let fittingSize = hosting.fittingSize
        let panelWidth: CGFloat = 480
        let panelHeight = min(fittingSize.height, 400)
        setContentSize(NSSize(width: panelWidth, height: max(panelHeight, 48)))
    }

    // MARK: - Presentation

    /// Centers the panel below the toolbar of the given parent window and shows it.
    func showCentered(relativeTo parentWindow: NSWindow?) {
        if let parent = parentWindow {
            let parentFrame = parent.frame
            let panelWidth = frame.width
            let originX = parentFrame.midX - panelWidth / 2
            let originY = parentFrame.maxY - 120   // below the toolbar area
            setFrameOrigin(NSPoint(x: originX, y: originY))
        }
        makeKeyAndOrderFront(nil)
    }

    // MARK: - NSPanel Override

    // Allow the panel to become key so the search field can receive keyboard events.
    override var canBecomeKey: Bool { true }
}
