import AppKit

// MARK: - Ghost Cursor Delegate Protocol
//
// Implemented by BrowserWindowController to receive cursor position events from
// the automation service. Using a protocol keeps BrowserAutomationService free of
// any AppKit/UI import while still allowing the window to drive the cursor overlay.
//
// Thread safety: all calls must arrive on the MainActor.

@MainActor
protocol GhostCursorDelegate: AnyObject {
    /// Called when an agent performs an interactive action on an element.
    /// - Parameters:
    ///   - point:   Element centre in page/viewport coordinates (top-left origin).
    ///   - agentID: Unique agent identifier from the HTTP request.
    func agentDidInteract(at point: CGPoint, agentID: String)
}
