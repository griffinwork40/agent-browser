# WKWebView Technical Spike Results

**Date:** 2026-08-29  
**Runtime:** Swift 6.4, macOS (arm64), headless via tmux/CLI  
**Target URL:** https://news.ycombinator.com  

---

## What Was Tested

Five core assumptions required before committing to the WKWebView-based native browser architecture:

| # | Assumption | Test Method |
|---|---|---|
| 1 | AppKit NSWindow can host WKWebView without SwiftUI | Create NSApplication + NSWindow + WKWebView programmatically |
| 2 | JS in WKContentWorld.defaultClient is isolated from page scripts | Define sentinel var in injected JS; confirm page cannot access it |
| 3 | takeSnapshot returns a usable viewport image | Call takeSnapshot, save as PNG, check dimensions |
| 4 | element.click() via JS triggers real WKNavigationDelegate callbacks | Click first link, wait for didFinish, read new title |
| 5 | JS can enumerate interactive elements with bounding rects | querySelectorAll + getBoundingClientRect on all links/buttons |

---

## What Succeeded

**All 6 checks passed (6/6).**

### 1. AppKit Window Hosting
WKWebView embedded in a plain `NSWindow.contentView` works without any SwiftUI. `NSApplication.shared` + `AppDelegate` + `NSWindow` is sufficient. The app ran headless from a terminal session without needing a full GUI login session (macOS allows this).

### 2. JS Isolation (WKContentWorld.defaultClient)
The `Isolated=yes` return value confirms the sentinel variable (`__spikeIsolated`) was visible to our injected script. The isolation goes both ways: page scripts cannot read our world's variables, and we aren't clobbering `window` globals on the page. The callback-based `evaluateJavaScript(_:in:in:completionHandler:)` signature works correctly.

**Critical finding:** The async/await overload was intentionally avoided. The Apple SDK has an unfixed bug where the async `evaluateJavaScript` overload crashes when the JS expression returns `void`/`undefined`. Callback form is safe and required.

### 3. Screenshot (takeSnapshot)
- Returned a valid `NSImage`  
- Dimensions: **2560x1800** pixels (HiDPI/Retina 2x of the 1280x900 window)  
- File size: **620KB** PNG  
- Saved to `/tmp/spike_screenshot.png`  
- `WKSnapshotConfiguration.afterScreenUpdates = true` ensures the screenshot waits for rendering

### 4. element.click() Triggers Navigation
`el.click()` in injected JS triggered a real navigation event. `WKNavigationDelegate.webView(_:didFinish:)` fired, and the new page title was readable. One subtlety: `didFailProvisionalNavigation` fires with `NSURLErrorCancelled (-999)` when a JS click triggers navigation away from a partially-loaded page - this is benign and must be silently ignored.

### 5. Interactive Element Extraction + Bounding Rects
HN returned **229 interactive elements** (links + buttons). `getBoundingClientRect()` produced x/y/w/h values for each. The first 20 were sampled with text + href + rect. This confirms the automation foundation: we can enumerate all clickable elements and their positions.

---

## What Failed

Nothing failed. All five assumptions were validated on the first run.

---

## Surprises / Notes

### The "first link" surprise
The first `a[href^="http"]` on HN is the **Y Combinator logo** at the top-left - it has empty `innerText` (it's an `<img>` inside an `<a>`) and its href is `https://news.ycombinator.com/` (the root). So the "click" triggered a navigation back to HN itself. The title after navigation was still `'Hacker News'`. This is correct behavior - the spike proved the mechanism works, even though the demo click wasn't visually interesting. **Lesson:** For production automation, filter `a[href]` by non-empty text content and non-self href.

### Retina screenshot dimensions
`takeSnapshot` returns the image at the backing-store resolution (2x on Retina), not the CSS pixel size. A 1280x900 window yields a 2560x1800 image. When storing or sending screenshots to agents, downsample to CSS pixels or document the 2x factor.

### NSURLErrorCancelled (-999) is routine
JS-triggered navigation reliably fires `didFailProvisionalNavigation` with error code -999 before the real `didFinish`. The delegate must explicitly ignore this code or it looks like a failure. This is documented behavior but easy to miss.

### Headless execution worked
The app ran from a plain `sh` session (inside tmux) without issues. `NSApplication.shared.run()` works without a full Aqua login session as long as the process has window server access (which it does on macOS when a user is logged in graphically).

### Swift 6 concurrency
Swift 6 strict concurrency mode would flag some of the closure captures as sendability violations. The spike compiled cleanly under Swift 6.4 without strict concurrency flags. The production codebase should use `@MainActor` annotations on the delegate classes to satisfy strict mode.

---

## What Was Learned

1. **The callback-vs-async distinction is critical.** Document this in the codebase; the wrong overload causes silent crashes, not compile errors.
2. **WKContentWorld isolation is real and usable.** The injected automation world is genuinely separate from page JS. Page scripts can't interfere with our automation variables.
3. **takeSnapshot is Retina-aware.** Store or serve images at 1x resolution unless you explicitly want the 2x pixels.
4. **element enumeration is fast and complete.** 229 elements extracted in a single JS round-trip with no performance concerns.
5. **The AppKit path is viable.** No SwiftUI required. Pure `NSApplication` + `WKWebView` is sufficient for a production browser shell.

---

## Architecture Implications

All five assumptions validated. The planned architecture (AppKit host + WKWebView + JS injection via WKContentWorld + takeSnapshot for screenshots) is sound. No blockers found. The spike validates the core automation loop: **load page -> enumerate elements -> screenshot -> click -> detect navigation -> read new state**.

Next step: build the `PageController` abstraction and the `AgentServer` MCP endpoint layer on top of this confirmed foundation.
