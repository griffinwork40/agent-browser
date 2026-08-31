# BROWSER_SCOPE.md

---

## 1. Executive Summary

We are scoping a native macOS browser built in Swift on WKWebView, designed from the ground up for humans who work alongside AI coding agents.

The core idea: the browser itself is agent-addressable. Every tab is a programmable object that external agents can inspect, navigate, and interact with through a local API. The user browses normally; the agent reads and acts on the same authenticated sessions the user has open.

A technical spike validated the five load-bearing assumptions (JS execution in isolated content worlds, screenshot capture, element enumeration, programmatic click, navigation detection). All passed. The project is a GO.

---

## 2. Product Thesis

A fast, native macOS browser that is excellent for normal browsing and becomes unusually powerful when paired with AI agents.

The distinction: this is not a browser with an AI chatbot sidebar. The browser itself is the programmable surface. External agents can call `browser.tabs()`, `browser.read(tab)`, `browser.click(tab, target)` through a local API. The browser is the user's authenticated proxy to the web, and agents operate through it rather than around it.

The competitive position is not "better rendering engine" or "better tab UI." It is: **no other browser treats its own state as a set of programmable primitives that external processes can address.**

---

## 3. Technical Feasibility

**GO. No blockers found.**

The concept is technically viable and multiple working implementations already exist (mcp-browser, aslan-browser). The core stack -- Swift + WKWebView + local HTTP server on loopback -- is a proven pattern.

A spike at `spike/BrowserSpike.swift` validated:

| Assumption | Result | Detail |
|---|---|---|
| AppKit hosts WKWebView without SwiftUI | Passed | Pure NSApplication + NSWindow + WKWebView |
| JS executes in isolated WKContentWorld | Passed | Page scripts cannot read injected world's variables |
| takeSnapshot captures viewport | Passed | 2560x1800 PNG (Retina 2x), 620KB |
| element.click() triggers navigation delegate | Passed | didFinish fired, new title readable |
| JS enumerates interactive elements with rects | Passed | 229 elements with text + href + bounding rects |

Spike results documented at `spike/SPIKE_RESULTS.md`.

### What is easy, feasible-but-awkward, risky, or impossible

| Operation | Rating | Key constraint |
|---|---|---|
| Execute JS (basic + async/Promises) | Easy | No built-in timeout; void-return crashes async Swift overload (use callback form) |
| Return complex types from JS | Feasible-but-awkward | 6-type whitelist; JSON.stringify required for custom objects |
| Screenshot viewport | Easy | `afterScreenUpdates: true` required for accurate paint |
| Screenshot full page | Feasible-but-awkward | Resize WKWebView frame to content height, or use createPDF |
| Screenshot WebGL/video | Impossible | Hardware-composited layers render blank; canvas.toDataURL() workaround for canvas only |
| Detect real navigation | Easy | Use didCommit for URL bar (not webView.url which updates at start) |
| Detect SPA pushState/hash | Feasible-but-awkward | KVO on url works; inject monkey-patch for full fidelity |
| Observe new windows/popups | Easy | WKUIDelegate; return nil to block, WKWebView to redirect to tab |
| Standard HTTP downloads | Easy | WKDownload + delegate; retain delegate yourself |
| Download progress/resume | Feasible-but-awkward | fileURL KVO never fires; resume is server-dependent |
| blob:/data: URL downloads | Impossible natively | JS FileReader + messageHandlers workaround |
| Intercept HTTP/HTTPS requests | Impossible | WKURLSchemeHandler only handles custom schemes |
| Cross-origin iframe DOM access | Impossible (web standard) | Same-origin iframes fully accessible |

---

## 4. Relevant Apple/WebKit APIs

### Core (V1)

| API | Purpose | macOS version |
|---|---|---|
| `WKWebView` | Web rendering | 10.10+ |
| `WKNavigationDelegate` | Navigation lifecycle (start, commit, finish, fail, redirect) | 10.10+ |
| `WKUIDelegate` | Popups, permission prompts, file uploads, alerts | 10.10+ |
| `evaluateJavaScript(_:in:in:completionHandler:)` | World-scoped JS execution | 11.0+ |
| `callAsyncJavaScript(_:arguments:in:in:)` | Async JS with Promise support | 11.0+ |
| `WKContentWorld` | Isolated JS execution namespaces | 11.0+ |
| `WKUserScript` / `WKUserContentController` | Script injection at page load; message handlers | 10.10+ |
| `WKScriptMessageHandler` / `WithReply` | Page-to-app messaging (one-way and two-way) | 10.10+ / 14.0+ |
| `WKWebsiteDataStore` | Cookie/cache isolation, profiles | 10.11+ |
| `WKWebsiteDataStore(forIdentifier:)` | Named per-profile data stores | 14.0+ |
| `WKHTTPCookieStore` | Cookie get/set/delete/observe | 10.13+ |
| `takeSnapshot(configuration:)` | Viewport screenshots | 10.13+ |
| `createPDF(configuration:)` | Full-page PDF export | 11.0+ |
| `WKDownload` / `WKDownloadDelegate` | Download lifecycle, progress, resume | 11.3+ |
| `WKContentRuleListStore` | Declarative content blocking (Safari-compatible JSON) | 11.0+ |
| `interactionState` | Opaque tab state blob (scroll, form, back/forward) for restore | 12.0+ |
| `WKPreferences.inactiveSchedulingPolicy` | Suspend/throttle background tab JS | 14.0+ |
| `Network.framework (NWListener)` | Local HTTP server on loopback | 12.0+ |

