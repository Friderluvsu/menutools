# Performance

Rules summary: `AGENTS.md` → "Performance Rules". This file holds the timer inventory, how to measure, and the measurement history.

## How to measure
- Use a release build (`make release` or `make run`). Close the panel, wait about 10 s, then sample.
- CPU: `ps -o %cpu= -p <pid>` or `top -l 3 -s 2 -pid <pid> -stats pid,cpu,mem`.
- Memory: `vmmap --summary <pid>` and read `Physical footprint` (and `peak`). Use this figure for comparisons. `ps` RSS includes shared framework pages and changes with uptime, so it is only a secondary signal.
- Panel lifecycle: `build/MenuTools.app/Contents/MacOS/MenuTools --panel-memory-diagnose [seconds]` (quit the running MenuTools first). It prints footprint and CPU time per phase.
- Object growth: `heap <pid>` twice and diff the class counts. The SwiftUI classes (`PropertyList.Element`, `AnyTrackedValue` dictionaries, `DisplayList.Item`) show whether the view graph grows.
- Keep the same conditions when comparing: same build configuration, panel state and uptime. A debug bundle (`make build`, `make preview`) is not comparable with a release bundle.

## Timer and watcher inventory

Verified against the source at the time of writing.

| Owner | Mechanism | Interval (tolerance) | Runs when |
|---|---|---|---|
| AILimitsManager | `Timer.scheduledTimer` | 300 s (30 s) | panel open (`onPopoverWillShow` / `onPopoverDidClose`) |
| SystemMonitorManager | `Timer.publish` + one 0.7 s warm-up | 2.0 s (0.5 s) | panel open |
| NetworkBypassManager | `Timer.publish` | 5.0 s (1.5 s) | panel open |
| FanControlManager | `Timer.publish` | 2.0 s (0.6 s) foreground; 5.0 s (1.5 s) background | foreground: panel open. Background: only in curve mode while the panel is closed |
| ClipboardManager | `Timer.publish` on `NSPasteboard.changeCount` | 1.0 s (0.5 s) | always, from launch |
| UniversalControlManager | directory watcher on `~/Library/Preferences/ByHost` and a wake observer, plus a timer | 120 s (36 s) with the watcher; 15 s (4.5 s) if the watcher cannot open | only while auto-enable is on |
| BatteryManager | IOPS run-loop source; Low Power Mode notification | event-driven, 0.5 s coalescing | always, no polling |
| WindowManager | session event tap (`leftMouseDown`, plus `leftMouseUp` for maximize) | event-driven | when Accessibility is granted and a feature is on |
| ShelfManager | global `.leftMouseDragged` monitor, 50 ms throttle; `.leftMouseUp` / `.leftMouseDown` monitors only during a file drag | event-driven | when the shelf is enabled and "Show on file drag" is on |
| iMessage | keyDown event tap | event-driven | only while Messages is frontmost and the feature is on |
| AntiSleepManager | countdown `DispatchSourceTimer` (1 s in the last hour, otherwise aligned to the next minute label) | 1 s to 60 s | while a timed session runs |
| WindowManager animation | `DispatchSourceTimer` on `animationQueue` | 16 ms, 0.22 s total | during a window resize |
| ClipboardManager filter | Combine debounce | 120 ms | while the search text changes |
| AppDelegate | KVO on `NSApp.effectiveAppearance`; `DispatchSourceSignal` for SIGTERM | event-driven | always |

Notes:
- Panel-scoped polling is started and stopped only by `AppState.onPopoverWillShow` and `onPopoverDidClose`. Do not start a new timer from a view's `onAppear`.
- The always-on items are cheap: one `changeCount` read per second, the event tap's window-bounds pre-check, and the shelf's throttled compare. Keep new always-on work at that level.
- Any new timer must set its tolerance explicitly.

## Baseline (before the overhaul)

Recorded earlier with a release build and the panel closed. This was `ps` RSS only; no footprint baseline exists.

- Idle CPU samples: 0.1, 0.1, 0.0, 0.3, 0.3, 0.1 (%). Range 0.0–0.3%.
- `ps` RSS: 31248–39536 KB (31–40 MB).

## Measurement history

