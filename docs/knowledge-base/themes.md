# Themes

Code: `Sources/MenuTools/Views/Theme/`.

| File | Role |
|---|---|
| `AppTheme.swift` | `AppThemeID` (case order = gallery order), `AppTheme` (all values per theme), Classic, `ChartPalette`, `ThemeTexture`, `ThemeManager` (UserDefaults `AppTheme`), `\.appTheme` environment key, `ThemeHost`, `Color(hex:)`. |
| `ThemeCatalog.swift` | The seven themes besides Classic. |
| `ThemeBackdrop.swift` | Panel background: optional `.ultraThinMaterial`, theme gradient, static texture Canvas (`ThemeTexturePainter`). |
| `ThemeEasterEgg.swift` | `ThemeEasterEggLayer` overlay and `ThemeEasterEggPainter` with Classic's egg; other ids go to `drawCatalog`. |
| `CatalogEasterEggs.swift` | `ThemeEasterEggPainter.drawCatalog`: the eggs for the catalog themes. |
| `ThemeGallery.swift` | Settings → Look: Classic as the featured tile, then a four-column grid of swatches (`ThemeSwatch`: backdrop, icon, name in the theme's type). The line under the grid shows the hovered (else selected) theme's name and tagline. |

## Catalogue

| Theme | Kind | Look | Texture | Easter egg |
|---|---|---|---|---|
| Classic (featured) | Original | Glass, system appearance | none | Six-colour stripes sweep, rainbow rim, "hello." |
| Graphite | Minimal | Neutral grey, muted blue-grey accent | none | Box breathing: a dot traces a square, "breathe in / hold / breathe out / hold" |
| Obsidian | Minimal | True black, 0.5pt hairlines, one blue accent, lowercase title | none | A ripple travels through a dot grid, "less is more." |
| Midnight | Professional | Deep navy, calm blue | Faint stars | A crescent moon rises, shooting stars, "make a wish." |
| Carbon | Professional | Square corners, flat greys, IBM-style chart colours | none | Systems check list with OK marks, "all systems nominal" |
| Neon | Professional | Near-black, cyan edges, magenta rim, soft glow | Gradient top edge | A neon sign buzzes on letter by letter, "OPEN LATE" |
| Dusk | Cozy | Indigo evening, lavender, rounded type | Faint skyline | City windows light up, "good evening." |
| Cosmos | Playful | Deep space, violet / pink, rounded type | Nebulae, stars, ringed planet | A saucer beams up a "CPU" cube, "we come in peace." |

## Plumbing
- `PopoverContentView.body` is `ThemeHost { panel }`. `ThemeHost` observes `ThemeManager` and sets `\.appTheme`, `.fontDesign` and `.tint`. `Font.system(size:weight:)` without a design picks up the theme's `fontDesign`; explicit `design: .monospaced` stays.
- Themed readers: `MacToolsCard`, `HoverHighlight`, header, metric tiles, IP chips, quick toggles, converter, task and clipboard rows, anti-sleep picker, session filter bar, shelf card, AI limit rows, stat chips and charts.
- `MacToolsTheme.cardBackground` and the other static colours remain for the Shelf floating panel and legacy views. They are Classic.
- `AppTheme.radius(_:)` scales corner radii (`cornerScale`: Carbon 0, Obsidian 0.6, Cosmos 1.25).
- Forced appearance: `AppDelegate.setupPanel` subscribes to `ThemeManager.$theme` and sets `panel.appearance`, so AppKit-backed controls match the dark themes. Classic follows the system.
- Charts: `StatPalette` reads `ThemeManager.shared.theme.charts`; `UsageChart` takes line width and fill opacity from the palette.

## Easter eggs
- Trigger: five clicks on the header icon within 2 s (`PanelHeader.countSecretTap`) → `ThemeManager.playEasterEgg()`.
- `ThemeEasterEggLayer` runs a `TimelineView(.animation)` for `duration` (5.2 s) and then removes it. Hit testing is off, so the panel stays usable.
- The Settings tab only says "Every theme hides a secret."

## Preview
```bash
build/MenuTools.app/Contents/MacOS/MenuTools --render-preview out.png --theme neon
build/MenuTools.app/Contents/MacOS/MenuTools --render-preview out.png --theme cosmos --egg-at 2.6
build/MenuTools.app/Contents/MacOS/MenuTools --render-preview out.png --settings --theme midnight -SettingsSection Look
```
`--theme` does not save. `-SettingsSection` uses the argument domain, so the saved Settings tab is not changed.
