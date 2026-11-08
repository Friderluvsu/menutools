# MenuTools Agent Reference

## Overview
MenuTools is a lightweight native macOS Menu Bar application (AppKit + SwiftUI) targeting macOS 14.0+. It provides system monitoring, AI subscription limits (Claude Code, Codex, Antigravity, Cursor), live Claude Code, Cursor, Codex and Antigravity sessions, a temporary file shelf, media conversion (FFmpeg / sips), sleep management (Awake and Closed-lid: `IOPMAssertion` / `pmset`), fan control via AppleSMC, network bypass (VanyaVPN + SpoofDPI), Low Power Mode toggle, clipboard history, window controls (green maximize, red quit on close) and iMessage shortcuts.

Rules live here. Full orientation for a new agent: `docs/AGENT_GUIDE.md`. Long-form details (endpoints, state machines, measurements) live in `docs/knowledge-base/` (index: `docs/knowledge-base/README.md`).

## Project Structure & Architecture

```
Sources/
├── MenuTools/                     # Main Application
│   ├── main.swift                 # Entry point (MainActor isolated) and diagnostic flags
│   ├── App/
│   │   ├── AppDelegate.swift      # NSStatusItem, NSPanel lifecycle, drag-safe outside-press logic
│   │   ├── AppState.swift         # Central coordinator; starts/stops manager polling with the panel
│   │   └── PreviewRenderer.swift  # Offscreen SwiftUI renderer for --render-preview / --render-battery-icons
│   ├── Features/
│   │   ├── AILimits/              # Claude Code / Codex / Antigravity / Cursor limits: fetchers, cache, manager
│   │   ├── ClaudeSessions/        # Live Claude Code sessions from ~/.claude/sessions/<pid>.json
│   │   ├── CursorSessions/        # Live Cursor agent chats from composer headers in state.vscdb
│   │   ├── CodexSessions/         # Live Codex CLI processes; cwd via proc_pidinfo
│   │   ├── AntigravitySessions/   # Live Antigravity chats from conversation_summaries.db
│   │   ├── AntiSleep/             # Awake (IOPMAssertion) and Closed-lid (pmset disablesleep, battery guard)
│   │   ├── Battery/               # IOKit.ps reader & appearance-aware BatteryIconRenderer
│   │   ├── Clipboard/             # History store (JSON), ⌥⌘V hotkey, floating HUD
│   │   ├── FanControl/            # SMCDriver (IOKit AppleSMC) & SMCHelperManager
│   │   ├── iMessage/              # CGEventTap shortcuts (↑/↓, ⌥⌫) while Messages is frontmost
│   │   ├── MediaConverter/        # FFmpeg / sips process wrapper (Video, Audio, GIF, Images)
│   │   ├── NetworkBypass/         # VanyaVPN (scutil) & SpoofDPI daemon manager
│   │   ├── Shelf/                 # Temporary file drop storage: drag monitor, floating panel, drag-out source
│   │   ├── StatusLights/          # Menu bar session lights: styles, renderer, change / open animations
│   │   ├── SystemMonitor/         # CPU, RAM, temperature, network I/O, IP; ProcessLookup
│   │   ├── SystemUtils/           # Eject disks, Empty Trash, auto-reset Google Drive
│   │   ├── UniversalControl/      # Keeps Universal Control enabled when auto-enable is on
│   │   └── WindowManager/         # Green maximize (no Spaces), red quit on close (AX + event tap)
│   ├── Helpers/
│   │   ├── Shell.swift            # Process execution helper (sync, async, privileged)
│   │   └── CarbonHotKeyHelper.swift # Carbon event hotkey registration
│   └── Views/
│       ├── PopoverContentView.swift # Panel root & dashboard sections (no ScrollView)
│       ├── Theme/                 # AppTheme model + Classic, ThemeCatalog, ThemeManager, backdrops, easter eggs, Settings gallery
│       ├── Components/            # Cards, tiles, theme, pickers: AILimitsCard, SessionsDashboardSection, ShelfCard, FanControlPickerView, ...
│       └── Tabs/                  # SettingsTabView is live; other tab files are unreferenced legacy
└── MenuToolsSMCHelper/
    └── main.swift                 # SUID/privileged CLI helper for AppleSMC & pmset
```

Unreferenced legacy files (do not delete without asking the user): `Views/Tabs/ComponentDashboardGrid.swift`, `FeaturesListView.swift`, `SystemToolsTabView.swift`, `NetworkTabView.swift`, `AntiSleepTabView.swift`, `MediaConverterTabView.swift`, `ClipboardTabView.swift`, and `Views/Components/UnifiedSearchPalette.swift`.

