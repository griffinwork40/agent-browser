// BrowserWindowController+Actions.swift
// @objc menu/keyboard target methods: tab lifecycle, navigation, find, zoom.
// Kept in a separate file to stay under the 350 LOC cap on the main controller.

import AppKit

// MARK: - Tab Actions (Menu / Keyboard targets)

extension BrowserWindowController {

    @objc func newTab(_ sender: Any?) {
        let tab = tabManager.createTab()
        tabManager.select(tab: tab)
        syncDisplayedTab()
        updateSidebar()

        if sender != nil {
            addressBar.focus()
        }
    }

    @objc func closeCurrentTab(_ sender: Any?) {
        tabManager.closeCurrentTab()

        if tabManager.tabs.isEmpty {
            let tab = tabManager.createTab()
            tabManager.select(tab: tab)
        }

        syncDisplayedTab()
        updateSidebar()
    }

    @objc func reopenClosedTab(_ sender: Any?) {
        if let tab = tabManager.reopenClosedTab() {
            tabManager.select(tab: tab)
            syncDisplayedTab()
            updateSidebar()
        }
    }

    @objc func switchToTabByNumber(_ sender: NSMenuItem) {
        let index = sender.tag - 1
        if index == 8 {
            tabManager.selectTab(at: tabManager.tabs.count - 1)
        } else {
            tabManager.selectTab(at: index)
        }
        syncDisplayedTab()
    }

    @objc func selectNextTab(_ sender: Any?) {
        tabManager.selectNextTab()
        syncDisplayedTab()
    }

    @objc func selectPreviousTab(_ sender: Any?) {
        tabManager.selectPreviousTab()
        syncDisplayedTab()
    }

    // MARK: - Navigation

    @objc func goBack(_ sender: Any?) {
        tabManager.activeTab?.goBack()
    }

    @objc func goForward(_ sender: Any?) {
        tabManager.activeTab?.goForward()
    }

    @objc func reloadPage(_ sender: Any?) {
        tabManager.activeTab?.reload()
    }

    @objc func hardReloadPage(_ sender: Any?) {
        tabManager.activeTab?.reloadFromOrigin()
    }

    @objc func focusAddressBar(_ sender: Any?) {
        addressBar.focus()
    }

    // MARK: - Find

    @objc func performFind(_ sender: Any?) {
        guard let tab = tabManager.activeTab else { return }

        let alert = NSAlert()
        alert.messageText = "Find in Page"
        alert.addButton(withTitle: "Find")
        alert.addButton(withTitle: "Cancel")

        let textField = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        alert.accessoryView = textField

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            let query = textField.stringValue
            if !query.isEmpty {
                tab.webView.evaluateJavaScript(
                    "window.find('\(query.replacingOccurrences(of: "'", with: "\\'"))')",
                    completionHandler: nil
                )
            }
        }
    }

    // MARK: - Zoom

    @objc func zoomIn(_ sender: Any?) {
        guard let tab = tabManager.activeTab else { return }
        tab.setZoom(min(tab.zoomLevel + 0.1, 3.0))
    }

    @objc func zoomOut(_ sender: Any?) {
        guard let tab = tabManager.activeTab else { return }
        tab.setZoom(max(tab.zoomLevel - 0.1, 0.3))
    }

    @objc func resetZoom(_ sender: Any?) {
        tabManager.activeTab?.setZoom(1.0)
    }
}
