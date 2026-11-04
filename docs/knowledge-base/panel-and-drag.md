# Panel & Drag: Interaction State Machine

Source: `Sources/MenuTools/App/AppDelegate.swift`, `Sources/MenuTools/Views/PopoverContentView.swift`. Rules summary: `AGENTS.md` → "Panel Interaction Model".

## Why it exists

The panel is a key-capable `NSPanel` without `.nonactivatingPanel` (see AGENTS rule 3). With its default `hidesOnDeactivate`, AppKit would close it on any click elsewhere and on focus loss. Two things must keep it open: a click that is part of a file drag (drop into the converter or the shelf card) and the popover's own focus changes. Plain outside clicks still close it.

## Constants
- Debounce after close: 0.15 s (`togglePanel` and spring-load).
- Ignore outside events for 0.15 s after show (`panelShownAt`).
- Movement threshold for a plain drag: 4 pt.
- Status-button hit area: union of the button rect and the status window frame, inset by −8 pt (`isClickOnStatusButton`).

## States

| State | Meaning |
|---|---|
| Closed | `isPanelOpen == false`, panel hidden, no outside monitor installed. |
| Open | Panel visible, `startOutsideClickMonitor()` installed for `leftMouseDown`, `rightMouseDown`, `leftMouseDragged`, `leftMouseUp`. |
| Press tracking | `outsidePressActive == true`, with the press point, the drag pasteboard `changeCount` at press time, a `moved` flag (over 4 pt) and a `dragged` flag (pasteboard changed). |

`showPanel` → Open. `hidePanel` → Closed. `hidePanel` is idempotent: it runs only when `isPanelOpen` or the window is visible, and it always stops the monitor and calls `onPopoverDidClose`.

## Transitions

| Event | Condition | Action |
|---|---|---|
| Status icon `mouseDown` | any | `isMouseDownOnButton = true`, `togglePanel` (open or close). `mouseUp` / `rightMouseUp` clear the flag. |
| Global `leftMouseDown` outside | not ignored | `beginOutsidePress()`: record point and `changeCount`. |
| Global `rightMouseDown` outside | not ignored | `hidePanel()` at once. |
| Global `leftMouseDragged` | press active, not yet dragged | If `changeCount` changed → `dragged = true` (file drag). Else if moved over 4 pt → `moved = true`. |
| Global `leftMouseUp` | press active | End press. Stay open if `dragged` or `changeCount` changed (file drag, including after the drop). Stay open if `moved` and the release point is inside the panel frame (plain drag ending over the panel). Otherwise `hidePanel()`. |
| `didResignKey` | not ignored, left button held (`NSEvent.pressedMouseButtons & 1`) | Start press tracking if not already active. Decide on mouse up. |
| `didResignKey` | not ignored, no button held (Cmd-Tab, modal dialog) | `hidePanel()` at once. |
| `Esc` in panel | panel is key | `hidePanel()` (key code 53). |
| Drag enters status icon | panel closed, 0.15 s since close | `showPanel(activate: false)`: `orderFrontRegardless`, no `NSApp.activate`, so the drag session is undisturbed. The icon returns `[]` from `draggingEntered`, so it never takes the drop. |
| Drop into panel (converter, shelf card) | panel visible | `focusPanelAfterDrop()`: after one run-loop turn, `NSApp.activate` and `makeKey`, so Esc and clicks work. |
| Converter file chooser closed | panel hidden by resign-key | `reopenPanelIfHidden()` shows the panel again. |

`shouldIgnoreOutsideEvent()` returns true when `isMouseDownOnButton` is set, within 0.15 s of showing, or when the click is on the status button. The status button's own click is always handled by the toggle, never by the monitor.

## Hot path and cost
- The global monitor lives only while the panel is open. Per drag event the work is one `changeCount` read, and it stops once a drag is detected.
- `didResignKey` runs synchronously on the main actor (`MainActor.assumeIsolated`), not through an async `Task`, so it cannot race the status button's mouse-down.

## Panel size
- `PanelHeightKey` reports the natural height of the SwiftUI root. `panelContentHeightChanged` stores it and refits the window on that same turn with `setFrame(..., animate: false)`. The top edge is captured when the panel opens (`anchoredPanelTop`) and height changes keep that edge, so only the bottom moves.
- `showPanel` lays the view out before positioning, so the first frame is correct.
- The hosting view has `sizingOptions = []`. The panel frame is driven only by the reported height.
- The Sessions page caps that height. Its filter stays put, and the list scrolls once the panel would pass `visibleFrame.height - 8`. The dashboard, Settings and stat pages still report their natural height and do not scroll.

## Known gaps and manual checks
- If the drag session swallows the final mouse-up, the panel stays open until the next outside click. The press then restarts normally.
- A modal `NSOpenPanel` opened from the panel with no button held closes it through the resign-key rule. The converter path is handled by `reopenPanelIfHidden`. Other flows are not.
- Not covered by automated tests. Check by hand with `make run`: drag an audio file from Finder onto the converter; drag a file over the status icon with the panel closed; click outside with a plain click and with a right click; press Esc.
