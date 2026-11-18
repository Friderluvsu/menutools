# Terax link

Source: `Sources/MenuTools/Features/TeraxLink/` (`TeraxLinkProtocol`, `TeraxLinkService`, `TeraxLinkServer`, `RestModeManager`, `TeraxLinkDiagnose`).

Terax's phone access shows MenuTools' agent sessions, system stats and power controls on a paired phone. Terax asks MenuTools over a local socket and relays the answer through its own encrypted phone channel. MenuTools never talks to the network for this.

## Socket

- Path: `~/Library/Application Support/MenuTools/terax.sock`, mode `0600`, folder `0700`.
- Every peer's uid is checked with `getpeereid`; a different user is dropped.
- One JSON line in, one JSON line out, then the connection closes. Requests over 16 KiB are refused.
- At most 8 connections at once; reads and writes time out after 3 s.
- Started at launch (not in preview renders). Off with `defaults write com.frider.MenuTools TeraxLinkEnabled -bool false`.
- A second MenuTools (a dev build beside the installed one) finds the socket answering and does not take it over. The socket file is removed on quit only if it is still ours.
- Idle cost: one listening descriptor watched by a dispatch source. No timer, no polling. A request reads state the managers already hold; nothing is sampled for it.

## Requests

| Request | Effect |
|---|---|
| `{"method":"status"}` | Snapshot below |
| `{"method":"status","params":{"refresh":true}}` | Re-reads the four session sources, battery and VPN / SpoofDPI status first (the same reads the timers make, waiting up to 4 s for the network check), then the snapshot. Nothing is checked |
| `{"method":"action","params":{"name":"lock"}}` | Display off now (`pmset displaysleepnow`) |
| `{"method":"action","params":{"name":"rest","on":true}}` | Rest mode on or off |
| `{"method":"action","params":{"name":"awake","on":true,"minutes":60}}` | Awake session; minutes 0 (no limit), 15, 30, 60, 120, 300 |
| `{"method":"action","params":{"name":"lid","on":true,"minutes":0}}` | Closed-lid session, same minutes |
| `{"method":"action","params":{"name":"lowPower","on":true}}` | Low Power Mode |
| `{"method":"action","params":{"name":"sleepWhenDone","on":true}}` | Arm or cancel Sleep when done |
| `{"method":"action","params":{"name":"wakeWhenDone","on":true}}` | Arm or cancel Wake me when done (off also stops a ringing alarm) |
| `{"method":"action","params":{"name":"alarm","on":false}}` | Stop the ringing alarm. `on` true is refused: the alarm only starts when sessions finish |
| `{"method":"action","params":{"name":"paneFocused","pid":4242}}` | The user brought the Terax pane whose shell is `pid` forward: every unchecked Claude Done row whose process runs under that shell is checked. A missing pid or one ≤ 1 is refused (`missing pid`); a pid with nothing under it is answered `ok` and changes nothing |

Replies are `{"ok":true,"result":<status>}` (an action returns the fresh status) or `{"ok":false,"error":"..."}`. Unknown methods, actions, durations and missing fields are refused by name. Optional fields are omitted when empty.

Nothing reached through the link may show an admin prompt, because nobody may be at the Mac to answer it: Closed-lid and Low Power Mode are refused when the privileged helper is not installed (`power.helper` is false).

## Status

Every snapshot carries `updatedAt` (epoch ms, when MenuTools built it) and `refreshed` (true when it answered a refresh), so the phone can show how fresh the data is.

- `sessions`: Claude, Cursor, Codex and Antigravity rows. `agent`, `name`, `project` (folder name only), `state` (`input`, `running`, `done`, `idle`, `ended`), `detail` (what an input row waits for), `since` (start, or finish for done and ended, epoch ms), `badge` (the row's cost or token badge), `pid` (Claude, Codex and Cursor CLI rows: the agent's process, so Terax can open the terminal it runs in; Terax replaces it before anything reaches the phone). Ordered input, running, done, idle, then up to 6 ended rows from the last 12 hours. No session ids, paths or transcript text.
- `stats`: from `SystemStatDetails.snapshot`, which the 2 s history tick updates while the panel is closed. CPU with the last 30 samples, memory, pressure, temperature, GPU, network speeds, load, uptime, startup disk.
- `battery`: charge, charging, plugged in, time left. Absent on Macs without a battery.
- `power`: Awake and Closed-lid (`remaining` seconds, absent for no limit), Low Power Mode, Rest mode, VPN and SpoofDPI (read only), whether the helper is installed, and `afterDone`.
- `power.afterDone`: `sleep` and `wake` (armed switches), `alarm` (ringing now), `alarmSince` (epoch ms), `busy` (what holds the switches up, e.g. `2 running · 1 waiting`; absent when everything is done or nothing is armed).

## Pane focus checks finished sessions

MenuTools keeps a finished session blue ("unchecked") until the user acts on it; opening the panel does not count. Looking at the session's terminal does, and in Terax that is a pane coming forward, which only Terax can see. So Terax reports it with `paneFocused`.

Terax side (not in this repo):

- Send `paneFocused` with the pane's **shell pid** (the pty child that `pane.reveal` matches against) when a pane becomes the one the user is looking at: its tab is selected, it gets focus inside a split, or the Terax window becomes key with it focused.
- Only after the pane has stayed focused for 2.5 s (`PANE_FOCUS_DWELL_MS`), so cycling through tabs does not check everything on the way.
- Fire and forget: one line on `terax.sock`, ignore the reply, never retry. MenuTools not running (no socket) is normal.
- A `pane.reveal` from MenuTools focuses the pane too. The resulting `paneFocused` is harmless: the row click already checked it.

