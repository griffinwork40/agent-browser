import AppKit
import WebKit

/// Manages a single browser window: tabs, navigation chrome, and web content.
@MainActor
final class BrowserWindowController: NSWindowController {

    // MARK: - State

    private var tabs: [BrowserTab] = []
    private var selectedTabIndex: Int = -1
    private var closedTabStack: [(url: URL?, index: Int)] = []

    private var currentTab: BrowserTab? {
        guard selectedTabIndex >= 0, selectedTabIndex < tabs.count else { return nil }
        return tabs[selectedTabIndex]
    }

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

    init() {
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
        newTab(nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Layout

    private func setupLayout() {
        guard let contentView = window?.contentView else { return }
        contentView.wantsLayer = true

        // Toolbar container (back/forward/reload/address bar)
        toolbarContainer.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(toolbarContainer)

        setupNavigationButtons()
        setupAddressBar()
        setupProgressBar()

        // Web content area
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
        // Back button
        backButton.image = NSImage(systemSymbolName: "chevron.left", accessibilityDescription: "Back")
        backButton.bezelStyle = .accessoryBarAction
        backButton.isBordered = false
        backButton.target = self
        backButton.action = #selector(goBack(_:))
        backButton.translatesAutoresizingMaskIntoConstraints = false
        toolbarContainer.addSubview(backButton)

        // Forward button
        forwardButton.image = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: "Forward")
        forwardButton.bezelStyle = .accessoryBarAction
        forwardButton.isBordered = false
        forwardButton.target = self
        forwardButton.action = #selector(goForward(_:))
        forwardButton.translatesAutoresizingMaskIntoConstraints = false
        toolbarContainer.addSubview(forwardButton)

        // Reload button
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

    // MARK: - Tab Management

    @objc func newTab(_ sender: Any?) {
        let tab = BrowserTab()
        tabs.append(tab)

        tab.onNewTabRequested = { [weak self] url in
            self?.openURLInNewTab(url)
        }

        selectTab(at: tabs.count - 1)

        // Focus address bar for new empty tab
        if sender != nil {
            addressBar.focus()
        }
    }

    @objc func closeCurrentTab(_ sender: Any?) {
        guard selectedTabIndex >= 0, selectedTabIndex < tabs.count else { return }
        let tab = tabs[selectedTabIndex]

        closedTabStack.append((url: tab.url, index: selectedTabIndex))
        tabs.remove(at: selectedTabIndex)

        if tabs.isEmpty {
            newTab(nil)
        } else {
            selectTab(at: min(selectedTabIndex, tabs.count - 1))
        }
    }

    @objc func reopenClosedTab(_ sender: Any?) {
        guard let closed = closedTabStack.popLast(), let url = closed.url else { return }
        let tab = BrowserTab()
        let insertIndex = min(closed.index, tabs.count)
        tabs.insert(tab, at: insertIndex)

        tab.onNewTabRequested = { [weak self] u in
            self?.openURLInNewTab(u)
        }

        selectTab(at: insertIndex)
        tab.load(url)
    }

    private func selectTab(at index: Int) {
        guard index >= 0, index < tabs.count else { return }

        // Remove current webview from hierarchy
        if selectedTabIndex >= 0, selectedTabIndex < tabs.count {
            tabs[selectedTabIndex].webView.removeFromSuperview()
        }

        selectedTabIndex = index
        let tab = tabs[index]

        // Add new tab's webview
        let wv = tab.webView
        wv.translatesAutoresizingMaskIntoConstraints = false
        webContentView.addSubview(wv)
        NSLayoutConstraint.activate([
            wv.topAnchor.constraint(equalTo: webContentView.topAnchor),
            wv.bottomAnchor.constraint(equalTo: webContentView.bottomAnchor),
            wv.leadingAnchor.constraint(equalTo: webContentView.leadingAnchor),
            wv.trailingAnchor.constraint(equalTo: webContentView.trailingAnchor),
        ])

        updateUI()
        observeProgress(for: tab)
    }

    private func openURLInNewTab(_ url: URL) {
        let tab = BrowserTab()
        tabs.append(tab)

        tab.onNewTabRequested = { [weak self] u in
            self?.openURLInNewTab(u)
        }

        selectTab(at: tabs.count - 1)
        tab.load(url)
    }

    @objc func switchToTabByNumber(_ sender: NSMenuItem) {
        let index = sender.tag - 1 // tag 1-9 -> index 0-8
        if index == 8 {
            // Cmd+9 goes to last tab (browser convention)
            selectTab(at: tabs.count - 1)
        } else {
            selectTab(at: index)
        }
    }

    @objc func selectNextTab(_ sender: Any?) {
        guard !tabs.isEmpty else { return }
        selectTab(at: (selectedTabIndex + 1) % tabs.count)
    }

    @objc func selectPreviousTab(_ sender: Any?) {
        guard !tabs.isEmpty else { return }
        selectTab(at: (selectedTabIndex - 1 + tabs.count) % tabs.count)
    }

    // MARK: - Navigation

    private func navigate(to input: String) {
        guard let tab = currentTab else { return }

        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        if let url = URL(string: trimmed), url.scheme != nil, url.host != nil {
            // Looks like a URL
            tab.load(url)
        } else if trimmed.contains(".") && !trimmed.contains(" ") {
            // Looks like a domain (e.g. "github.com")
            if let url = URL(string: "https://\(trimmed)") {
                tab.load(url)
            }
        } else {
            // Search query
            tab.loadSearch(trimmed)
        }
    }

    @objc func goBack(_ sender: Any?) {
        currentTab?.goBack()
    }

    @objc func goForward(_ sender: Any?) {
        currentTab?.goForward()
    }

    @objc func reloadPage(_ sender: Any?) {
        currentTab?.reload()
    }

    @objc func hardReloadPage(_ sender: Any?) {
        currentTab?.reloadFromOrigin()
    }

    @objc func focusAddressBar(_ sender: Any?) {
        addressBar.focus()
    }

    // MARK: - Find

    @objc func performFind(_ sender: Any?) {
        // Use WKWebView's built-in find interaction
        guard let tab = currentTab else { return }

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
        guard let tab = currentTab else { return }
        tab.setZoom(min(tab.zoomLevel + 0.1, 3.0))
    }

    @objc func zoomOut(_ sender: Any?) {
        guard let tab = currentTab else { return }
        tab.setZoom(max(tab.zoomLevel - 0.1, 0.3))
    }

    @objc func resetZoom(_ sender: Any?) {
        currentTab?.setZoom(1.0)
    }

    // MARK: - UI Updates

    private func updateUI() {
        guard let tab = currentTab else { return }
        addressBar.setURL(tab.url)
        backButton.isEnabled = tab.canGoBack
        forwardButton.isEnabled = tab.canGoForward
        window?.title = tab.title.isEmpty ? "Agent Browser" : tab.title

        let tabCount = tabs.count
        if tabCount > 1 {
            window?.title = "[\(selectedTabIndex + 1)/\(tabCount)] " + (tab.title.isEmpty ? "Agent Browser" : tab.title)
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

                // Also update nav button state and title
                self.updateUI()
            }
        }
    }
}
