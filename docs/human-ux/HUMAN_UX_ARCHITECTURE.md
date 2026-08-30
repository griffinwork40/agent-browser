# Human UX Architecture

Implementation architecture for the Agent Browser human UX redesign.

---

## Module Boundaries

### Dependency Graph

```
DesignSystem          (zero deps)
  ^
  |
BrowserCore           (pure types, no framework imports)
  ^         ^         ^
  |         |         |
BrowserEngine  Persistence  AgentIntegration
(WebKit)       (GRDB)       (Network)
  ^         ^         ^
  |         |         |
  +----+----+---------+
       |
  Features/*          (SwiftUI + upstream modules)
       ^
       |
  Window              (AppKit + everything above)
```

Arrows point from consumer to dependency. No module may import a peer or a downstream module.

---

## DesignSystem/

**Zero external dependencies.** Contains design tokens and generic SwiftUI primitives that have no browser knowledge.

### Files

| File | Contents |
|---|---|
| `DesignTokens.swift` | Static constants: Spacing (4pt grid), Typography, Radius, Materials, Motion, ControlSize, Opacity, Shadow. SwiftUI `EnvironmentKey` for token bundle injection. |
| `GlassSurface.swift` | Material container with radius, shadow, Reduce Transparency fallback |
| `IconButton.swift` | Tappable icon with hover/press feedback, tooltip, disabled state |
| `SidebarItem.swift` | Selectable row: leading icon, label, trailing badge, disclosure |
| `CommandField.swift` | Search/address/command input with clear button, leading icon |
| `StatusIndicator.swift` | Colored dot/icon for discrete state (idle, active, error) |
| `ActivityBadge.swift` | Numeric or dot badge overlay with animated transitions |
| `EmptyState.swift` | Centered placeholder for empty containers |
| `PopoverContainer.swift` | Floating card: header, scrollable body, footer |
| `ToolbarSurface.swift` | Full-width bar pinned to edge, material background |
| `SectionHeader.swift` | Collapsible section label with count badge |

---

## BrowserCore/

**Pure types. No framework imports.** No AppKit, no WebKit, no SwiftUI. All types are `Sendable` and `Codable`.

### Domain Types

```swift
// Tab identity -- write-once metadata
struct TabRecord: Identifiable, Sendable, Codable {
    let id: UUID
    let createdAt: Date
    var provenance: TabProvenance
    var lifecycleState: TabLifecycle
    var groupID: UUID?
    var isPinned: Bool
    var isPrivate: Bool
    var profileID: UUID?
}

// Navigation state -- reflected from WKWebView KVO
struct NavigationState: Sendable {
    var url: URL?
    var displayURL: URL?        // commit-phase URL (never provisional)
    var title: String
    var isLoading: Bool
    var loadProgress: Double
    var canGoBack: Bool
    var canGoForward: Bool
    var isSecure: Bool
    var zoomLevel: Double
}

enum TabProvenance: Sendable, Codable {
    case human
    case agent(agentID: String, sessionTag: String, requestedAt: Date)
    case restored(originalProvenance: TabProvenance)
}

enum TabLifecycle: String, Sendable, Codable {
    case empty       // created, no WebView yet
    case loading     // WebView created, navigation in progress
    case live        // page committed, WebView active
    case suspended   // JS halted, WebContent warm
    case cold        // interactionState captured, WebView at about:blank
    case crashed     // WebContent process died
}
```

### Additional Types

- `WorkspaceRecord` -- named tab group (id, name, color, tabIDs)
- `DownloadRecord` -- download state (id, url, filename, progress, status)
- `HistoryEntry` -- navigation record (id, url, title, visitedAt)
- `Bookmark` -- saved URL (id, url, title, folderID, createdAt)
- `AgentConnection` -- agent identity (id, connectedAt, lastSeenAt, status)
- `AgentAction` -- logged action (id, agentID, tabID, method, startedAt, status)

### Protocols

Two protocols, no more:

```swift
protocol PageInspectable {
    var currentURL: URL? { get }
    var pageTitle: String? { get }
    func evaluateJavaScript(_ script: String) async throws -> Any?
    func extractText() async throws -> String
    func extractMarkdown() async throws -> String
    func screenshot(rect: CGRect?) async throws -> NSImage
    func getInteractiveElements() async throws -> [ElementInfo]
}

protocol Navigable {
    func load(_ url: URL)
    func goBack()
    func goForward()
    func reload()
    var canGoBack: Bool { get }
    var canGoForward: Bool { get }
}
```

These exist so the agent API depends on the shape of a tab, not on WKWebView. They also enable testing without a live WebKit process. No additional protocols.

---

## BrowserEngine/

**Only module that imports WebKit.** Everything upstream works in pure value types.

### Files

