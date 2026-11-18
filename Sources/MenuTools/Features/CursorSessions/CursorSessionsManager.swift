import AppKit
import Foundation
import SwiftUI

/// Live Cursor agent chats (the app and the terminal CLI), and a record of chats that finished after
/// MenuTools saw them running.
@MainActor
final class CursorSessionsManager: ObservableObject {
    @Published private(set) var sessions: [CursorSession] = []
    @Published private(set) var ended: [CursorEndedSession] = []

    private let previewMode: Bool
    private var timer: Timer?
    private var tracking: [String: CursorComposerFact] = [:]
    private var panelOpen = false
    /// Session ids we already announced as needing input. Cleared when that chat is seen not waiting.
    private var awaitingInput: Set<String> = []
    private var pollInterval: TimeInterval = 15
    private let cli = CursorCLIScanner()
    private var cliPresent = false
    private var loading = false
    private var refreshAgain = false
    private var loadGeneration = 0
    /// Every scan runs here, the synchronous ones too: the scan keeps static caches.
    private static let scanQueue = DispatchQueue(label: "MenuTools.CursorScan", qos: .utility)

    private static let fastInterval: TimeInterval = 2
    private static let idleInterval: TimeInterval = 15

    var hasUnseenEnded: Bool { ended.contains { !$0.seen } }

    init(previewMode: Bool = false) {
        self.previewMode = previewMode
        if previewMode {
            sessions = CursorSession.samples
            ended = [.sample, .checkedSample]
            return
        }
        load()
        SessionNotifier.ensurePermission()
        refresh()
        reschedule()
    }

    /// Panel opened: refresh quickly, and remember which ended rows are still new.
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

    /// Panel closed. Ended rows stay until dismissed, so two finishes are not lost if you close between them.
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

    /// Raises the Cursor window for this project, then brings Cursor forward.
    func reveal(_ session: CursorSession) {
        if let pid = session.pid {
            let state: TeraxReveal.State =
                session.needsInput
                ? .input : session.status == "running" ? .running : session.status == "done" ? .done : .idle
            AppWindowFocus.revealTerminal(for: pid, state: state)
        } else {
            CursorWindowFocus.reveal(project: session.project, cwd: session.cwd)
        }
    }

    func revealEnded(_ item: CursorEndedSession) {
        CursorWindowFocus.reveal(project: item.project, cwd: item.cwd)
        check(item.id)
    }

    private func reschedule() {
        let fast = panelOpen || cliPresent || ProcessLookup.isRunning(named: "Cursor", missRetry: 4)
        let interval = fast ? Self.fastInterval : Self.idleInterval
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
            apply(Self.scanQueue.sync { CursorSessionFiles.scan() })
            return
        }
        guard !loading else {
            refreshAgain = true
            return
        }
        loading = true
        let generation = loadGeneration
        Self.scanQueue.async { [weak self] in
            let scan = CursorSessionFiles.scan()
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

    private func apply(_ scan: CursorScan) {
        defer { NotificationCenter.default.post(name: .sessionMenuMarksChanged, object: nil) }
        // A busy lock on Cursor's multi-GB DB used to return empty live rows and blank the ring until
        // the panel opened (immediate refresh). Keep the last good list instead.
        if scan.readFailed {
            reschedule()
            return
        }
        let terminal = cli.scan()
        cliPresent = terminal.present
        let live = Self.ordered(scan.live + terminal.live)
        if live != sessions { sessions = live }
        // Cursor quitting is not a chat finishing. Leave the tracked runs in place until the headers say so.
        guard scan.cursorRunning || !terminal.facts.isEmpty else {
            reschedule()
            return
        }
        let facts = scan.facts + terminal.facts
        let byID = Dictionary(facts.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var changed = false
        // Same composer id resumed after an Ended row: drop the stale Ended so the card is not duplicated.
        // An open CLI chat that only sits at its prompt is listed too; it does not count as resumed.
        let liveIDs = Set(live.filter { $0.status == "running" || $0.needsInput }.map(\.id))
        if ended.contains(where: { liveIDs.contains($0.id) }) {
            ended.removeAll { liveIDs.contains($0.id) }
            changed = true
        }
        let openIDs = Set(live.map(\.id))
        var finished: [CursorEndedSession] = []
        var finishedOpen: [CursorEndedSession] = []
        for (id, tracked) in tracking {
            guard let fact = byID[id] else { continue }
            if fact.unfinished {
                if fact != tracked {
                    tracking[id] = fact
                    changed = true
                }
            } else {
                tracking.removeValue(forKey: id)
                changed = true
                guard !ended.contains(where: { $0.id == id }) else { continue }
                let item = CursorEndedSession(
                    id: id,
                    name: fact.name.isEmpty ? tracked.name : fact.name,
                    project: fact.project,
                    cwd: fact.cwd.isEmpty ? tracked.cwd : fact.cwd,
                    subtitle: fact.subtitle.isEmpty ? tracked.subtitle : fact.subtitle,
                    endedAt: Date(),
                    seen: false
                )
                // A CLI chat still open shows its finished turn on its own row as Done.
                if openIDs.contains(id) {
                    finishedOpen.append(item)
                } else {
                    finished.append(item)
                }
            }
        }
        // Anything the card already shows as running must be watched, including a second chat that just started.
        for session in live where session.status == "running" {
            guard let fact = byID[session.id] else { continue }
            if tracking[session.id] != fact {
                tracking[session.id] = fact
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

    /// App chats first, so a chat both sources report is listed once.
    private static func ordered(_ live: [CursorSession]) -> [CursorSession] {
        var ids = Set<String>()
        return live.filter { ids.insert($0.id).inserted }.sorted { lhs, rhs in
            if lhs.needsInput != rhs.needsInput { return lhs.needsInput }
            return (lhs.startedAt ?? .distantPast) > (rhs.startedAt ?? .distantPast)
        }
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
    private func absorbInput(_ live: [CursorSession]) -> Bool {
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

    private func notifyInput(_ item: CursorSession) {
        SessionNotifier.post(
            title: "Cursor needs input", name: item.name, project: item.project, identifier: "cursor-input-\(item.id)")
    }

    private func notify(_ item: CursorEndedSession) {
        SessionNotifier.post(
            title: "Cursor finished", name: item.name, project: item.project, identifier: "cursor-ended-\(item.id)",
            session: "cursor:\(item.id)")
    }

    private static var storeURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MenuTools", isDirectory: true)
            .appendingPathComponent("cursor-session-watch.json")
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
    var tracking: [CursorComposerFact]
    var ended: [CursorEndedSession]
    var awaitingInput: [String]

    init(tracking: [CursorComposerFact], ended: [CursorEndedSession], awaitingInput: [String]) {
        self.tracking = tracking
        self.ended = ended
        self.awaitingInput = awaitingInput
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        tracking = try container.decode([CursorComposerFact].self, forKey: .tracking)
        ended = try container.decode([CursorEndedSession].self, forKey: .ended)
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
