import Testing
import Foundation
@testable import AgentBrowser

// MARK: - TabControlState FSM Tests

@Suite("TabControlState")
struct TabControlStateTests {

    // MARK: - Initial state

    @Test("Initial state is idle")
    @MainActor func initialStateIsIdle() {
        let state = TabControlState(tabID: UUID())
        #expect(state.state == .idle)
        #expect(state.activeAgentID == nil)
        #expect(state.interruptTrigger == nil)
    }

    // MARK: - Valid transitions

    @Test("idle -> agentActive via agentBegins")
    @MainActor func idleToAgentActive() {
        let state = TabControlState(tabID: UUID())
        let success = state.agentBegins(agentID: "agent-1")
        #expect(success == true)
        #expect(state.state == .agentActive)
        #expect(state.activeAgentID == "agent-1")
    }

    @Test("agentActive -> interrupting via humanInterrupts")
    @MainActor func agentActiveToInterrupting() {
        let state = TabControlState(tabID: UUID())
        state.agentBegins(agentID: "agent-1")
        state.humanInterrupts(trigger: .click)
        #expect(state.state == .interrupting)
        #expect(state.interruptTrigger == .click)
    }

    @Test("interrupting -> humanOwns via agentCompletes")
    @MainActor func interruptingToHumanOwns() {
        let state = TabControlState(tabID: UUID())
        state.agentBegins(agentID: "agent-1")
        state.humanInterrupts(trigger: .explicit)
        state.agentCompletes()
        #expect(state.state == .humanOwns)
    }

    @Test("agentActive -> idle via agentCompletes (no interrupt)")
    @MainActor func agentActiveToIdleNormal() {
        let state = TabControlState(tabID: UUID())
        state.agentBegins(agentID: "agent-1")
        state.agentCompletes()
        #expect(state.state == .idle)
        #expect(state.activeAgentID == nil)
    }

    @Test("agentActive -> error via agentFailed")
    @MainActor func agentActiveToError() {
        let state = TabControlState(tabID: UUID())
        state.agentBegins(agentID: "agent-1")
        state.agentFailed()
        #expect(state.state == .error)
    }

    @Test("interrupting -> error via agentFailed")
    @MainActor func interruptingToError() {
        let state = TabControlState(tabID: UUID())
        state.agentBegins(agentID: "agent-1")
        state.humanInterrupts(trigger: .click)
        #expect(state.state == .interrupting)
        state.agentFailed()
        #expect(state.state == .error)
        #expect(state.activeAgentID == nil)
    }

    @Test("humanEnds from error resets to idle")
    @MainActor func humanEndsFromError() {
        let state = TabControlState(tabID: UUID())
        state.agentBegins(agentID: "agent-1")
        state.agentFailed()
        #expect(state.state == .error)
        state.humanEnds()
        #expect(state.state == .idle)
        #expect(state.activeAgentID == nil)
        #expect(state.interruptTrigger == nil)
    }

    @Test("error -> idle via acknowledgeError")
    @MainActor func errorToIdle() {
        let state = TabControlState(tabID: UUID())
        state.agentBegins(agentID: "agent-1")
        state.agentFailed()
        state.acknowledgeError()
        #expect(state.state == .idle)
        #expect(state.activeAgentID == nil)
    }

    @Test("humanOwns -> agentActive via humanResumes")
    @MainActor func humanOwnsToAgentActive() {
        let state = TabControlState(tabID: UUID())
        state.agentBegins(agentID: "agent-1")
        state.humanInterrupts(trigger: .navigate)
        state.agentCompletes()  // -> humanOwns
        #expect(state.state == .humanOwns)
        state.humanResumes()
        #expect(state.state == .agentActive)
    }

    @Test("humanEnds resets to idle from any state")
    @MainActor func humanEndsFromAnyState() {
        let state = TabControlState(tabID: UUID())
        state.agentBegins(agentID: "agent-1")
        state.humanInterrupts(trigger: .type)
        state.humanEnds()
        #expect(state.state == .idle)
        #expect(state.activeAgentID == nil)
        #expect(state.interruptTrigger == nil)
    }

    // MARK: - Invalid transitions rejected

    @Test("agentBegins rejected when not idle (agentActive)")
    @MainActor func agentBeginsRejectedWhenNotIdle_agentActive() {
        let state = TabControlState(tabID: UUID())
        state.agentBegins(agentID: "agent-1")
        let second = state.agentBegins(agentID: "agent-2")
        // Should reject — tab already has an agent
        #expect(second == false)
        #expect(state.activeAgentID == "agent-1")
    }

    @Test("agentBegins rejected when interrupting")
    @MainActor func agentBeginsRejectedWhenInterrupting() {
        let state = TabControlState(tabID: UUID())
        state.agentBegins(agentID: "agent-1")
        state.humanInterrupts(trigger: .click)
        #expect(state.state == .interrupting)
        let result = state.agentBegins(agentID: "agent-2")
        #expect(result == false)
        #expect(state.activeAgentID == "agent-1")
    }

