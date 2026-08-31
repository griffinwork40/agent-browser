import XCTest
@testable import AgentBrowser

// MARK: - NavigationAction.classify Tests

final class NavigationActionClassifyTests: XCTestCase {

    // MARK: Helpers

    private func classify(_ input: String) -> AddressBar.NavigationAction {
        AddressBar.NavigationAction.classify(input)
    }

    // MARK: .navigate cases

    func testClassify_httpsURL_navigates() {
        let result = classify("https://example.com")
        if case .navigate(let url) = result {
            XCTAssertEqual(url.absoluteString, "https://example.com")
        } else {
            XCTFail("Expected .navigate, got \(result)")
        }
    }

    func testClassify_httpURLWithPath_navigates() {
        let result = classify("http://example.com/path")
        if case .navigate(let url) = result {
            XCTAssertTrue(url.absoluteString.hasPrefix("http://example.com"))
        } else {
            XCTFail("Expected .navigate, got \(result)")
        }
    }

    func testClassify_bareDomain_navigates() {
        // "example.com" has a dot, no spaces, doesn't start with "?" →
        // bare-domain branch prepends https://
        let result = classify("example.com")
        if case .navigate(let url) = result {
            XCTAssertEqual(url.absoluteString, "https://example.com")
        } else {
            XCTFail("Expected .navigate for bare domain, got \(result)")
        }
    }

    func testClassify_bareDomainWithPath_navigates() {
        let result = classify("example.com/path")
        if case .navigate(let url) = result {
            XCTAssertEqual(url.absoluteString, "https://example.com/path")
        } else {
            XCTFail("Expected .navigate for bare domain with path, got \(result)")
        }
    }

    // MARK: .search cases

    func testClassify_wordsWithSpace_searches() {
        let result = classify("hello world")
        if case .search(let query) = result {
            XCTAssertEqual(query, "hello world")
        } else {
            XCTFail("Expected .search for multi-word input, got \(result)")
        }
    }

    func testClassify_emptyString_searches() {
        let result = classify("")
        if case .search(let query) = result {
            XCTAssertEqual(query, "")
        } else {
            XCTFail("Expected .search for empty string, got \(result)")
        }
    }

    func testClassify_whitespaceOnly_searches() {
        // Whitespace trims to "" → .search("") via the `guard !trimmed.isEmpty` branch.
        let result = classify("   ")
        if case .search(let query) = result {
            XCTAssertEqual(query, "")
        } else {
            XCTFail("Expected .search for whitespace-only input, got \(result)")
        }
    }

    func testClassify_questionMarkPrefix_searches() {
        // Starts with "?" → bare-domain branch is skipped (hasPrefix("?") guard).
        let result = classify("?query")
        if case .search = result {
            // correct
        } else {
            XCTFail("Expected .search for ?-prefixed input, got \(result)")
        }
    }

    func testClassify_unsupportedScheme_navigatesViaBaredomainFallback() {
        // "ftp://example.com" fails the explicit-scheme guard (ftp ∉ {http,https}),
        // but it contains a dot, no spaces, and no "?" prefix, so the bare-domain
        // branch fires and prepends https://, yielding navigate(https://ftp://example.com).
        // This documents the actual runtime behavior of classify().
        let result = classify("ftp://example.com")
        if case .navigate = result {
            // expected: bare-domain branch fires
        } else {
            XCTFail("Expected .navigate via bare-domain fallback for ftp:// input, got \(result)")
        }
    }
}

// MARK: - stripLockPrefix Tests (indirect via onNavigate callback)

/// `stripLockPrefix` is `private`, so it is exercised indirectly:
/// set `stringValue` on an `AddressBar` instance to a prefixed string, then
/// invoke the private `handleAction` selector (reachable via `perform(_:)` at
/// runtime because it is `@objc`) and assert the correct URL arrives in the
/// `onNavigate` callback — proving the prefix was stripped before classify.
///
/// XCTest runs on the main thread, so AppKit objects can be created directly
/// without additional dispatch (calling `DispatchQueue.main.sync` from the main
/// thread would deadlock).
final class StripLockPrefixTests: XCTestCase {

    private var addressBar: AddressBar!

    override func setUp() {
        super.setUp()
        // XCTest already runs setUp on the main thread; no extra dispatch needed.
        addressBar = AddressBar()
    }

    override func tearDown() {
        addressBar = nil
        super.tearDown()
    }

    /// Invoke the private `handleAction` via the Objective-C runtime.
    /// `@objc private` methods remain reachable through `perform(_:)`.
    private func fireHandleAction() {
        addressBar.perform(Selector(("handleAction")))
    }

    func testStrip_objectReplacementCharPrefix_yieldsBarURL() {
        // U+FFFC + two spaces + URL is what applyDisplay writes for secure pages.
        let prefixed = "\u{FFFC}  https://example.com"
        var received: AddressBar.NavigationAction?

        addressBar.stringValue = prefixed
        addressBar.onNavigate = { received = $0 }
        fireHandleAction()

        guard let action = received else {
            XCTFail("onNavigate was not called — U+FFFC prefix may not have been stripped")
            return
        }
        if case .navigate(let url) = action {
            XCTAssertEqual(url.absoluteString, "https://example.com")
        } else {
            XCTFail("Expected .navigate after stripping U+FFFC prefix, got \(action)")
        }
    }

    func testStrip_lockEmojiPrefix_yieldsBarURL() {
        // Legacy fallback in stripLockPrefix: "🔒 " (emoji + space).
        let prefixed = "🔒 https://example.com"
        var received: AddressBar.NavigationAction?

        addressBar.stringValue = prefixed
        addressBar.onNavigate = { received = $0 }
        fireHandleAction()

        guard let action = received else {
            XCTFail("onNavigate was not called — 🔒 prefix may not have been stripped")
            return
        }
        if case .navigate(let url) = action {
            XCTAssertEqual(url.absoluteString, "https://example.com")
        } else {
            XCTFail("Expected .navigate after stripping 🔒 prefix, got \(action)")
        }
    }

    func testStrip_noPrefix_passthrough() {
        // A plain URL with no lock prefix passes through unchanged.
        var received: AddressBar.NavigationAction?

        addressBar.stringValue = "https://example.com"
        addressBar.onNavigate = { received = $0 }
        fireHandleAction()

        guard let action = received else {
            XCTFail("onNavigate was not called for plain URL")
            return
        }
        if case .navigate(let url) = action {
            XCTAssertEqual(url.absoluteString, "https://example.com")
        } else {
            XCTFail("Expected .navigate for plain https:// URL, got \(action)")
        }
    }

    func testStrip_plainHTTPSURL_unchanged() {
        // Explicit guard: stripLockPrefix must not alter a URL that carries no prefix.
        var received: AddressBar.NavigationAction?

        addressBar.stringValue = "https://example.com"
        addressBar.onNavigate = { received = $0 }
        fireHandleAction()

        if case .navigate(let url) = received {
            XCTAssertEqual(url.absoluteString, "https://example.com",
                "stripLockPrefix must not alter a URL that has no known prefix")
        } else {
            XCTFail("Expected .navigate for plain https:// URL, got \(String(describing: received))")
        }
    }
}