### Future (V2+)

| API | Purpose | macOS version |
|---|---|---|
| `WKWebExtensionController` | Browser extension hosting | 15.4+ |
| `WebView` / `WebPage` (SwiftUI) | Native SwiftUI web view | 26.0+ (Tahoe) |

### Critical behaviors

- **WKWebViewConfiguration is immutable after init.** processPool, websiteDataStore, URL scheme handlers must be set before creating the WKWebView.
- **WKUserContentController is live after init.** addUserScript, addContentRuleList send IPC to the running web process. Scripts added post-init apply to future navigations only.
- **`webView.url` updates eagerly at navigation start, not commit.** Use `didCommit` for URL bar display to prevent spoofing.
- **Destroying a WKWebView does NOT free its process.** WebProcessCache keeps it warm for 30 minutes. Navigate to `about:blank` for real memory reclaim.
- **The `async throws -> Any` Swift overload of evaluateJavaScript crashes on void/undefined returns.** Use the callback form exclusively.
- **NSURLErrorCancelled (-999) fires routinely.** Ignore it in didFailProvisionalNavigation; it's benign when JS triggers a new navigation.

---

## 5. Proposed Architecture

### Principle: AppKit hosts the shell, SwiftUI for embedded UI

WKWebView is an NSView that spawns OS-managed subprocesses. SwiftUI cannot own or reliably size it. AppKit manages windows, WKWebView lifecycle, and the toolbar. SwiftUI is embedded via NSHostingController for the tab sidebar, overlays, and settings.

### Module map

```
UI Layer
├── BrowserWindowController    NSWindowController per window
├── TabSidebarView             SwiftUI vertical tab list via NSHostingController
├── NavigationBar              NSView: back/forward/reload + URL field (NSTextField)
├── WebContentView             NSView: hosts active tab's WKWebView
└── DownloadBar                SwiftUI download progress strip

Browser State
├── BrowserSession             Per-window: tab list, selected tab, sidebar width
├── BrowserTab                 Per-tab: URL, title, lifecycle, lazy WKWebView
├── BrowserWorkspace           Tab group metadata (name, color, tab IDs)
└── ProfileManager             WKWebsiteDataStore factory

WebKit Integration
├── PageController             JS execution, content extraction, screenshots
├── ScriptBridge               Injected JS for DOM inspection/interaction
├── NavigationCoordinator      WKNavigationDelegate
├── UICoordinator              WKUIDelegate (popups, permissions, alerts)
├── DownloadCoordinator        WKDownloadDelegate
└── WebViewFactory             WKWebViewConfiguration + WKWebView creation

Persistence
├── HistoryStore               GRDB + FTS5 (history.db)
├── BookmarkStore              GRDB (browser.db)
├── SessionStore               GRDB (browser.db) + binary files for interactionState
├── AgentStore                 GRDB (agent.db) for permissions and action log
└── PreferencesStore           UserDefaults (custom suite)

Agent / Automation
├── AgentServer                NWListener HTTP on 127.0.0.1
├── AgentAuth                  Keychain-backed bearer tokens, Host/Origin validation
├── ToolRouter                 Maps JSON-RPC calls to BrowserSession/PageController
└── ActionLog                  Records agent actions for user visibility
```

### What talks to what

```
User action -> UI Layer -> BrowserSession -> BrowserTab -> PageController -> WKWebView
                                                                 ^
Agent request -> AgentServer -> ToolRouter -> BrowserSession -----+
```

The UI and the agent API converge at `BrowserSession` and `BrowserTab`. An agent calling `browser.tabs.open(url)` goes through the same `BrowserSession.newTab(url:)` that Cmd+T does. This means agent actions show up in the UI immediately and the action log captures both human and agent activity through the same path.

### Two protocols, no more

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

`BrowserTab` conforms to both. These exist so the agent API can depend on the shape of a tab without depending on WKWebView directly.

---

## 6. Tab/Page Lifecycle Model

### BrowserTab is the core programmable unit

```swift
@Observable @MainActor
final class BrowserTab: Identifiable {
    let id = UUID()
    private(set) var url: URL?
    private(set) var title: String = "New Tab"
    private(set) var favicon: NSImage?
    private(set) var isLoading: Bool = false
    private(set) var loadProgress: Double = 0
    private(set) var canGoBack: Bool = false
    private(set) var canGoForward: Bool = false
    private(set) var lifecycle: Lifecycle = .empty
    private(set) var webView: WKWebView?
    private(set) var pageController: PageController?
    var interactionState: Data?
    var workspaceID: UUID?
    var isPinned: Bool = false

    enum Lifecycle {
        case empty       // No WebView yet (new tab page)
        case loading     // WebView created, navigation in progress
        case live        // Page loaded, in or near viewport
        case suspended   // WebView alive, JS paused (inactiveSchedulingPolicy = .suspend)
        case cold        // interactionState captured, WebView at about:blank
    }
}
```

### State ownership

