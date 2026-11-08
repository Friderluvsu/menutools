import AppKit
import Foundation
import SwiftUI
import UserNotifications

/// Live Claude Code sessions. The directory watcher and timer stay on after launch so a waiting chat can mark the menu bar with the panel closed.
@MainActor
final class ClaudeSessionsManager: ObservableObject {
    @Published private(set) var sessions: [ClaudeSession] = []
    /// Live sessions whose last run finished (Running → Idle), keyed by session id (pid).
    /// Cleared when that session starts working again or its process exits.
    @Published private(set) var finished: [String: ClaudeFinish] = [:]
    /// Finished ids that were unseen when this panel open started. They stay blue until the panel closes.
    @Published private(set) var freshFinished: Set<String> = []

    var hasUnseenFinished: Bool { finished.values.contains { !$0.seen } }

    /// Blue on the row: not seen yet, or seen during this panel visit.
    func isFreshFinish(_ id: String) -> Bool {
        guard let finish = finished[id] else { return false }
        return !finish.seen || freshFinished.contains(id)
    }

    private let previewMode: Bool
    private var timer: Timer?
    private var watchSource: DispatchSourceFileSystemObject?
    private var askedPermission = false
    private var panelOpen = false
    private var pollInterval: TimeInterval = 15
    /// Pids we already announced as needing input. Dropped when that process is seen not waiting.
    private var awaitingInput: Set<String> = []
    /// When each session's current run started (working or waiting on the user mid-run).
    private var runningSince: [String: Date] = [:]
    /// First read that saw the session idle after a run. A finish needs the idle to hold.
    private var idleSince: [String: Date] = [:]

    /// A run shorter than this finishing is not announced (quick replies).
    private static let minimumRun: TimeInterval = 10
    /// Idle must hold this long, so a brief idle between steps is not a finish.
    private static let idleHold: TimeInterval = 3

    private static let fastInterval: TimeInterval = 2
    private static let idleInterval: TimeInterval = 15

    init(previewMode: Bool = false) {
        self.previewMode = previewMode
        if previewMode {
            sessions = ClaudeSession.samples
            if let last = sessions.last(where: { !$0.isWorking && !$0.needsInput }) {
                finished[last.id] = ClaudeFinish(finishedAt: Date().addingTimeInterval(-90), ranFor: 240, seen: false)
            }
            return
        }
        loadInputWatch()
        refresh()
    }

    /// Panel opened. The watch is already running; this only speeds the timer.
    func startMonitoring() {
        guard !previewMode else { return }
        panelOpen = true
        freshFinished = Set(finished.filter { !$0.value.seen }.map(\.key))
        refresh()
    }

    /// Panel closed. The watcher and a slower timer stay, so a later wait still reaches the menu bar.
    func stopMonitoring() {
        guard !previewMode else { return }
        panelOpen = false
        if !freshFinished.isEmpty { freshFinished = [] }
        reschedule()
    }

    /// The finished rows are on screen. Clears the menu-bar blue; rows stay blue until the panel closes.
    func acknowledgeFinished() {
        guard !previewMode, hasUnseenFinished else { return }
        freshFinished.formUnion(finished.filter { !$0.value.seen }.map(\.key))
        for key in finished.keys { finished[key]?.seen = true }
        saveInputWatch()
    }

    /// Brings forward the terminal (or other app) that owns this Claude process.
    func reveal(_ session: ClaudeSession) {
        var pid = session.pid
        for _ in 0..<8 {
            guard let parent = ProcessLookup.parentPid(pid) else { return }
            if let app = NSRunningApplication(processIdentifier: parent), app.activationPolicy == .regular {
                app.activate(from: .current)
                return
            }
            pid = parent
        }
    }

    private func reschedule() {
        let interval = panelOpen || !sessions.isEmpty ? Self.fastInterval : Self.idleInterval
        guard timer == nil || pollInterval != interval else { return }
        pollInterval = interval
        timer?.invalidate()
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        timer.tolerance = interval == Self.fastInterval ? 0.5 : interval * 0.3
        // `.common` still fires while another app is tracking the mouse. `.default` does not.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func refresh() {
        defer { NotificationCenter.default.post(name: .sessionMenuMarksChanged, object: nil) }
        let loaded = ClaudeSessionFiles.load()
        if loaded != sessions { sessions = loaded }
        let inputChanged = absorbInput(loaded)
        if absorbRuns(loaded) || inputChanged { saveInputWatch() }
        startWatcherIfNeeded()
        reschedule()
    }

    private func absorbInput(_ live: [ClaudeSession]) -> Bool {
        let waiting = live.filter(\.needsInput)
        let ids = Set(waiting.map(\.id))
        guard awaitingInput != ids else { return false }
        let fresh = waiting.filter { !awaitingInput.contains($0.id) }
        awaitingInput = ids
        if !fresh.isEmpty {
            ensureNotificationPermission()
            for item in fresh { notifyInput(item) }
        }
        return true
    }

