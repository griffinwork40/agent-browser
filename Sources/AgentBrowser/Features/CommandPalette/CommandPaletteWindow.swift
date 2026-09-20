// CommandPaletteWindow.swift
// Floating NSPanel that hosts the command palette search UI.

import AppKit
import SwiftUI

/// A non-activating floating panel that hosts `CommandPaletteView`.
///
/// Visual design: vibrancy background (hudWindow material), 12-pt corner
/// radius, and a transparent titlebar so the glass surface fills the full
/// panel rect without any extra chrome.
final class CommandPaletteWindow: NSPanel {

    init(contentRect: NSRect, hostingView: NSView) {
        super.init(
            contentRect: contentRect,
            styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .floating
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isMovableByWindowBackground = false
        backgroundColor = .clear
        hasShadow = true

        // Vibrancy background — sits behind the SwiftUI content view.
        let effect = NSVisualEffectView(frame: contentRect)
        effect.material = .hudWindow
        effect.state = .active
        effect.blendingMode = .behindWindow
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 12
        effect.layer?.masksToBounds = true

        // Pin the SwiftUI hosting view inside the effect view.
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(hostingView)
        NSLayoutConstraint.activate([
            hostingView.topAnchor.constraint(equalTo: effect.topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
            hostingView.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
        ])

        contentView = effect
    }

    // NSPanel must opt in to key-window status explicitly.
    override var canBecomeKey: Bool { true }

    // Backup Escape handler — SwiftUI's onKeyPress handles it first,
    // but cancelOperation fires if the event somehow reaches AppKit.
    override func cancelOperation(_ sender: Any?) {
        close()
    }
}