## Build & Run Workflows

Always use the project scripts rather than raw `swift build`:

```bash
make doctor      # Check toolchain, SDK, ffmpeg, spoofdpi, and codesign
make build       # Debug build into ./build/MenuTools.app (signed)
make release     # Release build into ./build/MenuTools.app
make run         # Release build, then launch
make install     # Release build, then copy to /Applications
make preview     # Debug build, render build/preview-*.png (kills the running MenuTools)
make dmg         # Package into MenuTools.dmg
make lint        # Run swift-format lint
make format      # Run swift-format in-place
```

`scripts/build.sh` selects the MacOSX15.2 SDK when it is installed, sets the module-cache path, passes `--disable-sandbox`, enables Swift's compatibility flag when the compiler and SDK versions differ, bundles the runtime and signs everything. Raw `swift build` skips all of that.

## Diagnostics Flags

Run the bundle binary (`build/MenuTools.app/Contents/MacOS/MenuTools`), never a `.build` binary.

- `--render-preview <png> [--settings] [--sessions] [--anti-sleep-picker] [--fan-picker] [--sample-tasks] [--open-session-detail <id>]`: renders the panel offscreen at its natural height, then exits. `--sample-tasks` adds sample converter tasks (layout check only). `--sessions` opens the Sessions page. `--open-session-detail` expands that row's details (`claude:83592`, `cursor:<id>`, `cursor-ended:<id>`, and the same shape for Codex and Antigravity). `--theme <id>` renders with that theme without saving it; `--egg-at <seconds>` draws one frame of the theme's easter egg. Append `-SettingsSection Look` to open a Settings page without writing the user's defaults.
- `--render-battery-icons <dir>`: writes the battery icon styles as PNGs.
- `--render-status-lights <png>`: one row per status-light style; columns are quiet, mixed, all on, popping on, turning off, open spin / wave, and all on over a light menu bar. Exits.
- `--window-diagnose`: prints `accessibility_trusted` and whether the session event tap can be created. Exits.
- `--anti-sleep-diagnose`: turns Awake and Closed-lid on and off for real and prints our assertion count and `SleepDisabled` after each step, then exits. It sets `pmset disablesleep 1` for a moment through the helper and restores it.
- `--render-preview … --lid-picker`: opens the Closed-lid duration picker instead of the Awake one.
- `--stat-diagnose`: prints CPU cluster indexes, load, memory pressure, GPU utilization and the top processes. No network addresses. Exits.
- `--ai-limits-diagnose`: prints per-provider status, windows and cache age, never tokens. It reads the Keychain secret in-process, so run it only when asked.
- `--show-popover`: opens the panel at launch (manual testing).
- `--panel-memory-diagnose [seconds]`: prints physical footprint and CPU time at launch, after the panel's monitors, after 10 open/close cycles and while the panel stays open (default 180 s), then quits. Needs no other MenuTools running.

