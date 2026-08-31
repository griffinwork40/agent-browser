import Foundation

// MARK: - Content Extraction Scripts
//
// Injected JavaScript for markdown and bounded content extraction.
// Separated from BrowserAutomationService.swift for maintainability.
//
// Additional scripts live in:
//   ContentExtraction+MainContent.swift  – mainContentScript(budget:query:)
//   ContentExtraction+FullMarkdown.swift – fullMarkdownScript

enum ContentExtraction {

    // MARK: - Read Modes

    /// Supported read modes for page content extraction.
    enum ReadMode: String {
        case summary    // Bounded: title + headings + lead content (~6K chars)
        case main       // Article/main content, boilerplate stripped (~16K chars)
        case full       // Uncapped full-page markdown
        case text       // Raw innerText
        case html       // Raw outerHTML
    }

    /// Default character budget per mode.
    static func defaultBudget(for mode: ReadMode) -> Int {
        switch mode {
        case .summary: return 6000
        case .main:    return 16000
        case .full:    return 0  // uncapped
        case .text:    return 0
        case .html:    return 0
        }
    }

    // MARK: - Summary Extraction Script

    /// JS that extracts a bounded summary: title, meta description, headings,
    /// and lead content from the main content area. Deterministic, no LLM.
    static func summaryScript(budget: Int, query: String?) -> String {
        let queryJS = query.map { "'\(escapeJS($0))'" } ?? "null"
        return """
        (function() {
            if (!document.body) return JSON.stringify({content:'(empty page)',chars:0,truncated:false});
            var budget = \(budget);
            var query = \(queryJS);
            var out = [];
            var chars = 0;

            // Title
            var title = document.title || '';
            if (title) { out.push('# ' + title); chars += title.length + 3; }

            // Meta description
            var meta = document.querySelector('meta[name="description"]');
            if (meta && meta.content) {
                var desc = meta.content.trim();
                if (desc) { out.push(desc); chars += desc.length + 1; }
            }

            // URL
            out.push('URL: ' + location.href);
            chars += location.href.length + 6;
            out.push('');

            // Find content root
            var root = document.querySelector('main, article, [role="main"]') || document.body;

            // Collect headings with their content
            var sections = [];
            var headings = root.querySelectorAll('h1,h2,h3,h4,h5,h6');
            for (var h of headings) {
                var level = parseInt(h.tagName[1]);
                var hText = (h.innerText || h.textContent || '').trim();
                if (!hText) continue;
                // Gather text from following siblings until next heading
                var content = [];
                var sib = h.nextElementSibling;
                while (sib && !/^H[1-6]$/.test(sib.tagName)) {
                    var tag = sib.tagName.toLowerCase();
                    if (tag === 'p' || tag === 'li' || tag === 'pre' || tag === 'blockquote' ||
                        tag === 'div' || tag === 'section') {
                        var t = (sib.innerText || sib.textContent || '').trim();
                        if (t) content.push(t);
                    }
                    sib = sib.nextElementSibling;
                }
                sections.push({ level: level, heading: hText, content: content });
            }

            // Query scoring: if query provided, boost matching sections
            if (query) {
                var qLower = query.toLowerCase();
                var terms = qLower.split(/\\s+/);
                sections.forEach(function(sec) {
                    var score = 0;
                    var hLower = sec.heading.toLowerCase();
                    var cLower = sec.content.join(' ').toLowerCase();
                    if (hLower.includes(qLower)) score += 100;
                    if (cLower.includes(qLower)) score += 50;
                    terms.forEach(function(t) {
                        if (hLower.includes(t)) score += 30;
                        if (cLower.includes(t)) score += 10;
                    });
                    sec._score = score;
                });
                sections.sort(function(a,b) { return (b._score||0) - (a._score||0); });
            }

            // Also gather lead content (first paragraphs before any heading)
            var leadPs = [];
            var firstChild = root.firstElementChild;
            while (firstChild && !/^H[1-6]$/.test(firstChild.tagName)) {
                if (firstChild.tagName === 'P' || firstChild.tagName === 'DIV') {
                    var lt = (firstChild.innerText || firstChild.textContent || '').trim();
                    if (lt && lt.length > 20) leadPs.push(lt);
                }
                firstChild = firstChild.nextElementSibling;
            }

            // Add lead content first
            for (var lp of leadPs) {
                if (chars + lp.length > budget) {
                    out.push(lp.slice(0, budget - chars) + '...');
                    chars = budget;
                    break;
                }
                out.push(lp);
                chars += lp.length + 1;
            }

            // Add sections within budget
            for (var sec of sections) {
                if (chars >= budget) break;
                var prefix = '#'.repeat(sec.level) + ' ';
                var hLine = prefix + sec.heading;
                if (chars + hLine.length > budget) break;
                out.push('');
                out.push(hLine);
                chars += hLine.length + 2;

                for (var para of sec.content) {
                    if (chars >= budget) break;
                    if (chars + para.length > budget) {
                        out.push(para.slice(0, budget - chars) + '...');
                        chars = budget;
                        break;
                    }
                    out.push(para);
                    chars += para.length + 1;
                }
            }

            var result = out.join('\\n').trim();
            return JSON.stringify({
                content: result || '(empty page)',
                characters: result.length,
                truncated: chars >= budget
            });
        })()
        """
    }

    // MARK: - Helpers

    static func escapeJS(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
         .replacingOccurrences(of: "'", with: "\\'")
         .replacingOccurrences(of: "\n", with: "\\n")
         .replacingOccurrences(of: "\r", with: "\\r")
    }
}
