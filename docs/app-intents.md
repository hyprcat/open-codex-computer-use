# App Intents (macOS)

When an app provides App Intents, an agent can discover its actions and parameters and call them directly. Apps without a supported action still use the existing GUI tools.

You do not need to create or bind shortcuts. OCU generates an execution template. On first use, review and add it in the system Shortcuts window. New parameter values reuse the template; changes to parameter names, action metadata or signing identity generate another template.

## Usage

Start by listing the app's actions. Discovery does not launch the app or read its windows.

```js
var app = await cua.getApp("Example App", { initialState: false });
nodeRepl.write(await app.listIntents({ limit: 20 }));
```

Choose an `id` and supply values for its `parameters`. The action and parameter below are examples; use the schema returned by discovery.

```js
nodeRepl.write(await app.prepareIntent("Echo", { text: "hello" }));
// Review and add the template in Shortcuts before running it.
nodeRepl.write(await app.runIntent("Echo", { text: "new value" }));
```

The same calls are available from the CLI:

```sh
ocu call list_intents --args '{"app":"Example App","limit":20}'
ocu call run_intent --args '{"app":"Example App","action_id":"Echo","parameters":{"text":"hello"},"prepare":true}'
ocu call run_intent --args '{"app":"Example App","action_id":"Echo","parameters":{"text":"new value"}}'
```

Templates live in `intent-templates/` beside the OCU configuration file, normally `~/.config/ocu/intent-templates/`. They contain parameter names and references. Each execution uses a fresh temporary JSON file and removes it afterward. Installed templates are called by Shortcuts UUID, so renaming does not select another shortcut.

Adding a template and authorizing execution are separate steps. On first execution, Shortcuts may request app access or ask “Allow … to output …?”. Review the content before allowing it. `Allow Once` permits this output; `Always Allow` remembers output approval for that shortcut. `prepareIntent` never executes the action or completes these approvals in advance.

## API and results

| JS API | Native tool | Purpose |
| --- | --- | --- |
| `app.listIntents({ limit, offset })` | `list_intents` | Return actions, parameters, `can_execute` and unsupported reasons. Default 50 items, maximum 100; paginate using `next_offset`. |
| `app.prepareIntent(id, parameters)` | `run_intent`, `prepare: true` | Prepare a template or check whether it is installed; never execute the action. |
| `app.runIntent(id, parameters)` | `run_intent` | Validate parameters and execute an installed template. |

| `status` | Meaning | Next step |
| --- | --- | --- |
| `available` | An action catalog was discovered | Check `can_execute` on each action. |
| `needs_approval` | The template is not prepared or installed | Prepare and confirm installation, or use the GUI. |
| `ready` | The template is installed | It can be invoked. |
| `unavailable` | Unsupported platform, action, parameter type or system tool | Use the GUI when `safe_to_fallback` is true. |
| `busy` | The same template is being prepared or executed | Wait for the current call. |
| `completed` | The system reported success | Read `output`, limited to 64 KiB; larger results set `output_truncated`. |
| `unknown` | Invocation started without a reliable completion result | Check whether the operation happened before retrying. Never automatically repeat it or switch to the GUI. |
| `failed` | The child process could not start | Check the reason. |

Parameters currently accept strings, booleans, integers in JavaScript’s safe range, finite numbers and enum values listed in metadata. Unknown names and incorrect types are rejected; total input is limited to 64 KiB. Required entities, arrays, files, rich text and unsupported return types make an action unavailable. Unsupported optional parameters can be omitted.

This is experimental. Discovery reads the main app bundle's `Metadata.appintents/extract.actionsdata` and currently recognizes JSON `version: 1`. This format is not an Apple public discovery API. Legacy SiriKit definitions, separate extension definitions and future formats are not supported yet. `can_execute` means the schema fits this implementation; system permissions or the app can still prevent execution.

Execution uses the system `shortcuts` command and returns `unknown` if no reliable result arrives within 20 seconds. Waiting for system approval can also time out: the action may already have executed while output approval is pending. Check the prompts and operation before deciding to retry. System prompts require separate handling; OCU does not automatically allow them. Installed templates can be edited in Shortcuts; its public CLI cannot verify their contents. Keep the generated actions and parameter references intact.

## Local integration test

Build the isolated test app with full Xcode installed:

```sh
python3 scripts/build-app-intent-fixture.py
```

Install and launch that app locally so Launch Services can discover `dev.ocu.IntentFixture`. It only echoes test values and writes a temporary test record; it does not access personal apps or data. Then build OCU and run:

```sh
swift build
python3 scripts/test-app-intent-fixture.py --prepare
# Review and add the generated template in Shortcuts.
python3 scripts/test-app-intent-fixture.py
```

Watch for system prompts during the test. Both executions must return their exact inputs. `Allow Once` may prompt again on the second call; choose `Always Allow` if you want to retain output approval for this test template. An unknown result stops the test immediately without retrying. For CLI behavior, see [Apple's command-line guide](https://support.apple.com/guide/shortcuts-mac/apd455c82f02/mac).