### Important Runtime & Security Rules
1. **Designated Requirement**: `com.frider.MenuTools`. `scripts/build.sh` signs the bundle with this requirement. Never execute `.build/debug/MenuTools` directly; TCC permissions (Accessibility, Input Monitoring) are bound to `/Applications/MenuTools.app` or the signed bundle in `build/`.
2. **Privileged Helper**: `build/MenuTools.app/Contents/Resources/bin/menutools-smc-helper` handles fan control and `pmset` operations (`lowpowermode`, `disablesleep`).
3. **Menu Bar Panel & Zero-Blink Architecture (Immediate-Dispatch Pattern)**:
   - `AppDelegate.swift` uses a custom `NSPanel` subclass (`MenuToolsPanel: NSPanel`) with `override var canBecomeKey: Bool { true }` and `override var canBecomeMain: Bool { true }` positioned at `.popUpMenu` level with `styleMask: [.borderless]` (without `.nonactivatingPanel`, ensuring true key window focus retention and interactive controls). Pressing `Esc` natively closes the panel.
   - The panel is built on first open (`showPanel` calls `setupPanel`), not at launch. `hidesOnDeactivate = false`: AppKit must not hide it on a click elsewhere; the outside-press logic decides instead.
   - Status button uses `@objc(ZeroBlinkStatusBarButton) ZeroBlinkStatusBarButton: NSStatusBarButton`:
     - `mouseDown(with:)` intercepts the click without calling `super.mouseDown(with:)`, suppressing AppKit's `trackMouse` modal loop and completely preventing the cell from rendering the highlighted background capsule (the blink).
     - The panel toggle action is dispatched **immediately on `mouseDown`** (`statusButtonMouseDown()`), matching native macOS menu bar interaction speed and eliminating the asynchronous gap between mouse down and mouse up.
     - `mouseUp(with:)` is a no-op action (`statusButtonMouseUp()`), resetting the interaction flag without dispatching extra toggle calls. `rightMouseDown` toggles; `rightMouseUp` also resets the flag.
     - `draw(_ dirtyRect:)` ensures `cell?.isHighlighted = false` right before `super.draw(dirtyRect)`.
     - `highlight(_:)` and `isHighlighted` are overridden to no-ops.
     - `button.cell` is preserved without unsafe swizzling; highlighting is disabled cleanly via `(button.cell as? NSButtonCell)?.highlightsBy = []` and `showsStateBy = []`.
   - **Double-Toggle & Focus Race Prevention**:
     - `panel.animationBehavior = .none`: eliminates utility window zoom/fade animation flicker when presenting translucent `.ultraThinMaterial` panels.
     - `isMouseDownOnButton` synchronization flag prevents `didResignKeyNotification` and `outsideClickMonitor` from prematurely closing the panel while the status button is processing the click.
     - Geometry check `isClickOnStatusButton(mouseLocation:)` unions the button's screen rect and the full `NSStatusBarWindow` frame expanded with an 8pt inset margin, guaranteeing reliable detection even on notch displays (34–38pt menu bars).
     - `didResignKeyNotification` executes synchronously on `.main` via `MainActor.assumeIsolated` without async `Task` runloop deferral, preventing race conditions with the button's click handler.
     - `togglePanel` enforces a clean 0.15s debounce against accidental rapid double-clicks without delaying normal interaction.
     - `hidePanel()` is idempotent (guarded by `isPanelOpen`), so monitors stop and `onPopoverDidClose` runs even if AppKit already ordered the window out.
4. **Theme Visibility & Native Battery Bar Variations**: Menu bar icons adapt to both macOS Dark and Light modes. Appearance comes from `NSApp.effectiveAppearance`, not the status button. `BatteryIconRenderer` provides:
   - `renderChargeOnly(...)`: Standalone battery charge level without '%' in native macOS system font (13pt monospaced digits), featuring dynamic Apple palettes: Charging Green `#30D158` with bolt, Low Power Yellow `#FFD60A`, Low Battery Red `#FF453A`.
   - `renderBar(...)`: Native classic macOS battery bar (22x11.5pt body, 3.5pt radius, 1.5x4.5pt terminal cap, 2pt cavity inset, Apple system color palettes: Low Power Yellow `#FFD60A`, Low Battery Red `#FF453A`, Charging Green `#30D158` with centered bolt, and optional outer percentage text or pure charge number without '%').
   - `renderGoldenGateBar(...)`: macOS 27 battery, matched pixel by pixel to a 2x screenshot of the system item: solid 23x12pt body with continuous (squircle) 4pt corners and no outline, charge fill edge to edge with a straight cut, detached 1.5x4pt terminal 1pt to the right, digits (SF Pro 11pt medium, width -0.1) knocked out of the body. On AC power (charging or on hold) a small knocked-out bolt follows the digits; without digits a large outlined bolt is drawn. Canvas 28x18pt. Details: `docs/knowledge-base/battery-icons.md`.
   - `renderRing(...)`: Circular dynamic color battery ring with dark/light contrast adaptation.
   - SF Symbols use `.semibold` weight with `isTemplate = true`. Battery renders are full colour (`isTemplate = false`).
