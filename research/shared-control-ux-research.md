# Shared-Control UX Research: Agent Browser
_Research date: 2026-08-29_

---

## 1. What the best systems have already solved

Six domains ship shared control today. The patterns that survived are:

| Domain | Killer pattern | Why it works |
|---|---|---|
| Cursor 2.0 / Claude Code | Grouped session list, one-line AI summary, "Needs Input" pinned top | Human scans 8 agents at once without opening any transcript |
| Figma / Google Docs | Ephemeral presence (colored cursor, focus border) on separate channel from durable edits | No conflict dialogs; zero overhead on the document |
| TeamViewer / Multi | Labeled dual cursor; role-switch with explicit toggle | Both parties always know who is driving |
| Windsurf Cascade | Named checkpoints + 20-tool budget cap | Human can always roll back; bounded autonomy |
| Browserbase DeepAgents | `interrupt_on` pauses at destructive tool boundary | Human approves the url+task before any click runs |
| Autonomous vehicles (SAE L3) | Multi-stage takeover cascade (info → warning → command); 10s lead time | Handoff is announced, not surprising |

**The universal principle**: ephemeral presence state (what the agent is doing right now) is strictly separated from durable action log (what the agent did). Presence is cheap, fast, and never persisted. Log is append-only, always recoverable.

---

## 2. Tab state machine (agent-controlled tab)

```
            agent claims tab
                   │
                   ▼
┌─────────────────────────────┐
│         AGENT_WORKING       │ ← animated indicator in tab bar
│  agent: navigating, clicking│   tab border: agent color (blue/purple)
│  human: read-only observer  │   ghost cursor visible
└──────────┬──────────────────┘
           │
     human touches tab
     (click / type / navigate)
           │
           ▼
┌─────────────────────────────┐
│      INTERRUPTING           │ ← <300ms flash: "Taking control..."
│  in-flight action: abort    │   agent receives interrupt signal
│  or complete current atomic │
│  step (never mid-form-fill) │
└──────────┬──────────────────┘
           │
           ▼
┌─────────────────────────────┐
│       HUMAN_OWNS            │ ← tab returns to normal appearance
│  agent: paused, watching    │   status chip: "Agent paused"
│  human: full control        │   resume button appears in tab bar
└──────────┬──────────────────┘
           │
     human clicks Resume,
     OR human navigates away
     (leaves the tab idle),
     OR timeout (configurable)
           │
           ▼
┌─────────────────────────────┐
│        RESUMING             │ ← agent re-reads page state
│  agent: re-orients          │   brief "Resuming..." indicator
│  page may have changed      │   agent gets diff of what changed
└──────────┬──────────────────┘
           │
           ▼
        AGENT_WORKING  (or → NEEDS_HUMAN if page state changed too much)
```

**NEEDS_HUMAN** is a separate terminal sub-state: agent hit a decision point it cannot resolve (login wall, CAPTCHA, ambiguous form). Tab gets a yellow badge, human must act first.

---

## 3. Touch-to-takeover: the core interaction

**Hypothesis confirmed by research**: implicit takeover on first touch is the right default.

Rationale from analogues:
- Cursor delivers human steering messages "at the agent's next tool call" — it finishes the atomic action, then hands off.
- AV research: never interrupt mid-maneuver; complete the current safe boundary first.
- TeamViewer/Multi: dual cursor coexists but only one person drives.

### Which human actions trigger takeover?
```
TRIGGERS (immediate takeover):
  - Click or tap on page content
  - Keyboard input focused to page
  - Address bar navigation
  - Drag on page content

NON-TRIGGERS (observer mode, no takeover):
  - Scrolling (read-only, agent keeps working)
  - Tab switching away (agent keeps working on idle tab)
  - Hovering without clicking
  - Opening DevTools (read-only)
```

Scroll is excluded because humans frequently scroll to read while an agent is filling a form in another section. Takeover on scroll would be catastrophic noise.

### What happens to in-flight automation?
The agent must track "atomic boundaries" - actions that must complete or fully abort:
- `navigate(url)` → let complete (navigation is atomic)
- `click(element)` → let complete (click is instantaneous)
- `fill(field, value)` → complete the current field, stop before next
- `submit(form)` → BLOCK (this is the destructive gate; require explicit human confirmation OR wait for AGENT_WORKING to trigger it)

