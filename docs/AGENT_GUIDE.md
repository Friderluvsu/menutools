# MenuTools — Full Guide for AI Agents

This document is a standalone orientation for coding agents that have not worked on MenuTools before. Read it first. Use `AGENTS.md` as the live rule set (imported by `CLAUDE.md`). Use `docs/knowledge-base/` for deep detail (endpoints, state machines, measurements).

**When code and any doc disagree, trust the code and fix the doc.**

---

## 1. What this project is

MenuTools is a **native macOS menu-bar utility** (AppKit + SwiftUI, Swift 6, **macOS 14.0+**). Bundle ID / designated requirement: `com.frider.MenuTools`. No third-party Swift packages — SPM only builds the app and a privileged helper.

It lives as a status item. Clicking the icon opens a custom `NSPanel` (not `NSPopover`) with a dashboard. There is no Dock icon in normal use; the panel is the UI.

### Feature surface (high level)

| Area | What it does |
|---|---|
| System monitor | CPU, GPU, RAM, temp, network I/O, disk, battery; clickable detail pages |
| Fan control | AppleSMC via privileged helper |
| AI limits | Claude Code / Codex / Antigravity / Cursor usage (read-only, no extra login) |
| Live sessions | Claude Code, Cursor agents, Codex CLI, Antigravity chats + notifications |
| Shelf | Temporary file drop shelf while dragging |
| Media converter | FFmpeg / sips (video, audio, GIF, images) |
| Anti-sleep | Awake (`IOPMAssertion`) and Closed-lid (`pmset disablesleep` via helper, battery guard); sessions resume after relaunch |
| Network | VanyaVPN (`scutil`) + SpoofDPI SOCKS proxy |
| Low Power Mode | Via SMC helper / `pmset` |
| Clipboard | History of text, images and file lists + themed ⌥⌘V HUD; ⇧⌥⌘V paste as plain text |
| Session usage | Tokens, estimated cost and context per agent session row, from Claude transcripts, Codex rollouts and Cursor composer data |
| Window controls | Green = maximize on current Space; red = quit when last window closes |
| iMessage | Shortcuts while Messages is frontmost (event tap) |
| System utils | Eject disks, Empty Trash, Google Drive FinderSync reset |

---

## 2. Repo map

```
Sources/
├── MenuTools/                      # Main app
│   ├── main.swift                  # Entry + diagnostic CLI flags
│   ├── App/
│   │   ├── AppDelegate.swift       # NSStatusItem, NSPanel, drag-safe outside-press
│   │   ├── AppState.swift          # Coordinator; starts/stops polling with panel
│   │   └── PreviewRenderer.swift   # Offscreen SwiftUI → PNG for make preview
│   ├── Features/<Name>/            # One folder per feature (managers, models)
│   ├── Helpers/                    # Shell.swift, CarbonHotKeyHelper.swift
│   └── Views/
│       ├── PopoverContentView.swift  # Panel root / dashboard (no ScrollView)
│       ├── Components/               # Cards, tiles, theme, pickers
│       └── Tabs/                     # SettingsTabView is live; other tabs are legacy
└── MenuToolsSMCHelper/
    └── main.swift                  # Privileged CLI for AppleSMC + pmset

docs/
├── AGENT_GUIDE.md                  # This file
└── knowledge-base/                 # Deep notes (see README there)

AGENTS.md                           # Canonical agent rules (always follow)
CLAUDE.md                           # Imports AGENTS.md + Claude-session extras
DEVELOPMENT.md                      # Human setup / daily workflow
README.md                           # Product README (user-facing, often Russian)
scripts/                            # build.sh, preview.sh, doctor.sh, …
Makefile                            # Preferred entry: make build / run / preview / …
```

**Do not delete without asking:** unreferenced legacy under `Views/Tabs/` (`ComponentDashboardGrid`, `FeaturesListView`, `SystemToolsTabView`, `NetworkTabView`, `AntiSleepTabView`, `MediaConverterTabView`, `ClipboardTabView`) and `Views/Components/UnifiedSearchPalette.swift`.

---

## 3. Hard rules (break these and you will cause real pain)

### Build and run

