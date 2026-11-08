import AppKit
import Foundation
import SwiftUI
import UserNotifications

/// Live Cursor agent chats, and a record of chats that finished after MenuTools saw them running.
@MainActor
final class CursorSessionsManager: ObservableObject {
    @Published private(set) var sessions: [CursorSession] = []
    @Published private(set) var ended: [CursorEndedSession] = []
    /// Ended ids that were new when this panel open started. They stay blue until the panel closes.
    @Published private(set) var freshEnded: Set<String> = []

    private let previewMode: Bool
    private var timer: Timer?
    private var tracking: [String: CursorComposerFact] = [:]
    private var askedPermission = false
    private var panelOpen = false
    /// Session ids we already announced as needing input. Cleared when that chat is seen not waiting.
    private var awaitingInput: Set<String> = []
    private var pollInterval: TimeInterval = 15

    private static let fastInterval: TimeInterval = 2
    private static let idleInterval: TimeInterval = 15

    var hasUnseenEnded: Bool { ended.contains { !$0.seen } }

    init(previewMode: Bool = false) {
        self.previewMode = previewMode
        if previewMode {
            sessions = CursorSession.samples
            ended = [.sample]
            return
        }
        load()
        ensureNotificationPermission()
        refresh()
        reschedule()
    }

    /// Panel opened: refresh quickly, and remember which ended rows are still new.
    func startMonitoring() {
        guard !previewMode else { return }
        panelOpen = true
        noteFreshEnded()
        refresh()
        reschedule()
    }

    /// Panel closed. Ended rows stay until dismissed, so two finishes are not lost if you close between them.
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

    /// Raises the Cursor window for this project, then brings Cursor forward.
    func reveal(_ session: CursorSession) {
        CursorWindowFocus.reveal(project: session.project, cwd: session.cwd)
    }

    func revealEnded(_ item: CursorEndedSession) {
        CursorWindowFocus.reveal(project: item.project, cwd: item.cwd)
        if let index = ended.firstIndex(where: { $0.id == item.id }), !ended[index].seen {
            ended[index].seen = true
            save()
        }
    }

    private func reschedule() {
        let interval = panelOpen || ProcessLookup.isRunning(named: "Cursor", missRetry: 4) ? Self.fastInterval : Self.idleInterval
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
        let scan = CursorSessionFiles.scan()
        // A busy lock on Cursor's multi-GB DB used to return empty live rows and blank the ring until
        // the panel opened (immediate refresh). Keep the last good list instead.
        if scan.readFailed {
            reschedule()
            return
        }
        if scan.live != sessions { sessions = scan.live }
        // Cursor quitting is not a chat finishing. Leave the tracked runs in place until the headers say so.
        guard scan.cursorRunning else {
            reschedule()
            return
        }
        let byID = Dictionary(scan.facts.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var changed = false
        // Same composer id resumed after an Ended row: drop the stale Ended so the card is not duplicated.
        let liveIDs = Set(scan.live.map(\.id))
        if ended.contains(where: { liveIDs.contains($0.id) }) {
            ended.removeAll { liveIDs.contains($0.id) }
            changed = true
        }
        var finished: [CursorEndedSession] = []
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
                finished.append(
                    CursorEndedSession(
                        id: id,
                        name: fact.name.isEmpty ? tracked.name : fact.name,
                        project: fact.project,
                        cwd: fact.cwd.isEmpty ? tracked.cwd : fact.cwd,
                        subtitle: fact.subtitle.isEmpty ? tracked.subtitle : fact.subtitle,
                        endedAt: Date(),
                        seen: false
                    ))
            }
        }
        // Anything the card already shows as running must be watched, including a second chat that just started.
        for session in scan.live where session.status == "running" {
            guard let fact = byID[session.id] else { continue }
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
        if absorbInput(scan.live) { changed = true }
        if changed { save() }
        reschedule()
    }

    /// Remember which ended rows are new. They stay blue, and the menu bar stays blue, until the row is on screen.
    private func noteFreshEnded() {
        freshEnded = Set(ended.filter { !$0.seen }.map(\.id))
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

    /// Returns true when the set of waiting chats changed. Does not save.
    private func absorbInput(_ live: [CursorSession]) -> Bool {
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

    private func notifyInput(_ item: CursorSession) {
        let content = UNMutableNotificationContent()
        content.title = "Cursor needs input"
        content.body = item.project == "—" || item.project.isEmpty ? item.name : "\(item.name) · \(item.project)"
        content.sound = .default
        let request = UNNotificationRequest(identifier: "cursor-input-\(item.id)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    private func notify(_ item: CursorEndedSession) {
        let content = UNMutableNotificationContent()
        content.title = "Cursor finished"
        content.body = item.project == "—" ? item.name : "\(item.name) · \(item.project)"
        content.sound = .default
        let request = UNNotificationRequest(identifier: "cursor-ended-\(item.id)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
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
