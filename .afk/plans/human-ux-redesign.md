# Plan: Human UX Redesign

## Status: Active
## Created: 2026-08-29

## Objective

Research, design, and plan the human-facing UX for Agent Browser so that it works beautifully as a normal macOS browser AND as a shared human-agent browsing session.

## Approach

Parallel research across 9 tracks (codebase archaeology, Liquid Glass, browser UX, human-agent interaction, design system, state architecture, agent concepts, accessibility, performance), synthesized into 6 deliverable documents in `docs/human-ux/`.

## Research Tracks Completed

1. **Archaeology** - Full codebase map: 2730 LOC, 14 Swift files, zero SwiftUI, zero design system
2. **Liquid Glass** - `.glassEffect()` API (macOS 26), `GlassEffectContainer`, material variants, accessibility degradation
3. **Browser UX** - Vertical tabs validated, Arc lessons, omnibox patterns, keyboard table stakes
4. **Human-agent interaction** - 4-layer activity model, touch-to-takeover state machine, soft gate pattern
5. **Design system** - 4-layer component architecture (tokens, primitives, browser, agent-aware)
6. **State architecture** - TabRecord/BrowserTab split, AgentActivityStore, Swift concurrency boundaries
7. **Agent concepts** - Provenance HIGH value/LOW complexity for V1, task grouping deferred
8. **Accessibility** - Complete keyboard shortcut inventory, VoiceOver landmarks, Reduce Transparency/Motion/Contrast
9. **Performance** - 6 live WKWebView cap, KVO debounce 200ms, max 2 glass surfaces, cold-first queue

## Key Decisions

### ADR-1: Vertical tabs, no horizontal
- Horizontal tabs fail at 8+ tabs (unreadable). Vertical tabs show titles at any scale.
- Sidebar at 180-240px wide; collapsible with Cmd-Shift-L.
- Alternatives rejected: horizontal (scaling), tree tabs (cognitive overhead), hybrid (complexity).

### ADR-2: AppKit window shell, SwiftUI embedded
- WKWebView is NSView; SwiftUI cannot own it. Window + toolbar + WKWebView = AppKit.
- Sidebar + overlays + settings + popovers = SwiftUI via NSHostingController.
- Never NSSplitViewController with NSHostingController (confirmed layout cycle bug).
- Alternative rejected: pure SwiftUI (WebView/WebPage macOS 26 too new, lacks WKNavigationDelegate).

### ADR-3: Liquid Glass on toolbar + sidebar only
- Max 2 glass surfaces per window (GPU budget). Never per-row. Never on web content.
- macOS 26: `.glassEffect()`. macOS 15: `.ultraThinMaterial` + `.thinMaterial` fallback.
- Reduce Transparency: opaque `NSColor.windowBackgroundColor` fallback.
- Alternative rejected: glass everywhere (GPU OOM on integrated graphics).

### ADR-4: Touch-to-takeover for human-agent control
- Click/type/navigate = immediate takeover. Scroll = NO (human reads while agent fills).
- Agent completes current atomic action, then hands off. Never interrupt mid-click.
- Tab indicator: colored left border (blue=working, yellow=needs-human, green=done).
- Form submit: 2-second soft gate. Everything else silent.
- Alternative rejected: explicit-only Take Control (too slow, breaks flow).

### ADR-5: Tab provenance in domain model
- Store origin (human/agent/agent+task/restored) in TabRecord. Write-once at creation.
- Enables "close all agent tabs from task X" with one action.
- Task/workspace grouping deferred to Later (high complexity, medium value).
- Alternative rejected: presentation-only provenance (loses bulk-close capability).

### ADR-6: State split: TabRecord (domain) vs BrowserTab (presentation)
- TabRecord: pure Sendable struct with identity, provenance, lifecycle, group.
- BrowserTab: @Observable wrapper owning WKWebView + KVO bridge.
- NavigationState: pure struct reflected from WKWebView, consumed by sidebar.
- Alternative rejected: monolithic BrowserTab (current state, couples domain to WebKit).

### ADR-7: GRDB everywhere for persistence
- GRDB + FTS5 for history, bookmarks, session, agent log.
- SwiftData rejected: no FTS5, doubles persistence surface area.
- WAL mode, DatabasePool, actor-isolated stores.

## Module Boundaries

```
DesignSystem (zero deps)
  <- BrowserCore (pure types, no framework imports)
    <- BrowserEngine (imports WebKit)
    <- Persistence (imports GRDB)
    <- AgentIntegration (imports Network)
      <- Features/* (import SwiftUI + upstream)
        <- Window (imports AppKit + everything)
```

## Implementation Phases

### Phase 1: Foundation (2 parallel lanes)
- Lane A: DesignSystem tokens + generic primitives
- Lane B: BrowserCore domain types + TabRecord/NavigationState split
- Sync: both complete before Phase 2

### Phase 2: Human Browser MVP (4 parallel lanes)
- Lane C: Sidebar + tab bar (SwiftUI)
- Lane D: Omnibox upgrade (autocomplete, URL/search, Cmd-L)
- Lane E: Persistence (GRDB, history, session restore, bookmarks)
- Lane F: Browser polish (tab lifecycle, keyboard shortcuts, downloads, find, zoom)
- Sync: all complete before Phase 3

### Phase 3: Agent-Aware UX V1 (3 parallel lanes)
- Lane G: Agent activity model + tab provenance
- Lane H: Agent activity indicators (tab border, popover)
- Lane I: Human takeover state machine + stop/resume

### Phase 4: Later (explicitly NOT blocking)
- Task/workspace grouping, command palette, multiple windows, ghost cursor, agent permissions

## Risks

1. BrowserAutomationService at 749 lines needs decomposition first
2. NSHostingController + AppKit layout pitfalls (avoid NSSplitViewController)
3. KVO observation overhead at 100+ tabs (debounce architecture from day 1)
4. Liquid Glass requires macOS 26 (graceful degradation on 15 required)
5. Tab lifecycle (cold/suspended) has no implementation yet

## Unresolved Questions

1. macOS 15 vs 26 minimum deployment target
2. Ghost cursor: V1 or V2? (requires agent-side protocol changes)
3. Tab thumbnail capture: performance budget needs spike
4. NSSplitViewController alternative for sidebar split

## Deliverables

All written to `docs/human-ux/`:
- HUMAN_UX_VISION.md
- HUMAN_UX_RESEARCH.md
- HUMAN_UX_ARCHITECTURE.md
- HUMAN_UX_COMPONENTS.md
- HUMAN_AGENT_INTERACTION.md
- HUMAN_UX_ROADMAP.md

## Verdict: GO
