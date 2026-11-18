import Foundation
import SwiftUI

/// Live Codex CLI processes. A process exiting is the chat ending (unlike Cursor, which keeps headers).
@MainActor
final class CodexSessionsManager: ObservableObject {
    @Published private(set) var sessions: [CodexSession] = []
    @Published private(set) var ended: [CodexEndedSession] = []

    private let previewMode: Bool
    private var timer: Timer?
    private var tracking: [String: CodexFact] = [:]
    private var panelOpen = false
    private var pollInterval: TimeInterval = 15
    private var loading = false
    private var refreshAgain = false
    private var loadGeneration = 0

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
        SessionNotifier.ensurePermission()
        refresh()
        reschedule()
    }

    func startMonitoring() {
        guard !previewMode else { return }
        panelOpen = true
        refresh(inBackground: true)
        reschedule()
    }

    /// Re-reads now, for a Terax refresh. Changes nothing the panel shows as seen.
    func refreshNow() {
        guard !previewMode else { return }
        refresh()
    }

    func stopMonitoring() {
        guard !previewMode else { return }
        panelOpen = false
        reschedule()
    }

    func dismiss(_ id: String) {
        guard ended.contains(where: { $0.id == id }) else { return }
        ended.removeAll { $0.id == id }
        save()
        NotificationCenter.default.post(name: .sessionMenuMarksChanged, object: nil)
    }

    func reveal(_ session: CodexSession) {
        AppWindowFocus.revealTerminal(for: session.pid)
    }

    func revealEnded(_ item: CodexEndedSession) {
        AppWindowFocus.reveal(
            named: ["ChatGPT", "Codex"], bundles: ["ChatGPT.app", "Codex.app"], project: item.project, cwd: item.cwd)
        check(item.id)
    }

    private func reschedule() {
        // `sessions` was just loaded from the live pids; no second walk of the process table.
        let busy = panelOpen || !sessions.isEmpty || !tracking.isEmpty
        let interval = busy ? Self.fastInterval : Self.idleInterval
        guard timer == nil || pollInterval != interval else { return }
        pollInterval = interval
        timer?.invalidate()
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh(inBackground: true) }
        }
        timer.tolerance = interval == Self.fastInterval ? 0.5 : interval * 0.3
        // `.common` still fires while another app is tracking the mouse. `.default` does not.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// Timer ticks and the panel opening walk the process table (about 10 ms) off the main thread.
    /// Launch and a Terax refresh read synchronously, so their answer already has the rows.
    private func refresh(inBackground: Bool = false) {
        guard inBackground else {
            loadGeneration += 1
            apply(CodexSessionFiles.load())
            return
        }
        guard !loading else {
            refreshAgain = true
            return
        }
        loading = true
        let generation = loadGeneration
        Task.detached(priority: .utility) { [weak self] in
            let loaded = CodexSessionFiles.load()
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.loading = false
                // A synchronous read landed meanwhile: this snapshot is older than it.
                if generation == self.loadGeneration { self.apply(loaded) }
                if self.refreshAgain {
                    self.refreshAgain = false
                    self.refresh(inBackground: true)
                }
            }
        }
    }

    private func apply(_ loaded: [CodexSession]) {
        defer { NotificationCenter.default.post(name: .sessionMenuMarksChanged, object: nil) }
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
                    subtitle: tracked.subtitle, endedAt: Date(), seen: false, usage: tracked.usage
                ))
        }
        for session in loaded {
            let fact = CodexFact(
                pid: session.pid, name: session.name, project: session.project, cwd: session.cwd,
                subtitle: session.subtitle, usage: session.usage)
            // Tokens move on every tick of a run; they are kept in memory and reach the file with
            // the next save that another change triggers, or when the process ends.
            if tracking[session.id]?.sameChat(as: fact) != true {
                changed = true
            }
            tracking[session.id] = fact
        }
        if !finished.isEmpty {
            ended.append(contentsOf: finished)
            changed = true
            SessionNotifier.ensurePermission()
            for item in finished { notify(item) }
        }
        if changed { save() }
        reschedule()
    }

    /// The user dealt with this ended row (its click, its ✓, its notification). It turns grey and
    /// folds away with the quiet rows; dismissing removes it.
    func check(_ id: String) {
        guard !previewMode, let index = ended.firstIndex(where: { $0.id == id }), !ended[index].seen else { return }
        ended[index].seen = true
        save()
        NotificationCenter.default.post(name: .sessionMenuMarksChanged, object: nil)
    }

    func checkAll() {
        guard !previewMode, hasUnseenEnded else { return }
        for index in ended.indices { ended[index].seen = true }
        save()
        NotificationCenter.default.post(name: .sessionMenuMarksChanged, object: nil)
    }

    /// From a "finished" notification click.
    func revealEnded(id: String) {
        if let item = ended.first(where: { $0.id == id }) { revealEnded(item) }
    }

    private func notify(_ item: CodexEndedSession) {
        SessionNotifier.post(
            title: "Codex finished", name: item.name, project: item.project, identifier: "codex-ended-\(item.id)",
            session: "codex:\(item.id)")
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