| Date | Build | Measurement | Result |
|---|---|---|---|
| 2026-10-09 (before the fix round) | release | idle CPU, 10 samples | 0% every sample |
| 2026-10-09 (before the fix round) | release | `ps` RSS, panel closed | 87–90 MB during the first 30 s, 73–81 MB after |
| 2026-10-09 (before the fix round) | release | `vmmap --summary` | physical footprint 27.4 MB, peak 28.8 MB |
| 2026-10-09 (fix round, as reported) | release | `vmmap --summary` | physical footprint 11.5 MB (peak 11.9 MB) |
| 2026-10-09 (fix round, as reported) | release | `ps` RSS | 58–67 MB |
| 2026-10-09 (fix round, as reported) | release | idle CPU | 0.0% |
| 2026-10-09 (controlled comparison) | baseline `HEAD` release, panel closed, 12 s after launch | `vmmap --summary` | physical footprint 11.9 MB (peak 12.3 MB); RSS 69.1 MB; CPU 0.0% |
| 2026-10-09 (controlled comparison) | current release, panel closed, 12 s after launch | `vmmap --summary` | physical footprint 11.6 MB (peak 12.0 MB); RSS 63.1 MB; CPU 0.0% |
| 2026-10-09 (controlled comparison) | current release, panel open, 12 s after launch | `vmmap --summary` | physical footprint 31.0 MB (peak 32.9 MB); RSS 102.8 MB; CPU 0.0% |

The pre-fix cause was the panel and its SwiftUI graph being built at launch. The panel is now built on first open (`showPanel` calls `setupPanel`). The controlled comparison found no idle physical-footprint regression against `HEAD` (11.6 MB current vs 11.9 MB baseline). Opening the dashboard adds about 19.4 MB in this sample (31.0 MB open vs 11.6 MB closed).

Comparison conditions: same Mac (macOS 27.2, arm64), release configuration, signed bundle, panel closed, fresh launch, and a 12 s wait before sampling. The baseline source was `HEAD` (`520af0e`), built in a temporary copy with the current `scripts/build.sh` and two toolchain-compatibility adjustments: SwiftPM tools version 5.9 and `MainActor.assumeIsolated` around the existing AppKit entry point. No feature code was changed in that copy. Since only one fresh-launch sample was taken per build, treat the 0.3 MB difference as effectively unchanged rather than a meaningful reduction.

RSS and footprint disagree (for example 63.1 MB RSS against 11.6 MB footprint in the controlled comparison). That is expected, because RSS counts shared pages. Compare footprints.

## Panel lifecycle audit (2026-10-10)

Release build, macOS 27.2, arm64.

| Phase | Footprint | CPU time |
|---|---|---|
| Launch, panel never opened (10 s idle) | 12.8–13.2 MB | 0.2 s total |
| Panel monitors ran 4 s, no UI | +3 MB (once +21 MB: first network fetches, not reproduced) | — |
| After 10 open/close cycles | 33–34 MB | — |
| Panel open 180 s with live polling | 33–34 MB, flat | 0.06 s for 180 s |
| Idle, panel closed (60 s, `top`) | — | 0.0%, ~0.1 idle wakeups/s, 3 threads |

- No leak while the panel is open: a `heap` diff across 150 s open went from 107.6k to 106.7k objects.
- No leak per open/close: 30 cycles moved the footprint by under 1 MB.
- Releasing the panel after close was tried and dropped. The hosting view deallocated, but the footprint did not fall, even after `malloc_zone_pressure_relief`: freed pages stay dirty in the malloc zone, and Swift type metadata and ObjC method caches (about 2 MB) stay for the life of the process. Rebuilding cost 50–80 ms on the next open.
- A 27 h instance (installed build of `a796370`) measured 64.8 MB footprint, but only 19.9 MB RSS (most of it compressed) and 195 s CPU in total (about 0.2% average). Its heap held 3–4 times more SwiftUI graph objects than a fresh open (for example 2904 against 780 `AnyTrackedValue` dictionaries). The source was not identified: Settings pages, pickers, the shelf panel and the clipboard HUD build view graphs on demand and keep them. Next step: run `leaks <pid>` and `heap <pid>` on a long-running instance before restarting it.

## Build and verification record

Reported for the fix round (2026-10-09):
- `make release`: exit 0, build 26.25 s.
- `make preview`: exit 0. The debug build took 10.11 s. `preview-dashboard.png`, `preview-settings.png` and `preview-anti-sleep.png` rendered.
- `--window-diagnose` at the last run: `accessibility_trusted=false session_tap_created=false`. Window controls were therefore inactive on that run. See `troubleshooting.md`.
- `--ai-limits-diagnose` at the last run: Claude login expired; Codex ok; Antigravity ok via the agy CLI (IDE not running). Statuses only.

This resume (2026-10-09): `make release` exited 0. The compiler emitted linker search-path warnings and one Swift `Sendable` warning; the app bundle was signed and produced successfully.

## Open items
- Find what grows the SwiftUI graph over a long session (see the 2026-10-10 audit).
- Repeat the comparison with multiple fresh launches if a smaller-than-1 MB memory change needs to be distinguished from run-to-run variation.