| File | Responsibility |
|---|---|
| `BrowserTab.swift` | `@Observable @MainActor` wrapper. Owns `WKWebView?` (lazy), KVO observations, NavigationCoordinator, UICoordinator. Reflects `NavigationState` from KVO. Conforms to `PageInspectable` and `Navigable`. |
| `PageController.swift` | JS execution, content extraction, screenshots. Stateless service operating on a given WKWebView. |
| `ScriptBridge.swift` | `automation-bridge.js` injection and execution in isolated `WKContentWorld`. |
| `NavigationCoordinator.swift` | `WKNavigationDelegate` implementation. |
| `UICoordinator.swift` | `WKUIDelegate` (popups, permissions, alerts). |
| `DownloadHandler.swift` | `WKDownloadDelegate` with progress tracking. |
| `WebViewFactory.swift` | `WKWebViewConfiguration` creation with shared process pool. |

### Key Change: BrowserTab Becomes a Thin Wrapper

Currently BrowserTab owns both domain identity AND the WKWebView. After refactor:

- `TabRecord` (in BrowserCore) holds identity, provenance, lifecycle
- `BrowserTab` (in BrowserEngine) holds the live WKWebView and bridges KVO to `@Observable` properties
- `BrowserTab.record: TabRecord` references the domain identity
- `BrowserTab.navState: NavigationState` is a value type computed from KVO

---

## Persistence/

**GRDB + SQLite. Actor-isolated.** WAL mode. DatabasePool for concurrent reads during writes.

### Database Files

| Database | Contents | Rationale |
|---|---|---|
| `history.db` | History entries + FTS5 index | High write rate; separate for WAL contention |
| `browser.db` | Bookmarks, sessions, workspaces | Low write rate, relational |
| `agent.db` | Agent tokens, action log, permissions | Security isolation |
| `TabState/<uuid>.interactionstate` | Binary WKWebView state blobs | Opaque, up to several MB |

### Stores

| Store | Isolation | Write Pattern |
|---|---|---|
| `HistoryStore` | `DatabaseActor` (off main) | Write on every navigation commit |
| `BookmarkStore` | `DatabaseActor` (off main) | Low frequency, user-initiated |
| `SessionStore` | `DatabaseActor` (off main) | Debounced every 30s + on quit |
| `AgentStore` | `DatabaseActor` (off main) | Write on every agent action |

All stores use `ValueObservation` to drive `@Observable` store wrappers on `@MainActor`, which SwiftUI views consume.

---

## AgentIntegration/

### Files

| File | Responsibility |
|---|---|
| `AgentHTTPServer.swift` | `NWListener` on 127.0.0.1:8833. HTTP routing, bearer token validation, Host/Origin checks. |
| `AgentActivityStore.swift` | `@Observable @MainActor`. Tracks connections, active actions, recent actions. Consumed by UI. |
| `AgentRegistry.swift` | Connected agents, token validation, agent identity. |
| `ToolRouter.swift` | Maps JSON-RPC tool calls to BrowserSession/PageController methods. |
| `ActionLog.swift` | Append-only agent action history. Writes to `agent.db`. |
| `TabControlState.swift` | Per-tab control state machine (IDLE/AGENT_ACTIVE/HUMAN_OWNS). |
| `TakeoverHandler.swift` | Intercepts human events, signals agent interrupt, manages transitions. |

---

## Features/

Each feature is a directory with SwiftUI views and feature-specific logic.

```
Features/
  Sidebar/
    TabSidebarView.swift      -- vertical tab list
    TabRowView.swift          -- single tab row
    SidebarHeaderView.swift   -- pinned section header
    PinnedTabsSection.swift   -- pinned tabs grid/list
  Omnibox/
    OmniboxView.swift         -- SwiftUI wrapper (or AddressBar stays AppKit)
    AutocompleteDropdown.swift -- NSPanel + SwiftUI results list
  Toolbar/
    NavigationControls.swift  -- back/forward/reload grouped
    BrowserToolbar.swift      -- full toolbar composition
  AgentActivity/
    AgentIndicator.swift      -- colored left border on tab row
    AgentActivityPopover.swift -- click-expand detail
    ProvenanceBadge.swift     -- human vs agent icon
    ControlStatusView.swift   -- Take Control bar
  Downloads/
    DownloadBar.swift         -- bottom strip
    DownloadItemView.swift    -- single download row
  Settings/
    SettingsView.swift        -- SwiftUI Settings scene
```

---

## Window/

### Files

| File | Responsibility |
|---|---|
| `BrowserWindowController.swift` | `NSWindowController`. Creates `NSWindow`. Wires AppKit layout: toolbar container, sidebar split, web content view. Hosts `NSHostingController` for SwiftUI sidebar. |
| `WindowSession.swift` | `@Observable @MainActor`. Per-window state: `[BrowserTab]`, `selectedTabID`, `closedTabStack`, `WindowUXState`. |
| `AppStore.swift` | `@MainActor`. App-global state: TabStore, WorkspaceStore, AgentRegistry, AgentActivityStore. Passed to window controllers at creation. |

---

## State Ownership

