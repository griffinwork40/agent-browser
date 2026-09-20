// BrowserWindowController+Sidebar.swift
// Sidebar construction and profile action wiring for BrowserWindowController.
// Extracted to keep BrowserWindowController.swift ≤ 350 LOC.

import AppKit
import SwiftUI

extension BrowserWindowController {

    // MARK: - Sidebar Setup

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
    /// Call whenever the tabs array or selection changes (individual tab properties
    /// — title, url, isLoading — are tracked automatically by @Observable).
    func updateSidebar() {
        sidebarHostingController?.rootView = makeSidebarView()
    }

    // MARK: - Sidebar View Factory

    func makeSidebarView() -> TabSidebarView {
        // Build profileID → colorName map from the live profiles list
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
                // P2: record closed tab into this profile's workspace history before removal.
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
                guard let self else { return }
                self.performProfileSwitch(to: id)
            },
            onCreateProfile: { [weak self] in
                guard let self else { return }
                self.promptAndCreateProfile()
            },
            onRenameProfile: { [weak self] id, newName -> Bool in
                guard let self else { return false }
                return self.profileManager.renameProfile(id: id, to: newName)
            },
            onDeleteProfile: { [weak self] id in
                guard let self else { return }
                Task { [weak self] in
                    guard let self else { return }
                    await self.profileManager.deleteProfile(id: id)
                    self.updateSidebar()
                }
            }
        )
    }
}
