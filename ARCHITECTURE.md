# Agent Browser: Architecture

---

## 1. Capability Classification

For each core browser operation, the honest rating.

### Execute JavaScript

**Easy.**

WKWebView has three JS execution APIs. The one to use is `callAsyncJavaScript(_:arguments:in:contentWorld:)` (macOS 11+). It runs the string as a function body (use `return`), supports `await` inside the body (Promise resolution handled by WebKit), and accepts typed arguments as a dictionary. Content worlds isolate your code from page scripts while sharing the DOM.

Round-trip latency is 0.5-2ms for local eval. Return values must be one of six types (String, Number, Bool, Date, Array, Dictionary) -- anything else requires `JSON.stringify()` on the JS side.

The one real gotcha: **there is no timeout.** A JS call that hangs (infinite loop, never-resolving Promise) hangs the completion handler forever. The mitigation is straightforward -- wrap async work in `Promise.race` with a `setTimeout` rejection arm. For sync JS, there is no recovery; you must trust the script or run it in a separate content world where a navigation cancellation can interrupt it.

The `async throws -> Any` Swift overload has an unfixed crash on void-returning JS (force-unwraps nil). Use the callback form or append `; true` to guarantee a non-undefined return.

### Capture Screenshots

**Easy for viewport. Feasible-but-awkward for full-page. Risky for WebGL/video.**

`takeSnapshot(configuration:)` captures the current viewport as an `NSImage`. Set `afterScreenUpdates: true` to wait for the latest paint. Sub-rect capture works via `WKSnapshotConfiguration.rect`. Resolution matches the display's device scale; override with `snapshotWidth`.

Full-page capture requires a workaround: evaluate `document.documentElement.scrollHeight` via JS, resize the WKWebView frame to the full content height, snapshot, restore the frame. Alternatively, `createPDF()` captures full-page content natively and you render the PDF to a bitmap via PDFKit. The PDF path is more reliable for long pages.

Hardware-accelerated content (WebGL canvases, `<video>` elements) renders blank in snapshots. This is a hard limitation in the WebKit source: software compositing cannot capture GPU layers. The workaround for `<canvas>` is `canvas.toDataURL()` via JS. For `<video>`, you're stuck.

### Detect Navigation Changes

**Easy for real navigations. Feasible-but-awkward for SPA routing.**

`WKNavigationDelegate` provides the full lifecycle: `didStartProvisionalNavigation`, `didReceiveServerRedirect`, `didCommit`, `didFinish`, `didFail`. Use `didCommit` (not `didStart`) to update the address bar -- `webView.url` updates eagerly at provisional start, which is a known URL-spoofing vector.

SPA navigation (`pushState`/`replaceState`) does not trigger any delegate callback. KVO on `webView.url` does fire, which catches most cases. For full fidelity, inject a user script that monkey-patches `history.pushState` and `history.replaceState` to post messages via `WKScriptMessageHandler`. Hash-only changes (`hashchange`) similarly need an injected listener -- the delegate never fires for those.

Iframe navigations fire `decidePolicyFor:` but not `didFinish`. You see the subframe navigation decision but not its completion.

### Observe New Tabs / Windows

**Easy.**

`WKUIDelegate.createWebViewWith(configuration:for:windowFeatures:)` fires when `targetFrame == nil` -- which means `window.open()` and `target="_blank"` links. Return a new `WKWebView` (created with the provided configuration copy -- required) to allow it, or `nil` to block.

To redirect a popup to a tab instead of a window: create the WKWebView inside your tab management system and add it to the view hierarchy before returning it. WebKit loads the request into whatever view you hand back.

You can inspect `navigationAction.request.url` and `navigationAction.navigationType` (.linkActivated vs .other) to distinguish user clicks from programmatic opens and decide selectively.

One gotcha: some sites trigger `window.open()` before they know the final URL, so `navigationAction.request.url` can be `nil` at call time for dynamic popups.

### Handle Downloads

**Easy for standard HTTP. Impossible (natively) for blob/data URLs.**

`WKDownload` (macOS 11.3+) handles the full lifecycle: `decideDestinationUsing` for filename/path, `downloadDidFinish`, `didFailWithError` with resume data. Progress is tracked via a `Progress` object (KVO `fractionCompleted`). MIME type is available in the `URLResponse` passed to `decideDestinationUsing`. Resume support exists in the API but depends on the server supporting HTTP range requests.

Downloads triggered by JS (setting `document.location`, clicking a dynamic `<a download>`) work through the standard pipeline when `navigationAction.shouldPerformDownload == true`.

**blob: URL downloads are broken** (WebKit bug 216918, still open). Calling `.download` on a blob navigation fails with an unsupported URL error. The workaround: inject JS that reads the blob via `FileReader`, base64-encodes it, and sends the data to Swift via `messageHandlers`. Same workaround for `data:` URL downloads.

Download delegates are not retained by WKWebView -- you must retain them yourself or the delegate disappears mid-download.

### Summary table

| Operation | Rating | Key constraint |
|---|---|---|
| Execute JS (basic) | Easy | No timeout; void-return crashes async overload |
| Execute JS (async/Promises) | Easy | No timeout; `Promise.race` wrapper recommended |
| Return complex types from JS | Feasible-but-awkward | 6-type whitelist; JSON.stringify for anything else |
| Screenshot (viewport) | Easy | `afterScreenUpdates: true` required |
| Screenshot (full page) | Feasible-but-awkward | Resize frame or use createPDF |
| Screenshot (specific element) | Feasible-but-awkward | JS getBoundingClientRect + config.rect |
| Screenshot (WebGL/video) | Risky / impossible | Silently blank; canvas.toDataURL() workaround for canvas only |
| Detect real navigation | Easy | Use didCommit for URL bar, not webView.url |
| Detect SPA pushState | Feasible-but-awkward | KVO on url works; inject monkey-patch for full fidelity |
| Detect hash changes | Feasible-but-awkward | Inject hashchange listener |
| Detect iframe navigation | Feasible-but-awkward | decidePolicyFor fires; didFinish does not |
| Observe new windows/popups | Easy | Return nil to block, WKWebView to allow/redirect |
| Downloads (standard HTTP) | Easy | Retain the delegate yourself |
| Downloads (progress/resume) | Feasible-but-awkward | fileURL KVO never fires; resume is server-dependent |
| Downloads (blob: URLs) | Impossible natively | JS FileReader + messageHandlers workaround |
| Downloads (data: URLs) | Impossible natively | Same workaround |

