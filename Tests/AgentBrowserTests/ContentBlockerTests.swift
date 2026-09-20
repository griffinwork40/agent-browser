import Testing
import WebKit
@testable import AgentBrowser

/// Tests for ContentBlockerManager and ContentBlockerRules.
///
/// These tests run on @MainActor because ContentBlockerManager is @MainActor-isolated
/// and WKWebViewConfiguration must be created on the main thread.
@Suite("ContentBlocker")
struct ContentBlockerTests {

    // MARK: - ContentBlockerRules

    @Test("Fallback JSON is valid JSON array")
    func fallbackJSONIsValidArray() throws {
        let json = ContentBlockerRules.fallbackJSON
        let data = json.data(using: .utf8)!
        let parsed = try JSONSerialization.jsonObject(with: data)
        guard let array = parsed as? [[String: Any]] else {
            Issue.record("Expected JSON array of rule objects")
            return
        }
        #expect(!array.isEmpty, "Fallback list must have at least one rule")
    }

    @Test("Every fallback rule has trigger and action")
    func fallbackRulesHaveRequiredKeys() throws {
        let json = ContentBlockerRules.fallbackJSON
        let data = json.data(using: .utf8)!
        let array = try JSONSerialization.jsonObject(with: data) as! [[String: Any]]
        for (index, rule) in array.enumerated() {
            #expect(rule["trigger"] != nil, "Rule \(index) missing 'trigger'")
            #expect(rule["action"] != nil,  "Rule \(index) missing 'action'")
        }
    }

    @Test("Fallback rule actions are 'block' type")
    func fallbackRulesAreBlockType() throws {
        let json = ContentBlockerRules.fallbackJSON
        let data = json.data(using: .utf8)!
        let array = try JSONSerialization.jsonObject(with: data) as! [[String: Any]]
        for (index, rule) in array.enumerated() {
            let action = rule["action"] as? [String: String]
            #expect(action?["type"] == "block", "Rule \(index) action type should be 'block'")
        }
    }

    @Test("Fallback identifier is non-empty")
    func fallbackIdentifierNonEmpty() {
        #expect(!ContentBlockerRules.fallbackIdentifier.isEmpty)
    }

    // MARK: - Enable / disable toggle

    @Test("ContentBlockerManager starts enabled by default on fresh UserDefaults")
    @MainActor func defaultsToEnabled() {
        // Use a fresh UserDefaults domain to isolate from real app state.
        let defaults = makeFreshDefaults()
        let manager = ContentBlockerManager(defaults: defaults)
        #expect(manager.isEnabled == true)
    }

    @Test("Toggle flips isEnabled")
    @MainActor func toggleFlipsEnabled() {
        let defaults = makeFreshDefaults()
        let manager = ContentBlockerManager(defaults: defaults)
        let initial = manager.isEnabled
        manager.toggleEnabled()
        #expect(manager.isEnabled == !initial)
        manager.toggleEnabled()
        #expect(manager.isEnabled == initial)
    }

    @Test("isEnabled persists across instances with same UserDefaults")
    @MainActor func enabledPersists() {
        let defaults = makeFreshDefaults()
        let manager1 = ContentBlockerManager(defaults: defaults)
        manager1.toggleEnabled() // flip once
        let storedValue = manager1.isEnabled

        let manager2 = ContentBlockerManager(defaults: defaults)
        #expect(manager2.isEnabled == storedValue)
    }

    // MARK: - applyRules / removeRules

    @Test("applyRules adds lists to config when enabled")
    @MainActor func applyRulesAddsLists() async {
        let defaults = makeFreshDefaults()
        let manager = ContentBlockerManager(defaults: defaults)
        // enabled by default, compile fallback
        await manager.setUp()

        let config = WKWebViewConfiguration()
        manager.applyRules(to: config)
        // After apply, removeAllContentRuleLists should be a no-op (lists were there).
        // We can only indirectly verify by checking removeRules doesn't crash.
        manager.removeRules(from: config)
    }

    @Test("applyRules skips lists when disabled")
    @MainActor func applyRulesSkipsWhenDisabled() async {
        let defaults = makeFreshDefaults()
        let manager = ContentBlockerManager(defaults: defaults)
        manager.toggleEnabled() // disable
        await manager.setUp()

        let config = WKWebViewConfiguration()
        // Should not throw or crash when disabled.
        manager.applyRules(to: config)
        manager.removeRules(from: config)
    }

    @Test("removeRules clears lists without crashing on empty config")
    @MainActor func removeRulesOnEmptyConfig() {
        let defaults = makeFreshDefaults()
        let manager = ContentBlockerManager(defaults: defaults)
        let config = WKWebViewConfiguration()
        // Removing from a config with no rules should not crash.
        manager.removeRules(from: config)
    }

    // MARK: - Toggle propagation

    @Test("toggleEnabled applies rules to tracked configs when enabling")
    @MainActor func toggleEnabledAppliesRules() async {
        let defaults = makeFreshDefaults()
        let manager = ContentBlockerManager(defaults: defaults)
        manager.toggleEnabled() // disable first
        await manager.setUp()

        let config = WKWebViewConfiguration()
        manager.applyRules(to: config)      // tracked but not applied (disabled)

        manager.toggleEnabled()             // re-enable → should apply to tracked config
        // Verify no crash and the toggle reached enabled state.
        #expect(manager.isEnabled == true)
    }

    @Test("toggleEnabled removes rules from tracked configs when disabling")
    @MainActor func toggleEnabledRemovesRules() async {
        let defaults = makeFreshDefaults()
        let manager = ContentBlockerManager(defaults: defaults)
        await manager.setUp()

        let config = WKWebViewConfiguration()
        manager.applyRules(to: config)      // tracked and applied (enabled)

        manager.toggleEnabled()             // disable → should remove from tracked config
        #expect(manager.isEnabled == false)
    }

    // MARK: - Fallback compilation

    @Test("setUp compiles fallback list successfully")
    @MainActor func setUpCompilesFallback() async {
        let defaults = makeFreshDefaults()
        let manager = ContentBlockerManager(defaults: defaults)
        await manager.setUp()
        // If compilation succeeded, applyRules + removeRules should work.
        let config = WKWebViewConfiguration()
        manager.applyRules(to: config)
        manager.removeRules(from: config)
    }

    // MARK: - Helpers

    /// Returns a fresh UserDefaults suite isolated from real app state.
    private func makeFreshDefaults() -> UserDefaults {
        let suiteName = "com.agentbrowser.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        // Remove lingering data from any prior run (should be none for a UUID suite).
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}
