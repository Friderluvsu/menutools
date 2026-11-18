import Foundation

/// Answers Terax link requests from the state the managers already keep: nothing is sampled for a
/// request, and the session managers poll on their own schedule.
@MainActor
final class TeraxLinkService {
    private unowned let app: AppState
    nonisolated static let refreshInterval: TimeInterval = 2
    private var lastRefresh = Date.distantPast

    init(app: AppState) {
        self.app = app
    }

    func handle(_ line: Data) async -> Data {
        switch TeraxLinkProtocol.parse(line) {
        case .failure(let error):
            return TeraxLinkProtocol.failure(error)
        case .success(.status(let refresh)):
            if refresh { await refreshAll() }
            return TeraxLinkProtocol.success(status(refreshed: refresh))
        case .success(.action(let action)):
            if let error = await perform(action) { return TeraxLinkProtocol.failure(error) }
            return TeraxLinkProtocol.success(status())
        }
    }

    /// Changes go through the same managers as the dashboard tiles. Nothing here may show an admin
    /// prompt: nobody is at the Mac to answer it.
    private func perform(_ action: TeraxLinkProtocol.Action) async -> TeraxLinkProtocol.LinkError? {
        switch action {
        case .lock:
            RestModeManager.turnDisplayOff()
        case .rest(let on):
            if on { app.restMode.start() } else { app.restMode.stop(wakeDisplay: true) }
        case .awake(let on, let seconds):
            if on { app.antiSleep.activate(duration: seconds) } else { app.antiSleep.deactivate() }
        case .lid(let on, let seconds):
            guard on else {
                app.antiSleep.deactivateLid()
                break
            }
            guard SMCHelperManager.isHelperInstalledSync else {
                return .refused("Closed-lid needs the MenuTools helper. Turn it on once on the Mac.")
            }
            app.antiSleep.activateLid(duration: seconds)
            // `disablesleep 1` runs on a worker; the reply waits for it so a failure is reported, not polled.
            var waited: TimeInterval = 0
            while app.antiSleep.lidWorking, waited < 5 {
                try? await Task.sleep(for: .milliseconds(50))
                waited += 0.05
            }
            if let error = app.antiSleep.lidError { return .refused(error) }
        case .lowPower(let on):
            guard SMCHelperManager.isHelperInstalledSync else {
                return .refused("Low Power Mode needs the MenuTools helper. Turn it on once on the Mac.")
            }
            guard app.battery.isLowPowerMode != on else { break }
            let changed = await SMCHelperManager.shared.setLowPowerMode(enabled: on, allowPrompt: false)
            guard changed else { return .refused("Could not change Low Power Mode") }
            app.battery.refreshBatteryState()
            if app.battery.isLowPowerMode != on { app.battery.isLowPowerMode = on }
        case .sleepWhenDone(let on):
            app.afterDone.setSleep(on)
        case .wakeWhenDone(let on):
            app.afterDone.setWake(on)
        case .alarm:
            app.afterDone.stopAlarm()
        case .paneFocused(let pid):
            app.checkSessions(underShell: pid)
        }
        return nil
    }

    /// What a refresh re-reads: the same reads the timers make, run now. Nothing is marked seen.
    /// At most once per `refreshInterval`: the session reads run on the main thread, and a phone
    /// polling with `refresh` would otherwise stall the panel.
    private func refreshAll() async {
        let now = Date()
        guard now.timeIntervalSince(lastRefresh) >= Self.refreshInterval else { return }
        lastRefresh = now
        app.claudeSessions.refreshNow()
        app.cursorSessions.refreshNow()
        app.codexSessions.refreshNow()
        app.antigravitySessions.refreshNow()
        app.battery.refreshBatteryState()
        await app.network.refreshStatusNow()
    }

    func status(now: Date = Date(), refreshed: Bool = false) -> LinkStatus {
        LinkStatus(
            updatedAt: now.epochMilliseconds,
            refreshed: refreshed,
            sessions: LinkSessionOrder.arrange(sessions(), nowMs: now.epochMilliseconds),
            stats: stats(),
            battery: battery(),
            power: power())
    }

