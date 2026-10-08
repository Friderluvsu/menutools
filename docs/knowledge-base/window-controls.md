# Window Controls (green maximize, red quit)

Source: `Sources/MenuTools/Features/WindowManager/WindowManager.swift` and `WindowManagerModels.swift`. Settings: `Views/Tabs/SettingsTabView.swift` (Windows page). Rules summary: `AGENTS.md` rule 9.

## What it changes
- **Green button**: instead of entering a full-screen Space, the window fills the visible frame of its screen (menu bar and Dock excluded). A second click restores the previous frame.
- **Red button**: when the last window of an app closes, the app quits. A "Always quit" mode quits on any red click.

Both are opt-in per setting and both are skipped for the apps in the exclusion list (Finder and Desktop Services by default) and for MenuTools itself.

## Requirements
- macOS Accessibility permission for the signed bundle. Without it no event tap is created. The green button then reaches macOS, which opens a full-screen Space, and the red button closes normally.
- `isAccessibilityGranted` starts from `AXIsProcessTrusted()`. It is refreshed on `refreshPermissions()`, which runs when the panel opens and when the app becomes active. The Windows page offers a prompt (`AXIsProcessTrustedWithOptions`, then a refresh one second later) and a link to Privacy & Security → Accessibility.
- `desiredEventMask()` returns nothing without permission, so `updateMonitoring()` removes any existing tap.

## Event tap

- `CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap, …)`.
- Mask: `leftMouseDown` when either feature is on; `leftMouseUp` only when maximize is on (to swallow the partner of a consumed click).
- `updateMonitoring()` is idempotent. It recreates the tap only when the mask changes, and re-enables a tap that the system disabled. `tapDisabledByTimeout` and `tapDisabledByUserInput` trigger `reenableEventTap()`.
- The tap is attached to the main run loop in common modes.

### Fast path (`processEvent`)
1. `leftMouseUp`: if no zoom click is in progress, pass through. Otherwise clear the flag and swallow the event.
2. `leftMouseDown`: clear any stale in-progress flag (a lost mouse-up). If neither feature is on, pass through.
3. `mayHitTrafficLights`: ask the window server for the layer-0 window under the pointer (`mouseEventWindowUnderMousePointer`). Return "no" when the window is MenuTools' own, or when the pointer is more than 160 pt right or 90 pt below the window's top-left corner. Traffic lights only sit there. Anything uncertain falls through.
4. `AXUIElementCopyElementAtPosition` on the system-wide element → `kAXSubroleAttribute` → subrole is `AXZoomButton`, `AXFullScreenButton` or `AXCloseButton`, otherwise pass through.
5. Owner PID (skip own process), `NSRunningApplication(processIdentifier:)`, bundle identifier (skip empty, own, or excluded).
6. Green: set `isZoomClickInProgress`, do the AX work on `axQueue`, and return `nil` (the click is swallowed, so no Space change).
7. Red: pass the click through, and check the window count on `axQueue` (see below).

Only the hit test runs in the tap callback. Every other AX call runs on `axQueue` (`userInteractive`), so the event tap never blocks on another app.

## Green button logic

- `prepareToggleMaximize`: read the window frame (AX), build a key `pid_<title>` (or `pid_<CFHash>` without a title), and hop to the main actor.
- `toggleMaximize`:
  - `targetRect` is the visible frame of the screen holding the window's centre. The screen is looked up in AX coordinates (origin top-left of the primary screen).
  - "Maximized" means every edge is within 30 pt of the target.
  - Maximized: restore the saved frame for the key. Without one, use 80% of the visible frame, centred.
  - Not maximized: save the current frame for the key, then animate to the target.
- Saved frames are kept in `runtime` (`previousFrame` / `setPreviousFrame` / `removePreviousFrame`), so they live as long as the app.

## Animation design

- `animateWindowFrame` cancels any running animation for the same key, then starts a new one.
- Duration 0.22 s, frame interval 16 ms, timer on `animationQueue` (`userInteractive`), so AX IPC never runs on the main thread.
- Ease-out cubic: `1 − (1 − t)³`. Progress is time-based (`DispatchTime.uptimeNanoseconds`). A slow AX write makes frames late, not the whole animation longer.
- Each frame is two AX writes: size, then position (`setFrameFast`). The last frame writes the exact target (`setWindowFrame`) and removes the timer from `animationTimers` only if it is still the current one.
- With "Animate resize" off, the target frame is set once on `animationQueue`.

## Red button logic

- Quit mode `Last window only` (default) or `Always quit`. `QuitOnCloseMode` is persisted under `WindowManager_QuitOnCloseMode`.
- `Always quit`: after 0.2 s, `NSRunningApplication.terminate()`.
- `Last window only`:
  - Before the click, count the app's windows: `kAXWindowsAttribute`. Minimized windows count as open. Windows 10 pt or smaller in either dimension (helper windows) do not count. A failed AX read returns nil, and nil never quits.
  - After 0.2 s, count again. If the count is 0 and `hasFullScreenWindowElsewhere` is false, terminate. That check looks for an off-screen, layer-0 window the size of a display (a full-screen window in another Space). Ordinary off-screen helper windows are ignored.
  - If the count did not drop (a slow close, or a "Save changes?" sheet), check once more after 0.4 s, which is 0.6 s after the click. A cancelled close keeps the count, so nothing quits.

## Settings and defaults

Windows page toggles, all on by default: maximize on green, quit on close, animate resize. Quit mode is `Last window only` by default. Exceptions are stored in `UserDefaults` and listed in Settings. Default exceptions: `com.apple.finder` and `com.apple.desktopservices`. An app-activation observer (`didBecomeActiveNotification`) also refreshes the permission state.

## Verification

- `MenuTools --window-diagnose` prints `accessibility_trusted=<bool> session_tap_created=<bool>` and exits. It is the fastest check for "why does the green button go full screen".
- Manual check with `make run`: green on a plain window (fills the screen, second click restores); green on Finder (unchanged, excluded); red on the last window of a test app (quits about 0.2 s to 0.6 s after the click); red with a hidden helper window present (expected to quit: hidden off-screen helpers are not counted).
