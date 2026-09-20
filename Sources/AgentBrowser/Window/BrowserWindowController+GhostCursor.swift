import AppKit

// MARK: - Ghost Cursor Wiring
//
// Extension of BrowserWindowController that:
//   1. Implements GhostCursorDelegate to receive agent interaction events.
//   2. Maps agentID → (agentColor, agentName) via AgentActivityStore.
//   3. Routes position events to the GhostCursorController overlay.
//
// The GhostCursorController is attached to webContentView so cursor views are
// always children of the content area, not the full window frame.

extension BrowserWindowController: GhostCursorDelegate {

    // MARK: - Setup

    /// Call once after the window layout and automation service are ready.
    /// Attaches the cursor controller to the web content area and wires the delegate.
    func setupGhostCursor(automationService: BrowserAutomationService,
                          activityStore: AgentActivityStore) {
        ghostCursorController.attach(to: webContentView)
        automationService.ghostCursorDelegate = self
        self.agentActivityStore = activityStore
    }

    // MARK: - GhostCursorDelegate

    /// Called by BrowserAutomationService after each successful interactive action.
    /// Looks up agent metadata from AgentActivityStore and shows/moves the cursor.
    func agentDidInteract(at point: CGPoint, agentID: String) {
        let color  = resolveAgentColor(agentID: agentID)
        let name   = resolveAgentName(agentID: agentID)
        ghostCursorController.showCursor(at: point,
                                         agentID: agentID,
                                         agentColor: color,
                                         agentName: name)
    }

    // MARK: - Helpers

    private func resolveAgentColor(agentID: String) -> NSColor {
        guard let store = agentActivityStore,
              let conn = store.connections.first(where: { $0.id == agentID }) else {
            return .systemBlue
        }
        return GhostCursorController.paletteColor(at: conn.colorIndex)
    }

    private func resolveAgentName(agentID: String) -> String {
        guard let store = agentActivityStore,
              let conn = store.connections.first(where: { $0.id == agentID }) else {
            return agentID
        }
        return conn.displayName
    }
}
