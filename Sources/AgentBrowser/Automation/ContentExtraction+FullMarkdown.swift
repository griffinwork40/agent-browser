// MARK: - Full Markdown Script (existing behavior)

extension ContentExtraction {

    static let fullMarkdownScript: String = """
    (function() {
        if (!document.body) return '';
        var out = [];
        var title = document.title || '';
        var root = document.querySelector('main, article, [role="main"]') || document.body;
        var SKIP = new Set(['script','style','noscript','svg','template','link','meta']);

        function hidden(el) {
            if (el.hidden) return true;
            var s = el.style;
            if (s && (s.display === 'none' || s.visibility === 'hidden')) return true;
            return false;
        }
        function txt(el) { return (el.innerText || el.textContent || '').replace(/[ \\t]+/g, ' ').trim(); }
        function absURL(href) {
            if (!href) return '';
            try { return new URL(href, document.baseURI).href; } catch(e) { return href; }
        }

        function walk(node) {
            if (node.nodeType === 3) { var t = node.textContent; if (t && t.trim()) out.push(t); return; }
            if (node.nodeType !== 1) return;
            var tag = node.tagName.toLowerCase();
            if (SKIP.has(tag)) return;
            if (hidden(node)) return;
            switch(tag) {
            case 'h1': case 'h2': case 'h3': case 'h4': case 'h5': case 'h6':
                out.push('\\n' + '#'.repeat(parseInt(tag[1])) + ' ' + txt(node) + '\\n'); return;
            case 'p':
                out.push('\\n'); for (var c of node.childNodes) walk(c); out.push('\\n'); return;
            case 'a':
                var href = node.getAttribute('href') || '';
                var atxt = txt(node);
                if (atxt && href && !href.startsWith('javascript:') && !href.startsWith('#')) {
                    out.push('[' + atxt + '](' + absURL(href) + ')');
                } else if (atxt) { out.push(atxt); }
                return;
            case 'img':
                var alt = node.getAttribute('alt') || '';
                var src = node.getAttribute('src') || '';
                if (src) out.push('![' + alt + '](' + absURL(src) + ')');
                return;
            case 'strong': case 'b':
                var st = txt(node); if (st) out.push('**' + st + '**'); return;
            case 'em': case 'i':
                var et = txt(node); if (et) out.push('*' + et + '*'); return;
            case 'code':
                if (node.parentElement && node.parentElement.tagName === 'PRE') break;
                var ct = (node.textContent || '').trim(); if (ct) out.push('`' + ct + '`'); return;
            case 'pre':
                var codeEl = node.querySelector('code');
                var lang = '';
                if (codeEl) { var m = (codeEl.className || '').match(/language-(\\w+)/); if (m) lang = m[1]; }
                out.push('\\n```' + lang + '\\n' + (node.textContent || '').trim() + '\\n```\\n'); return;
            case 'blockquote':
                txt(node).split('\\n').forEach(function(l) { out.push('\\n> ' + l.trim()); }); out.push('\\n'); return;
            case 'ul':
                out.push('\\n');
                Array.from(node.children).forEach(function(li) { if (li.tagName === 'LI') out.push('- ' + txt(li) + '\\n'); });
                return;
            case 'ol':
                out.push('\\n'); var i = 1;
                Array.from(node.children).forEach(function(li) { if (li.tagName === 'LI') { out.push(i + '. ' + txt(li) + '\\n'); i++; } });
                return;
            case 'table':
                out.push('\\n');
                var rows = node.querySelectorAll('tr'); var first = true;
                rows.forEach(function(tr) {
                    var cells = tr.querySelectorAll('th, td');
                    if (cells.length === 0) return;
                    out.push('| ' + Array.from(cells).map(function(c) { return txt(c); }).join(' | ') + ' |\\n');
                    if (first) { out.push('|' + Array.from(cells).map(function() { return '---'; }).join('|') + '|\\n'); first = false; }
                });
                out.push('\\n'); return;
            case 'hr': out.push('\\n---\\n'); return;
            case 'br': out.push('\\n'); return;
            case 'div': case 'section': case 'main': case 'article': case 'aside':
            case 'details': case 'summary': case 'figure': case 'figcaption':
                out.push('\\n'); for (var ch of node.childNodes) walk(ch); out.push('\\n'); return;
            default:
                for (var child of node.childNodes) walk(child); return;
            }
            for (var fb of node.childNodes) walk(fb);
        }

        walk(root);
        var result = out.join('').replace(/[ \\t]*\\n/g, '\\n').replace(/\\n{3,}/g, '\\n\\n').trim();
        if (title && !result.startsWith('# ' + title)) { result = '# ' + title + '\\n\\n' + result; }
        return result || '(empty page)';
    })()
    """
}
