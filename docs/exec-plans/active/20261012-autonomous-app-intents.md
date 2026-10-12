# PR #74: autonomous App Intent discovery and execution

## Objective
Preserve hyprcat’s original commit and update the existing PR on current main. Agents discover app-provided actions/parameters from installed bundle metadata; users do not bind shortcuts. Keep GUI tools independent.

## Approach
- Read only the requested app bundle’s bounded Metadata.appintents files, report supported metadata versions, discovered schemas and unsupported parameter/platform cases honestly.
- Build a fixed single-App-Intent workflow with metadata-derived descriptor and internally generated input glue. Fresh runtime parameters must not be frozen into the signed template.
- Use the supported Shortcuts CLI and one-time system import confirmation. Do not inject code into Apple processes or depend on unentitled private executors. Agent preparation and system confirmation are separate from execution.
- Validate app/intent identity and arguments; preserve the app denylist. Use stable generated templates, restricted cache permissions, verified installed identity/content where possible, deadlines and bounded output. Unknown execution results never permit automatic GUI retry.
- Add native list_intents/run_intent and JS app.listIntents/app.runIntent, including capability detection for older/non-macOS native runtimes.

## Progress
- [ ] Integrate current main and retain contributor history.
- [ ] Validate metadata, workflow descriptor and dynamic input against a real isolated App Intent fixture.
- [ ] Implement discovery, preparation/execution, failure states and JS integration.
- [ ] Add meaningful regression tests and bilingual docs/history/release notes.
- [ ] Run full checks and real fixture execution, push follow-up commits to #74.

## Validation
Unit parser/schema/template and injectable process tests, full Swift/Node checks, and an isolated fixture with two different runtime inputs. Never run existing personal shortcuts or modify system security protections. Metadata/workflow formats are empirical compatibility surfaces, not public API guarantees. Supported cases must be measured; unsupported/entity cases return a GUI-safe unavailable state before execution.
