# Human UX Roadmap

Phased implementation plan designed for parallel execution by Agent AFK subagents.

---

## Phasing Strategy

Work is organized into 4 phases. Each phase contains parallel lanes. Lanes within a phase execute concurrently with minimal file overlap. A sync point exists between phases where dependent work must wait.

```
Phase 1: Foundation         (2 lanes, greenfield)
  |
  v  sync
Phase 2: Human Browser MVP  (4 lanes, parallel)
  |
  v  sync
Phase 3: Agent-Aware UX V1  (3 lanes, parallel)
  |
  v  (ship)
Phase 4: Later              (backlog, no blocking)
```

---

## Phase 1: Foundation

**Objective:** Establish the design system and domain types that all subsequent work depends on.
**Dependencies:** None (greenfield).
**Sync:** Both lanes must complete before Phase 2 begins.

### Lane A: Design System Foundation

**Objective:** Create the reusable token and primitive layer.

**Files created:**
- `Sources/AgentBrowser/DesignSystem/DesignTokens.swift`
- `Sources/AgentBrowser/DesignSystem/GlassSurface.swift`
- `Sources/AgentBrowser/DesignSystem/IconButton.swift`
- `Sources/AgentBrowser/DesignSystem/SidebarItem.swift`
- `Sources/AgentBrowser/DesignSystem/CommandField.swift`
- `Sources/AgentBrowser/DesignSystem/StatusIndicator.swift`
- `Sources/AgentBrowser/DesignSystem/ActivityBadge.swift`
- `Sources/AgentBrowser/DesignSystem/EmptyState.swift`
- `Sources/AgentBrowser/DesignSystem/PopoverContainer.swift`
- `Sources/AgentBrowser/DesignSystem/ToolbarSurface.swift`
- `Sources/AgentBrowser/DesignSystem/SectionHeader.swift`

**Files modified:** None.

**Acceptance criteria:**
- All tokens defined as static constants in DesignTokens.swift
- Each primitive is a standalone SwiftUI View with a clear public init
- Each primitive renders correctly in SwiftUI Preview
- Each primitive handles dark mode and light mode
- Each primitive has appropriate accessibilityLabel/trait
- GlassSurface falls back to opaque background when Reduce Transparency is on
- All animated components respect Reduce Motion (static fallback)
- No file exceeds 350 LOC

**Tests:** SwiftUI previews for each primitive covering default state, selected state, disabled state, dark mode.

**Estimated LOC:** ~600 across 11 files
**Complexity:** Low
**Parallel with:** Lane B (zero file overlap)

---

### Lane B: Domain Type Extraction

**Objective:** Extract pure domain types from the current BrowserTab monolith.

**Files created:**
- `Sources/AgentBrowser/BrowserCore/TabRecord.swift`
- `Sources/AgentBrowser/BrowserCore/NavigationState.swift`
- `Sources/AgentBrowser/BrowserCore/TabProvenance.swift`
- `Sources/AgentBrowser/BrowserCore/TabLifecycle.swift`
- `Sources/AgentBrowser/BrowserCore/WorkspaceRecord.swift`
- `Sources/AgentBrowser/BrowserCore/DownloadRecord.swift`

**Files modified:**
- `Sources/AgentBrowser/WebKit/BrowserTab.swift` -- extract domain state to TabRecord; keep WKWebView wrapper
- `Sources/AgentBrowser/WebKit/TabManager.swift` -- reference TabRecord for identity

**Acceptance criteria:**
- TabRecord is Sendable, Codable, has zero framework imports
- NavigationState is Sendable, has zero framework imports
- TabProvenance enum defined with .human, .agent, .restored cases
- TabLifecycle enum defined with .empty through .crashed
- BrowserTab still functions as before but references TabRecord for identity
- All existing tests pass without modification
- No file exceeds 350 LOC

**Tests:** Unit tests for TabRecord, NavigationState, TabProvenance encoding/decoding.

**Estimated LOC:** ~400 across 8 files
**Complexity:** Medium (refactoring existing code)
**Parallel with:** Lane A (different directories)

---

## Phase 2: Human Browser MVP

**Objective:** Make Agent Browser genuinely pleasant as a normal browser.
**Dependencies:** Phase 1 complete (tokens and domain types available).
**Sync:** All 4 lanes must complete before Phase 3 begins.

### Lane C: Sidebar + Tab Bar

**Objective:** Vertical tab sidebar with SwiftUI.

**Files created:**
- `Sources/AgentBrowser/Features/Sidebar/TabSidebarView.swift`
- `Sources/AgentBrowser/Features/Sidebar/TabRowView.swift`
- `Sources/AgentBrowser/Features/Sidebar/SidebarHeaderView.swift`
- `Sources/AgentBrowser/Features/Sidebar/PinnedTabsSection.swift`

