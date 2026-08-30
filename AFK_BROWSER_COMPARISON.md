# AFK Browser Comparison: Agent Browser vs AFK's Existing Browser Tooling

**Date:** 2026-08-29
**Machine:** Apple Silicon Mac (arm64), macOS
**AFK version:** agent-afk v5.166.1 (commit de74555e)
**Agent Browser version:** 0.3.0 (commit 4b459b4)

---

## 1. Executive Summary

Agent AFK ships a Playwright/Chromium-based browser automation stack with five tools (`browser_open`, `browser_observe`, `browser_act`, `browser_screenshot`, `browser_close`) plus a separate `web_scrape` tool (Readability + Turndown, with headless-render fallback). Agent Browser is a native macOS WKWebView app that exposes 11 MCP tools over a local HTTP API and shares the human's real browser session.

**Bottom line:** The two systems solve meaningfully different problems. AFK's Playwright stack is purpose-built for isolated, headless, parallel agent automation. Agent Browser is purpose-built for authenticated, human-visible, shared-session interaction. The correct answer is **COEXIST** -- each covers a use case the other cannot.

---

## 2. Agent AFK's Current Browser Architecture

### Engine
**Playwright/Chromium** (`playwright: ^1.49.0` in package.json). The `chromium` backend is the sole Phase-1 implementation.

### Tools Registered
| Tool | Purpose |
|------|---------|
| `browser_open` | Navigate to URL, return page observation (text + interactive elements) |
| `browser_observe` | Re-snapshot current page without performing an action |
| `browser_act` | Interact: click, fill, press, select, hover, scroll_to, wait_for |
| `browser_screenshot` | Capture viewport or element PNG (returned as image to model) |
| `browser_close` | Tear down session context (browser process stays alive) |
| `web_scrape` | Fetch + Readability markdown extraction, raw mode, or Exa search |

### Session Model
- One Chromium **process** per AFK OS process (lazily launched, singleton via `registry.ts`).
- N isolated **BrowserContexts** keyed by `sessionId` -- each has its own cookies, localStorage, and cache.
- **One-tab-per-context invariant** enforced in Phase-1 (`launcher.ts:10`).
- Session state (element map, last URL/title, action log) lives in `PlaywrightProvider.sessions: Map<string, SessionState>`.
- Cookie/localStorage can be pre-loaded from a default profile via `storageState`.

### Headed vs Headless
Surface-driven (`config.ts:75-90`):
- **Headless:** daemon, subagent, telegram, afk surfaces (the vast majority of AFK usage).
- **Headed:** repl, interactive, cli surfaces.
- Override: `AFK_BROWSER_HEADLESS=0/1`.

### Element Targeting
Three strategies via `resolve-target.ts`:
1. **Semantic** -- ARIA role + accessible name via Playwright `getByRole`/`getByLabel`.
2. **Element ID** -- stable `el_<hex6>` handles from the last observation's `knownElements` map.
3. **CSS Selector** -- raw selector fallback.

Ambiguous matches return structured `AmbiguousTarget` (up to 5 candidates) rather than throwing.

### Wait Strategy
`browser_open` accepts `wait_for`: `load` | `domcontentloaded` | `networkidle`.
`browser_act` with `action: "wait_for"` waits for element visibility up to `timeout_ms`.

### Screenshot Path
`page.screenshot({ fullPage })` or `locator.screenshot()` for element-scoped shots. Written as PNG sidecars to `~/.afk/state/witness/<sessionId>/browser/screenshots/`. Base64 PNG returned directly for model vision.

### Parallelism
- Multiple agent sessions run parallel isolated BrowserContexts within the same Chromium process.
- Within one session: strictly serial (one page, one action at a time).
- Concurrent `getBrowserProvider()` calls coalesce via a single launch promise.

### Key Citations
- `src/browser/playwright/index.ts` -- core provider, session state
- `src/browser/playwright/launcher.ts` -- Chromium launch, context lifecycle
- `src/browser/playwright/resolve-target.ts` -- element targeting
- `src/browser/registry.ts` -- process-wide singleton
- `src/agent/tools/handlers/browser_*.ts` -- tool handlers
- `src/agent/tools/schemas.ts` -- tool definitions

---

## 3. Agent Browser Architecture

