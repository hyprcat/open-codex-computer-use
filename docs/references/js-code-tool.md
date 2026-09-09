# The `js` tool — the single Computer Use interface

`js` is the only tool advertised over MCP. It runs JavaScript that drives the
desktop through a synchronous `cua` API, so a whole flow (read state, find an
element, act, verify, loop, retry) happens in one call instead of one call per
action. The underlying actions (click, type, get_app_state, ...) are not
advertised; they are reachable from inside `js` as `cua.*`, and still callable by
name through the CLI (`open-computer-use call click ...`) for debugging.

## Runtime

- **Engine:** JavaScriptCore, in-process in the MCP server. macOS only. On a
  build without JavaScriptCore the tool returns a stable unsupported error.
- **Synchronous by design:** actions run in-process, so there are no promises and
  no top-level await. `cua.click(...)` returns when the action has run.
- **Scope and persistence:** each call runs in its own function scope, so
  `let`/`const` never collide across calls. Assign to `globalThis` for a value
  that must survive to the next call. Pass `reset: true` to clear all `globalThis`
  bindings before running.
- **Output:** `write(value)` appends to the result text (objects are
  JSON-stringified); `console.log(...)` adds a trailing newline. `emitImage(base64)`
  attaches an image. Return values are not auto-printed; use `write`.
- **Timeout:** `timeout_ms` bounds execution (default 30000 ms). A runaway script
  is terminated through JavaScriptCore's execution time-limit, which the framework
  exports but declares only privately; the shim `OpenComputerUseJavaScriptShim`
  restates the prototype.

## The `cua` API

State and elements (prefer these; act by element index):

```
cua.getState(app, opts?)    -> { text, elements }
cua.elements(app, opts?)    -> [{ index, role, title, value, identifier, bounds, actions }]
cua.find(app, e => ...)     -> first matching element, or null
cua.findAll(app, e => ...)  -> all matching elements
cua.getAppState(app, opts?) -> tree text only
cua.screenshot(app, opts?)  -> tree text, and emits the screenshot
```

Actions (each throws on a tool error; catch with try/catch):

```
cua.click(app, { element_index?, x?, y?, click_method? })
cua.type(app, text, { key_method? })
cua.pressKey(app, key, { key_method? })
cua.scroll(app, direction, element_index, pages?)
cua.drag(app, from_x, from_y, to_x, to_y)
cua.setValue(app, element_index, value)
cua.secondaryAction(app, element_index, action)
cua.listApps()
cua.call(tool, args)        // low-level escape hatch: { text, images }
```

## Example

```
const send = cua.find("Slack", e => e.role === "AXButton" && /send/i.test(e.title || ""));
if (send) { cua.click("Slack", { element_index: send.index }); }
else { write("no send button; state:\n" + cua.getAppState("Slack")); }
```

## Safety

The runtime binds only the Computer Use actions; JavaScriptCore exposes nothing
else (no filesystem, no network). `cua.call` refuses `js`, so a script cannot
re-enter the runtime. The actions it can drive are exactly the ones the discrete
definitions describe (`ToolDefinitions.discrete`).
