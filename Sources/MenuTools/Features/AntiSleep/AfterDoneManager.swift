import AppKit
import Foundation
import UserNotifications

/// Two one-shot switches for leaving agents to finish: **Sleep when done** ends Awake and Closed-lid
/// and puts the Mac to sleep once every session is done, and **Wake me when done** rings an alarm
/// (here, and on the phone through the Terax link) at the same moment.
///
/// "Done" means no session is running, and every session that needs input has waited for at least
/// `inputPatience`. The state must hold for `sleepSettle` / `wakeSettle` before anything happens, so a
/// chain of commands with a short gap between them does not count as the end.
@MainActor
final class AfterDoneManager: ObservableObject {
    /// Armed switches. Each turns itself off after it has acted.
    @Published private(set) var sleepArmed = false
    @Published private(set) var wakeArmed = false
    /// True while the alarm rings. Stopped by a click on the tile, the panel opening, local input,
    /// the phone, or after `alarmLimit`.
    @Published private(set) var alarmOn = false
    private(set) var alarmSince: Date?
    /// Seconds until the armed sleep happens, once everything is done. Nil while sessions are busy.
    @Published private(set) var sleepCountdown: Int?
    /// Sessions are done but someone is using the Mac: the countdown restarts on every input,
    /// so the tile says so instead of showing a frozen "60s".
    @Published private(set) var sleepWaitsForAway = false
    @Published private(set) var wakeCountdown: Int?
    /// What still holds things up, for the tiles: "2 running", "1 waiting".
    @Published private(set) var busyText: String?

    nonisolated static let inputPatience: TimeInterval = 5 * 60
    nonisolated static let sleepSettle: TimeInterval = 60
    nonisolated static let wakeSettle: TimeInterval = 20
    nonisolated static let alarmLimit: TimeInterval = 3 * 60
    nonisolated static let alarmInterval: TimeInterval = 1.6
    nonisolated static let alarmSound = "Glass"

    private unowned let app: AppState
    private let previewMode: Bool
    private var tick: DispatchSourceTimer?
    private var alarmTimer: DispatchSourceTimer?
    /// When the "done" state began. Nil while something is busy.
    private var doneSince: Date?
    /// When each input-needed session was first seen waiting, by provider-qualified id.
    private var waitingSince: [String: Date] = [:]
    /// Codex has no idle state: a process counts as running while its rollout usage changed within
    /// `inputPatience`, or it started that recently.
    private var codexActivity: [String: (usage: SessionUsage?, changed: Date)] = [:]
    private var sleeping = false

    init(app: AppState, previewMode: Bool) {
        self.app = app
        self.previewMode = previewMode
    }

    // MARK: Switches

    func toggleSleep() { setSleep(!sleepArmed) }
    func toggleWake() {
        if alarmOn {
            stopAlarm()
        } else {
            setWake(!wakeArmed)
        }
    }

    func setSleep(_ on: Bool) {
        guard sleepArmed != on else { return }
        sleepArmed = on
        armedChanged()
    }

    func setWake(_ on: Bool) {
        guard wakeArmed != on else { return }
        wakeArmed = on
        if !on { stopAlarm() }
        armedChanged()
    }

    /// Panel open: whoever opened it is here, so the alarm has done its job.
    func panelOpened() {
        stopAlarm()
    }

    private func armedChanged() {
        if sleepArmed || wakeArmed {
            // A 1 s tick is enough: the managers refresh every 2 s and the countdowns pass on their own.
            // Arming the second switch keeps the running "done" clock.
            guard tick == nil else {
                evaluate()
                return
            }
            let timer = DispatchSource.makeTimerSource(queue: .main)
            timer.schedule(deadline: .now() + 1, repeating: 1, leeway: .milliseconds(200))
            timer.setEventHandler { [weak self] in
                MainActor.assumeIsolated { self?.evaluate() }
            }
            timer.resume()
            tick = timer
            doneSince = nil
            evaluate()
        } else {
            tick?.cancel()
            tick = nil
            doneSince = nil
            waitingSince = [:]
            codexActivity = [:]
            sleepCountdown = nil
            sleepWaitsForAway = false
            wakeCountdown = nil
            busyText = nil
        }
    }

    // MARK: Done check

    private struct Row {
        var key: String
        var running: Bool
        var needsInput: Bool
    }

    private func rows(now: Date) -> [Row] {
        var rows: [Row] = []
        for s in app.claudeSessions.sessions {
            rows.append(Row(key: "claude:\(s.sessionId)", running: s.isWorking, needsInput: s.needsInput))
        }
        for s in app.cursorSessions.sessions {
            rows.append(Row(key: "cursor:\(s.id)", running: s.status == "running", needsInput: s.needsInput))
        }
        var codexSeen = Set<String>()
        for s in app.codexSessions.sessions {
            let key = "codex:\(s.id)"
            codexSeen.insert(key)
            var activity = codexActivity[key] ?? (usage: s.usage, changed: s.startedAt ?? now)
            if activity.usage != s.usage { activity = (usage: s.usage, changed: now) }
            codexActivity[key] = activity
            let running = now.timeIntervalSince(activity.changed) < Self.inputPatience
            rows.append(Row(key: key, running: running, needsInput: false))
        }
        codexActivity = codexActivity.filter { codexSeen.contains($0.key) }
        for s in app.antigravitySessions.sessions {
            rows.append(Row(key: "antigravity:\(s.id)", running: s.status == "running", needsInput: s.needsInput))
        }
        return rows
    }