---

## 2. Architecture

### Guiding constraints

1. WKWebView is an AppKit object. SwiftUI cannot own or reliably size it. **AppKit hosts the browser shell; SwiftUI is embedded for UI components.**
2. WKWebViewConfiguration is immutable after init. Tabs that need different isolation (private browsing, different profiles) must be created with different configurations from the start.
3. Each live WKWebView costs ~130 MB in its WebContent process. The architecture must manage tab lifecycles aggressively.
4. The agent API is a separate concern from the browser UI. An agent controlling tabs should go through the same interfaces the UI does.

### Module map

```
┌─────────────────────────────────────────────────────────────────────┐
│  BrowserApp                                                         │
│  SwiftUI @main entry point. Owns app lifecycle, main menu,         │
│  settings scene. Immediately delegates to AppKit for windows.       │
└────────────────────┬────────────────────────────────────────────────┘
                     │
        ┌────────────┴────────────┐
        │                         │
┌───────▼──────┐          ┌───────▼──────┐
│ BrowserWindow │          │ BrowserWindow │     (one per window)
│              │          │              │
│ NSWindow +   │          │ NSWindow +   │
│ WindowController         │ WindowController
└───────┬──────┘          └──────────────┘
        │
        │  owns
        │
┌───────▼──────────────────────────────────────────────────────┐
│  BrowserSession                                               │
│  Per-window state container. Owns the tab list, selected      │
│  tab, sidebar state, navigation chrome state.                 │
│  @Observable, @MainActor.                                     │
│                                                               │
│  ┌──────────┐  ┌──────────┐  ┌──────────┐                    │
│  │BrowserTab│  │BrowserTab│  │BrowserTab│  ...               │
│  └──────────┘  └──────────┘  └──────────┘                    │
└───────┬──────────────────────────────────────────────────────┘
        │
        │  each tab owns
        │
┌───────▼──────────────────────────────────────────────────────┐
│  BrowserTab                                                   │
│  The core programmable unit. Owns a lazy WKWebView?,          │
│  navigation state, title, URL, favicon, load progress.        │
│  Manages its own WebKit delegates.                            │
│  @Observable, @MainActor.                                     │
│                                                               │
│  Tab lifecycle: .empty → .loading → .live → .suspended → .cold│
└───────┬──────────────────────────────────────────────────────┘
        │
        │  delegates to
        │
┌───────▼──────────────────────────────────────────────────────┐
│  PageController                                               │
│  Wraps WKWebView interaction. JS execution, content           │
│  extraction, screenshot, DOM queries. Stateless service       │
│  that operates on a given WKWebView. This is the seam         │
│  between "browser state" and "WebKit plumbing."               │
└──────────────────────────────────────────────────────────────┘
```

### Separate concerns, concrete types

```
UI Layer
├── BrowserWindowController    NSWindowController. Creates window, wires layout.
├── TabSidebarView             SwiftUI. Vertical tab list, groups, drag reorder.
├── NavigationBar              NSView. Back/forward/reload buttons + URL field.
├── WebContentView             NSView. Hosts the active tab's WKWebView.
├── CommandPalettePanel        NSPanel + SwiftUI. Floating search/command overlay.
└── DownloadBar                SwiftUI. Download progress strip at bottom of window.

Browser State
├── BrowserSession             Per-window: tab list, selected tab, sidebar width.
├── BrowserTab                 Per-tab: URL, title, favicon, lifecycle, WebView.
├── BrowserWorkspace           Tab groups. A workspace is a named collection of tabs.
├── NavigationState            Per-tab: canGoBack, canGoForward, isLoading, progress.
└── ProfileManager             Maps profile IDs to WKWebsiteDataStore instances.

WebKit Integration
├── PageController             JS execution, content extraction, screenshots.
├── ScriptBridge               Injected JS bundle for DOM inspection/interaction.
├── NavigationCoordinator      WKNavigationDelegate implementation.
├── UICoordinator             WKUIDelegate implementation (popups, permissions, alerts).
├── DownloadCoordinator        WKDownloadDelegate implementation.
└── WebViewFactory             Creates WKWebViewConfiguration + WKWebView for a given profile.

Persistence
├── HistoryStore               SQLite + FTS5 via GRDB. Actor-isolated.
├── BookmarkStore              SwiftData. Folders, tags, URLs.
├── SessionStore               Codable JSON. Window frames, tab URLs, interactionState paths.
└── PreferencesStore           UserDefaults (custom suite).

Automation
├── AgentServer                NWListener on 127.0.0.1. HTTP + SSE.
├── AgentAuth                  Keychain-backed bearer token. Host/Origin validation.
├── ToolRouter                 Maps incoming tool calls to browser operations.
└── ActionLog                  Records agent actions for user visibility.

Agent APIs (external surface)
├── MCP endpoint               POST /mcp (JSON-RPC 2.0), GET /mcp (SSE events).
├── CLI tool                   `browser` command that hits the HTTP API.
└── AppleScript dictionary     Basic tab/navigation for power user scripting.
```

### What talks to what

```
 User clicks ──▶ UI Layer ──▶ BrowserSession ──▶ BrowserTab ──▶ PageController ──▶ WKWebView
                                                                      ▲
 Agent request ──▶ AgentServer ──▶ ToolRouter ──▶ BrowserSession ─────┘
```

The UI and the agent API converge at `BrowserSession` and `BrowserTab`. Neither bypasses the other. An agent calling `browser.tabs.open(url)` goes through the same `BrowserSession.newTab(url:)` that a Cmd+T keystroke does. This means:
- Agent actions show up in the UI immediately (tab bar updates, address bar updates).
- UI state is always the source of truth -- agents read it, not a shadow copy.
- The action log can record both user and agent actions through the same path.

### Protocol-based abstractions (where they earn their keep)

Two protocols. Not more.

