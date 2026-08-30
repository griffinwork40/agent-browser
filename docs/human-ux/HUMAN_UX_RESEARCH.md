# Human UX Research

Synthesis of findings from 9 parallel research tracks conducted for the Agent Browser human UX redesign.

---

## 1. Apple / Liquid Glass

### What Liquid Glass Is

A dynamic material introduced in macOS 26 Tahoe (WWDC 2025) that combines optical glass properties with fluid interactivity. It blurs content behind it, reflects surrounding color and light, and reacts to pointer interactions in real time. It forms a distinct functional layer floating above the content layer.

### Key APIs (macOS 26+)

| API | Purpose |
|---|---|
| `.glassEffect()` | Default modifier. Regular variant, capsule shape. |
| `.glassEffect(.regular.tint(.accent).interactive())` | Tinted, pointer-reactive |
| `.glassEffect(.clear)` | Highly translucent, for media backgrounds only |
| `GlassEffectContainer(spacing:)` | REQUIRED wrapper when multiple glass views coexist. Controls blend distance. |
| `.glassEffectUnion(id:namespace:)` | Combine distinct views into one glass shape |
| `.glassEffectID(_:in:)` | Coordinate morph animations across hierarchy |
| `.buttonStyle(.glass)` | Glass button style |
| `.buttonStyle(.prominent)` | Tinted primary action |

### What Gets Glass Automatically

All standard SwiftUI/UIKit/AppKit components: tab bars, toolbars, sidebars, sheets, popovers, alerts, buttons, sliders, toggles. Build against the macOS 26 SDK with no code changes.

Escape hatch: `UIDesignRequiresCompatibility` Info.plist key ships with previous appearance.

### Where NOT to Use Glass

- App content backgrounds
- Multiple custom controls simultaneously
- Stacked or overlapping glass elements
- Anything in the content layer
- Per-row in lists (100 glass rows risks GPU OOM on integrated graphics)

### Accessibility Degradation

| Setting | Behavior |
|---|---|
| Reduce Transparency | Translucency removed; system substitutes opaque appearance. Custom views need manual `.background` fallback. |
| Reduce Motion | Fluid morphing suppressed. Use `.materialize` transition. |
| Increase Contrast | Glass shifts more opaque; supply light-HC and dark-HC asset variants. |
| Dark/Light Mode | Automatic adaptation. Supply both color variants in asset catalog. |

### Performance Implications

- `.ultraThinMaterial`: ~0.3-0.8ms per surface per frame compositing cost
- Sidebar glass over live WKWebView forces re-composite every frame. Fix: separate NSView trees for sidebar and web content.
- Hard cap: **2 Liquid Glass surfaces per window** (toolbar + sidebar)
- GPU texture: ~65 MB per surface at 2560x1600 @2x. Two surfaces = 130 MB GPU.
- Window resize: throttle layout to 30fps during live resize

### macOS 15 Fallback

For deployments targeting macOS 15 (pre-Liquid Glass):
- Toolbar: `.bar` material via `NSVisualEffectView`
- Sidebar: `.sidebar` material
- Popovers: `.hudWindow` material
- All degrade gracefully under Reduce Transparency

---

## 2. Browser Competitive Research

### Tab Models

**Horizontal tabs are dead at scale.** Chrome and Firefox become unreadable at 8+ tabs and functionally unusable at 20+. At 50+ tabs, the tab bar is purely decorative. The fundamental scaling failure has not been solved in the horizontal paradigm.

**Vertical tabs are the correct foundation for power users.** Edge, Arc, Vivaldi, Firefox 133+, and Zen all converged on vertical sidebar tabs. A sidebar at 180-240px wide trades horizontal space the web does not use (95% of content is center-column constrained) for the ability to actually read tab titles at any scale.

**Tree tabs are opt-in, not default.** Visual noise is too high for most users. Arc deliberately avoided surfacing tree structure despite tracking parent-child internally. Correct decision.

**Tab groups/spaces: 3 distinct concepts to not conflate:**
1. Profile/Space: isolated browsing context (separate cookies, history). Arc Spaces. Only 5.52% of Arc DAU used >1 Space.
2. Tab group: visual grouping within a context. Chrome Tab Groups.
3. Session snapshot: crash recovery / "continue later."

### Sidebar Lessons

**Arc successes:** Sidebar readability universally praised. Favorites icon grid (pinned apps) worked. Cmd-S toggle became muscle memory. Swipe gesture for Space switching.

