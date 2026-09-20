import AppKit
import Foundation

// MARK: - ScriptingSupport
//
// Bridges the AppleScript runtime to AgentBrowser's model layer.
//
// Responsibilities:
// 1. NSWindow + BrowserWindowController extensions that expose `scriptingTabs`
//    and `scriptingActiveTab` as KVC-compliant properties the scripting engine
//    uses to resolve element specifiers like "tab 1 of window 1".
// 2. Custom NSScriptCommand subclasses for top-level commands:
//    • OpenLocationCommand  ("open location <URL>")
//    • ReloadTabCommand     ("reload [tab]")
//    • GoBackCommand        ("go back [tab]")
//    • GoForwardCommand     ("go forward [tab]")
// 3. NSApplication extension to handle "open location" routed through the
//    application object.
//
// Threading: all scripting callbacks arrive on the main thread; @MainActor
// isolation is preserved throughout.

// MARK: - NSWindow scripting bridge

extension NSWindow {

    /// Returns the BrowserWindowController that owns this window, if any.
    @MainActor
    var browserWindowController: BrowserWindowController? {
        windowController as? BrowserWindowController
    }

    /// KVC key `scriptingTabs`: the ordered list of ScriptableTab objects.
    /// The scripting engine calls this to resolve "tabs of window N".
    @objc @MainActor
    var scriptingTabs: [ScriptableTab] {
        guard let wc = browserWindowController else { return [] }
        return wc.tabManager.tabs.map { tab in
            ScriptableTab(tab: tab, parentWindow: self)
        }
    }

    /// KVC key `scriptingActiveTab`: the currently selected tab, or nil.
    @objc @MainActor
    var scriptingActiveTab: ScriptableTab? {
        guard let wc = browserWindowController,
              let active = wc.tabManager.activeTab else { return nil }
        return ScriptableTab(tab: active, parentWindow: self)
    }

    /// Setter for `scriptingActiveTab` — activates the tab at the matching index.
    @objc @MainActor
    func setScriptingActiveTab(_ scriptable: ScriptableTab) {
        guard let wc = browserWindowController else { return }
        wc.tabManager.select(tab: scriptable.tab)
        wc.syncDisplayedTab()
        wc.updateSidebar()
    }

    // MARK: - NSCreateCommand support (make new tab)

    /// Called by `make new tab [with properties {...}]`.
    /// Returns the newly created ScriptableTab.
    @objc @MainActor
    func newScriptingTab() -> ScriptableTab? {
        guard let wc = browserWindowController else { return nil }
        let tab = wc.tabManager.createTab()
        wc.tabManager.select(tab: tab)
        wc.syncDisplayedTab()
        wc.updateSidebar()
        return ScriptableTab(tab: tab, parentWindow: self)
    }
}

// MARK: - NSApplication: open location handler

extension NSApplication {

    /// Handles `open location <URL-string>` sent to the application object.
    @objc @MainActor
    func handleOpenLocationCommand(_ command: NSScriptCommand) {
        guard let urlString = command.directParameter as? String,
              let url = URL(string: urlString) else {
            command.scriptErrorNumber = errOSACantAssign
            command.scriptErrorString = "'open location' requires a valid URL string."
            return
        }
        openInNewTab(url)
    }

    /// Opens a URL in a new tab in the front BrowserWindowController.
    @MainActor
    func openInNewTab(_ url: URL) {
        for window in orderedWindows {
            if let wc = window.windowController as? BrowserWindowController {
                let tab = wc.tabManager.createTab(url: url)
                wc.tabManager.select(tab: tab)
                wc.syncDisplayedTab()
                wc.updateSidebar()
                window.makeKeyAndOrderFront(nil)
                return
            }
        }
    }
}

// MARK: - OpenLocationCommand

/// Top-level `open location <URL>` command.
/// Delegates to NSApplication.openInNewTab(_:).
final class OpenLocationCommand: NSScriptCommand {

    @MainActor
    override func performDefaultImplementation() -> Any? {
        guard let urlString = directParameter as? String,
              let url = URL(string: urlString) else {
            scriptErrorNumber = errOSACantAssign
            scriptErrorString = "'open location' requires a valid URL string."
            return nil
        }
        NSApplication.shared.openInNewTab(url)
        return nil
    }
}

// MARK: - ReloadTabCommand

/// `reload [tab]` — reloads the direct-parameter tab, or the active tab.
final class ReloadTabCommand: NSScriptCommand {

    @MainActor
    override func performDefaultImplementation() -> Any? {
        if let scriptable = directParameter as? ScriptableTab {
            scriptable.tab.reload()
            return nil
        }
        // No specifier — reload active tab of front window.
        for window in NSApplication.shared.orderedWindows {
            if let wc = window.windowController as? BrowserWindowController {
                wc.tabManager.activeTab?.reload()
                return nil
            }
        }
        return nil
    }
}

// MARK: - GoBackCommand

/// `go back [tab]` — navigates the specified tab (or active tab) back.
final class GoBackCommand: NSScriptCommand {

    @MainActor
    override func performDefaultImplementation() -> Any? {
        if let scriptable = directParameter as? ScriptableTab {
            scriptable.tab.goBack()
            return nil
        }
        for window in NSApplication.shared.orderedWindows {
            if let wc = window.windowController as? BrowserWindowController {
                wc.tabManager.activeTab?.goBack()
                return nil
            }
        }
        return nil
    }
}

// MARK: - GoForwardCommand

/// `go forward [tab]` — navigates the specified tab (or active tab) forward.
final class GoForwardCommand: NSScriptCommand {

    @MainActor
    override func performDefaultImplementation() -> Any? {
        if let scriptable = directParameter as? ScriptableTab {
            scriptable.tab.goForward()
            return nil
        }
        for window in NSApplication.shared.orderedWindows {
            if let wc = window.windowController as? BrowserWindowController {
                wc.tabManager.activeTab?.goForward()
                return nil
            }
        }
        return nil
    }
}
