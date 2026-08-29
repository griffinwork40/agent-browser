// BrowserSpike.swift
// Technical spike validating five WKWebView assumptions for a native macOS browser.
//
// ASSUMPTIONS TESTED:
//  1. WKWebView can be hosted in a plain NSWindow with AppKit (no SwiftUI needed)
//  2. JS injection via WKContentWorld.defaultClient runs isolated from page scripts
//  3. takeSnapshot(with:completionHandler:) produces a usable viewport image
//  4. Programmatic element.click() via JS triggers real WKNavigationDelegate callbacks
//  5. JS can enumerate interactive elements with bounding rects across real pages
//
// NOTE: All WK APIs use callback forms, NOT async/await.
// The async overloads on void-returning methods crash at runtime (unfixed Swift bug).

import AppKit
import WebKit

// ─── Step tracking ────────────────────────────────────────────────────────────

var results: [(String, Bool, String)] = [] // (step, success, detail)

func record(_ step: String, success: Bool, detail: String) {
    results.append((step, success, detail))
    let icon = success ? "✅" : "❌"
    print("\(icon) [\(step)] \(detail)")
}

// ─── App bootstrap ────────────────────────────────────────────────────────────

// ASSUMPTION 1 PROBE: Can we create an NSApplication + NSWindow without SwiftUI?
class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var webView: WKWebView!
    var navDelegate: NavigationDelegate!

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Build a plain NSWindow
        window = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 1280, height: 900),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Browser Spike"
        window.makeKeyAndOrderFront(nil)

        // Build WKWebView with default config
        let config = WKWebViewConfiguration()
        webView = WKWebView(frame: window.contentView!.bounds, configuration: config)
        webView.autoresizingMask = [.width, .height]
        window.contentView!.addSubview(webView)

        record("1-appkit-window", success: true, detail: "NSWindow + WKWebView created without SwiftUI")

        // Wire navigation delegate
        navDelegate = NavigationDelegate(webView: webView)
        webView.navigationDelegate = navDelegate

        // Kick off the load
        let url = URL(string: "https://news.ycombinator.com")!
        webView.load(URLRequest(url: url))
        print("⏳ Loading \(url) …")
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ app: NSApplication) -> Bool { true }
}

// ─── Navigation delegate — all spike steps fire from here ────────────────────

class NavigationDelegate: NSObject, WKNavigationDelegate {
    let webView: WKWebView
    var clickNavigation: WKNavigation?
    var isSecondLoad = false

    init(webView: WKWebView) { self.webView = webView }

    // Called when a page finishes loading
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if isSecondLoad {
            // STEP 4b: Read the new page title after click-triggered navigation
            runStep4b()
        } else {
            // First load — run steps 2, 3, 4a in sequence
            print("\n--- Page loaded: \(webView.url?.absoluteString ?? "?") ---\n")
            runStep2_extractElements {
                self.runStep3_screenshot {
                    self.runStep4a_click()
                }
            }
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        record("navigation", success: false, detail: "Navigation failed: \(error.localizedDescription)")
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation nav: WKNavigation!, withError error: Error) {
        // NSURLErrorCancelled (-999) fires legitimately when JS click triggers navigation mid-page;
        // treat it as non-fatal, the real didFinish arrives separately.
        let nsErr = error as NSError
        if nsErr.code == NSURLErrorCancelled { return }
        record("navigation-provisional", success: false, detail: "Provisional nav failed: \(error.localizedDescription)")
    }

