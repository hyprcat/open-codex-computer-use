# PR #74: autonomous App Intent discovery and execution

## Objective
Preserve hyprcat’s original commit and update the existing PR on current main. Agents discover app-provided actions/parameters from installed bundle metadata; users do not bind shortcuts. Keep GUI tools independent.

## Approach
- Read only the requested app bundle’s bounded Metadata.appintents files, report supported metadata versions, discovered schemas and unsupported parameter/platform cases honestly.
- Build a fixed single-App-Intent workflow with metadata-derived descriptor and internally generated input glue. Fresh runtime parameters must not be frozen into the signed template.
- Use the supported Shortcuts CLI and system import confirmation. Execution may separately request app access or output approval. Do not inject code into Apple processes or depend on unentitled private executors. Agent preparation and system confirmation are separate from execution.
- Validate app/intent identity and arguments; preserve the app denylist. Use stable generated templates, restricted cache permissions, verified installed identity/content where possible, deadlines and bounded output. Unknown execution results never permit automatic GUI retry.
- Add native list_intents/run_intent and JS app.listIntents/app.runIntent, including capability detection for older/non-macOS native runtimes.

## Progress
- [x] Integrate current main and retain contributor history.
- [x] Validate metadata, workflow descriptor and dynamic input against a real isolated App Intent fixture.
- [x] Implement discovery, preparation/execution, failure states and JS integration.
- [x] Add meaningful regression tests and bilingual docs/history/release notes.
- [x] Run full checks and real fixture execution; prepare the follow-up changes for #74.

## Validation
Unit parser/schema/template and injectable process tests, full Swift/Node checks, and an isolated fixture with two different runtime inputs. Never run existing personal shortcuts or modify system security protections. Metadata/workflow formats are empirical compatibility surfaces, not public API guarantees. Supported cases must be measured; unsupported/entity cases return a GUI-safe unavailable state before execution.

## Current evidence (2026-10-13)
- Swift 229 tests / 7 skipped / no failures; Node 37 passed; documentation and script syntax checks passed.
- Real JS/native discovery and unprepared-call preflight passed. Signed import works. The isolated fixture returned correct literal parameters in the system editor.
- Human-terminal and agent fixed-text controls succeeded after output approval. Adding a shortcut does not grant output approval; this is documented and included in preparation/failure hints. Started failures remain unknown, never a signal to retry real operations automatically.
- Dynamic fixture calls reached perform with exact parameters, then the system CLI crashed during output coercion for public.utf8-plain-text. Requesting public.plain-text fixes the observed crash.
- On macOS 26.5.1 / Xcode 26.5, native CLI, real JS/native MCP and packaged App Agent paths each passed two different runtime inputs and exact output assertions, including Unicode text, false booleans, integers and numbers. The real-execution gate is satisfied; broader compatibility remains experimental.
- Template version 9's dictionary glue and four parameter bindings match the system editor's exported actions exactly. A separate temporary JSON-text control crashed Shortcuts during import in an AppKit text-layout exception; it was not installed and is not used as proof of execution.
- Full make ci stops on missing baseline repository scaffold files; no unrelated scaffold repair is included.
