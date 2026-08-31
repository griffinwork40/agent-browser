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
               url.host != nil,
               url.user == nil {   // reject credential syntax e.g. https://evil.com@good.com
                return .navigate(url)
            }

            // Looks like a bare domain (has dots, no spaces, doesn't start with "?")
            if trimmed.contains(".") && !trimmed.contains(" ") && !trimmed.hasPrefix("?") {
                if let url = URL(string: "https://\(trimmed)"),
                   url.user == nil {   // reject credential syntax e.g. evil.com@good.com
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

    /// The raw URL being displayed (without the security prefix).
    private var rawURL: String = ""

    /// Attributed-string prefix shown when a page is HTTPS. Uses an SF Symbol
    /// image attachment so we avoid emoji rendering inconsistencies.
    private static let lockAttachment: NSAttributedString = {
        // Build a small lock.fill symbol at caption size, tinted with the system
        // secondary label color so it adapts to light/dark mode automatically.
        let config = NSImage.SymbolConfiguration(pointSize: 11, weight: .regular)
        let image = NSImage(systemSymbolName: "lock.fill", accessibilityDescription: "Secure")?
            .withSymbolConfiguration(config) ?? NSImage()
        let attachment = NSTextAttachment()
        attachment.image = image
        // Baseline-align the icon with the text descender so it sits flush.
        attachment.bounds = CGRect(x: 0, y: -2, width: 12, height: 12)
        let str = NSMutableAttributedString(attachment: attachment)
        // Space after the icon
        str.append(NSAttributedString(string: "  "))
        return str
    }()

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
        // Strip the lock-icon prefix if present (user may have pressed Return
        // while the display value is still showing the attributed prefix)
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

    /// Apply the correct display string (with or without SF Symbol lock prefix).
    private func applyDisplay() {
        if isSecure && !rawURL.isEmpty {
            // Build an attributed string: [lock-icon + space] + URL
            let full = NSMutableAttributedString(attributedString: Self.lockAttachment)
            full.append(NSAttributedString(
                string: rawURL,
                attributes: [
                    .font: NSFont.systemFont(ofSize: 13),
                    .foregroundColor: NSColor.labelColor,
                ]
            ))
            attributedStringValue = full
        } else {
            stringValue = rawURL
            textColor = .labelColor
        }
    }

    /// Strip the leading lock attachment (up to and including the trailing spaces)
    /// from a string, returning the bare URL. The attachment renders as a Unicode
    /// object-replacement character (U+FFFC) in the plain string value.
    private func stripLockPrefix(_ s: String) -> String {
        // NSTextAttachment is represented as U+FFFC in the plain string.
        // Our prefix is: U+FFFC + "  " (two spaces) — strip all of that.
        let attachmentChar = "\u{FFFC}"
        if s.hasPrefix(attachmentChar) {
            var stripped = String(s.dropFirst())      // remove U+FFFC
            while stripped.hasPrefix(" ") {
                stripped = String(stripped.dropFirst())
            }
            return stripped
        }
        // Fallback: also handle the legacy emoji prefix in case any stale value slips through
        let legacyPrefix = "🔒 "
        if s.hasPrefix(legacyPrefix) { return String(s.dropFirst(legacyPrefix.count)) }
        return s
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
            // Show raw URL (no lock icon) while editing
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
