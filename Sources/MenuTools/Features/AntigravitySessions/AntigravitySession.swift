import Foundation
import SQLite3

/// One live Antigravity agent conversation, from `conversation_summaries.db`.
struct AntigravitySession: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let project: String
    let cwd: String
    let subtitle: String
    let status: String
    let waitingFor: String?
    let startedAt: Date?

    var needsInput: Bool { waitingFor != nil }

    var statusTitle: String {
        if let waitingFor, !waitingFor.isEmpty { return Self.leadingCapital(waitingFor) }
        return Self.leadingCapital(status.isEmpty ? "live" : status)
    }

    var shortCwd: String { Self.shorten(cwd) }

    func uptime(now: Date) -> String {
        guard let startedAt else { return "—" }
        let seconds = Int(now.timeIntervalSince(startedAt))
        if seconds < 60 { return "now" }
        return AIResetFormatter.short(until: now.addingTimeInterval(TimeInterval(seconds)), now: now)
    }

    var tooltip: String {
        [name, cwd, statusTitle, subtitle, id].filter { !$0.isEmpty }.joined(separator: "\n")
    }

    private static func leadingCapital(_ raw: String) -> String {
        guard let first = raw.first else { return raw }
        return first.uppercased() + raw.dropFirst()
    }

    static func shorten(_ cwd: String) -> String {
        let home = NSHomeDirectory()
        if cwd.hasPrefix(home) { return "~" + cwd.dropFirst(home.count) }
        return cwd.isEmpty ? "—" : cwd
    }

    static let samples: [AntigravitySession] = [
        AntigravitySession(
            id: "agy-sample-run",
            name: "Lowrider scene",
            project: "3d-models",
            cwd: NSHomeDirectory() + "/3d-models",
            subtitle: "Interactive 3D Lowrider Experience",
            status: "running",
            waitingFor: nil,
            startedAt: Date(timeIntervalSinceNow: -22 * 60)
        )
    ]
}

struct AntigravityEndedSession: Identifiable, Equatable, Codable, Sendable {
    var id: String
    var name: String
    var project: String
    var cwd: String
    var subtitle: String
    var endedAt: Date
    var seen: Bool

    var shortCwd: String { AntigravitySession.shorten(cwd) }

    static let sample = AntigravityEndedSession(
        id: "agy-ended-sample",
        name: "Resume builder",
        project: "cv-maker",
        cwd: NSHomeDirectory() + "/projects/cv-maker",
        subtitle: "Interactive Resume Builder Development",
        endedAt: Date(timeIntervalSinceNow: -90),
        seen: false
    )
}

struct AntigravityFact: Equatable, Codable, Sendable {
    var id: String
    var name: String
    var project: String
    var cwd: String
    var subtitle: String
    var running: Bool
}

enum AntigravitySessionFiles {
    static var databaseURL: URL {
        let root =
            ProcessInfo.processInfo.environment["ANTIGRAVITY_CONFIG_DIR"]
            ?? (NSHomeDirectory() as NSString).appendingPathComponent(".gemini/antigravity")
        return URL(fileURLWithPath: root, isDirectory: true).appendingPathComponent("conversation_summaries.db")
    }

    /// `live` and `facts` are nil when the database could not be read. An empty list means the read succeeded and nothing is live.
    static func scan() -> (appRunning: Bool, live: [AntigravitySession]?, facts: [AntigravityFact]?) {
        let running = ProcessLookup.isLiveAntigravity()
        guard running else {
            lastScan = nil
            return (false, [], [])
        }
        // The result depends only on the database. `instr(raw_summary, …)` reads every summary blob,
        // so an unchanged file (and WAL) reuses the last good read.
        let signature = fileSignature()
        if let lastScan, let signature, lastScan.signature == signature {
            return (true, lastScan.live, lastScan.facts)
        }
        let db = AntigravitySummaryDB()
        guard db.open() else { return (true, nil, nil) }
        defer { db.close() }
        guard let rows = db.rows() else { return (true, nil, nil) }
        var live: [AntigravitySession] = []
        var facts: [AntigravityFact] = []
        for row in rows {
            facts.append(row.fact)
            if let session = row.session { live.append(session) }
        }
        live.sort { lhs, rhs in
            if lhs.needsInput != rhs.needsInput { return lhs.needsInput }
            return (lhs.startedAt ?? .distantPast) > (rhs.startedAt ?? .distantPast)
        }
        lastScan = signature.map { (signature: $0, live: live, facts: facts) }
        return (true, live, facts)
    }

    private static var lastScan: (signature: [Double], live: [AntigravitySession], facts: [AntigravityFact])?

    /// Modification time and size of the database and its WAL. nil when the database is missing.
    private static func fileSignature() -> [Double]? {
        let path = databaseURL.path
        var result: [Double] = []
        for (index, file) in [path, path + "-wal"].enumerated() {
            var info = stat()
            guard stat(file, &info) == 0 else {
                if index == 0 { return nil }
                result += [0, 0]
                continue
            }
            let mtime = Double(info.st_mtimespec.tv_sec) + Double(info.st_mtimespec.tv_nsec) / 1e9
            result += [mtime, Double(info.st_size)]
        }
        return result
    }
}

