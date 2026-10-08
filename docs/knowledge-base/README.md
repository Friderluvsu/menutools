# MenuTools Knowledge Base

Focused notes on how MenuTools works, written for maintainers and coding agents. The short rules live in `AGENTS.md` (imported by `CLAUDE.md`). These notes hold the detail: endpoints, state machines, geometry, timings and measurements.

| Note | Covers |
|---|---|
| [ai-limits.md](ai-limits.md) | Claude Code, Codex and Antigravity usage sources: endpoints, headers, response fields, token locations, cache, stale and rollover, back-off, status strings. |
| [battery-icons.md](battery-icons.md) | Menu bar battery renderers: Golden Gate geometry, bar and ring styles, colours, knocked-out digits, dark and light handling. |
| [panel-and-drag.md](panel-and-drag.md) | The panel's interaction state machine: outside press, file drags, spring-loading on the status icon, focus, size. |
| [shelf.md](shelf.md) | Temporary drop shelf: drag detection, floating panel, drag-out, persistence, card. |
| [window-controls.md](window-controls.md) | Green maximize and red quit: event tap, Accessibility requirement, fast path, animation design, quit timing. |
| [performance.md](performance.md) | Timer and watcher inventory, measurement method, baseline and measurement history, open items. |
| [troubleshooting.md](troubleshooting.md) | Symptom → cause → fix for window controls, AI limits, preview and build, sleep, shelf and drag, performance. |

## Conventions
- Facts here are taken from the code. When code and a note disagree, fix the note.
- Never record tokens, Keychain values, account names, plan names or usage numbers. Statuses are fine.
- Measurements are dated and say whether they were reported by a run or spot-checked.
- Keep each note focused on one topic. Link to others rather than repeating.
