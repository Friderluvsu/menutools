import Foundation
import SQLite3

/// One live Cursor agent chat, taken from the composer header table.
struct CursorSession: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let project: String
    let cwd: String
    /// "agent", "chat", "plan", …
    let mode: String
    /// What the chat last did, e.g. "Edited AppState.swift". Shown in the details drawer.
    let subtitle: String
    /// "running" while a turn is in progress.
    let status: String
    /// Set when the chat is blocked on the user: "input needed" or "plan".
    let waitingFor: String?
    let startedAt: Date?
    let filesChanged: Int

    var needsInput: Bool { waitingFor != nil }

    var statusTitle: String {
        if let waitingFor, !waitingFor.isEmpty { return Self.leadingCapital(waitingFor) }
        if status.isEmpty { return "Live" }
        return Self.leadingCapital(status)
    }

    var modeLabel: String {
        switch mode.lowercased() {
        case "cli": return "CLI"
        case "": return ""
        default: return Self.leadingCapital(mode)
        }
    }

    var shortCwd: String {
        let home = NSHomeDirectory()
        if cwd.hasPrefix(home) { return "~" + cwd.dropFirst(home.count) }
        return cwd.isEmpty ? "—" : cwd
    }

    func uptime(now: Date) -> String {
        guard let startedAt else { return "—" }
        let seconds = Int(now.timeIntervalSince(startedAt))
        if seconds < 60 { return "now" }
        return AIResetFormatter.short(until: now.addingTimeInterval(TimeInterval(seconds)), now: now)
    }

    var tooltip: String {
        var lines = [name]
        if !cwd.isEmpty { lines.append(cwd) }
        lines.append(statusTitle)
        if !subtitle.isEmpty { lines.append(subtitle) }
        var meta = [String]()
        if !modeLabel.isEmpty { meta.append(modeLabel) }
        if filesChanged > 0 { meta.append("\(filesChanged) files") }
        if !meta.isEmpty { lines.append(meta.joined(separator: " · ")) }
        lines.append(id)
        return lines.joined(separator: "\n")
    }

    private static func leadingCapital(_ raw: String) -> String {
        guard let first = raw.first else { return raw }
        return first.uppercased() + raw.dropFirst()
    }

    static let samples: [CursorSession] = [
        CursorSession(
            id: "11111111-2222-4333-8444-555555555555",
            name: "Panel session list",
            project: "menutools",
            cwd: NSHomeDirectory() + "/projects/menutools",
            mode: "agent",
            subtitle: "Edited PopoverContentView.swift",
            status: "running",
            waitingFor: nil,
            startedAt: Date(timeIntervalSinceNow: -48 * 60),
            filesChanged: 4
        ),
        CursorSession(
            id: "66666666-7777-4888-8999-aaaaaaaaaaaa",
            name: "Login flow",
            project: "salesiq",
            cwd: NSHomeDirectory() + "/projects/salesiq",
            mode: "agent",
            subtitle: "Edited AuthView.swift",
            status: "waiting",
            waitingFor: "input needed",
            startedAt: Date(timeIntervalSinceNow: -12 * 60),
            filesChanged: 2
        ),
    ]
}

enum CursorSessionFiles {
    /// A header still being written counts as running for this long after its last checkpoint.
    static let runningWindow: TimeInterval = 180
    /// An approval or plan prompt stays listed longer, then drops off so a stuck flag cannot linger all day.
    static let waitingWindow: TimeInterval = 30 * 60

    static var databaseURL: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Cursor/User/globalStorage/state.vscdb")
    }

    /// Top-level chats. `live` is what the card shows. `facts` includes finished headers so a watched run can be seen ending.
    static func scan(now: Date = .now) -> CursorScan {
        guard ProcessLookup.isRunning(named: "Cursor") else {
            return CursorScan(cursorRunning: false, live: [], facts: [])
        }
        let db = CursorHeaderDB()
        guard db.open() else { return CursorScan(cursorRunning: true, live: [], facts: []) }
        defer { db.close() }
        var live: [CursorSession] = []
        var facts: [CursorComposerFact] = []
        for raw in db.headerJSON() {
            guard let data = raw.data(using: .utf8),
                let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }
            if let fact = CursorComposerFact(header: json) { facts.append(fact) }
            if let session = CursorSession(header: json, now: now) { live.append(session) }
        }
        live.sort { lhs, rhs in
            if lhs.needsInput != rhs.needsInput { return lhs.needsInput }
            return (lhs.startedAt ?? .distantPast) > (rhs.startedAt ?? .distantPast)
        }
        return CursorScan(cursorRunning: true, live: live, facts: facts)
    }
}

/// One composer header, including chats that are no longer running.
struct CursorComposerFact: Equatable, Codable, Sendable {
    var id: String
    var name: String
    var project: String
    var cwd: String
    var subtitle: String
    var unfinished: Bool
    var activity: Date?
}

struct CursorScan: Sendable {
    var cursorRunning: Bool
    var live: [CursorSession]
    var facts: [CursorComposerFact]
}

/// A Cursor chat MenuTools saw running, which has since finished.
struct CursorEndedSession: Identifiable, Equatable, Codable, Sendable {
    var id: String
    var name: String
    var project: String
    var cwd: String
    var subtitle: String
    var endedAt: Date
    var seen: Bool