1. **Always use Make**, never raw `swift build`. Raw builds skip SDK pin, module-cache path, `--disable-sandbox`, Swift/SDK compatibility flag, runtime bundling and codesign.
2. **Never execute** `.build/.../MenuTools`. Run **`build/MenuTools.app`** via `make run` or `open`.
3. TCC (Accessibility, Input Monitoring) is bound to the **signed** bundle (`com.frider.MenuTools`). Running the wrong binary looks like “permissions broken”.
4. **One build at a time.** `make build`, `make release`, and `make preview` all write `build/` and `.build/`.
5. **`make preview` kills** the user’s running MenuTools and replaces `build/MenuTools.app` with a **debug** build. Warn before running it. Afterwards `make run` restores a release bundle.

```bash
make doctor     # toolchain, SDK, ffmpeg, spoofdpi, codesign
make build      # debug → ./build/MenuTools.app (signed)
make release    # release → ./build/MenuTools.app
make run        # release + launch
make preview    # debug + render build/preview-*.png (kills running app)
make lint / format
```

UI layout check: `make preview`, then **Read** `build/preview-dashboard.png`, `build/preview-settings.png`, `build/preview-anti-sleep.png`. PNGs show layout only — drag/focus/click need a live `make run`.

### Credentials and privacy

- **Never** read Keychain items or token files, and **never** print token values (`security find-generic-password -w`, `~/.claude/.credentials.json`, `~/.codex/auth.json`, agy token file, etc.).
- Diagnostics may print **statuses** only — never secrets, plan names, usage numbers, or emails into docs/code.
- Do **not** run `--ai-limits-diagnose` unless the user asks (it reads Keychain in-process even though it prints statuses).

### Code and UI conventions

- Labels: short and scannable (“краткость — сестра таланта”). No verbose help paragraphs in Settings/popover.
- Prefer editing existing patterns over inventing new architecture.
- Do not create markdown the user did not ask for (except when they ask, like this guide).
- Only commit when the user asks.

### Claude Code session extras (from CLAUDE.md)

- Subagent routing hint: Haiku for docs/mechanical/build; Sonnet for features; Opus for AppKit state machines and adversarial review.
- Split large work by disjoint files; one build at a time; update docs after behaviour changes.

---

## 4. Architecture in one page

### Lifecycle

1. `main.swift` (MainActor) boots `NSApplication` + `AppDelegate`.
2. Status item is created at launch; the **panel and SwiftUI graph are built on first open** (idle footprint ~11 MB).
3. `AppState` owns feature managers. `onPopoverWillShow` / `onPopoverDidClose` start and stop panel-scoped polling.
4. SIGTERM is routed to `NSApp.terminate` so `applicationWillTerminate` can restore `pmset disablesleep`. Power assertions die with the process.

### Panel (critical AppKit)

- Custom `MenuToolsPanel: NSPanel` — `canBecomeKey` / `canBecomeMain` true, `.popUpMenu` level, borderless, **without** `.nonactivatingPanel`. Esc closes.
- `hidesOnDeactivate = false`; outside-press logic owns hide behaviour.
- Status button: `ZeroBlinkStatusBarButton` — toggle on **mouseDown** (immediate), no AppKit highlight blink.
- Double-toggle races are prevented with `isMouseDownOnButton`, sync resign-key handling, geometry checks (notch-safe), and 0.15s debounce.
- Full interaction model (outside left/right press, file drag, spring-load, focus): `docs/knowledge-base/panel-and-drag.md`.

### Observation / SwiftUI

- `PopoverContentView` observes **nothing**.
- Each dashboard section observes **only its own manager** (e.g. `MetricsCard` → System Monitor, `DashboardSessionsSection` → four session managers).
- Publish values **only on change** to avoid idle re-renders.
- Panel width **360pt**; height = natural SwiftUI height (`PanelHeightKey`), capped to visible screen. Top edge stays under the status item.

### Dashboard order (no scroll on main dashboard)

Header → metrics (CPU, GPU, RAM, TEMP, NET, BAT, FAN, DISK; LAN/WAN copy) → AI Limits → session cards **or** Sessions summary → toggles (Awake, Lid, Low Power, VPN, SpoofDPI) → converter → shelf → clipboard (3 rows).

- Stat tiles open detail pages; **X** returns. FAN detail is fan control.
- If live+ended session rows across providers **> 3**, show one **Sessions** summary instead of inline cards.
- Settings: segmented General / Windows / Messages / Network; pages stay mounted; well height = tallest page (no resize on tab switch). Crossfade via `SessionDashboardLayout.pageAnimation`.

---

## 5. Feature briefs

Deep notes live under `docs/knowledge-base/`. Summaries below are enough to know **where to look**.

### AI Limits (`Features/AILimits/`)

