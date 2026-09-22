import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var windowController: BrowserWindowController?
    private var agentServer: AgentHTTPServer?

    /// Guards against duplicate in-flight quit-save Tasks when Cocoa calls
    /// applicationShouldTerminate more than once (e.g. repeated Cmd-Q presses
    /// while the async save is pending).
    @MainActor private var quitSaveInFlight = false

    // Shared state: ProfileManager and TabManager for the whole app.
    // Initialized in applicationDidFinishLaunching (already on main thread).
    private var profileManager: ProfileManager?
    private var tabManager: TabManager?

    // Extension manager: web extension loading / lifecycle.
    // `internal` so AppDelegate+Extensions.swift can access it.
    var extensionManager: ExtensionManager?

    /// Content blocker: created before TabManager so ProfileManager can use it.
    private var contentBlockerManager: ContentBlockerManager?

    // Persistence coordinator: sessions, history, auto-save.
    private let persistenceCoordinator = PersistenceCoordinator()

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMainMenu()

        let em = ExtensionManager()
        self.extensionManager = em

        let cbm = ContentBlockerManager()
        self.contentBlockerManager = cbm

        let pm = ProfileManager()
        pm.extensionManager = em
        pm.contentBlockerManager = cbm
        self.profileManager = pm

        let tm = TabManager(profileManager: pm)
        self.tabManager = tm

        // Create the browser window (without an initial tab — restore decides).
        windowController = BrowserWindowController(
            tabManager: tm,
            profileManager: pm,
            skipInitialTab: true
        )
        windowController?.showWindow(nil)

        // Start the agent automation server
        let automationService = BrowserAutomationService(
            tabManager: tm,
            takeoverHandler: TakeoverHandler()
        )
        agentServer = AgentHTTPServer(automationService: automationService)
        agentServer?.start()

        NSApp.activate(ignoringOtherApps: true)

        // Bootstrap persistence stores and restore the previous session.
        // Runs async to avoid blocking the main thread during disk I/O,
        // but stays on MainActor so TabManager mutations are safe.
        Task { @MainActor in
            // Start content blocker setup (downloads filter lists if stale).
            await cbm.setUp()

            await persistenceCoordinator.setUp(defaultProfileID: pm.activeProfileID)

            // P4: Restore per-profile workspaces (v2 path; migrates legacy flat tabs).
            let savedWorkspaces = await persistenceCoordinator.restoreWorkspaces(
                activeProfileID: pm.activeProfileID
            )

            if !savedWorkspaces.isEmpty {
                // Wire registry into window controller before restoring tabs.
                windowController?.loadWorkspaceRegistry(savedWorkspaces)

                // Recreate tabs for every known profile (active first for focus).
                let allProfileIDs = [pm.activeProfileID] +
                    pm.profiles.map(\.id).filter { $0 != pm.activeProfileID }
                for profileID in allProfileIDs {
                    guard let ws = savedWorkspaces[profileID], !ws.isEmpty else { continue }
                    for entry in ws.tabs {
                        tm.createTab(
                            url: entry.url,
                            provenance: .restored(originalAgentID: nil, originalSessionTag: nil),
                            profileID: entry.profileID,
                            id: entry.id
                        )
                    }
                }
                // Select the active profile's previously-chosen tab.
                if let activeWs = savedWorkspaces[pm.activeProfileID],
                   let selID = activeWs.selectedTabID,
                   let tab = tm.tab(for: selID) {
                    tm.select(tab: tab)
                } else if let first = tm.tabs.first(where: { $0.record.profileID == pm.activeProfileID }) {
                    tm.select(tab: first)
                } else if let any = tm.tabs.first {
                    tm.select(tab: any)
                }
            } else {
                // No saved session — open a single blank tab for the active profile.
                let firstTab = tm.createTab(profileID: pm.activeProfileID)
                tm.select(tab: firstTab)
            }

            // Wire coordinator back-reference so switch/persist paths work.
            windowController?.persistenceCoordinator = persistenceCoordinator

            // Wire history recording into the window controller.
            if let historyStore = persistenceCoordinator.makeHistoryStore() {
                windowController?.attachHistoryStore(historyStore)
            }

            windowController?.syncDisplayedTab()
            windowController?.updateSidebar()

            // Start debounced auto-save (every 30 s) using workspace-aware path.
            persistenceCoordinator.startAutoSave(
                tabManager: tm,
                profileManager: pm,
                windowController: windowController
            )
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    // MARK: - Quit-time persistence
    //
    // Ordering invariants:
    //   1. stopAutoSave() fires BEFORE the persistence await so an in-flight
    //      auto-save Task cannot race against the quit save and overwrite it
    //      with a stale snapshot.
    //   2. agentServer.stop() is deferred until AFTER a successful save so the
    //      server stays usable while the async save window is open. On a save
    //      failure we show an alert and cancel termination — the server must
    //      remain running so the user can retry. On success we stop it just
    //      before telling Cocoa to proceed.
    //   3. A small `quitSaveInFlight` flag prevents duplicate saves when Cocoa
    //      re-invokes applicationShouldTerminate (e.g. repeated Cmd-Q while the
    //      async window is open). If already in-flight, we defer again rather
    //      than double-save.
    //
    // We use applicationShouldTerminate(_:) + terminateLater /
    // replyToApplicationShouldTerminate to obtain an async window inside what
    // is otherwise a synchronous Cocoa gate.
    // applicationWillTerminate(_:) is NOT used for saves — it fires too late
    // (after the reply) and offers no way to await async work safely.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Guard: if a quit-save is already in-flight (repeated Cmd-Q), just
        // extend the wait — do NOT start a second concurrent save.
        if quitSaveInFlight { return .terminateLater }
        quitSaveInFlight = true

        // Capture state synchronously on the main actor before the Task hop.
        let wc = windowController
        let pm = profileManager
        let tm = tabManager

        Task { @MainActor [weak self] in
            guard let self else {
                NSApp.reply(toApplicationShouldTerminate: true)
                return
            }

            // Step 1: stop auto-save FIRST (prevents race with quit save).
            persistenceCoordinator.stopAutoSave()

            // Step 2: save all workspaces and await completion.
            var saved = true
            if let wc, let pm {
                let registry = wc.snapshotAllWorkspaces(tabManager: tm, profileManager: pm)
                saved = await persistenceCoordinator.saveAllWorkspacesAndWait(
                    registry,
                    activeProfileID: pm.activeProfileID
                )
            }

            if saved {
                // Step 3 (success): stop agent server, then let Cocoa terminate.
                agentServer?.stop()
                quitSaveInFlight = false
                NSApp.reply(toApplicationShouldTerminate: true)
            } else {
                // Step 3 (failure): alert user, resume auto-save, cancel quit.
                quitSaveInFlight = false
                // Resume auto-save so background snapshots continue — the user
                // has not quit, and we need the coordinator running.
                if let wc, let pm, let tm {
                    persistenceCoordinator.startAutoSave(
                        tabManager: tm,
                        profileManager: pm,
                        windowController: wc
                    )
                }
                // Surface the failure clearly before cancelling.
                let alert = NSAlert()
                alert.alertStyle = .critical
                alert.messageText = "Save Failed — Quit Cancelled"
                alert.informativeText =
                    "Agent Browser could not write your workspace to disk. " +
                    "Your session data has not been saved. " +
                    "Please free disk space or check permissions, then quit again."
                alert.addButton(withTitle: "OK")
                alert.runModal()
                NSApp.reply(toApplicationShouldTerminate: false)
            }
        }

        // Defer termination until the async save completes.
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Intentionally empty: all quit persistence is handled in
        // applicationShouldTerminate(_:) above to allow async awaiting.
    }

    // MARK: - Content Blocking

    @objc @MainActor private func toggleContentBlocking(_ sender: NSMenuItem) {
        contentBlockerManager?.toggleEnabled()
        sender.state = (contentBlockerManager?.isEnabled ?? false) ? .on : .off
    }

    // MARK: - Extensions Panel (see AppDelegate+Extensions.swift)

    /// Keeps the extensions panel window alive while it's open.
    /// `internal` so the AppDelegate+Extensions extension file can set it.
    var extensionsPanelWindow: NSWindow?


    // MARK: - Main Menu (implementation in AppDelegate+MainMenu.swift)
    func setupMainMenu() { _buildMainMenu() }
}
