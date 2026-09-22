import AppKit
import WebKit

// MARK: - Ghost Cursor Controller
//
// Manages the ghost cursor overlay lifecycle for a single browser window.
// Creates/destroys GhostCursorView instances per-agent and animates their
// position when the automation service reports element coordinates.
//
// Coordinate conversion: JS element.getBoundingClientRect() returns page-space
// coordinates with (0,0) at the top-left of the viewport. WKWebView's bounds
// also use top-left origin (flipped). NSView uses bottom-left origin (unflipped
// by default), so we flip the Y axis relative to the container height.
//
// Usage:
//   let ctrl = GhostCursorController()
//   ctrl.attach(to: webContentView)                // once, when window is set up
//   ctrl.showCursor(at: pt, agentID: "x",
//                  agentColor: .systemBlue,
//                  agentName: "My Agent")          // on each action
//   ctrl.hideCursor(agentID: "x")                  // on disconnect / explicit hide

@MainActor
final class GhostCursorController {

    // MARK: - State

    private struct CursorEntry {
        let view: GhostCursorView
        var hideTimer: Timer?
    }

    private var cursors: [String: CursorEntry] = [:]   // agentID → entry
    private weak var containerView: NSView?

    // MARK: - Constants

    private enum Config {
        static let animationDuration: TimeInterval = 0.3
        static let autoHideDelay:     TimeInterval = 2.0
        static let cursorAlpha:        CGFloat     = 0.88
    }

    // MARK: - Color Palette
    //
    // Six-color palette matching AgentConnection.colorIndex range (0-5).
    // These are vivid but semi-transparent-friendly so they read on any page background.
    // nonisolated: pure data, safe to call from any concurrency context.

    nonisolated static let palette: [NSColor] = [
        .systemBlue,
        .systemPurple,
        .systemOrange,
        .systemPink,
        .systemTeal,
        .systemGreen,
    ]

    /// Returns the NSColor for a given colorIndex, wrapping around if out of range.
    nonisolated static func paletteColor(at index: Int) -> NSColor {
        palette[abs(index) % palette.count]
    }

    // MARK: - Attachment

    /// Call once after the window's content hierarchy is built.
    /// The controller adds cursor views as siblings on top of the web content.
    func attach(to container: NSView) {
        containerView = container
    }

    // MARK: - Public API

    /// Show (or reposition) the ghost cursor for an agent at the given
    /// *page-coordinate* point (top-left origin, as returned by JS getBoundingClientRect).
    ///
    /// - Parameters:
    ///   - pagePoint:  Element centre in page/viewport coordinates (x right, y down).
    ///   - agentID:    Unique agent identifier.
    ///   - agentColor: Per-agent accent color from AgentActivityStore palette.
    ///   - agentName:  Display name for the label badge.
    func showCursor(at pagePoint: CGPoint, agentID: String,
                    agentColor: NSColor, agentName: String) {
        guard let container = containerView else { return }

        let viewPoint = convertToNSViewCoordinates(pagePoint, in: container)

        if let existing = cursors[agentID] {
            // Reuse and animate existing cursor to new position
            cancelHideTimer(agentID: agentID)
            animateMove(existing.view, to: viewPoint)
            existing.view.alphaValue = Config.cursorAlpha
        } else {
            // Create a new cursor view for this agent
            let cursorView = GhostCursorView(agentColor: agentColor, agentName: agentName)
            cursorView.alphaValue = 0
            cursorView.setFrameOrigin(viewPoint)
            container.addSubview(cursorView, positioned: .above, relativeTo: nil)

            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = Config.animationDuration * 0.5
                cursorView.animator().alphaValue = Config.cursorAlpha
            }
            cursors[agentID] = CursorEntry(view: cursorView, hideTimer: nil)
        }

        scheduleAutoHide(agentID: agentID)
    }

    /// Move an already-visible cursor to a new page-coordinate point.
    /// No-op if no cursor exists for the given agentID.
    func moveCursor(to pagePoint: CGPoint, agentID: String) {
        guard let container = containerView,
              let entry = cursors[agentID] else { return }
        cancelHideTimer(agentID: agentID)
        let viewPoint = convertToNSViewCoordinates(pagePoint, in: container)
        animateMove(entry.view, to: viewPoint)
        scheduleAutoHide(agentID: agentID)
    }

    /// Immediately fade out and remove the cursor for an agent.
    func hideCursor(agentID: String) {
        cancelHideTimer(agentID: agentID)
        fadeOutAndRemove(agentID: agentID)
    }

    /// Remove all cursors (e.g. on window close or agent disconnect).
    func removeAll() {
        for agentID in cursors.keys { hideCursor(agentID: agentID) }
    }

    // MARK: - Coordinate Conversion
    //
    // WKWebView coordinate system: origin top-left, Y grows downward.
    // NSView coordinate system (default, non-flipped): origin bottom-left, Y grows upward.
    //
    // Conversion: nsY = containerHeight - pageY - cursorHeight
    // We subtract cursorHeight so the cursor tip (top of the view) lands at pageY.

    func convertToNSViewCoordinates(_ pagePoint: CGPoint, in container: NSView) -> CGPoint {
        let containerHeight = container.bounds.height
        let cursorHeight: CGFloat = 48   // matches GhostCursorView frame height
        let nsY = containerHeight - pagePoint.y - cursorHeight
        return CGPoint(x: pagePoint.x, y: nsY)
    }

    // MARK: - Animation

    private func animateMove(_ view: GhostCursorView, to origin: CGPoint) {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = Config.animationDuration
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            view.animator().setFrameOrigin(origin)
        }
    }

    // MARK: - Auto-Hide Timer

    private func scheduleAutoHide(agentID: String) {
        cancelHideTimer(agentID: agentID)
        let timer = Timer.scheduledTimer(withTimeInterval: Config.autoHideDelay,
                                         repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.fadeOutAndRemove(agentID: agentID)
            }
        }
        cursors[agentID]?.hideTimer = timer
    }

    private func cancelHideTimer(agentID: String) {
        cursors[agentID]?.hideTimer?.invalidate()
        cursors[agentID]?.hideTimer = nil
    }

    private func fadeOutAndRemove(agentID: String) {
        guard let entry = cursors[agentID] else { return }
        cursors.removeValue(forKey: agentID)   // remove immediately to prevent double-remove
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = Config.animationDuration
            entry.view.animator().alphaValue = 0
        }, completionHandler: {
            entry.view.removeFromSuperview()
        })
    }
}
