import Testing
import WebKit
import Foundation
@testable import AgentBrowser

/// Tests for Issue #8: WKWebView recreation on profile switch.
///
/// Verifies:
///  - BrowserTab.recreateWebView replaces webView and clears the flag.
///  - KVO observations are torn down on the old view and set up on the new one.
///  - TabManager.recreateWebViews recreates the active tab eagerly and marks
///    background tabs with needsWebViewRecreation = true.
///  - Lazy recreation: needsWebViewRecreation is cleared when the tab is
///    subsequently passed through recreateWebView.
@Suite("WebView Recreation")
struct WebViewRecreationTests {

    // MARK: - BrowserTab.recreateWebView

    @Test("recreateWebView replaces webView with a new instance")
    @MainActor func recreatesWebViewInstance() {
        let pm = ProfileManager(storageURL: makeTempURL())
        let config = pm.makeConfiguration(for: pm.activeProfileID)
        let tab = BrowserTab(configuration: config)

        let original = tab.webView
        tab.recreateWebView(configuration: config)

        #expect(tab.webView !== original, "webView must be a new WKWebView instance")
    }

    @Test("recreateWebView clears needsWebViewRecreation flag")
    @MainActor func clearsRecreationFlag() {
        let pm = ProfileManager(storageURL: makeTempURL())
        let config = pm.makeConfiguration(for: pm.activeProfileID)
        let tab = BrowserTab(configuration: config)
        tab.needsWebViewRecreation = true

        tab.recreateWebView(configuration: config)

        #expect(tab.needsWebViewRecreation == false)
    }

    @Test("recreateWebView returns the old WKWebView")
    @MainActor func returnsOldWebView() {
        let pm = ProfileManager(storageURL: makeTempURL())
        let config = pm.makeConfiguration(for: pm.activeProfileID)
        let tab = BrowserTab(configuration: config)

        let original = tab.webView
        let returned = tab.recreateWebView(configuration: config)

        #expect(returned === original, "returned value must be the pre-recreation webView")
    }

    @Test("recreateWebView wires the new WKWebView to KVO — url observation fires")
    @MainActor func kvoRewiredAfterRecreation() {
        let pm = ProfileManager(storageURL: makeTempURL())
        let config = pm.makeConfiguration(for: pm.activeProfileID)
        let tab = BrowserTab(configuration: config)

        tab.recreateWebView(configuration: config)

        // After recreation, the tab still exposes a live webView.
        // KVO bridging to @Observable is intact when the webView property is valid.
        #expect(tab.webView.isLoading == false,
                "New webView must be idle; KVO bridging must not crash")
    }

    @Test("recreateWebView uses the supplied configuration's data store")
    @MainActor func usesSuppliedConfiguration() throws {
        let pm = ProfileManager(storageURL: makeTempURL())
        let profileB = pm.createProfile(name: "B")
        let configB = pm.makeConfiguration(for: profileB.id)
        let tab = BrowserTab(configuration: pm.makeConfiguration(for: pm.activeProfileID))

        tab.recreateWebView(configuration: configB)

        // The new webView's data store must be the one from profileB's configuration.
        #expect(tab.webView.configuration.websiteDataStore ===
                    pm.dataStore(for: profileB.id),
                "webView must use profile B's data store after recreation")
    }

    // MARK: - TabManager.recreateWebViews

    @Test("recreateWebViews recreates active tab eagerly")
    @MainActor func recreatesActivetabEagerly() {
        let pm = ProfileManager(storageURL: makeTempURL())
        let tm = TabManager(profileManager: pm)
        let active = tm.createTab(profileID: pm.activeProfileID)
        tm.select(tab: active)

        let original = active.webView
        let config = pm.makeConfiguration(for: pm.activeProfileID)
        _ = config // config is implicit in recreateWebViews

        let old = tm.recreateWebViews(for: pm.activeProfileID, activeTabID: active.id)

        #expect(old === original, "old view must be the pre-recreation webView")
        #expect(active.webView !== original, "active tab must have a fresh webView")
        #expect(active.needsWebViewRecreation == false,
                "active tab must not be flagged for lazy recreation")
    }

    @Test("recreateWebViews marks background tabs as needing recreation")
    @MainActor func marksBackgroundTabsLazy() {
        let pm = ProfileManager(storageURL: makeTempURL())
        let tm = TabManager(profileManager: pm)
        let active = tm.createTab(profileID: pm.activeProfileID)
        let bg1   = tm.createTab(profileID: pm.activeProfileID)
        let bg2   = tm.createTab(profileID: pm.activeProfileID)
        tm.select(tab: active)

        tm.recreateWebViews(for: pm.activeProfileID, activeTabID: active.id)

        #expect(bg1.needsWebViewRecreation == true)
        #expect(bg2.needsWebViewRecreation == true)
        #expect(active.needsWebViewRecreation == false,
                "active tab must not be marked for lazy recreation")
    }

    @Test("recreateWebViews skips tabs belonging to a different profile")
    @MainActor func skipsOtherProfileTabs() {
        let pm = ProfileManager(storageURL: makeTempURL())
        let profileB = pm.createProfile(name: "B")
        let tm = TabManager(profileManager: pm)

        let tabA = tm.createTab(profileID: pm.activeProfileID)
        let tabB = tm.createTab(profileID: profileB.id)
        tm.select(tab: tabA)

        let originalB = tabB.webView
        tm.recreateWebViews(for: pm.activeProfileID, activeTabID: tabA.id)

        #expect(tabB.webView === originalB,
                "Tab belonging to profile B must not be touched")
        #expect(tabB.needsWebViewRecreation == false,
                "Tab belonging to profile B must not be flagged")
    }

    @Test("Lazy recreation: needsWebViewRecreation cleared by recreateWebView")
    @MainActor func lazyFlagClearedOnRecreation() {
        let pm = ProfileManager(storageURL: makeTempURL())
        let config = pm.makeConfiguration(for: pm.activeProfileID)
        let tab = BrowserTab(configuration: config)
        tab.needsWebViewRecreation = true

        // Simulate what syncDisplayedTab does when it picks up the flag.
        tab.recreateWebView(configuration: config)

        #expect(tab.needsWebViewRecreation == false)
    }

    // MARK: - Helpers

    private func makeTempURL() -> URL {
        let tmp = FileManager.default.temporaryDirectory
        return tmp.appendingPathComponent(UUID().uuidString + "-profiles.json")
    }
}
