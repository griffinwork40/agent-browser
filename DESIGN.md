# Agent Browser: Design Document

> A native macOS browser designed for humans working alongside AI agents.

**Status**: Research & scoping complete. Ready for architecture approval before implementation.

---

## 1. Feasibility Verdict

**Yes. This is technically viable.**

The concept is not speculative -- multiple working implementations already exist in the wild (mcp-browser, aslan-browser, Ora Browser). The core stack -- Swift + WKWebView + a local MCP server on loopback -- is a proven pattern. Every major agent action we want (inspect, click, fill, extract, screenshot) is achievable through WKWebView's public APIs.

### What works cleanly

| Capability | Mechanism | Confidence |
|---|---|---|
| Open/close/navigate tabs | WKWebView lifecycle + WKNavigationDelegate | Rock-solid |
| Read page text & HTML | `evaluateJavaScript("document.body.innerText")` in isolated content world | Rock-solid |
| Page screenshots | `WKWebView.takeSnapshot(configuration:)` | Rock-solid |
| Execute arbitrary JS | `evaluateJavaScript(_:in:contentWorld:)` async, `callAsyncJavaScript` | Rock-solid |
| Inject scripts at page load | `WKUserScript` at `.atDocumentStart` / `.atDocumentEnd` | Rock-solid |
| Identify interactive elements | Injected JS DOM walker with `getBoundingClientRect`, ARIA, visibility checks | Solid (0.5-2ms round-trip) |
| Click elements | `element.click()` or `dispatchEvent(new MouseEvent(...))` via JS | Solid (caveats below) |
| Fill form fields | `element.focus(); element.value = x; element.dispatchEvent(new InputEvent(...))` | Solid for most sites |
| Extract structured page data | JS-based DOM traversal in isolated content world | Solid |
| Cookie management | `WKHTTPCookieStore` (get/set/delete/observe) | Rock-solid |
| Downloads | `WKDownload` + `WKDownloadDelegate` (macOS 11.3+) | Rock-solid |
| PDF export | `WKWebView.createPDF(configuration:)` | Rock-solid |
| Private browsing | `WKWebsiteDataStore.nonPersistent()` | Rock-solid |
| User profiles | `WKWebsiteDataStore(forIdentifier: UUID)` (macOS 14+) | Rock-solid |
| Web extensions | `WKWebExtensionController` (macOS 15.4+) | Solid but young |
| Content blocking | `WKContentRuleListStore` (declarative, Safari-compatible JSON) | Rock-solid |
| Local agent API | `NWListener` HTTP on 127.0.0.1 with bearer token | Proven in production |
| Page-to-Markdown | JS extraction of DOM + client-side Turndown/Readability | Solid |
| Shadow DOM traversal | `element.shadowRoot.querySelector(...)` via JS | Standard web API, fully works |

### Known limitations & hard edges

| Limitation | Impact | Workaround |
|---|---|---|
| **Cannot intercept HTTP/HTTPS requests** | No ad blocking via request modification, no request header injection | Use `WKContentRuleListStore` for declarative blocking. Proxy via `WKWebsiteDataStore.proxyConfigurations` for routing. |
| **`event.isTrusted` detection** | Some sites reject synthetic JS clicks/input | Most sites accept them. For true trusted events, would need `_WKAutomationSession` (private SPI). Not a blocker for 95%+ of use cases. |
| **Cross-origin iframe DOM access** | Cannot read a cross-origin iframe's DOM content | Same-origin iframes fully accessible. Cross-origin follows web standard (correct behavior). `WKFrameInfo`-targeted JS eval partially available. |
| **No native DOM API from Swift** | All DOM access requires JS round-trips | Sub-2ms latency makes this negligible. Content worlds provide tamper resistance. |
| **WKWebView memory: ~130 MB per live tab** | Limits practical tab count | LRU hibernation via `interactionState` capture. Keep 5-8 live, rest cold (~39 MB residual). |
| **WKProcessPool deprecated** | Cookie sharing mechanism changed | Use `WKWebsiteDataStore` for isolation. Process pool still needed for extension controller sharing. |
| **Default browser registration** | `LSSetDefaultHandlerForURLScheme` is private API | All major third-party browsers (Arc, Orion) use it. Not App Store compatible. |
| **WebKit controls process lifecycle** | Cannot force-terminate a WebContent process | `WebProcessCache` keeps processes warm. COLD state (navigate to about:blank) is the practical reclaim strategy. |
| **No HTTP request body in WKURLSchemeHandler** | POST bodies stripped for CORS reasons on custom schemes | Not relevant for the core use case. |
| **URL bar spoofing risk** | `webView.url` updates at navigation start, not commit | Track commit-phase URL from `webView(_:didCommit:)` for display. |

