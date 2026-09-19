import Foundation

/// Tool definitions for the 7 navigation and tab-management tools added in Phase 2.
/// Kept in a separate file to stay under the 350 LOC limit per file.
///
/// Dispatch cases for these tools live in MCPTools.swift `call(name:arguments:)`.
/// Browser-side implementations live in NavigationOperations.swift (BrowserAutomationService extension).
extension MCPTools {

    /// Tool definitions for tab management and navigation tools.
    /// Called from `definitions()` and concatenated with the base definitions.
    func navigationDefinitions() -> [[String: Any]] {
        [
            // MARK: - Tab Management

            tool("browser_close_tab",
                 desc: "Close a tab by ID. The tab is removed from the browser and cannot be recovered via the API.",
                 props: ["tab_id": prop("string", "Tab ID from browser_tabs")],
                 required: ["tab_id"]),

            tool("browser_switch_tab",
                 desc: "Switch to (select) an existing tab by ID, making it the active/visible tab.",
                 props: ["tab_id": prop("string", "Tab ID from browser_tabs")],
                 required: ["tab_id"]),

            // MARK: - Navigation

            tool("browser_navigate",
                 desc: "Navigate an existing tab to a new URL. The navigation is visible in the GUI. Only http and https URLs are allowed.",
                 props: [
                    "tab_id": prop("string", "Tab ID from browser_tabs"),
                    "url": prop("string", "URL to navigate to (http/https only)")
                 ],
                 required: ["tab_id", "url"]),

            tool("browser_back",
                 desc: "Go back in the browser history for a tab. Returns an error if there is no previous page.",
                 props: ["tab_id": prop("string", "Tab ID from browser_tabs")],
                 required: ["tab_id"]),

            tool("browser_forward",
                 desc: "Go forward in the browser history for a tab. Returns an error if there is no next page.",
                 props: ["tab_id": prop("string", "Tab ID from browser_tabs")],
                 required: ["tab_id"]),

            tool("browser_reload",
                 desc: "Reload the current page in a tab. Equivalent to pressing Cmd+R in the browser.",
                 props: ["tab_id": prop("string", "Tab ID from browser_tabs")],
                 required: ["tab_id"]),

            // MARK: - Page Metadata

            tool("browser_read_metadata",
                 desc: "Read page metadata for a tab: title, URL, security (isSecure), navigation state (canGoBack, canGoForward), and loading state. Does not extract page content -- use browser_read for that.",
                 props: ["tab_id": prop("string", "Tab ID from browser_tabs")],
                 required: ["tab_id"]),
        ]
    }
}
