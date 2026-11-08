# Claude Sessions

Source: `Sources/MenuTools/Features/ClaudeSessions/` (`ClaudeSession`, `ClaudeSessionsManager`) and `Views/Components/ClaudeSessionsCard.swift`.

This is separate from AI Limits. The usage OAuth token does not describe a running conversation. Claude Code itself writes one JSON file per live process.

## Where sessions live

`$CLAUDE_CONFIG_DIR/sessions/<pid>.json`, or `~/.claude/sessions/<pid>.json` when `CLAUDE_CONFIG_DIR` is unset. The file name is the process id. Claude removes it when that process exits. Files that do not end in `.json` (including the peer `.key` files) are ignored and never opened.

The card header uses Claude.app's icon (`/Applications/Claude.app`) when that app is installed, otherwise the `terminal` symbol. On the right of that header, and on the collapsed Sessions row, a colored count shows the mix: green running, orange needs input, gray idle. Every agent card uses those same colors. A row also carries a matching dot and tint. The dashboard omits this card when there are no live sessions. More than three live+ended rows across all providers collapse to a Sessions summary; click it for this full list.

## Fields the card shows

Decoded with every key optional except `pid` and `sessionId`. Unknown keys are ignored.

The row shows the chat name, the status word, a project chip and uptime. A chevron opens a details drawer (name, project, path, session id, pid, kind, entrypoint, version). Only one drawer is open across the session cards. Opening it animates the height. A click on the row, not the chevron, reveals the terminal.

| JSON | Where |
|---|---|
| `name` | Title, and the drawer. Falls back to the project folder, then the session id. |
| `waitingFor` | Status on the right when the user must act, e.g. "input needed" or "permission prompt". Orange dot, label, and row tint. |
| `status` | Main-loop word only: `busy` (generating), `waiting` (blocked on the user), `idle` (prompt). **Running** (green) when `busy` / `running` / `working`, or when a subagent is still unfinished even if this field is `idle`. **Idle** (gray) only when the main loop is idle and no subagent is running. |
| `cwd` | Project chip is the last path component. The full path is in the drawer, with `$HOME` shortened to `~`. |
| `kind`, `entrypoint`, `version` | Drawer. `cli` is shown as `CLI`. |
| `pid`, `sessionId` | Drawer. |
| `startedAt` | Uptime, epoch milliseconds. |

Hover also lists those facts. A click walks the parent process chain and activates the first regular app (the terminal Claude is running in).

Claude Code writes `status` from the **main** loop (`running` → `busy`, `requires_action` → `waiting`, otherwise `idle`). Waiting on a subagent leaves the main loop idle, so the card also reads `$CLAUDE_CONFIG_DIR/projects/<cwd with / → ->/<sessionId>/subagents/*.meta.json`. A meta file without `"finished": true` counts as active work; the jsonl transcripts are not opened.

## Liveness

`proc_pidpath` must succeed and the path must contain a directory component named `claude`. The shipped binary is named after its version (`2.1.316`), so the process name is not `claude`. A recycled pid that is some other process is not shown.

## When it runs

The watcher and timer start at launch. While a session file is present, or while the panel is open, the read is every 2 s (tolerance 0.5 s). Otherwise it is every 15 s. The watcher sees files appear and disappear. A status rewrite inside an existing file does not change the directory, so the timer covers that. The published array is replaced only when the decoded sessions differ.

The first time a session needs input, MenuTools posts **Claude needs input**, body `name · project`, and on that same read turns the top segment of the menu bar ring orange while the panel stays closed. Orange stays until that session is no longer waiting. The pid is stored in `~/Library/Application Support/MenuTools/claude-session-watch.json`, so a relaunch does not post again for the same wait. A working session turns the lower-right segment green.

## Finished runs (Done)

A Claude process stays open after a task, so the finish is the transition instead: a session that was Running (or waiting on input mid-run) and then holds Idle for 3 s, after a run of at least 10 s, is marked **Done** (blue status, "4m ago" in the uptime slot), posts **Claude finished** (`name · project · ran 12m`) and turns the lower-left (blue) light on until the row is seen, with the same seen / fresh rules as other providers' Ended rows. Done clears when that session starts working again or its process exits. Run starts and Done marks are saved in `claude-session-watch.json`, so a relaunch mid-run still catches the finish. Claude has no separate Ended row.

| Rule | Value |
|---|---|
| Counts as a run | `isWorking`, or `needsInput` once a run has started (a permission prompt is part of the run) |
| Finish | Idle (not working, not waiting) for `idleHold` = 3 s |
| Announced | Run length (start → first idle read) ≥ `minimumRun` = 10 s |
| Cleared | The same pid works again, or the session file goes away |
| Seen | Panel opened with the row inline on the dashboard, or the Sessions page opened (`AppState.acknowledgeEndedSessions`) |