Read-only usage for Claude Code, Codex, Antigravity, Cursor. Refresh on panel open (if cache > 2 min) and every 5 min while open. Cache: `Application Support/MenuTools/ai-limits-cache.json`. Back-off on 429 / failures. “Login expired” → **Run** opens Terminal so the **CLI** renews login — MenuTools never refreshes tokens itself.

| Provider | Source sketch |
|---|---|
| Claude Code | Keychain / credentials → Anthropic oauth usage API |
| Codex | `~/.codex/auth.json` → ChatGPT wham usage; jsonl fallback |
| Antigravity | Local language_server RPC, or `agy` + Cloud Code when IDE closed |
| Cursor | Bundled hook around `agent about --format json` (no HTTP) |

→ `docs/knowledge-base/ai-limits.md`

### Sessions (four managers)

All stay watching after launch: **2 s** (tolerance 0.5 s) when relevant app is live or panel open; **15 s** (4.5 s) otherwise. Menu bar can show a three-segment **session ring** (input / running / unseen ended). The dashboard Sessions summary border splits across orange, green, and blue by the waiting, running, and unchecked-ended counts, with one traveling light per such session. Already-checked ended rows stay off that border. An ended row shows when it finished in the uptime slot (`just now`, `4m ago`, `2h ago`).

| Provider | Live source | Ended rows? | Input-needed? |
|---|---|---|---|
| Claude | `~/.claude/sessions/<pid>.json` | No | Yes + notification |
| Cursor | Cursor `state.vscdb` composer headers | Yes until dismiss | Yes + notification |
| Codex | Live `codex` processes (+ optional sqlite titles) | Yes (process exit) | No |
| Antigravity | `conversation_summaries.db` | Yes until dismiss | Yes + notification |

→ `claude-sessions.md`, `cursor-sessions.md`, `codex-sessions.md`, `antigravity-sessions.md`

### Shelf (`Features/Shelf/`)

Global drag monitor; floating non-activating panel; files referenced in place (not copied); `shelf.json` persistence. Settings: `ShelfEnabled`, `ShelfShowOnDrag`. → `shelf.md`

### Window controls (`Features/WindowManager/`)

Session event tap on traffic lights via Accessibility. Green maximizes to `visibleFrame` (no full-screen Space). Red can quit app when last window closes. Needs Accessibility; exclusions in UserDefaults (Finder default). → `window-controls.md`

### Battery / menu bar icon

Appearance from `NSApp.effectiveAppearance`. Renderers: charge-only, classic bar, Golden Gate (macOS 27-style), ring. → `battery-icons.md`

### System stats

Clickable detail pages for CPU/GPU/RAM/TEMP/NET/BAT/DISK. → `system-stats.md`

### Performance model

Panel-scoped polls vs always-on watchers; timer tolerances; measure with `vmmap --summary` (physical footprint), not raw RSS. → `performance.md`

### Troubleshooting

Symptom → cause → fix. → `troubleshooting.md`

---

## 6. Diagnostics (bundle binary only)

Run: `build/MenuTools.app/Contents/MacOS/MenuTools <flag>`

| Flag | Purpose |
|---|---|
| `--render-status-lights <png>` | Every menu bar status-light style and its key animation frames, as one sheet |
| `--render-preview <png> […]` | Offscreen panel PNG; optional `--settings`, `--sessions`, `--anti-sleep-picker`, `--fan-picker`, `--sample-tasks`, `--open-session-detail <id>`, `--theme <id>`, `--egg-at <seconds>` |
| `--render-battery-icons <dir>` | Battery style PNGs |
| `--window-diagnose` | Accessibility + event tap creatable? |
| `--stat-diagnose` | CPU clusters, load, memory pressure, GPU, top processes (no IPs) |
| `--render-clipboard-hud <png> [--theme <id>]` | The ⌥⌘V window with sample clips, second row selected |
| `--session-usage-diagnose` | Per live Claude / Codex session: transcript found, files read, turns, token totals, model, estimated cost (counts only) |
| `--ai-limits-diagnose` | Provider statuses only — **user must ask** |
| `--show-popover [--stat cpu]` | Open panel at launch, optionally on a stat detail page (for CPU measurements) |
| `--panel-memory-diagnose [seconds]` | Footprint / CPU over open-close cycles |

---

## 7. Privileged helper

Path in bundle: `Contents/Resources/bin/menutools-smc-helper`.

