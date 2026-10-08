# MenuTools Agent Reference

## Overview
MenuTools is a lightweight native macOS Menu Bar application (AppKit + SwiftUI) targeting macOS 14.0+. It provides system monitoring, AI subscription limits (Claude Code, Codex, Antigravity), a temporary file shelf, media conversion (FFmpeg / sips), sleep management (`IOPMAssertion` / `pmset`), fan control via AppleSMC, network bypass (VanyaVPN + SpoofDPI), Low Power Mode toggle, clipboard history, window controls (green maximize, red quit on close) and iMessage shortcuts.

Rules live here. Long-form details (endpoints, state machines, measurements) live in `docs/knowledge-base/` (index: `docs/knowledge-base/README.md`).

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
│   │   ├── AILimits/              # Claude Code / Codex / Antigravity limits: fetchers, cache, manager
│   │   ├── AntiSleep/             # IOPMAssertion + caffeinate + lid sleep prevention
│   │   ├── Battery/               # IOKit.ps reader & appearance-aware BatteryIconRenderer
│   │   ├── Clipboard/             # History store (JSON), ⌥⌘V hotkey, floating HUD
│   │   ├── FanControl/            # SMCDriver (IOKit AppleSMC) & SMCHelperManager
│   │   ├── iMessage/              # CGEventTap shortcuts (↑/↓, ⌥⌫) while Messages is frontmost
│   │   ├── MediaConverter/        # FFmpeg / sips process wrapper (Video, Audio, GIF, Images)
│   │   ├── NetworkBypass/         # VanyaVPN (scutil) & SpoofDPI daemon manager
│   │   ├── Shelf/                 # Temporary file drop storage: drag monitor, floating panel, drag-out source
│   │   ├── SystemMonitor/         # CPU, RAM, temperature, network I/O, IP; ProcessLookup
│   │   ├── SystemUtils/           # Eject disks, Empty Trash, auto-reset Google Drive
│   │   ├── UniversalControl/      # Keeps Universal Control enabled when auto-enable is on
│   │   └── WindowManager/         # Green maximize (no Spaces), red quit on close (AX + event tap)
│   ├── Helpers/
│   │   ├── Shell.swift            # Process execution helper (sync, async, privileged)
│   │   └── CarbonHotKeyHelper.swift # Carbon event hotkey registration
│   └── Views/
│       ├── PopoverContentView.swift # Panel root & dashboard sections (no ScrollView)
│       ├── Components/            # Cards, tiles, theme, pickers: AILimitsCard, ShelfCard, FanControlPickerView, ...
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

- `--render-preview <png> [--settings] [--anti-sleep-picker] [--fan-picker] [--sample-tasks]`: renders the panel offscreen at its natural height, then exits. `--sample-tasks` adds sample converter tasks (layout check only).
- `--render-battery-icons <dir>`: writes the battery icon styles as PNGs.
- `--window-diagnose`: prints `accessibility_trusted` and whether the session event tap can be created. Exits.
- `--ai-limits-diagnose`: prints per-provider status, windows and cache age, never tokens. It reads the Keychain secret in-process, so run it only when asked.
- `--show-popover`: opens the panel at launch (manual testing).

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
   - `renderGoldenGateBar(...)`: macOS 27 Golden Gate battery, measured from the system item: 23x12pt body, 4pt radius, 1.5x4.5pt terminal, translucent body, charge fill, percentage knocked out of the fill. Canvas 28x18pt. Details: `docs/knowledge-base/battery-icons.md`.
   - `renderRing(...)`: Circular dynamic color battery ring with dark/light contrast adaptation.
   - SF Symbols use `.semibold` weight with `isTemplate = true`. Battery renders are full colour (`isTemplate = false`).
