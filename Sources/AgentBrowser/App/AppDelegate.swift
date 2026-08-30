import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var windowController: BrowserWindowController?
    private var agentServer: AgentHTTPServer?

    // Shared state: ProfileManager and TabManager for the whole app.
    // Initialized in applicationDidFinishLaunching (already on main thread).
    private var profileManager: ProfileManager?
    private var tabManager: TabManager?

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMainMenu()

        let pm = ProfileManager()
        self.profileManager = pm

        let tm = TabManager(profileManager: pm)
        self.tabManager = tm

        // Create the browser window
        windowController = BrowserWindowController(tabManager: tm, profileManager: pm)
        windowController?.showWindow(nil)

        // Start the agent automation server
        let automationService = BrowserAutomationService(tabManager: tm)
        agentServer = AgentHTTPServer(automationService: automationService)
        agentServer?.start()

        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationWillTerminate(_ notification: Notification) {
        agentServer?.stop()
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
