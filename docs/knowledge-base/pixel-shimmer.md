# Pixel shimmer (SymVibe `.sf-face`)

Reference for recreating the city-lights pixel animation from SymVibe’s pricing **Get Started** button (`.sf-face` with an `.sf-canvas`). MenuTools tried it on running session rows and the active Awake toggle, then removed it. This note keeps the recipe.

Source page: `https://www.symvibe.com/#pricing` (inspect `[data-sf] .sf-face` / inline script that calls `drawCity`).

## Look

- Dark warm face behind the dots: `rgba(36, 30, 25, 0.9)` plus a soft white top gradient (`opacity 0.06` → `0` at 48% height).
- Pixel colour on the site: `#FF8038`, drawn with `globalCompositeOperation = 'lighter'` (SwiftUI: `.plusLighter`).
- Dots are small squares on a grid, not a full solid fill. About half the cells are “lit”; the rest stay dim sparks.
- On the site the field fades in on hover (`reveal` → 1). A always-on accent would keep `reveal = 1`.

## Constants (from their script)

| Name | Value | Meaning |
|---|---|---|
| `CELL` | `4` | Grid cell side in CSS px |
| `DENSITY` | `0.5` | Fraction of cells with the bright base |
| Dot size | `max(1, round(CELL * 0.62))` | ~2 px filled square, centred in the cell |
| Frame cap | 30 fps | `requestAnimationFrame`, skip if under `1000/30` ms |

## Deterministic random

Same as their `rnd(i, salt)` so a resize does not reshuffle the city:

```js
function rnd(i, salt) {
  var x = Math.sin((i + 1) * 12.9898 + salt * 78.233) * 43758.5453;
  return x - Math.floor(x);
}
```

## Build the cell list (once per size)

```text
cols = floor(width / CELL), rows = floor(height / CELL)
offX = (width - cols * CELL) / 2
offY = (height - rows * CELL) / 2

for each (row, col):
  i = row * cols + col
  lit = rnd(i, 1) < DENSITY
  cell = {
    x: offX + col * CELL + CELL/2,
    y: offY + row * CELL + CELL/2,
    base: lit ? 0.5 + rnd(i, 2) * 0.5 : 0.05 + rnd(i, 3) * 0.18,
    sp:  0.6 + rnd(i, 4) * 2.4,   // per-cell angular speed (rad/s scale)
    ph:  rnd(i, 5) * 2π           // per-cell phase
  }
```

Each cell must have its **own** `sp` and `ph`. A shared frequency with only a phase offset reads as one wave, not independent twinkles.

## Draw each frame

`now` is seconds (`performance.now() / 1000` or equivalent).

```text
clear canvas
cx, cy = centre; maxD = hypot(cx, cy)
dot = max(1, round(CELL * 0.62)); off = dot / 2
composite = lighter; fillStyle = tint (#FF8038 on the site)

for each cell p:
  tw   = 0.55 + 0.45 * sin(now * p.sp + p.ph)
  bias = 0.55 + 0.45 * (1 - hypot(p.x - cx, p.y - cy) / maxD)
  a    = p.base * tw * bias * reveal
  if a <= 0.002: skip
  alpha = min(1, a)
  fillRect(p.x - off, p.y - off, dot, dot)
```

`bias` keeps the centre a bit brighter than the corners.

## SwiftUI sketch (removed from the app)

Former home: `Sources/MenuTools/Views/Components/PixelShimmerBackground.swift`.

- Drive with `TimelineView(.periodic(from:by: 1/30))` and draw in `Canvas`.
- Clip to the host’s continuous rounded rect.
- For status tints (system green/orange), keep hue but scale RGB so relative luminance matches `#FF8038`, or saturated greens blow out under plus-lighter.
- Cost: only while the view is mounted. One small canvas per accent at 30 fps; scales with how many accents are visible. Panel closed → no cost.

## Where it was wired (removed)

- Running session rows: `AgentLiveRow` when `isRunning && !needsInput`.
- Active Awake quick toggle only (not Retry / VPN / Low Power / SpoofDPI).

Idle, input-needed, and ended rows stayed on flat fills the whole time.