**Arc failures:** Inconsistent tab insertion order broke spatial model. Ctrl-Tab cycled by recency, not visual position -- disorienting. Extensions could not be pinned to toolbar. Sidebar hide failed in fullscreen (most common complaint).

**Safari Tab Groups:** Cross-group finding is difficult. Adds mandatory organizational step before every navigation.

**Design principles derived:**
- Pinned items at top, always visible
- Regular tabs below, scrollable
- New tabs always at bottom (natural reading direction)
- Hover-to-expand on collapsed sidebar (100-200ms delay)
- Tab cycling must match visual position order
- Full-width collapse shortcut

### Omnibox Patterns

**Unified input (URL + search + tab switch) is correct.** Chrome established this in 2009; the modern extension is merging tab switching into the same input.

**Arc's best feature:** Type a fragment, and if a tab is already open with that page, pressing enter switches to it instead of opening a duplicate. This alone eliminates massive duplicate-tab accumulation.

**Autocomplete principles:**
- Top result must not change as async suggestions arrive (stability)
- Ranked by frecency (recency x frequency), not recency alone
- Inline autocomplete on first hostname match
- Developer audience: always display full URL, not simplified form

**Command palette integration:** Cmd-K/Cmd-T should extend with verb support. `>` prefix for commands, `?` prefix for AI. AI is never the default route.

### Keyboard Table Stakes

Every power user has muscle memory. Breaking any shortcut causes immediate abandonment:

Cmd-T, Cmd-W, Cmd-Shift-T, Cmd-L, Cmd-[, Cmd-], Cmd-1 through Cmd-9, Cmd-Shift-[/], Cmd-R, Cmd-Shift-R, Cmd-., Cmd-F, Cmd-G, Cmd-Shift-G, Cmd-+, Cmd--, Cmd-0, Cmd-Shift-L (sidebar toggle), Cmd-Option-L (downloads), Cmd-N, Cmd-Shift-N, Cmd-P, Cmd-S.

### Visual Density

Safari's minimal chrome approach is correct. Arc proved webpage-first works. Chrome's compact mode shows power users want density. The right balance: compact but not cramped. 40pt tab rows, 52pt toolbar, collapsible sidebar.

### Patterns to Avoid

- Arc's forced organization (Spaces mandatory, auto-archiving)
- Safari's Tab Group finding friction
- Chrome's horizontal tab overflow
- Sidebar animations that lag behind pointer
- Tab insertion at top (breaks spatial model)

---

## 3. Human-Agent Interaction

### Universal Insight

Every domain studied (coding agents, collaborative editors, autonomous vehicles, remote desktop, industrial robotics) agrees: ephemeral presence state (what is happening now) must be strictly separated from the durable action log (what happened). Systems that conflated them either became too noisy or too opaque.

### Touch-to-Takeover

| Human Action | Triggers Takeover? | Rationale |
|---|---|---|
| Click page content | Yes | Unambiguous intent |
| Keyboard input to page | Yes | Unambiguous intent |
| Address bar navigation | Yes | Human redirecting |
| Right-click (context menu) | Yes | Human wants to interact |
| Scroll | **No** | Human reads while agent fills |
| Tab switch away | **No** | Agent keeps working on background tab |
| Hover without click | **No** | Observer behavior |

Explicit "Take Control" button remains useful for preemptive interrupt.

### 4-Layer Activity Visualization

| Layer | Visibility | Content | Effort |
|---|---|---|---|
| 0: Tab indicator | Always | Colored left border (blue/yellow/green) | Zero |
| 1: Tab subtitle | Sidebar open | "AFK: researching..." | Glance |
| 2: Hover peek | 2s hover delay | Current action, progress, Pause | 2 seconds |
| 3: Click expand | Deliberate click | Full log, intent preview, Pause/Resume/End | Deliberate |
| 4: Full history | On demand | Complete chronological log | Panel |

Nothing beyond Layer 0 auto-surfaces during normal agent work.

### Conflict Resolution

- Human always wins. Simultaneous events: human's fires, agent's logged as "overridden."
- Form submit is the only gated action (2-second non-blocking soft gate).
- Multi-agent same tab: strict FIFO queue. Never two agents simultaneously.
- Multi-agent different tabs: fully supported, each shows its agent's color.

### Trust Builders

