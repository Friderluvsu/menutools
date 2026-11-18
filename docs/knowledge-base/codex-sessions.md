# Codex Sessions

Source: `Sources/MenuTools/Features/CodexSessions/` (`CodexSession`, `CodexSessionsManager`) and `Views/Components/CodexSessionsCard.swift`.

This is separate from AI Limits and from Claude / Cursor sessions. Live rows come from running `codex` CLI processes, not ChatGPT.app.

## Where sessions live

`ProcessLookup.liveCodexPids()` walks the kernel process table and keeps pids whose executable basename is `codex` and whose path is not inside `ChatGPT.app`. The working directory comes from `proc_pidinfo` (`PROC_PIDVNODEPATHINFO`).

Optional titles come from the newest `~/.codex/state_*.sqlite` (or `$CODEX_HOME`), table `threads`:

```sql
SELECT cwd, title, preview, updated_at_ms FROM threads WHERE archived = 0
```

The database is opened read-only, with a 200 ms busy timeout, and closed after each read. A missing or busy file still lists the live processes, named after the project folder.

## What counts as live

A `codex` process is live. There is no separate “input needed” flag on the CLI, so every live row is **Running** (green). An ended row is blue. The header counts both. ChatGPT desktop threads are ignored: those files stay around after the app is idle, and they have no generating flag MenuTools can trust.

## When a chat ends

The process exiting is the end. MenuTools stores the pids it has already seen in `~/Library/Application Support/MenuTools/codex-session-watch.json`. When a watched pid is gone, MenuTools:

- posts a notification titled **Codex finished**, body `name · project`
- adds an **Ended** row on the Codex card (blue, so it does not look like a chat that needs input)
- turns the lower-left segment of the menu bar ring blue until that row is checked

A live process turns the lower-right segment green. Codex has no input-needed state. Opening the panel or the Sessions page checks nothing, and the Sessions summary does not check anything either. An unchecked finish keeps the blue row and the blue segment, and stays at the top, until it is checked. A row is checked by clicking it (which also raises the window), by its ✓ button, by the card header's **Mark all checked** button, or by clicking the **Codex finished** notification. A checked row turns grey, with a grey Ended label, and its ✕ removes it. In `codex-session-watch.json` the `seen` flag on an ended row means checked. The uptime slot shows when it finished: `just now`, `4m ago`, `2h ago`, `1d ago`. Unchecked Ended rows stay until checked and removed. Pids loaded from a previous launch that are already dead are dropped on start, so a relaunch does not fire stale alerts.

The watch starts at launch. While any Codex process is live, a pid is still tracked, or the panel is open, the read is every 2 s (tolerance 0.5 s). Otherwise it is every 15 s.

The card header uses ChatGPT.app's icon (bundle `com.openai.codex`) when that app is installed, otherwise the `chevron.left.forwardslash.chevron.right` symbol. The dashboard omits this card when there are no live or ended rows. More than three live+ended rows across all providers collapse to a Sessions summary; click it for this full list.

## Fields the card shows

The row shows the chat name, a project chip, a token badge (`18k tok`, from the thread's rollout log) and uptime. A chevron opens a details drawer (name, project, tokens, in / out, cache, model, context, path, pid, CLI, thread preview). Only one drawer is open across the session cards. Opening it animates the height. Token details: [session-usage.md](session-usage.md).

| Source | Where |
|---|---|
| `threads.title`, else project folder | Title, and the drawer |
| cwd last path component | Project chip |
| `threads.preview` | Drawer |
| process cwd | Drawer, `$HOME` shortened to `~` |
| process pid | Drawer |
| `threads.updated_at_ms` | Uptime when the thread row exists |

A click on a live row walks the parent pid chain and activates the terminal (or other regular app) that owns the process. A click on an Ended row raises a ChatGPT or Codex window whose title matches the project, when that app is running, and checks the row. The chevron does not reveal the app.

## When it runs

`AppState` constructs the manager at launch. `onPopoverDidShow` (one turn after the panel is on screen) only speeds the poll. It checks nothing. Published arrays are replaced only when they differ.
