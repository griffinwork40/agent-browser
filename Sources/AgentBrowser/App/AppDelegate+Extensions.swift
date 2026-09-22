// AppDelegate+Extensions.swift
// Handles the "Extensions…" menu item: opens an NSPanel hosting
// ExtensionListView so the extensions panel logic lives apart from AppDelegate.

import AppKit
import SwiftUI

extension AppDelegate {

    // MARK: - Extensions panel

    @objc func showExtensionsPanel(_ sender: Any?) {
        if let existing = extensionsPanelWindow, existing.isVisible {
            existing.makeKeyAndOrderFront(nil)
            return
        }
        guard let em = extensionManager else { return }
        let view = ExtensionListView(extensionManager: em)
        let hosting = NSHostingController(rootView: view)
        let window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 360),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Extensions"
        window.contentViewController = hosting
        window.isReleasedWhenClosed = false
        window.center()
        window.makeKeyAndOrderFront(nil)
        extensionsPanelWindow = window
    }
}