| State | Truth Owner | Level |
|---|---|---|
| Tab identity (id, provenance, lifecycle, group) | `AppStore.tabStore` | App |
| Navigation (URL, title, isLoading, progress) | `BrowserTab` <- WKWebView KVO | Tab |
| Selected tab | `WindowSession.selectedTabID` | Window |
| WKWebView instance | `BrowserTab.webView?` (lazy) | Tab |
| interactionState blob | `SessionStore` (disk) | Persistence |
| Closed tab stack | `WindowSession.closedTabStack` | Window |
| History | `HistoryStore` (actor) | Persistence |
| Bookmarks | `BookmarkStore` (actor) | Persistence |
| Downloads | `DownloadStore` | Window |
| Agent connections | `AgentRegistry` | App |
| Active agent actions | `AgentActivityStore` | App |
| Sidebar width, collapsed | `WindowUXState` | Window (UI only) |
| Address bar text | `NSTextField` local state | Ephemeral |

---

## SwiftUI / AppKit Responsibilities

### AppKit Owns

- NSWindow creation and lifecycle
- Toolbar layout (toolbarContainer NSView, 52pt height)
- WKWebView hosting (webContentView NSView)
- Main menu bar construction
- Keyboard shortcut routing (via NSMenu key equivalents)
- Address bar (NSTextField subclass for key event control)
- Sidebar split (manual NSView frame layout, NOT NSSplitViewController)
- Window chrome (titlebar, fullSizeContentView)

### SwiftUI Owns (via NSHostingController)

- Tab sidebar (`TabSidebarView` in NSHostingController, `sizingOptions = []`)
- Autocomplete dropdown (NSPanel + SwiftUI list)
- Settings window (SwiftUI `Settings` scene)
- Agent activity popover (SwiftUI in NSPopover)
- Download bar (SwiftUI in NSHostingController at window bottom)
- Command palette (NSPanel + SwiftUI, future)

### Communication Pattern

1. `@Observable` models (`WindowSession`, `BrowserTab`, `AgentActivityStore`) are shared references
2. AppKit controllers hold references and call methods directly
3. SwiftUI views observe `@Observable` properties via automatic tracking
4. NSHostingController receives models via `.environment()` at creation
5. NSHostingController `sizingOptions = []` prevents layout fights
6. Never use `NSSplitViewController` with `NSHostingController` children

---

## Testing Strategy

| Module | Test Type | Runner | Notes |
|---|---|---|---|
| BrowserCore | Unit tests | Swift Testing | Pure types, fast, no framework deps |
| DesignSystem | SwiftUI previews | Xcode Previews | Visual verification per primitive |
| Persistence | Unit tests | Swift Testing | In-memory `DatabaseQueue()` |
| BrowserEngine | Integration tests | XCTest | Requires `WKWebView` (live WebKit) |
| AgentIntegration | Integration tests | XCTest | Mock HTTP server |
| Features | SwiftUI previews + snapshots | Xcode + optional snapshot framework | |
| Window | Manual + UI tests | XCUITest | Full app integration |

---

## Architecture Decision Records

### ADR-1: Vertical Tabs

**Decision:** Vertical sidebar tabs, no horizontal tab bar.
**Alternatives:** Horizontal (Chrome), hybrid, tree tabs.
**Rationale:** Horizontal fails at 8+ tabs. Vertical scales to 100+. Developer audience expects density. All modern power-user browsers converged on vertical.

### ADR-2: AppKit Shell + SwiftUI Embedded

**Decision:** NSWindow + NSView layout for shell. SwiftUI via NSHostingController for UI panels.
**Alternatives:** Pure SwiftUI (WindowGroup + WebView), pure AppKit.
**Rationale:** WKWebView is NSView. SwiftUI cannot own/size it reliably. SwiftUI excels at declarative UI for sidebar/settings.

### ADR-3: Manual Split, Not NSSplitViewController

**Decision:** Manual NSView frame layout for sidebar + content split.
**Alternatives:** NSSplitViewController, SwiftUI NavigationSplitView.
**Rationale:** NSSplitViewController + NSHostingController causes infinite layout cycles (confirmed in blur-browser, Kestrel). Manual layout gives full control.

### ADR-4: GRDB Everywhere

**Decision:** GRDB + SQLite for all persistence (history, bookmarks, sessions, agent log).
**Alternatives:** SwiftData for bookmarks, Core Data, UserDefaults, JSON files.
**Rationale:** FTS5 required for history search. Mixing GRDB and SwiftData doubles the persistence surface. GRDB's ValueObservation drives @Observable cleanly. In-memory databases for fast tests.

### ADR-5: @Observable, Never ObservableObject

**Decision:** All model types use `@Observable` (Swift 5.9+ / macOS 14+).
**Alternatives:** `ObservableObject` + `@Published`.
**Rationale:** Property-level granularity, simpler API. Mixing the two observation systems in one hierarchy causes subtle bugs.

### ADR-6: Domain / Presentation Split

**Decision:** `TabRecord` (pure struct) for domain identity, `BrowserTab` (class) for presentation.
**Alternatives:** Monolithic `BrowserTab` (current state).
**Rationale:** Separating domain from WebKit allows pure-type tests, Sendable compliance, and clean persistence boundaries.