| Level | Owns | Example |
|---|---|---|
| App | Singletons: HistoryStore, BookmarkStore, AgentServer, ProfileManager | Shared across all windows |
| Window | BrowserSession (tab list, selected tab, sidebar width) | Independent browsing context |
| Workspace | Metadata only (name, color, tab IDs) | References tabs by ID; session owns tabs |
| Tab | URL, title, lifecycle, WKWebView, PageController, interactionState | Everything about one browsing context |
| WebKit | WKWebView, WKWebsiteDataStore, cookies, localStorage | Managed by WebKit; we read via KVO/delegates/JS |

### Memory management

| Tab state | WebView? | Memory | Restore time |
|---|---|---|---|
| `.empty` | nil | ~0 | N/A |
| `.live` | in view hierarchy | ~130 MB | instant |
| `.suspended` | alive, detached | ~130 MB (JS paused, no CPU) | instant |
| `.cold` | at about:blank | ~5-10 MB | 1-2s (re-navigate) |

Strategy: keep the active tab `.live`, last 5-8 accessed tabs `.suspended`, demote the rest to `.cold` on an LRU basis. The LRU check runs every 60 seconds. On memory pressure, aggressively cold the oldest suspended tabs.

50 tabs (5 live + 10 suspended + 35 cold) = ~2.2 GB total WebContent memory.
100 tabs (5 live + 10 suspended + 85 cold) = ~2.6 GB.

`interactionState` (macOS 12+) captures scroll position, form data, and back/forward history as an opaque NSData blob (typically 2-50 KB). Setting it on a WKWebView before navigation restores the user's place.

---

## 7. Browser Automation Design

### Mechanism: injected JS (primary) + WebKit delegates (lifecycle) + KVO (state)

All DOM inspection and interaction runs through JavaScript injected in an isolated `WKContentWorld` named "AgentBridge". This world shares the DOM with the page but has an isolated JS prototype chain -- page scripts cannot tamper with our `document.querySelector` or `getBoundingClientRect`.

WebKit delegate APIs handle navigation lifecycle, popups, downloads, and permissions. KVO bridges `WKWebView` state (`url`, `title`, `isLoading`, etc.) into `@Observable` properties.

### Why not the alternatives

| Alternative | Why not |
|---|---|
| **Accessibility APIs (AXUIElement)** | Requires system permission prompt (hostile onboarding). Slower (~50-100ms vs ~5ms). We own the WKWebView; we don't need a side channel. |
| **DOM serialization to Swift** | Wasteful. Serializing the full DOM across IPC on every call when JS can walk it in-process in 5ms. |
| **WebKit private SPI (_WKAutomationSession)** | Produces truly trusted events, but private API risk. V2 investigation if isTrusted becomes a real problem. |
| **Replicate Playwright** | Over-engineered for a native browser that owns its WebViews. Playwright must control a foreign process; we control our own. |

### ScriptBridge

A single JS file injected via `WKUserScript` at `.atDocumentEnd` in the `AgentBridge` content world. It exposes `window.__agentBridge` with methods:

- `getElements()` -- Walk DOM, find interactive elements, assign refs (`@e0`, `@e1`...) via `data-agent-ref`, return `[{ref, tag, role, text, ariaLabel, rect, inViewport, disabled}]`.
- `click(ref)` -- Find by `data-agent-ref`, scrollIntoView, click.
- `fill(ref, value)` -- Focus, set value, dispatch input + change events.
- `getText()` / `getHTML()` / `getLinks()` / `getMetadata()` / `getPageStructure()` -- Content extraction.
- `waitForSelector(selector, timeout)` -- MutationObserver-based wait.

### Element targeting

```swift
enum ElementTarget {
    case ref(String)          // "@e5" from getElements()
    case selector(String)     // CSS selector
    case text(String)         // Visible text match
    case role(String, String) // ARIA role + name
}
```

### Known limitations

- **`event.isTrusted` is false** for synthetic JS events. ~5% of sites check this. Same limitation as Playwright. Document it; investigate `_WKAutomationSession` for V2.
- **Cross-origin iframes** cannot be inspected (web standard).
- **No JS execution timeout.** Wrap async in `Promise.race` with timeout arm. Add Swift-side `Task` timeout on the automation API.

---

## 8. External Agent Bridge Design

### Transport: local HTTP (MCP over Streamable HTTP) + CLI

| Surface | Purpose | V1? |
|---|---|---|
| HTTP on 127.0.0.1 | MCP JSON-RPC + REST API for agents | Yes |
| CLI tool (`browser`) | bash-accessible commands for agents | Yes |
| MCP registration | Auto-patch Claude Code / AFK / Codex configs | Yes |
| Unix domain socket | Fast path for local tools | V2 |
| AppleScript | Basic tab scripting for power users | V2 |

### MCP tool catalog (V1: 18 tools)

```
browser_list_tabs, browser_new_tab, browser_close_tab, browser_switch_tab
browser_navigate, browser_back, browser_forward, browser_reload, browser_wait_for_load
browser_read_text, browser_read_html, browser_read_markdown
browser_elements, browser_click, browser_fill
browser_screenshot, browser_evaluate_js, browser_wait_for_selector
```

### CLI

```bash
browser tabs                      # list tabs
browser open https://example.com  # new tab
browser text                      # read active tab text
browser markdown                  # read as markdown
browser elements                  # list interactive elements
browser click "@e3"               # click by ref
browser fill "#email" "me@x.com"  # fill field
browser screenshot                # save screenshot
browser eval "document.title"     # run JS
```

---

## 9. Security Model

### Four independent defense layers

