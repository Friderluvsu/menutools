# MenuTools Knowledge Base

Focused notes on how MenuTools works, written for maintainers and coding agents. Start with the full orientation in [`docs/AGENT_GUIDE.md`](../AGENT_GUIDE.md). The short rules live in `AGENTS.md` (imported by `CLAUDE.md`). These notes hold the detail: endpoints, state machines, geometry, timings and measurements.

| Note | Covers |
|---|---|
| [ai-limits.md](ai-limits.md) | Claude Code, Codex, Antigravity and Cursor usage sources: endpoints, headers, response fields, token locations, cache, stale and rollover, back-off, status strings. |
| [claude-sessions.md](claude-sessions.md) | Live Claude Code sessions: `~/.claude/sessions/<pid>.json`, which fields the card shows, liveness check, panel polling. |
| [cursor-sessions.md](cursor-sessions.md) | Live Cursor agent chats: composer headers, running and input-needed rules, fields the card shows. |
| [codex-sessions.md](codex-sessions.md) | Live Codex CLI processes: pid table, cwd, optional `state_*.sqlite` titles, process-exit ended watch. |
| [antigravity-sessions.md](antigravity-sessions.md) | Live Antigravity conversations: `conversation_summaries.db`, running / input-needed rules, ended watch. |
| [battery-icons.md](battery-icons.md) | Menu bar battery renderers: Golden Gate geometry, bar and ring styles, colours, knocked-out digits, dark and light handling. |
| [panel-and-drag.md](panel-and-drag.md) | The panel's interaction state machine: outside press, file drags, spring-loading on the status icon, focus, size. |
| [shelf.md](shelf.md) | Temporary drop shelf: drag detection, floating panel, drag-out, persistence, card. |
| [window-controls.md](window-controls.md) | Green maximize and red quit: event tap, Accessibility requirement, fast path, animation design, quit timing. |
| [mouse.md](mouse.md) | Mouse wheel smooth scroll and modifiers, button actions, pointer speed via HID properties, per-app rules, testing. |
| [performance.md](performance.md) | Timer and watcher inventory, measurement method, baseline and measurement history, open items. |
| [system-stats.md](system-stats.md) | Clickable CPU, memory, temperature, network and battery details: what each page shows and where the numbers come from. |
| [pixel-shimmer.md](pixel-shimmer.md) | SymVibe `.sf-face` city-lights pixel recipe (tried on running rows / Awake, then removed). |
| [themes.md](themes.md) | Panel themes: catalogue, what each theme changes, environment plumbing, easter eggs, preview flags. |
| [troubleshooting.md](troubleshooting.md) | Symptom → cause → fix for window controls, AI limits, preview and build, sleep, shelf and drag, performance. |

## Conventions
- Facts here are taken from the code. When code and a note disagree, fix the note.
- Never record tokens, Keychain values, account names, plan names or usage numbers. Statuses are fine.
- Measurements are dated and say whether they were reported by a run or spot-checked.
- Keep each note focused on one topic. Link to others rather than repeating.
