import AppKit
import WebKit

// MARK: - Tab Operations
//
// Tab listing, get, and open operations.
// Extension of BrowserAutomationService extracted for the 350 LOC rule.

extension BrowserAutomationService {

    // MARK: - Data Types

    struct TabInfo: Codable, Sendable {
        let id: String
        let title: String
        let url: String?
        let isLoading: Bool
        let isActive: Bool
    }

    struct TabDetail: Codable, Sendable {
        let id: String
        let title: String
        let url: String?
        let isLoading: Bool
        let isActive: Bool
        let canGoBack: Bool
        let canGoForward: Bool
        let isSecure: Bool
    }

    struct OpenResult: Codable, Sendable {
        let id: String
        let url: String
    }

    // MARK: - Tab Listing

    func listTabs() -> [TabInfo] {
        let activeID = tabManager.activeTab?.id
        return tabManager.tabs.map { tab in
            TabInfo(
                id: tab.id.uuidString,
                title: tab.title,
                url: tab.url?.absoluteString,
                isLoading: tab.isLoading,
                isActive: tab.id == activeID
            )
        }
    }

    // MARK: - Get Tab

    func getTabResponse(id: String) -> AgentResponse {
        guard let tab = resolveTab(id) else {
            return .failure(code: ErrorCode.tabNotFound, message: "No tab with id: \(id)")
        }
        let activeID = tabManager.activeTab?.id
        return .success(TabDetail(
            id: tab.id.uuidString,
            title: tab.title,
            url: tab.url?.absoluteString,
            isLoading: tab.isLoading,
            isActive: tab.id == activeID,
            canGoBack: tab.canGoBack,
            canGoForward: tab.canGoForward,
            isSecure: tab.isSecure
        ))
    }

    // MARK: - Open URL

    func openURLResponse(_ urlString: String) -> AgentResponse {
        var resolved = urlString
        if URL(string: resolved)?.scheme == nil {
            if resolved.contains(".") && !resolved.contains(" ") {
                resolved = "https://\(resolved)"
            } else {
                return .failure(code: ErrorCode.invalidURL, message: "Cannot parse URL: \(urlString)")
            }
        }
        guard let url = URL(string: resolved) else {
            return .failure(code: ErrorCode.invalidURL, message: "Cannot parse URL: \(urlString)")
        }
        // Reject non-http(s) schemes (e.g. file://, javascript:) to prevent
        // the agent API from being used as a local-file or JS-injection vector.
        guard ["http", "https"].contains(url.scheme?.lowercased()) else {
            return .failure(code: ErrorCode.invalidURL, message: "Unsupported URL scheme: \(url.scheme ?? "none")")
        }
        let tab = tabManager.createTab(url: url)
        tabManager.select(tab: tab)
        return .success(OpenResult(id: tab.id.uuidString, url: url.absoluteString))
    }
}