5. **Concise UI Philosophy**: All labels and text in Settings and Popovers follow "краткость — сестра таланта": short, scannable titles and details without verbose explanatory paragraphs.
6. **Launch & Termination**: the panel and its SwiftUI graph are built on first open (keeps idle footprint ~11 MB). SIGTERM (`killall`, logout) is routed to `NSApp.terminate` via a `DispatchSourceSignal`, so `applicationWillTerminate` always restores `pmset disablesleep`. Power assertions die with the process, even on SIGKILL.
7. **Startup Tasks**: Routine system maintenance fixes (such as ignoring buggy Google Drive FinderSync plugin) execute silently in the background on startup via `appState.systemUtils.autoResetGoogleDriveHelper()`.
8. **AI Limits** (`Features/AILimits/`): read-only, no extra login. Refreshed on panel open (if older than 2 min) and every 5 min while open.
   - Claude Code: Keychain service discovered by prefix (`Claude Code…credentials`, may carry a CLAUDE_CONFIG_DIR hash suffix), read via `/usr/bin/security find-generic-password -s <service> -w` (fallback `~/.claude/.credentials.json`) → `GET api.anthropic.com/api/oauth/usage` (`anthropic-beta: oauth-2025-04-20`). Never refresh the token ourselves — Claude Code owns rotation. Pro/Max use `five_hour` / `seven_day`. Enterprise uses a dollar pool (**Included**) and `extra_usage` / `spend` (**Spend**) from the same response; do not run `claude /usage` (TUI-only).
   - Codex: `~/.codex/auth.json` → `GET chatgpt.com/backend-api/wham/usage`; offline fallback parses `token_count` events in `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl`.
   - Antigravity: finds `language_server*` process with `--csrf_token`, ports via `lsof`, RPC `GetUserStatus` / `RetrieveUserQuotaSummary` on self-signed `https://127.0.0.1` (trust accepted for loopback only).
     - IDE closed → `agy` CLI login: Keychain `gemini`/`antigravity` (go-keyring, may be `go-keyring-base64:` prefixed; file fallback `~/.gemini/antigravity-cli/antigravity-oauth-token`) → `POST cloudcode-pa.googleapis.com/v1internal:loadCodeAssist` → `retrieveUserQuotaSummary` (fallback `fetchAvailableModels`). Expired token → run `agy -p /usage --output-format json` (agy refreshes its own token); never refresh or write agy's token ourselves.
   - Cursor: the `agent` CLI only (`about --format json`). A bundled hook makes that process also read period usage and strip the email from the JSON. No HTTP calls and no session-database reads. **Included** / **Auto** / **API** come from that usage object; **On-demand** only when a spend cap is set. **Run** opens Terminal on `agent login`.
   - All three are undocumented internal APIs — decode every field as optional.
   - "Login expired" rows show a **Run** button: opens Terminal on `claude` / `codex login` / `agy` (temp `.command` file) so the CLI renews its own login.
   - **Cache**: `Application Support/MenuTools/ai-limits-cache.json` keeps the last good windows, plan, fetch time and back-off. A failed fetch keeps those numbers, marked "cached Xh ago", with the reason shown.
   - **Rollover**: windows whose reset time has passed show 0% (`rolledOver`). Data whose fetch time is over 15 min old (e.g. the Codex log fallback) is marked stale.
   - **Back-off**: HTTP 429 blocks the provider for `Retry-After` (60 s to 1 h, persisted across launches). Other failures back off 60 s, doubling, up to 15 min; background polls skip them. The refresh button is limited to one attempt per 10 s per provider.
   - Endpoints, headers, fields, failure strings: `docs/knowledge-base/ai-limits.md`.
9. **Window Controls & Traffic Lights Engine (vorssaint-style)**:
   - Mouse events on traffic light buttons are intercepted via a session-level event tap (`CGEvent.tapCreate` on `.leftMouseDown` and `.leftMouseUp`).
   - Position is resolved using `AXUIElementCopyElementAtPosition` and matched against `kAXSubroleAttribute` (`AXZoomButton`, `AXFullScreenButton`, `AXCloseButton`).
   - **Green Button (Maximize)**: Matches both `AXZoomButton` and `AXFullScreenButton`. Consumes the click event (`return nil`) so macOS/AppKit never transitions to a separate full-screen Space. Directly resizes and positions the target window to fill the active screen's `visibleFrame` (excluding Dock and Menu Bar) using `kAXPositionAttribute` and `kAXSizeAttribute`. On subsequent click, detects that the window is maximized and restores it to its previous frame.
   - **Red Button (Quit on close)**: When clicking the close button (`AXCloseButton`), computes the open window count via Accessibility API (`kAXWindowsAttribute`, minimized windows count as open), and triggers graceful `NSRunningApplication.terminate()` if it drops to 0 and no off-screen, screen-sized (full-screen Space) window remains in `CGWindowListCopyWindowInfo` (or if configured to `.always` quit). Plain off-screen CG windows are ignored: nearly every app keeps hidden helper windows.
   - **Exclusion List**: Checks target app's bundle identifier against user-defined exceptions (persisted in `UserDefaults`) and ignores MenuTools itself. Default exclusions include Finder (`com.apple.finder`).
   - **Permissions**: Requires macOS Accessibility (AX) permission. When permission is missing, UI reflects status with a direct prompt button. Without it no tap is created, so the green button falls through to macOS full screen and the red button closes normally.
   - Details (tap fast path, animation, quit timing): `docs/knowledge-base/window-controls.md`.

