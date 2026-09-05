// automation-bridge-relevance.js
// Element relevance scoring, mode filtering, and deduplication helpers.
// Must be injected BEFORE automation-bridge.js (same WKContentWorld).
// Attaches helpers to window.__agentBrowser so the main bridge can call them.
(() => {
  'use strict';

  const AB = window.__agentBrowser = window.__agentBrowser || {};

  // --- Relevance Scoring ---

  const FOOTER_PATTERNS = /privacy|terms|cookie|legal|copyright|\u00a9|sitemap|accessibility/i;
  const BOILERPLATE_PATTERNS = /^(skip to|sign up|log in|subscribe|newsletter|follow us|share|tweet|facebook|twitter|linkedin|instagram|youtube|pinterest|reddit|rss)/i;
  const HIGH_VALUE_ROLES = new Set(['textbox','searchbox','combobox','button','checkbox','radio','switch','slider','spinbutton']);
  const FORM_TAGS = new Set(['INPUT','TEXTAREA','SELECT']);

  AB._scoreElement = function (el, entry) {
    var score = 0;
    var tag = el.tagName.toUpperCase();
    var rect = entry.rect;
    var vh = window.innerHeight;
    var vw = window.innerWidth;
    var name = entry.name || '';
    var text = entry.text || '';
    var role = entry.role || '';
    var combinedLabel = (name + ' ' + text).toLowerCase();

    if (rect.y >= 0 && rect.y < vh && rect.x >= 0 && rect.x < vw) {
      score += 30;
      var cy = rect.y + rect.height / 2;
      var cx = rect.x + rect.width / 2;
      var distFromCenter = Math.sqrt(Math.pow((cx - vw/2) / vw, 2) + Math.pow((cy - vh/2) / vh, 2));
      if (distFromCenter < 0.3) score += 10;
    }

    if (document.activeElement === el) score += 40;
    if (FORM_TAGS.has(tag)) score += 25;
    if (HIGH_VALUE_ROLES.has(role)) score += 15;
    if (name) score += 10;

    var area = rect.width * rect.height;
    if (area > 5000) score += 8;
    else if (area > 1000) score += 4;

    if (el.closest('form')) score += 10;

    if (tag === 'BUTTON' || (tag === 'INPUT' && (el.type === 'submit' || el.type === 'button'))) {
      score += 8;
    }

    if (el.type === 'search' || role === 'searchbox' ||
        /search/i.test(name) || /search/i.test(el.placeholder || '')) {
      score += 20;
    }

    if (el.closest('footer') || el.closest('[role="contentinfo"]')) score -= 20;
    if (FOOTER_PATTERNS.test(combinedLabel)) score -= 25;
    if (BOILERPLATE_PATTERNS.test(combinedLabel)) score -= 15;
    if (area < 100) score -= 10;
    if (rect.y + rect.height < 0 || rect.y > vh * 2) score -= 30;
    if (!name && !text && !FORM_TAGS.has(tag)) score -= 15;

    var nav = el.closest('nav');
    if (nav && nav.querySelectorAll('a').length > 20) score -= 10;

    return score;
  };

  AB._queryMatch = function (entry, query) {
    if (!query) return 0;
    var q = query.toLowerCase();
    var terms = q.split(/\s+/).filter(Boolean);
    var score = 0;
    var fields = [
      (entry.name || '').toLowerCase(),
      (entry.text || '').toLowerCase(),
      (entry.placeholder || '').toLowerCase(),
      (entry.href || '').toLowerCase(),
      (entry.role || '').toLowerCase(),
    ];
    for (var t of terms) {
      for (var f of fields) {
        if (f.includes(t)) { score += 10; break; }
      }
    }
    var combinedLabel = fields.slice(0, 3).join(' ');
    if (combinedLabel.includes(q)) score += 20;
    return score;
  };

  AB._matchesMode = function (el, entry, mode) {
    var tag = el.tagName.toUpperCase();
    var role = entry.role || '';
    switch (mode) {
    case 'forms':
      return FORM_TAGS.has(tag) || role === 'checkbox' || role === 'radio' ||
             role === 'switch' || role === 'combobox' || role === 'listbox' ||
             role === 'spinbutton' || role === 'slider' ||
             (tag === 'BUTTON' && (el.type === 'submit' || el.closest('form')));
    case 'navigation':
      return tag === 'A' || role === 'link' || role === 'tab' ||
             role === 'menuitem' || role === 'treeitem' ||
             el.closest('nav') !== null;
    case 'all':
      return true;
    default:
      return true;
    }
  };

  AB._deduplicateElements = function (elements) {
    var seen = new Map();
    var result = [];
    for (var entry of elements) {
      var key = (entry.role || entry.tag) + '|' + (entry.name || entry.text || '');
      if (key === '|' || key === 'null|') {
        key = entry.tag + '|' + (entry.href || '') + '|' + (entry.inputType || '');
      }
      if (seen.has(key)) {
        var prev = seen.get(key);
        if ((entry._score || 0) > (prev._score || 0)) {
          result = result.filter(function(e) { return e.id !== prev.id; });
          result.push(entry);
          seen.set(key, entry);
        }
      } else {
        seen.set(key, entry);
        result.push(entry);
      }
    }
    return result;
  };
})();