### Verdict on agent actions specifically

> Can we reliably support: inspect page content, identify interactive elements, click elements, fill forms, extract visible text, extract semantic page structure?

**Yes to all.** The mechanism is JavaScript injection in an isolated content world (`WKContentWorld`). This is the same approach Playwright uses internally, and it's what mcp-browser and aslan-browser ship today. Round-trip latency for a full accessibility tree walk is 5-15ms on a typical page.

The only edge cases are:
- Sites that check `event.isTrusted` (rare, same limitation as Playwright)
- Closed shadow DOM roots (web standard, not a WebKit limitation)
- Cross-origin iframes (web security, not a limitation to work around)

---

## 2. Architecture

### Core principle: AppKit as host, SwiftUI as embedded UI

WKWebView is an AppKit object (`NSView`) that spawns OS-managed subprocesses. SwiftUI cannot own or reliably size it. The architecture is therefore **AppKit-first for the shell**, with SwiftUI injected via `NSHostingController` for UI components (sidebar, overlays, settings, command palette).

### SwiftUI WebView/WebPage (macOS 26+) -- future option, not V1

Apple shipped `WebView` and `WebPage` as first-class SwiftUI types at WWDC25 (macOS 26 / Tahoe). These are `@Observable`-native, support async navigation events, JS execution via `page.callJavaScript()`, PDF/archive export, and `Transferable` conformance. However:

- **macOS 26 is the minimum deployment target** -- not yet broadly deployed
- The SwiftUI `WebView` lacks the fine-grained control needed for a full browser (no `WKNavigationDelegate` equivalent, limited configuration surface)
- `WKWebView` remains the correct choice for V1

**Plan**: Build V1 on `WKWebView`. Evaluate migrating the web content layer to `WebPage` once macOS 26 is the minimum target and the API surface matures.

### Application structure

```
BrowserApp (@main, SwiftUI App entry point)
|
+-- BrowserWindowController (NSWindowController, one per window)
|   +-- BrowserWindow (NSWindow subclass, transparent titlebar)
|   +-- MainSplitView (NSView, manual frame layout -- NOT NSSplitViewController)
|       +-- SidebarHostingController (NSHostingController<TabSidebarView>)
|       |   +-- TabSidebarView (SwiftUI: vertical tab list, tab groups, drag reorder)
|       +-- ContentArea (NSView)
|           +-- ToolbarView (NSView: back/forward/URL field/reload/extensions)
|           +-- WebViewController (NSViewController, hosts active tab's WKWebView)
|
+-- TabManager (@Observable, @MainActor, per-window)
|   +-- [BrowserTab] (@Observable, lazy WKWebView?, interactionState)
|
+-- TabGroupManager (@Observable, @MainActor, app-global)
+-- ProfileManager (WKWebsiteDataStore factory, per-profile isolation)
+-- HistoryStore (GRDB.swift + SQLite FTS5, actor-isolated)
+-- BookmarkStore (SwiftData, ModelContext)
+-- SessionStore (Codable JSON, debounced writes)
+-- DownloadManager (WKDownloadDelegate, progress tracking)
+-- ExtensionManager (WKWebExtensionController, shared process pool)
+-- BrowserConfig (WKWebViewConfiguration factory, singleton base config)
|
+-- AgentServer (NWListener on 127.0.0.1, MCP + direct HTTP)
|   +-- MCPToolCatalog (40+ tools)
|   +-- ScriptBridge (injected JS for DOM inspection/interaction)
|   +-- AuthManager (Keychain-backed bearer tokens)
|
+-- Overlays (NSPanel, floating above window)
    +-- CommandPalette (SwiftUI)
    +-- AutocompleteDropdown (SwiftUI in child NSPanel)
```

