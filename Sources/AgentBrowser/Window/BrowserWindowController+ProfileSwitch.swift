import AppKit
import Foundation
import WebKit
import os

// MARK: - Non-Destructive Profile Switching

/// Extends `BrowserWindowController` with workspace-preserving profile switching.
///
/// Design contract (P2):
/// - Switching profiles saves the outgoing profile's workspace, then restores
///   the incoming profile's workspace. No tabs are destroyed.
/// - Same-profile switching is a no-op.
/// - When a profile has no saved workspace, a single blank tab is created.
/// - The inactive profile's tabs remain in TabManager but are not displayed.
///
/// File-ownership note: `profileWorkspaces` and `persistenceCoordinator` are
/// declared here and back-patched onto the controller at call time via the
/// coordinator wire-up in PersistenceCoordinator. The integration step in
/// BrowserWindowController.swift wires `performProfileSwitch` to call
/// `performWorkspacePreservingSwitch` instead.
extension BrowserWindowController {

    // MARK: - Workspace-Preserving Switch

    /// Switch to `newProfileID`, preserving both profiles' workspaces.
    ///
    /// This replaces the destructive `performProfileSwitch(to:)` body.
    /// The caller (`makeSidebarView`) passes the profile ID; this method owns
    /// the save/restore cycle.
    func performWorkspacePreservingSwitch(to newProfileID: UUID) {
        let currentProfileID = profileManager.activeProfileID
        guard newProfileID != currentProfileID else { return } // P2: same-profile no-op

        // 1. Snapshot the outgoing workspace.
        let outgoingWorkspace = snapshotCurrentWorkspace(profileID: currentProfileID)

        // 2. Persist outgoing workspace via coordinator.
        persistWorkspace(outgoingWorkspace, for: currentProfileID)

        // 3. Switch the active profile in ProfileManager.
        profileManager.switchTo(profileID: newProfileID)

        // 4. Restore or create the incoming workspace.
        restoreOrCreateWorkspace(for: newProfileID)

        // 5. Wire the incoming profile's HistoryStore into its tabs.
        //    Done asynchronously (makeHistoryStore(for:) may touch disk on first
        //    access) but dispatched on @MainActor so all Tab mutations are safe.
        if let coordinator = persistenceCoordinator {
            Task { [weak self] in
                guard let self else { return }
                let store = await coordinator.makeHistoryStore(for: newProfileID)
                for tab in self.tabManager.tabs where tab.record.profileID == newProfileID {
                    tab.attachHistoryStore(store)
                }
            }
        }

        // 6. Recreate WKWebViews so the new profile's data store takes effect.
        //    The active tab is recreated eagerly; background tabs are lazy
        //    (needsWebViewRecreation = true, recreated on first selection).
        let activeTabID = tabManager.activeTab?.id
        let oldView = tabManager.recreateWebViews(for: newProfileID, activeTabID: activeTabID)

        // 7. Mount the new webview and cross-fade (0.15s) over the old one.
        if let old = oldView, let active = tabManager.activeTab {
            crossFadeWebViewSwap(incoming: active.webView, outgoing: old)
        } else {
            // No previous active view to animate — plain sync is sufficient.
            syncDisplayedTab()
        }

        // 8. Refresh the sidebar to reflect the new profile's tabs.
        updateSidebar()
    }

    // MARK: - Cross-Fade Animation (Issue #8)

