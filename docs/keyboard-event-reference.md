# Keyboard Event Properties — Web Automation Reference

**Sources:** MDN UI Events spec, W3C uievents-code PR-2024, freeCodeCamp keycode list, React issue #10135, multiple automation implementation audits.

---

## Key Property Mapping Table

| Key | `event.key` | `event.code` | `keyCode` / `which` | `keypress` fires? |
|---|---|---|---|---|
| Enter | `"Enter"` | `"Enter"` | `13` | ✅ Yes |
| Escape | `"Escape"` | `"Escape"` | `27` | ❌ No |
| Tab | `"Tab"` | `"Tab"` | `9` | ❌ No |
| Backspace | `"Backspace"` | `"Backspace"` | `8` | ❌ No |
| Delete | `"Delete"` | `"Delete"` | `46` | ❌ No |
| ArrowUp | `"ArrowUp"` | `"ArrowUp"` | `38` | ❌ No |
| ArrowDown | `"ArrowDown"` | `"ArrowDown"` | `40` | ❌ No |
| ArrowLeft | `"ArrowLeft"` | `"ArrowLeft"` | `37` | ❌ No |
| ArrowRight | `"ArrowRight"` | `"ArrowRight"` | `39` | ❌ No |
| Home | `"Home"` | `"Home"` | `36` | ❌ No |
| End | `"End"` | `"End"` | `35` | ❌ No |
| PageUp | `"PageUp"` | `"PageUp"` | `33` | ❌ No |
| PageDown | `"PageDown"` | `"PageDown"` | `34` | ❌ No |
| Space | `" "` (one space) | `"Space"` | `32` | ✅ Yes (printable) |

**Notes on `event.key` vs `event.code`:**
- `event.key` = logical value (layout-aware, what the key produces). Use for text input and shortcuts.
- `event.code` = physical position (layout-blind). Use for game controls (WASD) where position matters regardless of keyboard layout.
- `event.which` is always identical to `keyCode` for these keys. Both are deprecated — prefer `event.key`.

**`keypress` rule:** Only fires for keys that produce a printable character, plus Enter. All navigation/control keys above (except Enter and Space) do not fire `keypress`. Modern guidance is to not rely on `keypress` at all — use `keydown` instead.

---

## Dispatching a KeyboardEvent Correctly

Minimal correct dispatch for a non-printable key:

```js
function dispatchKey(el, key, code, keyCode) {
  const init = {
    key,
    code,
    keyCode,
    which: keyCode,
    bubbles: true,
    cancelable: true,
    composed: true,       // crosses shadow DOM boundaries
  };
  el.dispatchEvent(new KeyboardEvent('keydown', init));
  el.dispatchEvent(new KeyboardEvent('keyup', init));
}

// Example: Enter
dispatchKey(document.activeElement, 'Enter', 'Enter', 13);
```

For Enter (which also fires `keypress`):

```js
el.dispatchEvent(new KeyboardEvent('keydown', init));
el.dispatchEvent(new KeyboardEvent('keypress', init));
el.dispatchEvent(new KeyboardEvent('keyup', init));
```

---

## React Controlled Inputs — Native Setter Trick

### Why `input.value = x` silently fails

React installs a value tracker on every controlled `<input>`. When you write `input.value = x` you call React's patched setter, which updates both the DOM value and the tracker simultaneously. When the next `input` event fires, React compares the DOM value to the tracker and sees them equal — concludes nothing changed — and swallows the event. Your `onChange` never fires.

### The correct sequence (React 15.6 through 18+)

**Critical ordering:** call the native setter BEFORE dispatching the event. Reversed order defeats the deduplication bypass.

```js
// 1. Get the browser's original setter (not React's patched one)
const nativeSetter = Object.getOwnPropertyDescriptor(
  HTMLInputElement.prototype,
  'value'
).set;

// For <textarea>, use HTMLTextAreaElement.prototype instead.

// 2. Write through the native setter — leaves React's tracker stale
nativeSetter.call(inputEl, newValue);

// 3. Dispatch a bubbling input event — React compares tracker != DOM, fires onChange
inputEl.dispatchEvent(new Event('input', { bubbles: true }));

// 4. Dispatch change as well (for libraries that listen for change; safe to always include)
inputEl.dispatchEvent(new Event('change', { bubbles: true }));
```