### Key architectural decisions

| Decision | Choice | Rationale |
|---|---|---|
| Window management | `NSWindow` + `NSWindowController` | `WindowGroup` cannot control titlebar, styleMask, or intercept native tab events |
| Root layout | Manual `NSView` frame layout | `NSSplitViewController` causes layout cycles with `NSHostingController`. `NSToolbar` with custom views conflicts with `fullSizeContentView`. |
| Tab bar | Custom SwiftUI `List`/`LazyVStack` via `NSHostingController` | Full styling control, `@Observable` reactivity, drag reorder |
| WKWebView hosting | `NSViewController` (not `NSViewRepresentable`) | Avoids sizing/clipping bugs, proper focus/responder chain |
| Address bar | `NSTextField` subclass | Key event interception, inline autocomplete, focus management with WKWebView |
| Observation system | `@Observable` (macOS 14+ / Swift 5.9) | Property-level granularity, simpler than `ObservableObject`. Never mix the two. |
| Process isolation | `WKWebsiteDataStore` per profile | `WKProcessPool` deprecated for isolation. DataStore controls network process. |
| Tab memory | Lazy creation + LRU COLD hibernation | ~130 MB per live tab. Capture `interactionState`, navigate to `about:blank`. COLD = ~39 MB. Keep 5-8 live. |
| Inactive tabs | `inactiveSchedulingPolicy = .suspend` (macOS 14+) | Halts JS without destroying process |
| History storage | GRDB.swift + SQLite FTS5 | High write rate, full-text search, complex queries |
| Bookmarks | SwiftData | Low write rate, relational (folders/tags), SwiftUI integration |
| Session restore | Codable JSON + binary `interactionState` files | Simple, fast, no schema overhead |
| Extensions | `WKWebExtensionController` (macOS 15.4+) | Native Safari extension format. All views sharing an extension controller MUST share the same process pool -- always `.copy()` from base config. |
| Content blocking | `WKContentRuleListStore` | Declarative, Safari-compatible JSON rules. Precompile and cache at launch. |
| Distribution | Signed + notarized DMG (outside App Store) | Default browser registration requires private API. All major third-party browsers do this. |
| Minimum macOS | macOS 15 (Sequoia) | Gets us: named data stores (14), inactiveSchedulingPolicy (14), web extensions (15.4), modern Swift concurrency |

### Known AppKit pitfalls to avoid

These are confirmed bugs/issues from real browser projects (blur-browser, Kestrel):

1. **Never use `NSSplitViewController`** with `NSHostingController` children -- causes infinite layout cycles
2. **Never use `NSToolbar` with custom `NSView` items** in `fullSizeContentView` mode -- conflicts with toolbar layout
3. **Always `.copy()` `WKWebViewConfiguration`** from a base config -- never create fresh configs when extensions are involved (breaks shared process pool)
4. **`NSHostingController` `sizingOptions`** must be set to `[]` (empty) to prevent it from fighting with manual layout
5. **WKWebView `interactionState`** is an opaque blob -- do not attempt to decode or modify it
6. **Destroying a `WKWebView` does NOT terminate its WebContent process** -- WebProcessCache keeps it warm. COLD (navigate to about:blank) is more effective than STUB (dealloc).

---

## 3. Agent API Design

### Transport: MCP over HTTP (Streamable HTTP)

The agent API is a local HTTP server bound to `127.0.0.1` serving MCP-compatible JSON-RPC.

