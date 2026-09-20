import AppKit
import Foundation

// MARK: - ScriptableTab
//
// NSObject wrapper around BrowserTab that exposes the tab's properties and
// navigation commands to the AppleScript runtime.
//
// Design notes:
// • @Observable BrowserTab is a @MainActor type; we must access it on the main
//   actor. ScriptableTab is itself an NSObject created on the main actor and
//   accessed by the scripting engine on the main thread, so this is safe.
// • Scripting key-value coding drives property access via Cocoa KVC. Every
//   scripting property declared in the sdef must have a matching Objective-C
//   accessible property here (or a valueForKey: override).
// • NSObject.objectSpecifier (computed var) is required so AppleScript can form
//   specifiers such as "tab 1 of window 1" and "tab whose name is 'GitHub'".

@MainActor
final class ScriptableTab: NSObject {

    // The underlying model object.
    let tab: BrowserTab

    // The parent window — needed to build specifiers.
    weak var parentWindow: NSWindow?

    init(tab: BrowserTab, parentWindow: NSWindow?) {
        self.tab = tab
        self.parentWindow = parentWindow
    }

    // MARK: - Scripting Properties

    /// Stable UUID string. Exposed as `id` in the sdef.
    @objc var scriptingID: String {
        tab.id.uuidString
    }

    /// Page title. Exposed as `name` in the sdef.
    @objc var scriptingTitle: String {
        tab.title
    }

    /// Current URL string. Exposed as `URL` in the sdef; settable to navigate.
    @objc var scriptingURL: String {
        get { tab.url?.absoluteString ?? "" }
        set {
            guard let url = URL(string: newValue) else { return }
            tab.load(url)
        }
    }

    /// 1-based position in the window's tab list.
    @objc var scriptingIndex: Int {
        guard let win = parentWindow,
              let wc = win.windowController as? BrowserWindowController else {
            return 1
        }
        let index = wc.tabManager.tabs.firstIndex(where: { $0.id == tab.id }) ?? 0
        return index + 1
    }

    /// True while the page is loading.
    @objc var scriptingIsLoading: Bool {
        tab.isLoading
    }

    // MARK: - Scripting Command Handlers

    /// Handles the AppleScript `close` command sent to this tab.
    @objc func handleClose(_ command: NSScriptCommand) {
        guard let win = parentWindow,
              let wc = win.windowController as? BrowserWindowController else { return }
        wc.tabManager.closeTab(tab)
        // If no tabs remain, open a blank one so the window stays usable.
        if wc.tabManager.tabs.isEmpty {
            let newTab = wc.tabManager.createTab()
            wc.tabManager.select(tab: newTab)
        }
        wc.syncDisplayedTab()
        wc.updateSidebar()
    }

    /// Handles the AppleScript `reload` command sent to this tab.
    @objc func handleReload(_ command: NSScriptCommand) {
        tab.reload()
    }

    /// Handles the AppleScript `go back` command sent to this tab.
    @objc func handleGoBack(_ command: NSScriptCommand) {
        tab.goBack()
    }

    /// Handles the AppleScript `go forward` command sent to this tab.
    @objc func handleGoForward(_ command: NSScriptCommand) {
        tab.goForward()
    }

    // MARK: - NSScriptObjectSpecifier

    /// Produces a specifier so AppleScript can refer to this tab as
    /// e.g. "tab 2 of window 1" or "tab id \"…\" of window 1".
    ///
    /// `objectSpecifier` is a computed property on NSObject consulted by the
    /// scripting runtime when it needs a canonical reference to this object.
    /// We return a name (ID-based) specifier relative to our parent window.
    /// The scripting runtime also auto-builds index specifiers for array elements
    /// returned via KVC (scriptingTabs), so this handles explicit back-references.
    override var objectSpecifier: NSScriptObjectSpecifier? {
        guard let win = parentWindow else { return nil }
        let winSpec = win.objectSpecifier
        // Use the window's NSScriptClassDescription as the container.
        guard let winClassDesc = NSScriptClassDescription(for: NSWindow.self) else {
            return nil
        }
        // Build a name specifier keyed on scriptingID within the window's tabs.
        return NSNameSpecifier(
            containerClassDescription: winClassDesc,
            containerSpecifier: winSpec,
            key: "scriptingTabs",
            name: scriptingID
        )
    }
}
