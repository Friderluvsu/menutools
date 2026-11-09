import Foundation
import SQLite3

/// One live Codex CLI process, optionally named from `~/.codex/state_*.sqlite`.
struct CodexSession: Identifiable, Equatable, Sendable {
    let pid: pid_t
    let name: String
    let project: String
    let cwd: String
    let subtitle: String
    let status: String
    let startedAt: Date?
    /// Cumulative tokens from the thread's rollout log. Nil until the first turn finishes.
    var usage: SessionUsage? = nil

    var id: String { "\(pid)" }
    var needsInput: Bool { false }
    var statusTitle: String { "Running" }

    var shortCwd: String { Self.shorten(cwd) }

    func uptime(now: Date) -> String {
        guard let startedAt else { return "—" }
        let seconds = Int(now.timeIntervalSince(startedAt))
        if seconds < 60 { return "now" }
        return AIResetFormatter.short(until: now.addingTimeInterval(TimeInterval(seconds)), now: now)
    }

    var tooltip: String {
        [name, cwd, "pid \(pid)"].filter { !$0.isEmpty }.joined(separator: "\n")
    }

    static func shorten(_ cwd: String) -> String {
        let home = NSHomeDirectory()
        if cwd.hasPrefix(home) { return "~" + cwd.dropFirst(home.count) }
        return cwd.isEmpty ? "—" : cwd
    }

    static let samples: [CodexSession] = [
        CodexSession(
            pid: 4242,
            name: "HR answers",
            project: "e",
            cwd: NSHomeDirectory() + "/Documents/Codex/2026-08-05/e",
            subtitle: "Отвечай кратко на HR вопросы",
            status: "running",
            startedAt: Date(timeIntervalSinceNow: -14 * 60),
            usage: .codexSample
        )
    ]
}

struct CodexEndedSession: Identifiable, Equatable, Codable, Sendable {
    var id: String
    var name: String
    var project: String
    var cwd: String
    var subtitle: String
    var endedAt: Date
    var seen: Bool
    /// Tokens at the time the process exited.
    var usage: SessionUsage? = nil

    var shortCwd: String { CodexSession.shorten(cwd) }

    static let sample = CodexEndedSession(
        id: "codex-ended-sample",
        name: "Interview cheat sheet",
        project: "for-whatever-you-want-to-do",
        cwd: NSHomeDirectory() + "/Documents/Codex/2026-07-29/for-whatever-you-want-to-do",
        subtitle: "Create AI interview cheat sheet",
        endedAt: Date(timeIntervalSinceNow: -50),
        seen: false,
        usage: .codexSample
    )
}

struct CodexFact: Equatable, Codable, Sendable {
    var pid: pid_t
    var name: String
    var project: String
    var cwd: String
    var subtitle: String
    var usage: SessionUsage? = nil

    var id: String { "\(pid)" }

    /// Equal apart from the token counts.
    func sameChat(as other: CodexFact) -> Bool {
        pid == other.pid && name == other.name && project == other.project && cwd == other.cwd
            && subtitle == other.subtitle
    }
}

enum CodexSessionFiles {
    static var home: URL {
        if let env = ProcessInfo.processInfo.environment["CODEX_HOME"], !env.isEmpty {
            return URL(fileURLWithPath: env, isDirectory: true)
        }
        return URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true).appendingPathComponent(
            ".codex", isDirectory: true)
    }

    static func load() -> [CodexSession] {
        // Processes first: with no Codex running (the usual case) the thread database is not opened.
        let pids = ProcessLookup.liveCodexPids()
        guard !pids.isEmpty else { return [] }
        let threads = CodexThreadDB.threadsByCwd()
        var sessions: [CodexSession] = []
        for pid in pids {
            let cwd = ProcessLookup.workingDirectory(pid) ?? ""
            let thread = threads[cwd]
            let project = URL(fileURLWithPath: cwd).lastPathComponent
            let title = (thread?.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            sessions.append(
                CodexSession(
                    pid: pid,
                    name: title.isEmpty ? (project.isEmpty ? "Codex" : project) : title,
                    project: project.isEmpty ? "—" : project,
                    cwd: cwd,
                    subtitle: thread?.preview ?? "",
                    status: "running",
                    startedAt: thread?.updatedAt,
                    usage: thread.flatMap { CodexRolloutUsage.usage(rolloutPath: $0.rolloutPath) }
                ))
        }
        return sessions.sorted { ($0.startedAt ?? .distantPast) > ($1.startedAt ?? .distantPast) }
    }
}

private struct CodexThread {
    var title: String
    var preview: String
    var updatedAt: Date?
    var rolloutPath: String
}

private enum CodexThreadDB {
    static func threadsByCwd() -> [String: CodexThread] {
        guard let url = newestStateURL() else { return [:] }
        var handle: OpaquePointer?
        guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else {
            sqlite3_close(handle)
            return [:]
        }
        defer { sqlite3_close(handle) }
        sqlite3_busy_timeout(handle, 200)
        let sql = "SELECT cwd, title, preview, updated_at_ms, rollout_path FROM threads WHERE archived = 0"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else { return [:] }
        defer { sqlite3_finalize(statement) }
        var result: [String: CodexThread] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            let cwd = text(statement, 0)
            guard !cwd.isEmpty else { continue }
            let ms = sqlite3_column_int64(statement, 3)
            result[cwd] = CodexThread(
                title: text(statement, 1),
                preview: text(statement, 2),
                updatedAt: ms > 1_000_000_000_000 ? Date(timeIntervalSince1970: Double(ms) / 1000) : nil,
                rolloutPath: text(statement, 4)
            )
        }
        return result
    }

    private static func newestStateURL() -> URL? {
        let dir = CodexSessionFiles.home
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return nil }
        let files = names.filter { $0.hasPrefix("state_") && $0.hasSuffix(".sqlite") }
        let url = files.compactMap { name -> (URL, Date)? in
            let file = dir.appendingPathComponent(name)
            let modified =
                (try? FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date)
                ?? .distantPast
            return (file, modified)
        }.max { $0.1 < $1.1 }?.0
        return url
    }

    private static func text(_ statement: OpaquePointer?, _ index: Int32) -> String {
        guard let bytes = sqlite3_column_text(statement, index) else { return "" }
        return String(cString: bytes)
    }
}