## Awake and Closed-lid (`Features/AntiSleep/`)
- Two independent sessions, two quick tiles. **Awake**: `PreventUserIdleSystemSleep` + `PreventSystemSleep` (AC only), plus `PreventUserIdleDisplaySleep` when "Keep display awake" is on. No admin. Closing the lid sleeps as usual. **Closed-lid** (tile "Lid"): the same system assertions (no display one) plus `pmset disablesleep 1` through the privileged helper, so the Mac keeps running with the lid closed, on battery too. Each has its own duration (∞, 15m–5h) and countdown. They can run together; stopping one leaves the other.
- **Battery guard**: Settings → General → "Closed-lid battery stop" (UserDefaults `AntiSleep_LidBatteryGuard`, default 15%, Off allowed). Unplugged at or below it, Closed-lid will not start and turns itself off (power-source notification), posting "Closed-lid off".
- Only MenuTools' own assertions count. No `caffeinate` is started, and other apps' `caffeinate` (Claude Code runs one) is never adopted or killed. The old launch check did both, which showed Awake as on while nothing held the Mac.
- **Relaunch**: sessions are saved (`AntiSleep_Session`, with the boot time) and resumed on a launch in the same boot; quitting restores `disablesleep 0` until then. Closed-lid resumes only when the helper is installed (no admin prompt at launch). A `SleepDisabled 1` found at launch with no Closed-lid session is restored (helper) or offered as Retry on the Lid tile.
- If the helper cannot disable sleep, Closed-lid turns off and the tile shows a warning ("Closed-lid needs admin") instead of looking active.

## Panel Interaction Model (drag-safe)
- **Outside left press** does not close the panel on press. It records the point and `NSPasteboard(name: .drag).changeCount`. On mouse up the panel closes unless the press became a file drag (drag pasteboard changed) or a plain drag that ended inside the panel.
- **Outside right press** closes at once. Status-icon clicks toggle the panel (0.15s debounce).
- **Focus loss** (`didResignKey`): with the left button held it starts the same press tracking; with no button held (Cmd-Tab, a modal dialog) it closes at once.
- The global mouse monitor runs only while the panel is visible.
- **Spring-load**: dragging files over the status icon opens the panel without activating the app (`showPanel(activate: false)`). The icon accepts no drop (`draggingEntered` returns `[]`); the drop lands in the panel (converter drop zone, shelf card), and `focusPanelAfterDrop()` then takes key focus.
- `reopenPanelIfHidden()` brings the panel back after the converter's file chooser closed it.
- Known limit: a modal dialog opened from the panel with no button held still closes it, except for the converter path.
- Details and state machine: `docs/knowledge-base/panel-and-drag.md`.

## Shelf (`Features/Shelf/`)
- Temporary drop storage. A global `.leftMouseDragged` monitor compares `NSPasteboard(.drag).changeCount` (throttled to 50 ms). Pasteboard types are read once per new drag, and only file drags show the shelf.
- Floating panel: non-activating, never key, `.statusBar` level, top-centre under the menu bar, works over full-screen apps. Sized to content (min 220pt, up to 5 columns; scrolls only beyond 3 rows).
- Files are referenced in place, never copied. Drag-out uses an AppKit `NSDraggingSource`, so the receiving app picks copy or move. Items that were moved or trashed leave the shelf.
- Hiding: a drag with no drop hides about 0.5s after mouse up. After a drop the panel stays until closed or idle (90s; 8s when empty), and never hides while the cursor is over it.
- Persistence: `~/Library/Application Support/MenuTools/shelf.json` (path and date). Missing files are dropped on load. Saves are coalesced onto a serial queue and flushed on quit.
- Settings → General: `ShelfEnabled` and `ShelfShowOnDrag`.
- Details: `docs/knowledge-base/shelf.md`.

## Claude Sessions (`Features/ClaudeSessions/`)
- Live Claude Code processes only. Each running `claude` writes `~/.claude/sessions/<pid>.json` (or `$CLAUDE_CONFIG_DIR/sessions`). The row shows the chat name, status (`waitingFor`, e.g. "input needed"; **Running** while the main loop is busy or a subagent is unfinished, even if the session file says `idle`), a project chip and uptime. Kind, entrypoint, version, path, pid and session id sit in a details drawer opened from the row's chevron. Only one drawer is open. Click a row to bring its terminal forward. Hidden on the dashboard when none are live.
- A session file whose pid is gone, or whose executable path has no `claude` directory component, is skipped. `.key` files are never read.
- The directory watcher and timer stay on after launch: 2 s (0.5 s) while a session file is present or the panel is open, 15 s (4.5 s) otherwise. A session that starts needing input posts a "Claude needs input" notification once per wait. The announced pids are stored in `Application Support/MenuTools/claude-session-watch.json`. A Claude process stays open after a task, so the finish is the transition instead: a session that was Running (or waiting on input mid-run) and then holds Idle for 3 s, after a run of at least 10 s, is marked **Done** (blue status, "4m ago" in the uptime slot), posts **Claude finished** (`name · project · ran 12m`) and turns the lower-left (blue) light on until the row is seen, with the same seen / fresh rules as other providers' Ended rows. Done clears when that session starts working again or its process exits. Run starts and Done marks are saved in `claude-session-watch.json`, so a relaunch mid-run still catches the finish. Claude has no separate Ended row.
- Details: `docs/knowledge-base/claude-sessions.md`.

