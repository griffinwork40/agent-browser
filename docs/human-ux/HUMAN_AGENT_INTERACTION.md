# Human-Agent Interaction Design

Detailed shared-control design for Agent Browser.

---

## Core Principle

The browser communicates agent activity without becoming an agent dashboard. The human always has authority. External agents operate the browser; the browser does not contain intelligence.

---

## Activity Model

### Agent Connection Lifecycle

```
DISCONNECTED -> CONNECTED    (agent authenticates via bearer token)
CONNECTED    -> ACTIVE       (agent begins an operation)
ACTIVE       -> CONNECTED    (operation completes)
CONNECTED    -> DISCONNECTED (token expires, agent crashes, explicit disconnect)
```

### Domain Types

```swift
struct AgentConnection: Identifiable, Sendable {
    let id: String                // token prefix or declared agentID
    let connectedAt: Date
    var lastSeenAt: Date
    var displayName: String       // "AFK", "Claude", "Codex", or custom
    var status: ConnectionStatus  // .active | .idle | .disconnected
    var color: AgentColor         // assigned from fixed palette
}

struct AgentAction: Identifiable, Sendable {
    let id: UUID
    let agentID: String
    let tabID: UUID
    let method: String            // "page.click", "page.read", etc.
    let description: String       // "Clicking 'Add to Cart'"
    let startedAt: Date
    var status: ActionStatus      // .inFlight | .completed(at:) | .failed(at:,reason:) | .overridden(at:)
}
```

### AgentActivityStore

```swift
@Observable @MainActor
final class AgentActivityStore {
    var connections: [AgentConnection] = []
    var activeActions: [AgentAction] = []       // currently in-flight
    var recentActions: [AgentAction] = []       // completed, capped at 50

    func actionsForTab(_ tabID: UUID) -> [AgentAction]
    func isTabAgentControlled(_ tabID: UUID) -> Bool
    func activeAgentForTab(_ tabID: UUID) -> AgentConnection?
}
```

---

## Tab Control State Machine

Each tab has an independent control state:

```
    +------+     agent begins      +--------------+
    | IDLE | -------------------> | AGENT_ACTIVE |
    +------+                      +--------------+
       ^                           |      |      |
       |   agent completes         |      |      |
       +---------------------------+      |      |
       |                                  |      |
       |              human touches       |      | error
       |                                  v      v
       |                          +------------+ +-------+
       |                          |INTERRUPTING| | ERROR |
       |                          +------------+ +-------+
       |                                  |          |
       |               <100ms             |  ack/    |
       |           (agent completes       | timeout  |
       |            current atomic)       |          |
       |                                  v          |
       |                          +------------+     |
       +--------------------------| HUMAN_OWNS |<----+
            (resume or idle)      +------------+
```

### State Definitions

| State | Meaning | Tab Indicator |
|---|---|---|
| IDLE | No agent activity on this tab | Hidden |
| AGENT_ACTIVE | Agent is performing an operation | Blue, pulsing |
| INTERRUPTING | Human touched tab; agent completing current atomic action | Blue, solid (transient, <100ms) |
| HUMAN_OWNS | Human has taken control; agent paused | Hidden (human has control) |
| ERROR | Agent action failed | Red, flash |

### Transitions

| From | To | Trigger |
|---|---|---|
| IDLE | AGENT_ACTIVE | Agent begins operation via API |
| AGENT_ACTIVE | IDLE | Agent operation completes normally |
| AGENT_ACTIVE | INTERRUPTING | Human clicks/types/navigates in tab |
| AGENT_ACTIVE | ERROR | Agent operation throws error |
| INTERRUPTING | HUMAN_OWNS | Agent completes current atomic action |
| HUMAN_OWNS | IDLE | Human stops interacting, no agent task waiting |
| HUMAN_OWNS | AGENT_ACTIVE | Human clicks Resume |
| ERROR | IDLE | Error acknowledged or 10s timeout |

---

## Provenance Model

### Tab Provenance

Write-once at tab creation, stored in `TabRecord`:

```swift
enum TabProvenance: Sendable, Codable {
    case human
    case agent(agentID: String, sessionTag: String, requestedAt: Date)
    case restored(originalProvenance: TabProvenance)
}
```

`sessionTag` groups tabs from the same agent task (e.g., "research-wkwebview-content-worlds").

### Provenance-Enabled Actions

