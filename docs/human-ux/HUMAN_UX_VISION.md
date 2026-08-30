# Human UX Vision

## Product Thesis

Agent Browser should work beautifully as a normal macOS browser even when no agent is connected.

Its unique advantage: the browser has a first-class model for both humans and external agents operating the same browser state. Every tab is a programmable object. External agents see exactly what the human sees -- the same authenticated sessions, the same rendered pages, the same interactive elements.

### What Agent Browser Is

Infrastructure and interface for a shared human-agent browsing session. External agents such as Agent AFK, Claude, Codex, or future tools can operate it through a local API. The browser remains model-agnostic. It does not contain intelligence. It exposes browser state to external intelligence and visualizes external agent activity.

### What Agent Browser Is Not

- Safari clone with an AI sidebar
- Chrome clone with a chatbot panel
- Arc clone with forced organization
- A browser that owns its own LLM
- A generic "AI browser"
- A headless automation tool with a GUI attached

The browser's competitive position is not "better rendering engine" or "better tab UI." It is: no other browser treats its own state as a set of programmable primitives that external processes can address while a human uses it simultaneously.

---

## Design Principles

### Webpage-first

Browser chrome consumes minimal attention and space. The website is the primary content. The sidebar collapses. The toolbar is compact. There is no dashboard, no panel, no overlay that competes with the webpage for attention by default.

Every pixel of chrome earns its place by reducing friction between the human and the web, or between the agent and the web. Features that add chrome for their own sake are rejected.

### Native

Prefer platform-native macOS interaction over custom reinvention. Use Liquid Glass where Apple intends it (toolbar, sidebar, popovers). Use system materials, system controls, SF Symbols, dark/light mode, and the system accent color. Respect every accessibility setting (Reduce Transparency, Reduce Motion, Increase Contrast, VoiceOver).

The browser should feel like it belongs on macOS. Not like a web app wrapped in a native shell. Not like an Electron app pretending to be native. The test: does it look and behave like something Apple would ship?

### Fast

Common interactions feel instant. The target is <100ms perceived latency for all direct human actions:

- Cmd-L (focus address bar)
- Cmd-T (new tab)
- Cmd-W (close tab)
- Tab switching (click or keyboard)
- Back/forward
- Sidebar toggle
- Opening links
- Address bar autocomplete appearance

The browser should never make the human wait for chrome. The web page may be slow; the browser around it must not be.

### Keyboard excellent

The audience is developers and power users. Keyboard navigation must be exceptional, not adequate. Every standard browser shortcut works. Tab switching by position works. The address bar is the universal entry point. The sidebar is navigable by keyboard. Focus management between AppKit and SwiftUI boundaries is seamless.

A developer should be able to use Agent Browser for a full day without touching the trackpad for browser-level operations.

### Agent-aware, not agent-dominated

The browser communicates agent activity without turning the UI into an agent dashboard. The default state is a normal browser. Agent activity is:

- **Always visible** when it exists (subtle tab indicator)
- **Available on demand** (click for detail)
- **Never unsolicited** (no popups, no notifications, no modals for reads)
- **Separated from browser chrome** (agent info in the sidebar, not the toolbar)

When no agent is connected, the browser looks and works exactly like a normal browser.

### Human authority

The human always understands when an agent is acting and can regain control immediately. This is the foundational trust contract:

- **Touch-to-takeover**: click, type, or navigate in an agent-controlled tab to immediately interrupt
- **No approval for reads**: agents read pages silently
- **Soft gate for mutations**: form submits and purchases get a brief, non-blocking confirmation
- **Stop is instant**: one click to halt any agent activity
- **Activity is visible**: the human can always see what the agent did

The browser is the human's territory. Agents are guests who operate with permission and transparency.

---

## What Agent Browser Should Feel Like

**Safari's focus and polish.** The same restraint in chrome design. The same respect for the webpage. The same native feel.

**Arc's power-user density.** The vertical sidebar with readable tab titles. The keyboard-first workflow. The Cmd-T-to-search-open-tabs pattern.