    /// Mount `incoming` into the web-content area and fade it in over `outgoing`.
    ///
    /// Layout steps:
    /// 1. The outgoing view is still in the hierarchy (already removed from its
    ///    tab's superview by recreateWebView, re-added here for the fade).
    /// 2. The incoming view is pinned to the web-content area, initially transparent.
    /// 3. A 0.15s animation fades incoming to 1.0 and outgoing to 0.0.
    /// 4. On completion the outgoing view is removed and `syncDisplayedTab` is
    ///    called to finish UI wiring (progress observer, address bar, etc.).
    private func crossFadeWebViewSwap(incoming: WKWebView, outgoing: WKWebView) {
        // Re-attach the outgoing view on top so it is visible during fade-out.
        outgoing.translatesAutoresizingMaskIntoConstraints = false
        outgoing.alphaValue = 1.0
        webContentView.addSubview(outgoing)
        NSLayoutConstraint.activate([
            outgoing.topAnchor.constraint(equalTo: webContentView.topAnchor),
            outgoing.bottomAnchor.constraint(equalTo: webContentView.bottomAnchor),
            outgoing.leadingAnchor.constraint(equalTo: webContentView.leadingAnchor),
            outgoing.trailingAnchor.constraint(equalTo: webContentView.trailingAnchor),
        ])

        // Mount the incoming view underneath, initially invisible.
        incoming.translatesAutoresizingMaskIntoConstraints = false
        incoming.alphaValue = 0.0
        webContentView.addSubview(incoming, positioned: .below, relativeTo: outgoing)
        NSLayoutConstraint.activate([
            incoming.topAnchor.constraint(equalTo: webContentView.topAnchor),
            incoming.bottomAnchor.constraint(equalTo: webContentView.bottomAnchor),
            incoming.leadingAnchor.constraint(equalTo: webContentView.leadingAnchor),
            incoming.trailingAnchor.constraint(equalTo: webContentView.trailingAnchor),
        ])

        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.15
            ctx.allowsImplicitAnimation = true
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            outgoing.animator().alphaValue = 0.0
            incoming.animator().alphaValue = 1.0
        }, completionHandler: { [weak self] in
            outgoing.removeFromSuperview()
            // NSAnimationContext completion handlers always fire on the main thread.
            // MainActor.assumeIsolated lets us call @MainActor methods safely.
            MainActor.assumeIsolated {
                self?.forceResyncDisplayedTab()
            }
        })
    }

    /// Force-resyncs the displayed tab even when displayedTabID matches.
    ///
    /// Called from the cross-fade completion block to finish UI wiring
    /// (address bar, progress observer) after the animation completes.
    func forceResyncDisplayedTab() {
        // Clear the cached ID so syncDisplayedTab re-wires everything.
        clearDisplayedTabID()
        syncDisplayedTab()
        updateSidebar()
    }

    // MARK: - Workspace Snapshot

    /// Captures current TabManager state as a `ProfileWorkspace`.
    func snapshotCurrentWorkspace(profileID: UUID) -> ProfileWorkspace {
        let tabEntries = tabManager.tabs
            .filter { $0.record.profileID == profileID }
            .map { tab in
                ProfileWorkspace.TabEntry(
                    id: tab.id,
                    urlString: tab.url?.absoluteString,
                    title: tab.title,
                    provenance: tab.record.provenance,
                    profileID: profileID
                )
            }
        let selectedID: UUID? = {
            if let active = tabManager.activeTab, active.record.profileID == profileID {
                return active.id
            }
            return tabManager.tabs.first(where: { $0.record.profileID == profileID })?.id
        }()

        // Merge with any existing closed-tab history for this profile.
        let existing = workspaceRegistry[profileID]
        let closedHistory = existing?.closedTabHistory ?? []

        return ProfileWorkspace(
            profileID: profileID,
            tabs: tabEntries,
            selectedTabID: selectedID,
            closedTabHistory: closedHistory
        )
    }

    // MARK: - Workspace Restore

    /// Restores the incoming profile's workspace into TabManager, or creates a blank tab.
    private func restoreOrCreateWorkspace(for profileID: UUID) {
        if let saved = workspaceRegistry[profileID], !saved.isEmpty {
            // Restore saved tabs — recreate any that don't already exist.
            let existingIDs = Set(tabManager.tabs.filter { $0.record.profileID == profileID }.map(\.id))
            for entry in saved.tabs where !existingIDs.contains(entry.id) {
                tabManager.createTab(
                    url: entry.url,
                    provenance: .restored(originalAgentID: nil, originalSessionTag: nil),
                    profileID: profileID,
                    id: entry.id
                )
            }
            // Select the previously active tab.
            if let selectedID = saved.selectedTabID,
               let tab = tabManager.tab(for: selectedID) {
                tabManager.select(tab: tab)
            } else {
                // Pick first tab for this profile.
                if let first = tabManager.tabs.first(where: { $0.record.profileID == profileID }) {
                    tabManager.select(tab: first)
                }
            }
        } else {
            // No saved workspace — create a blank tab for the new profile.
            let blank = tabManager.createTab(profileID: profileID)
            tabManager.select(tab: blank)
        }
    }

    // MARK: - Registry (in-memory workspace store)

    /// In-memory workspace registry. Backed by the persistence coordinator on save/restore.
    /// Keyed by profileID for O(1) lookup.
    ///
    /// Note: stored as a computed property backed by an associated-object key to avoid
    /// adding stored properties to the class extension. The coordinator populates this
    /// at restore time via `loadWorkspaceRegistry(_:)`.
    var workspaceRegistry: [UUID: ProfileWorkspace] {
        get {
            (objc_getAssociatedObject(self, &Self.workspaceRegistryKey) as? [UUID: ProfileWorkspace]) ?? [:]
        }
        set {
            objc_setAssociatedObject(self, &Self.workspaceRegistryKey, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        }
    }

    private static var workspaceRegistryKey: UInt8 = 0

    /// Load a saved registry (called by PersistenceCoordinator at restore time).
    func loadWorkspaceRegistry(_ registry: [UUID: ProfileWorkspace]) {
        workspaceRegistry = registry
    }

    // MARK: - Persistence bridge

    /// Persist a single workspace into the registry and schedule a disk write.
    func persistWorkspace(_ workspace: ProfileWorkspace, for profileID: UUID) {
        workspaceRegistry[profileID] = workspace
        // Coordinator writes the full registry to disk.
        persistenceCoordinator?.saveAllWorkspaces(workspaceRegistry,
                                                   activeProfileID: profileManager.activeProfileID)
    }

    // MARK: - Full-registry snapshot

    /// Snapshots every profile's workspace from TabManager into the registry
    /// and returns the merged result. Used by auto-save and quit paths.
    ///
    /// - Parameters:
    ///   - tabManager: Optional override (nil → use self.tabManager).
    ///   - profileManager: Optional override (nil → use self.profileManager).
    func snapshotAllWorkspaces(
        tabManager: TabManager? = nil,
        profileManager: ProfileManager? = nil
    ) -> [UUID: ProfileWorkspace] {
        let tm = tabManager ?? self.tabManager
        let pm = profileManager ?? self.profileManager
        let start = Date()
        var registry = workspaceRegistry

        // Pre-group tabs by profileID once (O(n)) instead of filtering per profile (O(n*p)).
        let tabsByProfile = Dictionary(grouping: tm.tabs, by: { $0.record.profileID })

        for profile in pm.profiles {
            let pid = profile.id
            let profileTabs = tabsByProfile[pid] ?? []
            let tabEntries = profileTabs.map { tab in
                ProfileWorkspace.TabEntry(
                    id: tab.id,
                    urlString: tab.url?.absoluteString,
                    title: tab.title,
                    provenance: tab.record.provenance,
                    profileID: pid
                )
            }
            let selectedID: UUID? = {
                if let active = tm.activeTab, active.record.profileID == pid {
                    return active.id
                }
                return profileTabs.first?.id
            }()
            let existing = registry[pid]
            let closedHistory = existing?.closedTabHistory ?? []
            registry[pid] = ProfileWorkspace(
                profileID: pid,
                tabs: tabEntries,
                selectedTabID: selectedID,
                closedTabHistory: closedHistory
            )
        }
        workspaceRegistry = registry
        let elapsed = Date().timeIntervalSince(start) * 1000
        os_log("snapshotAllWorkspaces: %d profiles, %d tabs, %.1fms",
               pm.profiles.count, tm.tabs.count, elapsed)
        return registry
    }

    // MARK: - Coordinator back-reference

    /// Weak reference to PersistenceCoordinator, set by the coordinator at startup.
    ///
    /// Stored via a WeakBox associated object with RETAIN semantics to avoid a
    /// dangling-pointer crash. ASSIGN semantics were previously used here, which is
    /// only safe when the referent's lifetime strictly exceeds the associated object's;
    /// the WeakBox approach is correct regardless of deallocation order.
    var persistenceCoordinator: PersistenceCoordinator? {
        get {
            (objc_getAssociatedObject(self, &Self.persistenceCoordinatorKey) as? WeakBox<PersistenceCoordinator>)?.value
        }
        set {
            objc_setAssociatedObject(self, &Self.persistenceCoordinatorKey,
                                     newValue.map(WeakBox.init),
                                     .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        }
    }

    private static var persistenceCoordinatorKey: UInt8 = 1
}

// MARK: - WeakBox

/// Type-erased weak wrapper compatible with associated-object RETAIN storage.
/// Storing a weak reference with RETAIN semantics (not ASSIGN) means the box
/// itself is retained, but the referent can still be deallocated independently,
/// preventing both retain cycles and dangling-pointer crashes.
private final class WeakBox<T: AnyObject> {
    weak var value: T?
    init(_ value: T) { self.value = value }
}
