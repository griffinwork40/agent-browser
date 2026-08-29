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

      results.push(entry);
    }

    return results;
  }

  // --- PUBLIC API ---

  AB.inspect = function () {
    AB._generation += 1;
    return JSON.stringify({
      generation: AB._generation,
      url: location.href,
      title: document.title,
      elements: collectElements(),
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
