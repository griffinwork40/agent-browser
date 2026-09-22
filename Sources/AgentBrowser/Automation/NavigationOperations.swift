import AppKit
import WebKit

// MARK: - Navigation Operations
//
// Browser-side implementations for the 7 Phase 2 tools:
//   tabs.close, tabs.switch, tabs.navigate,
//   page.back, page.forward, page.reload
//
// tabs.get (used by browser_read_metadata) already exists in TabOperations.swift.
//
// Extension of BrowserAutomationService extracted for the 350 LOC rule.

extension BrowserAutomationService {

    // MARK: - Data Types

    struct CloseResult: Codable, Sendable {
        let id: String
        let closed: Bool
    }

    struct NavigateResult: Codable, Sendable {
        let id: String
        let url: String
    }

    struct NavActionResult: Codable, Sendable {
        let id: String
        let action: String      // "back", "forward", or "reload"
    }

    // MARK: - tabs.close

    func closeTabResponse(id: String) -> AgentResponse {
        guard let tab = resolveTab(id) else {
            return .failure(code: ErrorCode.tabNotFound, message: "No tab with id: \(id)")
        }
        let tabID = tab.id
        let closed = tabManager.closeTab(tab)
        if closed {
            sessionExpiryWiredTabs.remove(tabID)
            AuthWallInterceptorState.shared.removeTab(tabID: tabID)
        }
        return .success(CloseResult(id: id, closed: closed))
    }

    // MARK: - tabs.switch

    func switchTabResponse(id: String) -> AgentResponse {
        guard let tab = resolveTab(id) else {
            return .failure(code: ErrorCode.tabNotFound, message: "No tab with id: \(id)")
        }
        tabManager.select(tab: tab)
        // Return the full TabDetail so callers can confirm the tab state.
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

    // MARK: - tabs.navigate

    func navigateResponse(id: String, urlString: String) -> AgentResponse {
        guard let tab = resolveTab(id) else {
            return .failure(code: ErrorCode.tabNotFound, message: "No tab with id: \(id)")
        }
        switch validateAndResolveURL(urlString) {
        case .failure(let detail):
            return .failure(code: detail.code, message: detail.message)
        case .success(let url):
            tab.load(url)
            return .success(NavigateResult(id: id, url: url.absoluteString))
        }
    }

    // MARK: - page.back

    func backResponse(id: String) -> AgentResponse {
        guard let tab = resolveTab(id) else {
            return .failure(code: ErrorCode.tabNotFound, message: "No tab with id: \(id)")
        }
        guard tab.canGoBack else {
            return .failure(code: ErrorCode.invalidState, message: "Tab has no previous page to go back to")
        }
        tab.goBack()
        return .success(NavActionResult(id: id, action: "back"))
    }

    // MARK: - page.forward

    func forwardResponse(id: String) -> AgentResponse {
        guard let tab = resolveTab(id) else {
            return .failure(code: ErrorCode.tabNotFound, message: "No tab with id: \(id)")
        }
        guard tab.canGoForward else {
            return .failure(code: ErrorCode.invalidState, message: "Tab has no next page to go forward to")
        }
        tab.goForward()
        return .success(NavActionResult(id: id, action: "forward"))
    }

    // MARK: - page.reload

    func reloadResponse(id: String) -> AgentResponse {
        guard let tab = resolveTab(id) else {
            return .failure(code: ErrorCode.tabNotFound, message: "No tab with id: \(id)")
        }
        tab.reload()
        return .success(NavActionResult(id: id, action: "reload"))
    }
}
