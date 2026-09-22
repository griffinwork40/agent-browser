import AppKit
import Observation

/// Central coordinator for all open browser windows.
///
/// Tracks every `BrowserWindowController` instance, provides factory methods
/// for creating and closing windows, and exposes the currently active window.
/// All windows share the same `ProfileManager` so cookies/storage stay
/// consistent across the session.
///
/// Thread-safety: all mutation happens on `@MainActor`.
@Observable @MainActor
final class WindowSessionManager {

    // MARK: - State

    /// All currently open window controllers, in creation order.
    private(set) var windowControllers: [BrowserWindowController] = []

    /// The window controller whose NSWindow is currently key (frontmost).
    private(set) var activeWindowController: BrowserWindowController?

    // MARK: - Dependencies (shared across all windows)

    private let profileManager: ProfileManager
    private let persistenceCoordinator: PersistenceCoordinator

    // MARK: - Init

    init(profileManager: ProfileManager, persistenceCoordinator: PersistenceCoordinator) {
        self.profileManager = profileManager
        self.persistenceCoordinator = persistenceCoordinator
    }

    // MARK: - Window Lifecycle

    /// Create a new browser window with its own `TabManager`.
    ///
    /// The returned controller is already registered and shown. Callers may
    /// populate it (e.g. restore tabs) before or after calling this method.
    ///
    /// - Parameter skipInitialTab: When `true` the window opens without a blank
    ///   tab so the caller can restore saved tabs instead.
    /// - Returns: The newly created and shown `BrowserWindowController`.
    @discardableResult
    func createWindow(skipInitialTab: Bool = false) -> BrowserWindowController {
        let tm = TabManager(profileManager: profileManager)
        let wc = BrowserWindowController(
            tabManager: tm,
            profileManager: profileManager,
            skipInitialTab: skipInitialTab
        )
        wc.windowSessionManager = self

        // Give each subsequent window a unique autosave name so AppKit doesn't
        // clobber the first window's saved frame.
        if !windowControllers.isEmpty {
            wc.window?.setFrameAutosaveName("BrowserWindow-\(UUID().uuidString)")
        }

        windowControllers.append(wc)
        wc.showWindow(nil)
        activeWindowController = wc
        return wc
    }

    /// Called by `BrowserWindowController` when its window is about to close.
    ///
    /// Removes the controller from the registry and updates `activeWindowController`.
    func closeWindow(_ controller: BrowserWindowController) {
        windowControllers.removeAll { $0 === controller }
        if activeWindowController === controller {
            activeWindowController = windowControllers.last
        }
    }

    /// Called by `BrowserWindowController` when its window becomes key.
    func windowDidBecomeKey(_ controller: BrowserWindowController) {
        activeWindowController = controller
    }

    // MARK: - Session Snapshot

    /// Snapshot every window's workspaces for quit-time or auto-save persistence.
    ///
    /// Returns a `[windowIndex: [UUID: ProfileWorkspace]]` keyed by stable window
    /// order so the session can be restored across launches.
    func snapshotAllWindows() -> [[UUID: ProfileWorkspace]] {
        windowControllers.map { wc in
            wc.snapshotAllWorkspaces(
                tabManager: wc.tabManager,
                profileManager: wc.profileManager
            )
        }
    }
}
