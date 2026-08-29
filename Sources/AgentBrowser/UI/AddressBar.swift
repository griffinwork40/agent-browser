import AppKit

/// URL/search text field. Handles Enter to navigate, Escape to cancel.
final class AddressBar: NSTextField {

    var onNavigate: ((String) -> Void)?

    init() {
        super.init(frame: .zero)
        setup()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

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
    }

    @objc private func handleAction() {
        let text = stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        onNavigate?(text)

        // Resign first responder so keyboard goes back to web content
        window?.makeFirstResponder(nil)
    }

    func setURL(_ url: URL?) {
        // Only update if user is not actively editing
        guard window?.firstResponder != currentEditor() else { return }
        stringValue = url?.absoluteString ?? ""
    }

    func focus() {
        window?.makeFirstResponder(self)
        selectText(nil)
    }

    // Select all text when the field gets focus
    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        if result {
            // Defer selectAll to avoid timing issues
            DispatchQueue.main.async { [weak self] in
                self?.selectText(nil)
            }
        }
        return result
    }

    // Escape key resigns focus
    override func cancelOperation(_ sender: Any?) {
        window?.makeFirstResponder(nil)
    }
}