```swift
/// Anything that can read and act on a loaded web page.
protocol PageInspectable {
    var currentURL: URL? { get }
    var pageTitle: String? { get }
    var isLoading: Bool { get }

    func evaluateJavaScript(_ script: String) async throws -> Any?
    func extractText() async throws -> String
    func extractHTML() async throws -> String
    func extractMarkdown() async throws -> String
    func screenshot(rect: CGRect?) async throws -> NSImage
    func getInteractiveElements() async throws -> [ElementInfo]
}

/// Anything that can navigate.
protocol Navigable {
    func load(_ url: URL)
    func goBack()
    func goForward()
    func reload()
    func stop()
    var canGoBack: Bool { get }
    var canGoForward: Bool { get }
}
```

`BrowserTab` conforms to both. `PageController` implements the `PageInspectable` methods against a `WKWebView` instance. These protocols exist so the agent API layer can depend on the shape of a tab without depending on WKWebView directly. They also make testing possible without a live WebKit process.

No `BrowserService`, no `BrowserInteractor`, no `BrowserRepository`, no `UseCaseProvider`. The domain is too small for that.

---

## 3. Tab Representation

### BrowserTab is the first-class programmable object

```swift
@Observable @MainActor
final class BrowserTab: Identifiable {
    // Identity
    let id = UUID()
    let createdAt = Date()

    // Display state (observed by UI and agents)
    private(set) var url: URL?
    private(set) var title: String = "New Tab"
    private(set) var favicon: NSImage?
    private(set) var isLoading: Bool = false
    private(set) var loadProgress: Double = 0
    private(set) var canGoBack: Bool = false
    private(set) var canGoForward: Bool = false

    // Lifecycle
    private(set) var lifecycle: Lifecycle = .empty
    enum Lifecycle {
        case empty       // Tab exists, no WebView created yet (new tab page)
        case loading     // WebView created, navigation in progress
        case live        // WebView created, page loaded, in or near viewport
        case suspended   // WebView alive but JS paused (inactiveSchedulingPolicy = .suspend)
        case cold        // interactionState captured, WebView navigated to about:blank
    }

    // WebView (lazy, nullable)
    private(set) var webView: WKWebView?

    // For cold restoration
    var interactionState: Data?

    // Relationships
    var workspaceID: UUID?
    var isPinned: Bool = false
    var order: Int = 0

    // Page controller (created with the WebView)
    private(set) var pageController: PageController?

    // KVO observations on the WebView
    private var observations: [NSKeyValueObservation] = []
}
```

### What state lives where

| Level | State | Why there |
|---|---|---|
| **App** | `ProfileManager`, `HistoryStore`, `BookmarkStore`, `AgentServer`, `PreferencesStore` | Shared across all windows. Singleton-ish, but passed via dependency injection, not global access. |
| **Window** | `BrowserSession` (tab list, selected tab, sidebar width, window frame) | Each window is an independent browsing context. |
| **Workspace** | `BrowserWorkspace` (name, color, tab IDs) | A named group within a window. A workspace is metadata over tabs, not a container that owns them. The session owns tabs; workspaces reference them by ID. |
| **Tab** | `BrowserTab` (URL, title, favicon, lifecycle, WKWebView, interactionState, PageController) | The tab is the atomic unit. Everything about a single browsing context lives here. |
| **WebKit** | `WKWebView`, `WKWebsiteDataStore`, `WKBackForwardList`, cookies, localStorage, sessionStorage | Managed by WebKit. We read from it (KVO, delegates, JS) but don't duplicate it. Cookies live in the data store, not in our model. |

### @Observable and reactivity

All model types use `@Observable` (Swift 5.9+ / macOS 14+). Never `ObservableObject`. Never mix the two -- they use different observation systems that don't compose.

The flow:

1. **WKWebView publishes state via KVO** (`url`, `title`, `isLoading`, `estimatedProgress`, `canGoBack`, `canGoForward`).
2. **BrowserTab observes KVO** and copies values to its own `@Observable` properties.
3. **SwiftUI views** observe `BrowserTab` properties and re-render automatically.
4. **Agent API** reads the same `BrowserTab` properties.

```swift
// In BrowserTab
func attachWebView(_ wv: WKWebView) {
    self.webView = wv
    self.pageController = PageController(webView: wv)
    observations = [
        wv.observe(\.url)               { [weak self] wv, _ in self?.url = wv.url },
        wv.observe(\.title)             { [weak self] wv, _ in self?.title = wv.title ?? "" },
        wv.observe(\.isLoading)         { [weak self] wv, _ in self?.isLoading = wv.isLoading },
        wv.observe(\.estimatedProgress) { [weak self] wv, _ in self?.loadProgress = wv.estimatedProgress },
        wv.observe(\.canGoBack)         { [weak self] wv, _ in self?.canGoBack = wv.canGoBack },
        wv.observe(\.canGoForward)      { [weak self] wv, _ in self?.canGoForward = wv.canGoForward },
    ]
    lifecycle = .loading
}
```

This KVO-to-Observable bridge is the only place WebKit state crosses into our model. Everything downstream reads `BrowserTab`, not `WKWebView`.

### Lifecycle and memory

The lifecycle states map directly to memory management strategies:

| State | WebView? | Memory cost | Restore time | When to use |
|---|---|---|---|---|
| `.empty` | nil | ~0 | N/A | New tab page, not yet navigated |
| `.loading` | live | ~50-130 MB (growing) | N/A | Navigation in progress |
| `.live` | live, in view | ~130 MB | instant | Active or recently-used tab |
| `.suspended` | live, not in view | ~130 MB (JS paused) | instant | Background tab, accessed recently |
| `.cold` | live but at about:blank | ~5-10 MB | 1-2s (re-navigate) | Background tab, not accessed recently |

Key facts from WebKit source research:

