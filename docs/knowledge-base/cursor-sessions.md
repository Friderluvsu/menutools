# Cursor Sessions

Source: `Sources/MenuTools/Features/CursorSessions/` (`CursorSession`, `CursorSessionsManager`, `CursorCLISessions`) and `Views/Components/CursorSessionsCard.swift`.

This is separate from AI Limits and from Claude sessions. Cursor does not write a pid file per chat. The live list comes from the composer header table.

## Where sessions live

`~/Library/Application Support/Cursor/User/globalStorage/state.vscdb`, table `composerHeaders`. The query is read-only:

```sql
SELECT value FROM composerHeaders WHERE isArchived = 0 AND isSubagent = 0
```

`value` is a small JSON summary (about 1 KB). `cursorDiskKV` conversation blobs are never opened. The database is opened only while the panel is open, with a 200 ms busy timeout, and closed after each read.

Nothing is listed unless a process named `Cursor` is running. Quit Cursor and the card goes empty even if a header still says the run never finished.

## Cursor CLI

The terminal agent (`cursor-agent`, `agent`) keeps its chats out of `state.vscdb`, in `~/.cursor/chats/<md5 of the folder>/<chat id>/`: `meta.json` (title, folder, times) and `store.db` (`meta` and `blobs`; the messages are encrypted). So its state comes from the process (`CursorCLIScanner`):

- **Which chat.** CLI processes run as `node` from `~/.local/share/cursor-agent/versions/…` (the copy Cursor.app keeps for its background worker, under Application Support, is skipped). Each one holds its chat's `store.db` open, found by listing its open files (`PROC_PIDLISTFDS`). That gives the exact chat, even with two CLIs in one folder.
- **Running.** A working CLI redraws its spinner, several percent of a core; at the prompt it measures about 0.1%. CPU above 2% over a poll, or a write to `store.db`, opens a tentative run. It counts, and the row appears, only once the chat gains message blobs (`SELECT count(*) FROM blobs`), so typing a prompt or starting the CLI is never a turn. A long tool call keeps the spinner busy.
- **Finished.** 12 s with neither CPU work nor writes, or the CLI quitting mid-turn, ends the run: the usual **Cursor finished** notification and Ended row. The first sighting of a chat (a new CLI, `/new`, MenuTools starting) is a baseline, never a turn.
- **Not yet.** Needs input: the messages are encrypted, so a waiting CLI reads as finished. A Cursor hook could report it later.

Every open CLI chat is listed, like a Claude or Codex terminal: Running during a turn, Done after one (the notification still goes out, but no Ended row while the chat stays open), Idle before the first. Rows show mode CLI and carry the process id, so Terax can open the terminal from the phone. A click raises the terminal that owns the process. CLI chats are listed whether or not Cursor.app runs.

Cost: no CLI means one process-table walk every 6 s. Per live CLI and poll (every 2 s while one is open): one CPU sample, one open-file listing and two `stat`s; `store.db` is opened (read-write with `query_only`, as for Antigravity) only when it changed. `--cursor-cli-diagnose` prints each live CLI's chat id, project, blob count and CPU share over 6 s, and checks the run rules.

## What counts as live

`unfinishedRunAt` on the header stays set on chats that were interrupted, so it is not enough on its own. Clean in-progress turns (a first `sleep 30`, a long shell tool) often never write that field: Cursor keeps `chatGenerationUUID` on `composerData:<id>` instead and clears it when the turn completes. MenuTools json_extracts that blob (status, `chatGenerationUUID`, `generatingBubbleIds`, `unfinishedRunAt`) only for headers whose checkpoint is under 30 minutes old.