    @Test("agentBegins rejected when humanOwns")
    @MainActor func agentBeginsRejectedWhenHumanOwns() {
        let state = TabControlState(tabID: UUID())
        state.agentBegins(agentID: "agent-1")
        state.humanInterrupts(trigger: .explicit)
        state.agentCompletes()  // -> humanOwns
        let result = state.agentBegins(agentID: "agent-2")
        #expect(result == false)
    }

    @Test("humanInterrupts ignored when not agentActive")
    @MainActor func humanInterruptsIgnoredWhenIdle() {
        let state = TabControlState(tabID: UUID())
        // From idle — should be a no-op
        state.humanInterrupts(trigger: .click)
        #expect(state.state == .idle)
        #expect(state.interruptTrigger == nil)
    }

    @Test("humanResumes ignored when not humanOwns")
    @MainActor func humanResumesIgnoredWhenIdle() {
        let state = TabControlState(tabID: UUID())
        state.humanResumes()
        #expect(state.state == .idle)
    }

    @Test("acknowledgeError ignored when not in error state")
    @MainActor func acknowledgeErrorIgnoredWhenIdle() {
        let state = TabControlState(tabID: UUID())
        state.acknowledgeError()
        #expect(state.state == .idle)
    }

    // MARK: - lastTransitionAt advances

    @Test("lastTransitionAt advances on each transition")
    @MainActor func transitionTimestampAdvances() async throws {
        let state = TabControlState(tabID: UUID())
        let t0 = state.lastTransitionAt
        // Small sleep to ensure clock advances
        try await Task.sleep(nanoseconds: 5_000_000)
        state.agentBegins(agentID: "agent-1")
        let t1 = state.lastTransitionAt
        #expect(t1 > t0)
    }

    // MARK: - shouldTriggerTakeover

    @Test("shouldTriggerTakeover returns true for all triggers")
    @MainActor func shouldTriggerTakeoverForAllTriggers() {
        let triggers: [InterruptTrigger] = [.click, .type, .navigate, .contextMenu, .explicit]
        for trigger in triggers {
            #expect(TabControlState.shouldTriggerTakeover(trigger) == true,
                    "Expected true for trigger \(trigger)")
        }
    }
}

// MARK: - ProfileManager Tests

@Suite("ProfileManager")
struct ProfileManagerTests {

    @Test("Default profile is created on init")
    @MainActor func defaultProfileCreated() {
        let pm = makeTestProfileManager()
        #expect(!pm.profiles.isEmpty)
        #expect(pm.activeProfile != nil)
    }

    @Test("createProfile adds a profile")
    @MainActor func createProfileAddsProfile() {
        let pm = makeTestProfileManager()
        let initialCount = pm.profiles.count
        let p = pm.createProfile(name: "Work")
        #expect(pm.profiles.count == initialCount + 1)
        #expect(pm.profiles.contains { $0.id == p.id })
    }

    @Test("switchTo changes the active profile")
    @MainActor func switchToChangesActive() {
        let pm = makeTestProfileManager()
        let p2 = pm.createProfile(name: "Personal")
        pm.switchTo(profileID: p2.id)
        #expect(pm.activeProfileID == p2.id)
        #expect(pm.activeProfile?.id == p2.id)
    }

    @Test("switchTo unknown ID is a no-op")
    @MainActor func switchToUnknownIsNoOp() {
        let pm = makeTestProfileManager()
        let originalID = pm.activeProfileID
        pm.switchTo(profileID: UUID())
        #expect(pm.activeProfileID == originalID)
    }

    @Test("deleteProfile prevents deleting last profile")
    @MainActor func deleteLastProfilePrevented() async {
        let pm = makeTestProfileManager()
        #expect(pm.profiles.count == 1)
        let lastID = pm.profiles[0].id
        await pm.deleteProfile(id: lastID)
        // Guard: profiles.count > 1 prevents deletion
        #expect(pm.profiles.count == 1)
        #expect(pm.activeProfileID == lastID)
    }

    @Test("deleteProfile removes a non-last profile")
    @MainActor func deleteNonLastProfile() async {
        let pm = makeTestProfileManager()
        let p2 = pm.createProfile(name: "Work")
        #expect(pm.profiles.count == 2)
        await pm.deleteProfile(id: p2.id)
        #expect(pm.profiles.count == 1)
        #expect(!pm.profiles.contains { $0.id == p2.id })
    }