- **Destroying a WKWebView does NOT free its process memory.** WebKit's `WebProcessCache` keeps the process warm for 30 minutes, suspended after 30 seconds. Deallocating the view saves the ~200 KB proxy object but the 130 MB WebContent process stays.
- **Navigating to about:blank IS effective.** It replaces the DOM with an empty document, releasing the JS heap and decoded images while keeping the process alive and cheap (~5-10 MB for an empty page).
- **`interactionState`** (macOS 12+) captures scroll position, form data, and the full back/forward list as an opaque `NSData` blob (typically 2-50 KB). Set it on a WKWebView before navigation to restore state on the next load.
- **`inactiveSchedulingPolicy = .suspend`** (macOS 14+) pauses JS timers and execution but does NOT free memory. It stops the tab from consuming CPU, not RAM. Audio/media-playing tabs are automatically exempted.

The memory management strategy:

1. The **active tab** is `.live` -- in the view hierarchy, fully interactive.
2. The **last 5-8 accessed tabs** are `.suspended` -- WebView alive, JS paused, instant switch.
3. **Older tabs** transition to `.cold` -- `interactionState` captured, WebView navigated to `about:blank`. Selecting them requires a 1-2s re-navigation.
4. On **memory pressure** (`didReceiveMemoryWarning`), aggressively cold the oldest suspended tabs.

The LRU is tracked by `lastAccessedAt` on `BrowserTab`. A background task runs every 60 seconds to demote tabs that exceed the live budget.

### 50-100 tabs

At 50 tabs with 5 live + 10 suspended + 35 cold:
- Live: 5 x 130 MB = 650 MB
- Suspended: 10 x 130 MB = 1.3 GB
- Cold: 35 x ~8 MB = 280 MB
- **Total WebContent memory: ~2.2 GB**

At 100 tabs with 5 live + 10 suspended + 85 cold:
- **Total: ~2.6 GB**

This is comparable to Safari's memory profile with similar tab counts. The key is that cold tabs are cheap, and the user only ever sees instant switching for their recent ~15 tabs.

---

## 4. Agent Automation

### Internal automation API

The automation layer is **not a protocol, not a god-object, not Playwright.** It's a set of methods on `BrowserSession` (for tab management) and `PageController` (for page interaction) that the `ToolRouter` calls.

```swift
// Tab operations -- on BrowserSession
@Observable @MainActor
final class BrowserSession {
    func listTabs() -> [TabInfo]
    func newTab(url: URL?) -> BrowserTab
    func closeTab(_ id: UUID)
    func selectTab(_ id: UUID)
    func currentTab() -> BrowserTab?
}

// Page operations -- on PageController
@MainActor
final class PageController {
    private let webView: WKWebView
    private let scriptBridge: ScriptBridge

    // Reading
    func text() async throws -> String
    func html() async throws -> String
    func markdown() async throws -> String
    func metadata() async throws -> PageMetadata
    func links() async throws -> [LinkInfo]

    // Inspection
    func interactiveElements() async throws -> [ElementInfo]
    func screenshot(rect: CGRect?) async throws -> NSImage
    func find(_ text: String) async throws -> [FindResult]

    // Interaction
    func click(_ target: ElementTarget) async throws
    func fill(_ target: ElementTarget, value: String) async throws
    func select(_ target: ElementTarget, value: String) async throws
    func scroll(_ direction: ScrollDirection, amount: CGFloat?) async throws
    func press(_ key: KeyCombo) async throws

    // JavaScript
    func evaluate(_ script: String) async throws -> Any?
    func evaluateAsync(_ script: String) async throws -> Any?

    // Navigation
    func navigate(to url: URL) async throws
    func waitForLoad(timeout: TimeInterval) async throws
    func waitForSelector(_ selector: String, timeout: TimeInterval) async throws
}
```

### How automation actually works: the hybrid approach

The automation uses **injected JavaScript as the primary mechanism**, with **WebKit delegate APIs for lifecycle events**, and **KVO for state observation.** Not accessibility APIs. Not DOM serialization.

Why this hybrid, not the alternatives:

**Injected JavaScript (primary):**
- DOM queries, element identification, click/fill/scroll, text extraction, page structure.
- Runs in an isolated `WKContentWorld` named "AgentBridge" -- page scripts cannot tamper with `document.querySelector` or `getBoundingClientRect` in our world. The DOM itself is shared (reads and writes work), but the JS prototype chain is protected.
- 0.5-2ms round-trip per call. Fast enough for interactive automation.
- This is what Playwright, mcp-browser, and aslan-browser all use internally.

**WebKit delegate APIs (lifecycle):**
- `WKNavigationDelegate` for navigation events (load start, commit, finish, fail, redirects).
- `WKUIDelegate` for popups, permission prompts, file uploads.
- `WKDownloadDelegate` for downloads.
- These are the only reliable way to observe navigation and lifecycle. JS injection alone misses navigation boundaries.

**KVO (state observation):**
- `url`, `title`, `isLoading`, `estimatedProgress`, `canGoBack`, `canGoForward`.
- Bridges WebKit state into `@Observable` properties for both UI and agent consumption.

**Why NOT pure accessibility APIs:**
- macOS Accessibility (`AXUIElement`) requires the user to grant Accessibility permission in System Preferences. That's a hostile onboarding step for a browser.
- The AX tree for WKWebView is exposed as `AXWebArea` and does surface headings, links, and form controls, but it's slower to query than JS (~50-100ms vs ~5ms) and less controllable.
- We own the WKWebView -- we can inject whatever JS we want. We don't need to use the AX tree as a side channel.

**Why NOT raw DOM serialization:**
- Serializing the full DOM to Swift on every call would be expensive for complex pages and redundant -- we'd just be moving the same tree across IPC that JS can already walk in-process.
- The right pattern is: ask specific questions via JS, get specific answers back. Not: dump the entire DOM and parse it in Swift.

### ScriptBridge: the injected JS

A single JS file injected via `WKUserScript` at `.atDocumentEnd` in a named content world (`AgentBridge`). It exposes a `window.__agentBridge` object with methods:

- `getElements()` -- walk the DOM, find interactive elements, assign refs (`@e0`, `@e1`, ...) via `data-agent-ref` attributes, return an array of `{ref, tag, role, text, ariaLabel, rect, inViewport, disabled}`.
- `click(ref)` -- find element by `data-agent-ref`, scroll into view, click.
- `fill(ref, value)` -- focus, set value, dispatch `input` and `change` events.
- `select(ref, value)` -- set `<select>` value, dispatch `change`.
- `scroll(direction, amount)` -- `window.scrollBy`.
- `getText()` -- `document.body.innerText`.
- `getHTML()` -- `document.documentElement.outerHTML`.
- `getLinks()` -- all `<a href>` elements with text and href.
- `getMetadata()` -- title, description, canonical URL, Open Graph tags.
- `waitForSelector(selector, timeout)` -- MutationObserver-based wait, resolves when element appears.
- `getPageStructure()` -- headings hierarchy, forms with fields, images with alt text.

