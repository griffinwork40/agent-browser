import AppKit
import WebKit

/// Manages a single browser window: navigation chrome, web content display.
/// Tab state lives in the shared TabManager; this controller is the UI over it.
@MainActor
final class BrowserWindowController: NSWindowController {

    // MARK: - Shared State

    let tabManager: TabManager

    /// Track which tab is currently displayed in the view hierarchy.
    private var displayedTabID: UUID?

    // MARK: - UI Components

    private let addressBar = AddressBar()
    private let backButton = NSButton()
    private let forwardButton = NSButton()
    private let reloadButton = NSButton()
    private let progressBar = NSProgressIndicator()
    private let webContentView = NSView()
    private let toolbarContainer = NSView()

    // KVO for progress
    private var progressObservation: NSKeyValueObservation?

    // MARK: - Init

    init(tabManager: TabManager) {
        self.tabManager = tabManager

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

        // Sync display whenever TabManager selection changes (from UI or automation)
        tabManager.onSelectionChanged = { [weak self] in
            self?.syncDisplayedTab()
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

        toolbarContainer.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(toolbarContainer)

        setupNavigationButtons()
        setupAddressBar()
        setupProgressBar()

        webContentView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(webContentView)

        NSLayoutConstraint.activate([
            toolbarContainer.topAnchor.constraint(equalTo: contentView.topAnchor),
            toolbarContainer.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            toolbarContainer.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            toolbarContainer.heightAnchor.constraint(equalToConstant: 42),

            webContentView.topAnchor.constraint(equalTo: toolbarContainer.bottomAnchor),
            webContentView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
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
        addressBar.onNavigate = { [weak self] input in
            self?.navigate(to: input)
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

    // MARK: - Tab Actions (Menu/Keyboard targets)

    @objc func newTab(_ sender: Any?) {
        let tab = tabManager.createTab()
        tabManager.select(tab: tab)
        syncDisplayedTab()

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
    }

    @objc func reopenClosedTab(_ sender: Any?) {
        if let tab = tabManager.reopenClosedTab() {
            tabManager.select(tab: tab)
            syncDisplayedTab()
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

    private func navigate(to input: String) {
        guard let tab = tabManager.activeTab else { return }
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        if let url = URL(string: trimmed), url.scheme != nil, url.host != nil {
            tab.load(url)
        } else if trimmed.contains(".") && !trimmed.contains(" ") {
            if let url = URL(string: "https://\(trimmed)") {
                tab.load(url)
            }
        } else {
            tab.loadSearch(trimmed)
        }
    }

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
                tab.webView.evaluateJavaScript("window.find('\(query.replacingOccurrences(of: "'", with: "\\'"))')", completionHandler: nil)
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

    // MARK: - UI Updates

    private func updateUI() {
        guard let tab = tabManager.activeTab else { return }
        addressBar.setURL(tab.url)
        backButton.isEnabled = tab.canGoBack
        forwardButton.isEnabled = tab.canGoForward
        window?.title = tab.title.isEmpty ? "Agent Browser" : tab.title

        let tabCount = tabManager.tabs.count
        if tabCount > 1 {
            window?.title = "[\((tabManager.selectedTabIndex) + 1)/\(tabCount)] " + (tab.title.isEmpty ? "Agent Browser" : tab.title)
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