    private func sessions() -> [LinkSession] {
        var rows: [LinkSession] = []
        let claude = app.claudeSessions
        for session in claude.sessions {
            let finish = claude.finished[session.id]
            let state: LinkSession.State =
                session.needsInput ? .input : session.isWorking ? .running : finish != nil ? .done : .idle
            rows.append(
                LinkSession(
                    agent: "claude", name: session.name, project: session.project, state: state,
                    detail: session.needsInput ? session.waitingFor : nil,
                    since: (state == .done ? finish?.finishedAt : session.startedAt)?.epochMilliseconds,
                    badge: claude.usage[session.id]?.badge, pid: session.pid))
        }
        for session in app.cursorSessions.sessions {
            let state: LinkSession.State =
                session.needsInput
                ? .input : session.status == "running" ? .running : session.status == "done" ? .done : .idle
            rows.append(
                LinkSession(
                    agent: "cursor", name: session.name, project: session.project, state: state,
                    detail: session.needsInput ? session.waitingFor : nil,
                    since: session.startedAt?.epochMilliseconds, badge: session.usage?.badge, pid: session.pid))
        }
        for session in app.codexSessions.sessions {
            rows.append(
                LinkSession(
                    agent: "codex", name: session.name, project: session.project, state: .running, detail: nil,
                    since: session.startedAt?.epochMilliseconds, badge: session.usage?.badge, pid: session.pid))
        }
        for session in app.antigravitySessions.sessions {
            let state: LinkSession.State =
                session.needsInput ? .input : session.status == "running" ? .running : .idle
            rows.append(
                LinkSession(
                    agent: "antigravity", name: session.name, project: session.project, state: state,
                    detail: session.needsInput ? session.waitingFor : nil,
                    since: session.startedAt?.epochMilliseconds, badge: nil, pid: session.pid))
        }
        for ended in app.cursorSessions.ended {
            rows.append(
                LinkSession(
                    agent: "cursor", name: ended.name, project: ended.project, state: .ended, detail: nil,
                    since: ended.endedAt.epochMilliseconds, badge: nil))
        }
        for ended in app.codexSessions.ended {
            rows.append(
                LinkSession(
                    agent: "codex", name: ended.name, project: ended.project, state: .ended, detail: nil,
                    since: ended.endedAt.epochMilliseconds, badge: ended.usage?.badge))
        }
        for ended in app.antigravitySessions.ended {
            rows.append(
                LinkSession(
                    agent: "antigravity", name: ended.name, project: ended.project, state: .ended, detail: nil,
                    since: ended.endedAt.epochMilliseconds, badge: nil))
        }
        return rows
    }

    private func stats() -> LinkStats {
        let snap = app.systemMonitor.details.snapshot
        let startup = snap.disks.first(where: \.isStartup) ?? snap.disks.first
        return LinkStats(
            cpu: snap.cpuUsage,
            cpuHistory: Array(snap.cpuHistory.suffix(30)),
            memory: snap.memoryPercent,
            memoryUsedGB: snap.memoryUsedGB,
            memoryTotalGB: snap.memoryTotalGB,
            memoryPressure: snap.memoryPressure,
            temperature: snap.temperature > 0 ? snap.temperature : nil,
            gpu: snap.gpuUsage,
            downKBps: snap.downloadKBps,
            upKBps: snap.uploadKBps,
            load1: snap.load1,
            uptime: snap.uptime,
            disk: startup.map {
                LinkStats.Disk(usedPercent: $0.usedFraction * 100, freeBytes: $0.availableBytes)
            })
    }

    private func battery() -> LinkBattery? {
        let battery = app.battery
        guard battery.hasBattery else { return nil }
        return LinkBattery(
            percent: battery.percentage, charging: battery.isCharging, pluggedIn: battery.isPluggedIn,
            timeRemaining: battery.timeRemainingFormatted)
    }

    private func power() -> LinkPower {
        let sleep = app.antiSleep
        return LinkPower(
            awake: .init(
                on: sleep.awakeOn, remaining: sleep.awakeOn && sleep.awakeRemaining > 0 ? sleep.awakeRemaining : nil),
            lid: .init(
                on: sleep.lidOn, remaining: sleep.lidOn && sleep.lidRemaining > 0 ? sleep.lidRemaining : nil,
                error: sleep.lidError),
            lowPower: app.battery.isLowPowerMode,
            rest: .init(on: app.restMode.isOn, since: app.restMode.since?.epochMilliseconds),
            afterDone: .init(
                sleep: app.afterDone.sleepArmed, wake: app.afterDone.wakeArmed, alarm: app.afterDone.alarmOn,
                alarmSince: app.afterDone.alarmSince?.epochMilliseconds, busy: app.afterDone.busyText),
            vpn: app.network.isVPNConnected,
            spoofDPI: app.network.isSpoofDPIRunning,
            helper: SMCHelperManager.isHelperInstalledSync)
    }
}