    var shortCwd: String {
        let home = NSHomeDirectory()
        if cwd.hasPrefix(home) { return "~" + cwd.dropFirst(home.count) }
        return cwd.isEmpty ? "—" : cwd
    }

    static let sample = CursorEndedSession(
        id: "ended-sample",
        name: "Push the branch",
        project: "menutools",
        cwd: NSHomeDirectory() + "/projects/menutools",
        subtitle: "Edited AppState.swift",
        endedAt: Date(timeIntervalSinceNow: -60),
        seen: false
    )
}

extension CursorComposerFact {
    fileprivate init?(header: [String: Any]) {
        if (header["isDraft"] as? Bool) == true { return nil }
        guard let id = header["composerId"] as? String, !id.isEmpty else { return nil }
        let cwd = CursorSession.workspacePath(header)
        let folder = URL(fileURLWithPath: cwd).lastPathComponent
        let project = folder.isEmpty ? "—" : folder
        let trimmed = (header["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let activity = [
            CursorSession.milliseconds(header["conversationCheckpointLastUpdatedAt"]),
            CursorSession.milliseconds(header["lastUpdatedAt"]),
        ].compactMap { $0 }.max()
        self.init(
            id: id,
            name: trimmed.isEmpty ? (project == "—" ? "Cursor" : project) : trimmed,
            project: project,
            cwd: cwd,
            subtitle: (header["subtitle"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
            unfinished: CursorSession.milliseconds(header["unfinishedRunAt"]) != nil,
            activity: activity
        )
    }
}

extension CursorSession {
    fileprivate init?(header: [String: Any], now: Date) {
        if (header["isDraft"] as? Bool) == true { return nil }
        let unfinished = Self.milliseconds(header["unfinishedRunAt"])
        let blocking = (header["hasBlockingPendingActions"] as? Bool) == true
        let plan = (header["hasPendingPlan"] as? Bool) == true
        let activity =
            [
                Self.milliseconds(header["conversationCheckpointLastUpdatedAt"]),
                Self.milliseconds(header["lastUpdatedAt"]),
            ]
            .compactMap { $0 }
            .max()
        guard let activity else { return nil }
        let age = now.timeIntervalSince(activity)
        let waiting = blocking || plan
        let running = unfinished != nil && age <= CursorSessionFiles.runningWindow
        if waiting {
            guard age <= CursorSessionFiles.waitingWindow else { return nil }
        } else if !running {
            return nil
        }

        let cwd = Self.workspacePath(header)
        let project = URL(fileURLWithPath: cwd).lastPathComponent
        let trimmedName = (header["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let id = header["composerId"] as? String ?? UUID().uuidString
        self.init(
            id: id,
            name: trimmedName.isEmpty ? (project.isEmpty ? "Cursor" : project) : trimmedName,
            project: project.isEmpty ? "—" : project,
            cwd: cwd,
            mode: header["unifiedMode"] as? String ?? "",
            subtitle: (header["subtitle"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
            status: running && !waiting ? "running" : "waiting",
            waitingFor: blocking ? "input needed" : (plan ? "plan" : nil),
            startedAt: Self.milliseconds(header["createdAt"]),
            filesChanged: Self.int(header["filesChangedCount"])
        )
    }

    private static func int(_ value: Any?) -> Int {
        (value as? NSNumber)?.intValue ?? 0
    }

    fileprivate static func milliseconds(_ value: Any?) -> Date? {
        guard let number = value as? NSNumber else { return nil }
        let ms = number.doubleValue
        guard ms > 1_000_000_000_000 else { return nil }
        return Date(timeIntervalSince1970: ms / 1000)
    }

    fileprivate static func workspacePath(_ header: [String: Any]) -> String {
        let workspace = header["workspaceIdentifier"] as? [String: Any]
        let uri = workspace?["uri"] as? [String: Any]
        return uri?["fsPath"] as? String ?? ""
    }
}

/// Read-only access to Cursor's composer header table. Conversation blobs are never opened.
private final class CursorHeaderDB {
    private var db: OpaquePointer?

    func open() -> Bool {
        if db != nil { return true }
        let path = CursorSessionFiles.databaseURL.path
        guard FileManager.default.fileExists(atPath: path) else { return false }
        var handle: OpaquePointer?
        guard sqlite3_open_v2(path, &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else {
            sqlite3_close(handle)
            return false
        }
        sqlite3_busy_timeout(handle, 200)
        db = handle
        return true
    }

    func close() {
        if let db { sqlite3_close(db) }
        db = nil
    }

    func headerJSON() -> [String] {
        guard let db else { return [] }
        let sql = "SELECT value FROM composerHeaders WHERE isArchived = 0 AND isSubagent = 0"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }
        var values: [String] = []
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_ROW {
                guard let text = sqlite3_column_text(statement, 0) else { continue }
                let json = String(cString: text)
                // Headers are about 1 KB. Anything larger is not the summary row we show.
                if json.utf8.count <= 65_536 { values.append(json) }
            } else {
                break
            }
        }
        return values
    }
}
