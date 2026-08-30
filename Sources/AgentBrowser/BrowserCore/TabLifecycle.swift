import Foundation

/// The lifecycle phase of a browser tab.
///
/// Phases are ordered roughly by resource cost:
/// `empty` → `loading` → `live` → `suspended` → `cold`
/// `crashed` is a terminal error state from which only restoration is possible.
enum TabLifecycle: String, Sendable, Codable, Hashable, CaseIterable {
    /// Created but no WKWebView allocated yet.
    case empty

    /// WKWebView created; navigation is in progress (provisional commit pending).
    case loading

    /// Page has committed; WKWebView is active and JS is running.
    case live

    /// WKWebView exists but JS execution has been paused (background tab optimization).
    case suspended

    /// Interaction state captured and serialized; WKWebView has been torn down
    /// (navigated to about:blank). Can be restored on demand.
    case cold

    /// The WKWebView's WebContent process terminated unexpectedly.
    case crashed

    // MARK: - Convenience predicates

    /// True for states from which the tab can be revived to `live`.
    var isRestorable: Bool { self == .cold || self == .crashed }

    /// True when a live WKWebView instance exists for this tab.
    var hasWebView: Bool { self != .empty && self != .cold }

    /// True when the tab is actively loading or displaying a page.
    var isActive: Bool { self == .loading || self == .live }
}
