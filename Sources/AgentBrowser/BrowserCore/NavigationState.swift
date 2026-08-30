import Foundation

/// Snapshot of a tab's navigation status at a point in time.
/// Pure value type — no framework dependencies.
struct NavigationState: Sendable, Equatable {
    var url: URL?
    var title: String
    var isLoading: Bool
    var loadProgress: Double
    var canGoBack: Bool
    var canGoForward: Bool
    var isSecure: Bool
    var zoomLevel: Double

    /// The "new tab" baseline state.
    static let empty = NavigationState(
        url: nil,
        title: "New Tab",
        isLoading: false,
        loadProgress: 0,
        canGoBack: false,
        canGoForward: false,
        isSecure: false,
        zoomLevel: 1.0
    )

    /// The committed URL. Exists as a named property so callers don't need to
    /// distinguish between the displayed URL and the WKWebView's provisionalURL —
    /// future phases can add a `provisionalURL` here without breaking call sites.
    var displayURL: URL? { url }
}