| Action | How |
|---|---|
| Close all tabs from agent X | Filter by `provenance.agentID` |
| Close all tabs from task Y | Filter by `provenance.sessionTag` |
| Keep tab (promote to human) | Set `provenance = .human` (only allowed mutation) |
| Visual distinction | ProvenanceBadge on agent-created tabs |

### Provenance in Session Restoration

Agent-created tabs are restored with `.restored(originalProvenance: .agent(...))`. The original agent/task information is preserved for display and filtering. The agent connection itself is NOT restored (agent must reconnect).

---

## Takeover Design

### Touch-to-Takeover

When an agent controls a tab, direct human interaction immediately interrupts.

| Human Action | Triggers Takeover? | Rationale |
|---|---|---|
| Click page content | **Yes** | Unambiguous intent to interact |
| Keyboard input to page | **Yes** | Unambiguous intent to type |
| Address bar navigation | **Yes** | Human redirecting the tab |
| Right-click (context menu) | **Yes** | Human wants contextual interaction |
| Scroll | **No** | Human reads while agent works; scroll-as-takeover is catastrophic noise |
| Tab switch away | **No** | Agent keeps working on the background tab |
| Hover without click | **No** | Observer behavior, not control intent |
| Window resize | **No** | Layout operation, not content interaction |

### Takeover Flow

1. Human clicks/types/navigates in an agent-controlled tab
2. Browser intercepts the event in the AppKit event queue (<50ms)
3. Browser signals the agent via API: structured interrupt with current URL and action context
4. Agent completes the current atomic action (see boundaries below)
5. Tab control state transitions: AGENT_ACTIVE > INTERRUPTING > HUMAN_OWNS
6. Non-blocking banner appears: "You have control. [Let agent resume when done]" (auto-dismiss 3s)
7. Human's original action is delivered to the page normally

### Atomic Action Boundaries

The agent completes the current atomic action before yielding. Never interrupt mid-action.

| Action Type | Atomic Boundary | Interrupt Behavior |
|---|---|---|
| Click | Instantaneous | Always completes (already fired) |
| Fill | Completes current field | Never submits form; field has partial value |
| Navigate | If fired: completes. If queued: cancels. | Navigation may arrive at new URL |
| Read/inspect | Completes | Non-mutating, harmless to finish |
| Screenshot | Completes | Non-mutating |
| Press (Enter on form) | **GATED** | Never fires without human approval |
| Evaluate JS | Completes | Cannot partially execute |

### Explicit Take Control Button

A persistent but subtle "Take Control" button visible when an agent is active on the focused tab. Single click, no confirmation dialog. Useful for:

- Preemptive interrupt before agent reaches a destructive gate
- When the human wants control but has not yet interacted with the page
- Clear signal vs. the implicit touch-to-takeover

---

## Stop / Resume / End

### Stop

Immediately halts the agent's current task on this tab. Agent receives a stop signal. In-flight atomic action completes, but no further actions are dispatched. Tab transitions to HUMAN_OWNS.

Available via: Take Control button, agent activity popover Stop button, keyboard shortcut (Cmd-Shift-A suggested).

### Resume

Human explicitly allows agent to continue. Tab transitions back to AGENT_ACTIVE. Agent receives a resume signal containing:

- Current URL (may have changed during HUMAN_OWNS)
- Summary of DOM changes to interactive elements
- Human actions taken during HUMAN_OWNS period (from action log)

Available via: agent activity popover Resume button, control status bar Resume button.

Three resume scenarios:
1. **Page unchanged**: agent resumes immediately from where it left off
2. **Page partially changed**: agent receives changes as context, incorporates
3. **Page drastically changed** (human navigated away): agent prompted "Resume from new location?" or task is ended

### End

Terminates the agent's entire task (not just current action). All agent-created tabs from this task remain open but transition to IDLE. Agent receives an end signal. No further actions from this task are accepted.

Available via: agent activity popover End button.

---

## Soft Gate (Form Submit Protection)

Only form submits, purchases, and deletes receive a confirmation gate. Everything else fires silently.

### Detection

The browser identifies gated actions by:
- Button `type="submit"` inside a `<form>`
- Button with role="button" that is the closest submit target in a form
- Button text matching patterns: "submit", "purchase", "buy", "pay", "delete", "remove", "confirm order"
- Agent API `page.click` on an element flagged as `isSubmit` in the element inspection

### Flow

1. Agent requests `page.click` on a detected submit/purchase/delete target
2. Browser shows 2-second non-blocking interstitial: "Agent wants to submit this form. [Allow] [Review First]"
3. No response in 2 seconds: auto-allow (prevents stalling on unattended use)
4. "Review First": transitions to HUMAN_OWNS, form NOT submitted, human inspects
5. "Allow": form submitted, agent continues normally