Used for AppleSMC fan control and privileged `pmset` (`lowpowermode`, `disablesleep`). Source: `Sources/MenuToolsSMCHelper/`. Do not reinvent privileged paths in the main app.

---

## 8. How to change things safely

### Before coding

1. Find the feature folder under `Sources/MenuTools/Features/`.
2. Find the SwiftUI card/section under `Views/Components/` (or Settings under `Views/Tabs/SettingsTabView.swift`).
3. Skim the matching `docs/knowledge-base/*.md` if behaviour/timings/endpoints are involved.
4. Note polling ownership in `AppState` — do not leave timers running with the panel closed unless the feature is intentionally always-on.

### While coding

- Match existing naming, observation scope, and short UI copy.
- Prefer `publish only on change`.
- For panel / drag / status-item work, treat `AppDelegate` as a state machine — read `panel-and-drag.md` first.
- For AI limits, decode every API field as **optional**; never write tokens.

### After coding

- Update the relevant knowledge-base note if behaviour, endpoints, or timings changed.
- Prefer `make preview` for layout (warn about kill + debug bundle); `make run` for interaction.
- `make lint` / `make format` when touching Swift style.

### Verification checklist (typical UI change)

- [ ] Builds via `make build` or `make release`
- [ ] Preview PNGs look right (if layout)
- [ ] Panel open/close still drag-safe
- [ ] No new always-on poll without reason
- [ ] Docs updated if behaviour changed
- [ ] No secrets or account details in code/docs

---

## 9. Common pitfalls

| Pitfall | Why it hurts |
|---|---|
| `swift build` + run `.build` binary | Wrong TCC identity; missing SDK/compat flags |
| `make preview` without warning | Kills user’s app; leaves debug bundle |
| Observing `AppState` from the root view | Extra SwiftUI invalidations |
| Closing panel on outside **mouseDown** | Breaks file drag into converter/shelf |
| Refreshing AI tokens ourselves | Ownership belongs to CLIs; can corrupt auth |
| Printing Keychain / usage numbers | Security + user privacy rule |
| Deleting “unused” Tab views | Legacy on purpose — ask first |
| Measuring with `ps` RSS only | Shared frameworks inflate RSS; use `vmmap` |

---

## 10. Doc index (where to go next)

| Doc | Role |
|---|---|
| [AGENTS.md](../AGENTS.md) | Canonical short rules — follow always |
| [CLAUDE.md](../CLAUDE.md) | AGENTS import + Claude build/routing notes |
| [DEVELOPMENT.md](../DEVELOPMENT.md) | Human toolchain setup |
| [knowledge-base/README.md](knowledge-base/README.md) | Index of deep notes |
| [knowledge-base/ai-limits.md](knowledge-base/ai-limits.md) | Usage APIs, cache, back-off |
| [knowledge-base/claude-sessions.md](knowledge-base/claude-sessions.md) | Claude live sessions |
| [knowledge-base/cursor-sessions.md](knowledge-base/cursor-sessions.md) | Cursor agent chats |
| [knowledge-base/codex-sessions.md](knowledge-base/codex-sessions.md) | Codex CLI sessions |
| [knowledge-base/antigravity-sessions.md](knowledge-base/antigravity-sessions.md) | Antigravity chats |
| [knowledge-base/panel-and-drag.md](knowledge-base/panel-and-drag.md) | Panel interaction state machine |
| [knowledge-base/shelf.md](knowledge-base/shelf.md) | File shelf |
| [knowledge-base/window-controls.md](knowledge-base/window-controls.md) | Green maximize / red quit |
| [knowledge-base/battery-icons.md](knowledge-base/battery-icons.md) | Menu bar battery rendering |
| [knowledge-base/system-stats.md](knowledge-base/system-stats.md) | Stat detail pages |
| [knowledge-base/performance.md](knowledge-base/performance.md) | Timers, watchers, footprint |
| [knowledge-base/troubleshooting.md](knowledge-base/troubleshooting.md) | Symptom → fix |

---

## 11. Suggested first 15 minutes for a new agent

1. Skim this guide + `AGENTS.md`.
2. Open `App/AppDelegate.swift` and `App/AppState.swift` to see panel + polling ownership.
3. Open `Views/PopoverContentView.swift` to see dashboard composition.
4. Jump into the feature folder matching the user’s task.
5. Read the matching knowledge-base note before changing timings, APIs, or drag/panel behaviour.
6. Build with `make build` (or release/`run`/`preview` as appropriate — warn on preview).
