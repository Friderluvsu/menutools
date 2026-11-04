# Antigravity Sessions

Source: `Sources/MenuTools/Features/AntigravitySessions/` (`AntigravitySession`, `AntigravitySessionsManager`) and `Views/Components/AntigravitySessionsCard.swift`.

This is separate from AI Limits and from Claude / Cursor / Codex sessions. Live rows come from Antigravity’s conversation summary database while the IDE or the `agy` hub is running.

## Where sessions live

`~/.gemini/antigravity/conversation_summaries.db` (or `$ANTIGRAVITY_CONFIG_DIR/conversation_summaries.db`), table `conversation_summaries`. The query is read-only:

```sql
SELECT conversation_id, title, preview, status, not_fully_idle, killed,
       last_modified_time, last_user_input_time, workspace_uris,
       instr(raw_summary, 'ask_question')
FROM conversation_summaries
```

The database is opened only while Antigravity or `agy` is running, with a 200 ms busy timeout, and closed after each read. The connection is read-write with `PRAGMA query_only=ON`. A read-only connection cannot open this WAL file while the IDE holds it: `sqlite3_open` succeeds and the query then fails, so the scan would look empty and the previous chat would stay on the Ended row. A failed read keeps the previous rows. Killed conversations are skipped.

Nothing is listed unless a process whose path has a component containing `Antigravity` (the IDE bundle is `Antigravity IDE.app`), or whose basename is `agy`, is running. Quit the IDE (and the hub) and the card goes empty even if a row still says the run never finished.

## What counts as live

`status` values look like `CASCADE_RUN_STATUS_*`. MenuTools treats them as:

| State | Rule | Row |
|---|---|---|
| Running | status contains `RUNNING`, `BUSY` or `CANCEL`, or `not_fully_idle` is set | **Running** (green) |
| Needs the user | status contains `WAIT`, `INPUT` or `APPROVAL`, or `raw_summary` contains `ask_question` (the open question form, which leaves status as `RUNNING`) | **Input needed** (orange) |
| Idle | anything else, including `IDLE` / `UNSPECIFIED` with `not_fully_idle` clear | not listed |

## When a chat ends

MenuTools remembers a conversation after it has seen that conversation live. The set is stored in `~/Library/Application Support/MenuTools/antigravity-session-watch.json`, so it survives a relaunch during a long task.

On a later read, if that same row is still in the table and it is no longer live, the chat finished. MenuTools then:

- posts a notification titled **Antigravity finished**, body `name · project`
- adds an **Ended** row on the Antigravity card (blue, so it does not look like a chat that needs input)
- turns the lower-left segment of the menu bar ring blue until that row is on screen

Opening the panel clears the blue segment when the row is in the dashboard list. More than three rows collapse to a Sessions summary, and that summary does not count: the segment and the blue row stay until the Sessions page is opened. Ended rows you have already seen turn grey, and the word Ended stays blue. A finish you have not seen keeps the blue row, and stays at the top, until you close the panel after seeing it. The first time a live conversation is waiting, MenuTools posts **Antigravity needs input** (same body) and, on that same read, turns the top segment orange while the panel stays closed. Orange stays until that conversation is no longer waiting. The id is stored in the watch file. A running conversation turns the lower-right segment green. Opening the panel does not clear orange or green. Ended rows stay until the x on the row is pressed. If the same conversation id becomes live again, its Ended row is dropped so the card is not duplicated. Antigravity not running does not count as finished: the tracked ids stay until the summaries themselves go idle.

The watch starts at launch. While Antigravity is running, or while the panel is open, the read is every 2 s (tolerance 0.5 s). Otherwise it is every 15 s.

The card header uses Antigravity.app's icon when that app is installed, otherwise the `arrow.up.forward.circle` symbol. Its right side counts rows in the shared colors: green running, orange needs input, blue ended. The dashboard omits this card when there are no live or ended rows. More than three live+ended rows across all providers collapse to a Sessions summary; click it for this full list.

## Fields the card shows

The row shows the chat name, the status word, a project chip and uptime. A chevron opens a details drawer (name, project, path, id, preview). Only one drawer is open across the session cards. Opening it animates the height.

| Column | Where |
|---|---|
| `title`, else `preview`, else project folder | Title, and the drawer |
| first `workspace_uris` path | Project chip is the last path component. The full path is in the drawer, with `$HOME` shortened to `~`. |
| `preview` | Drawer |
| conversation id | Drawer |
| `last_modified_time` | Uptime |

A click raises the Antigravity window whose title belongs to that project (`file — project`), using Accessibility when it is granted, then activates the app. The chevron does not raise the window.

## When it runs

`AppState` constructs the manager at launch. `onPopoverWillShow` only speeds the poll and marks ended rows seen. Published arrays are replaced only when they differ.
