import AppKit

/// URL/search omnibox. Classifies input as a direct navigation or search query,
/// shows a security indicator when viewing an HTTPS page, and fires a debounced
/// change callback for future autocomplete support.
final class AddressBar: NSTextField {

    // MARK: - Navigation action

    enum NavigationAction {
        case navigate(URL)
        case search(String)

        /// Classify raw user input into a direct navigation or a search.
        static func classify(_ input: String) -> NavigationAction {
            let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return .search(trimmed) }

            // Explicit scheme + host → navigate directly
            if let url = URL(string: trimmed),
               let scheme = url.scheme,
               ["http", "https"].contains(scheme.lowercased()),
               url.host != nil {
                return .navigate(url)
            }

            // Looks like a bare domain (has dots, no spaces, doesn't start with "?")
            if trimmed.contains(".") && !trimmed.contains(" ") && !trimmed.hasPrefix("?") {
                if let url = URL(string: "https://\(trimmed)") {
                    return .navigate(url)
                }
            }

            return .search(trimmed)
        }
    }

    // MARK: - Callbacks

    /// Called when the user commits a navigation (Return key).
    var onNavigate: ((NavigationAction) -> Void)?

    /// Called on every text change (debounced ~200 ms). Hook for future autocomplete.
    var onSearchChanged: ((String) -> Void)?

    // MARK: - Security state

    private var isSecure: Bool = false

    /// The raw URL being displayed (without the prepended lock emoji).
    private var rawURL: String = ""

    // MARK: - Debounce

    private var debounceTimer: Timer?

    // MARK: - Init

    init() {
        super.init(frame: .zero)
        setup()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Setup

    private func setup() {
        placeholderString = "Search or enter URL"
        font = .systemFont(ofSize: 13)
        bezelStyle = .roundedBezel
        focusRingType = .none
        lineBreakMode = .byTruncatingTail
        usesSingleLineMode = true
        cell?.sendsActionOnEndEditing = false
        target = self
        action = #selector(handleAction)
        delegate = self
    }

    // MARK: - Commit action (Return key)

    @objc private func handleAction() {
        let text = stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        // Strip the lock-emoji prefix if present (user may have pressed Return
        // while the display value is still showing it)
        let clean = stripLockPrefix(text)
        guard !clean.isEmpty else { return }
        let action = NavigationAction.classify(clean)
        onNavigate?(action)
        window?.makeFirstResponder(nil)
    }

    // MARK: - URL display

    /// Update the displayed URL. If not editing, prepends the lock emoji when secure.
    func setURL(_ url: URL?) {
        guard window?.firstResponder != currentEditor() else { return }
        rawURL = url?.absoluteString ?? ""
        applyDisplay()
    }

    /// Update the security indicator. Call whenever the active tab's isSecure changes.
    func updateSecurityIndicator(isSecure: Bool) {
        self.isSecure = isSecure
        // Only repaint if not currently editing
        if window?.firstResponder != currentEditor() {
            applyDisplay()
        }
    }

    /// Apply the correct display string (with or without lock prefix).
    private func applyDisplay() {
        if isSecure && !rawURL.isEmpty {
            stringValue = "🔒 \(rawURL)"
            textColor = .labelColor
        } else {
            stringValue = rawURL
            textColor = .labelColor
        }
    }

    /// Strip the leading lock-emoji prefix if present, returning the bare URL/query.
    private func stripLockPrefix(_ s: String) -> String {
        let prefix = "🔒 "
        return s.hasPrefix(prefix) ? String(s.dropFirst(prefix.count)) : s
    }

    // MARK: - Focus helpers

    func focus() {
        window?.makeFirstResponder(self)
        selectText(nil)
    }

    /// Select all text when focused so typing immediately replaces it.
    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        if result {
            // Show raw URL (no emoji) while editing
            if !rawURL.isEmpty {
                stringValue = rawURL
            }
            DispatchQueue.main.async { [weak self] in
                self?.selectText(nil)
            }
        }
        return result
    }

    /// Escape key resigns focus and restores the display URL.
    override func cancelOperation(_ sender: Any?) {
        applyDisplay()
        window?.makeFirstResponder(nil)
    }
}

// MARK: - NSTextFieldDelegate (debounced change callbacks)

extension AddressBar: NSTextFieldDelegate {
    func controlTextDidChange(_ obj: Notification) {
        debounceTimer?.invalidate()
        debounceTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: false) { [weak self] _ in
            guard let self else { return }
            let current = self.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            self.onSearchChanged?(self.stripLockPrefix(current))
        }
    }
}
