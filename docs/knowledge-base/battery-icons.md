# Battery Menu Bar Icons

Source: `Sources/MenuTools/Features/Battery/BatteryIconRenderer.swift`, `BatteryManager.swift`, and the icon update in `Sources/MenuTools/App/AppDelegate.swift` (`updateStatusItemIcon`).

## Pipeline

1. `BatteryManager` reads the power source with `IOPSCopyPowerSourcesInfo`. It refreshes on power-source notifications, coalesced with a 0.5s delay. It is never polled. Low Power Mode comes from `NSProcessInfoPowerStateDidChange`.
2. Each published property is assigned only when it changes, and `AppState` forwards `battery.objectWillChange`.
3. `AppDelegate.updateStatusItemIcon()` picks the renderer for the `MenuBarIconStyle`. It re-renders only when the style, percentage, charging, Low Power or dark-mode value changed.
4. Dark mode is `NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua`. The status button itself can report `.aqua` over a dark menu bar, so it is not used. A KVO observer on `NSApp.effectiveAppearance` re-runs the update on a system light/dark switch.

Battery icons are full colour (`isTemplate = false`). Every renderer takes `isDarkMode` and picks dark or light values from it.

## Golden Gate (macOS 27 style), `renderGoldenGateBar`

The code comment says the geometry was measured from the system item: a 23 × 12 pt body and a 1.5 × 4.5 pt terminal.

| Element | Value |
|---|---|
| Canvas | 28 × 18 pt |
| Body rect | origin (1.5, 3.0), 23 × 12 pt |
| Body corner radius | 4.0 pt |
| Body outline | `insetBy(0.5)`, 1.0 pt stroke |
| Terminal cap | 1.5 × 4.5 pt at `bodyRect.maxX + 0.75`, vertically centred, 0.75 pt radius |
| Charge area | body inset by 1.5 pt |
| Fill width | `innerWidth × pct / 100`, minimum 2 pt when pct > 0 |
| Fill corner radius | `min(2, fillWidth / 2)` |

Colours:

| State | Fill (dark / light) | Ink on fill |
|---|---|---|
| Low Power Mode | `#FFD60A` / `(0.85, 0.608, 0)` | black |
| ≤ 20% and not charging | `#FF453A` / `(0.843, 0, 0.082)` | white |
| Charging | `#30D158` / `(0.141, 0.686, 0.282)` | black |
| Normal | white 95% / black 85% | black (dark), white (light) |

Empty body: white 42% (dark) or black 22% (light). Rim: white 18% (dark) or black 30% (light). Ink on the empty part: white (dark) or black (light).

Digits and bolt: the percentage (`showPercentInside`) is drawn in `systemFont(9.5, .bold, .rounded)`. A `bolt.fill` symbol (6.5 pt, bold) appears while charging, with a 1 pt gap before the number. The group is centred on the body. The content is drawn twice: clipped to the fill with the on-fill ink, then clipped to "body minus fill" (even-odd) with the on-empty ink. This is what makes the digits look knocked out of the charge.

Without the percentage and without charging, only the body, fill and cap are drawn.

## Native bar, `renderBar`
- Canvas 27 × 18 pt, or wider when text is drawn.
- Body 22 × 11.5 pt at y 3.25, outline 1.1 pt, corner radius 3.5 pt.
- Cap 1.5 × 4.5 pt at `maxX + 1.2`, y 6.75.
- Fill minimum 1.5 pt. Text uses monospaced digits, 11.5 pt. Bolt symbol 6.8 pt, bold.

## Charge only, `renderChargeOnly`
- Text in monospaced digits, 13 pt, with an optional `bolt.fill` (9 pt, bold) before it when charging. No battery outline.
- Colours follow the same Low Power, low and charging palette.

## Ring, `renderRing`
- Canvas 18 × 18 pt, radius 6.8 pt, colour arc by level.
- Charging shows a 7 × 9 pt bolt at the centre. The optional number is monospaced digits, 6.5 pt, bold.

## Verifying
- `build/MenuTools.app/Contents/MacOS/MenuTools --render-battery-icons <dir>` writes the styles as PNGs (for example `battery-charge-85-dark`).
- In the running app, change the style in Settings and compare with the system battery item in both appearances.
