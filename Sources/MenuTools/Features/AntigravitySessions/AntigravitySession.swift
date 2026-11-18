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
    /// The `agy` process of this conversation, when one runs in its folder. Nil for the IDE.
    var pid: pid_t? = nil

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
    /// The IDE and the `agy` CLI keep separate folders with the same `conversation_summaries.db`.
    static var databaseURLs: [URL] {
        let gemini = (NSHomeDirectory() as NSString).appendingPathComponent(".gemini")
        let ide =
            ProcessInfo.processInfo.environment["ANTIGRAVITY_CONFIG_DIR"]
            ?? (gemini as NSString).appendingPathComponent("antigravity")
        let cli = (gemini as NSString).appendingPathComponent("antigravity-cli")
        return [ide, cli].map {
            URL(fileURLWithPath: $0, isDirectory: true).appendingPathComponent("conversation_summaries.db")
        }
    }

    /// `live` and `facts` are nil when a database could not be read. An empty list means the read succeeded and nothing is live.
    static func scan() -> (appRunning: Bool, live: [AntigravitySession]?, facts: [AntigravityFact]?) {
        let running = ProcessLookup.isLiveAntigravity()
        guard running else {
            lastScans = [:]
            return (false, [], [])
        }
        var live: [AntigravitySession] = []
        var idle: [AntigravitySession] = []
        var facts: [AntigravityFact] = []
        var found = false
        for url in databaseURLs {
            // A folder that was never used has no database; that is not a failed read.
            guard let signature = fileSignature(url.path) else {
                lastScans[url.path] = nil
                continue
            }
            found = true
            guard let read = read(url, signature: signature) else { return (true, nil, nil) }
            live += read.live
            idle += read.idle
            facts += read.facts
        }
        guard found else { return (true, nil, nil) }
        live = dedup(attachProcesses(live, idle: idle))
        live.sort { lhs, rhs in
            if lhs.needsInput != rhs.needsInput { return lhs.needsInput }
            return (lhs.startedAt ?? .distantPast) > (rhs.startedAt ?? .distantPast)
        }
        facts = dedupFacts(facts)
        return (true, live, facts)
    }

    /// When the same conversation exists in multiple databases (e.g. IDE and agy CLI),
    /// keep the more active state (running beats idle), matching `dedup` for live sessions.
    private static func dedupFacts(_ facts: [AntigravityFact]) -> [AntigravityFact] {
        var best: [String: AntigravityFact] = [:]
        var order: [String] = []
        for fact in facts {
            if let current = best[fact.id] {
                let preferNew: Bool
                if fact.running != current.running {
                    preferNew = fact.running
                } else {
                    let newScore = (fact.name.isEmpty ? 0 : 1) + (fact.cwd.isEmpty ? 0 : 1) + (fact.subtitle.isEmpty ? 0 : 1)
                    let curScore = (current.name.isEmpty ? 0 : 1) + (current.cwd.isEmpty ? 0 : 1) + (current.subtitle.isEmpty ? 0 : 1)
                    preferNew = newScore > curScore
                }
                if preferNew { best[fact.id] = fact }
            } else {
                best[fact.id] = fact
                order.append(fact.id)
            }
        }
        return order.compactMap { best[$0] }
    }

    /// One conversation can sit in both databases: keep the row with a process, else the more active one.
    private static func dedup(_ sessions: [AntigravitySession]) -> [AntigravitySession] {
        func rank(_ session: AntigravitySession) -> Int {
            (session.pid != nil ? 4 : 0) + (session.needsInput ? 2 : 0) + (session.status != "idle" ? 1 : 0)
        }
        var best: [String: AntigravitySession] = [:]
        var order: [String] = []
        for session in sessions {
            if let current = best[session.id] {
                if rank(session) > rank(current) { best[session.id] = session }
            } else {
                best[session.id] = session
                order.append(session.id)
            }
        }
        return order.compactMap { best[$0] }
    }

    private static func normalized(_ path: String) -> String {
        guard !path.isEmpty else { return "" }
        return URL(fileURLWithPath: path).resolvingSymlinksInPath().standardized.path
    }

    /// The summaries name a folder, not a process, so a CLI conversation gets the `agy` running in
    /// that folder. Two in one folder cannot be told apart, so neither gets one. An `agy` whose
    /// conversation is at rest keeps its latest conversation listed as idle, so it stays reachable.
    private static func attachProcesses(
        _ sessions: [AntigravitySession], idle: [AntigravitySession]
    ) -> [AntigravitySession] {
        let pids = ProcessLookup.liveAgyPids()
        guard !pids.isEmpty else { return sessions }
        var byFolder: [String: [pid_t]] = [:]
        for pid in pids {
            guard let cwd = ProcessLookup.workingDirectory(pid) else { continue }
            byFolder[normalized(cwd), default: []].append(pid)
        }
        var result = sessions.map { session in
            var session = session
            if let found = byFolder[normalized(session.cwd)], found.count == 1 { session.pid = found[0] }
            return session
        }
        let busyFolders = Set(sessions.map { normalized($0.cwd) })
        for (folder, found) in byFolder where found.count == 1 && !busyFolders.contains(folder) {
            let latest = idle.filter { normalized($0.cwd) == folder }
                .max { ($0.startedAt ?? .distantPast) < ($1.startedAt ?? .distantPast) }
            guard var session = latest else { continue }
            session.pid = found[0]
            result.append(session)
        }
        return result
    }

    /// The result depends only on the database. `instr(raw_summary, …)` reads every summary blob,
    /// so an unchanged file (and WAL) reuses the last good read.
    private static func read(
        _ url: URL, signature: [Double]
    ) -> (live: [AntigravitySession], idle: [AntigravitySession], facts: [AntigravityFact])? {
        if let last = lastScans[url.path], last.signature == signature {
            return (last.live, last.idle, last.facts)
        }
        let db = AntigravitySummaryDB(path: url.path)
        guard db.open() else { return nil }
        defer { db.close() }
        guard let rows = db.rows() else { return nil }
        let live = rows.compactMap(\.session)
        let idle = rows.compactMap(\.idle)
        let facts = rows.map(\.fact)
        lastScans[url.path] = (signature: signature, live: live, idle: idle, facts: facts)
        return (live, idle, facts)
    }

    private static var lastScans:
        [String: (
            signature: [Double], live: [AntigravitySession], idle: [AntigravitySession], facts: [AntigravityFact]
        )] = [:]

    @MainActor
    static func diagnose() -> [String] {
        var lines: [String] = []
        lines.append("isLiveAntigravity: \(ProcessLookup.isLiveAntigravity())")
        lines.append("liveAgyPids: \(ProcessLookup.liveAgyPids())")
        for url in databaseURLs {
            lines.append("db: \(url.path) exists: \(FileManager.default.fileExists(atPath: url.path))")
        }
        let result = scan()
        lines.append("scan: appRunning=\(result.appRunning) live=\(result.live?.count ?? -1) facts=\(result.facts?.count ?? -1)")
        if let live = result.live {
            for s in live {
                lines.append("  live: id=\(s.id) name=\(s.name) status=\(s.status) needsInput=\(s.needsInput) pid=\(s.pid?.description ?? "nil")")
            }
        }
        if let facts = result.facts {
            for f in facts {
                lines.append("  fact: id=\(f.id) name=\(f.name) running=\(f.running)")
            }
        }
        return lines
    }

    /// Modification time and size of the database and its WAL. nil when the database is missing.
    private static func fileSignature(_ path: String) -> [Double]? {
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
    /// The same conversation at rest, for an `agy` still open on it.
    var idle: AntigravitySession?
    var fact: AntigravityFact
}

private final class AntigravitySummaryDB {
    private let path: String
    private var db: OpaquePointer?

    init(path: String) {
        self.path = path
    }

    func open() -> Bool {
        if db != nil { return true }
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
            let session = AntigravitySession(
                id: id, name: display, project: fact.project, cwd: cwd, subtitle: preview,
                status: interpreted.live ? (interpreted.running ? "running" : "waiting") : "idle",
                waitingFor: interpreted.waitingFor, startedAt: modified
            )
            result.append(
                AntigravityRow(
                    session: interpreted.live ? session : nil, idle: interpreted.live ? nil : session, fact: fact))
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