    // ── STEP 2: Extract interactive elements via JS in isolated world ──────────
    // ASSUMPTION 2 PROBE: WKContentWorld.defaultClient keeps injected JS isolated
    // from page scripts (page cannot snoop or overwrite our variables).
    func runStep2_extractElements(then next: @escaping () -> Void) {
        // Prove isolation: define a sentinel var; the page script won't see it.
        let js = """
        (function() {
            var __spikeIsolated = 'yes';  // only visible in this world
            var els = document.querySelectorAll('a[href], button');
            var out = [];
            for (var i = 0; i < Math.min(els.length, 20); i++) {
                var el = els[i];
                var r = el.getBoundingClientRect();
                out.push({
                    tag: el.tagName,
                    text: (el.innerText || el.textContent || '').trim().slice(0, 80),
                    href: el.href || '',
                    x: Math.round(r.x), y: Math.round(r.y),
                    w: Math.round(r.width), h: Math.round(r.height)
                });
            }
            return JSON.stringify({ isolated: __spikeIsolated, count: els.length, sample: out });
        })();
        """
        // CRITICAL: use callback form, NOT async/await (async void overload crashes)
        webView.evaluateJavaScript(js, in: nil, in: .defaultClient) { result in
            switch result {
            case .success(let value):
                let str = value as? String ?? "(non-string)"
                // Parse the JSON to surface a few highlights
                if let data = str.data(using: .utf8),
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    let count = json["count"] as? Int ?? 0
                    let isolated = json["isolated"] as? String ?? "?"
                    if let sample = json["sample"] as? [[String: Any]], let first = sample.first {
                        let text = first["text"] as? String ?? ""
                        let x = first["x"] as? Int ?? 0
                        let y = first["y"] as? Int ?? 0
                        let w = first["w"] as? Int ?? 0
                        let h = first["h"] as? Int ?? 0
                        record("2-js-extraction", success: true,
                               detail: "Found \(count) interactive els. Isolated=\(isolated). First: '\(text)' at (\(x),\(y)) \(w)×\(h)")
                    } else {
                        record("2-js-extraction", success: true, detail: "Found \(count) elements (no sample). Isolated=\(isolated)")
                    }
                } else {
                    record("2-js-extraction", success: true, detail: "JS ran but JSON parse failed: \(str.prefix(200))")
                }
            case .failure(let err):
                record("2-js-extraction", success: false, detail: "JS error: \(err)")
            }
            next()
        }
    }

    // ── STEP 3: Viewport screenshot via takeSnapshot ───────────────────────────
    // ASSUMPTION 3 PROBE: takeSnapshot returns a real NSImage we can save/inspect.
    func runStep3_screenshot(then next: @escaping () -> Void) {
        let config = WKSnapshotConfiguration()
        config.afterScreenUpdates = true

        // takeSnapshot uses old-style completion handler — no async/await issue here
        webView.takeSnapshot(with: config) { image, error in
            if let err = error {
                record("3-snapshot", success: false, detail: "takeSnapshot failed: \(err)")
                next()
                return
            }
            guard let img = image else {
                record("3-snapshot", success: false, detail: "takeSnapshot returned nil image")
                next()
                return
            }
            // Save to disk for inspection
            let path = "/tmp/spike_screenshot.png"
            if let tiff = img.tiffRepresentation,
               let bmp = NSBitmapImageRep(data: tiff),
               let png = bmp.representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: path))
                record("3-snapshot", success: true,
                       detail: "Snapshot \(Int(img.size.width))×\(Int(img.size.height))px saved to \(path)")
            } else {
                record("3-snapshot", success: true,
                       detail: "Snapshot obtained (\(Int(img.size.width))×\(Int(img.size.height))) but PNG conversion failed")
            }
            next()
        }
    }

    // ── STEP 4a: Get page text + click first link ──────────────────────────────
    // ASSUMPTION 4 PROBE: element.click() in JS triggers a real navigation that
    // WKNavigationDelegate receives — i.e. it's not swallowed silently.
    // ASSUMPTION 5 PROBE (bonus): document.title and body.innerText are readable.
    func runStep4a_click() {
        // First read title + body text
        let readJS = """
        JSON.stringify({
            title: document.title,
            bodyText: (document.body ? document.body.innerText : '').slice(0, 500)
        });
        """
        webView.evaluateJavaScript(readJS, in: nil, in: .defaultClient) { result in
            switch result {
            case .success(let value):
                if let str = value as? String,
                   let data = str.data(using: .utf8),
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    let title = json["title"] as? String ?? ""
                    let body  = (json["bodyText"] as? String ?? "").prefix(120)
                    record("4a-page-content", success: true, detail: "title='\(title)' body='\(body)…'")
                } else {
                    record("4a-page-content", success: false, detail: "Could not parse title/body JSON")
                }
            case .failure(let err):
                record("4a-page-content", success: false, detail: "title/body JS error: \(err)")
            }

            // Now click the first link
            // We find the first <a href> that has an HTTP URL (skip anchors/javascript: links)
            let clickJS = """
            (function() {
                var links = document.querySelectorAll('a[href^="http"]');
                if (links.length === 0) { return JSON.stringify({clicked: false, reason: 'no http links found'}); }
                var el = links[0];
                var href = el.href;
                var text = (el.innerText || el.textContent || '').trim().slice(0, 80);
                el.click();
                return JSON.stringify({clicked: true, href: href, text: text});
            })();
            """
            // Again: callback form only
            self.webView.evaluateJavaScript(clickJS, in: nil, in: .defaultClient) { result2 in
                switch result2 {
                case .success(let value):
                    if let str = value as? String,
                       let data = str.data(using: .utf8),
                       let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                        let clicked = json["clicked"] as? Bool ?? false
                        let href = json["href"] as? String ?? ""
                        let text = json["text"] as? String ?? ""
                        if clicked {
                            record("4b-click-trigger", success: true,
                                   detail: "Clicked '\(text)' -> \(href). Waiting for navigation…")
                            // Mark that next didFinish is the post-click load
                            self.isSecondLoad = true
                        } else {
                            let reason = json["reason"] as? String ?? "?"
                            record("4b-click-trigger", success: false, detail: "Click not fired: \(reason)")
                            self.printSummary()
                        }
                    } else {
                        record("4b-click-trigger", success: false, detail: "click JS returned unexpected value")
                        self.printSummary()
                    }
                case .failure(let err):
                    record("4b-click-trigger", success: false, detail: "click JS error: \(err)")
                    self.printSummary()
                }
            }
        }
    }

    // ── STEP 4c: Read new title after click-triggered navigation ──────────────
    func runStep4b() {
        let url = webView.url?.absoluteString ?? "?"
        let titleJS = "document.title;"
        webView.evaluateJavaScript(titleJS, in: nil, in: .defaultClient) { result in
            switch result {
            case .success(let value):
                let title = value as? String ?? "(none)"
                record("4c-post-click-title", success: true,
                       detail: "Navigation landed at \(url) — title='\(title)'")
            case .failure(let err):
                record("4c-post-click-title", success: false, detail: "title JS failed: \(err)")
            }
            self.printSummary()
        }
    }

    // ── Final summary ──────────────────────────────────────────────────────────
    func printSummary() {
        print("\n" + String(repeating: "═", count: 70))
        print("SPIKE SUMMARY")
        print(String(repeating: "═", count: 70))
        let passed = results.filter { $0.1 }.count
        let failed = results.filter { !$0.1 }.count
        for (step, ok, detail) in results {
            print("  \(ok ? "✅" : "❌") \(step): \(detail.prefix(100))")
        }
        print("")
        print("Passed: \(passed) / \(passed + failed)")
        print(String(repeating: "═", count: 70))
        print("")
        print("ASSUMPTIONS VALIDATED:")
        print("  1. AppKit NSWindow + WKWebView: \(results.first(where: {$0.0 == "1-appkit-window"})?.1 == true ? "YES" : "NO")")
        print("  2. JS isolation (WKContentWorld.defaultClient): \(results.first(where: {$0.0 == "2-js-extraction"})?.1 == true ? "YES" : "NO")")
        print("  3. takeSnapshot for screenshots: \(results.first(where: {$0.0 == "3-snapshot"})?.1 == true ? "YES" : "NO")")
        print("  4. element.click() triggers navigation delegate: \(results.first(where: {$0.0 == "4c-post-click-title"})?.1 == true ? "YES" : "NO")")
        print("  5. JS can read page content (title/body): \(results.first(where: {$0.0 == "4a-page-content"})?.1 == true ? "YES" : "NO")")
        print("")

        // Exit after a brief delay (give the window a moment to render)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            NSApplication.shared.terminate(nil)
        }
    }
}

// ─── Entry point ──────────────────────────────────────────────────────────────

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
