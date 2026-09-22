// AppDelegate+MainMenu.swift
// Extracted from AppDelegate.swift to keep both files under the 350-LOC cap.

import AppKit

extension AppDelegate {

    func setupMainMenu() {
        let mainMenu = NSMenu()
        mainMenu.addItem(makeAppMenuItem())
        mainMenu.addItem(makeFileMenuItem())
        mainMenu.addItem(makeEditMenuItem())
        mainMenu.addItem(makeViewMenuItem())
        mainMenu.addItem(makeNavigateMenuItem())
        mainMenu.addItem(makeProfilesMenuItem())
        mainMenu.addItem(makeWindowMenuItem())
        NSApp.mainMenu = mainMenu
    }

    // MARK: - App Menu

    private func makeAppMenuItem() -> NSMenuItem {
        let menu = NSMenu()
        menu.addItem(NSMenuItem(
            title: "About Agent Browser",
            action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
            keyEquivalent: ""
        ))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(
            title: "Quit Agent Browser",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        ))
        let item = NSMenuItem()
        item.submenu = menu
        return item
    }

    // MARK: - File Menu

    private func makeFileMenuItem() -> NSMenuItem {
        let menu = NSMenu(title: "File")
        menu.addItem(withTitle: "New Window",
                     action: #selector(BrowserWindowController.newWindow(_:)),
                     keyEquivalent: "n")
        menu.addItem(.separator())
        menu.addItem(withTitle: "New Tab",
                     action: #selector(BrowserWindowController.newTab(_:)),
                     keyEquivalent: "t")
        menu.addItem(withTitle: "Close Tab",
                     action: #selector(BrowserWindowController.closeCurrentTab(_:)),
                     keyEquivalent: "w")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Reopen Closed Tab",
                     action: #selector(BrowserWindowController.reopenClosedTab(_:)),
                     keyEquivalent: "T")
        let item = NSMenuItem()
        item.submenu = menu
        return item
    }

    // MARK: - Edit Menu

    private func makeEditMenuItem() -> NSMenuItem {
        let menu = NSMenu(title: "Edit")
        menu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        menu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        menu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        menu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(
            title: "Find...",
            action: #selector(BrowserWindowController.performFind(_:)),
            keyEquivalent: "f"
        ))
        let searchAllTabs = NSMenuItem(
            title: "Search All Tabs",
            action: #selector(BrowserWindowController.showContentSearch(_:)),
            keyEquivalent: "f"
        )
        searchAllTabs.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(searchAllTabs)
        let item = NSMenuItem()
        item.submenu = menu
        return item
    }

    // MARK: - View Menu

    private func makeViewMenuItem() -> NSMenuItem {
        let menu = NSMenu(title: "View")
        menu.addItem(withTitle: "Reload",
                     action: #selector(BrowserWindowController.reloadPage(_:)),
                     keyEquivalent: "r")
        let hardReload = NSMenuItem(
            title: "Hard Reload",
            action: #selector(BrowserWindowController.hardReloadPage(_:)),
            keyEquivalent: "R"
        )
        hardReload.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(hardReload)
        menu.addItem(.separator())
        let toggleSidebar = NSMenuItem(
            title: "Toggle Sidebar",
            action: #selector(BrowserWindowController.toggleSidebar(_:)),
            keyEquivalent: "L"
        )
        toggleSidebar.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(toggleSidebar)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Zoom In",
                                action: #selector(BrowserWindowController.zoomIn(_:)),
                                keyEquivalent: "+"))
        menu.addItem(NSMenuItem(title: "Zoom Out",
                                action: #selector(BrowserWindowController.zoomOut(_:)),
                                keyEquivalent: "-"))
        menu.addItem(NSMenuItem(title: "Actual Size",
                                action: #selector(BrowserWindowController.resetZoom(_:)),
                                keyEquivalent: "0"))
        let item = NSMenuItem()
        item.submenu = menu
        return item
    }

    // MARK: - Navigate Menu

    private func makeNavigateMenuItem() -> NSMenuItem {
        let menu = NSMenu(title: "Navigate")
        menu.addItem(NSMenuItem(title: "Back",
                                action: #selector(BrowserWindowController.goBack(_:)),
                                keyEquivalent: "["))
        menu.addItem(NSMenuItem(title: "Forward",
                                action: #selector(BrowserWindowController.goForward(_:)),
                                keyEquivalent: "]"))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Open Location...",
                                action: #selector(BrowserWindowController.focusAddressBar(_:)),
                                keyEquivalent: "l"))
        let item = NSMenuItem()
        item.submenu = menu
        return item
    }

    // MARK: - Profiles Menu

    private func makeProfilesMenuItem() -> NSMenuItem {
        let menu = NSMenu(title: "Profiles")
        let next = NSMenuItem(title: "Next Profile",
                              action: #selector(BrowserWindowController.switchToNextProfile(_:)),
                              keyEquivalent: "]")
        next.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(next)
        let prev = NSMenuItem(title: "Previous Profile",
                              action: #selector(BrowserWindowController.switchToPreviousProfile(_:)),
                              keyEquivalent: "[")
        prev.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(prev)
        menu.addItem(.separator())
        let newProfile = NSMenuItem(title: "New Profile...",
                                    action: #selector(BrowserWindowController.createNewProfile(_:)),
                                    keyEquivalent: "N")
        newProfile.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(newProfile)
        let item = NSMenuItem()
        item.submenu = menu
        return item
    }

    // MARK: - Window Menu

    private func makeWindowMenuItem() -> NSMenuItem {
        let menu = NSMenu(title: "Window")
        menu.addItem(withTitle: "Minimize",
                     action: #selector(NSWindow.performMiniaturize(_:)),
                     keyEquivalent: "m")
        menu.addItem(withTitle: "Zoom",
                     action: #selector(NSWindow.performZoom(_:)),
                     keyEquivalent: "")
        menu.addItem(.separator())
        for i in 1...9 {
            let tab = NSMenuItem(title: "Tab \(i)",
                                 action: #selector(BrowserWindowController.switchToTabByNumber(_:)),
                                 keyEquivalent: "\(i)")
            tab.tag = i
            menu.addItem(tab)
        }
        menu.addItem(.separator())
        let nextTab = NSMenuItem(title: "Show Next Tab",
                                 action: #selector(BrowserWindowController.selectNextTab(_:)),
                                 keyEquivalent: "\t")
        nextTab.keyEquivalentModifierMask = [.control]
        menu.addItem(nextTab)
        let prevTab = NSMenuItem(title: "Show Previous Tab",
                                 action: #selector(BrowserWindowController.selectPreviousTab(_:)),
                                 keyEquivalent: "\t")
        prevTab.keyEquivalentModifierMask = [.control, .shift]
        menu.addItem(prevTab)
        let item = NSMenuItem()
        item.submenu = menu
        NSApp.windowsMenu = menu
        return item
    }
}
