import AppKit
import SwiftUI
import WebKit

/// Manages a single browser window: sidebar, navigation chrome, web content.
/// Tab state lives in the shared TabManager; this controller is the UI layer over it.
@MainActor
final class BrowserWindowController: NSWindowController {

    // MARK: - Shared State

    let tabManager: TabManager
    let profileManager: ProfileManager

    /// Back-reference to the window manager — injected after creation.
    /// Weak to avoid a retain cycle (manager owns controllers).
    weak var windowSessionManager: WindowSessionManager?
    /// Agent activity data source — optional so windows without automation still compile.
    var agentActivityStore: AgentActivityStore?
    /// Handles human-takeover interactions for agent-controlled tabs.
    var takeoverHandler: TakeoverHandler?
    /// Track which tab is currently displayed in the view hierarchy.
    private var displayedTabID: UUID?

    // MARK: - UI Components

    // Internal so extensions (+Actions, +Toolbar) can reach these.
    let addressBar = AddressBar()
    let backButton = NSButton()
    let forwardButton = NSButton()
    let reloadButton = NSButton()
    let sidebarToggleButton = NSButton()
    let progressBar = NSProgressIndicator()
    let webContentView = NSView()
    let toolbarContainer = NSView()

    // MARK: - Sidebar
    // sidebarHostingController and sidebarContainerView are `internal` (not private)
    // so BrowserWindowController+Sidebar.swift can reach them from the same module.
    // Sidebar stored properties are internal (not private) so BrowserWindowController+Sidebar.swift
    // can access them.
    var sidebarHostingController: NSHostingController<TabSidebarView>?
    let sidebarContainerView = NSView()
    var isSidebarVisible = true
    /// Stored so we can zero/restore it on toggle.
    var sidebarWidthConstraint: NSLayoutConstraint?
    // Sidebar setup, update, toggle, profile dialogs, and makeSidebarView()
    // live in BrowserWindowController+Sidebar.swift.

    // MARK: - Ghost Cursor

    /// Manages semi-transparent agent cursor overlays on the web content area.
    let ghostCursorController = GhostCursorController()

    // MARK: - KVO

    private var progressObservation: NSKeyValueObservation?

    // MARK: - Persistence

    /// Shared history store — injected after async init in PersistenceCoordinator.
    private var historyStore: HistoryStore?

    /// Shared bookmark store — injected after async init in PersistenceCoordinator.
    var bookmarkStore: BookmarkStore?

    // MARK: - Command Palette

    /// Retained while the palette panel is visible; nil when closed.
    /// Internal (not private) so the +Actions extension can read/write it.
    var commandPaletteWindow: CommandPaletteWindow?

    // MARK: - Init

    init(tabManager: TabManager, profileManager: ProfileManager, skipInitialTab: Bool = false) {
        self.tabManager = tabManager
        self.profileManager = profileManager

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Agent Browser"
        window.setFrameAutosaveName("BrowserWindow")
        window.minSize = NSSize(width: 400, height: 300)
        // Transparent titlebar lets the toolbar's NSVisualEffectView material bleed
        // to the very top edge of the window, giving the full Liquid Glass effect.
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden

        super.init(window: window)
        window.delegate = self
        setupLayout()
        setupSidebar()

        // Sync display whenever TabManager selection changes (from UI or automation)
        tabManager.onSelectionChanged = { [weak self] in
            self?.syncDisplayedTab()
            self?.updateSidebar()
        }

        // Create first tab unless the caller will restore one asynchronously.
        if !skipInitialTab {
            let firstTab = tabManager.createTab()
            tabManager.select(tab: firstTab)
        }
    }

    // MARK: - History Injection

