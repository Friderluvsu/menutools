import Foundation
import SwiftUI

/// Live Antigravity conversations. Reads the IDE's and the agy CLI's `conversation_summaries.db` while either runs.
@MainActor
final class AntigravitySessionsManager: ObservableObject {
    @Published private(set) var sessions: [AntigravitySession] = []
    @Published private(set) var ended: [AntigravityEndedSession] = []

    private let previewMode: Bool
    private var timer: Timer?
    private var tracking: [String: AntigravityFact] = [:]
    private var panelOpen = false
    /// Conversation ids we already announced as needing input. Cleared when that chat is seen not waiting.
    private var awaitingInput: Set<String> = []
    private var pollInterval: TimeInterval = 15
    private var loading = false
    private var refreshAgain = false
    private var loadGeneration = 0
    /// Every scan runs here, the synchronous ones too: the scan keeps static caches.
    private static let scanQueue = DispatchQueue(label: "MenuTools.AntigravityScan", qos: .utility)

    private static let fastInterval: TimeInterval = 2
    private static let idleInterval: TimeInterval = 15

    var hasUnseenEnded: Bool { ended.contains { !$0.seen } }

    init(previewMode: Bool = false) {
        self.previewMode = previewMode
        if previewMode {
            sessions = AntigravitySession.samples
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

    func reveal(_ session: AntigravitySession) {
        if let pid = session.pid, TeraxReveal.reveal(pid: pid, state: session.needsInput ? .input : nil) {
            return
        }
        AppWindowFocus.reveal(
            named: ["Antigravity IDE", "Antigravity"],
            bundles: ["Antigravity IDE.app", "Antigravity.app"],
            project: session.project, cwd: session.cwd)
    }

    func revealEnded(_ item: AntigravityEndedSession) {
        AppWindowFocus.reveal(
            named: ["Antigravity IDE", "Antigravity"],
            bundles: ["Antigravity IDE.app", "Antigravity.app"],
            project: item.project, cwd: item.cwd)
        check(item.id)
    }

    private func reschedule() {
        let interval = panelOpen || ProcessLookup.isLiveAntigravity() ? Self.fastInterval : Self.idleInterval
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

    /// Timer ticks and the panel opening read the database off the main thread (up to 30 ms, which
    /// stalled the panel's page fades). Launch and a Terax refresh read synchronously.
    private func refresh(inBackground: Bool = false) {
        guard inBackground else {
            loadGeneration += 1
            apply(Self.scanQueue.sync { AntigravitySessionFiles.scan() })
            return
        }
        guard !loading else {
            refreshAgain = true
            return
        }
        loading = true
        let generation = loadGeneration
        Self.scanQueue.async { [weak self] in
            let scan = AntigravitySessionFiles.scan()
            DispatchQueue.main.async {
                MainActor.assumeIsolated { [weak self] in
                    guard let self else { return }
                    self.loading = false
                    // A synchronous read landed meanwhile: this snapshot is older than it.
                    if generation == self.loadGeneration { self.apply(scan) }
                    if self.refreshAgain {
                        self.refreshAgain = false
                        self.refresh(inBackground: true)
                    }
                }
            }
        }
    }

    private func apply(_ scan: (appRunning: Bool, live: [AntigravitySession]?, facts: [AntigravityFact]?)) {
        defer { NotificationCenter.default.post(name: .sessionMenuMarksChanged, object: nil) }
        // A failed read must not wipe the live rows. That left only the previous Ended row while a question was open.
        guard let live = scan.live, let facts = scan.facts else {
            reschedule()
            return
        }
        if live != sessions { sessions = live }
        guard scan.appRunning else {
            reschedule()
            return
        }
        let byID = Dictionary(facts.map { ($0.id, $0) }, uniquingKeysWith: { first, second in
            if first.running != second.running { return first.running ? first : second }
            return first.name.isEmpty ? second : first
        })
        var changed = false
        // Same conversation id resumed after an Ended row: drop the stale Ended so the card is not duplicated.
        // An open agy whose conversation is at rest is listed as idle; it does not count as resumed.
        let liveIDs = Set(live.filter { $0.status != "idle" }.map(\.id))
        if ended.contains(where: { liveIDs.contains($0.id) }) {
            ended.removeAll { liveIDs.contains($0.id) }
            changed = true
        }
        let openIDs = Set(live.map(\.id))
        var finished: [AntigravityEndedSession] = []
        var finishedOpen: [AntigravityEndedSession] = []
        for (id, tracked) in tracking {
            guard let fact = byID[id] else { continue }
            let isRunning = fact.running || liveIDs.contains(id)
            if isRunning {
                if fact != tracked {
                    var updated = fact
                    updated.running = true
                    tracking[id] = updated
                    changed = true
                }
            } else {
                tracking.removeValue(forKey: id)
                changed = true
                guard !ended.contains(where: { $0.id == id }) else { continue }
                let item = AntigravityEndedSession(
                    id: id,
                    name: fact.name.isEmpty ? tracked.name : fact.name,
                    project: fact.project,
                    cwd: fact.cwd.isEmpty ? tracked.cwd : fact.cwd,
                    subtitle: fact.subtitle.isEmpty ? tracked.subtitle : fact.subtitle,
                    endedAt: Date(),
                    seen: false
                )
                // Still open in agy: its own row shows it at rest, so only the notification goes out.
                if openIDs.contains(id) {
                    finishedOpen.append(item)
                } else {
                    finished.append(item)
                }
            }
        }
        for session in live where session.status != "idle" {
            let baseFact = byID[session.id] ?? AntigravityFact(
                id: session.id, name: session.name, project: session.project,
                cwd: session.cwd, subtitle: session.subtitle, running: true
            )
            var activeFact = baseFact
            activeFact.running = true
            if tracking[session.id] != activeFact {
                tracking[session.id] = activeFact
                changed = true
            }
        }
        if !finished.isEmpty {
            ended.append(contentsOf: finished)
            changed = true
        }
        if !finished.isEmpty || !finishedOpen.isEmpty {
            SessionNotifier.ensurePermission()
            for item in finished + finishedOpen { notify(item) }
        }
        if absorbInput(live) { changed = true }
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

    /// Returns true when the set of waiting chats changed. Does not save.
    private func absorbInput(_ live: [AntigravitySession]) -> Bool {
        let waiting = live.filter(\.needsInput)
        let ids = Set(waiting.map(\.id))
        guard awaitingInput != ids else { return false }
        let fresh = waiting.filter { !awaitingInput.contains($0.id) }
        awaitingInput = ids
        if !fresh.isEmpty {
            SessionNotifier.ensurePermission()
            for item in fresh { notifyInput(item) }
        }
        return true
    }

    private func notifyInput(_ item: AntigravitySession) {
        SessionNotifier.post(
            title: "Antigravity needs input", name: item.name, project: item.project, identifier: "agy-input-\(item.id)")
    }

    private func notify(_ item: AntigravityEndedSession) {
        SessionNotifier.post(
            title: "Antigravity finished", name: item.name, project: item.project, identifier: "agy-ended-\(item.id)",
            session: "agy:\(item.id)")
    }

    private static var storeURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MenuTools", isDirectory: true)
            .appendingPathComponent("antigravity-session-watch.json")
    }

    private func load() {
        guard let data = try? Data(contentsOf: Self.storeURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        guard let file = try? decoder.decode(WatchFile.self, from: data) else { return }
        tracking = Dictionary(file.tracking.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        ended = file.ended
        awaitingInput = Set(file.awaitingInput)
    }

    private func save() {
        let file = WatchFile(tracking: Array(tracking.values), ended: ended, awaitingInput: Array(awaitingInput))
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        guard let data = try? encoder.encode(file) else { return }
        let url = Self.storeURL
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}

private struct WatchFile: Codable {
    var tracking: [AntigravityFact]
    var ended: [AntigravityEndedSession]
    var awaitingInput: [String]

    init(tracking: [AntigravityFact], ended: [AntigravityEndedSession], awaitingInput: [String]) {
        self.tracking = tracking
        self.ended = ended
        self.awaitingInput = awaitingInput
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        tracking = try container.decode([AntigravityFact].self, forKey: .tracking)
        ended = try container.decode([AntigravityEndedSession].self, forKey: .ended)
        awaitingInput = try container.decodeIfPresent([String].self, forKey: .awaitingInput) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(tracking, forKey: .tracking)
        try container.encode(ended, forKey: .ended)
        try container.encode(awaitingInput, forKey: .awaitingInput)
    }

    private enum CodingKeys: String, CodingKey {
        case tracking, ended, awaitingInput
    }
}
