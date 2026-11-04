# Cursor Sessions

Source: `Sources/MenuTools/Features/CursorSessions/` (`CursorSession`, `CursorSessionsManager`) and `Views/Components/CursorSessionsCard.swift`.

This is separate from AI Limits and from Claude sessions. Cursor does not write a pid file per chat. The live list comes from the composer header table.

## Where sessions live

`~/Library/Application Support/Cursor/User/globalStorage/state.vscdb`, table `composerHeaders`. The query is read-only:

```sql
SELECT value FROM composerHeaders WHERE isArchived = 0 AND isSubagent = 0
```

`value` is a small JSON summary (about 1 KB). `cursorDiskKV` conversation blobs are never opened. The database is opened only while the panel is open, with a 200 ms busy timeout, and closed after each read.

Nothing is listed unless a process named `Cursor` is running. Quit Cursor and the card goes empty even if a header still says the run never finished.

## What counts as live

`unfinishedRunAt` stays set on chats that were interrupted, so it is not enough on its own.

| State | Rule | Row |
|---|---|---|
| Running | `unfinishedRunAt` is set and `conversationCheckpointLastUpdatedAt` (or `lastUpdatedAt`) is under 3 minutes old | **Running** (green) |
| Needs the user | `hasBlockingPendingActions` | **Input needed** (orange), kept for 30 minutes after the last checkpoint |
| Plan | `hasPendingPlan` | **Plan** (orange), same 30 minute window |

Drafts, archived chats and subagents are skipped. Needs-input rows are listed first.

## When a chat ends

MenuTools remembers a chat only after it has seen that chat running (fresh `unfinishedRunAt`). The set is stored in `~/Library/Application Support/MenuTools/cursor-session-watch.json`, so it survives a relaunch during a long task.

On a later read, if that same header is still in the table and `unfinishedRunAt` is gone, the chat finished. MenuTools then:

- posts a notification titled **Cursor finished**, body `name · project`
- adds an **Ended** row on the Cursor card (blue, so it does not look like a chat that needs input)
- turns the lower-left segment of the menu bar ring blue until that row is on screen

Opening the panel clears the blue segment when the row is in the dashboard list. More than three rows collapse to a Sessions summary, and that summary does not count: the segment and the blue row stay until the Sessions page is opened. Ended rows you have already seen turn grey, and the word Ended stays blue. A finish you have not seen keeps the blue row, and stays at the top, until you close the panel after seeing it. Ended rows stay until the x on the row is pressed, so two chats that finish together both remain. The first time a live chat is waiting, MenuTools posts **Cursor needs input** (same body) and, on that same read, turns the top segment orange while the panel stays closed. Orange stays until that chat is no longer waiting. The id is stored in the watch file, so a relaunch does not post again for the same wait. A running chat turns the lower-right segment green. Opening the panel does not clear orange or green. If the same `composerId` becomes live again (another turn in that chat), its Ended row is dropped so the card is not duplicated. Cursor not running does not count as finished: the tracked ids stay until the headers themselves say the run is over.

The watch starts at launch. While Cursor is running, or while the panel is open, the read is every 2 s (tolerance 0.5 s). Otherwise it is every 15 s. That way a second short chat is not missed between polls.

The card header uses Cursor.app's icon when that app is installed, otherwise the `cursorarrow` symbol. Its right side counts rows in the shared colors: green running, orange needs input, gray idle, blue ended. The dashboard omits this card when there are no live or ended rows. More than three live+ended rows across all providers collapse to a Sessions summary; click it for this full list.

## Fields the card shows

The row shows the chat name, the status word, a project chip and uptime. The last-edit subtitle stays off the row. A chevron opens a details drawer (name, project, path, composer id, mode, activity, files changed). Only one drawer is open across the session cards. Opening it animates the height. A click on the row, not the chevron, raises Cursor.

| JSON | Where |
|---|---|
| `name` | Title, and the drawer. Falls back to the project folder. |
| `unifiedMode` | Drawer: Agent, Chat, Plan, … |
| `subtitle` | Drawer, labeled Activity. What the chat last did. |
| `workspaceIdentifier.uri.fsPath` | Project chip is the last path component. The full path is in the drawer, with `$HOME` shortened to `~`. |
| `createdAt` | Uptime, epoch milliseconds. |
| `filesChangedCount` | Drawer, when it is above zero. |
| `composerId` | Drawer. |

Hover also lists those facts. A click raises the Cursor window whose title ends with that project (`DEVELOPMENT.md — menutools`), using Accessibility when it is granted, then activates Cursor. Without Accessibility, Cursor comes forward on whichever window was last used.

## When it runs

`AppState.onPopoverWillShow` reads before the panel lays out. The same timer has already been running since launch: 2 s while Cursor is running, 15 s when it is not. The published arrays are replaced only when the decoded sessions or the ended list differ.