Element refs are assigned per `getElements()` call and persist until the next call or page navigation. For SPAs, a `MutationObserver` can optionally invalidate refs on significant DOM changes.

### ElementTarget: how agents identify what to click

```swift
enum ElementTarget {
    case ref(String)          // "@e5" -- from a previous getElements() call
    case selector(String)     // "button.submit" -- CSS selector
    case text(String)         // "Sign in" -- visible text match
    case role(String, String) // ("button", "Submit") -- ARIA role + name
    case xpath(String)        // "//button[@type='submit']" -- XPath (fallback)
}
```

The agent should prefer `ref` (unambiguous, from a prior inspection) or `text` (readable, intent-preserving). CSS selectors are a fallback for precision. XPath for edge cases.

### Tradeoffs acknowledged

1. **`event.isTrusted` is false** for synthetic JS events. ~5% of sites check this. Playwright has the same limitation. For truly trusted events, you'd need `_WKAutomationSession` (private SPI). Not worth the private API dependency for V1.

2. **Cross-origin iframes** cannot be inspected. Same-origin iframes are fully accessible. This is a web security standard, not a limitation to work around.

3. **Closed shadow DOM roots** return `null` for `shadowRoot`. The element is visible in the rendered page and clickable by position, but its internal structure is hidden. Standard web behavior.

4. **JS execution has no timeout.** We wrap async operations in `Promise.race`. We don't have a kill switch for sync infinite loops. Navigation away from the page cancels pending evaluations.

---

## 5. External Agent Connection

### V1 recommendation: Local HTTP + CLI

Two surfaces:

1. **HTTP server on 127.0.0.1** (NWListener, fixed port with fallback). Serves MCP-compatible JSON-RPC at `POST /mcp` and SSE events at `GET /mcp`. Also serves a simpler REST-ish API at `GET/POST /api/...` for non-MCP clients.
2. **CLI tool** (`browser`) that hits the HTTP server. Lets agents use `bash` tool calls without needing an MCP client.

### Why not the alternatives

| Option | V1? | Reasoning |
|---|---|---|
| **HTTP on loopback** | Yes | Universal. Every agent can make HTTP requests. MCP's Streamable HTTP transport rides on it. |
| **CLI** | Yes | Agents that use `bash` tool calls (most of them) get zero-setup access. |
| **MCP** | Yes (over HTTP) | Claude Code, AFK, and Codex all consume MCP servers. The transport is HTTP. |
| **Unix domain socket** | Not V1 | Faster (~30% less latency), but harder for agents to consume. No `curl`, no `fetch`. Worth adding in V2 as an optional fast path. |
| **XPC** | No | XPC services are internal to the app bundle. External processes cannot connect without a Mach service (`SMAppService`), which adds significant complexity for no benefit over HTTP. |
| **AppleScript** | V2 | Nice for Keyboard Maestro / shell scripting. Cannot return complex data. Implement a basic dictionary (open/close/navigate/get URL) in V2. |
| **gRPC** | No | Proto definitions + generated stubs + HTTP/2 is massive overkill. JSON-RPC is simpler and every agent already speaks it. |

### Security model

**Threat**: A malicious web page loaded in the browser itself (or any browser on the machine) makes requests to `127.0.0.1:PORT` from JavaScript. DNS rebinding attacks can bypass same-origin policy by resolving `evil.com` to `127.0.0.1`.

**Four independent defense layers:**

1. **Loopback binding.** `NWListener` binds to `NWEndpoint.hostPort(host: .ipv4(.loopback), port: ...)`. Traffic from other machines cannot reach the server. This is not affected by macOS Local Network Privacy (loopback is exempt).

2. **Host header validation.** Every request must have a `Host` header matching `127.0.0.1:<port>` or `localhost:<port>`. A DNS-rebound request arrives with `Host: evil.com:<port>` -- rejected. Browsers cannot forge the `Host` header. This is the primary DNS rebinding defense.

3. **Origin header validation.** If an `Origin` header is present and not a loopback origin, reject. Defense-in-depth against CORS misconfiguration. Note: `no-cors` mode `fetch()` may omit Origin on simple requests, which is why Host validation is the primary check.

4. **Bearer token.** 32-byte random token generated via `SecRandomCopyBytes`, base64url-encoded, stored in the Keychain (`kSecAttrService: "com.browser.agent-api"`, `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`). Every request must include `Authorization: Bearer <token>`. Even if a rebound page reaches the server, it cannot guess the token.

**Token distribution to agents:**

On launch (and on token rotation), the browser writes a connection descriptor:

```json
// ~/.config/agent-browser/connection.json (mode 0600)
{
  "url": "http://127.0.0.1:8833",
  "token": "base64url-encoded-32-bytes",
  "pid": 12345,
  "version": "1.0.0"
}
```

Agents read this file. The browser also optionally auto-patches known MCP config files:
- `~/.claude.json` (Claude Code) -- adds/updates `mcpServers.agent-browser` entry
- `~/.afk/config/mcp.json` (AFK) -- same
- `~/.codex/config.json` (Codex) -- same

Token rotation: user clicks "Rotate Token" in settings, new token is generated, connection.json is rewritten, agent configs are re-patched. Agents that cache the token must re-read on 401.

**Port selection:**

Fixed port (8833) with fallback. On `EADDRINUSE`, try 8834, 8835, ..., up to 8843. Write the actual bound port to `connection.json`. Fixed-ish ports are better than random ports because agents can have a reasonable default without reading a file.

### What the agent sees

MCP tool catalog:

