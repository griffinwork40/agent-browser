# Multi-Account Profiles

## Problem

User has ~10 Google accounts and needs fast sign-in and switching.

## Core Mechanism

`WKWebsiteDataStore(forIdentifier: UUID)` (macOS 14+). Each UUID gets a fully
isolated cookie jar, localStorage, IndexedDB, cache, and service workers.
Safari 17 Profiles uses this same API. No hard limit on store count.

**One profile = one UUID = one data store = one Google account.**

## Google-Specific Constraints

1. **`disallowed_useragent`** -- Google returns 403 on default WKWebView UA.
   Fix: set `customUserAgent` to include `Version/X.X Safari/605.1.15`.
   Already done in `BrowserTab.swift` line 62.

2. **ITP cookie purge** -- WebKit may purge `accounts.google.com` cookies
   after 30 days of inactivity in a profile. Low priority for V1.

3. **ASWebAuthenticationSession** -- not needed. User signs in via WKWebView
   directly. Cookies land in the profile's data store automatically.

## Architecture

### New Files

| File | Layer | Purpose |
|------|-------|---------|
| `BrowserCore/ProfileRecord.swift` | Domain | Pure value type: id, name, color, email |
| `WebKit/ProfileManager.swift` | WebKit | Profile CRUD, active profile, config factory |
| `Features/Profiles/ProfilePickerView.swift` | UI | Sidebar footer profile list + add |
| `Features/Profiles/ProfileRowView.swift` | UI | Single profile row in picker |

### Modified Files

| File | Change |
|------|--------|
| `BrowserCore/TabRecord.swift` | Add `profileID: UUID` field |
| `WebKit/BrowserTab.swift` | Config factory takes profile UUID, sets `WKWebsiteDataStore(forIdentifier:)` |
| `WebKit/TabManager.swift` | `createTab()` gains `profileID`, popup inherits parent profile |
| `Persistence/SessionStore.swift` | `TabSnapshot` gains `profileID` |
| `Persistence/PersistenceManager.swift` | Per-profile subdirectories |
| `App/AppDelegate.swift` | Init `ProfileManager`, inject into `TabManager` and window |
| `Window/BrowserWindowController.swift` | Wire profile picker into sidebar |
| `Features/Sidebar/TabSidebarView.swift` | Profile footer section |
| `Features/Sidebar/TabRowView.swift` | Profile color ring on favicon |

## UX

| Pattern | Shortcut | Notes |
|---------|----------|-------|
| Profile list in sidebar footer | Click | Color avatar + name |
| Direct switch | Cmd+Shift+1-9, Cmd+Shift+0 | One keystroke per profile |
| Cycle | Cmd+Shift+] / [ | Next/prev profile (existing Cmd+1-9 = tabs) |
| New profile | Via picker | Creates UUID, opens sign-in tab |

Profile color ring on each tab's favicon shows which account context it belongs to.
Active profile shown in sidebar footer with colored badge.

## Implementation Phases

### Phase 1: Foundation (serial)
- `ProfileRecord` domain type
- `ProfileManager` with config factory
- Wire into `BrowserTab`, `TabManager`, `AppDelegate`

### Phase 2: UI (parallel)
- Lane A: `ProfilePickerView` + `ProfileRowView` + sidebar footer
- Lane B: Keyboard shortcuts for profile switching
- Lane C: Tab color rings + session restore with profileID