**Form submit is the only action gated by default.** Everything else either completes instantly or can be cleanly interrupted at field boundaries.

### Explicit "Take Control" button
Still useful alongside implicit takeover, for one specific case: the human is watching and wants to preemptively pause the agent before it reaches a boundary (e.g., "I see it's about to submit that form and I want to review first"). The button gives a clean interrupt without waiting for the agent to hit the gate.

Button lives in the tab bar as an icon, not a modal. Disappears when human already owns the tab.

---

## 4. Agent activity visualization: layered disclosure

**Design principle from Figma/Google Docs**: three presence levels — identity, location, activity. Add a fourth for agents: intent (what will happen next).

### Layer 0: Always-visible tab indicator (5px effort from human)
```
[  🤖  amazon.com  ×  ]   ← blue pulsing left border = agent working
[  ⚠️  checkout.html ×  ]   ← yellow = needs human
[  ✓   amazon.com  ×  ]   ← green briefly = just completed
[  amazon.com     ×  ]   ← normal = human owns
```
Agent avatar (small colored dot matching the agent identity) in the tab favicon area. Same agent always same color across all tabs it controls.

### Layer 1: Ghost cursor (ambient, ~zero effort)
A semi-transparent cursor in the agent's color moves around the page showing where the agent's attention is. Exactly like Figma's multiplayer cursor. Labeled with agent name on hover.

Key decisions from research:
- 30fps broadcast, interpolated on receive (smooth, not janky)
- Fades to 40% opacity when agent is idle between steps
- Disappears entirely when human owns the tab

### Layer 2: Hover tab to peek (2-second effort)
Tooltip-style peek panel on tab hover:
```
┌───────────────────────────────┐
│ 🤖 Claude (Agent AFK)         │
│ ──────────────────────────── │
│ Searching for "MacBook Pro"   │
│ Step 3 of ~8                  │
│ Started 45s ago               │
│ [Pause]  [View Log]           │
└───────────────────────────────┘
```

### Layer 3: Click to expand activity panel (deliberate, 5s effort)
Sidebar/sheet showing:
- **Intent preview**: "Next: will click Add to Cart button"
- **Step log**: chronological list of completed actions (navigate, click, extract)
- **Agent source**: which external agent is controlling (Claude, Codex, AFK)
- **Started/duration**
- **Pause / Resume / End** controls

### Layer 4: Full history (on-demand, archival)
Accessible from activity panel → "Full Log":
- Every action with timestamp and outcome
- Screenshots at key steps (taken automatically by agent)
- Network requests the agent triggered
- Replay capability

**Nothing beyond Layer 0 should auto-surface during normal agent work.** Auto-surfacing activity destroys the value of having agents — it recreates the anxiety of watching someone else control your computer.

---

## 5. Multiple agents, same browser

Most complex case. Three sub-scenarios:

### 5a. Multiple agents, different tabs (easy)
Each tab gets its own indicator. No conflict. Human sees at a glance which tabs are agent-controlled by the colored border.

### 5b. Multiple agents, queue for same tab (needs policy)
Agents queue. Tab shows queue depth: `🤖×2` in the tab indicator. First agent in queue runs. Second waits. When first finishes or human interrupts, second gets the tab.

**Never let two agents drive simultaneously.** This is the universal lesson from all domains: dual cursor works for humans (who can negotiate socially) but agents cannot negotiate.

### 5c. Same agent, multiple tabs
Tabs all share the same agent color. Activity panel shows cross-tab context: "This agent is also active on 2 other tabs."

### Priority model for conflicts
```
1. Human always wins (any touch immediately interrupts)
2. Explicit "End agent control" always wins
3. First-in queue runs; later agents wait (FIFO, not priority)
4. Destructive actions (submit, purchase, delete) require gate regardless of queue position
```

---

## 6. Conflict resolution for simultaneous action

**Race condition window**: human clicks at exactly the same moment agent fires a click.

