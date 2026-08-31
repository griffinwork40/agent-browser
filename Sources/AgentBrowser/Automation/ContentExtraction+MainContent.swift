// MARK: - Main Content Extraction Script

extension ContentExtraction {

    /// JS that extracts main/article content with nav/footer/boilerplate stripped.
    /// Uses semantic containers and density heuristics. Bounded by character budget.
    static func mainContentScript(budget: Int, query: String?) -> String {
        let queryJS = query.map { "'\(escapeJS($0))'" } ?? "null"
        return """
        (function() {
            if (!document.body) return JSON.stringify({content:'(empty page)',characters:0,truncated:false});
            var budget = \(budget > 0 ? budget : 999999);
            var query = \(queryJS);
            var SKIP = new Set(['script','style','noscript','svg','template','link','meta']);
            var STRIP = new Set(['nav','header','footer']);

            function hidden(el) {
                if (el.hidden) return true;
                var s = el.style;
                if (s && (s.display === 'none' || s.visibility === 'hidden')) return true;
                return false;
            }
            function isBoilerplate(el) {
                var role = el.getAttribute('role') || '';
                if (role === 'navigation' || role === 'banner' || role === 'contentinfo') return true;
                if (role === 'complementary') return true;
                var cls = (el.className || '').toLowerCase();
                var id = (el.id || '').toLowerCase();
                var combined = cls + ' ' + id;
                if (/\\b(footer|nav|sidebar|menu|cookie|banner|advertisement|social|share)\\b/.test(combined)) return true;
                return false;
            }
            function txt(el) { return (el.innerText || el.textContent || '').replace(/[ \\t]+/g, ' ').trim(); }
            function absURL(href) {
                if (!href) return '';
                try { return new URL(href, document.baseURI).href; } catch(e) { return href; }
            }

            var root = document.querySelector('main, article, [role="main"]') || document.body;
            var out = [];
            var chars = 0;

            // Title
            var title = document.title || '';
            if (title) { out.push('# ' + title + '\\n'); chars += title.length + 4; }

            function walk(node) {
                if (chars >= budget) return;
                if (node.nodeType === 3) {
                    var t = node.textContent;
                    if (t && t.trim()) { out.push(t); chars += t.length; }
                    return;
                }
                if (node.nodeType !== 1) return;
                var tag = node.tagName.toLowerCase();
                if (SKIP.has(tag)) return;
                if (hidden(node)) return;
                if (STRIP.has(tag) || isBoilerplate(node)) return;

                switch(tag) {
                case 'h1': case 'h2': case 'h3': case 'h4': case 'h5': case 'h6':
                    var lvl = tag[1];
                    var prefix = '#'.repeat(parseInt(lvl));
                    var hTxt = txt(node);
                    if (hTxt) { out.push('\\n' + prefix + ' ' + hTxt + '\\n'); chars += hTxt.length + parseInt(lvl) + 3; }
                    return;
                case 'p':
                    out.push('\\n');
                    for (var c of node.childNodes) walk(c);
                    out.push('\\n');
                    return;
                case 'a':
                    var href = node.getAttribute('href') || '';
                    var atxt = txt(node);
                    if (atxt && href && !href.startsWith('javascript:') && !href.startsWith('#')) {
                        var link = '[' + atxt + '](' + absURL(href) + ')';
                        out.push(link); chars += link.length;
                    } else if (atxt) {
                        out.push(atxt); chars += atxt.length;
                    }
                    return;
                case 'strong': case 'b':
                    var st = txt(node);
                    if (st) { out.push('**' + st + '**'); chars += st.length + 4; }
                    return;
                case 'em': case 'i':
                    var et = txt(node);
                    if (et) { out.push('*' + et + '*'); chars += et.length + 2; }
                    return;
                case 'code':
                    if (node.parentElement && node.parentElement.tagName === 'PRE') break;
                    var ct = (node.textContent || '').trim();
                    if (ct) { out.push('`' + ct + '`'); chars += ct.length + 2; }
                    return;
                case 'pre':
                    var codeEl = node.querySelector('code');
                    var lang = '';
                    if (codeEl) { var m = (codeEl.className || '').match(/language-(\\w+)/); if (m) lang = m[1]; }
                    var preText = (node.textContent || '').trim();
                    out.push('\\n```' + lang + '\\n' + preText + '\\n```\\n');
                    chars += preText.length + lang.length + 10;
                    return;
                case 'blockquote':
                    txt(node).split('\\n').forEach(function(l) { out.push('\\n> ' + l.trim()); chars += l.length + 4; });
                    out.push('\\n');
                    return;
                case 'ul':
                    out.push('\\n');
                    Array.from(node.children).forEach(function(li) {
                        if (li.tagName === 'LI') { var t = txt(li); out.push('- ' + t + '\\n'); chars += t.length + 3; }
                    });
                    return;
                case 'ol':
                    out.push('\\n');
                    var i = 1;
                    Array.from(node.children).forEach(function(li) {
                        if (li.tagName === 'LI') { var t = txt(li); out.push(i + '. ' + t + '\\n'); chars += t.length + 4; i++; }
                    });
                    return;
                case 'table':
                    out.push('\\n');
                    var rows = node.querySelectorAll('tr');
                    var first = true;
                    rows.forEach(function(tr) {
                        var cells = tr.querySelectorAll('th, td');
                        if (cells.length === 0) return;
                        var line = '| ' + Array.from(cells).map(function(c) { return txt(c); }).join(' | ') + ' |';
                        out.push(line + '\\n'); chars += line.length + 1;
                        if (first) {
                            var sep = '|' + Array.from(cells).map(function() { return '---'; }).join('|') + '|';
                            out.push(sep + '\\n'); chars += sep.length + 1;
                            first = false;
                        }
                    });
                    out.push('\\n');
                    return;
                case 'hr':
                    out.push('\\n---\\n'); chars += 6;
                    return;
                case 'br':
                    out.push('\\n'); chars += 1;
                    return;
                case 'img':
                    var alt = node.getAttribute('alt') || '';
                    var src = node.getAttribute('src') || '';
                    if (src && !src.startsWith('data:')) {
                        var img = '![' + alt + '](' + absURL(src) + ')';
                        out.push(img); chars += img.length;
                    }
                    return;
                default:
                    for (var child of node.childNodes) walk(child);
                    return;
                }
                for (var fb of node.childNodes) walk(fb);
            }

            walk(root);

            var result = out.join('')
                .replace(/[ \\t]*\\n/g, '\\n')
                .replace(/\\n{3,}/g, '\\n\\n')
                .trim();

            // Apply budget truncation at paragraph boundary
            var truncated = false;
            if (budget > 0 && result.length > budget) {
                var cutPoint = result.lastIndexOf('\\n\\n', budget);
                if (cutPoint < budget * 0.5) cutPoint = result.lastIndexOf('\\n', budget);
                if (cutPoint < budget * 0.5) cutPoint = budget;
                result = result.slice(0, cutPoint).trim() + '\\n\\n[... content truncated]';
                truncated = true;
            }

            // Query-focused: if query provided, try to find and prioritize matching sections
            if (query && result.length > 200) {
                var qLower = query.toLowerCase();
                var lines = result.split('\\n');
                var matchedBlocks = [];
                var currentBlock = [];
                var currentScore = 0;
                for (var li = 0; li < lines.length; li++) {
                    var line = lines[li];
                    if (/^#{1,6} /.test(line)) {
                        if (currentBlock.length > 0) {
                            matchedBlocks.push({ text: currentBlock.join('\\n'), score: currentScore });
                        }
                        currentBlock = [line];
                        currentScore = line.toLowerCase().includes(qLower) ? 100 : 0;
                    } else {
                        currentBlock.push(line);
                        if (line.toLowerCase().includes(qLower)) currentScore += 50;
                    }
                }
                if (currentBlock.length > 0) {
                    matchedBlocks.push({ text: currentBlock.join('\\n'), score: currentScore });
                }
                var anyMatch = matchedBlocks.some(function(b) { return b.score > 0; });
                if (anyMatch) {
                    matchedBlocks.sort(function(a,b) { return b.score - a.score; });
                    var qResult = [];
                    var qChars = 0;
                    for (var blk of matchedBlocks) {
                        if (qChars + blk.text.length > budget && qChars > 0) break;
                        qResult.push(blk.text);
                        qChars += blk.text.length;
                    }
                    result = qResult.join('\\n\\n').trim();
                }
            }

            return JSON.stringify({
                content: result || '(empty page)',
                characters: result.length,
                truncated: truncated
            });
        })()
        """
    }
}