```
Agent (Claude Code, AFK, Codex, etc.)
    |
    | HTTP POST /mcp   (JSON-RPC 2.0, Authorization: Bearer <token>)
    | HTTP GET  /mcp   (SSE stream for server-initiated events)
    |
MCP Server (NWListener, 127.0.0.1:8833)
    |
    | @MainActor dispatch to BrowserTab/TabManager
    |
WKWebView + ScriptBridge (injected JS in isolated content world)
```

### Authentication & security

| Layer | Defense |
|---|---|
| **Loopback binding** | `NWListener` bound to `127.0.0.1` only. External machines cannot connect. |
| **Bearer token** | Per-launch random token stored in Keychain. Every request requires `Authorization: Bearer <token>`. |
| **Host header validation** | Reject requests where `Host` is not `127.0.0.1:<port>` or `localhost:<port>`. Stops DNS rebinding. |
| **Origin header validation** | If `Origin` present and not loopback, reject. Stops web page CSRF. |
| **Token rotation** | Rotatable from browser settings. Agents re-read config on rotation. |

### Tool catalog (initial)

**Tab management**:
- `browser.tabs.list()` -- list all open tabs with id, url, title, isActive
- `browser.tabs.open(url)` -- open new tab, return tab id
- `browser.tabs.close(tabId)` -- close a tab
- `browser.tabs.switch(tabId)` -- switch to a tab
- `browser.tabs.current()` -- get active tab info

**Navigation**:
- `browser.navigate(url, tabId?)` -- navigate tab to URL
- `browser.back(tabId?)` -- go back
- `browser.forward(tabId?)` -- go forward
- `browser.reload(tabId?)` -- reload
- `browser.waitForLoad(tabId?)` -- wait for page load to complete

**Page reading**:
- `browser.page.text(tabId?)` -- extract visible text
- `browser.page.html(tabId?)` -- get full HTML
- `browser.page.markdown(tabId?)` -- extract as clean Markdown (Readability + Turndown)
- `browser.page.title(tabId?)` -- get page title
- `browser.page.url(tabId?)` -- get current URL

**Interaction**:
- `browser.page.click(target, tabId?)` -- click an element (by selector, text, element ref)
- `browser.page.fill(target, value, tabId?)` -- fill a form field
- `browser.page.select(target, value, tabId?)` -- select dropdown option
- `browser.page.hover(target, tabId?)` -- hover over element
- `browser.page.scroll(direction, amount?, tabId?)` -- scroll page
- `browser.page.press(key, tabId?)` -- press keyboard key/combo

**Inspection**:
- `browser.page.elements(tabId?)` -- list interactive elements with refs, roles, text, positions
- `browser.page.screenshot(tabId?, rect?)` -- capture screenshot as PNG
- `browser.page.pdf(tabId?)` -- export as PDF
- `browser.page.find(text, tabId?)` -- find text on page

**JavaScript**:
- `browser.page.evaluate(script, tabId?)` -- execute JS, return result
- `browser.page.evaluateAsync(script, tabId?)` -- execute async JS

**Session/data**:
- `browser.cookies.get(url?, tabId?)` -- get cookies
- `browser.cookies.set(cookie)` -- set a cookie
- `browser.cookies.clear(url?)` -- clear cookies
- `browser.console.logs(tabId?)` -- get captured console output

**Tab organization (AI-native)**:
- `browser.tabs.group(tabIds, name?)` -- group tabs
- `browser.tabs.search(query)` -- search across open tab content
- `browser.tabs.compare(tabIds)` -- extract & compare content from multiple tabs
- `browser.page.summarize(tabId?)` -- summarize current page
- `browser.page.ask(question, tabId?)` -- ask a question about current page

### Companion CLI

A small Swift CLI (`browser-cli` or just `browser`) that connects to the HTTP server:

```bash
browser open https://example.com
browser tabs
browser text                    # extract text from active tab
browser markdown                # extract markdown
browser screenshot              # save screenshot
browser click "Sign in"         # click by visible text
browser fill "#email" "me@x.com"
browser elements                # list interactive elements
browser eval "document.title"
browser ask "What is this page about?"
```

