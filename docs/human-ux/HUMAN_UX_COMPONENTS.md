# Human UX Components

Proposed reusable component inventory for Agent Browser, organized in 4 layers.

---

## Layer 0: Design Tokens

All tokens live in `DesignSystem/DesignTokens.swift`. Static constants, zero dependencies.

### Spacing (4pt base grid)

| Token | Value | Usage |
|---|---|---|
| `Spacing.px2` | 2pt | Icon-to-text gap, tight padding |
| `Spacing.px4` | 4pt | Between related controls |
| `Spacing.px6` | 6pt | Inline padding |
| `Spacing.px8` | 8pt | Standard padding, toolbar item gaps |
| `Spacing.px12` | 12pt | Section padding |
| `Spacing.px16` | 16pt | Card padding, sidebar insets |
| `Spacing.px20` | 20pt | Large section gaps |
| `Spacing.px24` | 24pt | Major section separation |
| `Spacing.px32` | 32pt | Empty state spacing |
| `Spacing.px48` | 48pt | Hero spacing |

### Typography

| Token | Spec | Usage |
|---|---|---|
| `displayLarge` | 28pt semibold rounded | Empty state titles |
| `title` | 17pt semibold | Section headers |
| `body` | 13pt regular | Tab titles, general text |
| `caption` | 11pt regular | URLs, timestamps, secondary text |
| `label` | 11pt medium | Badges, status labels |
| `mono` | 12pt monospaced | URLs in address bar, code |

### Corner Radii

| Token | Value | Usage |
|---|---|---|
| `Radius.small` | 4pt | Badges, small controls |
| `Radius.medium` | 8pt | Cards, popovers |
| `Radius.large` | 12pt | Panels, large surfaces |
| `Radius.pill` | 999pt | Capsule shapes (address bar) |

### Materials

| Token | Material | Usage |
|---|---|---|
| `Materials.chrome` | `.bar` | Toolbar, status bar |
| `Materials.overlay` | `.hudWindow` | Command palette, popovers |
| `Materials.surface` | `.sidebar` | Sidebar background |
| `Materials.card` | `.regularMaterial` | Cards, popover content |

### Animation

| Token | Spec | Usage |
|---|---|---|
| `Motion.micro` | 0.10s easeOut | Badge counts, icon swaps |
| `Motion.standard` | spring(0.25, 0.82) | General transitions |
| `Motion.enter` | spring(0.35, 0.78) | Panel appearance |
| `Motion.exit` | 0.18s easeIn | Dismissals |

All animations conditioned on `@Environment(\.accessibilityReduceMotion)`.

### Control Sizing

| Token | Value |
|---|---|
| `iconButtonSmall` | 24pt |
| `iconButtonRegular` | 28pt |
| `tabRowHeight` | 40pt |
| `sidebarWidth` | 240pt |
| `toolbarHeight` | 52pt |

### Opacity

| Token | Value | Usage |
|---|---|---|
| `disabled` | 0.35 | Disabled controls |
| `secondary` | 0.60 | Secondary text |
| `subtle` | 0.08 | Hover fills |
| `divider` | 0.12 | Separator lines |

---

## Layer 1: Generic UI Primitives

No browser knowledge. Pure SwiftUI views in `DesignSystem/`.

### GlassSurface

**Responsibility:** Applies the correct Material background, corner radius, and optional shadow to any content.

**Inputs:** `material: Material = .regularMaterial`, `radius: CGFloat = Radius.medium`, `elevation: Bool = false`, `@ViewBuilder content`

**Composition:** ZStack with `.background(material)`, `.clipShape(.rect(cornerRadius:))`, optional shadow.

**Accessibility:** Purely decorative. No semantic role. Reduce Transparency: falls back to `Color(.windowBackgroundColor)`.

---

### IconButton

**Responsibility:** Tappable icon with hover/press feedback, optional tooltip.

**Inputs:** `systemImage: String`, `label: String` (accessibility), `size: CGFloat = 28`, `isEnabled: Bool = true`, `action: () -> Void`

**Composition:** Button with Image(systemName:), hierarchical rendering. Custom ButtonStyle for hover (subtle fill) and press (scale 0.95) states. `.help(label)` for tooltip.

**Accessibility:** `.accessibilityLabel(label)`. Disabled: `.accessibilityAddTraits(.isNotEnabled)`.

---

### SidebarItem

**Responsibility:** Generic selectable row with leading icon, label, optional trailing content.

**Inputs:** `isSelected: Bool`, `leadingContent: some View`, `label: String`, `trailingContent: (some View)?`, `action: () -> Void`

**Composition:** Button wrapping HStack. Selected state: accent tint background at `Opacity.subtle`. `.buttonStyle(.plain)` with custom hover/press.

