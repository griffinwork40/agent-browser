// BrowserWindowController+Sidebar.swift
// Sidebar setup, makeSidebarView, and profile-creation dialog — extracted from
// BrowserWindowController.swift to stay under the 350-LOC cap.

import AppKit
import SwiftUI

extension BrowserWindowController {

    // MARK: - Sidebar Init

    /// Creates the NSHostingController<TabSidebarView> and embeds it in sidebarContainerView.
    /// Called once from init after setupLayout().
    func setupSidebar() {
        let view = makeSidebarView()
        let hc = NSHostingController(rootView: view)
        sidebarHostingController = hc

        let hostView = hc.view
        hostView.translatesAutoresizingMaskIntoConstraints = false
        sidebarContainerView.addSubview(hostView)

        NSLayoutConstraint.activate([
            hostView.topAnchor.constraint(equalTo: sidebarContainerView.topAnchor),
            hostView.bottomAnchor.constraint(equalTo: sidebarContainerView.bottomAnchor),
            hostView.leadingAnchor.constraint(equalTo: sidebarContainerView.leadingAnchor),
            hostView.trailingAnchor.constraint(equalTo: sidebarContainerView.trailingAnchor),
        ])
    }

    /// Rebuilds the sidebar rootView with fresh tabs/selection data.
    func updateSidebar() {
        sidebarHostingController?.rootView = makeSidebarView()
    }

    // MARK: - Profile Switch Entry Point

    /// Switches to the given profile, preserving both profiles' workspaces (P2).
    func performProfileSwitch(to profileID: UUID) {
        performWorkspacePreservingSwitch(to: profileID)
    }

    // MARK: - Profile Creation Dialog

    /// Shows a naming dialog, then creates a profile with the entered name.
    func promptAndCreateProfile() {
        let alert = NSAlert()
        alert.messageText = "New Profile"
        alert.informativeText = "Enter a name for the new profile."
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")

        let nameField = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        nameField.placeholderString = "Profile name"
        nameField.stringValue = ""
        alert.accessoryView = nameField

        guard let window else { return }
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            guard response == .alertFirstButtonReturn else { return }
            let name = nameField.stringValue.trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else {
                self.promptAndCreateProfile()
                return
            }
            guard self.profileManager.isNameAvailable(name) else {
                let errAlert = NSAlert()
                errAlert.messageText = "Name Already Taken"
                errAlert.informativeText =
                    "\"\(name)\" is already used by another profile. Choose a different name."
                errAlert.addButton(withTitle: "OK")
                errAlert.beginSheetModal(for: window) { [weak self] _ in
                    self?.promptAndCreateProfile()
                }
                return
            }
            self.profileManager.createProfile(name: name)
            self.updateSidebar()
        }
    }

    // MARK: - Sidebar View Factory

    func makeSidebarView() -> TabSidebarView {
        let profileColors: [UUID: String] = Dictionary(
            uniqueKeysWithValues: profileManager.profiles.map { ($0.id, $0.colorName) }
        )
        return TabSidebarView(
            tabs: tabManager.tabs,
            selectedTabID: tabManager.activeTab?.id,
            profileColors: profileColors,
            onSelect: { [weak self] tab in
                self?.tabManager.select(tab: tab)
                self?.syncDisplayedTab()
            },
            onClose: { [weak self] tab in
                guard let self else { return }
                let entry = ProfileWorkspace.TabEntry(
                    id: tab.id,
                    urlString: tab.url?.absoluteString,
                    title: tab.title,
                    provenance: tab.record.provenance,
                    profileID: tab.record.profileID
                )
                let pid = tab.record.profileID
                let existing = self.workspaceRegistry[pid] ?? ProfileWorkspace.empty(for: pid)
                self.workspaceRegistry[pid] = existing.addingClosed(entry)
                self.tabManager.closeTab(tab)
                if self.tabManager.tabs.isEmpty {
                    let newTab = self.tabManager.createTab()
                    self.tabManager.select(tab: newTab)
                }
                self.syncDisplayedTab()
                self.updateSidebar()
            },
            onNewTab: { [weak self] in
                guard let self else { return }
                let tab = self.tabManager.createTab()
                self.tabManager.select(tab: tab)
                self.syncDisplayedTab()
                self.updateSidebar()
                self.addressBar.focus()
            },
            profiles: profileManager.profiles,
            activeProfileID: profileManager.activeProfileID,
            onSwitchProfile: { [weak self] id in
                self?.performProfileSwitch(to: id)
            },
            onCreateProfile: { [weak self] in
                self?.promptAndCreateProfile()
            },
            onRenameProfile: { [weak self] id, newName -> Bool in
                guard let self else { return false }
                return self.profileManager.renameProfile(id: id, to: newName)
            }
        )
    }

    // MARK: - Profile Naming Dialog

    /// Shows a naming dialog, then creates a profile with the entered name.
    /// Rejects empty or duplicate names and re-prompts instead of using a default (P1).
    func promptAndCreateProfile() {
        let alert = NSAlert()
        alert.messageText = "New Profile"
        alert.informativeText = "Enter a name for the new profile."
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")

        let nameField = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        nameField.placeholderString = "Profile name"
        nameField.stringValue = ""
        alert.accessoryView = nameField

        guard let window else { return }
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            guard response == .alertFirstButtonReturn else { return }
            let name = nameField.stringValue.trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { self.promptAndCreateProfile(); return }
            guard self.profileManager.isNameAvailable(name) else {
                let errAlert = NSAlert()
                errAlert.messageText = "Name Already Taken"
                errAlert.informativeText =
                    "\"\(name)\" is already used by another profile. Choose a different name."
                errAlert.addButton(withTitle: "OK")
                errAlert.beginSheetModal(for: window) { [weak self] _ in
                    self?.promptAndCreateProfile()
                }
                return
            }
            self.profileManager.createProfile(name: name)
            self.updateSidebar()
        }
    }
}
