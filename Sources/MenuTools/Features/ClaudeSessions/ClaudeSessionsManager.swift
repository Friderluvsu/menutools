import AppKit
import Foundation
import SwiftUI
import UserNotifications

/// Live Claude Code sessions. The directory watcher and timer stay on after launch so a waiting chat can mark the menu bar with the panel closed.
@MainActor
final class ClaudeSessionsManager: ObservableObject {
    @Published private(set) var sessions: [ClaudeSession] = []

    private let previewMode: Bool
    private var timer: Timer?
    private var watchSource: DispatchSourceFileSystemObject?
    private var askedPermission = false
    private var panelOpen = false
    private var pollInterval: TimeInterval = 15
    /// Pids we already announced as needing input. Dropped when that process is seen not waiting.
    private var awaitingInput: Set<String> = []

    private static let fastInterval: TimeInterval = 2
    private static let idleInterval: TimeInterval = 15

    init(previewMode: Bool = false) {
        self.previewMode = previewMode
        if previewMode {
            sessions = ClaudeSession.samples
            return
        }
        loadInputWatch()
        refresh()
    }

    /// Panel opened. The watch is already running; this only speeds the timer.
    func startMonitoring() {
        guard !previewMode else { return }
        panelOpen = true
        refresh()
    }

    /// Panel closed. The watcher and a slower timer stay, so a later wait still reaches the menu bar.
    func stopMonitoring() {
        guard !previewMode else { return }
        panelOpen = false
        reschedule()
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
        if absorbInput(loaded) { saveInputWatch() }
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
    }

    private func saveInputWatch() {
        let file = InputWatch(awaitingInput: Array(awaitingInput))
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

private struct InputWatch: Codable {
    var awaitingInput: [String]
}
