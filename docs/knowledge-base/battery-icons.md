# Battery Menu Bar Icons

Source: `Sources/MenuTools/Features/Battery/BatteryIconRenderer.swift`, `BatteryManager.swift`, and the icon update in `Sources/MenuTools/App/AppDelegate.swift` (`updateStatusItemIcon`).

## Pipeline

1. `BatteryManager` reads the power source with `IOPSCopyPowerSourcesInfo`. It refreshes on power-source notifications, coalesced with a 0.5s delay. It is never polled. Low Power Mode comes from `NSProcessInfoPowerStateDidChange`.
2. Each published property is assigned only when it changes, and `AppState` forwards `battery.objectWillChange`.
3. `AppDelegate.updateStatusItemIcon()` picks the renderer for the `MenuBarIconStyle`. It re-renders only when the style, percentage, charging, Low Power or dark-mode value changed.
4. Dark mode is `NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua`. The status button itself can report `.aqua` over a dark menu bar, so it is not used. A KVO observer on `NSApp.effectiveAppearance` re-runs the update on a system light/dark switch.

Battery icons are full colour (`isTemplate = false`). Every renderer takes `isDarkMode` and picks dark or light values from it.

## Golden Gate (macOS 27 style), `renderGoldenGateBar`

Matched pixel by pixel against a 2x screenshot of the system battery item (dark menu bar, 80%). At 2x the rendered body, terminal, digits and bolt land on the same pixel columns and rows as the system item.

| Element | Value |
|---|---|
| Canvas | 28 × 18 pt |
| Body rect | origin (1.5, 3.0), 23 × 12 pt, no outline |
| Body corners | continuous (squircle) radius 4 pt, clamped to fit the 12 pt height (`continuousRoundedRect`) |
| Charge fill | edge to edge from the left, straight right edge, width `23 × pct / 100` floored to 0.5 pt, clipped to the body |
| Terminal | 1.5 × 4 pt, 1 pt gap after the body, flat left side, rounded right side |

Colours (dark / light). Measured over a black bar: fill 241, empty 116, terminal 139 (of 255).

| Part | Dark | Light |
|---|---|---|
| Charge fill | white 94.5% | black 85% |
| Empty part | white 45% | black 32% |
| Terminal | white 54% | black 38% |
| Low Power Mode fill | `#FFD60A` | `(0.85, 0.608, 0)` |
| ≤ 20% and not on AC | `#FF453A` | `(0.843, 0, 0.082)` |

The empty colour is drawn only right of the fill; the translucent fill must not stack on it.

Digits: SF Pro 11 pt, medium, width `NSFont.Width(rawValue: -0.1)` (between standard and condensed; this matches the system digit width of 5.5 pt and height of 8 pt). Weights between medium and semibold do not interpolate; medium is the closer match. The digits are centred on the body by glyph bounds, 0.25 pt above centre, and drawn with `.destinationOut`, so the menu bar shows through. The font shrinks in 0.5 pt steps until the group fits the body minus 3 pt ("100").

AC power: `AppDelegate` passes `isCharging || isPluggedIn`, because the system shows the bolt even when charging is on hold (for example at an 80% limit).
- With digits (steady state of the system item): a small knocked-out bolt follows the digits 0.75 pt apart, and the pair is centred on the body. The bolt is a 6-point polygon traced from the system item (`smallBoltPath`), 0.625 × digit height wide, overshooting the digits by 0.5 pt at both tips.
- Without digits: the `bolt.fill` symbol at 12.5 pt regular, centred 0.5 pt above the body centre and overhanging it by about 1 pt. Its 1 pt outline is knocked out (`destinationOut` at 16 offsets on a 1 pt circle), then it is filled with the charge colour. The system also shows this large bolt for a moment right after the charger is plugged in.
- There is no green charging fill.

Match quality (mean absolute difference of 8-bit grey over the 46 × 24 px body): 12.8 against the system item at 80% on battery, 13.2 live in the menu bar next to the system item. The remainder is antialiasing on the digits.

`.batteryBarGoldenGate` draws the same icon without digits.

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
- `build/MenuTools.app/Contents/MacOS/MenuTools --render-battery-icons <dir>` writes the styles as PNGs at 2x (the menu bar scale) over a near-black or light background, for example `battery-gg-percent-80-dark` and `battery-gg-bolt-80-dark`. Compare them 1:1 with a screenshot of the system item.
- In the running app, change the style in Settings and compare with the system battery item in both appearances.