This lets agents use `bash` tool calls directly without needing an MCP client.

### MCP registration

The browser auto-patches MCP config files for known agents on first launch:

- `~/.config/claude-code/config.json` (Claude Code)
- `~/.codex/config.json` (Codex)
- `~/.afk/config/mcp.json` (AFK)

Config entry:
```json
{
  "mcpServers": {
    "browser": {
      "transport": "http",
      "url": "http://127.0.0.1:8833/mcp",
      "headers": { "Authorization": "Bearer <token>" }
    }
  }
}
```

---

## 4. ScriptBridge: The DOM Inspection Engine

The ScriptBridge is injected JS that runs in an isolated `WKContentWorld` (tamper-resistant -- page scripts cannot override our `querySelector`, `getBoundingClientRect`, etc.).

### Injected at document start

```javascript
// Runs in WKContentWorld("AgentBridge") -- isolated from page scripts
(function() {
    const BRIDGE = {};

    // Build accessibility-style element tree
    BRIDGE.getElements = function() {
        const interactive = [];
        const all = document.querySelectorAll('a, button, input, select, textarea, [role="button"], [role="link"], [role="tab"], [tabindex], [onclick]');

        let refCounter = 0;
        for (const el of all) {
            const rect = el.getBoundingClientRect();
            const style = window.getComputedStyle(el);

            // Skip invisible elements
            if (rect.width === 0 || rect.height === 0) continue;
            if (style.visibility === 'hidden' || style.display === 'none') continue;
            if (style.opacity === '0') continue;

            const ref = `@e${refCounter++}`;
            el.setAttribute('data-agent-ref', ref);

            interactive.push({
                ref: ref,
                tag: el.tagName.toLowerCase(),
                role: el.getAttribute('role') || inferRole(el),
                text: getVisibleText(el),
                placeholder: el.placeholder || null,
                ariaLabel: el.getAttribute('aria-label') || null,
                type: el.type || null,
                href: el.href || null,
                disabled: el.disabled || el.getAttribute('aria-disabled') === 'true',
                rect: { x: rect.x, y: rect.y, w: rect.width, h: rect.height },
                inViewport: rect.top < window.innerHeight && rect.bottom > 0
            });
        }
        return interactive;
    };

    // Click by ref
    BRIDGE.click = function(ref) {
        const el = document.querySelector(`[data-agent-ref="${ref}"]`);
        if (!el) return { error: 'Element not found' };
        el.scrollIntoView({ block: 'center' });
        el.click();
        return { ok: true };
    };

    // Fill by ref
    BRIDGE.fill = function(ref, value) {
        const el = document.querySelector(`[data-agent-ref="${ref}"]`);
        if (!el) return { error: 'Element not found' };
        el.focus();
        el.value = value;
        el.dispatchEvent(new Event('input', { bubbles: true }));
        el.dispatchEvent(new Event('change', { bubbles: true }));
        return { ok: true };
    };

    // Extract clean text
    BRIDGE.getText = function() {
        return document.body.innerText;
    };

    // Extract page as structured data
    BRIDGE.getPageStructure = function() {
        return {
            title: document.title,
            url: location.href,
            h1: [...document.querySelectorAll('h1')].map(h => h.innerText),
            headings: [...document.querySelectorAll('h1,h2,h3,h4,h5,h6')].map(h => ({
                level: parseInt(h.tagName[1]),
                text: h.innerText
            })),
            links: [...document.querySelectorAll('a[href]')].slice(0, 100).map(a => ({
                text: a.innerText.trim(),
                href: a.href
            })),
            images: [...document.querySelectorAll('img')].slice(0, 50).map(img => ({
                alt: img.alt,
                src: img.src
            })),
            forms: [...document.querySelectorAll('form')].map(f => ({
                action: f.action,
                method: f.method,
                fields: [...f.elements].map(el => ({
                    name: el.name,
                    type: el.type,
                    value: el.value
                }))
            }))
        };
    };

    window.__agentBridge = BRIDGE;
})();
```

### Swift-side execution

