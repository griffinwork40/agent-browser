# Agent Browser MCP

MCP (Model Context Protocol) adapter for Agent Browser. Lets MCP-compatible AI agents (Claude Code, etc.) control the human's real browser session.

## Architecture

```
MCP client (Claude Code, Codex, etc.)
  -> stdio (JSON-RPC 2.0)
    -> agent-browser-mcp (thin adapter)
      -> authenticated HTTP API
        -> running Agent Browser
          -> live WKWebView tabs (visible in the GUI)
```

The MCP adapter owns no browser. Every operation targets the exact same tabs the human sees. There is no headless browser, no Playwright, no Chromium.

## Setup

### 1. Build

```bash
cd agent-browser
swift build
```

This produces two executables:
- `.build/debug/AgentBrowser` - the browser GUI
- `.build/debug/agent-browser-mcp` - the MCP adapter

### 2. Start Agent Browser

```bash
.build/debug/AgentBrowser
```

The browser writes connection info to `~/.config/agent-browser/connection.json`. The MCP adapter reads this file automatically.

### 3. Configure MCP client

#### Claude Code

Add to `.mcp.json` at your project root:

```json
{
  "mcpServers": {
    "agent-browser": {
      "command": "/absolute/path/to/agent-browser/.build/debug/agent-browser-mcp"
    }
  }
}
```

Or add to `~/.claude.json` for global access:

```json
{
  "mcpServers": {
    "agent-browser": {
      "command": "/absolute/path/to/agent-browser/.build/debug/agent-browser-mcp"
    }
  }
}
```

#### Generic stdio MCP client

Spawn `agent-browser-mcp` as a subprocess. Communicate via stdin/stdout using JSON-RPC 2.0 (one JSON message per line).

## Available Tools

| Tool | Description |
|---|---|
| `browser_tabs` | List all open tabs with IDs, titles, URLs, loading state |
| `browser_open` | Open a URL in a new visible tab |
| `browser_read` | Read live page content (markdown, text, or HTML) |
| `browser_inspect` | Inspect interactive elements with semantic handles |
| `browser_click` | Click an element by handle |
| `browser_fill` | Fill a text input (React/Vue/Angular compatible) |
| `browser_press` | Press a keyboard key (Enter, Escape, Tab, etc.) |
| `browser_select` | Select a dropdown option |
| `browser_wait` | Wait for load, URL change, text, or element |
| `browser_eval` | Execute JavaScript (privileged) |
| `browser_screenshot` | Capture tab as PNG image |

## Element Handle Lifecycle

1. Call `browser_inspect` to get element handles (e.g., `el_a1b2c3`)
2. Use handles with `browser_click`, `browser_fill`, `browser_press`, `browser_select`
3. After navigation or DOM changes, handles may become stale
4. Stale handles return `ELEMENT_NOT_FOUND` -- never silently misresolve
5. Re-inspect to get fresh handles after page changes

## Example Workflow

```
browser_tabs()
-> [{id: "ABC-123", title: "New Tab"}]

browser_open({url: "https://github.com/search"})
-> {id: "DEF-456", url: "https://github.com/search"}

browser_wait({tab_id: "DEF-456", condition: "load"})
-> {ok: true, elapsed: 0.5}

browser_inspect({tab_id: "DEF-456"})
-> el_abc123  input  "Search GitHub"  type=text

browser_fill({tab_id: "DEF-456", element_id: "el_abc123", value: "swift webkit"})
-> {ok: true, action: "fill"}

browser_press({tab_id: "DEF-456", key: "Enter", element_id: "el_abc123"})
-> {ok: true, action: "press"}

browser_wait({tab_id: "DEF-456", condition: "url", value: "search"})
-> {ok: true, elapsed: 1.2}

browser_read({tab_id: "DEF-456"})
-> (markdown content of search results)

browser_screenshot({tab_id: "DEF-456"})
-> (PNG image of the search results page)
```

## Error Handling

Tool errors use `isError: true` in the MCP result (passed to the LLM for correction):

| Error | Cause |
|---|---|
| `TAB_NOT_FOUND` | Invalid tab ID |
| `ELEMENT_NOT_FOUND` | Invalid or stale element handle |
| `ELEMENT_NOT_INTERACTABLE` | Element is hidden or disabled |
| `WAIT_TIMEOUT` | Wait condition not met within timeout |
| `JAVASCRIPT_ERROR` | JS execution failed |
| `INVALID_PARAMS` | Missing required parameters |
| Browser not running | No `connection.json` or stale PID |

## Security

The trust chain:

```
MCP client (trusted by the user)
  -> agent-browser-mcp (local process)
    -> Bearer token auth (from connection.json, chmod 0600)
      -> Agent Browser (loopback only, DNS rebinding defense)
        -> live browser session
```

**This is extremely privileged.** A connected MCP client can:
- Read authenticated web pages
- Click buttons and submit forms
- Fill inputs with arbitrary text
- Execute JavaScript in any tab
- Interact with banking, email, social media

The security boundary is the MCP client itself. Only connect trusted agents.

`browser_eval` is the most privileged tool. It can execute arbitrary JavaScript in the context of any authenticated page.

## Known Limitations

- Top-level DOM only (no iframe/shadow DOM traversal)
- Element handles don't survive full page navigation
- No network interception
- No file download management through MCP
- Screenshot returns base64 PNG (can be large for high-res displays)
- Single browser instance (the running Agent Browser)
- Browser must be running before the MCP adapter starts