    private func evaluate() {
        guard sleepArmed || wakeArmed, !sleeping else { return }
        let now = Date()
        let rows = rows(now: now)
        var running = 0
        var waiting = 0
        var stuck = 0
        var seen = Set<String>()
        for row in rows {
            if row.needsInput {
                seen.insert(row.key)
                let since = waitingSince[row.key] ?? now
                waitingSince[row.key] = since
                if now.timeIntervalSince(since) >= Self.inputPatience { stuck += 1 } else { waiting += 1 }
            } else if row.running {
                running += 1
            }
        }
        waitingSince = waitingSince.filter { seen.contains($0.key) }

        let done = running == 0 && waiting == 0
        if done {
            if doneSince == nil { doneSince = now }
        } else {
            doneSince = nil
        }
        let text: String? = {
            if done { return stuck > 0 ? "\(stuck) stuck" : nil }
            var parts: [String] = []
            if running > 0 { parts.append("\(running) running") }
            if waiting > 0 { parts.append("\(waiting) waiting") }
            return parts.joined(separator: " · ")
        }()
        if busyText != text { busyText = text }

        let held = doneSince.map { now.timeIntervalSince($0) } ?? 0
        // Sleep also waits for the Mac to be unattended: keyboard or mouse input in the last
        // `sleepSettle` means someone is here (it is what stops the alarm, too).
        let idle = RestModeManager.secondsSinceLocalInput()
        let sleepWait = max(Self.sleepSettle - held, Self.sleepSettle - idle)
        let sleepLeft = done && sleepArmed ? max(0, Int(sleepWait.rounded(.up))) : nil
        let wakeLeft = done && wakeArmed ? max(0, Int((Self.wakeSettle - held).rounded(.up))) : nil
        if sleepCountdown != sleepLeft { sleepCountdown = sleepLeft }
        // Input in the last 3 s, not the done hold, is what keeps the countdown up; once the
        // keyboard and mouse rest, the real countdown shows.
        let waitsForAway = sleepLeft != nil && idle < held && idle < 3
        if sleepWaitsForAway != waitsForAway { sleepWaitsForAway = waitsForAway }
        if wakeCountdown != wakeLeft { wakeCountdown = wakeLeft }

        if wakeArmed, done, held >= Self.wakeSettle {
            wakeArmed = false
            startAlarm(stuck: stuck)
            // Only tear down when nothing stays armed: `armedChanged` would restart sleep's clock.
            if !sleepArmed { armedChanged() }
        }
        // The alarm first: a sleeping Mac could not answer the phone's stop request.
        if sleepArmed, done, sleepWait <= 0, !alarmOn {
            sleepArmed = false
            armedChanged()
            goToSleep()
        }
    }

    // MARK: Sleep

    private func goToSleep() {
        guard !previewMode else { return }
        sleeping = true
        app.restMode.stop()
        app.antiSleep.deactivate()
        app.antiSleep.deactivateLid()
        Task { [weak self] in
            // Closed-lid restores `pmset disablesleep 0` through the helper; sleep would be refused before that.
            var waited: TimeInterval = 0
            while let self, self.app.antiSleep.sleepDisabledInEffect, waited < 5 {
                try? await Task.sleep(for: .milliseconds(200))
                waited += 0.2
            }
            guard let self else { return }
            self.sleeping = false
            Self.run("/usr/bin/pmset", ["sleepnow"])
        }
    }

    // MARK: Alarm

    private func startAlarm(stuck: Int) {
        guard !previewMode, !alarmOn else { return }
        alarmOn = true
        alarmSince = Date()
        notify(stuck: stuck)
        // Rest mode keeps the Mac silent; the phone still rings through the link.
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: Self.alarmInterval, leeway: .milliseconds(100))
        timer.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.alarmTick() }
        }
        timer.resume()
        alarmTimer = timer
    }

    private func alarmTick() {
        guard alarmOn, let since = alarmSince else { return }
        if Date().timeIntervalSince(since) >= Self.alarmLimit
            || RestModeManager.secondsSinceLocalInput() < Self.alarmInterval
        {
            stopAlarm()
            return
        }
        if !Alerts.silenced { NSSound(named: NSSound.Name(Self.alarmSound))?.play() }
    }

    func stopAlarm() {
        guard alarmOn else { return }
        alarmTimer?.cancel()
        alarmTimer = nil
        alarmOn = false
        alarmSince = nil
    }

    private func notify(stuck: Int) {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
        let content = UNMutableNotificationContent()
        content.title = "All sessions done"
        content.body = stuck > 0 ? "\(stuck) waiting for input over 5 min" : "Nothing is running"
        content.sound = .default
        Alerts.post(UNNotificationRequest(identifier: "afterdone.wake", content: content, trigger: nil))
    }

    nonisolated private static func run(_ path: String, _ arguments: [String]) {
        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = arguments
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try? process.run()
            process.waitUntilExit()
        }
    }
}
