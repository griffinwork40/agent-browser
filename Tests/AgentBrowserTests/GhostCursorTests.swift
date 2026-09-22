import Testing
import AppKit
@testable import AgentBrowser

// MARK: - Ghost Cursor Tests
//
// Tests for GhostCursorController: coordinate conversion, cursor lifecycle,
// palette mapping, auto-hide timer scheduling, and animation state management.
//
// These tests run without a display server because they operate on
// GhostCursorController's in-memory cursor dictionary, not rendered views.
// Any test that needs a visible NSView creates a mock container view whose
// bounds we set explicitly.

@Suite("GhostCursor")
struct GhostCursorTests {

    // MARK: - Coordinate Conversion

    @Test("Y-axis flip: page origin top-left maps to NSView bottom-left origin")
    @MainActor func coordinateConversionFlipsY() {
        let ctrl = GhostCursorController()
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))

        // Page point at the top-left corner (0, 0) should map near the bottom of the view.
        let topLeft = ctrl.convertToNSViewCoordinates(CGPoint(x: 0, y: 0), in: container)
        // nsY = containerHeight(600) - pageY(0) - cursorHeight(48) = 552
        #expect(topLeft.x == 0)
        #expect(topLeft.y == 552)

        // Page point in the middle of a 800×600 view
        let center = ctrl.convertToNSViewCoordinates(CGPoint(x: 400, y: 300), in: container)
        #expect(center.x == 400)
        #expect(center.y == 252)  // 600 - 300 - 48
    }

    @Test("X-axis is passed through unchanged")
    @MainActor func xAxisPassthrough() {
        let ctrl = GhostCursorController()
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 1024, height: 768))
        let result = ctrl.convertToNSViewCoordinates(CGPoint(x: 123, y: 0), in: container)
        #expect(result.x == 123)
    }

    @Test("Page point at bottom of viewport maps to near NSView origin y=0")
    @MainActor func bottomPagePointNearNSViewOrigin() {
        let ctrl = GhostCursorController()
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        // pageY = 600 - 48 = 552 → nsY = 600 - 552 - 48 = 0
        let bottomPoint = ctrl.convertToNSViewCoordinates(CGPoint(x: 0, y: 552), in: container)
        #expect(bottomPoint.y == 0)
    }

    // MARK: - Color Palette

    @Test("Palette returns a non-nil color for every index 0-5")
    func paletteCoversAllIndices() {
        for i in 0..<6 {
            let color = GhostCursorController.paletteColor(at: i)
            // NSColor is not nil by construction; verify it's not a zero-alpha clear color.
            #expect(color != .clear)
        }
    }

    @Test("Palette wraps around for out-of-range indices")
    func paletteWrapsAround() {
        let color0 = GhostCursorController.paletteColor(at: 0)
        let color6 = GhostCursorController.paletteColor(at: 6)
        // Index 6 should produce the same color as index 0 (6 % 6 == 0)
        #expect(color0 == color6)
    }

    @Test("Negative indices are handled gracefully via abs()")
    func paletteNegativeIndex() {
        // Should not crash and should return a valid color
        let color = GhostCursorController.paletteColor(at: -1)
        #expect(color != .clear)
    }

    // MARK: - Cursor Action Classification

    @Test("click/fill/select/hover are cursor actions")
    func cursorActionClassification() {
        #expect(BrowserAutomationService.isCursorAction("click")  == true)
        #expect(BrowserAutomationService.isCursorAction("fill")   == true)
        #expect(BrowserAutomationService.isCursorAction("select") == true)
        #expect(BrowserAutomationService.isCursorAction("hover")  == true)
    }

    @Test("press/wait/inspect are NOT cursor actions")
    func nonCursorActionClassification() {
        #expect(BrowserAutomationService.isCursorAction("press")   == false)
        #expect(BrowserAutomationService.isCursorAction("wait")    == false)
        #expect(BrowserAutomationService.isCursorAction("inspect") == false)
        #expect(BrowserAutomationService.isCursorAction("")        == false)
    }

    // MARK: - Protocol: page.cursor.position

    @Test("page.cursor.position returns ok for valid tab id")
    @MainActor func cursorPositionMethod() async {
        let tm = TabManager()
        let tab = tm.createTab()
        let svc = BrowserAutomationService(tabManager: tm, takeoverHandler: TakeoverHandler())

        // Attach a mock delegate to capture the call
        let delegate = MockGhostCursorDelegate()
        svc.ghostCursorDelegate = delegate

        let req = AgentRequest(method: "page.cursor.position", params: [
            "id":      AnyCodable(tab.id.uuidString as Any),
            "x":       AnyCodable(Double(120) as Any),
            "y":       AnyCodable(Double(340) as Any),
            "agentId": AnyCodable("agent-1" as Any),
        ])
        let resp = await svc.dispatch(req)
        #expect(resp.ok == true)

        // Delegate should have received the point
        #expect(delegate.lastPoint?.x == 120.0)
        #expect(delegate.lastPoint?.y == 340.0)
        #expect(delegate.lastAgentID == "agent-1")
    }

    @Test("page.cursor.position requires id parameter")
    @MainActor func cursorPositionMissingId() async {
        let tm = TabManager()
        let svc = BrowserAutomationService(tabManager: tm, takeoverHandler: TakeoverHandler())
        let req = AgentRequest(method: "page.cursor.position", params: [
            "x": AnyCodable(10.0),
            "y": AnyCodable(20.0),
        ])
        let resp = await svc.dispatch(req)
        #expect(resp.ok == false)
        #expect(resp.error?.code == ErrorCode.invalidParams)
    }

    // MARK: - Lifecycle: showCursor / hideCursor

    @Test("showCursor adds a cursor view to the container")
    @MainActor func showCursorAddsView() {
        let ctrl = GhostCursorController()
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        ctrl.attach(to: container)

        ctrl.showCursor(at: CGPoint(x: 100, y: 200),
                        agentID: "agent-A",
                        agentColor: .systemBlue,
                        agentName: "Agent A")

        #expect(container.subviews.count == 1)
        #expect(container.subviews.first is GhostCursorView)
    }

    @Test("showCursor for same agentID reuses the existing view")
    @MainActor func showCursorReusesView() {
        let ctrl = GhostCursorController()
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        ctrl.attach(to: container)

        ctrl.showCursor(at: CGPoint(x: 100, y: 100),
                        agentID: "agent-A", agentColor: .systemBlue, agentName: "A")
        ctrl.showCursor(at: CGPoint(x: 200, y: 200),
                        agentID: "agent-A", agentColor: .systemBlue, agentName: "A")

        // Still only one view — reused the existing one
        #expect(container.subviews.count == 1)
    }

    @Test("showCursor for different agentIDs creates multiple views")
    @MainActor func showCursorMultipleAgents() {
        let ctrl = GhostCursorController()
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        ctrl.attach(to: container)

        ctrl.showCursor(at: CGPoint(x: 100, y: 100),
                        agentID: "agent-A", agentColor: .systemBlue, agentName: "A")
        ctrl.showCursor(at: CGPoint(x: 200, y: 200),
                        agentID: "agent-B", agentColor: .systemPurple, agentName: "B")

        #expect(container.subviews.count == 2)
    }

    @Test("hideCursor removes the cursor view from the container (after fade completes)")
    @MainActor func hideCursorRemovesView() async throws {
        let ctrl = GhostCursorController()
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        ctrl.attach(to: container)

        ctrl.showCursor(at: CGPoint(x: 100, y: 100),
                        agentID: "agent-A", agentColor: .systemBlue, agentName: "A")
        #expect(container.subviews.count == 1)

        ctrl.hideCursor(agentID: "agent-A")

        // The fade animation takes ~0.3s; after completion the view is removed.
        // In test environments NSAnimationContext may not animate but the
        // completion handler still fires eventually on the main run loop.
        // Poll up to 2s in 100ms increments to avoid brittle sleep timing.
        var elapsed = 0
        while !container.subviews.isEmpty && elapsed < 20 {
            try await Task.sleep(nanoseconds: 100_000_000)
            elapsed += 1
        }
        #expect(container.subviews.isEmpty)
    }

    @Test("removeAll clears all agent cursors")
    @MainActor func removeAllClearsAllCursors() async throws {
        let ctrl = GhostCursorController()
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        ctrl.attach(to: container)

        ctrl.showCursor(at: .zero, agentID: "a1", agentColor: .systemBlue, agentName: "A1")
        ctrl.showCursor(at: .zero, agentID: "a2", agentColor: .systemPurple, agentName: "A2")
        #expect(container.subviews.count == 2)

        ctrl.removeAll()
        // Poll up to 2s for animation completion.
        var elapsed = 0
        while !container.subviews.isEmpty && elapsed < 20 {
            try await Task.sleep(nanoseconds: 100_000_000)
            elapsed += 1
        }
        #expect(container.subviews.isEmpty)
    }
}

// MARK: - Mock Ghost Cursor Delegate

/// Captures ghost cursor events for test assertions.
@MainActor
private final class MockGhostCursorDelegate: GhostCursorDelegate {
    var lastPoint: CGPoint?
    var lastAgentID: String?

    func agentDidInteract(at point: CGPoint, agentID: String) {
        lastPoint = point
        lastAgentID = agentID
    }
}
