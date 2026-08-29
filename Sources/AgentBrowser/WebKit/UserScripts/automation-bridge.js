(() => {
  'use strict';

  const AB = window.__agentBrowser = window.__agentBrowser || {};
  AB._generation = 0;

  // --- Helpers ---

  function hexId() {
    return Math.floor(Math.random() * 0xffffff).toString(16).padStart(6, '0');
  }

  function getOrAssignHandle(el) {
    let h = el.dataset.agentbrowserId;
    if (!h) { h = 'el_' + hexId(); el.dataset.agentbrowserId = h; }
    return h;
  }

  function isVisible(el) {
    const s = getComputedStyle(el);
    if (s.display === 'none' || s.visibility === 'hidden' || parseFloat(s.opacity) === 0) return false;
    const r = el.getBoundingClientRect();
    return r.width >= 1 && r.height >= 1;
  }

  const SKIP_TAGS = new Set(['SCRIPT','STYLE','TEMPLATE','NOSCRIPT','SVG']);

  function inSkipTree(el) {
    let n = el.parentElement;
    while (n) { if (SKIP_TAGS.has(n.tagName)) return true; n = n.parentElement; }
    return false;
  }

  function truncate(s, n) {
    if (!s) return '';
    s = s.trim();
    return s.length > n ? s.slice(0, n) + '…' : s;
  }

  // --- Accessible name (priority order per spec) ---

  function accessibleName(el) {
    const ariaLabel = el.getAttribute('aria-label');
    if (ariaLabel) return ariaLabel.trim();

    const labelledBy = el.getAttribute('aria-labelledby');
    if (labelledBy) {
      const text = labelledBy.split(/\s+/).map(id => {
        const ref = document.getElementById(id);
        return ref ? (ref.innerText || ref.textContent || '').trim() : '';
      }).filter(Boolean).join(' ');
      if (text) return text;
    }

    // Associated label via for/id
    const id = el.id;
    if (id) {
      const lbl = document.querySelector(`label[for="${CSS.escape(id)}"]`);
      if (lbl) return (lbl.innerText || lbl.textContent || '').trim();
    }
    // Wrapping label
    const parentLabel = el.closest('label');
    if (parentLabel) {
      const clone = parentLabel.cloneNode(true);
      clone.querySelectorAll('input,select,textarea,button').forEach(c => c.remove());
      const t = (clone.innerText || clone.textContent || '').trim();
      if (t) return t;
    }

    if (el.placeholder) return el.placeholder;
    if (el.title) return el.title;
    if (el.tagName === 'IMG') return el.alt || '';

    const inner = (el.innerText || el.textContent || '').trim();
    if (inner) return truncate(inner, 100);

    return el.name || '';
  }

  // --- Key map for press() ---

  const KEY_MAP = {
    Enter:     { key: 'Enter',     code: 'Enter',      keyCode: 13,  charCode: 13 },
    Escape:    { key: 'Escape',    code: 'Escape',      keyCode: 27,  charCode: 0  },
    Tab:       { key: 'Tab',       code: 'Tab',         keyCode: 9,   charCode: 0  },
    Backspace: { key: 'Backspace', code: 'Backspace',   keyCode: 8,   charCode: 0  },
    Delete:    { key: 'Delete',    code: 'Delete',      keyCode: 46,  charCode: 0  },
    ArrowUp:   { key: 'ArrowUp',   code: 'ArrowUp',     keyCode: 38,  charCode: 0  },
    ArrowDown: { key: 'ArrowDown', code: 'ArrowDown',   keyCode: 40,  charCode: 0  },
    ArrowLeft: { key: 'ArrowLeft', code: 'ArrowLeft',   keyCode: 37,  charCode: 0  },
    ArrowRight:{ key: 'ArrowRight',code: 'ArrowRight',  keyCode: 39,  charCode: 0  },
    Home:      { key: 'Home',      code: 'Home',        keyCode: 36,  charCode: 0  },
    End:       { key: 'End',       code: 'End',         keyCode: 35,  charCode: 0  },
    PageUp:    { key: 'PageUp',    code: 'PageUp',      keyCode: 33,  charCode: 0  },
    PageDown:  { key: 'PageDown',  code: 'PageDown',    keyCode: 34,  charCode: 0  },
    Space:     { key: ' ',         code: 'Space',       keyCode: 32,  charCode: 32 },
  };

  function fireKey(target, type, info) {
    target.dispatchEvent(new KeyboardEvent(type, {
      bubbles: true, cancelable: true,
      key: info.key, code: info.code,
      keyCode: info.keyCode, which: info.keyCode, charCode: info.charCode,
    }));
  }

  function fireEvent(el, type, init = {}) {
    el.dispatchEvent(new Event(type, { bubbles: true, cancelable: true, ...init }));
  }

  function fireMouseEvent(el, type, x, y) {
    el.dispatchEvent(new MouseEvent(type, {
      bubbles: true, cancelable: true,
      clientX: x, clientY: y, view: window,
    }));
  }

  // --- INTERACTIVE ELEMENT SELECTOR ---

  const INTERACTIVE_ROLES = new Set([
    'button','link','textbox','combobox','listbox','option','checkbox','radio',
    'menuitem','menuitemcheckbox','menuitemradio','switch','tab','searchbox',
    'slider','spinbutton','treeitem','gridcell',
  ]);

  // --- Relevance Scoring ---

  const FOOTER_PATTERNS = /privacy|terms|cookie|legal|copyright|©|sitemap|accessibility/i;
  const BOILERPLATE_PATTERNS = /^(skip to|sign up|log in|subscribe|newsletter|follow us|share|tweet|facebook|twitter|linkedin|instagram|youtube|pinterest|reddit|rss)/i;
  const HIGH_VALUE_ROLES = new Set(['textbox','searchbox','combobox','button','checkbox','radio','switch','slider','spinbutton']);
  const FORM_TAGS = new Set(['INPUT','TEXTAREA','SELECT']);

  function scoreElement(el, entry) {
    var score = 0;
    var tag = el.tagName.toUpperCase();
    var rect = entry.rect;
    var vh = window.innerHeight;
    var vw = window.innerWidth;
    var name = entry.name || '';
    var text = entry.text || '';
    var role = entry.role || '';
    var combinedLabel = (name + ' ' + text).toLowerCase();

    // In-viewport: strong positive
    if (rect.y >= 0 && rect.y < vh && rect.x >= 0 && rect.x < vw) {
      score += 30;
      // Near viewport center: bonus
      var cy = rect.y + rect.height / 2;
      var cx = rect.x + rect.width / 2;
      var distFromCenter = Math.sqrt(Math.pow((cx - vw/2) / vw, 2) + Math.pow((cy - vh/2) / vh, 2));
      if (distFromCenter < 0.3) score += 10;
    }

    // Focused element: strong signal
    if (document.activeElement === el) score += 40;

    // Form inputs: high value for agent interaction
    if (FORM_TAGS.has(tag)) score += 25;

    // High-value ARIA roles
    if (HIGH_VALUE_ROLES.has(role)) score += 15;

    // Has accessible name: more useful
    if (name) score += 10;

    // Larger visible area: more prominent
    var area = rect.width * rect.height;
    if (area > 5000) score += 8;
    else if (area > 1000) score += 4;

    // Part of a form
    if (el.closest('form')) score += 10;

    // Primary/submit buttons
    if (tag === 'BUTTON' || (tag === 'INPUT' && (el.type === 'submit' || el.type === 'button'))) {
      score += 8;
    }

    // Search inputs
    if (el.type === 'search' || role === 'searchbox' ||
        /search/i.test(name) || /search/i.test(el.placeholder || '')) {
      score += 20;
    }

    // Negative: footer/boilerplate
    if (el.closest('footer') || el.closest('[role="contentinfo"]')) score -= 20;
    if (FOOTER_PATTERNS.test(combinedLabel)) score -= 25;
    if (BOILERPLATE_PATTERNS.test(combinedLabel)) score -= 15;

    // Negative: very small controls (likely decorative)
    if (area < 100) score -= 10;

    // Negative: offscreen
    if (rect.y + rect.height < 0 || rect.y > vh * 2) score -= 30;

    // Negative: empty name on non-input
    if (!name && !text && !FORM_TAGS.has(tag)) score -= 15;

    // Negative: repetitive nav (deeply nested in nav with many siblings)
    var nav = el.closest('nav');
    if (nav && nav.querySelectorAll('a').length > 20) score -= 10;

    return score;
  }

  function queryMatch(entry, query) {
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
    // Exact match bonus
    var combinedLabel = fields.slice(0, 3).join(' ');
    if (combinedLabel.includes(q)) score += 20;
    return score;
  }

  // --- Mode Filtering ---

  function matchesMode(el, entry, mode) {
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
    default: // 'interactive'
      return true;
    }
  }

  // --- Deduplication ---

  function deduplicateElements(elements) {
    var seen = new Map();
    var result = [];
    for (var entry of elements) {
      var key = (entry.role || entry.tag) + '|' + (entry.name || entry.text || '');
      // Keep elements with unique identity; skip exact duplicates with same label
      if (key === '|' || key === 'null|') {
        // Both role and name empty -- keep if it has a unique href or input type
        key = entry.tag + '|' + (entry.href || '') + '|' + (entry.inputType || '');
      }
      if (seen.has(key)) {
        var prev = seen.get(key);
        // Keep the one with higher relevance score
        if ((entry._score || 0) > (prev._score || 0)) {
          // Replace previous
          result = result.filter(function(e) { return e.id !== prev.id; });
          result.push(entry);
          seen.set(key, entry);
        }
        // else skip this duplicate
      } else {
        seen.set(key, entry);
        result.push(entry);
      }
    }
    return result;
  }

  function collectElements() {
    const results = [];
    const seen = new Set();

    const candidates = document.querySelectorAll(
      'a[href], button, input, textarea, select, [role], [contenteditable="true"], [tabindex]'
    );

    for (const el of candidates) {
      if (seen.has(el)) continue;
      seen.add(el);

      const tag = el.tagName.toUpperCase();
      if (SKIP_TAGS.has(tag) || inSkipTree(el)) continue;

      const role = el.getAttribute('role') || '';
      const isNativeInteractive = ['A','BUTTON','INPUT','TEXTAREA','SELECT'].includes(tag);
      const hasInteractiveRole = INTERACTIVE_ROLES.has(role);
      const isContentEditable = el.isContentEditable && el.getAttribute('contenteditable') === 'true';
      const hasTabIndex = el.hasAttribute('tabindex');

      if (!isNativeInteractive && !hasInteractiveRole && !isContentEditable && !hasTabIndex) continue;
      if (!isVisible(el)) continue;

      const rect = el.getBoundingClientRect();
      const handle = getOrAssignHandle(el);
      const name = accessibleName(el);
      const inputType = el.type || null;
      const isDisabled = el.disabled || el.getAttribute('aria-disabled') === 'true';
      const isChecked = el.type === 'checkbox' || el.type === 'radio' ? el.checked : undefined;

      const entry = {
        id: handle,
        tag: tag.toLowerCase(),
        role: role || null,
        name: truncate(name, 100),
        text: truncate((el.innerText || el.textContent || '').trim(), 100),
        placeholder: el.placeholder || null,
        inputType: inputType,
        value: ('value' in el && el.type !== 'password') ? el.value : undefined,
        href: el.href || null,
        disabled: isDisabled || false,
        checked: isChecked,
        visible: true,
        rect: { x: Math.round(rect.x), y: Math.round(rect.y), width: Math.round(rect.width), height: Math.round(rect.height) },
      };

      // Strip undefined keys for a compact payload
      for (const k of Object.keys(entry)) { if (entry[k] === undefined) delete entry[k]; }

      // Compute relevance score
      entry._score = scoreElement(el, entry);
      entry._el = el;

      results.push(entry);
    }

    return results;
  }

  // --- PUBLIC API ---

  AB.inspect = function (opts) {
    opts = opts || {};
    AB._generation += 1;

    var mode = opts.mode || 'interactive';
    var limit = typeof opts.limit === 'number' ? opts.limit : 30;
    var query = opts.query || null;

    // Collect all interactive elements
    var allElements = collectElements();
    var totalInteractive = allElements.length;

    // Apply mode filter
    var filtered = allElements;
    if (mode !== 'all') {
      filtered = allElements.filter(function(entry) {
        return matchesMode(entry._el, entry, mode);
      });
    }

    // Apply query scoring boost
    if (query) {
      for (var entry of filtered) {
        entry._score += queryMatch(entry, query);
      }
    }

    // Sort by relevance score descending
    filtered.sort(function(a, b) { return (b._score || 0) - (a._score || 0); });

    // Deduplicate
    filtered = deduplicateElements(filtered);

    // Apply limit (0 or negative means unlimited)
    var truncated = false;
    var returnedCount = filtered.length;
    if (limit > 0 && filtered.length > limit) {
      filtered = filtered.slice(0, limit);
      truncated = true;
      returnedCount = filtered.length;
    }

    // Strip internal fields before serialization
    var elements = filtered.map(function(entry) {
      var clean = {};
      for (var k of Object.keys(entry)) {
        if (k !== '_score' && k !== '_el') clean[k] = entry[k];
      }
      return clean;
    });

    return JSON.stringify({
      generation: AB._generation,
      url: location.href,
      title: document.title,
      returned: elements.length,
      totalInteractive: totalInteractive,
      truncated: truncated,
      mode: mode,
      elements: elements,
    });
  };

  AB.resolveElement = function (handleId) {
    return document.querySelector(`[data-agentbrowser-id="${CSS.escape(handleId)}"]`) || null;
  };

  AB.checkStale = function (handleId) {
    return !document.querySelector(`[data-agentbrowser-id="${CSS.escape(handleId)}"]`);
  };

  AB.click = function (handleId) {
    const el = AB.resolveElement(handleId);
    if (!el) return JSON.stringify({ error: 'ELEMENT_NOT_FOUND' });
    if (!document.contains(el)) return JSON.stringify({ error: 'ELEMENT_STALE' });
    if (!isVisible(el)) return JSON.stringify({ error: 'ELEMENT_NOT_VISIBLE' });
    if (el.disabled || el.getAttribute('aria-disabled') === 'true') return JSON.stringify({ error: 'ELEMENT_DISABLED' });

    const r = el.getBoundingClientRect();
    const x = r.left + r.width / 2;
    const y = r.top + r.height / 2;

    fireMouseEvent(el, 'mouseover', x, y);
    fireMouseEvent(el, 'mouseenter', x, y);
    fireMouseEvent(el, 'mousemove', x, y);
    fireMouseEvent(el, 'mousedown', x, y);

    const focusable = ['A','BUTTON','INPUT','TEXTAREA','SELECT'].includes(el.tagName)
      || el.getAttribute('tabindex') != null;
    if (focusable) { try { el.focus(); } catch (_) {} }

    fireMouseEvent(el, 'mouseup', x, y);
    fireMouseEvent(el, 'click', x, y);

    return JSON.stringify({ ok: true });
  };

  AB.fill = function (handleId, value) {
    const el = AB.resolveElement(handleId);
    if (!el) return JSON.stringify({ error: 'ELEMENT_NOT_FOUND' });
    if (!document.contains(el)) return JSON.stringify({ error: 'ELEMENT_STALE' });
    if (!isVisible(el)) return JSON.stringify({ error: 'ELEMENT_NOT_VISIBLE' });

    const tag = el.tagName.toUpperCase();
    const previousValue = el.value || el.textContent || '';

    try { el.focus(); } catch (_) {}

    if (tag === 'INPUT') {
      const nativeSetter = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value');
      nativeSetter.set.call(el, value);
      fireEvent(el, 'focus');
      el.select();
      el.dispatchEvent(new InputEvent('input', { bubbles: true, cancelable: true, inputType: 'insertReplacementText', data: value }));
      fireEvent(el, 'change');
    } else if (tag === 'TEXTAREA') {
      const nativeSetter = Object.getOwnPropertyDescriptor(HTMLTextAreaElement.prototype, 'value');
      nativeSetter.set.call(el, value);
      fireEvent(el, 'focus');
      el.select();
      el.dispatchEvent(new InputEvent('input', { bubbles: true, cancelable: true, inputType: 'insertReplacementText', data: value }));
      fireEvent(el, 'change');
    } else if (el.isContentEditable) {
      el.textContent = value;
      fireEvent(el, 'input');
    } else {
      return JSON.stringify({ error: 'ELEMENT_NOT_FILLABLE' });
    }

    return JSON.stringify({ ok: true, previousValue });
  };

  AB.press = function (handleId, key) {
    const target = handleId
      ? AB.resolveElement(handleId)
      : document.activeElement;
    if (!target) return JSON.stringify({ error: 'ELEMENT_NOT_FOUND' });

    const info = KEY_MAP[key];
    if (!info) return JSON.stringify({ error: 'UNKNOWN_KEY' });

    fireKey(target, 'keydown', info);
    if (info.charCode > 0) fireKey(target, 'keypress', info);
    fireKey(target, 'keyup', info);

    return JSON.stringify({ ok: true });
  };

  AB.select = function (handleId, value) {
    const el = AB.resolveElement(handleId);
    if (!el) return JSON.stringify({ error: 'ELEMENT_NOT_FOUND' });
    if (el.tagName.toUpperCase() !== 'SELECT') return JSON.stringify({ error: 'ELEMENT_NOT_SELECT' });

    el.value = value;
    fireEvent(el, 'change');
    return JSON.stringify({ ok: true });
  };

  AB.waitForElement = function (condition, timeoutMs = 5000) {
    return new Promise((resolve, reject) => {
      const deadline = Date.now() + timeoutMs;

      function check() {
        let found = null;

        if (condition.selector) {
          found = document.querySelector(condition.selector);
        } else if (condition.text) {
          const els = document.querySelectorAll('*');
          for (const el of els) {
            if (!SKIP_TAGS.has(el.tagName) && (el.innerText || '').includes(condition.text)) {
              found = el; break;
            }
          }
        } else if (condition.role || condition.name) {
          const els = document.querySelectorAll(condition.role ? `[role="${condition.role}"]` : '*');
          for (const el of els) {
            if (!condition.name || accessibleName(el).includes(condition.name)) {
              found = el; break;
            }
          }
        }

        if (found && isVisible(found)) {
          const handle = getOrAssignHandle(found);
          resolve(JSON.stringify({ id: handle, tag: found.tagName.toLowerCase() }));
          return;
        }
        if (Date.now() >= deadline) {
          reject(JSON.stringify({ error: 'WAIT_TIMEOUT' }));
          return;
        }
        setTimeout(check, 100);
      }

      check();
    });
  };

  AB.waitForText = function (text, timeoutMs = 5000) {
    return new Promise((resolve, reject) => {
      const deadline = Date.now() + timeoutMs;

      function check() {
        if ((document.body.innerText || document.body.textContent || '').includes(text)) {
          resolve(JSON.stringify({ ok: true }));
          return;
        }
        if (Date.now() >= deadline) {
          reject(JSON.stringify({ error: 'WAIT_TIMEOUT' }));
          return;
        }
        setTimeout(check, 100);
      }

      check();
    });
  };
})();