**The unique transparency of a shared-control browser.** Like watching a capable colleague browse alongside you. You can see what they are doing. You can take over at any moment. You are never surprised.

The emotional register: **calm when idle. Informative when active. Never anxious.**

### Compared to Existing Browsers

| Browser | What Agent Browser shares | What Agent Browser does differently |
|---|---|---|
| **Safari** | Restraint, native feel, webpage-first philosophy | Vertical tabs, agent activity indicators, tab provenance |
| **Chrome** | Keyboard shortcuts, omnibox behavior, developer audience | Less chrome, no horizontal tab bar, no extension ecosystem (V1) |
| **Arc** | Sidebar approach, keyboard-first, Cmd-T search | Simpler mental model (no Spaces, no auto-archiving, no forced organization) |
| **Dia** | Agent-aware browsing concept | External agents, not built-in AI; infrastructure, not features |

---

## Visual Direction

### Materials and Glass

- **Toolbar**: Liquid Glass on macOS 26; `.bar` material fallback on macOS 15
- **Sidebar**: Liquid Glass or `.sidebar` material
- **Popovers and sheets**: Liquid Glass (automatic on standard controls)
- **Web content area**: NEVER glass. Solid background only.
- **Per-row in sidebar**: NO glass. Plain backgrounds with hover states.
- **Maximum**: 2 glass surfaces per window (GPU performance constraint)

### Color

- Muted, system-native color palette
- System accent color for agent activity indicators and selection highlights
- Agent-specific colors from a fixed palette: Blue, Purple, Orange, Teal, Pink, Indigo
- SF Symbols throughout, hierarchical rendering
- No custom icon set (V1)

### Typography

- System font (SF Pro) at system sizes
- 13pt body, 11pt caption, 17pt section titles
- Monospaced (SF Mono) for URLs in the address bar

### Density

- Compact information density appropriate for developer audience
- 40pt tab row height (readable but not wasteful)
- 52pt toolbar height (matches system toolbar conventions)
- 240px default sidebar width (adjustable)

### Accessibility Degradation

- **Reduce Transparency**: opaque `NSColor.windowBackgroundColor` fallback for all materials
- **Reduce Motion**: instant transitions, no animation, static indicators
- **Increase Contrast**: 1pt borders on all regions, bold text for active tab
- **Dark/Light mode**: automatic adaptation through system colors and materials

---

## Non-Goals

These are things Agent Browser explicitly does not attempt:

| Non-Goal | Rationale |
|---|---|
| AI chatbot sidebar | Conversation belongs in the agent (AFK, Claude, etc.), not the browser |
| Browser-owned LLM | The browser is model-agnostic infrastructure |
| Natural language in omnibox as default | Preserves trust and speed; AI is opt-in via prefix |
| Arc-style Spaces/auto-archiving | Simpler mental model; organization is optional, not enforced |
| Chrome-style extension ecosystem | WKWebExtensionController is macOS 15.4+ and young; V2 |
| iOS / cross-platform | macOS only. Period. |
| Custom rendering engine | WebKit via WKWebView |
| Built-in DevTools | Safari's Web Inspector is available in debug builds |
| Sync (bookmarks, history) | Cloud infrastructure, accounts, conflict resolution are out of scope |
| Default browser registration (V1) | Requires private API; Apple-relations risk |

---

## Browser Philosophy

The browser is a window onto the web, not a platform unto itself.

The web page is the content. The browser is the frame. The agent is a collaborator who can look through the same frame and occasionally adjust what is displayed.

Features earn their place by reducing friction. The bar is: does this make the human more effective at browsing, or does this make the agent more effective at helping? If neither, it does not ship.

The architecture is designed for years of development, not a demo. Every component is reusable. Every boundary is explicit. Every module has a single owner. The design system is real -- not a collection of one-off views. The state model is clean -- not a tangle of callbacks.

Agent Browser should be the best native macOS browser for developers, with or without agents. The agent capability is what makes it unique. The browser quality is what makes it usable.
