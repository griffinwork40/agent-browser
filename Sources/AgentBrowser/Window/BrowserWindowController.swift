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

    private var sidebarHostingController: NSHostingController<TabSidebarView>?
    private let sidebarContainerView = NSView()
    private var isSidebarVisible = true
    /// Stored so we can zero/restore it on toggle.
    private var sidebarWidthConstraint: NSLayoutConstraint?

    // MARK: - KVO

    private var progressObservation: NSKeyValueObservation?

    // MARK: - Persistence

    /// Shared history store — injected after async init in PersistenceCoordinator.
    private var historyStore: HistoryStore?

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

    /// Injects the shared HistoryStore so navigation events can be recorded.
    /// Wires the store into all currently open tabs and into every future tab
    /// created while this window is alive.
    func attachHistoryStore(_ store: HistoryStore) {
        self.historyStore = store

        // Wire into already-open tabs (restored from disk or pre-existing).
        for tab in tabManager.tabs {
            tab.attachHistoryStore(store)
        }

        // Wire into tabs created after this point by observing TabManager.
        // We piggyback on the existing onSelectionChanged hook — new tabs
        // are always selected immediately after creation, so this fires
        // at the right moment.
        let previousSelectionChanged = tabManager.onSelectionChanged
        tabManager.onSelectionChanged = { [weak self] in
            previousSelectionChanged?()
            // Attach history store to the newly-selected tab if needed.
            if let activeTab = self?.tabManager.activeTab,
               let hs = self?.historyStore {
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

    // MARK: - Sidebar

    /// Creates the NSHostingController<TabSidebarView> and embeds it in sidebarContainerView.
    /// Called once from init after setupLayout().
    private func setupSidebar() {
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

    /// Switches to the given profile, preserving both profiles' workspaces (P2).
    ///
    /// Delegates to `performWorkspacePreservingSwitch(to:)` defined in
    /// `BrowserWindowController+ProfileSwitch.swift`. Same-profile switching is a no-op.
    func performProfileSwitch(to profileID: UUID) {
        performWorkspacePreservingSwitch(to: profileID)
    }

    /// Shows a naming dialog, then creates a profile with the entered name.
    ///
    /// Replaces the hardcoded "New Profile" creation (P1).
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
            // P1: reject empty or duplicate names; re-prompt instead of using a default.
            guard !name.isEmpty else {
                self.promptAndCreateProfile()
                return
            }
            guard self.profileManager.isNameAvailable(name) else {
                let errAlert = NSAlert()
                errAlert.messageText = "Name Already Taken"
                errAlert.informativeText = "\"\(name)\" is already used by another profile. Choose a different name."
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

    private func makeSidebarView() -> TabSidebarView {
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
            }
        )
    }

    // MARK: - Sidebar Toggle

    @objc func toggleSidebar(_ sender: Any?) {
        isSidebarVisible.toggle()
        let targetWidth: CGFloat = isSidebarVisible ? ControlSize.sidebarWidth : 0

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = Motion.standard
            ctx.allowsImplicitAnimation = true
            sidebarWidthConstraint?.constant = targetWidth
            sidebarContainerView.isHidden = !isSidebarVisible
            window?.contentView?.layoutSubtreeIfNeeded()
        }
    }

    // MARK: - Tab Display Sync

    /// Ensure the window shows the TabManager's currently selected tab.
    func syncDisplayedTab() {
        guard let activeTab = tabManager.activeTab else { return }

        // Nothing to do if already showing this tab
        if displayedTabID == activeTab.id { return }

        // Remove previous webview
        if let oldID = displayedTabID,
           let oldTab = tabManager.tab(for: oldID) {
            oldTab.webView.removeFromSuperview()
        }

        // Add new tab's webview
        displayedTabID = activeTab.id
        let wv = activeTab.webView
        wv.translatesAutoresizingMaskIntoConstraints = false
        webContentView.addSubview(wv)
        NSLayoutConstraint.activate([
            wv.topAnchor.constraint(equalTo: webContentView.topAnchor),
            wv.bottomAnchor.constraint(equalTo: webContentView.bottomAnchor),
            wv.leadingAnchor.constraint(equalTo: webContentView.leadingAnchor),
            wv.trailingAnchor.constraint(equalTo: webContentView.trailingAnchor),
        ])

        updateUI()
        observeProgress(for: activeTab)
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
