# Agent Browser

A native macOS browser where every tab is a programmable object.

## What is this

A fast, native macOS browser built in Swift on WebKit. It works as a normal browser, but every live tab is addressable by external AI agents through a local API.

When you browse the web normally, any external process on your machine can:

- **List your open tabs** and their metadata
- **Read page content** from the actual live DOM (not a re-fetch -- authenticated pages, client-rendered SPAs, dynamic content)
- **Inspect interactive elements** semantically (buttons, links, inputs with accessible names, roles, and stable handles)
- **Click, fill, press keys, select options** on live page elements
- **Wait for conditions** (page load, URL change, element appearance, text content)
- **Open URLs** in new tabs
- **Execute JavaScript** in any tab
- **Capture screenshots** of any tab

All operations target the same WKWebView instances you are using. No headless browser. No Playwright. No Chromium.

## Quick Start

```bash
# Build and run
swift build && .build/debug/AgentBrowser
```

The browser opens a window and starts a local API server on `127.0.0.1:8833`.

Connection info is written to `~/.config/agent-browser/connection.json`:
```json
{
  "url": "http://127.0.0.1:8833",
  "token": "<random-bearer-token>",
  "pid": 12345
}
```

## CLI

```bash
# Check if browser is running
./browser-ctl health

# List all open tabs
./browser-ctl tabs

# Open a URL
./browser-ctl open https://github.com

# Read page content from a live tab
./browser-ctl read <tab-id>

# Execute JavaScript
./browser-ctl eval <tab-id> 'return document.title'

# Take a screenshot
./browser-ctl screenshot <tab-id> page.png

# --- Interactive Automation ---

# Inspect interactive elements (returns semantic handles)
./browser-ctl inspect <tab-id>

# Click an element by handle
./browser-ctl click <tab-id> el_a1b2c3

# Fill a text input
./browser-ctl fill <tab-id> el_a1b2c3 "search query"

# Press a key (Enter, Escape, Tab, etc.)
./browser-ctl press <tab-id> Enter el_a1b2c3

# Wait for page load, URL change, or element
./browser-ctl wait <tab-id> --load
./browser-ctl wait <tab-id> --url "github.com/search"
./browser-ctl wait <tab-id> --text "Results"
./browser-ctl wait <tab-id> --element "#results"
```

### Example Workflow

```bash
# Open GitHub, find search, type query, submit
ID=$(./browser-ctl open https://github.com | python3 -c "import json,sys; print(json.load(sys.stdin)['id'])")
./browser-ctl wait $ID --load
./browser-ctl inspect $ID
# Output: el_abc123  textbox  name="Search or jump to..."
./browser-ctl fill $ID el_abc123 "WKWebView Swift"
./browser-ctl press $ID Enter el_abc123
./browser-ctl wait $ID --url "search"
./browser-ctl read $ID
```

## HTTP API

All endpoints require `Authorization: Bearer <token>` (except `/health`).

| Method | Path | Description |
|--------|------|-------------|
| `GET` | `/health` | Health check (no auth) |
| `GET` | `/api/tabs` | List all tabs |
| `GET` | `/api/tabs/:id` | Get tab details |
| `POST` | `/api/tabs` | Open URL in new tab (`{"url": "..."}`) |
| `GET` | `/api/tabs/:id/read` | Read page content (live DOM text) |
| `POST` | `/api/tabs/:id/js` | Execute JavaScript (`{"script": "..."}`) |
| `GET` | `/api/tabs/:id/screenshot` | Capture viewport as PNG |
| `GET/POST` | `/api/tabs/:id/inspect` | Inspect interactive elements |
| `POST` | `/api/tabs/:id/click` | Click element (`{"elementId": "el_xxx"}`) |
| `POST` | `/api/tabs/:id/fill` | Fill input (`{"elementId": "el_xxx", "value": "..."}`) |
| `POST` | `/api/tabs/:id/press` | Press key (`{"key": "Enter", "elementId": "el_xxx"}`) |
| `POST` | `/api/tabs/:id/select` | Select option (`{"elementId": "el_xxx", "value": "..."}`) |
| `POST` | `/api/tabs/:id/wait` | Wait for condition (`{"condition": "url", "value": "..."}`) |

### Examples

```bash
TOKEN=$(python3 -c "import json; print(json.load(open('$HOME/.config/agent-browser/connection.json'))['token'])")

# List tabs
curl -s -H "Authorization: Bearer $TOKEN" http://127.0.0.1:8833/api/tabs

# Read a page
curl -s -H "Authorization: Bearer $TOKEN" http://127.0.0.1:8833/api/tabs/<id>/read

# Execute JS
curl -s -X POST -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"script": "return document.title"}' \
  http://127.0.0.1:8833/api/tabs/<id>/js
```

## Security

- Server binds to **127.0.0.1 only** -- no network exposure
- **Bearer token** authentication on every request (random 32-byte token)
- **Host header validation** prevents DNS rebinding attacks
- Token stored in `~/.config/agent-browser/connection.json` (mode 0600)

## Architecture

```
External Agent (Claude Code, AFK, curl, etc.)
    |
    | HTTP + Bearer token
    |
AgentHTTPServer (NWListener on 127.0.0.1:8833)
    |
    | @MainActor dispatch
    |
BrowserAutomationService
    |
    | operates on live tab state
    |
TabManager --> [BrowserTab] --> WKWebView
    ^                              |
    |                              | KVO
    +-- BrowserWindowController ---+
        (UI: address bar, tabs, navigation)
```

The automation service and the UI both operate on the same `TabManager` and `BrowserTab` instances. When an agent opens a tab, it appears in the browser window. When an agent reads a page, it reads from the same WKWebView the user is looking at.

## Status

- [x] Native macOS browser (AppKit + WKWebView)
- [x] Multi-tab support with keyboard shortcuts
- [x] **Agent HTTP API** (list, get, open, read, js, screenshot)
- [x] **Interactive automation** (inspect, click, fill, press, select, wait)
- [x] **Semantic element handles** (accessible names, roles, stable IDs)
- [x] **React/Vue/Angular compatible** form fill (native setter bypass)
- [x] **CLI tool** (`browser-ctl`) with full automation commands
- [x] Bearer token authentication
- [x] DNS rebinding defense
- [x] Connection descriptor for auto-discovery
- [x] Content extraction (markdown, text, HTML)
- [ ] Tab sidebar (vertical tabs)
- [ ] History / bookmarks / persistence
- [ ] MCP protocol support

## Requirements

- macOS 14+
- Swift 5.9+

## License

MIT