| Layer | Mechanism | What it stops |
|---|---|---|
| **Loopback binding** | NWListener bound to 127.0.0.1 only | External machines |
| **Host header validation** | Reject if Host is not `127.0.0.1:<port>` or `localhost:<port>` | DNS rebinding (primary defense) |
| **Origin header validation** | Reject if Origin present and not loopback | CORS misconfiguration |
| **Bearer token** | 32-byte random via SecRandomCopyBytes, Keychain-stored | Web page CSRF, unauthorized local processes |

### Token distribution

Connection descriptor written on launch:

```json
// ~/.config/agent-browser/connection.json (mode 0600)
{"url": "http://127.0.0.1:8833", "token": "...", "pid": 12345, "version": "1.0.0"}
```

Browser optionally auto-patches known MCP configs (`~/.claude.json`, `~/.afk/config/mcp.json`).

### Port selection

Fixed port 8833 with fallback to 8834-8843 on `EADDRINUSE`. Actual bound port written to `connection.json`. Fixed-ish ports give agents a reasonable default without requiring file reads.

### Sandbox posture

Hardened Runtime (required for notarization). No App Sandbox for V1 -- needed for writing agent config files and full download access. Distribute as signed + notarized DMG. Add App Sandbox later if App Store distribution becomes a goal.

---

## 10. Persistence Strategy

| Data | Technology | File | Rationale |
|---|---|---|---|
| **Browsing history** | GRDB + FTS5 | `history.db` (DatabasePool) | High write rate, full-text search, isolated from other tables to avoid WAL contention |
| **Bookmarks** | GRDB | `browser.db` (DatabasePool) | Relational (folders, tags, many-to-many), same pool as session/workspace |
| **Session state** | GRDB | `browser.db` | Tab list, selected tab, window frame. Debounced 500ms writes |
| **Tab interactionState** | Binary files | `TabState/<uuid>.interactionstate` | Opaque blobs up to several MB; SQLite BLOBs cause WAL bloat |
| **Workspaces** | GRDB | `browser.db` | Small, relational (workspace has many tabs) |
| **Settings** | UserDefaults | Custom suite | Flat key-value; survives app updates; trivially readable |
| **Agent permissions** | GRDB | `agent.db` (DatabasePool) | Tokens, action log, rate limits. Separate file for security isolation |
| **Download history** | GRDB | `browser.db` | Low write rate, queryable by date/filename |
| **Favicons** | NSCache + disk LRU | `Caches/favicons/<sha256>.png` | Pure key-value LRU; SQLite BLOBs are wrong here |

### Why GRDB everywhere (and not SwiftData)

SwiftData has no FTS5 support (history search requires it). Mixing GRDB and SwiftData in one app doubles the persistence surface area for no benefit. GRDB's `ValueObservation` drives `@Observable` stores cleanly -- assign results in the `onChange` callback and SwiftUI reacts automatically. `DatabasePool` with WAL mode handles concurrent reads during writes. In-memory databases (`DatabaseQueue()`) make tests fast. GRDB is Swift 6 safe (`Database` closures are non-escaping and non-Sendable by construction).

---

## 11. V1 Scope

The smallest browser you could daily-drive, with the agent foundation built in from day one.

### Includes

**Browser:**
- Single window (multi-window V2)
- Vertical tab sidebar (SwiftUI list via NSHostingController)
- Address bar with URL/search (NSTextField, autocomplete from history)
- Back / forward / reload / stop
- Tab title + favicon in sidebar
- Loading progress indicator
- New tab (Cmd+T), close tab (Cmd+W), reopen closed tab (Cmd+Shift+T)
- Tab switching (click, Cmd+1-9, Ctrl+Tab)
- Find in page (Cmd+F)
- Zoom (Cmd+/-, Cmd+0)
- Full keyboard shortcuts (all standard browser shortcuts)
- Context menus, file uploads, basic popup handling
- Print (Cmd+P)

**Data:**
- Browsing history (searchable)
- Bookmarks (add/remove/folders)
- Session restoration (save on quit, restore on launch)
- Private browsing (non-persistent data store)
- Downloads (progress, open in Finder)
- Settings panel (homepage, search engine)

**Agent:**
- Local HTTP server (always running while browser is open)
- 18-tool MCP catalog
- Bearer token auth + Host/Origin validation
- Connection descriptor file
- CLI tool (`browser`)
- Action log (visible in sidebar)
- Auto-patch Claude Code / AFK / Codex MCP configs

### Why the agent API is in V1

The agent API is the product thesis. A browser without it is just another WebKit wrapper. Building it from day one means the architecture is proven to support automation before we pile on features. The V1 API is intentionally minimal: 18 tools, request/response only, no autonomous workflows.

---

## 12. Explicit Non-Goals

| Feature | Why not V1 | When |
|---|---|---|
| Web extensions | WKWebExtensionController is young; large API surface | V2 |
| Content blocking / ad blocker | Rule list curation is a separate project | V2 |
| Multiple windows | Session management complexity | V2 |
| Tab groups / workspaces | Data model supports them; UI is scope | V2 |
| Split panes | Multiple simultaneous WKWebViews, memory + layout | V2 |
| Command palette | Valuable but not foundational | V2 |
| User profiles | Easy to implement; profile-switching UI is scope | V2 |
| Password autofill | Requires Apple-managed `web-browser` entitlement | V2+ |
| WebAuthn / Passkeys | Requires separate Apple entitlement | V1.2 (apply early) |
| Default browser registration | Private API; Apple-relations risk | V2 |
| Sync | Cloud infra, accounts, conflict resolution | Not planned |
| iOS / cross-platform | macOS only | Not planned |
| Custom rendering engine | We use WebKit | Never |
| DevTools | Safari's Web Inspector exists; building our own is years of work | Never |
| Reader mode | JS Readability injection; polish | V2 |
| AI chatbot sidebar | Not the thesis | V3+ if ever |
| Autonomous agent workflows | V1 API is request/response; orchestration is higher-level | V3+ |

