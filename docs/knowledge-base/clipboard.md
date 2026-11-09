# Clipboard

History with text, images and file lists, and a plain-paste hotkey. Source: `Sources/MenuTools/Features/Clipboard/` (`ClipboardManager`, `ClipboardHUDView`, `ClipboardHUDWindowController`), `Views/Components/ClipboardItemRow.swift`, `ClipboardCard` / `ClipRow` in `PopoverContentView.swift`, `CarbonHotKeyHelper`.

## HUD

A 480×380 non-activating floating panel, centred on the screen under the pointer. Its root view sits in a `ThemeHost`, so it draws with the selected theme: `ThemeBackdrop` (material, gradient, texture), `controlFill` header and footer, `tileFill` / `hoverFill` / accent rows, the theme's corner scale and panel stroke. The panel's `appearance` follows the theme the same way the main panel's does (catalog themes force dark). Rows are a fixed 30 pt with a fixed-width trailing slot: hovering or selecting swaps the meta text (size or count, age) for the pin and delete buttons in place, so nothing shifts. A text-transform mode was tried here and removed.

## Items

`ClipboardItem.kind` is `text`, `image` or `files`. `text` is always the search key: the text, the full paths joined by `\n` (files), or `""` (image). `contentKey` is the dedupe key (`text`, or `imageHash` for images). Snippets: `Image 1200×800`; files are the file names joined by `, `.

Stored in `Application Support/MenuTools/clipboard_history.json` (old files without `kind` load as text). Saves are coalesced (1 s) onto a serial queue and flushed on quit.

## Capture

The `changeCount` is checked every 1 s (and when the HUD opens). Order, each step gated by a setting:

1. File URLs on the pasteboard (`ClipboardCaptureFiles`) become a files item.
2. A non-empty string becomes a text item (max 2 MB), unless image data is also present and the string is a bare URL (`http`, `https`, `file`, `data`, one line): that is a browser's "Copy Image", so the image wins. Any other text wins over an attached bitmap (spreadsheet cells copy with one).
3. PNG or TIFF data (`ClipboardCaptureImages`) becomes an image item. Only the bytes are taken on the main thread; on the save queue the TIFF is encoded to PNG (skipped when the PNG is over 20 MB, or the TIFF over 80 MB before encoding), hashed (SHA-256), and written as `<uuid>.png` plus a 48 px `<uuid>.thumb.png` in `Application Support/MenuTools/clipboard-images/`.

Same content again moves the existing item to the top (a pinned one keeps its place and only gets a new date). Only the newest 20 unpinned images are kept. Deleting, clearing or trimming an image removes its file and thumb, and drops only that item from the thumbnail cache; image items whose file is missing are dropped on load, and files in the folder that no item references are deleted on load.

Rows load the thumb file (an image without one is decoded at thumbnail size from the full file) and cache it in an `NSCache` by item id. File rows show the Finder icon of the first file, cached by path.

## Paste

- Text: `setString`. Files: the existing paths are written as file URLs (missing ones skipped; if none exist the item is deleted). Image: the PNG file is written as `NSImage` and `.png` data.
- The HUD re-activates the previous app, then posts ⌘V.

## Hotkeys

| Keys | Action |
|---|---|
| ⌥⌘V | Open the HUD (Carbon id 1) |
| ⇧⌥⌘V | Paste the current pasteboard as plain text, no app switch (id 2). Off by default: many apps bind the same keys to "Paste and Match Style", and a global hotkey hides that. |

Plain paste snapshots every pasteboard item's data by type, writes the bare string, waits until no modifier key is held (polled every 20 ms, up to 1 s, so the posted ⌘V is not read as ⇧⌥⌘V), posts ⌘V, and 0.3 s later puts the snapshot back unless something else wrote to the pasteboard in between. A later plain ⌘V therefore still pastes the original rich text, image or files.

`CarbonHotKeyHelper` keeps one handler per id and installs the Carbon event handler once.

## Settings (Settings → General → Clipboard)

UserDefaults: `ClipboardCaptureImages` (on), `ClipboardCaptureFiles` (on), `ClipboardPlainPasteHotkey` (off).