MenuTools walks each unchecked Claude finish's process up to 16 parents (`ProcessLookup.descends`) and checks it when the shell pid is among them. Cursor, Codex and Antigravity rows are not checked this way: their ended rows have no live process to walk.

## Sleep when done and Wake me when done

Two one-shot switches on the dashboard (`AfterDoneManager`, under the Awake row), also armed from the phone. Neither is saved across launches.

- **Done** means no session is running and every session that needs input has waited over 5 minutes (`inputPatience`). A Claude process that sits idle after its task counts as done. The done state must hold for 60 s before sleep and 20 s before the alarm (`sleepSettle`, `wakeSettle`), so a short gap between chained commands is not the end. The tiles show the countdown (`Sleep in 42s`) or what is still busy (`Alarm · 2 running`).
- **Sleep when done** stops Rest mode, Awake and Closed-lid, waits up to 5 s for the helper to restore `pmset disablesleep 0` (`AntiSleepManager.sleepDisabledInEffect`), then runs `pmset sleepnow`. With the lid closed, ending Closed-lid is itself the sleep.
- **Sleep when done** also waits until the Mac has seen no keyboard or mouse input for 60 s; the tile's countdown shows whichever wait is longer. A Codex process counts as running only while its rollout usage changed, or it started, within the last 5 min (Codex has no idle state, so an open prompt would otherwise block the switches forever). Firing the wake alarm does not restart sleep's clock.
- **Wake me when done** posts an "All sessions done" notification and rings: on the Mac, Glass every 1.6 s (not while Rest mode keeps the Mac silent); on the phone, Terax sees `afterDone.alarm` true in the status and plays its own repeating sound until it sends `alarm` off. The alarm stops on a tile click, the panel opening, keyboard or mouse input at the Mac, the phone's stop, or after 3 minutes (`alarmLimit`).
- With both armed, the alarm fires first and sleep waits until the alarm has stopped: a sleeping Mac could not answer the phone's stop request, so the phone would ring on.
- Cost: the manager subscribes to `sessionMenuMarksChanged` and runs a 1 s timer only while a switch is armed; nothing runs otherwise.

Session managers keep their own schedule: they already poll every 2 s while their agent runs, and Claude also watches its sessions folder, so a phone viewer adds no polling.

## Rest mode

For stepping away while agents keep working. The phone shows one Rest button in its header, lit while Rest mode is on; the state always comes from MenuTools, so switching views or reopening the page shows it. The Mac has the same switch: the Rest tile in the dashboard's second row of quick toggles (lit "Resting" while on; a click ends it with the display turned on). Starting from the tile waits 1 s so the click's mouse-up cannot wake the display and end it at once.

On:

1. A `PreventUserIdleSystemSleep` assertion, so the Mac does not sleep and terminals keep running.
2. Low Power Mode on, only when the helper is installed and it was off.
3. MenuTools' notifications and alert sounds silenced (`Alerts`, in `Helpers/`): session alerts, conversions, the Closed-lid battery guard and the status light sounds. They are dropped, not queued; the session lists still show what needs input. Terax asks for the Rest state over the socket before each of its own agent alerts and holds back its notification and sound too.
4. Display off.

Off, from the phone: alerts are allowed again, the assertion is released, Low Power Mode is turned off only if Rest turned it on, and the display is turned back on (`IOPMAssertionDeclareUserActivity`, falling back to `caffeinate -u`). With a password required after the display sleeps, that shows the lock screen.

A display wake is checked against the time since the last keyboard, trackpad or mouse event (`CGEventSource.secondsSinceLastEventType`, HID state):

- Input in the last 3 s: someone is at the Mac, and Rest mode ends.
- No local input (a notification lit the display): Rest mode stays on, and the display goes dark again after 15 s. Without this, Awake's "keep display awake" would hold a notification-lit display on. Input during those 15 s ends Rest mode instead.

Typing from the phone reaches terminals, not the HID system, so remote use never ends Rest mode. Awake and Closed-lid sessions are untouched. Closing the lid still sleeps the Mac unless Closed-lid is on. Quitting MenuTools ends the assertion; Low Power Mode it turned on stays on.

## Diagnose

`--terax-link-diagnose` runs the link on a temporary socket with preview state and checks status, `paneFocused` (with and without a pid), every refusal, the size limit, the socket mode and the second-instance check. It performs no action, so power settings never change. Exit code 0 when everything passed.

## Session click opens the Terax pane

Clicking a Claude, Codex, Cursor or Antigravity CLI session whose process runs under Terax shows the pane it runs in, not just the app (`Features/TeraxLink/TeraxReveal.swift`). Each running Terax writes `~/Library/Caches/terax*/control.json` (loopback port, token, app pid, user-only). MenuTools walks the session pid's parents until one matches a descriptor's pid, activates that Terax, and sends one line over its control port: `{"method":"pane.reveal","params":{"pid":…,"state":"input|running|done|idle"}}`. Terax switches space and tab, focuses the pane and flashes its border (orange for input). Anything not under Terax falls back to activating the owning app as before.

Check it: `.build/debug/MenuTools --terax-reveal-diagnose <pid> [state]` prints the descriptors, the owning Terax and its reply (it really switches the tab).