```swift
// In BrowserTab or ScriptBridge.swift
func getInteractiveElements() async throws -> [ElementInfo] {
    let result = try await webView.evaluateJavaScript(
        "JSON.stringify(window.__agentBridge.getElements())",
        in: nil,
        contentWorld: agentWorld  // isolated WKContentWorld("AgentBridge")
    )
    guard let json = result as? String,
          let data = json.data(using: .utf8) else { throw BridgeError.invalidResponse }
    return try JSONDecoder().decode([ElementInfo].self, from: data)
}
```

### Element reference stability

Element refs (`@e0`, `@e1`, ...) are assigned per `getElements()` call via `data-agent-ref` attributes. They persist across calls within a single page load but are invalidated on navigation. The ScriptBridge re-assigns refs on each call, so agents should call `elements()` before interacting if the page may have changed.

For SPA navigation (no full page load), a MutationObserver can be injected to detect DOM changes and optionally re-index.

---

## 5. Data Model

### BrowserTab

```swift
@Observable @MainActor
final class BrowserTab: Identifiable {
    let id = UUID()
    var url: URL?
    var title: String = "New Tab"
    var favicon: NSImage?
    var isLoading: Bool = false
    var loadProgress: Double = 0
    var canGoBack: Bool = false
    var canGoForward: Bool = false
    var isBookmarked: Bool = false
    var isPinned: Bool = false

    // WebView is lazily created
    private(set) var webView: WKWebView?

    // For COLD hibernation
    var interactionState: Data?

    // Console log capture
    var consoleLogs: [ConsoleEntry] = []

    enum State { case stub, cold, background, live }
    var state: State = .stub
}
```

### TabManager

```swift
@Observable @MainActor
final class TabManager {
    var tabs: [BrowserTab] = []
    var selectedTabID: UUID?
    var closedTabs: [ClosedTabInfo] = []  // for reopen (Cmd+Shift+T)

    var selectedTab: BrowserTab? { tabs.first { $0.id == selectedTabID } }

    func newTab(url: URL? = nil) -> BrowserTab { ... }
    func closeTab(_ id: UUID) { ... }
    func switchTo(_ id: UUID) { ... }
    func moveTab(from: Int, to: Int) { ... }
    func hibernateInactiveTabs(keepLive: Int = 5) { ... }
}
```

### Profile

```swift
struct BrowserProfile: Identifiable, Codable {
    let id: UUID
    var name: String
    var color: Color
    var icon: String

    var dataStore: WKWebsiteDataStore {
        WKWebsiteDataStore(forIdentifier: id)
    }
}
```

### Session restoration

```swift
struct SessionState: Codable {
    var windows: [WindowState]

    struct WindowState: Codable {
        var frame: CGRect
        var tabs: [TabState]
        var selectedTabIndex: Int
        var sidebarWidth: CGFloat
    }

    struct TabState: Codable {
        var url: URL
        var title: String
        var isPinned: Bool
        var interactionStateFile: String?  // path to binary blob
    }
}
```

---

## 6. Feature Roadmap

### Phase 1: Core browser (functional daily driver)

- [ ] Window management (NSWindow + NSWindowController)
- [ ] Tab bar (vertical sidebar, SwiftUI in NSHostingController)
- [ ] WKWebView hosting with navigation delegate
- [ ] Address bar with basic autocomplete
- [ ] Back / forward / reload
- [ ] New tab / close tab / switch tab / reopen closed tab
- [ ] Keyboard shortcuts (all standard browser shortcuts)
- [ ] Basic history (SQLite + FTS5)
- [ ] Basic bookmarks
- [ ] Session restoration (save/restore open tabs)
- [ ] Downloads (WKDownload)
- [ ] Find in page
- [ ] Private browsing (non-persistent data store)
- [ ] Context menus
- [ ] Page zoom
- [ ] Print

### Phase 2: Agent API