---

## 13. Technical Risks

Ranked by threat to product thesis.

### Threatens the thesis

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| **JS execution timeout** (agent hangs on never-resolving Promise) | Medium | Agent becomes unreliable | Promise.race with timeout arm; Swift-side Task timeout; navigation cancels pending evals |
| **`event.isTrusted` detection** (5% of sites reject synthetic clicks) | Low | Agent can't interact with those sites | Document limitation; investigate `_WKAutomationSession` for V2 |
| **Website compatibility** (OAuth popups, bot detection, user-agent sniffing) | Medium | Users can't daily-drive it | Dogfood immediately; Safari-like user agent; correct popup handling |

### Does not threaten the thesis

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| Memory with many tabs | Certain | Performance degradation at 50+ tabs | LRU cold/suspend/live lifecycle; ~2.2 GB at 50 tabs |
| Cross-origin iframe restrictions | Certain | Can't inspect cross-origin iframes | Web standard; screenshot fallback; wait for redirect to main frame |
| blob:/data: URL downloads | Medium | JS-generated exports fail | JS FileReader + messageHandler workaround |
| WebRTC (video calls) | High | Google Meet etc. | Include camera/mic entitlements + Info.plist strings from day one |
| DRM (Netflix) | Low | Streaming media fails | Not V1 priority; investigate FairPlay entitlements if reported |
| Passkeys | Growing | Can't log into passkey-only sites | Apply for entitlement early |
| WebSocket/SSE in suspended tabs | Medium | Connections drop in background | Standard browser behavior; pages reconnect on wake |

---

## 14. Product Differentiation

Five advantages, with honest assessment of why each is meaningfully better rather than merely different.

### 1. Every tab is an API endpoint

**Why it's better, not just different:**

Today when a coding agent needs web content, it launches a headless Chromium (500 MB, 2-4s cold start), navigates to a URL with no auth, waits for load, extracts, tears down. Every page read is a fresh anonymous session.

With this browser, the agent calls `browser_read_markdown` on the tab already open. The page is already loaded, already authenticated, already at the right scroll position. Round-trip is <100ms. The agent reads what the user sees.

This changes the economics of agent-web interaction from "expensive batch operation" to "near-free side-channel." When reading a web page costs <100ms instead of 5 seconds, agents will do it more often, which makes them better at tasks that involve the web.

**Concrete examples:**
- User has 12 tabs from a research session including paywalled articles (institutional access), a Notion doc, and a Google Sheet. Agent synthesizes across all of them. Today: impossible without user pasting each.
- Agent reviewing a PR cross-references MDN pages, a GitHub discussion, and a library changelog -- all already open. Today: burns tokens re-fetching stale versions.
- Agent asked "flag any HubSpot deal in negotiation >30 days with no matching Linear ticket" reads both dashboards from the already-rendered, already-filtered tabs. Today: requires OAuth setup for two separate APIs.

### 2. Browser as authenticated proxy

**Why it's better, not just different:**

This is the strongest advantage. The set of accessible sites changes qualitatively, not just quantitatively.

Headless browsers fail on: SSO/SAML flows with MFA, Cloudflare/DataDome bot detection, session-bound tokens tied to browser TLS fingerprint, HTTPOnly cookies that JS can't extract. Cookie injection from a separate store fails because backends check device fingerprint + session binding.

The authenticated proxy model sidesteps all of this. The agent's requests go through the user's already-authenticated browser session. They are indistinguishable from the user navigating normally.

What becomes accessible: internal company tools (any SSO-gated service), banking dashboards, LinkedIn, paywalled articles, SaaS platforms without public APIs (Airtable, Notion, HubSpot reporting).

The security model is better than giving the agent a password: the agent never sees credentials, cannot re-authenticate independently, and operates within the user's existing session with the user's existing permissions. Revoke the bearer token and the agent loses all access instantly.

### 3. Keyboard-first workflow with agent command palette

**Why it's better, not just different:**

A standard browser command palette searches bookmarks and history by title/URL. This one searches across open tab *content* -- not titles, the actual page text. "Which of my open tabs mentions the pricing change?" becomes a single keystroke query.

But the honest assessment: this advantage is execution-dependent. It only works if the palette is fast. A 3-second latency on commands means it never becomes a habit. The content-search capability is real and local (no model inference required for search). The agent-powered natural language commands ("close all tabs from github.com") require inference latency that current models don't reliably deliver for interactive use.

**Verdict: real but weakest of the five. It's a V2 feature for good reason.**

### 4. Terminal/editor integration

**Why it's better, not just different:**

`browser read-text` from a terminal gives you the rendered, JS-executed, authenticated content of whatever the user is looking at. `curl` gives you raw HTML without JS execution or auth. Readability-CLI gives you cleaned text without auth. Neither gives you the actual rendered state of a logged-in session.