**Files modified:**
- `Sources/AgentBrowser/Window/BrowserWindowController.swift` -- add sidebar split layout with NSHostingController

**Acceptance criteria:**
- Vertical tab list showing favicon + title + close button per tab
- Click tab to switch; visual selection highlight
- Drag to reorder tabs
- Pinned tabs section at top (always visible, not scrolled)
- Sidebar collapse/expand with Cmd-Shift-L keyboard shortcut
- Hover to expand when collapsed (200ms delay)
- Loading indicator on tab row (replacing favicon temporarily)
- Tab count visible in section header
- Works with 100 tabs without frame drops (List with fixed 40pt row height)
- NSHostingController sizingOptions = [] to prevent layout fights
- No NSSplitViewController (manual NSView frame layout for split)

**Tests:** SwiftUI preview for TabRowView in all states. Integration test for tab switch via sidebar click.

**Estimated LOC:** ~500 across 5 files
**Complexity:** Medium
**Parallel with:** Lanes D, E, F
**Overlap:** BrowserWindowController.swift (Lane C adds sidebar at TOP of layout; coordinate with Lane D for toolbar)

---

### Lane D: Omnibox Upgrade

**Objective:** Address bar with autocomplete, proper URL/search detection, Cmd-L excellence.

**Files created:**
- `Sources/AgentBrowser/Features/Omnibox/AutocompleteDropdown.swift`

**Files modified:**
- `Sources/AgentBrowser/UI/AddressBar.swift` -- major upgrade
- `Sources/AgentBrowser/Window/BrowserWindowController.swift` -- address bar wiring updates

**Acceptance criteria:**
- Cmd-L selects all text and focuses the address bar
- URL detection: input with scheme + host navigates directly
- Search detection: input with spaces or no dots searches via default engine
- Domain completion: typing "git" suggests "github.com" from history (when persistence available)
- Open tab search: type partial title and matching open tabs appear in suggestions
- HTTPS lock icon in address bar
- Full URL displayed (developer audience -- no simplified display)
- Escape cancels editing and restores previous URL
- Enter on autocomplete suggestion navigates to it
- Autocomplete dropdown positions below address bar (NSPanel child window)

**Tests:** Unit tests for URL/search detection logic. Integration test for Cmd-L focus.

