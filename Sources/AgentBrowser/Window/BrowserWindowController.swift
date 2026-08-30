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

    // Internal so BrowserWindowController+Actions extension can call addressBar.focus()
    let addressBar = AddressBar()
    private let backButton = NSButton()
    private let forwardButton = NSButton()
    private let reloadButton = NSButton()
    private let progressBar = NSProgressIndicator()
    private let webContentView = NSView()
    private let toolbarContainer = NSView()

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
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Agent Browser"
        window.setFrameAutosaveName("BrowserWindow")
        window.minSize = NSSize(width: 400, height: 300)
        window.titlebarAppearsTransparent = false
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

        // Toolbar
        toolbarContainer.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(toolbarContainer)
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
            // Toolbar spans full width at the top
            toolbarContainer.topAnchor.constraint(equalTo: contentView.topAnchor),
            toolbarContainer.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            toolbarContainer.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            toolbarContainer.heightAnchor.constraint(equalToConstant: 42),

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

    private func setupNavigationButtons() {
        backButton.image = NSImage(systemSymbolName: "chevron.left", accessibilityDescription: "Back")
        backButton.bezelStyle = .accessoryBarAction
        backButton.isBordered = false
        backButton.target = self
        backButton.action = #selector(goBack(_:))
        backButton.translatesAutoresizingMaskIntoConstraints = false
        toolbarContainer.addSubview(backButton)

        forwardButton.image = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: "Forward")
        forwardButton.bezelStyle = .accessoryBarAction
        forwardButton.isBordered = false
        forwardButton.target = self
        forwardButton.action = #selector(goForward(_:))
        forwardButton.translatesAutoresizingMaskIntoConstraints = false
        toolbarContainer.addSubview(forwardButton)

        reloadButton.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "Reload")
        reloadButton.bezelStyle = .accessoryBarAction
        reloadButton.isBordered = false
        reloadButton.target = self
        reloadButton.action = #selector(reloadPage(_:))
        reloadButton.translatesAutoresizingMaskIntoConstraints = false
        toolbarContainer.addSubview(reloadButton)

        NSLayoutConstraint.activate([
            backButton.leadingAnchor.constraint(equalTo: toolbarContainer.leadingAnchor, constant: 12),
            backButton.centerYAnchor.constraint(equalTo: toolbarContainer.centerYAnchor),
            backButton.widthAnchor.constraint(equalToConstant: 28),

            forwardButton.leadingAnchor.constraint(equalTo: backButton.trailingAnchor, constant: 4),
            forwardButton.centerYAnchor.constraint(equalTo: toolbarContainer.centerYAnchor),
            forwardButton.widthAnchor.constraint(equalToConstant: 28),

            reloadButton.leadingAnchor.constraint(equalTo: forwardButton.trailingAnchor, constant: 4),
            reloadButton.centerYAnchor.constraint(equalTo: toolbarContainer.centerYAnchor),
            reloadButton.widthAnchor.constraint(equalToConstant: 28),
        ])
    }

    private func setupAddressBar() {
        addressBar.translatesAutoresizingMaskIntoConstraints = false
        addressBar.onNavigate = { [weak self] action in
            switch action {
            case .navigate(let url):
                self?.tabManager.activeTab?.load(url)
            case .search(let query):
                self?.tabManager.activeTab?.loadSearch(query)
            }
        }
        toolbarContainer.addSubview(addressBar)

        NSLayoutConstraint.activate([
            addressBar.leadingAnchor.constraint(equalTo: reloadButton.trailingAnchor, constant: 8),
            addressBar.trailingAnchor.constraint(equalTo: toolbarContainer.trailingAnchor, constant: -12),
            addressBar.centerYAnchor.constraint(equalTo: toolbarContainer.centerYAnchor),
            addressBar.heightAnchor.constraint(equalToConstant: 28),
        ])
    }

    private func setupProgressBar() {
        progressBar.style = .bar
        progressBar.isIndeterminate = false
        progressBar.minValue = 0
        progressBar.maxValue = 1
        progressBar.isHidden = true
        progressBar.translatesAutoresizingMaskIntoConstraints = false
        toolbarContainer.addSubview(progressBar)

        NSLayoutConstraint.activate([
            progressBar.leadingAnchor.constraint(equalTo: toolbarContainer.leadingAnchor),
            progressBar.trailingAnchor.constraint(equalTo: toolbarContainer.trailingAnchor),
            progressBar.bottomAnchor.constraint(equalTo: toolbarContainer.bottomAnchor),
            progressBar.heightAnchor.constraint(equalToConstant: 2),
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