    /// Injects the default-profile HistoryStore so navigation events can be
    /// recorded. Wires the default store into currently open tabs and sets up
    /// a hook that injects the correct per-profile store into each tab as it
    /// becomes active.
    ///
    /// - Note: After a profile switch the correct store is also wired directly
    ///   in `performWorkspacePreservingSwitch`, which covers tabs that exist at
    ///   switch time. The hook here covers tabs created *after* the switch.
    func attachHistoryStore(_ store: HistoryStore) {
        self.historyStore = store

        // Wire into already-open tabs for the default profile.
        for tab in tabManager.tabs {
            tab.attachHistoryStore(store)
        }

        // Wire into tabs created/selected after this point.
        // We piggyback on the existing onSelectionChanged hook — new tabs
        // are always selected immediately after creation, so this fires
        // at the right moment.
        let previousSelectionChanged = tabManager.onSelectionChanged
        tabManager.onSelectionChanged = { [weak self] in
            previousSelectionChanged?()
            guard let self,
                  let activeTab = self.tabManager.activeTab else { return }
            let profileID = activeTab.record.profileID
            if let coordinator = self.persistenceCoordinator {
                // Ask the coordinator for the profile-specific store.
                // makeHistoryStore(for:) is async so dispatch a Task; the tab
                // will record history once the store arrives (typically < 1 ms
                // for an already-created store).
                Task { [weak self] in
                    guard let self else { return }
                    let hs = await coordinator.makeHistoryStore(for: profileID)
                    activeTab.attachHistoryStore(hs)
                }
            } else if let hs = self.historyStore {
                // Coordinator not yet wired (early startup) — fall back to the
                // default-profile store. This path covers the first tab before
                // the persistence coordinator is injected.
                activeTab.attachHistoryStore(hs)
            }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Layout

    private func setupLayout() {
        guard let contentView = window?.contentView else { return }
        contentView.wantsLayer = true

        // Toolbar — glass background via NSVisualEffectView (Option A).
        // We insert the effect view as the first (bottom-most) subview of the
        // toolbarContainer so all button/field subviews draw on top of it.
        toolbarContainer.translatesAutoresizingMaskIntoConstraints = false
        toolbarContainer.wantsLayer = true
        contentView.addSubview(toolbarContainer)
        setupToolbarGlassBackground()
        setupNavigationButtons()
        setupSidebarToggle()
        setupAddressBar()
        setupProgressBar()

        // Web content area — fills everything to the left of the sidebar
        webContentView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(webContentView)

        // Sidebar container — sits to the RIGHT of web content
        sidebarContainerView.translatesAutoresizingMaskIntoConstraints = false
        sidebarContainerView.wantsLayer = true
        sidebarContainerView.layer?.masksToBounds = true
        contentView.addSubview(sidebarContainerView)

        let widthConstraint = sidebarContainerView.widthAnchor.constraint(
            equalToConstant: ControlSize.sidebarWidth
        )
        sidebarWidthConstraint = widthConstraint

        NSLayoutConstraint.activate([
            // Toolbar spans full width at the top.
            // With .fullSizeContentView + titlebarAppearsTransparent the toolbar
            // top is pinned to the window top (behind the titlebar area), so the
            // glass material fills all the way to the top window edge.
            toolbarContainer.topAnchor.constraint(equalTo: contentView.topAnchor),
            toolbarContainer.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            toolbarContainer.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            toolbarContainer.heightAnchor.constraint(equalToConstant: ControlSize.toolbarHeight),

            // Sidebar: right edge, full height below toolbar
            sidebarContainerView.topAnchor.constraint(equalTo: toolbarContainer.bottomAnchor),
            sidebarContainerView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            sidebarContainerView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            widthConstraint,

            // Web content: fills remainder to the left of sidebar
            webContentView.topAnchor.constraint(equalTo: toolbarContainer.bottomAnchor),
            webContentView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            webContentView.trailingAnchor.constraint(equalTo: sidebarContainerView.leadingAnchor),
            webContentView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
        ])
    }

    // MARK: - Tab Display Sync
    // Sidebar setup, makeSidebarView, promptAndCreateProfile → BrowserWindowController+Sidebar.swift

    /// Ensure the window shows the TabManager's currently selected tab.
    ///
    /// Lazy WebView recreation (Issue #8): if the active tab's `needsWebViewRecreation`
    /// flag is set (a background tab that was deferred during profile switch), recreate
    /// it now before mounting — no extra animation, since it was never visible.
    func syncDisplayedTab() {
        guard let activeTab = tabManager.activeTab else { return }

        // Lazy recreation: background tab selected for the first time after a profile switch.
        if activeTab.needsWebViewRecreation {
            let config = profileManager.makeConfiguration(for: activeTab.record.profileID)
            activeTab.recreateWebView(configuration: config)
            // Clear cached ID so the remount below always runs.
            displayedTabID = nil
        }

        // Nothing to do if already showing this tab
        if displayedTabID == activeTab.id { return }

        // Remove previous webview
        if let oldID = displayedTabID,
           let oldTab = tabManager.tab(for: oldID) {
            oldTab.webView.removeFromSuperview()
        }

        // Add new tab's webview — skip if it is already mounted in webContentView
        // (e.g. cross-fade animation in +ProfileSwitch already added and constrained it).
        // Position below the agent status bar (if visible) and apply its inset.
        displayedTabID = activeTab.id
        let wv = activeTab.webView
        if wv.superview !== webContentView {
            wv.translatesAutoresizingMaskIntoConstraints = false
            // Ensure the status bar host view stays on top of the web content view
            if let statusHost = controlStatusHostingController?.view {
                webContentView.addSubview(wv, positioned: .below, relativeTo: statusHost)
            } else {
                webContentView.addSubview(wv)
            }
            let barInset = controlStatusHeightConstraint?.constant ?? 0
            NSLayoutConstraint.activate([
                wv.topAnchor.constraint(equalTo: webContentView.topAnchor, constant: barInset),
                wv.bottomAnchor.constraint(equalTo: webContentView.bottomAnchor),
                wv.leadingAnchor.constraint(equalTo: webContentView.leadingAnchor),
                wv.trailingAnchor.constraint(equalTo: webContentView.trailingAnchor),
            ])
        }

        updateUI()
        observeProgress(for: activeTab)
    }

    /// Reset the cached displayed-tab ID so the next `syncDisplayedTab` call
    /// unconditionally remounts and rewires the current tab.
    ///
    /// Used by the profile-switch cross-fade completion handler in
    /// `BrowserWindowController+ProfileSwitch.swift` after animation finishes.
    func clearDisplayedTabID() {
        displayedTabID = nil
    }

    // MARK: - UI Updates

    private func updateUI() {
        guard let tab = tabManager.activeTab else { return }
        addressBar.setURL(tab.url)
        backButton.isEnabled = tab.canGoBack
        forwardButton.isEnabled = tab.canGoForward
        window?.title = tab.title.isEmpty ? "Agent Browser" : tab.title

        let tabCount = tabManager.tabs.count
        if tabCount > 1 {
            window?.title = "[\((tabManager.selectedTabIndex) + 1)/\(tabCount)] "
                + (tab.title.isEmpty ? "Agent Browser" : tab.title)
        }
        addressBar.updateSecurityIndicator(isSecure: tab.isSecure)
    }

    private func observeProgress(for tab: BrowserTab) {
        progressObservation?.invalidate()
        progressObservation = tab.webView.observe(\.estimatedProgress) { [weak self] wv, _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let progress = wv.estimatedProgress
                self.progressBar.doubleValue = progress
                self.progressBar.isHidden = progress >= 1.0
                self.updateUI()
            }
        }
    }
}