## Cursor Sessions (`Features/CursorSessions/`)
- Live Cursor agent chats only. Headers live in `~/Library/Application Support/Cursor/User/globalStorage/state.vscdb` (`composerHeaders`). The row shows the chat name, status (Running, or Input needed / Plan), a project chip and uptime. Mode, the last-edit subtitle, path, file count and composer id sit in the details drawer. Click a row to raise the Cursor window whose title ends with that project (`file — project`).
- A chat counts as running when `composerData` still has `chatGenerationUUID` (or `status` is `generating` / `generatingBubbleIds` non-empty), or when `unfinishedRunAt` is set and its checkpoint moved in the last 3 minutes. Clean tool waits (e.g. `sleep 30`) often never set `unfinishedRunAt`; the UUID is what lights green. **Input needed** (orange) when `hasBlockingPendingActions` / `hasPendingPlan` is set, or when an `ask_question` tool bubble is still `loading`/`pending` (AskQuestion often skips the header flag). Approval and plan prompts stay for 30 minutes. Subagents, archived chats and conversation message blobs are not read; `composerData` is only json_extract'd for generation fields on recent headers. A busy SQLite read keeps the previous live rows so the ring does not go blank until the panel opens. Nothing is listed when Cursor is not running. Hidden on the dashboard when there are no live or ended rows.
- A run MenuTools has already seen stays tracked after the panel closes. While Cursor is running the read is every 2 s (0.5 s), otherwise 15 s. When that header's active-generation signals clear (`chatGenerationUUID` gone and no `unfinishedRunAt`), MenuTools posts a "Cursor finished" notification (name and project). The row is marked seen when it is on screen: inline on the dashboard when the panel opens, or on the Sessions page when the dashboard is only a summary. A seen row goes grey and keeps a blue Ended label; one you have not seen stays on the blue row until the panel closes. Each ended row shows when it finished in the uptime slot (`just now`, `4m ago`, `2h ago`). Ended rows stay until dismissed, so two chats that finish together both remain; the same `composerId` going live again drops its Ended row. Quit Cursor does not count as the chat finishing. The first time a live chat is waiting, MenuTools posts "Cursor needs input" once; the id stays in the watch file until that chat is seen not waiting, so a relaunch does not repeat it. The watched ids are stored in `Application Support/MenuTools/cursor-session-watch.json`, so a relaunch mid-task still notices the end.
- Details: `docs/knowledge-base/cursor-sessions.md`.

## Codex Sessions (`Features/CodexSessions/`)
- Live `codex` CLI processes only (not ChatGPT.app). The row shows the chat name (thread title when `~/.codex/state_*.sqlite` has one), a project chip and uptime. Path, pid and the thread preview sit in the details drawer. Click a live row to bring its terminal forward; an Ended row raises ChatGPT/Codex when that app is open. Hidden on the dashboard when there are no live or ended rows.
- The process exiting is the chat ending. MenuTools posts a "Codex finished" notification. Ended rows stay until dismissed. Pids from a previous launch that are already dead are dropped on start. The watched pids are stored in `Application Support/MenuTools/codex-session-watch.json`. Codex has no input-needed state.
- Details: `docs/knowledge-base/codex-sessions.md`.

## Antigravity Sessions (`Features/AntigravitySessions/`)
- Live Antigravity conversations only. Summaries live in `~/.gemini/antigravity/conversation_summaries.db`. The row shows the chat name, status (Running, or Input needed), a project chip and uptime. Path, id and preview sit in the details drawer. Click a row to raise the Antigravity window whose title ends with that project.
- Running / busy / canceling and `not_fully_idle` count as live. Wait / input / approval, and an open `ask_question` form, show as Input needed. Nothing is listed when Antigravity and `agy` are not running. Hidden on the dashboard when there are no live or ended rows.
- A conversation MenuTools has already seen stays tracked after the panel closes. While Antigravity is running the read is every 2 s (0.5 s), otherwise 15 s. When that summary goes idle, MenuTools posts an "Antigravity finished" notification. The row is marked seen when it is on screen: inline on the dashboard when the panel opens, or on the Sessions page when the dashboard is only a summary. Ended rows stay until dismissed; the same conversation id going live again drops its Ended row. Quit Antigravity does not count as the chat finishing. The first time a live conversation is waiting, MenuTools posts "Antigravity needs input" once; the id stays in the watch file until that conversation is seen not waiting. The watched ids are stored in `Application Support/MenuTools/antigravity-session-watch.json`.
- Details: `docs/knowledge-base/antigravity-sessions.md`.