### What is NOT Gated

- Reading/inspecting (non-mutating)
- Clicking links/navigation (reversible)
- Filling form fields (not yet submitted)
- Scrolling (non-mutating)
- Screenshots (non-mutating)
- Selecting dropdown options (not yet submitted)
- Pressing non-submit keys (Tab, Escape, etc.)

---

## Activity Visualization

### Layer 0: Tab Indicator (always visible)

Colored left border on the tab row in the sidebar, 3px wide:

| Color | Meaning | Animation |
|---|---|---|
| Blue | Agent actively working | Pulsing: opacity 0.5-1.0, 2s period |
| Yellow | Agent needs human input | Static |
| Green | Agent completed | Flash, then fade over 3s |
| Red | Agent error | Flash, then static for 5s |
| Absent | No agent activity | --- |

Reduce Motion: all states static (no pulsing, no fading).

### Layer 1: Tab Subtitle (visible when sidebar is open)

Text below the tab title, at `Typography.caption` size:

- "AFK: researching..." (agent active)
- "Claude: 3 actions" (agent active, summarized)
- "Waiting for you" (agent needs human)
- "Completed" (agent done, before indicator fades)

Updates at most every 2 seconds to avoid visual noise.

### Layer 2: Hover Peek (on hover over tab indicator, 2-second delay)

Tooltip-style overlay:
- Current action: "Clicking 'Add to Cart'"
- Progress: "Step 3 of ~8"
- Duration: "Started 45s ago"
- [Pause] button

### Layer 3: Click Expand (deliberate click on indicator)

Full agent activity popover (via `PopoverContainer`):
- Agent name and assigned color
- Intent preview: "Next: will navigate to checkout"
- Step-by-step action log with timestamps
- [Pause] [Resume] [End] buttons
- [View full history] link

### Layer 4: Full History (on demand)

Dedicated activity panel (sidebar section or sheet):
- Complete chronological log of all agent actions across all tabs
- Filterable by agent, tab, time range
- Auto-screenshots at key steps (V2)
- Exportable as JSON (V2)

---

## Multiple Agents

### Visual Distinction

Each connected agent receives a unique color from a fixed palette:

| Index | Color | Usage |
|---|---|---|
| 0 | Blue | First agent (default) |
| 1 | Purple | Second agent |
| 2 | Orange | Third agent |
| 3 | Teal | Fourth agent |
| 4 | Pink | Fifth agent |
| 5 | Indigo | Sixth agent |

Color assigned by agentID, consistent across sessions (hash-based assignment).

### Simultaneous Operations

- Multiple agents on **different tabs**: fully supported. Each tab shows its agent's color.
- Multiple agents on **same tab**: strict FIFO queue. Tab indicator shows queue depth ("2 agents queued" in subtitle). First-in runs; others wait.
- Queue visibility: count in tab subtitle, detail in hover peek.

### Agent Identity

- Named by `agentID` from API: "AFK", "Claude", "Codex", or custom string
- Displayed in activity popover, tab subtitle, control status bar
- Color + name together for identification
- If agent does not declare a name, use token prefix as identifier

---

## Session Restoration

### What to Restore

| Data | Restored? | Notes |
|---|---|---|
| Agent-created tabs | Yes | With provenance metadata intact |
| Tab groupings by task | Yes | sessionTag preserved in TabRecord |
| Activity history | Yes | From agent.db action log |
| Tab control state | Reset to IDLE | All tabs start uncontrolled |

### What to Discard

| Data | Discarded? | Notes |
|---|---|---|
| Agent connections | Yes | Agent must reconnect on new session |
| In-flight operations | Yes | Agent must re-request |
| Ephemeral indicators | Yes | Ghost cursor, active pulsing |
| HUMAN_OWNS state | Yes | All tabs reset to IDLE |

---

## Conflict Behavior

| Scenario | Resolution |
|---|---|
| Human clicks while agent clicking | Human wins; agent action logged as "overridden" |
| Agent acts on tab human is using | Agent queued until tab transitions to IDLE |
| Two agents target same tab | FIFO queue; second agent waits |
| Agent acts during form submit gate | Gate blocks agent action until resolved |
| Network error during agent action | Agent receives error; tab stays in current state |
| Agent disconnects mid-action | In-flight action completes; no further actions; tab transitions to IDLE |
| Agent reconnects after disconnect | Must re-authenticate; previous task state not assumed |