```
# Tab management
browser_list_tabs        → [{id, url, title, isActive, lifecycle}]
browser_new_tab          → {id, url?, active?}
browser_close_tab        → {tabId}
browser_switch_tab       → {tabId}

# Navigation
browser_navigate         → {url, tabId?}
browser_back             → {tabId?}
browser_forward          → {tabId?}
browser_reload           → {tabId?}
browser_wait_for_load    → {tabId?, timeout?}

# Reading
browser_read_text        → {tabId?} → string
browser_read_html        → {tabId?} → string
browser_read_markdown    → {tabId?} → string
browser_read_metadata    → {tabId?} → {title, url, description, ...}
browser_read_links       → {tabId?} → [{text, href}]

# Interaction
browser_elements         → {tabId?} → [{ref, tag, role, text, rect, ...}]
browser_click            → {target, tabId?}
browser_fill             → {target, value, tabId?}
browser_select           → {target, value, tabId?}
browser_scroll           → {direction, amount?, tabId?}
browser_press            → {key, tabId?}

# Inspection
browser_screenshot       → {tabId?, rect?} → base64 PNG
browser_evaluate_js      → {script, tabId?} → any

# Waiting
browser_wait_for_selector → {selector, tabId?, timeout?}
```

All `tabId?` parameters default to the active tab when omitted.

CLI equivalents:

```bash
browser tabs                           # list tabs
browser open https://example.com       # new tab
browser close <tabId>                  # close tab
browser text                           # read text from active tab
browser markdown                       # read as markdown
browser elements                       # list interactive elements
browser click "@e3"                    # click by ref
browser click "Sign in"                # click by text
browser fill "#email" "me@x.com"       # fill field
browser screenshot                     # save screenshot
browser eval "document.title"          # run JS
browser wait ".results" --timeout 5    # wait for selector
```

---

## 6. V1 Scope

The smallest browser you could daily-drive, with the agent foundation built in from day one.

### V1 includes