**Why `bubbles: true` is non-negotiable:** React uses event delegation — one listener attached at the document root. A non-bubbling event never reaches it.

### Full production-ready function

```js
const _inputSetter   = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype,   'value').set;
const _textareSetter = Object.getOwnPropertyDescriptor(HTMLTextAreaElement.prototype, 'value').set;

function setNativeValue(el, value) {
  const setter = el instanceof HTMLTextAreaElement ? _textareSetter : _inputSetter;
  setter.call(el, value);
  el.dispatchEvent(new Event('input',  { bubbles: true }));
  el.dispatchEvent(new Event('change', { bubbles: true }));
}
```

### Adding the focus/blur cycle (for validation)

React form libraries (React Hook Form, Formik, Zod-backed forms) mark fields as "touched" only after focus + blur. Without this, required-field validation errors may not clear even though the value is set:

```js
function setNativeValueWithTouch(el, value) {
  el.focus();
  setNativeValue(el, value);                                    // setter + events above
  el.dispatchEvent(new FocusEvent('blur', { bubbles: true }));
  el.blur();
}
```

### Edge case: rendering mid-dispatch

If dispatching inside a React render cycle, wrap in `setTimeout`:

```js
setTimeout(() => inputEl.dispatchEvent(new Event('input', { bubbles: true })));
```

---

## `element.click()` and React `onClick`

**Yes, `element.click()` reliably triggers React `onClick` handlers.** React's synthetic event system intercepts the native `click` event as it bubbles. `element.click()` dispatches a real native `MouseEvent` which bubbles normally, so React's root listener picks it up and calls `onClick` as expected. No special treatment needed.

The only exception: elements where `pointer-events: none` is set or the element is disabled — in those cases the click may not propagate.

---

## Framework Compatibility: Native Setter + Input Event

| Framework | Native setter needed? | Events to dispatch | Notes |
|---|---|---|---|
| **React 16–18+** | ✅ Required | `input` + `change` (both bubbling) | Setter before event. Fiber/concurrent mode behaves the same. |
| **Vue 3 (`v-model`)** | ✅ Recommended | `input` only | `v-model` binds `@input`. One event is sufficient for Composition API `ref()` bindings. Add `change` if using VeeValidate/FormKit. |
| **Angular (reactive forms)** | ✅ Required | `input` + `change` | `FormControl` syncs on `input`; `NgModel` (template-driven) also needs `change`. Fire both to cover both patterns. |
| **Svelte** | ✅ Recommended | `input` | `bind:value` listens to `input`. |
| **Vanilla HTML** | ❌ Not needed | `input` or `change` | No framework tracker to defeat. |

**Bottom line:** the native-setter + bubbling `input` + `change` pattern is safe to apply universally across all modern frameworks. It does not break vanilla HTML and is required for every major framework-controlled input.

---

## `<select>` Elements

`<select>` does not have a `value` accessor on `HTMLInputElement.prototype`. Use:

```js
const nativeSelectSetter = Object.getOwnPropertyDescriptor(
  HTMLSelectElement.prototype, 'value'
).set;

nativeSelectSetter.call(selectEl, optionValue);
selectEl.dispatchEvent(new Event('change', { bubbles: true }));
// Note: select listens for 'change', not 'input'
```

---

## Quick Reference: Common Pitfalls

| Mistake | Result | Fix |
|---|---|---|
| `input.value = x` then dispatch `input` | React dedupes, onChange never fires | Use native prototype setter first |
| Event without `bubbles: true` | React's root listener never sees it | Always set `bubbles: true` |
| Native setter after event (wrong order) | Tracker already updated, event swallowed | Setter → event, never reversed |
| `new Event('input')` for `<select>` | Ignored | Use `new Event('change')` for selects |
| Skipping focus/blur | Validation stays in "untouched" state | Dispatch `focus` before, `blur` after |
| `keypress` for arrow keys | Event never fires | Use `keydown` for all navigation keys |