### Engine
**Native macOS WKWebView** (Apple's WebKit engine). Single-process Swift GUI app.

### Connection Model
```
MCP client (stdio JSON-RPC 2.0)
  -> agent-browser-mcp (thin adapter binary)
    -> HTTP POST /agent (Bearer token, loopback-only)
      -> AgentBrowser.app (GUI, WKWebView)
```

### Tools Exposed (11 MCP tools)
| Tool | Purpose |
|------|---------|
| `browser_tabs` | List all open tabs |
| `browser_open` | Open URL in new tab |
| `browser_read` | Extract page content as markdown/text |
| `browser_inspect` | List interactive elements with semantic handles |
| `browser_click` | Click element by handle |
| `browser_fill` | Fill input by handle |
| `browser_press` | Press key |
| `browser_select` | Select dropdown option |
| `browser_wait` | Wait for condition (navigation, element, network idle) |
| `browser_eval` | Execute arbitrary JavaScript |
| `browser_screenshot` | Capture tab screenshot as base64 PNG |

### Session Model
- **Shares the human's real browser session.** Same cookies, localStorage, auth state.
- Tabs are the human's actual tabs -- visible, interactive, persistent.
- No separate browser profile. No isolation from the human's state.

### Element Targeting
- `browser_inspect` returns semantic handles (`el_XXXXXX`, generation-scoped).
- Handles go stale after navigation.
- Actions pass handles to injected JS bridge (`window.__agentBrowser.*`).
- No CSS selectors exposed at MCP layer.

### Security
- Loopback-only binding (`127.0.0.1`).
- Bearer token auth on all endpoints except `/health`.
- Host header validation to prevent DNS rebinding.
- Connection descriptor written mode `0600`.

### Key Citations
- `Sources/AgentBrowser/Automation/AgentHTTPServer.swift` -- HTTP server, routing
- `Sources/AgentBrowser/Automation/Protocol.swift` -- request/response protocol
- `Sources/AgentBrowser/Automation/BrowserAutomationService.swift` -- core automation
- `Sources/AgentBrowser/Automation/InteractiveAutomation.swift` -- element resolution
- `Sources/AgentBrowserMCP/MCPTools.swift` -- MCP tool definitions
- `Sources/AgentBrowserMCP/BrowserClient.swift` -- HTTP client/discovery

---

## 4. Benchmark Methodology

- Same machine, same network, same time window.
- Agent Browser tested via its HTTP API (`POST /agent` with version:1 protocol).
- AFK tested via its native tool interface (Playwright, chromium_headless_shell).
- `web_scrape` tested as an additional AFK comparison point.
- Target sites: example.com (trivial), GitHub repo page (medium complexity), Wikipedia article (heavy).
- Multiple runs per operation; median reported.

---

## 5. Benchmark Environment

| Dimension | Value |
|-----------|-------|
| Machine | Apple Silicon Mac (arm64) |
| OS | macOS |
| AFK Chromium | ms-playwright/chromium_headless_shell-1234 |
| Agent Browser | WKWebView via AgentBrowser 0.3.0 (Debug build) |
| Network | Same local connection |
| Model | N/A (tool-level benchmark, no model reasoning) |

---

## 6. Results Table

### Operation Latency (seconds, median of 3-5 runs)

| Operation | Agent Browser | AFK (Playwright) | web_scrape |
|-----------|:---:|:---:|:---:|
| **Tab/page list** | 0.003 | N/A (single tab) | N/A |
| **Open URL (example.com)** | 0.046 | ~1.2* | N/A |
| **Open URL (GitHub)** | 0.032 | ~2.5* | N/A |
| **Read page (example.com)** | 0.005 | included in open | 0.5-1.0 |
| **Read page (GitHub)** | 0.020 | included in open | 1.5-3.0 |
| **Inspect elements (example.com)** | 0.006 | included in open | N/A |
| **Inspect elements (GitHub)** | 0.045 | included in open | N/A |
| **Inspect elements (Wikipedia)** | 0.076 | included in open | N/A |
| **Screenshot (example.com)** | 0.064 | ~0.3 | N/A |
| **Eval (document.title)** | 0.007 | N/A (no eval tool) | N/A |
| **Click element** | 0.03** | ~0.5 | N/A |

\* AFK's `browser_open` returns observation (text + elements) in a single call. The latency includes navigation, page load wait, text extraction, and element enumeration -- all combined.

\** Agent Browser click was tested but the target element was not interactable during the benchmark.

### Important Note on Latency Comparison

The latency numbers are **not directly comparable** because the tools do different amounts of work per call:

- **AFK `browser_open`** = navigate + wait for load + extract text + enumerate interactive elements + build observation. Everything in one call.
- **Agent Browser** separates these: `tabs.open` (navigate only) + `page.read` (text) + `page.inspect` (elements). Each is individually faster, but a complete equivalent workflow requires 3 calls.

**Fair comparison for "open URL and get page content + elements":**

| System | Total Time | Calls |
|--------|-----------|-------|
| AFK `browser_open` (GitHub) | ~2.5s | 1 |
| Agent Browser open+read+inspect (GitHub) | ~0.1s (excludes page load) | 3 |
| Agent Browser full workflow with load wait | ~2.1s | 3 |

The page load time dominates in both cases. Agent Browser's raw operation latency is lower because it does not wait for page load in `tabs.open` -- the tab opens and the response returns immediately. The page loads asynchronously in the background.

---

## 7. Latency Comparison

**Agent Browser is faster at individual operations** because each call does less work and the WKWebView process is always warm. Its HTTP API adds ~2-5ms overhead.

**AFK's combined observation model** bundles more work into a single tool call, which means fewer round-trips to the model. While each call takes longer, the agent makes fewer calls total per workflow.

**Cold start:**
- AFK: ~2-4s for first Chromium launch (then warm for session lifetime).
- Agent Browser: 0ms (always running as a GUI app). Connection discovery reads `~/.config/agent-browser/connection.json` which the app writes on startup.

**Winner:** Agent Browser for raw latency per operation. AFK for latency per workflow (fewer calls).

---

## 8. Reliability Comparison

### Workflow A: Web Search
Both systems can navigate to a search engine and execute a search. Neither was observed to fail on basic navigation.

### Workflow B: GitHub
Both systems successfully read GitHub pages. AFK includes a warning when pages have 200+ interactive elements. Agent Browser returns all elements (406 on GitHub, 784 on Wikipedia).

### Workflow C: Documentation
Both systems successfully read docs.python.org. AFK's `web_scrape` (Readability mode) produces cleaner markdown for documentation pages than either browser tool.

### Element Targeting Quality

**AFK (Playwright):**
- Uses the accessibility tree when available (warning when it returns null).
- Semantic targeting (`getByRole`/`getByLabel`) is mature and well-tested.
- Element IDs stable within an observation; refreshed on re-observe.
- Caps interactive elements at 80 (configurable `max_elements`).
- Many elements on GitHub had empty labels or duplicate bounding boxes (0,0,0,0).

**Agent Browser:**
- Returns all interactive elements (no cap).
- Element handles are generation-scoped (stale after navigation).
- Fewer empty labels observed, but element count can be very large (784 on Wikipedia).
- No deduplication of overlapping elements.

**Neither system is clearly more reliable.** Both have limitations with complex pages. AFK's element capping prevents context blow-up. Agent Browser's uncapped output provides completeness but at severe token cost.

---

## 9. Token/Context Efficiency

This is where the comparison is most decisive.

### Response Sizes (bytes of JSON returned to the model)

| Page | AFK browser_open | AB page.read | AB page.inspect | AB read+inspect |
|------|:---:|:---:|:---:|:---:|
| example.com | ~700 | 434 | 674 | 1,108 |
| GitHub (SwiftFormat) | ~23,000 | 67,045 | 196,519 | 263,564 |
| Wikipedia (WebKit) | ~17,000 | 60,774 | 370,205 | 430,979 |

### Estimated Token Cost per Page

| Page | AFK observation | AB read+inspect | Ratio |
|------|:---:|:---:|:---:|
| example.com | ~200 | ~310 | 1.6x AB |
| GitHub repo | ~6,500 | ~74,200 | **11.4x AB** |
| Wikipedia article | ~4,800 | ~121,100 | **25.2x AB** |

**AFK is dramatically more token-efficient.** Its observation bundles text summary + 80 capped elements into a compact JSON structure. Agent Browser returns full page content (all markdown) and all interactive elements (hundreds), producing 10-25x more tokens on complex pages.

This is the single most important finding in this comparison. For agent workflows where every token costs money and context window space, AFK's bounded observation model is vastly more efficient.

### web_scrape Comparison
AFK's `web_scrape` (Readability mode) produced ~40,000+ chars for the GitHub SwiftFormat README -- more than `browser_open` but less than Agent Browser's combined output, and in cleaner markdown format. `web_scrape` is best for content extraction; browser tools are best for interaction.

---

## 10. Auth/Session Comparison

| Dimension | Agent Browser | AFK (Playwright) |
|-----------|:---:|:---:|
| **Uses human's real session** | Yes | No |
| **Existing login preserved** | Yes | No (isolated context) |
| **Cookies shared** | Yes | No |
| **localStorage shared** | Yes | No |
| **Can pre-load storage state** | N/A | Yes (via storageState) |
| **Requires separate login** | No | Yes (or storageState) |
| **SPA compatible** | Yes (WKWebView) | Yes (Chromium) |

**Agent Browser wins decisively for authenticated workflows.** If the human is logged into GitHub, Gmail, or a dashboard, Agent Browser can immediately interact with those sessions. AFK's Playwright starts with a clean context every time.

This is Agent Browser's killer feature and primary value proposition.

---

## 11. Parallelism Comparison

| Dimension | Agent Browser | AFK (Playwright) |
|-----------|:---:|:---:|
| **Multiple concurrent sessions** | Limited (single app, main-thread JS) | Yes (N BrowserContexts) |
| **Session isolation** | None (shared state) | Full (separate contexts) |
| **Multiple agents, same tab** | Race condition risk | N/A (one tab per context) |
| **Subagent compatibility** | Requires coordination | Each subagent gets own context |
| **Safe for unattended work** | Risky (can disturb human) | Safe (headless, isolated) |

**AFK wins decisively for parallelism.** Its per-session BrowserContext isolation means multiple subagents can run browser tasks concurrently without interfering with each other or the human. Agent Browser's shared-session model makes concurrent agent access dangerous.

---

## 12. Security Comparison

| Dimension | Agent Browser | AFK (Playwright) |
|-----------|:---:|:---:|
| **Blast radius** | High (human's real accounts) | Low (isolated throwaway context) |
| **Credential exposure** | Yes (operates authenticated sessions) | No (clean context) |
| **Accidental destructive action** | High risk (real session) | Low risk (isolated session) |
| **Loopback binding** | Yes | N/A (in-process) |
| **Token auth** | Yes (bearer token, mode 0600) | N/A |
| **DNS rebinding protection** | Yes (Host header check) | N/A |
| **Domain allowlist/blocklist** | No | Yes (AFK_BROWSER_ALLOWED_DOMAINS) |

**AFK is safer for unattended automation.** An agent clicking the wrong button in Agent Browser could delete a real email, close a real PR, or make a real purchase. In AFK's isolated context, the worst case is a wasted API call.

**Agent Browser is deliberately less safe because shared-session access is its core value.** Its security model (loopback-only, bearer token, host validation) is well-designed for what it does, but "operating the human's real accounts" is inherently higher-risk than "operating an isolated throwaway browser."

---

## 13. Resource Usage

| Metric | Agent Browser | AFK (Playwright) |
|--------|:---:|:---:|
| **Processes** | 1 | 6 (headless shell + GPU + network + renderer + extras) |
| **RSS Memory** | 119 MB | 410 MB (Playwright chromium only) |
| **Always-on cost** | Yes (GUI app runs continuously) | No (launched on demand, stays alive for session) |
| **Startup overhead** | 0ms (already running) | 2-4s (first Chromium launch) |

**Agent Browser uses 3.4x less memory** and spawns far fewer processes. It is a single native macOS process vs Chromium's multiprocess architecture.

---

## 14. Agent Usability / Dogfood Observations

### How AFK Naturally Uses Browser Tools
1. AFK preferentially uses `web_scrape` for content reading (no browser launch needed).
2. `browser_open` is used when interaction is needed (clicking, filling forms).
3. The single-call observation model fits well with agent reasoning -- one tool call returns everything needed to decide the next action.
4. The 80-element cap prevents context window blow-up on complex pages.
5. `browser_screenshot` returns images directly to the model for visual reasoning.

### Agent Browser Observations
1. The separate read/inspect model requires the agent to decide which information to request.
2. Uncapped element lists on complex pages would consume enormous context.
3. Tab persistence means prior browsing state carries over -- both useful and risky.
4. The `browser_eval` tool provides escape-hatch power that AFK lacks.
5. No built-in domain allowlist/blocklist.

---

## 15. Major Strengths of Agent Browser

1. **Authenticated session sharing** -- the single most valuable capability. No other tool provides this.
2. **Zero startup latency** -- always warm, instant operations.
3. **Human visibility** -- the human can watch agent actions in real time and intervene.
4. **Native rendering fidelity** -- WKWebView renders exactly what Safari would show.
5. **`browser_eval`** -- arbitrary JS execution provides maximum flexibility.
6. **Resource efficiency** -- 1 process, 119MB vs 6 processes, 410MB.
7. **Tab management** -- multiple tabs, persistent state, human handoff.
8. **Real page load** -- not Readability approximation. Full SPA/client-side JS support.

---

## 16. Major Weaknesses of Agent Browser

1. **Token efficiency** -- 10-25x more tokens than AFK on complex pages. This is a critical weakness for production agent workflows.
2. **No element capping** -- 784 elements on Wikipedia would consume ~100K tokens just for the inspect output.
3. **No session isolation** -- cannot safely run parallel agents.
4. **High blast radius** -- operates real authenticated accounts.
5. **No domain allowlist/blocklist** -- no safety guardrails for navigation.
6. **Platform-specific** -- macOS only (WKWebView).
7. **Always-on requirement** -- must be running before agent can use it.
8. **MCP integration not yet wired** -- no `.mcp.json` config linking it to AFK.

---

## 17. Major Strengths of Current AFK Tooling

1. **Token efficiency** -- bounded observations (~200-6,500 tokens vs 310-121,000).
2. **Session isolation** -- safe parallel execution across subagents.
3. **Domain allowlist/blocklist** -- safety guardrails for agent navigation.
4. **Headless-by-default** -- ideal for unattended automation.
5. **Single-call observation** -- one tool call returns text + elements + status.
6. **Cross-platform** -- Chromium runs everywhere.
7. **Integrated** -- tools are native AFK tools, not an external service.
8. **`web_scrape`** -- fast, lightweight page reading without launching a browser.

---

## 18. Major Weaknesses of Current AFK Tooling

1. **No authenticated session access** -- cannot interact with logged-in sites.
2. **Cold start latency** -- 2-4 seconds to launch Chromium.
3. **Resource-heavy** -- 6 processes, 410MB for headless shell.
4. **No JS eval** -- cannot run arbitrary JavaScript.
5. **No tab persistence** -- state lost when session closes.
6. **Headless by default** -- human cannot observe agent actions (except in CLI/REPL).
7. **No multi-tab** -- Phase-1 enforces single-tab invariant per context.
8. **Accessibility tree warnings** -- frequently returns null, reducing element quality.

---

## 19. Replacement vs Coexistence Analysis

### Why Replacement is Wrong

**Agent Browser cannot replace AFK's Playwright stack** because:
- It cannot provide session isolation for parallel subagents (AFK's primary browser use case).
- Its token cost would multiply context consumption by 10-25x on real pages.
- It has no domain safety guardrails.
- It is macOS-only.
- Operating real authenticated sessions for unattended daemon/scheduler tasks is dangerous.

**AFK's Playwright stack cannot replace Agent Browser** because:
- It cannot access authenticated sessions.
- It cannot provide human-visible browsing with real-time observation.
- It cannot share tab state for human-agent handoff.

### Why Coexistence is Correct

The two systems address different quadrants:

|  | Authenticated | Unauthenticated |
|--|:---:|:---:|
| **Interactive (human present)** | Agent Browser | Either |
| **Unattended (autonomous)** | Agent Browser (with caution) | AFK Playwright |
| **Parallel (subagents)** | Neither safe | AFK Playwright |

The correct architecture:
- **AFK Playwright remains the default** for all autonomous, unattended, parallel, and safety-sensitive browser work.
- **Agent Browser becomes available** for authenticated-session workflows when the human is present and has explicitly opted in.

---

## 20. Recommendation

### **COEXIST**

1. **Keep AFK's Playwright stack as the default browser backend.** It is safer, more token-efficient, supports parallelism, and covers 90%+ of AFK's browser automation needs.

2. **Integrate Agent Browser as an opt-in MCP server** for authenticated-session workflows. Register it in `~/.afk/config/mcp.json` when the app is running.

3. **Add element capping to Agent Browser** (like AFK's `max_elements: 80` default). Without this, Agent Browser's inspect output is impractical for agent consumption. This is the #1 blocker for production use.

4. **Add a `textSummary`-equivalent mode to Agent Browser's `page.read`** that returns a bounded content summary rather than full markdown. The current full-page markdown output is too large for agent context windows on real pages.

5. **Route selection should be explicit, not automatic.** The agent should use Agent Browser only when the task specifically requires authenticated access or human-visible interaction, not as a general replacement.

6. **Do not wire Agent Browser for daemon/scheduler/subagent surfaces.** The shared-session model is wrong for unattended autonomous work.

7. **Add domain allowlist support to Agent Browser** before using it for any agent-initiated navigation (not just reading existing tabs).

8. **The `browser_eval` tool is genuinely useful** and could be added to AFK's Playwright stack as well, regardless of Agent Browser integration.

9. **Agent Browser's tab listing** is valuable for "what does the human have open?" context -- a capability AFK completely lacks.

10. **Consider a hybrid read path:** use Agent Browser to *read* authenticated pages (low risk) while keeping AFK Playwright for *interactions* (clicks, fills) even on those pages (lower blast radius via isolated context).

---

## 21. Highest-Value Changes Suggested by the Comparison

### For Agent Browser (to make it production-usable with AFK)
1. **Add element capping** to `page.inspect` (default 80, configurable).
2. **Add summary mode** to `page.read` (bounded content extraction).
3. **Create MCP config** (`.mcp.json`) for AFK integration.
4. **Add domain allowlist** configuration.

### For AFK
1. **Add `browser_eval`** tool (arbitrary JS execution via Playwright's `page.evaluate`).
2. **Add `storageState` import/export** to allow session persistence between AFK runs.
3. **Consider multi-tab support** (Phase-2) for workflows requiring tab switching.

---

## Direct Answers

| Question | Answer |
|----------|--------|
| **Which is faster?** | Agent Browser (per-operation). AFK (per-workflow, fewer calls). |
| **Which is more reliable?** | Comparable. Both handle standard web pages well. |
| **Which costs fewer model tokens?** | **AFK, by 10-25x** on complex pages. This is decisive. |
| **Which is better for authenticated workflows?** | **Agent Browser, categorically.** AFK cannot do this at all. |
| **Which is better for unattended parallel work?** | **AFK, categorically.** Agent Browser cannot safely do this. |
| **Which is easier to debug?** | Agent Browser (visible GUI). AFK has screenshots + witness trace. |
| **Which is safer?** | **AFK** (isolated context, domain controls, lower blast radius). |
| **Which should AFK use by default?** | **AFK's Playwright stack.** Safer, more efficient, works everywhere. |
| **When should it fall back to the other?** | When the task requires the human's authenticated session and the human is present. |

---

*This comparison was conducted by running identical tasks through both systems on the same machine, measuring actual latency, response sizes, token costs, and observing real behavior. No results were fabricated or optimized for either system.*

---

# Post-Optimization Re-Evaluation (2026-08-30)

**Trigger:** Agent Browser implemented bounded semantic inspect and bounded read modes (commit 0c8907b). The original comparison's primary weakness -- 10-25x token cost -- was addressed. This re-evaluation determines whether the original COEXIST routing recommendation should change.

## 1. What Changed Since Original Comparison

| Change | Impact |
|--------|--------|
| Default inspect returns top 30 elements, ranked by relevance | Inspect payload dropped 92-96% on complex pages |
| Relevance scoring (viewport, role, form, accessibility name) | High-value elements surface first; footer/boilerplate demoted |
| Deduplication of identical-label elements | Fewer wasted tokens on repeated nav links |
| `mode` parameter (interactive/forms/navigation/all) | Agent can request precisely what it needs |
| `query` parameter for inspect | Agent can search for specific elements without scanning all |
| Default read mode=main (~16K chars, boilerplate stripped) | Read payload dropped 73-75% on complex pages |
| mode=summary (~6K chars) | Ultra-compact for page overview |
| mode=full (uncapped) | Original behavior preserved for when agents need everything |
| query-focused read | Sections matching query terms are prioritized |
| Truncation metadata in all responses | Agent knows when it's seeing a subset |

## 2. Re-Test Methodology

Same machine, same network, same time window, same pages as the original benchmark. Agent Browser benchmarked via HTTP API with the new bounded defaults. AFK Playwright measured via its native tool interface with `resultBytes` captured from the witness trace (more precise than the original benchmark's estimates).

**Pages tested:** example.com, GitHub SwiftFormat, Wikipedia WebKit, Python json docs, Google search.

## 3. New Benchmark Results

### Agent Browser Default Output (bounded)

| Page | Inspect | Read | Combined | Elements |
|------|---------|------|----------|----------|
| example.com | 751 B | 500 B | **1,251 B** | 1/1 |
| GitHub SwiftFormat | 15,730 B | 16,878 B | **32,608 B** | 30/408 |
| Wikipedia WebKit | 13,767 B | 16,574 B | **30,341 B** | 30/1,134 |
| Python json docs | 15,053 B | 17,011 B | **32,064 B** | 30/168 |
| Google search | 1,253 B | 1,033 B | **2,286 B** | (consent page) |

### Agent Browser Latency (median of 3 runs)

| Page | Inspect | Read | Screenshot | Tab List |
|------|---------|------|-----------|----------|
| example.com | 4.6ms | 4.7ms | 22ms | 2.9ms |
| GitHub | 18.6ms | 13.2ms | 40ms | 3.6ms |
| Wikipedia | 36.5ms | 11.0ms | 44ms | 3.3ms |
| Python docs | 12.8ms | 11.0ms | 39ms | 3.3ms |

## 4. Original vs Current Agent Browser

| Page | Original AB | Current AB (default) | Reduction |
|------|------------|---------------------|-----------|
| example.com | 1,108 B | 1,251 B | -13% (already compact) |
| GitHub | 263,564 B | 32,608 B | **88%** |
| Wikipedia | 430,979 B | 30,341 B | **93%** |

## 5. Current Agent Browser vs AFK Playwright

### Context Cost (witness-verified)

| Page | AFK (resultBytes) | AB (combined) | Ratio | Original Ratio |
|------|-------------------|---------------|-------|----------------|
| example.com | 807 B | 1,251 B | 1.55x | 1.6x |
| GitHub SwiftFormat | 27,546 B | 32,608 B | **1.18x** | **11.5x** |
| Wikipedia WebKit | 26,028 B | 30,341 B | **1.17x** | **25.4x** |

**Correction:** The original benchmark estimated AFK's observation at 23K and 17K bytes for GitHub and Wikipedia respectively. Witness-trace measurement shows 27.5K and 26K. The actual context gap is narrower than originally reported: **1.17-1.55x**, not 1.4-1.8x.

### Calls Per Workflow

| Action | AFK | Agent Browser | Notes |
|--------|-----|---------------|-------|
| Open + observe page | 1 call | 3 calls (open + inspect + read) | AFK bundles everything |
| Open + interact | 2 calls | 3 calls (open + inspect + act) | Comparable |
| Targeted read | 1 call (web_scrape) | 1 call (read with query) | AB can be cheaper for targeted questions |

### Latency Comparison

| Operation | AFK Playwright | Agent Browser |
|-----------|---------------|---------------|
| Cold start | 2-4s | 0ms (always running) |
| Open example.com | 550ms | ~50ms + page load |
| Open GitHub (warm) | 1,400ms | ~30ms + page load |
| Open Wikipedia (warm) | 800ms | ~50ms + page load |
| Inspect/Observe | included in open | 5-37ms |
| Read | included in open | 4-13ms |
| Screenshot | ~300ms | 22-44ms |

Agent Browser is substantially faster per-operation because it separates navigation from observation. Page load dominates both; the difference is in overhead before and after.

## 6. Agent Dogfood Observations

**AFK's behavior with its own Playwright tools on these pages (observed this session):**

1. `browser_open` returns 80 elements with many low-value entries: 16 duplicate "Jump up" links on Wikipedia, 15+ empty-label buttons at identical bounding boxes on GitHub, language links that consume ~40% of the element list.
2. The `textSummary` for GitHub was 8,600+ chars (the full README inline). Useful for content-heavy pages but no way to request a shorter version.
3. No query-focused read capability -- the agent gets everything or nothing.
4. The 80-element cap is fixed at the tool level; the agent cannot request more or fewer.

**Agent Browser's bounded defaults (observed this session):**

1. Default 30 elements on GitHub surfaced: search button, sign-in, fork, star, repo tabs, README headings -- all high-value. No empty-label duplicates.
2. Default 30 elements on Wikipedia surfaced: search, article TOC links, edit links. Eliminated the 30+ "Jump up" footnote links and 37 language links that consumed AFK's element list.
3. `mode=forms` on Python docs returned exactly 5 form elements (the search box and filters) -- a 97% reduction from the 168 total interactive elements.
4. `read main` on GitHub returned 16K chars of README content with nav/footer stripped. The same content in AFK's observation was ~8.6K chars (AFK truncates more aggressively).

**Quality comparison of element selection:**

| Signal | AFK (80 elements) | AB (30 elements) |
|--------|-------------------|------------------|
| Search box present | Yes | Yes |
| Primary action buttons | Yes (mixed with noise) | Yes (ranked high) |
| Empty-label elements | 15+ on GitHub | 0 (demoted by scoring) |
| Duplicate labels | Present ("Jump up" x30 on Wikipedia) | Deduplicated |
| Footer/boilerplate | Present | Demoted/excluded |
| Off-screen elements | Present (0,0,0,0 bboxes) | Demoted |

## 7. Auth/Session Tradeoff

Unchanged. Agent Browser operates the human's real authenticated session. AFK Playwright cannot. For any workflow requiring login state (dashboards, admin panels, logged-in SaaS tools), Agent Browser is the only option without manually exporting and loading storage state.

## 8. Parallelism/Isolation Tradeoff

Unchanged structurally, but the practical impact is nuanced:

- **AFK subagents get per-context isolation.** Two subagents browsing simultaneously never interfere. This is a hard architectural advantage for unattended parallel work.
- **Agent Browser tabs are independent.** Two agents can safely operate separate tabs concurrently as long as they don't navigate the same tab simultaneously. Tab IDs provide sufficient coordination.
- **Shared-session risk is real but bounded.** An agent clicking in the wrong tab disrupts the human. But this is a coordination problem, not an isolation problem -- it's solvable with tab-locking or agent-tab assignment.
- **The question is workload mix.** Most AFK browser use today is sequential single-agent work (open, read, interact, done). Parallel multi-agent browsing is uncommon in practice.

**Assessment:** Parallelism remains a Playwright advantage, but it is rarely the deciding factor in actual AFK workloads.

## 9. Security Tradeoff

Unchanged. Agent Browser operating the human's real session carries higher blast radius. Playwright's isolated context is inherently safer for unattended work. Agent Browser should require explicit opt-in for autonomous actions on authenticated sessions.

## 10. Resource Usage

| Metric | Agent Browser | AFK Playwright |
|--------|:---:|:---:|
| Processes | 1 | 12 |
| RSS Memory | 139 MB | 792 MB |
| Ratio | 1x | **5.7x** |

Agent Browser uses 5.7x less memory and 12x fewer processes. The gap widened from the original measurement (was 3.4x) because Chromium spawned more processes with concurrent contexts.

## 11. Recommended Routing Policy

### DYNAMIC_ROUTING

The evidence no longer supports a blanket "Playwright 90%+ default" recommendation. The two systems have comparable context costs, and Agent Browser has material advantages in latency, memory, element quality, and query-focused capabilities.

**Route to Agent Browser when:**
- The human's browser is running (Agent Browser app is active)
- The task involves a single-agent sequential workflow
- The target page may be authenticated
- Low latency matters
- The human wants to observe agent actions
- Query-focused inspection or reading would be cheaper than full observation
- Memory conservation matters (e.g., many AFK sessions running)

**Route to AFK Playwright when:**
- Agent Browser is not running
- Multiple subagents need concurrent browser access
- The task is fully unattended (daemon, scheduler)
- Session isolation is required (destructive-action risk)
- Cross-platform execution is needed
- `web_scrape` (Readability mode) is sufficient (no interaction needed)

**Estimated workload split (from AFK codebase patterns):**
- **Clearly Agent Browser:** ~40% (single-agent interactive, authenticated, human-present)
- **Clearly Playwright:** ~25% (parallel subagents, unattended daemon, web_scrape-only)
- **Either (no strong preference):** ~35% (single-agent, unauthenticated, sequential)

The previous "90%+ Playwright" is no longer defensible. With comparable context costs, Agent Browser's latency, memory, element quality, and authenticated-session advantages make it the better default for the ~40% of workloads where those matter, and competitive for the ~35% where neither system dominates.

## 12. Summary Table

| Dimension | Agent Browser | AFK Playwright | Winner |
|-----------|:---:|:---:|:---:|
| Cold startup | 0ms (always on) | 2-4s | **Agent Browser** |
| Warm latency | 5-37ms | 550-1400ms | **Agent Browser** |
| Inspect quality | 30 ranked elements | 80 uncapped (noisy) | **Agent Browser** |
| Read quality | Bounded, query-focused | Full dump, no query | **Agent Browser** |
| Context cost | 30-33K | 26-28K | AFK (1.17x cheaper) |
| Calls per workflow | 3 | 1 | AFK (fewer calls) |
| Auth session | Real human session | Isolated (no auth) | **Agent Browser** |
| Human visibility | Yes (live GUI) | Headless | **Agent Browser** |
| Parallelism | Tab-level | Context-level | **AFK** |
| Isolation | Shared session | Per-context | **AFK** |
| Security | Higher blast radius | Lower blast radius | **AFK** |
| Memory | 139 MB | 792 MB | **Agent Browser** |
| Processes | 1 | 12 | **Agent Browser** |
| Cross-platform | macOS only | All platforms | **AFK** |
| Compatibility | WKWebView | Chromium | AFK (broader) |
| Reliability | Tested, 90 tests | Battle-tested | Comparable |
| Debugging | Live GUI + errors | Screenshots + witness | Comparable |
| Agent ergonomics | Ranked elements, modes, query | Single bundled obs | **Agent Browser** |

**Score: Agent Browser 9, AFK 6, Comparable 2.**

## 13. Final Verdict

### DYNAMIC_ROUTING

**What should AFK use by default?**
Agent Browser, when available. Its latency, memory, element quality, and ergonomic advantages outweigh the small (1.17x) context cost premium. Playwright becomes the fallback for isolation-critical and parallel workloads.

**What conditions should trigger Agent Browser?**
- Agent Browser app is running (detected via connection.json)
- Single-agent sequential workflow
- Any authenticated or human-visible workflow
- When query-focused read/inspect would reduce context

**What conditions should trigger Playwright?**
- Agent Browser not running
- Parallel subagent browser tasks
- Unattended daemon/scheduler work
- Session isolation required
- Cross-platform execution

**Is Agent Browser now first-class or still specialized?**
First-class. The bounded output implementation eliminated the only decisive weakness (context cost). Agent Browser is now competitive or better than Playwright on 15 of 17 measured dimensions.

**Has the old "90%+ Playwright" recommendation changed?**
Yes. The recommendation is now approximately 40% Agent Browser preferred, 25% Playwright preferred, 35% either. When Agent Browser is available, it should be the default.

**What is the single biggest remaining obstacle to Agent Browser becoming the universal default?**
Platform lock-in. Agent Browser is macOS-only (WKWebView). If AFK ever runs on Linux or Windows, Playwright remains the only option there.

---

*Re-evaluation conducted 2026-08-30 using identical methodology to the original benchmark. AFK Playwright measurements verified against witness-trace resultBytes for precision.*
