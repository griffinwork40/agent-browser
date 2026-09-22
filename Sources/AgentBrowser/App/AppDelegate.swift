import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {

    // MARK: - Core Services

    private var activityStore: AgentActivityStore?

    /// Guards against duplicate in-flight quit-save Tasks when Cocoa calls
    /// applicationShouldTerminate more than once (e.g. repeated Cmd-Q presses
    /// while the async save is pending).
    @MainActor private var quitSaveInFlight = false

    private let persistenceCoordinator = PersistenceCoordinator()
    private var profileManager: ProfileManager?

    /// Extension manager: web extension loading / lifecycle.
    /// `internal` so AppDelegate+Extensions.swift can access it.
    var extensionManager: ExtensionManager?

    /// Content blocker: created before TabManager so ProfileManager can use it.
    private var contentBlockerManager: ContentBlockerManager?

    /// Keeps the extensions panel window alive while it's open.
    /// `internal` so the AppDelegate+Extensions extension file can set it.
    var extensionsPanelWindow: NSWindow?

    /// Central multi-window coordinator — created in applicationDidFinishLaunching.
    @MainActor private var windowSessionManager: WindowSessionManager?

    /// Agent HTTP server for automation (singleton across all windows).
    private var agentServer: AgentHTTPServer?

    // MARK: - Launch

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMainMenu()

        let em = ExtensionManager()
        self.extensionManager = em

        let cbm = ContentBlockerManager()
        self.contentBlockerManager = cbm

        let store = AgentActivityStore()
        self.activityStore = store

        let pm = ProfileManager()
        pm.extensionManager = em
        pm.contentBlockerManager = cbm
        self.profileManager = pm

        let wsm = WindowSessionManager(
            profileManager: pm,
            persistenceCoordinator: persistenceCoordinator
        )
        self.windowSessionManager = wsm

        // Bring the app to the front synchronously so the first window gets focus
        // immediately on launch rather than waiting for the async restore Task.
        NSApp.activate(ignoringOtherApps: true)

        // Bootstrap persistence then restore (or create) the first window.
        Task { @MainActor in
            // Start content blocker setup (downloads filter lists if stale).
            await cbm.setUp()

            await persistenceCoordinator.setUp(defaultProfileID: pm.activeProfileID)

            let windowSnapshots = await persistenceCoordinator.restoreWindowSnapshots()

            if !windowSnapshots.isEmpty {
                // Restore each saved window in order.
                for winSnap in windowSnapshots {
                    let wc = wsm.createWindow(skipInitialTab: true)
                    let workspaces = winSnap.workspacesByUUID
                    let activeProfileID = winSnap.activeProfileID

                    wc.loadWorkspaceRegistry(workspaces)

                    // Recreate tabs — active profile first so it gets focus.
                    let allProfileIDs = [activeProfileID] +
                        pm.profiles.map(\.id).filter { $0 != activeProfileID }
                    for pid in allProfileIDs {
                        guard let ws = workspaces[pid], !ws.isEmpty else { continue }
                        for entry in ws.tabs {
                            wc.tabManager.createTab(
                                url: entry.url,
                                provenance: .restored(originalAgentID: nil, originalSessionTag: nil),
                                profileID: entry.profileID,
                                id: entry.id
                            )
                        }
                    }

                    // Select the previously-chosen tab for the active profile.
                    if let activeWs = workspaces[activeProfileID],
                       let selID = activeWs.selectedTabID,
                       let tab = wc.tabManager.tab(for: selID) {
                        wc.tabManager.select(tab: tab)
                    } else if let first = wc.tabManager.tabs.first(where: {
                        $0.record.profileID == activeProfileID
                    }) {
                        wc.tabManager.select(tab: first)
                    } else if let any = wc.tabManager.tabs.first {
                        wc.tabManager.select(tab: any)
                    }

                    finishWiringWindow(wc, pm: pm)
                }
            } else {
                // Legacy path: try old single-window workspace format.
                let savedWorkspaces = await persistenceCoordinator.restoreWorkspaces(
                    activeProfileID: pm.activeProfileID
                )

                let wc = wsm.createWindow(skipInitialTab: true)

                if !savedWorkspaces.isEmpty {
                    wc.loadWorkspaceRegistry(savedWorkspaces)
                    let allProfileIDs = [pm.activeProfileID] +
                        pm.profiles.map(\.id).filter { $0 != pm.activeProfileID }
                    for pid in allProfileIDs {
                        guard let ws = savedWorkspaces[pid], !ws.isEmpty else { continue }
                        for entry in ws.tabs {
                            wc.tabManager.createTab(
                                url: entry.url,
                                provenance: .restored(originalAgentID: nil, originalSessionTag: nil),
                                profileID: entry.profileID,
                                id: entry.id
                            )
                        }
                    }
                    if let activeWs = savedWorkspaces[pm.activeProfileID],
                       let selID = activeWs.selectedTabID,
                       let tab = wc.tabManager.tab(for: selID) {
                        wc.tabManager.select(tab: tab)
                    } else if let first = wc.tabManager.tabs.first(where: {
                        $0.record.profileID == pm.activeProfileID
                    }) {
                        wc.tabManager.select(tab: first)
                    } else if let any = wc.tabManager.tabs.first {
                        wc.tabManager.select(tab: any)
                    }
                } else {
                    // No saved session — open a single blank tab.
                    let firstTab = wc.tabManager.createTab(profileID: pm.activeProfileID)
                    wc.tabManager.select(tab: firstTab)
                }

                finishWiringWindow(wc, pm: pm)
            }

            // Wire agent HTTP server and ghost cursor against the first window's tab manager.
            if let firstWC = wsm.windowControllers.first {
                let automationService = BrowserAutomationService(
                    tabManager: firstWC.tabManager,
                    takeoverHandler: TakeoverHandler()
                )
                agentServer = AgentHTTPServer(automationService: automationService)
                agentServer?.start()

                // Wire ghost cursor overlay on the first window.
                if let as_ = activityStore {
                    firstWC.setupGhostCursor(automationService: automationService,
                                             activityStore: as_)
                }
            }

            // Multi-window auto-save every 30 s.
            startMultiWindowAutoSave(wsm: wsm, pm: pm)
        }
    }

    // MARK: - Window Wiring Helper

    @MainActor
    private func finishWiringWindow(_ wc: BrowserWindowController, pm: ProfileManager) {
        wc.persistenceCoordinator = persistenceCoordinator

        if let historyStore = persistenceCoordinator.makeHistoryStore() {
            wc.attachHistoryStore(historyStore)
        }
        wc.syncDisplayedTab()
        wc.updateSidebar()
    }

    // MARK: - Multi-Window Auto-Save

    @MainActor private var multiWindowAutoSaveTimer: Timer?

    /// Handle for the repeating auto-save task so it can be cancelled before
    /// the quit snapshot runs, preventing a save-vs-save race on termination.
    @MainActor private var multiWindowAutoSaveTask: Task<Void, Never>?

    @MainActor
    private func startMultiWindowAutoSave(wsm: WindowSessionManager, pm: ProfileManager) {
        multiWindowAutoSaveTimer?.invalidate()
        multiWindowAutoSaveTimer = Timer.scheduledTimer(
            withTimeInterval: 30,
            repeats: true
        ) { [weak self, weak wsm, weak pm] _ in
            guard let self, let wsm, let pm else { return }
            // Dispatch the save on the MainActor so we can store the handle
            // for cancellation in applicationShouldTerminate.
            let task = Task { @MainActor [weak self, weak wsm, weak pm] in
                guard let self, let wsm, let pm else { return }
                _ = await self.buildAndSaveWindowSnapshots(wsm: wsm, pm: pm)
            }
            // Assign from the outer (nonisolated) closure is unavoidable here;
            // use a MainActor hop to cross the isolation boundary safely.
            Task { @MainActor [weak self] in self?.multiWindowAutoSaveTask = task }
        }
    }

    @MainActor
    private func buildAndSaveWindowSnapshots(
        wsm: WindowSessionManager,
        pm: ProfileManager
    ) async -> Bool {
        let snaps = wsm.windowControllers.map { wc in
            WindowSnapshot(
                workspaces: wc.snapshotAllWorkspaces(
                    tabManager: wc.tabManager,
                    profileManager: wc.profileManager
                ),
                activeProfileID: wc.profileManager.activeProfileID
            )
        }
        let activeProfileID = wsm.activeWindowController?.profileManager.activeProfileID
            ?? pm.activeProfileID
        return await persistenceCoordinator.saveWindowSnapshotsAndWait(
            snaps,
            activeProfileID: activeProfileID
        )
    }

    // MARK: - App Lifecycle

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // With multi-window, only quit when the last window is closed.
        true
    }

    /// Quit-time persistence.
    ///
    /// Ordering invariants (same as single-window but extended to all windows):
    ///   1. Stop auto-save FIRST to avoid a race with the quit snapshot.
    ///   2. Snapshot + await all windows.
    ///   3. On success: stop agent server, reply true. On failure: alert, cancel.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if quitSaveInFlight { return .terminateLater }
        quitSaveInFlight = true

        Task { @MainActor [weak self] in
            guard let self else {
                NSApp.reply(toApplicationShouldTerminate: true)
                return
            }

            multiWindowAutoSaveTask?.cancel()
            multiWindowAutoSaveTask = nil
            multiWindowAutoSaveTimer?.invalidate()
            multiWindowAutoSaveTimer = nil
            persistenceCoordinator.stopAutoSave()

            var saved = true
            if let wsm = windowSessionManager, let pm = profileManager {
                saved = await buildAndSaveWindowSnapshots(wsm: wsm, pm: pm)
            }

            if saved {
                agentServer?.stop()
                quitSaveInFlight = false
                NSApp.reply(toApplicationShouldTerminate: true)
            } else {
                quitSaveInFlight = false
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

        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Intentionally empty — all quit persistence handled in
        // applicationShouldTerminate(_:) to allow async awaiting.
    }

    // MARK: - Content Blocking

    @objc @MainActor private func toggleContentBlocking(_ sender: NSMenuItem) {
        contentBlockerManager?.toggleEnabled()
        sender.state = (contentBlockerManager?.isEnabled ?? false) ? .on : .off
    }
}
// Menu construction is in AppDelegate+MainMenu.swift (extracted to stay under 350 LOC).