- [ ] Local HTTP server (NWListener on 127.0.0.1)
- [ ] MCP tool catalog (navigate, read, click, fill, screenshot, etc.)
- [ ] ScriptBridge (injected JS for DOM inspection)
- [ ] Bearer token auth + DNS rebinding defense
- [ ] CLI companion tool
- [ ] Auto-registration with Claude Code, Codex, AFK
- [ ] Console log capture
- [ ] Action log (visible in browser, what the agent did)

### Phase 3: Power features

- [ ] Tab groups / workspaces
- [ ] User profiles (per-profile WKWebsiteDataStore)
- [ ] Command palette
- [ ] Split panes
- [ ] Content blocking (WKContentRuleList with EasyList/EasyPrivacy)
- [ ] Web extensions (WKWebExtensionController)
- [ ] Page-to-Markdown extraction
- [ ] PDF export
- [ ] "Ask this page" (agent-powered Q&A about current page)
- [ ] "Summarize tab" (agent-powered summary)
- [ ] Cross-tab search
- [ ] Automatic tab organization (agent-powered)
- [ ] Multi-tab comparison (agent-powered content diff)

### Phase 4: Polish & ecosystem

- [ ] Default browser registration
- [ ] Spotlight integration
- [ ] Handoff (NSUserActivity)
- [ ] Auto-update (Sparkle)
- [ ] Favicon fetching & caching
- [ ] Reader mode (JS-injected Readability)
- [ ] Picture-in-Picture
- [ ] Password autofill (requires `com.apple.developer.web-browser` entitlement)
- [ ] WebAuthn / Passkeys (requires `com.apple.developer.web-browser.public-key-credential`)

---

## 7. Entitlements Plan

### For direct distribution (notarized DMG) -- recommended for V1

```xml
<!-- Hardened Runtime (required for notarization) -->
<key>com.apple.security.cs.allow-jit</key>
<true/>  <!-- WebKit JIT compiler needs this -->

<!-- Network -->
<key>com.apple.security.network.client</key>
<true/>  <!-- WKWebView won't function without this -->
<key>com.apple.security.network.server</key>
<true/>  <!-- For the local MCP server -->

<!-- Media (WebRTC) -->
<key>com.apple.security.device.camera</key>
<true/>
<key>com.apple.security.device.audio-input</key>
<true/>
```

### Apply for early (Apple managed entitlements)

- `com.apple.developer.web-browser` -- needed for: default browser, Service Workers, password autofill, Web Inspector in production
- `com.apple.developer.web-browser.public-key-credential` -- needed for WebAuthn/Passkeys

---

## 8. Technology Stack Summary

| Layer | Technology |
|---|---|
| Language | Swift 5.9+ (Swift 6 strict concurrency where possible) |
| UI framework | AppKit (windows, layout, WKWebView) + SwiftUI (sidebar, overlays, settings) |
| Web engine | WKWebView (system WebKit) |
| Minimum macOS | 15 (Sequoia) |
| HTTP server | Network.framework (NWListener) |
| History DB | SQLite via GRDB.swift + FTS5 |
| Bookmarks DB | SwiftData |
| Session state | Codable JSON |
| Preferences | UserDefaults (custom suite) |
| Secrets | Keychain (bearer tokens) |
| Auto-update | Sparkle |
| Distribution | Signed + notarized DMG |
| Build system | Xcode / swift build |
| Package manager | Swift Package Manager |

### Dependencies (minimal)

- **GRDB.swift** -- SQLite wrapper with FTS5 support
- **Sparkle** -- auto-update framework
- *(Optional)* **SwiftNIO** -- if we want the HTTP server at a higher level than raw NWListener
- *(Optional)* **swift-markdown** -- for Markdown rendering on new tab page

---

## 9. Prior Art Reference