5. **Concise UI Philosophy**: All labels and text in Settings and Popovers follow "краткость — сестра таланта": short, scannable titles and details without verbose explanatory paragraphs.
6. **Launch & Termination**: the panel and its SwiftUI graph are built on first open (keeps idle footprint ~11 MB). SIGTERM (`killall`, logout) is routed to `NSApp.terminate` via a `DispatchSourceSignal`, so `applicationWillTerminate` always restores `pmset disablesleep`; `caffeinate` runs with `-w <our pid>` and dies with the app even on SIGKILL.
7. **Startup Tasks**: Routine system maintenance fixes (such as ignoring buggy Google Drive FinderSync plugin) execute silently in the background on startup via `appState.systemUtils.autoResetGoogleDriveHelper()`.
8. **AI Limits** (`Features/AILimits/`): read-only, no extra login. Refreshed on panel open (if older than 2 min) and every 5 min while open.
   - Claude Code: Keychain service discovered by prefix (`Claude Code…credentials`, may carry a CLAUDE_CONFIG_DIR hash suffix), read via `/usr/bin/security find-generic-password -s <service> -w` (fallback `~/.claude/.credentials.json`) → `GET api.anthropic.com/api/oauth/usage` (`anthropic-beta: oauth-2025-04-20`). Never refresh the token ourselves — Claude Code owns rotation.
   - Codex: `~/.codex/auth.json` → `GET chatgpt.com/backend-api/wham/usage`; offline fallback parses `token_count` events in `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl`.
   - Antigravity: finds `language_server*` process with `--csrf_token`, ports via `lsof`, RPC `GetUserStatus` / `RetrieveUserQuotaSummary` on self-signed `https://127.0.0.1` (trust accepted for loopback only).
     - IDE closed → `agy` CLI login: Keychain `gemini`/`antigravity` (go-keyring, may be `go-keyring-base64:` prefixed; file fallback `~/.gemini/antigravity-cli/antigravity-oauth-token`) → `POST cloudcode-pa.googleapis.com/v1internal:loadCodeAssist` → `retrieveUserQuotaSummary` (fallback `fetchAvailableModels`). Expired token → run `agy -p /usage --output-format json` (agy refreshes its own token); never refresh or write agy's token ourselves.
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

## Performance Rules
- **Panel-scoped polling**: `AppState.onPopoverWillShow` starts and `onPopoverDidClose` stops System Monitor (2s), Network status (5s), Fan speed (2s; a 5s loop only in curve mode when closed) and AI Limits (5 min).
- **Always-on watchers**: Clipboard `changeCount` check (1s), the Window Manager event tap (when Accessibility is granted), the Shelf drag monitor (when enabled), and Universal Control file watcher (when auto-enable is on). Battery is event-driven (power-source notifications, 0.5s coalescing) and never polled. The iMessage tap exists only while Messages is frontmost.
- **Timers** set an explicit tolerance with `Timer.publish(every:tolerance:)` or `timer.tolerance`, so the system can coalesce wakeups.
- **Publish only on change**: assign published values only when they differ, so idle ticks never re-render SwiftUI.
- **Event taps stay cheap**: the callback does a window-bounds pre-check, then the Accessibility hit test on a background queue. `mouseUp` is handled only after a consumed zoom click.
- **Observation scope**: each dashboard section observes only its own manager. `PopoverContentView` observes nothing.
- **Memory**: measure with `vmmap --summary <pid>` (Physical footprint), not `ps` RSS alone, because RSS includes shared framework pages. Baseline and history: `docs/knowledge-base/performance.md`.

## Dashboard Layout (no scroll)
- Panel width 360pt. Height is the natural content height reported by SwiftUI (`PanelHeightKey`). The top edge stays under the status item, and the height is capped at the screen's visible height.
- The dashboard and Settings never scroll. Settings is split into segmented pages: General, Windows, Messages, Network.
- Order: header (app icon, title, Eject disks, Empty Trash, Settings) → metrics (CPU, RAM, TEMP/FAN, NET, BAT; LAN/WAN copy chips) → AI Limits → quick toggles (Awake, Low Power, VPN, SpoofDPI) → converter (last 4 tasks, then "+N more") → shelf → clipboard (3 rows, ⌥⌘V).
- Per-manager subviews: `MetricsCard` watches System Monitor, `FanTile` watches Fan Control, `BatteryTile` watches Battery, `AILimitsCard` watches AI Limits, `ConverterCard` watches the converter, `ShelfSection` watches Shelf, `ClipboardCard` watches Clipboard.
- Keep labels short (see rule 5).
