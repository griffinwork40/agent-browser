# Agent Browser

A native macOS browser designed for humans working alongside AI agents.

## What is this

A fast, native macOS browser built in Swift on WebKit. It is an excellent normal browser that becomes unusually powerful when paired with AI coding agents.

The core idea: the browser itself is agent-addressable. Every tab is a programmable object. External agents can inspect, navigate, and interact with pages through a local API. The user browses normally. The agent reads and acts on the same authenticated sessions the user already has open.

This is **not** a browser with an AI chatbot sidebar. The browser *itself* is the programmable surface.

## Status

**Phase 1: one-tab browser** (in progress)

- [x] Technical spike (validated WKWebView assumptions)
- [x] AppKit window with WKWebView
- [x] Address bar with URL/search
- [x] Back / forward / reload / stop
- [x] Page title in window title
- [x] Loading progress bar
- [x] Basic keyboard shortcuts (Cmd+L, Cmd+R, Cmd+[, Cmd+], Cmd+T, Cmd+W)
- [x] Multiple tabs (Cmd+T, Cmd+W, Cmd+1-9, Ctrl+Tab)
- [x] Reopen closed tab (Cmd+Shift+T)
- [x] JavaScript alerts/confirms/prompts
- [x] File uploads
- [x] Downloads (to ~/Downloads)
- [x] Popup handling
- [x] Find in page (Cmd+F)
- [x] Zoom (Cmd+/-, Cmd+0)
- [ ] Tab sidebar (Phase 2)
- [ ] History / bookmarks (Phase 3)
- [ ] Session restore (Phase 3)
- [ ] Agent API (Phase 6)

## Build

Requires macOS 14+ and Swift 5.9+.

```bash
swift build
```

## Run

```bash
swift run AgentBrowser
```

Or build and run the binary directly:

```bash
swift build && .build/debug/AgentBrowser
```

## Architecture

See [BROWSER_SCOPE.md](BROWSER_SCOPE.md) for the full scope document, including:

- Technical feasibility assessment
- Architecture design
- Tab lifecycle model
- Automation design
- Security model
- Persistence strategy
- V1 scope and non-goals
- 7-phase implementation roadmap

## Core stack

| Layer | Technology |
|---|---|
| Language | Swift 5.9+ |
| UI | AppKit (windows, layout, WKWebView) + SwiftUI (sidebar, overlays) |
| Web engine | WKWebView (system WebKit) |
| Minimum macOS | 14 (Sonoma) |
| Agent API (planned) | HTTP on 127.0.0.1 (MCP-compatible) |
| Persistence (planned) | GRDB.swift + SQLite FTS5 |

## Product thesis

Existing browsers treat their state as private. If a coding agent needs to read a web page, it launches a headless Chromium instance, navigates with no auth, extracts, and tears down. Every page read is a fresh anonymous session.

This browser makes its state programmable. The agent calls `browser_read_markdown` on the tab the user already has open. The page is already loaded, already authenticated, already at the right scroll position. The round-trip is <100ms.

When reading a web page costs <100ms instead of 5 seconds, agents will do it more often. That makes them better at tasks that involve the web.

## License

MIT