**Estimated LOC:** ~300 across 3 files
**Complexity:** Medium
**Parallel with:** Lanes C, E, F
**Overlap:** BrowserWindowController.swift (Lane D modifies EXISTING setupAddressBar; non-overlapping with Lane C's sidebar addition)

---

### Lane E: Persistence Layer

**Objective:** History, bookmarks, session restoration.

**Files created:**
- `Sources/AgentBrowser/Persistence/DatabaseSetup.swift`
- `Sources/AgentBrowser/Persistence/HistoryStore.swift`
- `Sources/AgentBrowser/Persistence/BookmarkStore.swift`
- `Sources/AgentBrowser/Persistence/SessionStore.swift`
- `Sources/AgentBrowser/Persistence/Migrations/V1.swift`

**Files modified:**
- `Sources/AgentBrowser/App/AppDelegate.swift` -- wire stores at launch, session save on quit
- `Package.swift` -- add GRDB dependency

**Acceptance criteria:**
- GRDB DatabasePool initialized at app launch with WAL mode
- History entry written on every navigation commit (from NavigationCoordinator)
- History searchable via FTS5 full-text search
- Bookmarks: add/remove/organize in folders
- Session restore: save all tab URLs + selectedTabID on quit, restore on launch
- interactionState captured for cold tabs (binary files in TabState/ directory)
- Debounced session saves every 30 seconds during use
- 90-day history retention with FTS5 index; older rows archived
- In-memory database for tests

**Tests:** Unit tests with in-memory DatabaseQueue for each store. Integration test for save/restore cycle.

**Estimated LOC:** ~600 across 6 files
**Complexity:** High (new dependency, migration system, multiple stores)
**Parallel with:** Lanes C, D, F
**Overlap:** AppDelegate.swift (Lane E adds store initialization; Lane F adds menu items -- non-overlapping methods)

---

### Lane F: Browser Polish

**Objective:** Daily-driver quality. Everything needed to use Agent Browser as a primary browser for a week.

**Files modified:**
- `Sources/AgentBrowser/WebKit/BrowserTab.swift` -- lazy WebView, lifecycle states, interactionState
- `Sources/AgentBrowser/WebKit/TabManager.swift` -- LRU demotion logic, tab lifecycle management
- `Sources/AgentBrowser/WebKit/DownloadHandler.swift` -- progress tracking, UI integration
- `Sources/AgentBrowser/Window/BrowserWindowController.swift` -- keyboard shortcuts, find, zoom, stop button
- `Sources/AgentBrowser/App/AppDelegate.swift` -- complete menu bar with all shortcuts

**Acceptance criteria:**
- Tab lifecycle implemented: .empty / .loading / .live / .suspended / .cold
- Lazy WebView creation (WKWebView not created until first navigation)
- Suspended tabs: inactiveSchedulingPolicy = .suspend after 5 min background
- Cold tabs: interactionState captured, WebView at about:blank after 15 min
- LRU demotion runs every 60 seconds
- Full keyboard shortcut set (30+ shortcuts from accessibility audit)
- Native find in page using WKWebView.find API (not JS window.find)
- Zoom in/out/reset working
- Reload button toggles to stop (X icon) when loading
- Downloads with progress tracking and open-in-Finder
- Middle-click opens link in new tab (via UICoordinator popup handling)
- Context menus on web content
- Camera/microphone permission prompts for WebRTC
- Print (Cmd-P) working

**Tests:** Unit tests for LRU logic. Integration tests for lifecycle state transitions.

**Estimated LOC:** ~400 modifications across 5 files
**Complexity:** Medium
**Parallel with:** Lanes C, D, E
**Overlap:** BrowserWindowController.swift (Lane F adds keyboard shortcut METHODS; Lane C adds sidebar LAYOUT -- different code regions)

---

## Phase 3: Agent-Aware UX V1

**Objective:** The smallest set of human-agent interactions that make Agent Browser distinct.
**Dependencies:** Phase 2 complete (sidebar + tab display must exist for agent indicators).

**Pre-requisite cleanup:** Decompose `BrowserAutomationService.swift` (749 lines) before Phase 3:
- Extract tab operations into `TabOperationRouter.swift`
- Extract page operations into `PageOperationRouter.swift`
- Keep BrowserAutomationService as thin dispatcher

### Lane G: Agent Activity Domain Model

**Objective:** Domain types and stores for agent activity tracking.

**Files created:**
- `Sources/AgentBrowser/AgentIntegration/AgentActivityStore.swift`
- `Sources/AgentBrowser/AgentIntegration/AgentRegistry.swift`
- `Sources/AgentBrowser/AgentIntegration/ActionLog.swift`
- `Sources/AgentBrowser/BrowserCore/AgentConnection.swift`
- `Sources/AgentBrowser/BrowserCore/AgentAction.swift`

**Files modified:**
- `Sources/AgentBrowser/Automation/BrowserAutomationService.swift` -- emit agent actions to ActivityStore
- `Sources/AgentBrowser/Automation/AgentHTTPServer.swift` -- register connections in AgentRegistry

**Acceptance criteria:**
- AgentActivityStore tracks connected agents and in-flight actions (@Observable @MainActor)
- Every agent API call logged as AgentAction with agentID, tabID, method, timestamp
- Tab provenance set on agent-created tabs via `TabRecord.provenance`
- Action log persisted to agent.db via GRDB
- Multiple simultaneous agent connections supported and tracked
- Agent identity (name, color) assigned from fixed palette on connect

**Tests:** Unit tests for AgentActivityStore. Integration test for action logging round-trip.

**Estimated LOC:** ~400 across 7 files
**Complexity:** Medium
**Parallel with:** Lanes H, I

---

### Lane H: Agent Activity UI

**Objective:** Visual indicators for agent activity in the sidebar and toolbar.

**Files created:**
- `Sources/AgentBrowser/Features/AgentActivity/AgentIndicator.swift`
- `Sources/AgentBrowser/Features/AgentActivity/AgentActivityPopover.swift`
- `Sources/AgentBrowser/Features/AgentActivity/ProvenanceBadge.swift`
- `Sources/AgentBrowser/Features/AgentActivity/ControlStatusView.swift`

**Files modified:**
- `Sources/AgentBrowser/Features/Sidebar/TabRowView.swift` -- add AgentIndicator and ProvenanceBadge
- `Sources/AgentBrowser/Window/BrowserWindowController.swift` -- add ControlStatusView when agent active

**Acceptance criteria:**
- Colored left border (3px) on tab row when agent is active
- Blue pulsing for working, yellow static for needs-human, green flash for done
- ProvenanceBadge (subtle robot icon) on agent-created tabs
- Agent activity popover on click: current action, step log, agent name, Pause/Resume/End
- ControlStatusView in toolbar area when agent active on focused tab: agent name + "Take Control"
- Reduce Motion: no pulsing, static color changes only
- High Contrast: agent states distinguished by shape as well as color

**Tests:** SwiftUI previews for each state (working, needs-human, done, error, idle).

**Estimated LOC:** ~350 across 6 files
**Complexity:** Low
**Parallel with:** Lanes G, I

---

### Lane I: Human Takeover State Machine

**Objective:** Implement touch-to-takeover, stop, resume, soft gate.

**Files created:**
- `Sources/AgentBrowser/AgentIntegration/TabControlState.swift`
- `Sources/AgentBrowser/AgentIntegration/TakeoverHandler.swift`

**Files modified:**
- `Sources/AgentBrowser/Automation/BrowserAutomationService.swift` -- check control state before dispatching actions
- `Sources/AgentBrowser/Automation/AgentHTTPServer.swift` -- interrupt/resume API endpoints
- `Sources/AgentBrowser/Window/BrowserWindowController.swift` -- intercept human events for takeover detection

**Acceptance criteria:**
- Click/type/navigate in agent-controlled tab triggers immediate takeover
- Scroll does NOT trigger takeover
- Agent receives structured interrupt signal via API
- Agent completes current atomic action before yielding (click completes, fill finishes field)
- Resume button re-enables agent on the tab
- 2-second soft gate on detected form submit / purchase / delete actions
- State machine: IDLE > AGENT_ACTIVE > INTERRUPTING > HUMAN_OWNS > (resume) AGENT_ACTIVE
- Non-blocking "You have control" banner on takeover (auto-dismiss 3s)
- API endpoints: POST /api/interrupt (agent receives), POST /api/resume (agent sends)

**Tests:** Unit tests for state machine transitions (all edges). Integration test for takeover flow.

**Estimated LOC:** ~350 across 5 files
**Complexity:** High (event interception, API protocol, race conditions)
**Parallel with:** Lanes G, H

---

## Phase 4: Later

Explicitly NOT blocking the initial ship. Ranked by product value.

| Priority | Feature | Complexity | Notes |
|---|---|---|---|
| 1 | Command palette (Cmd-K) | Medium | Search tabs, history, bookmarks, commands |
| 2 | Task/workspace tab grouping | High | Auto-group by sessionTag; visual clusters |
| 3 | Multiple windows | High | WindowSession per window, AppStore coordinates |
| 4 | Ghost cursor | Medium | Semi-transparent agent cursor; needs protocol extension |
| 5 | Content search across tabs | Medium | FTS across all open tab text |
| 6 | Tab thumbnails | Medium | Hover preview; performance spike needed |
| 7 | Agent permissions per agent | Medium | Read/write/click capability restrictions |
| 8 | Web extensions | High | WKWebExtensionController (macOS 15.4+) |
| 9 | Content blocking | Medium | WKContentRuleListStore with EasyList |
| 10 | AppleScript dictionary | Low | Basic tab/navigation scripting |

---

## File Overlap Matrix

| Lane | Creates | Modifies | Overlaps With |
|---|---|---|---|
| A (Design System) | DesignSystem/* (11 files) | None | None |
| B (Domain Types) | BrowserCore/* (6 files) | BrowserTab, TabManager | None |
| C (Sidebar) | Features/Sidebar/* (4 files) | BrowserWindowController | D, F (coordinate) |
| D (Omnibox) | Features/Omnibox/* (1 file) | AddressBar, BrowserWindowController | C, F (coordinate) |
| E (Persistence) | Persistence/* (5 files) | AppDelegate, Package.swift | F (coordinate AppDelegate) |
| F (Browser Polish) | None | BrowserTab, TabManager, BWC, AppDelegate, DownloadHandler | C, D, E (coordinate) |
| G (Agent Domain) | AgentIntegration/*, BrowserCore/* (5+2 files) | BAS, AgentHTTPServer | I (coordinate) |
| H (Agent UI) | Features/AgentActivity/* (4 files) | TabRowView, BrowserWindowController | None new |
| I (Takeover) | AgentIntegration/* (2 files) | BAS, AgentHTTPServer, BWC | G (coordinate) |

### Coordination Protocol for BrowserWindowController.swift

This file is the primary contention point. Resolution by region:

1. **Lane C:** Adds sidebar split at the TOP of `setupLayout()` -- new NSView for sidebar, new NSHostingController
2. **Lane D:** Modifies EXISTING `setupAddressBar()` method -- changes within the method
3. **Lane F:** Adds keyboard shortcut action METHODS (`@objc func` blocks) at the bottom
4. **Lane H:** Adds ControlStatusView BELOW the toolbar area in layout

Each lane works on clearly separated methods. Merge conflicts are structural (method ordering), not semantic (same code changed).

### BrowserAutomationService.swift Decomposition

This 749-line file MUST be decomposed before Phase 3 begins:

- `TabOperationRouter.swift` -- tabs.list, tabs.open, tabs.close, tabs.switch
- `PageOperationRouter.swift` -- page.read, page.eval, page.screenshot, page.metadata
- `InteractiveRouter.swift` -- page.inspect, page.click, page.fill, page.press, page.select, page.wait
- `BrowserAutomationService.swift` -- thin dispatcher that routes to the above

This decomposition is a prerequisite task between Phase 2 and Phase 3.