**Browser fundamentals:**
- Single window (multi-window is V2)
- Vertical tab sidebar (custom SwiftUI list in NSHostingController)
- Address bar with URL/search (NSTextField, basic autocomplete from history)
- Back / forward / reload / stop
- Page title and favicon in tab list
- Loading progress indicator
- New tab (Cmd+T), close tab (Cmd+W), reopen closed tab (Cmd+Shift+T)
- Tab switching (click, Cmd+1-9, Ctrl+Tab)
- Find in page (Cmd+F, using WKWebView's find API)
- Zoom (Cmd+/-, Cmd+0)
- Standard keyboard shortcuts (full list from the architecture doc)
- Context menus (right-click on page)
- File uploads (`<input type="file">` via WKUIDelegate)
- Basic popup handling (open in new tab, or block)
- Print (Cmd+P)

**Navigation and data:**
- Browsing history (SQLite + FTS5, searchable)
- Bookmarks (SwiftData, add/remove/organize in folders)
- Session restoration (save open tabs on quit, restore on launch)
- Private browsing mode (non-persistent data store, separate window indicator)
- Downloads (WKDownload, progress bar, open-in-Finder)
- Settings panel (homepage, search engine, default profile)

**Agent foundation:**
- Local HTTP server on 127.0.0.1 (always running while browser is open)
- Bearer token auth with Host/Origin validation
- Connection descriptor file (`~/.config/agent-browser/connection.json`)
- Core MCP tools: `list_tabs`, `new_tab`, `close_tab`, `switch_tab`, `navigate`, `back`, `forward`, `reload`, `read_text`, `read_html`, `read_markdown`, `elements`, `click`, `fill`, `screenshot`, `evaluate_js`, `wait_for_load`, `wait_for_selector`
- CLI tool (`browser`) for bash-based agent access
- Action log (visible in browser sidebar/panel -- what the agent did)
- Auto-patch Claude Code / AFK / Codex MCP configs on first launch

### Why the agent API is in V1, not V2

The agent API is the product thesis. A browser without it is just another WebKit wrapper. Building it from day one means:
- The architecture is proven to support automation before we pile on features.
- Early users (us) can immediately use it with coding agents.
- The action log and agent-visibility features inform the UI design.

The V1 agent API is intentionally minimal -- 18 tools, no autonomous workflows, no AI-in-the-browser features. It's a read/write API for tabs and pages.

---

## 7. V1 Kill List

Explicitly not in V1. Each item has a reason.

| Feature | Why not V1 |
|---|---|
| **Web extensions** | `WKWebExtensionController` is macOS 15.4+ and young. The API surface is large. Extensions are a feature multiplier only after the core browser is solid. |
| **Content blocking / ad blocker** | `WKContentRuleList` is easy to add, but curating and compiling rule lists (EasyList, EasyPrivacy) is a separate project. V2. |
| **Multiple windows** | Multi-window adds session management complexity (which window does a tab belong to?). V1 is single-window. |
| **Tab groups / workspaces** | The data model supports them (workspace ID on tab), but the UI, persistence, and group-switching UX are V2. |
| **Split panes** | Requires hosting multiple WKWebViews simultaneously with independent navigation. Memory and layout complexity. V2. |
| **Command palette** | Valuable but not blocking. It's a UI feature on top of a working browser, not a foundation. V2. |
| **User profiles** | `WKWebsiteDataStore(forIdentifier:)` makes profiles easy to implement, but the profile switching UI, per-profile settings, and profile management are scope. V2. |
| **Password manager integration** | Requires `com.apple.developer.web-browser` entitlement (Apple approval process). V2 after entitlement is granted. |
| **WebAuthn / Passkeys** | Requires separate `com.apple.developer.web-browser.public-key-credential` entitlement. V1.2. |
| **Default browser registration** | Requires private API (`LSSetDefaultHandlerForURLScheme`). Not V1 -- too much Apple-relations risk for a first release. |
| **Sync (bookmarks, history, tabs)** | Cloud infrastructure, accounts, conflict resolution. Way out of scope. |
| **iOS / cross-platform** | macOS only. Period. |
| **Custom rendering engine** | We use WebKit. We do not render HTML. |
| **DevTools** | Safari's Web Inspector is available in debug builds. Building our own is years of work. |
| **Reader mode** | JS-based Readability injection is straightforward but it's polish, not foundation. V2. |
| **"Ask this page" / "Summarize tab"** | AI features that depend on the agent API existing. Build the API (V1), build the AI features on top (V2/V3). |
| **Autonomous agent workflows** | The V1 API is request/response. An agent sends a command, gets a result. No agent orchestration, no multi-step automation, no goal-directed browsing. Those are V3+. |
| **Picture-in-Picture** | Nice to have. Not foundational. |
| **Auto-update (Sparkle)** | Should be in V1 for distribution, but can be added late in the cycle. Not blocking architecture. |
| **Handoff / Continuity** | NSUserActivity is easy, but requires an iOS companion to be useful. Not V1. |
| **Spotlight integration** | Nice. Not blocking. V2. |

---

## 8. Technical Risks

### 1. Website compatibility

**Likelihood: Medium. Impact: High. Threatens product thesis: Yes (indirectly).**

WKWebView renders with the system WebKit engine, which is the same engine Safari uses. So compatibility should be identical to Safari. The risk is not rendering -- it's that our browser chrome, navigation handling, popup logic, and permission prompts need to handle the full diversity of real websites.

Specific risks:
- OAuth flows that open popups -- we must handle `createWebViewWith` correctly and route popups to tabs, or the login flow breaks.
- Sites that detect non-Safari user agents and serve degraded content -- we should set a Safari-like user agent string by default.
- Sites that require Service Workers (some PWAs) -- these need the `com.apple.developer.web-browser` entitlement on iOS but work on macOS without it.
- Sites that require push notifications -- WKWebView supports `WKWebsiteDataStore`-level push, but it's complex.

**Mitigation:** Start dogfooding immediately. File bugs. Set a Safari-like default user agent. Handle OAuth popups correctly from day one.

### 2. Memory with many tabs

**Likelihood: Certain. Impact: Medium. Threatens product thesis: No.**

Each live WKWebView costs ~130 MB in WebContent process memory. 20 live tabs = 2.6 GB. This is a physics problem, not a bug.

**Mitigation:** The cold/suspended/live lifecycle described in section 3. LRU-based demotion. Keep 5-8 live, suspend 10, cold the rest. Users with 100+ tabs will see 1-2s delay when switching to a cold tab. This is the same behavior as Safari.

### 3. `event.isTrusted` detection

**Likelihood: Low (~5% of sites). Impact: Medium (agent can't interact with those sites). Threatens product thesis: Partially.**

Some sites check `event.isTrusted === true` and reject synthetic events. Our JS-injected clicks produce untrusted events. Playwright has the same limitation.

**Mitigation:** For V1, document the limitation. For V2, investigate `_WKAutomationSession` (WebKit's private automation API) which can dispatch truly trusted events. This is the same API Safari's Web Inspector uses for element highlighting and interaction.

### 4. Cross-origin iframe restrictions

**Likelihood: Certain (it's a web standard). Impact: Low for most sites. Threatens product thesis: No.**

Agents cannot inspect cross-origin iframe content. This affects embedded payment forms, third-party auth widgets, and some ad iframes.

**Mitigation:** Same-origin iframes are fully accessible. For cross-origin, the agent can screenshot the iframe's bounding rect and use vision-based interaction, or wait for the flow to redirect back to the main frame. This is the same limitation every browser automation tool has.

### 5. blob: and data: URL downloads

**Likelihood: Medium (JS-generated PDFs, exports). Impact: Medium. Threatens product thesis: No.**

WebKit bug 216918. Native download pipeline doesn't handle these URL schemes.

**Mitigation:** The JS FileReader + messageHandler workaround works reliably. Implement it as part of the DownloadCoordinator. Users won't notice the difference.

### 6. DRM / Encrypted Media

**Likelihood: Low for a dev-focused browser. Impact: High when it hits (Netflix, Spotify web). Threatens product thesis: No.**

Encrypted Media Extensions (EME) with FairPlay DRM requires specific entitlements on iOS. On macOS, WKWebView supports EME for FairPlay content, but the CDM (Content Decryption Module) availability depends on the system. Netflix may or may not work.

**Mitigation:** Not a V1 priority. If users report DRM issues, investigate entitlements. DRM is not relevant to the agent-browser thesis.

### 7. WebRTC (video calls)

**Likelihood: High (Google Meet, Zoom web). Impact: High. Threatens product thesis: No.**

WebRTC requires camera and microphone access. WKWebView supports `requestMediaCapturePermissionFor` (macOS 12+) but needs `NSCameraUsageDescription` and `NSMicrophoneUsageDescription` in Info.plist, plus the corresponding entitlements for sandboxed apps.

**Mitigation:** Include the usage descriptions and entitlements from day one. Implement the `WKUIDelegate` permission prompt. Test with Google Meet.

### 8. JavaScript execution timeout (agent reliability)

**Likelihood: Medium. Impact: Medium (agent hangs on a single call). Threatens product thesis: Yes if unmitigated.**

A `callAsyncJavaScript` call that awaits a never-resolving Promise hangs forever. A sync `evaluateJavaScript` with an infinite loop pegs the WebContent process.

**Mitigation:** Wrap all async JS in `Promise.race` with a timeout arm (10s default). For the automation API, add a Swift-side `Task` timeout that cancels the continuation and returns an error. Navigation away from the page also cancels pending evaluations.

### 9. WebSocket / SSE connections in suspended tabs

**Likelihood: Medium. Impact: Low (tab reconnects on wake). Threatens product thesis: No.**

Tabs in `.suspended` state (via `inactiveSchedulingPolicy = .suspend`) lose their WebSocket and SSE connections. When the tab is reactivated, the page's reconnection logic must fire.

**Mitigation:** This is standard browser behavior. Well-written web apps handle reconnection. Pages with active audio/media are automatically exempted from suspension.

### 10. Passkeys / WebAuthn

**Likelihood: Growing. Impact: High (can't log into passkey-only sites). Threatens product thesis: No.**

Requires `com.apple.developer.web-browser.public-key-credential` entitlement.

**Mitigation:** Apply for the entitlement early (it's separate from the web-browser entitlement). Not blocking V1 launch; targeted for V1.2.

---

## 9. What Could Make This Genuinely Better Than Safari/Chrome

Five concrete advantages. No buzzwords.

### 1. Every tab is an API endpoint

Today, if a coding agent needs to read a web page, it launches a headless Chromium instance (500 MB download, 2-5s cold start), navigates, extracts, and tears down. Every page read is a fresh session with no cookies, no logged-in state, no history.

With this browser, the agent calls `browser_read_markdown` on the tab the user already has open. The page is already loaded, already authenticated, already at the right scroll position. The round-trip is <50ms, not 5 seconds. The agent reads what the user sees, not a fresh anonymous load of the same URL.

This changes the economics of agent-web interaction from "expensive batch operation" to "free side-channel." Agents will read web pages more often when it's cheap, which makes them better at tasks that involve the web.

### 2. The browser is the user's authenticated proxy

Right now, when you ask an agent to "check my GitHub PR" or "look at that Notion doc," the agent either asks you to paste the content, or uses a headless browser that isn't logged into anything. The whole reason browser-use tools exist is to bridge this gap, badly.

This browser shares the user's real sessions. The agent can read a page the user is logged into without re-authenticating, without storing credentials, without OAuth dance. The browser IS the auth proxy. This is the single most valuable thing about building the agent API into a real browser rather than a headless tool.

### 3. Keyboard-first workflow with agent-powered command palette

The command palette is not just "search bookmarks and history." It's an agent-connected search across all open tab content, history, and bookmarks simultaneously. Type a question, get answers sourced from your actual browsing context.

More importantly: the command palette is the same interface for both human commands ("close all tabs from github.com") and agent-dispatched actions. When an agent calls `browser_new_tab`, the action appears in the same action log the user sees in the sidebar. The human and the agent share a single command surface.

### 4. Terminal/editor integration as a first-class feature

The CLI tool (`browser open`, `browser text`, `browser screenshot`) means any terminal workflow can incorporate the browser. A shell script can scrape a page. A coding agent's `bash` tool can take a screenshot of the running app in the browser for visual verification. An editor plugin can "open in browser" and then "read the page back" to compare rendered output to source.

The connection descriptor at `~/.config/agent-browser/connection.json` means any tool on the machine can discover and connect to the running browser in one read. No configuration, no port guessing, no process discovery.

### 5. Visible agent activity

When an agent interacts with the browser, the user sees what happened. Every agent action is logged: "Agent opened https://...", "Agent clicked 'Submit'", "Agent read page text." The action log is not buried in a terminal transcript -- it's in the browser sidebar, timestamped, next to the tab it affected.

This is the inverse of headless browser automation, where the agent operates invisibly and the user trusts it blindly. Here, the browser is the agent's hands, and the user can watch them move. The user can also interrupt: if the agent is about to click something destructive, the user sees the action in the log and can close the tab or revoke the agent's token.

This transparency is not an AI feature. It's a UI feature that makes agent automation trustworthy enough to actually use in production.

---

## 12. Interactive Automation Layer (v0.3.0)

### Overview

The interactive automation layer lets external agents inspect, identify, and interact with live DOM elements through the same API surface as tab/page operations. No CSS selectors required -- agents receive semantic element handles.

### Architecture

```
automation-bridge.js (injected via WKUserScript in .defaultClient world)
    ↓ evaluateJavaScript
InteractiveAutomation.swift (routing + inspect + types)
InteractiveActions.swift   (click/fill/press/select/wait implementation)
    ↓ routeInteractive / routeInteractiveAsync
BrowserAutomationService.swift (dispatch switch falls through to interactive router)
    ↓
AgentHTTPServer.swift (REST routes: /api/tabs/{id}/inspect, /click, /fill, etc.)
```

### Element Handle Design

Element handles are 6-char hex strings prefixed with `el_` (e.g., `el_a1b2c3`). They are:
- Injected as `data-agentbrowser-id` attributes on DOM elements during `inspect()`
- Resolved via CSS attribute selector `[data-agentbrowser-id="el_xxx"]`
- Scoped to a single inspect generation (stale handles detected via DOM presence check)
- Never silently resolve to the wrong element -- if the DOM changes and the handle's element is gone, the operation fails with `ELEMENT_STALE`

### Semantic Naming Algorithm

Accessible name for each element follows this priority:
1. `aria-label` attribute
2. `aria-labelledby` -> resolved element text
3. Associated `<label>` (via `for` attribute or wrapping)
4. `placeholder` attribute
5. `title` attribute
6. `alt` text (for images)
7. Visible `innerText` (truncated to 100 chars)
8. `name` attribute (last resort)

### Protocol Methods

| Method | Params | Description |
|---|---|---|
| `page.inspect` | `id` | Return compact list of interactive elements with handles |
| `page.click` | `id`, `elementId` | Click element (full mouse event sequence) |
| `page.fill` | `id`, `elementId`, `value` | Fill input/textarea (React-compatible native setter) |
| `page.press` | `id`, `key`, `elementId?` | Press keyboard key (Enter, Escape, Tab, etc.) |
| `page.select` | `id`, `elementId`, `value` | Select dropdown option |
| `page.wait` | `id`, `condition`, `value?`, `timeout?` | Wait for load/url/text/element |

### Error Codes (new)

`ELEMENT_NOT_FOUND`, `ELEMENT_STALE`, `ELEMENT_NOT_INTERACTABLE`, `UNSUPPORTED_ELEMENT`, `WAIT_TIMEOUT`, `NAVIGATION_FAILED`, `INVALID_ARGUMENT`

### Framework Compatibility

The `fill()` action uses the native value setter bypass to work with React, Vue, Angular:
```js
Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set.call(el, value);
el.dispatchEvent(new Event('input', { bubbles: true }));
el.dispatchEvent(new Event('change', { bubbles: true }));
```

### Known Limitations

- **V1 is top-level DOM only.** Same-origin iframes are not traversed. Cross-origin iframes are inaccessible by design (SOP).
- **Shadow DOM:** Open shadow roots could be supported; closed shadow roots cannot. V1 does not traverse shadow DOM.
- **Stale handles after SPA navigation:** A client-side route change may invalidate handles without a full page load. Re-inspect after any navigation.
- **No network interception.** WebKit provides no CDP equivalent.
- **WebGL/video elements** are not captured in screenshots.