    /// Running → Idle after a real run is a finish: Done row, notification, menu bar blue.
    private func absorbRuns(_ live: [ClaudeSession]) -> Bool {
        let now = Date()
        let liveIDs = Set(live.map(\.id))
        var changed = false
        var nextFinished = finished.filter { liveIDs.contains($0.key) }
        if nextFinished.count != finished.count { changed = true }
        runningSince = runningSince.filter { liveIDs.contains($0.key) }
        idleSince = idleSince.filter { liveIDs.contains($0.key) }
        var fresh: [(ClaudeSession, ClaudeFinish)] = []
        for session in live {
            let id = session.id
            if session.isWorking || session.needsInput {
                // Still inside a run (a permission prompt is part of it). A new run clears Done.
                if runningSince[id] == nil {
                    runningSince[id] = now
                    changed = true
                }
                idleSince[id] = nil
                if session.isWorking, nextFinished.removeValue(forKey: id) != nil {
                    changed = true
                    freshFinished.remove(id)
                }
                continue
            }
            guard let start = runningSince[id] else { continue }
            let idleStart = idleSince[id] ?? now
            if idleSince[id] == nil { idleSince[id] = now }
            guard now.timeIntervalSince(idleStart) >= Self.idleHold else { continue }
            runningSince[id] = nil
            idleSince[id] = nil
            changed = true
            let ranFor = idleStart.timeIntervalSince(start)
            guard ranFor >= Self.minimumRun else { continue }
            let finish = ClaudeFinish(finishedAt: idleStart, ranFor: ranFor, seen: false)
            nextFinished[id] = finish
            fresh.append((session, finish))
        }
        if nextFinished != finished { finished = nextFinished }
        if !fresh.isEmpty {
            ensureNotificationPermission()
            for (session, finish) in fresh { notifyFinished(session, finish) }
        }
        return changed
    }

    private func notifyFinished(_ item: ClaudeSession, _ finish: ClaudeFinish) {
        let content = UNMutableNotificationContent()
        content.title = "Claude finished"
        let project = item.project
        let place = project.isEmpty || project == "—" ? item.name : "\(item.name) · \(project)"
        content.body = "\(place) · ran \(ClaudeFinish.duration(finish.ranFor))"
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: "claude-finished-\(item.id)-\(Int(finish.finishedAt.timeIntervalSince1970))",
            content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    private func ensureNotificationPermission() {
        guard !askedPermission else { return }
        askedPermission = true
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func notifyInput(_ item: ClaudeSession) {
        let content = UNMutableNotificationContent()
        content.title = "Claude needs input"
        let project = item.project
        content.body = project.isEmpty || project == "—" ? item.name : "\(item.name) · \(project)"
        content.sound = .default
        let request = UNNotificationRequest(identifier: "claude-input-\(item.id)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    private static var storeURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MenuTools", isDirectory: true)
            .appendingPathComponent("claude-session-watch.json")
    }

    private func loadInputWatch() {
        guard let data = try? Data(contentsOf: Self.storeURL),
            let file = try? JSONDecoder().decode(InputWatch.self, from: data)
        else { return }
        awaitingInput = Set(file.awaitingInput)
        runningSince = file.runningSince ?? [:]
        finished = file.finished ?? [:]
    }

    private func saveInputWatch() {
        let file = InputWatch(awaitingInput: Array(awaitingInput), runningSince: runningSince, finished: finished)
        guard let data = try? JSONEncoder().encode(file) else { return }
        let url = Self.storeURL
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    private func startWatcherIfNeeded() {
        guard watchSource == nil else { return }
        let fd = open(ClaudeSessionFiles.directory.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .rename, .delete],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                // `.delete` is the directory itself going away. A session file appearing only sets `.write`.
                if source.data.contains(.delete) {
                    self.watchSource?.cancel()
                    self.watchSource = nil
                }
                self.refresh()
            }
        }
        source.setCancelHandler { close(fd) }
        watchSource = source
        source.resume()
    }
}

/// Saved so a relaunch mid-run still notices the finish, and an unseen Done stays unseen.
private struct InputWatch: Codable {
    var awaitingInput: [String]
    var runningSince: [String: Date]?
    var finished: [String: ClaudeFinish]?
}

/// A live session's last run finished.
struct ClaudeFinish: Codable, Equatable, Sendable {
    var finishedAt: Date
    var ranFor: TimeInterval
    var seen: Bool

    /// "45s", "12m", "1h 05m".
    static func duration(_ seconds: TimeInterval) -> String {
        let whole = Int(seconds)
        if whole < 60 { return "\(whole)s" }
        if whole < 3600 { return "\(whole / 60)m" }
        return String(format: "%dh %02dm", whole / 3600, (whole % 3600) / 60)
    }
}