The connection descriptor at `~/.config/agent-browser/connection.json` means any tool on the machine discovers the running browser in one file read. Chrome DevTools Protocol requires knowing the debug port, which requires launching Chrome with `--remote-debugging-port`, which requires restarting Chrome, which means losing all your sessions. The connection descriptor is always there with no setup.

**Honest assessment: this is a real but niche workflow.** Most developers aren't bottlenecked by "how do I get browser content into my terminal." It matters to tool builders and power users, not to most end users.

**Verdict: real advantage, lowest user-visible impact of the five.**

### 5. Visible agent activity

**Why it's better, not just different:**

This is about trust, not capability. Playwright trace viewer shows you what happened after the fact -- excellent for debugging, useless for real-time oversight. Headless operation is invisible. Browser DevTools is a low-level firehose. None of these is a supervision interface.

The browser itself as the agent's workspace changes the trust model: the agent operates in your visual space, you can see and interrupt at any time. The default assumption shifts from "fully delegated" (risky) or "fully supervised" (defeats the purpose) to "loosely supervised" (efficient and trustworthy).

What makes it work beyond "a log":
- **Tab highlighting**: when the agent reads or interacts with a tab, that tab gets a visual indicator.
- **Intent display**: before acting, show what the agent intends ("Reading pricing section" not "clicking (x,y)").
- **Pause-and-redirect**: keyboard shortcut pauses the agent for course correction without losing state.
- **Write-action preview**: form submissions show a preview before executing.

**Verdict: second strongest advantage after authenticated proxy. Determines adoption -- users won't delegate to what they can't see.**

### Ranked by impact

1. **Authenticated proxy** -- qualitative capability gap
2. **Visible agent activity** -- trust gap that determines adoption
3. **Tab as API endpoint** -- meaningful latency/convenience improvement; strongest when combined with #1
4. **Command palette** -- real but execution-dependent; V2
5. **Terminal integration** -- real but niche

---

## 15. Proposed Repo/Module Structure

```
AgentBrowser/
├── AgentBrowser.xcodeproj/
│   └── xcshareddata/xcschemes/
│       ├── AgentBrowser.xcscheme
│       └── browser-ctl.xcscheme
│
├── AgentBrowserApp/                    # App target (thin shell)
│   ├── Info.plist
│   ├── AgentBrowser.entitlements
│   ├── Assets.xcassets/
│   ├── App/
│   │   ├── AgentBrowserApp.swift       # @main entry
│   │   ├── AppDelegate.swift           # NSApplicationDelegate, menu bar
│   │   └── AppState.swift              # Global @Observable
│   ├── Windows/
│   │   ├── BrowserWindowController.swift
│   │   └── BrowserWindow.swift
│   ├── UI/
│   │   ├── Toolbar/
│   │   │   ├── AddressBar.swift
│   │   │   └── NavigationButtons.swift
│   │   ├── Sidebar/
│   │   │   ├── TabListView.swift
│   │   │   └── TabRowView.swift
│   │   ├── WebContentView.swift
│   │   └── Settings/
│   │       └── SettingsView.swift
│   └── Resources/
│       └── Scripts/
│           └── agent-bridge.js
│
├── browser-ctl/                        # CLI target
│   ├── main.swift
│   └── Commands/
│
├── Packages/
│   └── BrowserKit/                     # Local Swift Package
│       ├── Package.swift
│       └── Sources/
│           ├── BrowserCore/            # Models, protocols. No frameworks.
│           │   ├── Models/
│           │   │   ├── Tab.swift
│           │   │   ├── Session.swift
│           │   │   └── Workspace.swift
│           │   ├── Protocols/
│           │   │   ├── PageInspectable.swift
│           │   │   └── Navigable.swift
│           │   └── Types/
│           ├── BrowserEngine/          # WKWebView layer. Only module that imports WebKit.
│           │   ├── PageController.swift
│           │   ├── ScriptBridge.swift
│           │   ├── NavigationCoordinator.swift
│           │   ├── UICoordinator.swift
│           │   ├── DownloadCoordinator.swift
│           │   └── WebViewFactory.swift
│           ├── BrowserPersistence/     # GRDB. History, bookmarks, sessions.
│           │   ├── Database.swift
│           │   ├── Migrations/
│           │   └── Stores/
│           │       ├── HistoryStore.swift
│           │       ├── BookmarkStore.swift
│           │       └── SessionStore.swift
│           └── BrowserAgent/           # HTTP server, MCP, auth.
│               ├── Server/
│               │   └── AgentHTTPServer.swift
│               ├── MCP/
│               │   ├── ToolRouter.swift
│               │   └── Tools/
│               └── Auth/
│                   └── AgentAuth.swift
│       └── Tests/
│           ├── BrowserCoreTests/
│           ├── BrowserPersistenceTests/
│           └── BrowserAgentTests/
│
├── spike/                              # Technical spike (disposable)
│   ├── BrowserSpike.swift
│   ├── build.sh
│   └── SPIKE_RESULTS.md
│
├── docs/
├── scripts/
├── BROWSER_SCOPE.md
├── DESIGN.md
├── ARCHITECTURE.md
└── README.md
```

### Key structural rules