| Project | Relevance | Key takeaway |
|---|---|---|
| **mcp-browser** (brainfuel) | Most directly relevant | Full MCP server + WKWebView browser. MIT. ~400 lines for the MCP layer. Bearer auth + DNS rebinding defense. Auto-patches agent configs. |
| **aslan-browser** | DOM inspection approach | Accessibility-tree-first design. `ScriptBridge.swift` is the reference for element walking. Unix socket transport. Python SDK. |
| **Ora Browser** | Browser UX reference | GPL. Closest to a "real browser" in Swift. Arc-inspired design. |
| **Chord Browser** | Extension hosting | WKWebExtension integration, space-isolated sessions |
| **Kestrel Browser** | Memory measurements | Confirmed ~130 MB/tab, WebProcessCache behavior, COLD vs STUB tradeoffs |
| **blur-browser** | AppKit pitfalls | Documented NSSplitViewController + NSHostingController layout cycle, NSToolbar + fullSizeContentView conflict |
| **Orion (Kagi)** | AppleScript dictionary | Safari-compatible scripting dictionary, `do JavaScript` support |
| **Playwright WebKit** | Automation internals | Patched WebKit with pipe transport. Content world isolation. WKFrameInfo-targeted eval. |

---

## 10. Open Questions for Implementation

1. **Project name** -- needs a name before creating the Xcode project
2. **Repo location** -- `~/Projects/browser/` or somewhere else?
3. **macOS 15 vs 14 minimum** -- macOS 15 gets us web extensions (15.4). macOS 14 gets us profiles + inactive scheduling. Recommend 15.
4. **SwiftNIO vs raw NWListener for HTTP** -- NWListener is zero-dependency but lower-level. SwiftNIO adds a dependency but gives us HTTP parsing for free.
5. **Start with Phase 1 or Phase 1+2 interleaved?** -- The agent API could be built alongside the core browser from day one, or layered on after a functional browser exists.
6. **License** -- MIT? Apache 2.0? Proprietary?

---

## Appendix A: WebKit API Surface Summary

### New in macOS 26+ (WWDC25)

- `WebView` (SwiftUI view) -- native SwiftUI web view
- `WebPage` (@Observable) -- model behind WebView with callJavaScript, export as PDF/archive, navigation events
- `WebPage.Configuration` -- Swift-native configuration with URLSchemeHandler protocol
- `URLSchemeHandler` -- Swift protocol replacing ObjC WKURLSchemeHandler

### New in macOS 27+ (WWDC26)

- `load(_ url: URL)` -- convenience method on WKWebView (promoted from SPI)
- `requestGeolocationPermission` on WKUIDelegate (promoted from SPI)
- `WKDownload.isUserInitiated` + `originatingFrame`
- Safari 27: 1000+ fixes, CSS Grid Lanes, Customizable Select, `<model>` element
- Web Extensions: packager no longer requires Xcode

### Stable (macOS 14-15)

- `WKWebsiteDataStore(forIdentifier:)` -- named profiles (14+)
- `WKWebsiteDataStore.proxyConfigurations` -- proxy support (14+)
- `inactiveSchedulingPolicy` -- suspend/throttle background tabs (14+)
- `WKWebExtensionController` -- extension hosting (15.4+)
- `WKDownload` -- full download management (11.3+)
- `WKContentWorld` -- isolated JS execution (11+)
- `callAsyncJavaScript` -- async JS with await support (11+)
- `takeSnapshot` -- page screenshots (10.13+)
- `createPDF` / `createWebArchiveData` -- export (11+)
- `WKContentRuleListStore` -- content blocking (11+)

## Appendix B: Research Sources

Full research reports from the scoping investigation are preserved at:
- WebKit API inventory: `~/.afk/state/sessions/b48f63ac-d4c6-4d3f-af4b-82064bd6ec22/compose/toolu_01Bz3e8jbU2edxixdmDhirrL/webkit-apis.txt`
- Agent browser control feasibility: `~/.afk/state/sessions/b48f63ac-d4c6-4d3f-af4b-82064bd6ec22/compose/toolu_01Bz3e8jbU2edxixdmDhirrL/agent-browser-control.txt`
- macOS browser architecture: `~/.afk/state/sessions/b48f63ac-d4c6-4d3f-af4b-82064bd6ec22/compose/toolu_01Bz3e8jbU2edxixdmDhirrL/macos-browser-architecture.txt`