## Themes (`Views/Theme/`)
- 8 themes. Classic (featured, the original look) on top, then a four-column swatch grid: Graphite, Obsidian (minimal), Midnight, Carbon, Neon (professional), Dusk (cozy), Cosmos (playful). All but Classic are dark. The line under the grid names the hovered or selected theme. Picked in Settings → Look; saved in UserDefaults `AppTheme` (a saved id that no longer exists falls back to Classic). Classic lives in `AppTheme.swift`, the rest in `ThemeCatalog.swift`; eggs: `ThemeEasterEgg.swift` (Classic) → `CatalogEasterEggs.swift` (`drawCatalog`).
- `ThemeHost` (inside `PopoverContentView`) is the only observer of `ThemeManager`. It injects `\.appTheme`, `fontDesign` and `tint`. Views read colours through `@Environment(\.appTheme)`; never read `ThemeManager.shared` in a dashboard view (it would not re-render). The stat page's `StatPalette` reads the manager directly because the page is rebuilt on every open.
- A theme sets: backdrop (material and/or gradient), a static Canvas texture, card / control / tile fills, stroke, corner scale, glow, accent, font design, header title, forced appearance (`AppDelegate` sets `panel.appearance`) and the chart palette.
- Easter egg: five quick clicks on the header icon play that theme's Canvas animation for about 5 s. The `TimelineView` exists only while it plays.
- Status colours (session ring and summary border, warnings, AI limit bars) stay semantic and are not themed. The Shelf floating panel and Clipboard HUD keep the Classic look.
- Details: `docs/knowledge-base/themes.md`.

## Performance Rules
- **Panel-scoped polling**: `AppState.onPopoverWillShow` starts and `onPopoverDidClose` stops Network status (5s), Fan speed (2s; a 5s loop only in curve mode when closed), and AI Limits (5 min). System Monitor's 2 s history tick starts at launch and keeps the last 10 minutes of CPU, GPU, memory, temperature and network samples while the panel is closed; opening the panel publishes those numbers on the tiles and does not clear the series. A process walk runs only while the CPU or Memory detail page is open. GPU client times are read only while the GPU page is open.
- **Session watch**: Claude, Cursor, Codex, and Antigravity stay on after launch. 2 s (0.5 s) while that app is live or the panel is open, 15 s (4.5 s) otherwise. Timers run on the common run-loop mode, and an activity keeps App Nap from deferring them until the panel opens. Claude uses "a session file is present" instead of a process name. A chat MenuTools has seen running posts a notification when it finishes. Cursor, Antigravity, and Claude also post once when a chat starts needing input.
- **Menu bar ring**: Settings → General → **Status lights** (UserDefaults `StatusLightsEnabled`, default on). On: the status item shows three colour session lights (`AppState.sessionMarks`) in the picked style (Ring, Dots, Stack, Triad, Bars, Pie; `StatusLightStyle`). Off: the static icon picked in "Menu bar icon" (`updateLegacyStatusItemIcon`, battery or symbol styles, with the alert dot). The input light (top in Ring) turns orange while any session needs input and stays until it does not. Lower right turns green while any session is running. Lower left turns blue for an unseen ended row and clears when that row is on screen. Rows listed on the dashboard count as soon as the panel opens. The Sessions summary does not: the segment and the blue row stay until the Sessions page is opened. Seeing the row turns already-seen ended rows grey (the Ended label stays blue) and leaves the new one on the blue row until the panel closes. Each session refresh posts `sessionMenuMarksChanged` after the rows are stored and paints the ring as a bitmap (the same path as the old alert dot), so a segment appears while the panel stays closed. Quiet segments stay the menu bar color. The battery and symbol icons remain in `updateLegacyStatusItemIcon`; set the flag to false to restore them. With lights on, the same picker is labelled "Panel icon" and changes the panel header only. **Drawing and animation** (`Features/StatusLights/`): `StatusLightsView` is a Core Animation layer tree added to the status button over a transparent placeholder image (which sizes the item); `ZeroBlinkStatusBarButton.layout` keeps it on the image slot. A light turning on pops and sends out a halo, one turning off shrinks and fades; opening the panel spins Ring / Pie / Triad once or runs a wave through Dots / Stack / Bars; "Test" plays a demo. All are CA animations rendered by the render server: no timer and no per-frame bitmaps (swapping `button.image` per frame was throttled by macOS and stuttered). Toggle `StatusLightAnimations`; off under Reduce Motion. `StatusLightsRenderer` draws the same shapes as bitmaps for Settings previews and `--render-status-lights`. On the dashboard the Sessions summary border is a smooth gradient split by the waiting, running, and unchecked-ended counts (orange, green, blue; idle and already-checked ended rows are left out), and one light per such session travels that stroke. An ended row counts here while it is still the blue row in the list. No light when none of those three are present.
- **Always-on watchers**: Clipboard `changeCount` check (1s), the Window Manager event tap (when Accessibility is granted), the Shelf drag monitor (when enabled), and Universal Control file watcher (when auto-enable is on). Battery is event-driven (power-source notifications, 0.5s coalescing) and never polled. The iMessage tap exists only while Messages is frontmost.
- **Timers** set an explicit tolerance with `Timer.publish(every:tolerance:)` or `timer.tolerance`, so the system can coalesce wakeups.
- **Publish only on change**: assign published values only when they differ, so idle ticks never re-render SwiftUI.
- **Event taps stay cheap**: the callback does a window-bounds pre-check, then the Accessibility hit test on a background queue. `mouseUp` is handled only after a consumed zoom click.
- **Observation scope**: each dashboard section observes only its own manager. `DashboardSessionsSection` observes the four session managers. `PopoverContentView` observes nothing. `DashboardView` observes only `DashboardLayoutStore` (changes when the user rearranges).
- **Memory**: measure with `vmmap --summary <pid>` (Physical footprint), not `ps` RSS alone, because RSS includes shared framework pages. Baseline and history: `docs/knowledge-base/performance.md`.

