# Mouse

Settings → Mouse: wheel, buttons, pointer and per-app rules for external mice. Rules summary: `AGENTS.md` → Mouse.

## Files
- `Features/Mouse/MouseSettings.swift`: `MousePrefs` (all options, JSON in UserDefaults `MouseSettings`), `MouseAction`, `KeyCombo`, `MouseButtonBinding`, `MouseAppRule`.
- `Features/Mouse/MouseManager.swift`: MainActor owner. Pushes prefs, frontmost bundle id and the screen-zoom flag into the engine; computes the tap mask; applies or restores the pointer; button capture.
- `Features/Mouse/MouseEventEngine.swift`: the tap thread, wheel handling, smooth-scroll frames, button handling.
- `Features/Mouse/MouseActionRunner.swift`: keystrokes, middle click, Dock actions.
- `Features/Mouse/PointerController.swift`: HID service properties and hot-plug.
- `Views/Components/MouseSettingsPage.swift`: the Scroll, Buttons, Cursor and Apps sub-pages (`MouseSettingsTab` in UserDefaults).

## Event tap
- `cgSessionEventTap`, head insert, default (can consume). Mask: `scrollWheel` when Wheel is on; `otherMouseDown/Up/Dragged` when Buttons is on or a capture is running. Mask 0 (or no Accessibility) stops the thread.
- The thread runs its own CFRunLoop; `stop()` performs the teardown on that loop and waits for it. A timeout or user-input disable re-enables the tap in the callback.
- Config is read once per event from an `OSAllocatedUnfairLock`.

## Wheel
| Step | Rule |
|---|---|
| Filter | `scrollWheelEventIsContinuous == 0`, scroll phase 0, momentum phase 0. Everything else passes. |
| Direction | Sign of `DeltaAxis1/2` (or the fixed-point field). The line count itself is ignored. |
| Ctrl zoom | ⌃ held (not ⌘), vertical tick, screen zoom not using scroll → ⌘= / ⌘−, tick consumed. |
| Shift | ⇧ held and no sideways delta → vertical becomes sideways, ⇧ removed. |
| Command | ⌘ held → × fast gain, ⌘ removed. |
| Acceleration | Same direction within 120 ms grows a streak (max 14): × (1 + acceleration × streak × 0.45). |
| Distance | 48 px × acceleration × gain × speed (sideways speed for the x axis). |
| Output | Smooth off: one pixel event. Smooth on: added to the remaining distance; frames post `remaining × (1 − e^(−dt / (glide / 4)))`, integer pixels with a carried remainder; the timer stops when nothing remains. |

## Buttons
- Button numbers are CGEvent's: 2 middle, 3 back, 4 forward, 5+ extra (shown as "Button N+1").
- Back / Forward are ⌘[ / ⌘], so they work in Finder, Safari, Chrome, Xcode and most editors.
- Space left / right post ⌃← / ⌃→ with the fn and keypad flags at the HID tap; they follow the user's Mission Control shortcuts.
- Shortcut recorder: local key-down monitor while the panel is key; Esc alone cancels.

## Pointer
- Speed is relative to the device's own resolution: 1.0× changes nothing.
- Acceleration uses the macOS scale (0–3) written as IOFixed; "Acceleration off" writes −1 (linear), as LinearMouse does.
- If MenuTools is killed with SIGKILL the changed values stay until the mouse reconnects or the Mac restarts (SIGTERM and Quit restore them).

## Testing
- Layout: `--render-preview <png> --settings -SettingsSection Mouse -MouseSettingsTab Scroll|Buttons|Cursor|Apps`.
- Behaviour needs a real mouse and `make run`: the wheel, the buttons and the pointer cannot be checked from a render.
- BetterMouse lists MenuTools as a possibly interfering app because both use event taps. Turn off the overlapping feature in one of them.
