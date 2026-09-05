import AppKit

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

    // Persistence coordinator: sessions, history, auto-save.
    private let persistenceCoordinator = PersistenceCoordinator()

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMainMenu()

        let pm = ProfileManager()
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
            await persistenceCoordinator.setUp()

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

    // MARK: - Main Menu

    private func setupMainMenu() {
        let mainMenu = NSMenu()

        // App menu
        let appMenu = NSMenu()
        appMenu.addItem(NSMenuItem(title: "About Agent Browser", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: ""))
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(title: "Quit Agent Browser", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        let appMenuItem = NSMenuItem()
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        // File menu
        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(withTitle: "New Tab", action: #selector(BrowserWindowController.newTab(_:)), keyEquivalent: "t")
        fileMenu.addItem(withTitle: "Close Tab", action: #selector(BrowserWindowController.closeCurrentTab(_:)), keyEquivalent: "w")
        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: "Reopen Closed Tab", action: #selector(BrowserWindowController.reopenClosedTab(_:)), keyEquivalent: "T")
        let fileMenuItem = NSMenuItem()
        fileMenuItem.submenu = fileMenu
        mainMenu.addItem(fileMenuItem)

        // Edit menu
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenu.addItem(.separator())
        editMenu.addItem(NSMenuItem(title: "Find...", action: #selector(BrowserWindowController.performFind(_:)), keyEquivalent: "f"))
        let editMenuItem = NSMenuItem()
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        // View menu
        let viewMenu = NSMenu(title: "View")
        viewMenu.addItem(withTitle: "Reload", action: #selector(BrowserWindowController.reloadPage(_:)), keyEquivalent: "r")
        let hardReloadItem = NSMenuItem(title: "Hard Reload", action: #selector(BrowserWindowController.hardReloadPage(_:)), keyEquivalent: "R")
        hardReloadItem.keyEquivalentModifierMask = [.command, .shift]
        viewMenu.addItem(hardReloadItem)
        viewMenu.addItem(.separator())
        let toggleSidebarItem = NSMenuItem(
            title: "Toggle Sidebar",
            action: #selector(BrowserWindowController.toggleSidebar(_:)),
            keyEquivalent: "L"
        )
        toggleSidebarItem.keyEquivalentModifierMask = [.command, .shift]
        viewMenu.addItem(toggleSidebarItem)
        viewMenu.addItem(.separator())
        viewMenu.addItem(NSMenuItem(title: "Zoom In", action: #selector(BrowserWindowController.zoomIn(_:)), keyEquivalent: "+"))
        viewMenu.addItem(NSMenuItem(title: "Zoom Out", action: #selector(BrowserWindowController.zoomOut(_:)), keyEquivalent: "-"))
        viewMenu.addItem(NSMenuItem(title: "Actual Size", action: #selector(BrowserWindowController.resetZoom(_:)), keyEquivalent: "0"))
        let viewMenuItem = NSMenuItem()
        viewMenuItem.submenu = viewMenu
        mainMenu.addItem(viewMenuItem)

        // Navigate menu
        let navMenu = NSMenu(title: "Navigate")
        navMenu.addItem(NSMenuItem(title: "Back", action: #selector(BrowserWindowController.goBack(_:)), keyEquivalent: "["))
        navMenu.addItem(NSMenuItem(title: "Forward", action: #selector(BrowserWindowController.goForward(_:)), keyEquivalent: "]"))
        navMenu.addItem(.separator())
        navMenu.addItem(NSMenuItem(title: "Open Location...", action: #selector(BrowserWindowController.focusAddressBar(_:)), keyEquivalent: "l"))
        let navMenuItem = NSMenuItem()
        navMenuItem.submenu = navMenu
        mainMenu.addItem(navMenuItem)

        // Profiles menu
        let profilesMenu = NSMenu(title: "Profiles")
        let nextProfileItem = NSMenuItem(
            title: "Next Profile",
            action: #selector(BrowserWindowController.switchToNextProfile(_:)),
            keyEquivalent: "]"
        )
        nextProfileItem.keyEquivalentModifierMask = [.command, .shift]
        profilesMenu.addItem(nextProfileItem)
        let prevProfileItem = NSMenuItem(
            title: "Previous Profile",
            action: #selector(BrowserWindowController.switchToPreviousProfile(_:)),
            keyEquivalent: "["
        )
        prevProfileItem.keyEquivalentModifierMask = [.command, .shift]
        profilesMenu.addItem(prevProfileItem)
        profilesMenu.addItem(.separator())
        let newProfileItem = NSMenuItem(
            title: "New Profile...",
            action: #selector(BrowserWindowController.createNewProfile(_:)),
            keyEquivalent: "N"
        )
        newProfileItem.keyEquivalentModifierMask = [.command, .shift]
        profilesMenu.addItem(newProfileItem)
        let profilesMenuItem = NSMenuItem()
        profilesMenuItem.submenu = profilesMenu
        mainMenu.addItem(profilesMenuItem)

        // Window menu
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowMenu.addItem(.separator())
        for i in 1...9 {
            let item = NSMenuItem(title: "Tab \(i)", action: #selector(BrowserWindowController.switchToTabByNumber(_:)), keyEquivalent: "\(i)")
            item.tag = i
            windowMenu.addItem(item)
        }
        windowMenu.addItem(.separator())
        let nextTabItem = NSMenuItem(title: "Show Next Tab", action: #selector(BrowserWindowController.selectNextTab(_:)), keyEquivalent: "\t")
        nextTabItem.keyEquivalentModifierMask = [.control]
        windowMenu.addItem(nextTabItem)
        let prevTabItem = NSMenuItem(title: "Show Previous Tab", action: #selector(BrowserWindowController.selectPreviousTab(_:)), keyEquivalent: "\t")
        prevTabItem.keyEquivalentModifierMask = [.control, .shift]
        windowMenu.addItem(prevTabItem)
        let windowMenuItem = NSMenuItem()
        windowMenuItem.submenu = windowMenu
        mainMenu.addItem(windowMenuItem)
        NSApp.windowsMenu = windowMenu

        NSApp.mainMenu = mainMenu
    }
}
