import Foundation

/// Lightweight value-type that describes a loaded web extension.
///
/// This struct is intentionally free of WebKit types so it can be
/// constructed and tested without macOS 15.4 availability constraints.
struct ExtensionInfo: Identifiable, Equatable, Sendable {
    /// Stable identifier derived from the extension's manifest (or its directory URL
    /// as a fallback when the manifest lacks an explicit id field).
    let id: String

    /// Human-readable display name from the extension manifest.
    let name: String

    /// Manifest-declared version string, e.g. "1.0.0".
    let version: String

    /// Whether the extension is currently active in the ``ExtensionManager``.
    var isEnabled: Bool

    /// The on-disk location of the unpacked extension directory (or .xpi archive).
    let extensionURL: URL
}
