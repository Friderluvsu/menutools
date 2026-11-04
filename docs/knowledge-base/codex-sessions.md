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
- turns the lower-left segment of the menu bar ring blue until that row is on screen

A live process turns the lower-right segment green. Codex has no input-needed state. Opening the panel clears the blue segment when the row is in the dashboard list. More than three rows collapse to a Sessions summary, and that summary does not count: the segment and the blue row stay until the Sessions page is opened. Ended rows you have already seen turn grey, and the word Ended stays blue. A finish you have not seen keeps the blue row, and stays at the top, until you close the panel after seeing it. Ended rows stay until the x on the row is pressed. Pids loaded from a previous launch that are already dead are dropped on start, so a relaunch does not fire stale alerts.

The watch starts at launch. While any Codex process is live, a pid is still tracked, or the panel is open, the read is every 2 s (tolerance 0.5 s). Otherwise it is every 15 s.

The card header uses ChatGPT.app's icon (bundle `com.openai.codex`) when that app is installed, otherwise the `chevron.left.forwardslash.chevron.right` symbol. The dashboard omits this card when there are no live or ended rows. More than three live+ended rows across all providers collapse to a Sessions summary; click it for this full list.

## Fields the card shows

The row shows the chat name, a project chip and uptime. A chevron opens a details drawer (name, project, path, pid, CLI, thread preview). Only one drawer is open across the session cards. Opening it animates the height.

| Source | Where |
|---|---|
| `threads.title`, else project folder | Title, and the drawer |
| cwd last path component | Project chip |
| `threads.preview` | Drawer |
| process cwd | Drawer, `$HOME` shortened to `~` |
| process pid | Drawer |
| `threads.updated_at_ms` | Uptime when the thread row exists |

A click on a live row walks the parent pid chain and activates the terminal (or other regular app) that owns the process. A click on an Ended row raises a ChatGPT or Codex window whose title matches the project, when that app is running. The chevron does not reveal the app.

## When it runs

`AppState` constructs the manager at launch. `onPopoverWillShow` only speeds the poll and marks ended rows seen. Published arrays are replaced only when they differ.
