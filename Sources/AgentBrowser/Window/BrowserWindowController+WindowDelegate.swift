// BrowserWindowController+WindowDelegate.swift
// NSWindowDelegate conformance: notifies WindowSessionManager on key / close events.

import AppKit

extension BrowserWindowController: NSWindowDelegate {

    // MARK: - Key Window

    /// Fires when this window becomes the frontmost (key) window.
    /// Updates `WindowSessionManager.activeWindowController` so callers can ask
    /// which window is currently in front without iterating all windows.
    func windowDidBecomeKey(_ notification: Notification) {
        windowSessionManager?.windowDidBecomeKey(self)
    }

    // MARK: - Close

    /// Fires when the window is about to close (user clicks the red button,
    /// Cmd-W on the last tab, or AppKit terminates).
    ///
    /// We notify the manager so it can deregister this controller and update
    /// `activeWindowController` before the NSWindowController deallocates.
    func windowWillClose(_ notification: Notification) {
        windowSessionManager?.closeWindow(self)
    }
}