Resolution from research:
- AV systems: whichever signal arrived first to the actuation layer wins. The other is logged as "overridden."
- Figma: last-writer-wins for same property (but this is the wrong model for browser — a double-click is destructive).

**For the browser**: human wins any simultaneous race, AND the agent action is rolled back if it already fired. Log it as "agent action overridden by human."

This is physically achievable because:
- Browser maintains event queue
- Native macOS app can intercept agent's WebDriver calls before they reach the page
- 50-150ms window of uncertainty is acceptable (within human reaction time anyway)

---

## 7. Trust calibration: signal vs noise

From AV research: trust erodes when handoffs feel unexpected. From Figma: presence creates trust by showing what others are doing without requiring interaction.

### What creates trust
- Agent is always visible (ghost cursor, tab indicator) — "I can see what it's doing"
- Human can stop instantly — "I'm in control even when I'm not driving"
- History is always available — "I can see what it did"
- Destructive gates require confirmation — "It won't do anything irreversible without me"

### What creates noise (avoid these)
- Modals during agent work ("Agent is doing X, OK?")
- Requiring approval for read actions (navigate, scroll, extract)
- Auto-opening activity panels while human is looking at a different tab
- Notifications for every step

### Progressive disclosure rule
Only escalate to human attention when:
1. Agent cannot proceed without human input (NEEDS_HUMAN state)
2. Agent is about to take a destructive/irreversible action (submit form, make purchase, delete account)
3. Agent has been working for >N minutes and hasn't completed (configurable timeout)

For everything else: ambient indicators only.

---

## 8. Resume after interruption

The hardest UX problem. Page state may have changed while human owned the tab.

**Three scenarios**:
```
A. Page unchanged → Resume immediately, agent re-reads DOM, continues
B. Page partially changed (human filled one field) → Agent incorporates 
   the change, treats it as provided context, continues from next step
C. Page drastically changed (human navigated away) → Agent shows 
   "Page changed. Resume from new location?" with current URL shown
```

**Agent gets a diff**: when control transfers back, agent receives:
- Current URL vs URL when interrupted
- DOM snapshot comparison (key interactive elements that changed)
- Human's interaction log (what the human clicked/typed during HUMAN_OWNS)

This mirrors how Claude Code's agent view shows "a recap of what happened while you were away" when you attach to a session.

---

## 9. Design patterns summary

### Pattern A: "Ghost Driver"
Render the agent as a visible presence on the tab (colored cursor, tab indicator, ghost of what it's doing). Human feels like they're watching a colleague work, not a black box executing.

### Pattern B: "Soft Gate"
Form submits, purchases, and account deletions get a 2-second interstitial: "Agent will submit this form. [Allow] [Review first]." All other actions are silent.

### Pattern C: "Task-Scoped Control"
From pair programming research: control is handed to the agent for a specific task ("research and add to cart"), not open-ended. Task scope shows in the activity panel. When task completes, control automatically returns to human — agent does not linger.

### Pattern D: "Takeover Cascade"
When human takes over, a 3-second non-blocking banner appears at top of tab content: "You have control. [Let agent resume when done]". This mirrors AV multi-stage ToR but flipped: it's the human being informed, not prompted.

### Pattern E: "Separate Presence from Log"
Ghost cursor and tab indicator = ephemeral presence (high-frequency, never stored). Step log and history = durable action log (low-frequency, always recoverable). Never mix these two channels.

---

## 10. Open questions for implementation

1. **Atomic boundary detection**: how does the agent runtime communicate "I'm in a safe interrupt window" vs "don't interrupt now"? Needs API design.

2. **Ghost cursor rendering**: done by agent (sends coordinates) or by browser (watches what agent is doing via WebDriver intercept)? Agent-driven is more accurate; browser-driven works even if agent doesn't support it.

3. **Multi-agent queue UX**: does the human see who's waiting? Do waiting agents' owners get notified when they finally get the tab?

4. **Resume timeout**: if human owns the tab for 30 minutes, does the agent's task expire? What's the default?

5. **Agent identity persistence**: same agent color across sessions? Stored per agent-ID, not per session, so repeat interactions with the same agent always feel familiar.