1. **WebKit is imported only inside `BrowserEngine`.** Everything above works in plain value types. The CLI and persistence layer compile and test without a display.
2. **Use GRDB-dynamic** (not GRDB) because both the app and CLI targets link BrowserPersistence. Dynamic avoids duplicate symbols.
3. **Swift Testing** for package tests; XCTest for UI automation.
4. **Start with folders in one target** if the local package feels like too much scaffolding on day one. Extract the package when the CLI target needs shared code. The refactor is mechanical.

---

## 16. Vertical-Slice Implementation Roadmap

### Phase 0: Technical spike (COMPLETE)

**Objective:** Validate core WKWebView assumptions.

**Deliverables:** `spike/BrowserSpike.swift`, `spike/SPIKE_RESULTS.md`

**Status:** All 5 assumptions validated. JS isolation, screenshots, element extraction, programmatic click, navigation detection all confirmed working.

---

### Phase 1: One-tab browser

**Objective:** A single window showing one WKWebView with working navigation.

**Deliverables:**
- Xcode project with AppKit window + WKWebView
- Address bar (NSTextField) that loads URLs and searches
- Back / forward / reload / stop buttons
- Page title in window title bar
- Loading progress bar
- WKNavigationDelegate wired: commit, finish, fail, redirect
- WKUIDelegate wired: basic popup handling (open in same view or block)
- Basic keyboard shortcuts (Cmd+L focus address bar, Cmd+R reload, Cmd+[ back, Cmd+] forward)

**Dependencies:** None (greenfield).

**Key technical questions:**
- NSWindow layout: manual frame NSView or simpler approach for single-tab?
- Address bar: NSTextField directly or NSSearchField?

**Acceptance criteria:**
- Can navigate to any URL, including HTTPS
- Back/forward/reload work
- Page title updates
- Can use Google (search from address bar)
- OAuth popup flow works (test with GitHub login)
- Cmd+L focuses address bar

---

### Phase 2: Real tab system

**Objective:** Multiple tabs with a vertical sidebar, tab switching, and lifecycle management.

**Deliverables:**
- `BrowserSession` and `BrowserTab` models (@Observable)
- Vertical tab sidebar (SwiftUI via NSHostingController)
- Tab creation (Cmd+T), closing (Cmd+W), switching (click, Cmd+1-9)
- Reopen closed tab (Cmd+Shift+T)
- Only the active tab's WKWebView in the view hierarchy
- Tab lifecycle: .empty / .live (others deferred to Phase 4)
- Favicon loading and display in sidebar
- New tab page (blank or simple start page)

**Dependencies:** Phase 1 (window + navigation working).

**Key technical questions:**
- NSHostingController sizing with `sizingOptions = []` to prevent layout cycles
- Manual frame layout for sidebar + content split
- KVO-to-Observable bridge implementation

**Acceptance criteria:**
- Can open 10+ tabs and switch between them
- Only one WKWebView in the view hierarchy at a time
- Tab sidebar shows title + favicon for each tab
- Closing all tabs shows new tab page
- Cmd+T / Cmd+W / Cmd+1-9 work

---

### Phase 3: Persistence

**Objective:** History, bookmarks, session restore, settings.

**Deliverables:**
- GRDB setup: `history.db` with FTS5, `browser.db` for bookmarks/sessions
- `HistoryStore`: write on navigation commit, FTS5 search
- `BookmarkStore`: add/remove/folders, star icon in address bar
- `SessionStore`: save tab list + selected tab on quit, restore on launch
- `interactionState` capture: save to binary files, restore on tab activation
- Settings panel: homepage URL, search engine, clear history
- History panel (Cmd+Y): searchable list
- Bookmarks panel: folder tree + flat list

**Dependencies:** Phase 2 (tab system).

**Key technical questions:**
- GRDB DatabasePool setup with proper migrations
- Debounced session writes (500ms) vs. immediate on quit
- interactionState blob size management

**Acceptance criteria:**
- History is searchable (type partial title or URL, find it)
- Bookmarks survive app restart
- Quitting and relaunching restores all tabs at their previous URLs
- interactionState restores scroll position on cold tab activation
- Address bar autocomplete draws from history

---

### Phase 4: Browser polish

**Objective:** Daily-driver quality. Everything needed to use it as your main browser for a week.

**Deliverables:**
- Full keyboard shortcuts (all standard browser shortcuts)
- Context menus on web content
- Find in page (Cmd+F)
- Zoom (Cmd+/-, Cmd+0)
- Downloads: WKDownload delegate, progress bar, open-in-Finder
- Download manager panel
- Private browsing: non-persistent data store, visual indicator
- File uploads
- Camera/microphone permission prompts (WebRTC)
- Tab lifecycle: `.suspended` and `.cold` states, LRU demotion
- Print (Cmd+P)
- Drag-and-drop tab reordering
- Middle-click to open link in new tab

**Dependencies:** Phase 3 (persistence -- downloads need history).

