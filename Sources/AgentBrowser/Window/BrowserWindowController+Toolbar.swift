import AppKit

/// Toolbar layout and glass background setup — extracted from BrowserWindowController
/// to keep the main file under the 350-LOC ceiling.
extension BrowserWindowController {

    /// Inserts an NSVisualEffectView as the bottom-most subview of toolbarContainer,
    /// giving the toolbar a `.titlebar` material glass background that bleeds behind the
    /// transparent titlebar to the top window edge.
    func setupToolbarGlassBackground() {
        let effect = NSVisualEffectView()
        effect.material = .titlebar       // .titlebar gives the same "bar" look AppKit
                                          // uses for its own toolbars, matching .bar in SwiftUI
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.translatesAutoresizingMaskIntoConstraints = false
        // Insert below all future subviews (buttons, address bar, progress bar)
        toolbarContainer.addSubview(effect, positioned: .below, relativeTo: nil)

        NSLayoutConstraint.activate([
            effect.topAnchor.constraint(equalTo: toolbarContainer.topAnchor),
            effect.bottomAnchor.constraint(equalTo: toolbarContainer.bottomAnchor),
            effect.leadingAnchor.constraint(equalTo: toolbarContainer.leadingAnchor),
            effect.trailingAnchor.constraint(equalTo: toolbarContainer.trailingAnchor),
        ])
    }

    func setupNavigationButtons() {
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

        // With .fullSizeContentView the traffic-light buttons sit at ~y=20 in
        // the titlebar region. Nav buttons are centered in the full 52pt toolbar
        // height, which naturally clears the traffic lights (they are at ~y=8–24).
        // The 80pt leading offset pushes them past the traffic-light cluster.
        NSLayoutConstraint.activate([
            backButton.leadingAnchor.constraint(equalTo: toolbarContainer.leadingAnchor, constant: 80),
            backButton.centerYAnchor.constraint(equalTo: toolbarContainer.centerYAnchor),
            backButton.widthAnchor.constraint(equalToConstant: ControlSize.iconButtonRegular),

            forwardButton.leadingAnchor.constraint(equalTo: backButton.trailingAnchor, constant: Spacing.px4),
            forwardButton.centerYAnchor.constraint(equalTo: toolbarContainer.centerYAnchor),
            forwardButton.widthAnchor.constraint(equalToConstant: ControlSize.iconButtonRegular),

            reloadButton.leadingAnchor.constraint(equalTo: forwardButton.trailingAnchor, constant: Spacing.px4),
            reloadButton.centerYAnchor.constraint(equalTo: toolbarContainer.centerYAnchor),
            reloadButton.widthAnchor.constraint(equalToConstant: ControlSize.iconButtonRegular),
        ])
    }

    func setupAddressBar() {
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
            addressBar.leadingAnchor.constraint(equalTo: reloadButton.trailingAnchor, constant: Spacing.px8),
            addressBar.trailingAnchor.constraint(equalTo: toolbarContainer.trailingAnchor, constant: -Spacing.px12),
            addressBar.centerYAnchor.constraint(equalTo: toolbarContainer.centerYAnchor),
            addressBar.heightAnchor.constraint(equalToConstant: 28),
        ])
    }

    func setupProgressBar() {
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
}