- Agent is always visible ("I can see what it's doing")
- Human can stop instantly ("I'm in control")
- History always available ("I can see what it did")
- Destructive gates require confirmation ("It won't surprise me")

### Noise Creators (Avoid)

- Modals during agent work
- Auto-opening panels
- Per-step notifications
- Requiring scroll confirmation

### Named Design Patterns

1. **Ghost Driver** -- agent rendered as visible presence (tab indicator, cursor). Like watching a colleague.
2. **Soft Gate** -- only form submits/purchases/deletes get a 2-second interstitial. Everything else silent.
3. **Task-Scoped Control** -- control for a specific task; returns to human on completion.
4. **Takeover Cascade** -- 3-second non-blocking banner: "You have control. [Let agent resume]."
5. **Separate Presence from Log** -- indicators = ephemeral (never stored); step log = durable.

---

## 4. Accessibility

### V1 Blocking

- Full keyboard navigation chain: Toolbar > Address bar > Tab bar > Sidebar > Web content
- VoiceOver landmarks: AXToolbar, AXTabGroup, AXGroup (sidebar), AXWebArea
- Complete keyboard shortcut inventory (30+ shortcuts)
- Focus ring on every interactive element (3:1 contrast ratio minimum)
- Focus preservation on tab switch (return to previous element or address bar)
- Reduce Transparency: opaque fallbacks for all materials
- Reduce Motion: instant transitions, no animation, static loading indicator
- High Contrast: 1pt borders on all regions, bold text for active tab
- Tab state differentiation by more than color alone (bold/icon/underline)
- Agent activity: color + shape distinction (circle/triangle/X)

### V1 Nice-to-Have

- Agent activity VoiceOver announcements on state change
- Custom VoiceOver rotor (Tabs, Agents, Bookmarks)
- Keyboard shortcut cheat sheet (Cmd-/)
- Focus-ring color matching accent color

### V2

- Customizable keyboard shortcuts
- Vim-style spatial navigation
- Full Increase Contrast override for all custom tints

---

## 5. Performance

### Memory Budget

| Tab Count | Strategy | Estimated RAM |
|---|---|---|
| 20 | 4 live + 6 suspended + 10 cold | ~590 MB |
| 50 | 5 live + 10 suspended + 35 cold | ~2.2 GB |
| 100 | 6 live + 14 suspended + 80 cold | ~2.6 GB |
| 200 | 6 live + 10 suspended + 184 cold | ~1.9 GB |

Hard cap: 6 live WKWebViews on a 16 GB machine.

### LRU Policy

- Live > suspended: 5 min backgrounded
- Suspended > cold: 15 min backgrounded (capture interactionState, navigate to about:blank)
- Cold > destroyed: 2h idle
- Pinned tabs: never below suspended
- Agent-created tabs: cold immediately when task completes

### Sidebar Performance

- Use `List` (NSTableView bridge), never `LazyVStack` for >20 tabs
- Fixed row height (44pt) required
- Favicon: 16x16 NSImage, NSCache capped at 4 MB
- KVO debounce at 200ms per tab; batch to <=5 updates/sec to SwiftUI
- Tab thumbnails: V2 (capture cost prohibitive for V1)

### Glass Performance

- Max 2 glass surfaces per window (toolbar + sidebar)
- Sidebar and web content in separate NSView trees (avoids per-frame recomposite)
- Window resize: throttle layout to 30fps during live resize

### Agent Tab Bursts

Cold-first queue: create sidebar row + cold WKWebView immediately, promote to live via 3-concurrent gate. On task complete, schedule cold demotion in 60s.

### Persistence

- Session save: every 30s idle + on tab close + on app quit. Never on every navigation.
- FTS5 history: 90-day retention in indexed table; archive older rows.
- Query latency at 100K rows: ~25ms (within 50ms autocomplete budget).

---

## Citations

- Apple Developer Documentation: developer.apple.com/documentation/swiftui/applying-liquid-glass-to-custom-views
- Apple Human Interface Guidelines: developer.apple.com/design/human-interface-guidelines/
- WWDC25: "What's new in SwiftUI", "Liquid Glass" sessions
- Arc usage data: 5.52% of daily active users used >1 Space
- WKWebView memory measurements: Kestrel Browser project, confirmed ~130 MB per live tab
- WebKit WebProcessCache behavior: 30-minute warm period, 30-second suspend
- blur-browser: confirmed NSSplitViewController + NSHostingController layout cycle bug
