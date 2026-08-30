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

    // MARK: - Init

    init(tabManager: TabManager, profileManager: ProfileManager) {
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

        // Create first tab
        let firstTab = tabManager.createTab()
        tabManager.select(tab: firstTab)
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
        setupAddressBar()
        setupProgressBar()

        // Sidebar container — sits to the LEFT of web content
        sidebarContainerView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(sidebarContainerView)

        // Web content area — fills everything to the right of the sidebar
        webContentView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(webContentView)

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

            // Sidebar: left edge → full height below toolbar
            sidebarContainerView.topAnchor.constraint(equalTo: toolbarContainer.bottomAnchor),
            sidebarContainerView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            sidebarContainerView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            widthConstraint,

            // Web content: fills remainder to the right of sidebar
            webContentView.topAnchor.constraint(equalTo: toolbarContainer.bottomAnchor),
            webContentView.leadingAnchor.constraint(equalTo: sidebarContainerView.trailingAnchor),
            webContentView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
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
                self.profileManager.switchTo(profileID: id)
                // Profile switch only affects new tabs — existing tabs keep their
                // original data store. New tabs created after this call will use
                // profileManager.activeProfileID via TabManager.createTab().
                self.updateSidebar()
            },
            onCreateProfile: { [weak self] in
                guard let self else { return }
                self.profileManager.createProfile(name: "New Profile")
                self.updateSidebar()
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
