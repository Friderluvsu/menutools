import Foundation
import SwiftUI
import UserNotifications

/// Live Codex CLI processes. A process exiting is the chat ending (unlike Cursor, which keeps headers).
@MainActor
final class CodexSessionsManager: ObservableObject {
    @Published private(set) var sessions: [CodexSession] = []
    @Published private(set) var ended: [CodexEndedSession] = []
    /// Ended ids that were new when this panel open started. They stay blue until the panel closes.
    @Published private(set) var freshEnded: Set<String> = []

    private let previewMode: Bool
    private var timer: Timer?
    private var tracking: [String: CodexFact] = [:]
    private var askedPermission = false
    private var panelOpen = false
    private var pollInterval: TimeInterval = 15

    private static let fastInterval: TimeInterval = 2
    private static let idleInterval: TimeInterval = 15

    var hasUnseenEnded: Bool { ended.contains { !$0.seen } }

    init(previewMode: Bool = false) {
        self.previewMode = previewMode
        if previewMode {
            sessions = CodexSession.samples
            ended = [.sample]
            return
        }
        load()
        ensureNotificationPermission()
        refresh()
        reschedule()
    }

    func startMonitoring() {
        guard !previewMode else { return }
        panelOpen = true
        noteFreshEnded()
        refresh()
        reschedule()
    }

    func stopMonitoring() {
        guard !previewMode else { return }
        panelOpen = false
        if !freshEnded.isEmpty { freshEnded = [] }
        reschedule()
    }

    func dismiss(_ id: String) {
        guard ended.contains(where: { $0.id == id }) else { return }
        ended.removeAll { $0.id == id }
        save()
    }

    func reveal(_ session: CodexSession) {
        AppWindowFocus.revealTerminal(for: session.pid)
    }

    func revealEnded(_ item: CodexEndedSession) {
        AppWindowFocus.reveal(
            named: ["ChatGPT", "Codex"], bundles: ["ChatGPT.app", "Codex.app"], project: item.project, cwd: item.cwd)
        if let index = ended.firstIndex(where: { $0.id == item.id }), !ended[index].seen {
            ended[index].seen = true
            save()
        }
    }

    private func reschedule() {
        // `sessions` was just loaded from the live pids; no second walk of the process table.
        let busy = panelOpen || !sessions.isEmpty || !tracking.isEmpty
        let interval = busy ? Self.fastInterval : Self.idleInterval
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
        let loaded = CodexSessionFiles.load()
        if loaded != sessions { sessions = loaded }
        let liveIDs = Set(loaded.map(\.id))
        var changed = false
        var finished: [CodexEndedSession] = []
        for (id, tracked) in tracking {
            if liveIDs.contains(id), ProcessLookup.isAlive(tracked.pid) {
                continue
            }
            tracking.removeValue(forKey: id)
            changed = true
            guard !ended.contains(where: { $0.id == id }) else { continue }
            finished.append(
                CodexEndedSession(
                    id: id, name: tracked.name, project: tracked.project, cwd: tracked.cwd,
                    subtitle: tracked.subtitle, endedAt: Date(), seen: false
                ))
        }
        for session in loaded {
            let fact = CodexFact(
                pid: session.pid, name: session.name, project: session.project, cwd: session.cwd,
                subtitle: session.subtitle)
            if tracking[session.id] != fact {
                tracking[session.id] = fact
                changed = true
            }
        }
        if !finished.isEmpty {
            ended.append(contentsOf: finished)
            changed = true
            ensureNotificationPermission()
            for item in finished { notify(item) }
        }
        if changed { save() }
        reschedule()
    }

    /// Remember which ended rows are new. They stay blue, and the menu bar stays blue, until the row is on screen.
    private func noteFreshEnded() {
        let fresh = Set(ended.filter { !$0.seen }.map(\.id))
        if fresh != freshEnded { freshEnded = fresh }
    }

    /// The ended rows are visible. Clear the menu-bar blue and keep the blue row until the panel closes.
    func acknowledgeEnded() {
        guard !previewMode, hasUnseenEnded else { return }
        freshEnded.formUnion(ended.filter { !$0.seen }.map(\.id))
        for index in ended.indices { ended[index].seen = true }
        save()
        NotificationCenter.default.post(name: .sessionMenuMarksChanged, object: nil)
    }

    private func ensureNotificationPermission() {
        guard !askedPermission else { return }
        askedPermission = true
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func notify(_ item: CodexEndedSession) {
        let content = UNMutableNotificationContent()
        content.title = "Codex finished"
        content.body = item.project == "—" ? item.name : "\(item.name) · \(item.project)"
        content.sound = .default
        let request = UNNotificationRequest(identifier: "codex-ended-\(item.id)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    private static var storeURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MenuTools", isDirectory: true)
            .appendingPathComponent("codex-session-watch.json")
    }

    private func load() {
        guard let data = try? Data(contentsOf: Self.storeURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        guard let file = try? decoder.decode(WatchFile.self, from: data) else { return }
        tracking = Dictionary(file.tracking.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        ended = file.ended
        // Pids from a previous launch are dead; drop them so a relaunch does not fire stale "finished" alerts.
        tracking = tracking.filter { ProcessLookup.isAlive($0.value.pid) }
    }

    private func save() {
        let file = WatchFile(tracking: Array(tracking.values), ended: ended)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        guard let data = try? encoder.encode(file) else { return }
        let url = Self.storeURL
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}

private struct WatchFile: Codable {
    var tracking: [CodexFact]
    var ended: [CodexEndedSession]
}