## Dashboard Layout (no scroll)
- Panel width 360pt. Height is the natural content height reported by SwiftUI (`PanelHeightKey`). The top edge stays under the status item, and the height is capped at the screen's visible height.
- The dashboard, stat detail page and Settings never scroll. The Sessions page pins a filter (All, Claude, Cursor, Codex, Antigravity; a provider with no rows is left off) and scrolls the list once it would make the panel taller than the screen. That list keeps a trailing gutter so the scroller does not cover the rows. Settings is split into segmented pages: General, Look (themes and dashboard layout), Windows, Messages, Network. Opening and closing Settings crossfades (`SessionDashboardLayout.pageAnimation`). The five pages are built with Settings and stay mounted; a tab click only changes which page is visible. The settings well stays at the tallest page, so a tab click does not resize the panel.
- CPU, GPU, RAM, TEMP, NET, BAT, DISK and FAN open a detail page. **X** returns, same as Sessions. FAN is the fan control on that page. The fan tile is one column and the disk tile is the other two. LAN and WAN still copy. Detail fields: `docs/knowledge-base/system-stats.md`.
- Session cards with no live or ended rows are omitted. If live+ended rows across all providers exceed 3 (`SessionDashboardLayout.maxInlineRows`), the dashboard shows one **Sessions** summary (counts). Click it for a Sessions page with the full lists; **X** returns like Settings. The pages crossfade. The panel's top edge does not move; only its height changes.
- Order: header (app icon, title, Eject disks, Empty Trash, Settings), then the sections in the user's order from Settings → Look → Layout (`DashboardLayoutStore`, UserDefaults `DashboardLayout` order and `DashboardHidden`). Default: metrics (CPU, GPU, RAM, TEMP, NET, BAT, FAN, DISK; LAN/WAN copy chips) → AI Limits → session cards or Sessions summary → quick toggles (Awake, Lid, Low Power, VPN, SpoofDPI) → converter (last 4 tasks, then "+N more") → shelf → clipboard (3 rows, ⌥⌘V). Rows are dragged (a local `DragGesture`, committed on release; no system drag session, so no floating copy and no Dropzone or Shelf reaction) or moved with the arrows; the eye hides a section; Reset restores the default. Sessions and Shelf still hide themselves when empty or disabled. Preview a layout with `-DashboardLayout '(clipboard, metrics, …)' -DashboardHidden '(converter)'`.
- Per-manager subviews: `MetricsCard` watches System Monitor, `FanTile` watches Fan Control, `BatteryTile` watches Battery, `AILimitsCard` watches AI Limits, `DashboardSessionsSection` watches the four session managers, `ConverterCard` watches the converter, `ShelfSection` watches Shelf, `ClipboardCard` watches Clipboard.
- Keep labels short (see rule 5).
