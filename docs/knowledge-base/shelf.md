# Shelf

Temporary drop storage, in the spirit of NotchDrop, Dropover and Yoink. Source: `Sources/MenuTools/Features/Shelf/` (`ShelfManager`, `ShelfPanelController`, `ShelfDragSource`) and `Sources/MenuTools/Views/Components/ShelfCard.swift`.

## Components

| Type | Role |
|---|---|
| `ShelfManager` (`@MainActor`, `shared`) | Items, persistence, global drag detection, drop handling, file actions. |
| `ShelfPanelController` / `ShelfPanel` | Floating, non-activating panel at the top centre of the screen. |
| `ShelfPanelView` | SwiftUI grid of tiles inside the floating panel. |
| `ShelfDragSource` (`NSViewRepresentable`) | AppKit `NSDraggingSource` overlay for drag-out, right-click menus and double-click. |
| `ShelfCard` | Compact card in the dashboard (and `ShelfSection` wrapper). |

`ShelfItem` holds `id`, `url`, `name` and `addedAt`. Files are referenced in place.

## Drag detection

- A global `.leftMouseDragged` monitor runs while the shelf is enabled and "Show on file drag" is on (`start()` / `updateDragMonitor()`).
- `handleGlobalDrag` throttles to one check per 50 ms. It compares `NSPasteboard(name: .drag).changeCount` (one integer compare). Only when the count changes does it read `types`, and it proceeds only if `.fileURL` is present.
- A file drag sets `isFileDragActive`, shows the floating shelf if it is hidden (`panelShownByDrag = true`), and adds a global `.leftMouseUp` / `.leftMouseDown` monitor. Mouse-down is a fallback reset if the drag's mouse-up is swallowed.
- Global mouse monitors need no Accessibility or Input Monitoring permission.

## Hiding

- A drag that ends without a drop: `endFileDrag` waits about 0.5 s for dropped URLs to arrive, then hides the panel.
- After a drop, or when the user opened the shelf manually, the panel stays. It hides when:
  - the x button is pressed (`hide()`), or
  - it has been idle for 90 s (8 s when empty). A single one-shot `DispatchWorkItem` re-arms itself while the cursor is over the panel or a drag is active.
- Items stay on the shelf when the panel hides.

## Panel

- `NSPanel` with `.borderless` and `.nonactivatingPanel`. `canBecomeKey` and `canBecomeMain` are false, so it never takes focus.
- Level `.statusBar`; collection behaviour `canJoinAllSpaces`, `fullScreenAuxiliary`, `stationary`, `ignoresCycle`. It shows over full-screen apps.
- Top centre of the screen, 6 pt below the visible frame's top. Resized to SwiftUI's `fittingSize` on show and on each change (`contentDidChange`, one run-loop turn later).
- `.ultraThinMaterial` background, 14 pt continuous corners.
- Width at least 220 pt, up to 5 columns. The grid scrolls only beyond 3 rows.
- A drag-all handle appears when there are 2 or more items.

## Moving files out

- Dragging uses `ShelfDragSourceView` (an `NSDraggingSource`), not SwiftUI `.onDrag`. The receiving app decides copy or move from the standard modifiers.
- The offered operations are `copy`, `move`, `link`, `generic` and `delete` for drops outside the app, and `copy` only inside it. Finder applies its usual rules to the modifiers.
- `dragOutEnded` runs when the drag ends. It refreshes the drag pasteboard baseline (so the drag-out is not mistaken for a new file drag), then calls `removeMissing()` now and again after 1 s. Files that were moved or trashed drop off the shelf.
- Item right-click menu: Open, Show in Finder, Copy to…, Move to…, Remove.
- Drag-all menu: Copy All to…, Move All to…, Clear.
- Copy and Move choose a folder with `NSOpenPanel` (directories only, create allowed), then run on a detached task. A name clash gets a ` 2` (then ` 3`…) suffix before the extension. Only files that really moved are removed from the shelf. Errors show an `NSAlert`.
- Double-click opens the file.

## Adding items

- `handleDrop(_:)` accepts `NSItemProvider`s carrying `public.file-url`. The card's `onDrop(of: [.fileURL])` uses it.
- `add(urls:)` normalises URLs (resolves `/.file/id=` references), drops duplicates by path, skips missing files and returns the number added.
- A drop during a drag, or while a drop decision is pending, marks `droppedDuringDrag`, so the panel is kept.

## Persistence

- File: `~/Library/Application Support/MenuTools/shelf.json`, a JSON array of `{ path, addedAt }`.
- Loaded at init. Entries whose files are gone are dropped, and the file is rewritten if anything was dropped.
- Saves are coalesced: several mutations in one run-loop turn produce one write on a serial queue (`MenuTools.ShelfSave`). `stop()` (called on quit from `applicationWillTerminate`) flushes synchronously.

## Settings and API

- Settings → General → Shelf: `Toggle` for `ShelfEnabled` (default on) and `Toggle` for `ShelfShowOnDrag` (default on, disabled when the shelf is off).
- Public surface: `items`, `add(urls:)`, `remove(id:)`, `clear()`, `removeMissing()`, `handleDrop(_:)`, `showPanel()`, `hidePanel()`, `togglePanel()`, `open(_:)`, `reveal(_:)`, `copy(_:)`, `move(_:)`. Read-only published: `isFileDragActive`, `isPanelVisible`.
- Lifecycle: `AppDelegate.applicationDidFinishLaunching` calls `start()`. `applicationWillTerminate` calls `stop()`.

## Dashboard card

- Empty: about 32 pt tall, one line: the label "Shelf" and "Drop files to hold them" (`Release to add` while a file is over it), with an accent outline on drop.
- With items: about 60 pt. Header with the count, drag-all (2 or more items), Float (shows or hides the floating shelf) and Clear. Then one row of chips that can be dragged out.
- More than 4 items: 3 chips and a `+N` chip that opens the floating shelf. The card never scrolls.

## Verification status

The drag-detection approach follows boring.notch's `DragDetector`. These behaviours depend on macOS delivering events during another app's drag session, and they have been reviewed rather than verified on hardware:
- global `.leftMouseDragged` and `.leftMouseUp` still fire during a Finder drag;
- a window shown mid-drag accepts the drop;
- Finder reports the drop result late or generically, so moved or trashed items are found by the post-drag `removeMissing()` checks;
- the hover-only remove (x) on floating tiles sits over the AppKit drag overlay. Right-click Remove always works.

Check by hand: drag a file over the status icon (the panel should spring open), drop into the shelf, drag a chip out to another app with Option and without it, and trash a dragged-out file.
