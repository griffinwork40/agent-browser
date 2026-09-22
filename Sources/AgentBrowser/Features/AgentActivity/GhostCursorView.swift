import AppKit

// MARK: - Ghost Cursor View
//
// A semi-transparent overlay NSView that renders an agent's cursor position
// on top of the web content area. Shows a tinted cursor icon and agent name
// badge. Transparent to mouse events so it never blocks user interaction.
//
// Lifecycle: created/managed by GhostCursorController.
// Animation: NSAnimationContext 0.3s ease-in-out position transitions.
// Fade: auto-hides after 2s of inactivity via GhostCursorController timer.

@MainActor
final class GhostCursorView: NSView {

    // MARK: - Subviews

    private let cursorImageView = NSImageView()
    private let labelContainer  = NSView()
    private let nameLabel       = NSTextField(labelWithString: "")

    // MARK: - Layout Constants

    private enum Layout {
        static let cursorSize: CGFloat    = 28
        static let labelPadH: CGFloat     = 6
        static let labelPadV: CGFloat     = 3
        static let labelOffsetX: CGFloat  = 18
        static let labelOffsetY: CGFloat  = -10
        static let cornerRadius: CGFloat  = 5
    }

    // MARK: - Init

    init(agentColor: NSColor, agentName: String) {
        // Outer frame sized to hold cursor + badge; position is set externally.
        super.init(frame: NSRect(x: 0, y: 0, width: 120, height: 48))
        wantsLayer = true
        layer?.zPosition = 1000
        setupCursorImage(color: agentColor)
        setupLabel(text: agentName, color: agentColor)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: - Hit Test — transparent to mouse events

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    // MARK: - Setup

    private func setupCursorImage(color: NSColor) {
        let config = NSImage.SymbolConfiguration(pointSize: Layout.cursorSize,
                                                  weight: .regular)
        let symbol = NSImage(systemSymbolName: "cursorarrow", accessibilityDescription: nil)?
            .withSymbolConfiguration(config)

        // Tint to agent color; blend with white so it stays readable over dark pages.
        let blended = color.blended(withFraction: 0.35, of: .white) ?? color
        let tinted = symbol.flatMap { tintedImage($0, color: blended) }
        cursorImageView.image = tinted ?? symbol
        cursorImageView.imageScaling = .scaleProportionallyDown
        cursorImageView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(cursorImageView)

        NSLayoutConstraint.activate([
            cursorImageView.leadingAnchor.constraint(equalTo: leadingAnchor),
            cursorImageView.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            cursorImageView.widthAnchor.constraint(equalToConstant: Layout.cursorSize),
            cursorImageView.heightAnchor.constraint(equalToConstant: Layout.cursorSize),
        ])
    }

    private func setupLabel(text: String, color: NSColor) {
        // Background pill
        labelContainer.wantsLayer = true
        labelContainer.layer?.backgroundColor = color.withAlphaComponent(0.85).cgColor
        labelContainer.layer?.cornerRadius    = Layout.cornerRadius
        labelContainer.translatesAutoresizingMaskIntoConstraints = false
        addSubview(labelContainer)

        nameLabel.stringValue               = text
        nameLabel.font                      = .systemFont(ofSize: 10, weight: .semibold)
        nameLabel.textColor                 = .white
        nameLabel.backgroundColor           = .clear
        nameLabel.isBezeled                 = false
        nameLabel.isEditable                = false
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        labelContainer.addSubview(nameLabel)

        NSLayoutConstraint.activate([
            // Label inside container with horizontal/vertical padding
            nameLabel.leadingAnchor.constraint(equalTo: labelContainer.leadingAnchor,
                                               constant: Layout.labelPadH),
            nameLabel.trailingAnchor.constraint(equalTo: labelContainer.trailingAnchor,
                                                constant: -Layout.labelPadH),
            nameLabel.topAnchor.constraint(equalTo: labelContainer.topAnchor,
                                           constant: Layout.labelPadV),
            nameLabel.bottomAnchor.constraint(equalTo: labelContainer.bottomAnchor,
                                              constant: -Layout.labelPadV),

            // Container anchored relative to cursor tip
            labelContainer.leadingAnchor.constraint(equalTo: leadingAnchor,
                                                    constant: Layout.labelOffsetX),
            labelContainer.topAnchor.constraint(equalTo: topAnchor,
                                                constant: Layout.labelOffsetY),
        ])
    }

    // MARK: - Helpers

    private func tintedImage(_ source: NSImage, color: NSColor) -> NSImage? {
        let size   = source.size
        let result = NSImage(size: size)
        result.lockFocus()
        color.set()
        let rect = NSRect(origin: .zero, size: size)
        rect.fill()
        source.draw(in: rect, from: .zero, operation: .destinationIn, fraction: 1.0)
        result.unlockFocus()
        return result
    }
}
