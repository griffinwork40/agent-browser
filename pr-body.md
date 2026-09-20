## Task/workspace tab grouping in sidebar

Auto-groups agent-created tabs by `sessionTag` from `TabProvenance`, with collapsible cluster headers in the sidebar. Human tabs remain ungrouped. Restored tabs with an `originalSessionTag` are grouped; those without are ungrouped.

Relates to #6.

---

### What was added

**`TabGrouping.swift`** (~100 LOC)
- `TabGroup` struct — `id: String` (sessionTag), `agentID`, `tabs`, `isCollapsed`, `displayTitle` (truncated at 20 chars)
- `TabGroupOrTab` — `@MainActor` enum: `.group(TabGroup)` or `.ungrouped(BrowserTab)`, with stable `id: String`
- `groupTabs(_ tabs: [BrowserTab]) -> [TabGroupOrTab]` — preserves original insertion order; groups are emitted at the position of their first tab, remaining members merged in as they appear

**`TabGroupHeaderView.swift`** (~80 LOC)
- Collapsible row: agent color dot (stable djb2 hash over palette) · sessionTag label · tab count badge · animated chevron
- Uses design tokens: `Spacing.px4/px8`, `Typography.caption/label`, `Radius.small/pill`, `Motion.micro`

**`TabSidebarView.swift`** (modified)
- Calls `groupTabs()` to organize the tab list
- Renders `TabGroupHeaderView` before each group's rows
- `@State private var collapsedGroups: Set<String>` tracks per-group collapse state
- Grouped `TabRowView` rows are indented `Spacing.px12` to nest under the header

**`TabGroupingTests.swift`** (17 tests)
- Empty input → empty output
- Single and multiple human tabs → all ungrouped
- Same-tag agent tabs → one group; different tags → separate groups
- `agentID` sourced from first tab in group
- Human tabs before/after group preserve relative order
- Interleaved human tabs and multiple groups with scattered repeated tags
- Restored-with-tag → grouped; restored-without-tag → ungrouped
- `displayTitle` short/long truncation
- `TabGroupOrTab.id` prefixes (`group:`, `tab:`)

### Verification

```
swift build   → Build complete! (0 errors)
swift test    → Test run with 197 tests in 16 suites passed
```

All 17 new `TabGrouping` tests pass alongside the full existing suite (180 tests).

### Notes

- `TabGroupOrTab` is `@MainActor` so its `id` property can safely access `BrowserTab.id` (MainActor-isolated); `ForEach` in `TabSidebarView` uses the `id: \.id` form
- No file exceeds 350 LOC