| State | Rule | Row |
|---|---|---|
| Running | `chatGenerationUUID` is set, or `status` is `generating`, or `generatingBubbleIds` is non-empty; **or** `unfinishedRunAt` is set and `conversationCheckpointLastUpdatedAt` (or `lastUpdatedAt`) is under 3 minutes old | **Running** (green) |
| Needs the user | `hasBlockingPendingActions` on the header or `composerData`; **or** an `ask_question` tool bubble whose `toolFormerData.status` / `additionalData.status` is `loading` or `pending` (AskQuestion often never flips the header flag — Cursor notifies from memory) | **Input needed** (orange), kept for 30 minutes after the last checkpoint |
| Plan | `hasPendingPlan` on the header or `composerData` | **Plan** (orange), same 30 minute window |

Drafts, archived chats and subagents are skipped. Needs-input rows are listed first. Conversation message blobs are still never opened. A busy lock on `state.vscdb` keeps the previous live rows instead of clearing the ring.

## When a chat ends

MenuTools remembers a chat only after it has seen that chat running (active generation or fresh `unfinishedRunAt`). The set is stored in `~/Library/Application Support/MenuTools/cursor-session-watch.json`, so it survives a relaunch during a long task.

On a later read, if that same header is still in the table and the active-generation signals are gone (`chatGenerationUUID` cleared and no `unfinishedRunAt`), the chat finished. MenuTools then:

- posts a notification titled **Cursor finished**, body `name · project`
- adds an **Ended** row on the Cursor card (blue, so it does not look like a chat that needs input)
- turns the lower-left segment of the menu bar ring blue until that row is checked

Opening the panel or the Sessions page checks nothing. An unchecked finish keeps the blue row and the blue segment, and stays at the top, until it is checked. The Sessions summary does not check anything either. A row is checked by clicking it (which also raises the Cursor window), by its ✓ button, by the card header's **Mark all checked** button, or by clicking the **Cursor finished** notification. A checked row turns grey, with a grey Ended label, and its ✕ removes it. In `cursor-session-watch.json` the `seen` flag on an ended row means checked. The uptime slot shows when it finished: `just now`, `4m ago`, `2h ago`, `1d ago`. Unchecked Ended rows stay until checked and removed, so two chats that finish together both remain. The first time a live chat is waiting, MenuTools posts **Cursor needs input** (same body) and, on that same read, turns the top segment orange while the panel stays closed. Orange stays until that chat is no longer waiting. The id is stored in the watch file, so a relaunch does not post again for the same wait. A running chat turns the lower-right segment green. Opening the panel does not clear orange or green. If the same `composerId` becomes live again (another turn in that chat), its Ended row is dropped so the card is not duplicated. Cursor not running does not count as finished: the tracked ids stay until the headers themselves say the run is over.

The watch starts at launch. While Cursor is running, or while the panel is open, the read is every 2 s (tolerance 0.5 s). Otherwise it is every 15 s. That way a second short chat is not missed between polls.

The card header uses Cursor.app's icon when that app is installed, otherwise the `cursorarrow` symbol. Its right side counts rows in the shared colors: green running, orange needs input, gray idle, blue to check (unchecked finishes only). The dashboard omits this card when there are no live or ended rows. More than three live+ended rows across all providers collapse to a Sessions summary; click it for this full list.

## Fields the card shows

The row shows the chat name, the status word, a project chip, a context badge (`11% ctx`, from `composerData.contextTokensUsed` / `contextTokenLimit`; see [session-usage.md](session-usage.md)) and uptime. The last-edit subtitle stays off the row. A chevron opens a details drawer (name, project, context, path, composer id, mode, activity, files changed). Only one drawer is open across the session cards. Opening it animates the height. A click on the row, not the chevron, raises Cursor and checks an ended row.

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

`AppState.onPopoverDidShow` reads one turn after the panel is on screen (the read used to sit between the click and the first frame). The same timer has already been running since launch: 2 s while Cursor is running, 15 s when it is not. The published arrays are replaced only when the decoded sessions or the ended list differ.

CLI chats: a failed CPU or open-file probe for a live pid keeps its chat (only a gone pid, or the pid opening another chat, ends it). The pid's chat folder is cached and re-resolved on each process walk (6 s) or when `store.db` disappears; message growth is read as `max(rowid)` on a read-only connection with a 20 ms busy wait (read-write `query_only` fallback).