**Accessibility:** `.accessibilityLabel(label)`. `.accessibilityAddTraits(.isSelected)` when selected.

---

### CommandField

**Responsibility:** Single-line text input for search, address, commands. Clear button, leading icon slot.

**Inputs:** `text: Binding<String>`, `placeholder: String`, `leadingIcon: String?`, `onSubmit: (String) -> Void`, `onCancel: () -> Void`

**Composition:** HStack with optional Image, TextField, clear IconButton. Wrapped in GlassSurface with capsule radius. Uses `.focused()` and `.onSubmit`.

**Accessibility:** `.accessibilityLabel(placeholder)`. Clear button announced separately.

---

### StatusIndicator

**Responsibility:** Colored dot or icon communicating a discrete state.

**Inputs:** `status: Status` enum (idle, active, waiting, error, success), `animated: Bool`

**Composition:** Circle or Image with semantic color from switch. Active: repeating opacity animation. Reduce Motion: static color, no animation.

**Accessibility:** `.accessibilityLabel(status.description)`.

---

### ActivityBadge

**Responsibility:** Numeric or dot badge overlaid on another view.

**Inputs:** `count: Int`, `style: BadgeStyle` (dot, count, text)

**Composition:** `.overlay(alignment: .topTrailing)` with colored circle. Count uses `.contentTransition(.numericText())`.

**Accessibility:** `.accessibilityLabel("\(count) items")`.

---

### EmptyState

**Responsibility:** Centered placeholder when a container has no content.

**Inputs:** `systemImage: String`, `title: String`, `message: String`, `action: (label: String, handler: () -> Void)?`

**Composition:** VStack(spacing: Spacing.px12) with icon, title, body, optional Button. Centered with `.frame(maxWidth: .infinity, maxHeight: .infinity)`.

**Accessibility:** `accessibilityElement(children: .combine)`.

---

### PopoverContainer

**Responsibility:** Floating card with optional header, scrollable body, footer.

**Inputs:** `title: String?`, `width: CGFloat`, `@ViewBuilder body`, `@ViewBuilder footer`

**Composition:** VStack with optional header (title + close button), ScrollView body, optional footer. Material background.

**Accessibility:** `.accessibilityElement(children: .contain)`.

---

### ToolbarSurface

**Responsibility:** Full-width bar pinned to top or bottom of a container.

**Inputs:** `height: CGFloat = 52`, `@ViewBuilder content`

**Composition:** HStack with horizontal padding inside material background with fixed height.

**Accessibility:** `accessibilityElement(children: .contain)`.

---

### SectionHeader

**Responsibility:** Collapsible section label with optional count badge.

**Inputs:** `title: String`, `isExpanded: Binding<Bool>`, `count: Int?`

**Composition:** Button with HStack: title, Spacer, optional ActivityBadge, chevron that rotates. `.disclosureGroupStyle` compatible.

**Accessibility:** `.accessibilityLabel(title)`, `.accessibilityHint("Double tap to \(isExpanded ? "collapse" : "expand")")`.

---

## Layer 2: Browser Components

Built from Layer 1 primitives. Browser-specific. In `Features/`.

### TabRowView

**Responsibility:** Single tab in the sidebar. Shows favicon, title, close button, agent indicator, loading state.

**Built from:** SidebarItem + StatusIndicator + ActivityBadge + AgentIndicator (Layer 3)

**Inputs:** `tab: BrowserTab` (observed), `isSelected: Bool`, `onSelect: () -> Void`, `onClose: () -> Void`

**Composition:** SidebarItem with favicon Image as leading content, tab title as label, close button as trailing content. Loading state: StatusIndicator replacing favicon. Agent indicator: colored left border via overlay.

**Accessibility:** Role: AXTab. Label: tab title. Value: URL. Loading: "Loading" trait. Agent: "Agent active" in description.

---

### TabSidebarView

**Responsibility:** Vertical tab list. Pinned section + regular tabs. Drag reorder. New tab button.

**Built from:** List + SectionHeader + TabRowView + EmptyState

**Inputs:** `tabs: [BrowserTab]`, `selectedTabID: UUID?`, `onSelect`, `onClose`, `onReorder`, `onNewTab`

**Composition:** List with .sidebar style. PinnedTabsSection at top. Regular tabs in scrollable section. Footer: new tab button. Uses `.onMove` for drag reorder.

**Accessibility:** Role: AXTabGroup. Announces tab count.

---

### NavigationControls

**Responsibility:** Back/forward/reload grouped.

**Built from:** HStack of IconButton

**Inputs:** `canGoBack`, `canGoForward`, `isLoading`, `onBack`, `onForward`, `onReload`, `onStop`

**Composition:** HStack(spacing: Spacing.px4) with three IconButtons. Reload toggles to stop (X) when isLoading.

**Accessibility:** Each button labeled. Reload/stop announces current state.

