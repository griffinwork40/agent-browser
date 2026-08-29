import Foundation

// agent-browser-mcp: MCP server adapter for Agent Browser.
//
// Architecture:
//   MCP client (Claude Code, etc.)
//     -> stdio JSON-RPC
//       -> this process
//         -> HTTP to running Agent Browser
//           -> BrowserAutomationService
//             -> live WKWebView tabs
//
// This process owns NO browser. It is a thin protocol adapter.

let server = MCPServer()
server.run()
// run() blocks on stdin until EOF, then exits.