private struct AntigravityRow {
    var session: AntigravitySession?
    var fact: AntigravityFact
}

private final class AntigravitySummaryDB {
    private var db: OpaquePointer?

    func open() -> Bool {
        if db != nil { return true }
        let path = AntigravitySessionFiles.databaseURL.path
        guard FileManager.default.fileExists(atPath: path) else { return false }
        var handle: OpaquePointer?
        // A read-only connection cannot open the WAL this file uses while the IDE holds it:
        // sqlite3_open succeeds and the query then fails with SQLITE_CANTOPEN, so the scan
        // looks empty and the previous chat stays on the Ended row.
        guard sqlite3_open_v2(path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else {
            sqlite3_close(handle)
            return false
        }
        sqlite3_busy_timeout(handle, 200)
        guard sqlite3_exec(handle, "PRAGMA query_only=ON;", nil, nil, nil) == SQLITE_OK else {
            sqlite3_close(handle)
            return false
        }
        db = handle
        return true
    }

    func close() {
        if let db { sqlite3_close(db) }
        db = nil
    }

    func rows() -> [AntigravityRow]? {
        guard let db else { return nil }
        let sql = """
            SELECT conversation_id, title, preview, status, not_fully_idle, killed,
                   last_modified_time, last_user_input_time, workspace_uris,
                   instr(raw_summary, 'ask_question')
            FROM conversation_summaries
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        var result: [AntigravityRow] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let id = Self.text(statement, 0)
            guard !id.isEmpty else { continue }
            if sqlite3_column_int(statement, 5) != 0 { continue }
            let title = Self.text(statement, 1)
            let preview = Self.text(statement, 2)
            let statusRaw = Self.text(statement, 3)
            let notIdle = sqlite3_column_int(statement, 4) != 0
            let modified = Self.date(statement, 6)
            let cwd = Self.firstWorkspace(Self.text(statement, 8))
            let project = URL(fileURLWithPath: cwd).lastPathComponent
            let name = (title.isEmpty ? preview : title).trimmingCharacters(in: .whitespacesAndNewlines)
            let display = name.isEmpty ? (project.isEmpty ? "Antigravity" : project) : name
            let asking = sqlite3_column_int(statement, 9) > 0
            let interpreted = Self.interpret(statusRaw, notFullyIdle: notIdle, askingQuestion: asking)
            let fact = AntigravityFact(
                id: id, name: display, project: project.isEmpty ? "—" : project, cwd: cwd,
                subtitle: preview, running: interpreted.live
            )
            var session: AntigravitySession?
            if interpreted.live {
                session = AntigravitySession(
                    id: id, name: display, project: fact.project, cwd: cwd, subtitle: preview,
                    status: interpreted.running ? "running" : "waiting",
                    waitingFor: interpreted.waitingFor, startedAt: modified
                )
            }
            result.append(AntigravityRow(session: session, fact: fact))
        }
        return result
    }

    private static func interpret(
        _ raw: String, notFullyIdle: Bool, askingQuestion: Bool
    ) -> (live: Bool, running: Bool, waitingFor: String?) {
        let status = raw.uppercased()
        // The question form leaves status as RUNNING. The summary names the open ask_question tool.
        if askingQuestion {
            return (true, false, "input needed")
        }
        if status.contains("WAIT") || status.contains("INPUT") || status.contains("APPROVAL") {
            return (true, false, "input needed")
        }
        if status.contains("RUNNING") || status.contains("BUSY") || status.contains("CANCEL") {
            return (true, true, nil)
        }
        if notFullyIdle { return (true, true, nil) }
        return (false, false, nil)
    }

    private static func text(_ statement: OpaquePointer?, _ index: Int32) -> String {
        guard let bytes = sqlite3_column_text(statement, index) else { return "" }
        return String(cString: bytes)
    }

    private static func date(_ statement: OpaquePointer?, _ index: Int32) -> Date? {
        let raw = text(statement, index)
        guard !raw.isEmpty, !raw.hasPrefix("0001-01-01") else { return nil }
        if let date = isoFractional.date(from: raw) { return date }
        if let date = isoPlain.date(from: raw) { return date }
        return fallbackFormatter.date(from: raw)
    }

    // Built once: a formatter per row per poll showed up in CPU samples.
    private static let isoFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private static let isoPlain: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
    private static let fallbackFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSSSSSZZZZZ"
        return formatter
    }()

    private static func firstWorkspace(_ raw: String) -> String {
        guard let data = raw.data(using: .utf8),
            let list = try? JSONSerialization.jsonObject(with: data) as? [String]
        else { return "" }
        for item in list {
            var path = item
            if path.hasPrefix("file://") {
                path = URL(string: path)?.path ?? String(path.dropFirst("file://".count))
            }
            if let decoded = path.removingPercentEncoding { path = decoded }
            if !path.isEmpty { return path }
        }
        return ""
    }
}