---

### BrowserToolbar

**Responsibility:** Full toolbar bar containing navigation controls + address bar.

**Built from:** ToolbarSurface + NavigationControls + CommandField (or AppKit AddressBar)

**Inputs:** Tab navigation state, address bar callbacks.

---

### DownloadItemView

**Responsibility:** Single download row with progress, filename, open button.

**Built from:** SidebarItem + ProgressView

**Inputs:** DownloadRecord (observed)

**Accessibility:** Label: filename. Value: progress percentage. Action: "Open in Finder".

---

### HistoryRowView

**Responsibility:** History entry. Domain icon, title, URL, timestamp.

**Built from:** SidebarItem

**Inputs:** HistoryEntry

---

### BookmarkItemView

**Responsibility:** Bookmark entry. Favicon, title, folder badge.

**Built from:** SidebarItem

**Inputs:** Bookmark

---

## Layer 3: Agent-Aware Components

Built from Layer 1 + Layer 2. Agent-specific. In `Features/AgentActivity/`.

### AgentIndicator

**Responsibility:** Colored left border on tab row when agent is active.

**States:**
- Hidden: no agent activity
- Blue (pulsing): agent working
- Yellow (static): agent needs human input
- Green (flash, then fade): agent completed

**Composition:** Rectangle, 3px wide, left edge. Pulsing: opacity 0.5-1.0, 2s period. Reduce Motion: static color.

**Accessibility:** VoiceOver: "Agent active" / "Agent needs attention" / "Agent completed".

---

### AgentActivityPopover

**Responsibility:** Click-to-expand detail on agent-active tab.

**Content:** Agent name + color, current action description, step-by-step log with timestamps, Pause/Resume/End buttons, "View full history" link.

**Built from:** PopoverContainer + List + IconButton

**Inputs:** `[AgentAction]` for the tab, agent connection info

**Accessibility:** Group with action buttons individually labeled.

---

### ProvenanceBadge

**Responsibility:** Subtle icon distinguishing human vs agent-created tabs.

**Composition:** Small Image. Human: no badge (default). Agent: robot SF Symbol at `Opacity.secondary`. Restored: clock SF Symbol.

**Inputs:** `TabProvenance`

**Accessibility:** "Created by agent AFK" / "Created by you" / "Restored from previous session".

---

### ControlStatusView

**Responsibility:** Thin bar shown when agent is operating on the focused tab.

**Content:** Agent name, current action summary, "Take Control" / "Stop" button.

**Built from:** ToolbarSurface + text + IconButton

**Inputs:** `TabControlState`, `onTakeControl: () -> Void`

**Accessibility:** Live region. Announces state changes: "Agent AFK is active. Take Control button available."

---

## Directory Structure

```
Sources/AgentBrowser/
  DesignSystem/
    DesignTokens.swift
    GlassSurface.swift
    IconButton.swift
    SidebarItem.swift
    CommandField.swift
    StatusIndicator.swift
    ActivityBadge.swift
    EmptyState.swift
    PopoverContainer.swift
    ToolbarSurface.swift
    SectionHeader.swift
  BrowserCore/
    TabRecord.swift
    NavigationState.swift
    TabProvenance.swift
    TabLifecycle.swift
    WorkspaceRecord.swift
    DownloadRecord.swift
    AgentConnection.swift
    AgentAction.swift
    PageInspectable.swift
    Navigable.swift
  BrowserEngine/  (renamed from WebKit/)
    BrowserTab.swift
    PageController.swift
    ScriptBridge.swift
    NavigationCoordinator.swift
    UICoordinator.swift
    DownloadHandler.swift
    WebViewFactory.swift
  Persistence/
    DatabaseSetup.swift
    HistoryStore.swift
    BookmarkStore.swift
    SessionStore.swift
    AgentStore.swift
    Migrations/
  AgentIntegration/  (evolved from Automation/)
    AgentHTTPServer.swift
    AgentActivityStore.swift
    AgentRegistry.swift
    ToolRouter.swift
    ActionLog.swift
    TabControlState.swift
    TakeoverHandler.swift
  Features/
    Sidebar/
      TabSidebarView.swift
      TabRowView.swift
      SidebarHeaderView.swift
      PinnedTabsSection.swift
    Omnibox/
      AutocompleteDropdown.swift
    Toolbar/
      NavigationControls.swift
      BrowserToolbar.swift
    AgentActivity/
      AgentIndicator.swift
      AgentActivityPopover.swift
      ProvenanceBadge.swift
      ControlStatusView.swift
    Downloads/
      DownloadBar.swift
      DownloadItemView.swift
    Settings/
      SettingsView.swift
  Window/
    BrowserWindowController.swift
    WindowSession.swift
    AppStore.swift
  App/
    AppDelegate.swift
    main.swift
```