    @Test("deleteProfile switches active profile when active is deleted")
    @MainActor func deleteActiveSwitchesProfile() async {
        let pm = makeTestProfileManager()
        let p2 = pm.createProfile(name: "Work")
        pm.switchTo(profileID: p2.id)
        #expect(pm.activeProfileID == p2.id)
        await pm.deleteProfile(id: p2.id)
        // Active should now be p1 (profiles[0])
        #expect(pm.activeProfileID != p2.id)
        #expect(!pm.profiles.isEmpty)
    }

    @Test("updateProfile reflects the change")
    @MainActor func updateProfile() {
        let pm = makeTestProfileManager()
        let original = pm.profiles[0]
        let renamed = ProfileRecord(id: original.id, name: "Renamed", colorName: "red",
                                    email: original.email, avatarURL: original.avatarURL,
                                    createdAt: original.createdAt)
        pm.updateProfile(renamed)
        #expect(pm.profiles[0].name == "Renamed")
    }

    @Test("dataStore returns the same store for the same profile")
    @MainActor func dataStoreIsCached() {
        let pm = makeTestProfileManager()
        let id = pm.activeProfileID
        let store1 = pm.dataStore(for: id)
        let store2 = pm.dataStore(for: id)
        // Identity check — must be the same WKWebsiteDataStore instance
        #expect(store1 === store2)
    }

    // MARK: - Helpers

    /// Creates an isolated ProfileManager backed by a fresh temp directory so
    /// tests never share on-disk state with each other or with the real app.
    @MainActor
    private func makeTestProfileManager() -> ProfileManager {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        return ProfileManager(storageURL: tmp.appendingPathComponent("profiles.json"))
    }
}

// MARK: - TakeoverHandler Tests

@Suite("TakeoverHandler")
struct TakeoverHandlerTests {

    @Test("controlState returns the same instance for the same tabID")
    @MainActor func controlStateIsCached() {
        let handler = TakeoverHandler()
        let id = UUID()
        let s1 = handler.controlState(for: id)
        let s2 = handler.controlState(for: id)
        #expect(s1 === s2)
    }

    @Test("processHumanEvent triggers takeover when agent is active")
    @MainActor func processHumanEventTriggersWhenAgentActive() {
        let handler = TakeoverHandler()
        let tabID = UUID()
        handler.beginAgentAction(tabID: tabID, agentID: "bot-1")
        let triggered = handler.processHumanEvent(tabID: tabID, trigger: .click)
        #expect(triggered == true)
        #expect(handler.controlState(for: tabID).state == .interrupting)
    }

    @Test("processHumanEvent is no-op when agent is not active")
    @MainActor func processHumanEventNoOpWhenIdle() {
        let handler = TakeoverHandler()
        let tabID = UUID()
        let triggered = handler.processHumanEvent(tabID: tabID, trigger: .click)
        #expect(triggered == false)
        #expect(handler.controlState(for: tabID).state == .idle)
    }

    @Test("canAgentAct returns true when idle")
    @MainActor func canAgentActWhenIdle() {
        let handler = TakeoverHandler()
        let tabID = UUID()
        #expect(handler.canAgentAct(on: tabID) == true)
    }

    @Test("canAgentAct returns false when humanOwns")
    @MainActor func canAgentActFalseWhenHumanOwns() {
        let handler = TakeoverHandler()
        let tabID = UUID()
        handler.beginAgentAction(tabID: tabID, agentID: "bot")
        handler.processHumanEvent(tabID: tabID, trigger: .explicit)
        handler.completeAgentAction(tabID: tabID)  // -> humanOwns
        #expect(handler.canAgentAct(on: tabID) == false)
    }

    @Test("agentControlledTabs lists tabs with agentActive state")
    @MainActor func agentControlledTabsList() {
        let handler = TakeoverHandler()
        let id1 = UUID()
        let id2 = UUID()
        handler.beginAgentAction(tabID: id1, agentID: "bot")
        handler.beginAgentAction(tabID: id2, agentID: "bot")
        let controlled = handler.agentControlledTabs
        #expect(controlled.contains(id1))
        #expect(controlled.contains(id2))
    }

    @Test("removeTab cleans up the state")
    @MainActor func removeTabCleansUp() {
        let handler = TakeoverHandler()
        let tabID = UUID()
        handler.beginAgentAction(tabID: tabID, agentID: "bot")
        handler.removeTab(tabID)
        // After removal the tab should have fresh idle state
        let state = handler.controlState(for: tabID)
        #expect(state.state == .idle)
    }

    @Test("humanOwnedTabs lists tabs with humanOwns state")
    @MainActor func humanOwnedTabsList() {
        let handler = TakeoverHandler()
        let tabID = UUID()
        handler.beginAgentAction(tabID: tabID, agentID: "bot")
        handler.processHumanEvent(tabID: tabID, trigger: .explicit)
        handler.completeAgentAction(tabID: tabID)  // -> humanOwns
        #expect(handler.humanOwnedTabs.contains(tabID))
        #expect(!handler.agentControlledTabs.contains(tabID))
    }
}
