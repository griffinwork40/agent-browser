import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var windowController: BrowserWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMainMenu()
        windowController = BrowserWindowController()
        windowController?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
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

        let findItem = NSMenuItem(title: "Find...", action: #selector(BrowserWindowController.performFind(_:)), keyEquivalent: "f")
        editMenu.addItem(findItem)

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

        let zoomInItem = NSMenuItem(title: "Zoom In", action: #selector(BrowserWindowController.zoomIn(_:)), keyEquivalent: "+")
        viewMenu.addItem(zoomInItem)

        let zoomOutItem = NSMenuItem(title: "Zoom Out", action: #selector(BrowserWindowController.zoomOut(_:)), keyEquivalent: "-")
        viewMenu.addItem(zoomOutItem)

        let resetZoomItem = NSMenuItem(title: "Actual Size", action: #selector(BrowserWindowController.resetZoom(_:)), keyEquivalent: "0")
        viewMenu.addItem(resetZoomItem)

        let viewMenuItem = NSMenuItem()
        viewMenuItem.submenu = viewMenu
        mainMenu.addItem(viewMenuItem)

        // Navigate menu
        let navMenu = NSMenu(title: "Navigate")
        let backItem = NSMenuItem(title: "Back", action: #selector(BrowserWindowController.goBack(_:)), keyEquivalent: "[")
        navMenu.addItem(backItem)

        let forwardItem = NSMenuItem(title: "Forward", action: #selector(BrowserWindowController.goForward(_:)), keyEquivalent: "]")
        navMenu.addItem(forwardItem)

        navMenu.addItem(.separator())

        let focusAddressItem = NSMenuItem(title: "Open Location...", action: #selector(BrowserWindowController.focusAddressBar(_:)), keyEquivalent: "l")
        navMenu.addItem(focusAddressItem)

        let navMenuItem = NSMenuItem()
        navMenuItem.submenu = navMenu
        mainMenu.addItem(navMenuItem)

        // Window menu
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")

        // Tab switching: Cmd+1 through Cmd+9
        windowMenu.addItem(.separator())
        for i in 1...9 {
            let item = NSMenuItem(
                title: "Tab \(i)",
                action: #selector(BrowserWindowController.switchToTabByNumber(_:)),
                keyEquivalent: "\(i)"
            )
            item.tag = i
            windowMenu.addItem(item)
        }

        // Ctrl+Tab / Ctrl+Shift+Tab for next/prev tab
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
