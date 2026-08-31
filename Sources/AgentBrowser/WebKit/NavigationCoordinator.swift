import WebKit

/// Handles WKNavigationDelegate callbacks.
/// Wired to a BrowserTab's WKWebView. Must be retained by the tab.
final class NavigationCoordinator: NSObject, WKNavigationDelegate {

    /// Called when a committed URL is available (safe for address bar display).
    var onCommittedURL: ((URL?) -> Void)?

    /// Called on navigation finish.
    var onDidFinish: (() -> Void)?

    /// Injected by PersistenceCoordinator / BrowserWindowController after async init.
    /// Receives a history record on every successfully completed navigation.
    var historyStore: HistoryStore?

    // MARK: - WKNavigationDelegate

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        // Handle target=_blank / window.open by opening in same tab
        // (Phase 2 will open in a new tab instead)
        if navigationAction.targetFrame == nil {
            if let url = navigationAction.request.url {
                webView.load(URLRequest(url: url))
            }
            decisionHandler(.cancel)
            return
        }

        decisionHandler(.allow)
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationResponse: WKNavigationResponse,
        decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void
    ) {
        // If the response cannot be shown, try to download
        if !navigationResponse.canShowMIMEType {
            decisionHandler(.download)
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        // didCommit is the safe point for URL bar updates (not webView.url which updates eagerly)
        onCommittedURL?(webView.url)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        onDidFinish?()

        // Record the completed navigation in browsing history.
        if let url = webView.url, !url.isFileURL {
            let title = webView.title ?? url.host ?? url.absoluteString
            if let store = historyStore {
                Task {
                    await store.addEntry(url: url, title: title)
                }
            }
        }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        // NSURLErrorCancelled (-999) fires routinely when JS triggers a new navigation.
        // Silently ignore it.
        let nsError = error as NSError
        if nsError.code == NSURLErrorCancelled { return }

        print("[NavigationCoordinator] Provisional navigation failed: \(error.localizedDescription)")
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        let nsError = error as NSError
        if nsError.code == NSURLErrorCancelled { return }

        print("[NavigationCoordinator] Navigation failed: \(error.localizedDescription)")
    }

    func webView(
        _ webView: WKWebView,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        // Allow loopback hosts for local dev servers (e.g. self-signed certs).
        // All other hosts use the system's default certificate validation.
        let host = challenge.protectionSpace.host
        if (host == "localhost" || host == "127.0.0.1"),
           let trust = challenge.protectionSpace.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }

    // MARK: - Downloads (basic)

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        download.delegate = DownloadHandler.shared
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        download.delegate = DownloadHandler.shared
    }
}
