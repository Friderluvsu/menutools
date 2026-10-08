# Troubleshooting

Each entry gives the symptom, the cause in the code, and the fix. Source references point at the files that produce the behaviour.

## Window controls

### Green button goes to full screen instead of filling the screen
- **Cause**: Accessibility is not granted to the running bundle. With no permission no event tap is created, so the click reaches macOS (`WindowManager.desiredEventMask`).
- **Check**: `build/MenuTools.app/Contents/MacOS/MenuTools --window-diagnose` prints `accessibility_trusted=false`.
- **Fix**: System Settings → Privacy & Security → Accessibility, then enable MenuTools. The Windows page in MenuTools shows the status and has a prompt button. Run the signed bundle (`make run` or `/Applications/MenuTools.app`). Do not run a binary from `.build` (its TCC identity differs). Reopen the panel afterwards, because permission is refreshed on open.

### Red button does not quit the app
- Quit on close is off (Settings → Windows).
- Mode is `Last window only` and windows are still open. Minimized windows count as open.
- A full-screen window lives in another Space. The app is kept running while such a window exists.
- Accessibility is not granted (see above).
- The app is in the exclusion list.
- A slow close (for example a "Save changes?" sheet) keeps the window count, so nothing quits. Finish or cancel the sheet.

### Maximize or restore moves the window to a strange place
- The maximize toggle compares the window with the screen that contains its centre. Move the window fully onto the target display and click again.

## AI Limits

### Claude card: "Login expired — run claude"
- **Cause**: The Claude Code OAuth token has expired (`expiresAt` is in the past or less than 30 s away), or the API returned 401. MenuTools never refreshes the token, by design.
- **Fix**: Click **Run** on the row (it opens Terminal running `claude`), or run `claude` yourself. Once Claude Code rewrites its credentials, the next refresh (panel open, or the 5 min timer while the panel is open) picks them up. Cached numbers stay visible, marked stale.

### Claude card: "Token lacks usage scope"
- HTTP 403. Sign in again with `claude`.

### Claude or Codex card: "Rate limited, retry later"
- HTTP 429. The provider is blocked for the `Retry-After` time (at least 60 s, at most 1 h), and the block survives relaunches. Without cached data the row shows `Rate limited — retry in …`. Wait; the refresh button does not bypass this block.

### Codex card: "cached 2h ago" with "Login expired — run codex"
- The online call returned 401. Click **Run** (Terminal, `codex login`).

### Codex card shows numbers that are a few hours old without an error
- The online call failed and the offline log fallback is in use (`~/.codex/sessions/…/rollout-*.jsonl`). Numbers refresh when Codex records a new turn or the online call works again.

### Antigravity card: "Open Antigravity or sign in with agy"
- Neither the IDE language server nor a CLI token was found. Open Antigravity, or run `agy` and sign in.

### Antigravity card: "Login expired — run agy"
- The CLI token has expired and `agy -p /usage` could not refresh it, either because agy is not installed (checked at `~/.local/bin/agy`, `/opt/homebrew/bin/agy`, `/usr/local/bin/agy`) or because it failed. Click **Run** or run `agy`.

### Antigravity card: "Language server did not respond" or "Quota API unavailable"
- The IDE's RPC or the cloud quota API failed. Antigravity falls back to the CLI token on the next refresh. If it persists, restart the IDE.

## Preview and build

### The menu bar app closes when I run `make preview`
- Expected. `scripts/preview.sh` runs `killall MenuTools` before rendering. Start the app again with `make run`. `make run` rebuilds the release bundle first.

### Build fails with SDK or compiler version errors
- The Swift compiler and macOS SDK versions differ. Run `make doctor`, then use `make build` or `make release`. Those scripts apply the compatibility flag. Raw `swift build` does not.

### Launching the app does nothing
- A second copy is already running. The single-instance check in `main.swift` exits quietly. Quit the other copy, then launch again.

## Sleep

### The Mac stays awake (or does not sleep) after MenuTools was force-killed
- A `SIGKILL` skips cleanup, so `pmset disablesleep` may still be set. `caffeinate` itself exits with MenuTools (`-w <pid>`). Launch MenuTools and quit it normally. At launch the app detects `SleepDisabled 1` and restores it on quit. Check the state with `pmset -g | grep SleepDisabled`.

## Shelf and drag-and-drop

### The shelf does not appear when I drag a file
- Settings → General → Shelf: check that Shelf is enabled and "Show on file drag" is on. The global drag monitor is installed only when both are on.
- Only drags whose pasteboard carries a file URL open the shelf.

### The panel stays open after a file drag ends
- By design: a drag that changed the drag pasteboard keeps the panel open through the drop. Click outside once to close it.

### The panel closes when a file dialog opens from it
- A modal dialog with no mouse button held closes the panel through the resign-key rule (`panel-and-drag.md`). The converter reopens the panel after its file chooser. Other dialogs, such as Shelf "Copy to…" from the dashboard card, do not. Use the floating shelf (its header Float button) for those.

### Dragging a file onto the status icon does not open the panel
- The panel springs open only while the panel is closed and at least 0.15 s after it last closed. Drop targets on the icon itself do not accept the file. Drop the file into the panel after it opens.

## Performance

### Idle memory is higher than the baseline
- Check whether the panel was opened in this session: its SwiftUI graph is built on first open. Then measure `vmmap --summary <pid>` physical footprint, not RSS. Compare with `performance.md`. Always-on work is limited to the items in its timer inventory.

## Anti-sleep and battery

### Battery icon looks wrong in one appearance
- Icons are redrawn when `NSApp.effectiveAppearance` changes. Render all styles with `--render-battery-icons <dir>` and compare dark and light (`battery-icons.md`).

## Converter

### Video or audio conversion fails right away
- ffmpeg is missing from the expected places. Install it: the converter expects it in `/opt/homebrew/bin`, `/usr/local/bin`, or `PATH` (see `DEVELOPMENT.md`). `make doctor` reports whether ffmpeg is found. Image conversion uses `sips` and is not affected.