**Key technical questions:**
- inactiveSchedulingPolicy timing: when to suspend, when to cold
- Download delegate retention (WKDownView doesn't retain it)
- blob: URL download workaround

**Acceptance criteria:**
- Can daily-drive for a week without reaching for Safari/Chrome
- Downloads work (including JS-triggered)
- Google Meet video call works
- GitHub OAuth login flow works
- Private browsing tabs don't persist data
- 20+ tabs without noticeable slowdown

---

### Phase 5: Internal automation layer

**Objective:** PageController and ScriptBridge working internally, before any external exposure.

**Deliverables:**
- `ScriptBridge`: agent-bridge.js injected at page load in AgentBridge content world
- `PageController`: Swift API over ScriptBridge
  - `extractText()`, `extractHTML()`, `extractMarkdown()`
  - `getInteractiveElements()` returns `[ElementInfo]`
  - `click(target)`, `fill(target, value)`
  - `screenshot(rect:)`, `evaluate(script:)`
  - `waitForLoad()`, `waitForSelector(selector, timeout:)`
- Element ref system: `@e0`, `@e1` ... via `data-agent-ref` attributes
- Internal tests: extract elements from a known page, click, verify navigation

**Dependencies:** Phase 2 (tab system). Can be developed in parallel with Phase 3/4.

**Key technical questions:**
- Content world isolation verification (page can't read our globals)
- JS timeout wrapper implementation (Promise.race)
- Markdown extraction quality (Readability + Turndown or custom)

**Acceptance criteria:**
- `pageController.getInteractiveElements()` returns correct elements for HN, GitHub, Google
- `pageController.click(.text("Sign in"))` triggers navigation on GitHub
- `pageController.fill(.selector("#search"), value: "test")` fills Google search
- `pageController.screenshot()` returns a valid NSImage
- `pageController.extractMarkdown()` produces clean readable markdown

---

### Phase 6: External agent bridge

**Objective:** External agents can control the browser through a local API.

**Deliverables:**
- `AgentServer`: NWListener HTTP on 127.0.0.1:8833
- `AgentAuth`: Keychain bearer token, Host/Origin validation
- `ToolRouter`: 18 MCP tools mapped to BrowserSession + PageController
- MCP JSON-RPC endpoint at POST /mcp
- SSE event stream at GET /mcp
- Connection descriptor file at `~/.config/agent-browser/connection.json`
- Auto-patch Claude Code / AFK / Codex MCP configs
- `ActionLog`: records all agent actions, visible in sidebar
- `browser-ctl` CLI: separate Xcode target, ArgumentParser commands
- `agent.db`: token storage, action log, rate limiting

**Dependencies:** Phase 5 (PageController must be working).

**Key technical questions:**
- NWListener HTTP parsing: manual or SwiftNIO?
- MCP Streamable HTTP transport implementation
- Token rotation UX

**Acceptance criteria:**
- AFK / Claude Code can discover the browser via MCP config and use all 18 tools
- `browser-ctl tabs` lists open tabs from the terminal
- `browser-ctl click "@e3"` clicks an element in the active tab
- Agent actions appear in the browser's action log
- A web page loaded in the browser cannot reach the API (Host validation works)
- Revoking the token immediately blocks agent access

---

### Phase 7: AI-native differentiators

**Objective:** Features that make the agent-browser combination genuinely better than browser + separate agent.

**Deliverables:**
- Tab content search (search across all open tabs' text, no model required)
- "Ask this page" (agent-powered Q&A about current tab content)
- "Summarize tab" (agent-powered summary)
- Agent activity overlay (tab highlighting, intent display)
- Pause-and-redirect (keyboard shortcut to interrupt agent)
- Write-action preview (form submission preview before executing)

**Dependencies:** Phase 6 (agent bridge must be working).

**Key technical questions:**
- Content search indexing: when to extract/cache tab text? Memory budget?
- Agent overlay UX: NSPanel over web content? HTML injection? Both?
- Pause semantics: how to interrupt an in-flight MCP tool call?

**Acceptance criteria:**
- Content search across 10 open tabs returns results in <500ms
- "Ask this page" produces a useful answer about any page
- Agent activity overlay shows intent before acting
- Pause shortcut interrupts agent mid-action and allows redirect

---

## 17. Open Questions

1. **Project name.** "Agent Browser" is a working name. Needs a real name before Xcode project creation.
2. **License.** MIT? Apache 2.0? Proprietary?
3. **SwiftNIO vs raw NWListener for HTTP.** NWListener is zero-dependency but requires manual HTTP parsing. SwiftNIO adds a dependency but gives HTTP + WebSocket parsing for free. Decision needed before Phase 6.
4. **macOS 14 vs 15 minimum.** macOS 14 gets named data stores + inactiveSchedulingPolicy. macOS 15 adds web extensions (15.4). Recommend 14 for V1 (broader reach), add extension support when targeting 15.
5. **Apply for Apple entitlements now?** `com.apple.developer.web-browser` and `web-browser.public-key-credential` take time. Start the process during Phase 1-2.
6. **Markdown extraction approach.** Bundle Readability.js + Turndown.js and inject them? Or write a Swift-native extractor? JS injection is faster to ship; Swift-native is faster to execute.

---

## 18. Recommended Immediate Next Step

**Create the Xcode project and build Phase 1: one-tab browser.**

Concrete actions:
1. Pick a project name.
2. Create the Xcode project with the directory structure from Section 15 (start with folders in one target; extract BrowserKit package when the CLI target arrives in Phase 6).
3. Build Phase 1: NSWindow + WKWebView + NSTextField address bar + back/forward/reload + WKNavigationDelegate + basic keyboard shortcuts.
4. Simultaneously: apply for `com.apple.developer.web-browser` entitlement (it takes weeks).
5. Target: Phase 1 complete in one sprint. Phase 2 in the next.

The spike proved the WebKit foundation is sound. Phase 1 is the smallest vertical slice that produces a thing you can actually use to load a web page. Everything else builds on it.
