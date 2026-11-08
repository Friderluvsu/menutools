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
    /// Only needed for interrupted chats that keep `unfinishedRunAt` after the turn is gone.
    static let runningWindow: TimeInterval = 180
    /// An approval or plan prompt stays listed longer, then drops off so a stuck flag cannot linger all day.
    static let waitingWindow: TimeInterval = 30 * 60

    static var databaseURL: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Cursor/User/globalStorage/state.vscdb")
    }

    /// Tool-bubble keys last seen per composer. Exact key reads are cheap; `LIKE 'bubbleId:…%'` is not
    /// (multi-GB `cursorDiskKV`), so we rediscover at most every few seconds while a turn is active.
    fileprivate static var toolBubbleKeys: [String: [String]] = [:]
    fileprivate static var toolBubbleKeysAt: [String: Date] = [:]
    fileprivate static let toolKeyRediscoverInterval: TimeInterval = 3

    /// Top-level chats. `live` is what the card shows. `facts` includes finished headers so a watched run can be seen ending.
    static func scan(now: Date = .now) -> CursorScan {
        guard ProcessLookup.isRunning(named: "Cursor", missRetry: 4) else {
            toolBubbleKeys = [:]
            toolBubbleKeysAt = [:]
            return CursorScan(cursorRunning: false, live: [], facts: [], readFailed: false)
        }
        // Unchanged database and WAL: reuse the last read. It expires after `reuseLimit` because the
        // running and waiting windows depend on the clock, not only on the file.
        let signature = fileSignature()
        if let lastScan, let signature, lastScan.signature == signature,
            now.timeIntervalSince(lastScan.at) < reuseLimit
        {
            return lastScan.scan
        }
        let db = CursorHeaderDB()
        guard db.open() else {
            return CursorScan(cursorRunning: true, live: [], facts: [], readFailed: true)
        }
        defer { db.close() }
        let headerRead = db.headerJSON()
        if headerRead.busy {
            return CursorScan(cursorRunning: true, live: [], facts: [], readFailed: true)
        }
        var live: [CursorSession] = []
        var facts: [CursorComposerFact] = []
        var activeIDs: Set<String> = []
        for raw in headerRead.values {
            guard let data = raw.data(using: .utf8),
                let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }
            let generation = Self.generation(for: json, db: db, now: now)
            if let fact = CursorComposerFact(header: json, generation: generation) { facts.append(fact) }
            if let session = CursorSession(header: json, generation: generation, now: now) {
                live.append(session)
                activeIDs.insert(session.id)
            }
        }
        // Drop caches for composers that are no longer live or unfinished.
        let keepIDs = activeIDs.union(Set(facts.filter(\.unfinished).map(\.id)))
        toolBubbleKeys = toolBubbleKeys.filter { keepIDs.contains($0.key) }
        toolBubbleKeysAt = toolBubbleKeysAt.filter { keepIDs.contains($0.key) }
        live.sort { lhs, rhs in
            if lhs.needsInput != rhs.needsInput { return lhs.needsInput }
            return (lhs.startedAt ?? .distantPast) > (rhs.startedAt ?? .distantPast)
        }
        let result = CursorScan(cursorRunning: true, live: live, facts: facts, readFailed: false)
        lastScan = signature.map { (signature: $0, at: now, scan: result) }
        return result
    }

    private static let reuseLimit: TimeInterval = 10
    private static var lastScan: (signature: [Double], at: Date, scan: CursorScan)?

    /// Modification time and size of `state.vscdb` and its WAL. nil when the database is missing.
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

    /// `unfinishedRunAt` on the header covers interrupted turns. Clean in-progress turns (e.g. a long
    /// `sleep`) often leave that field empty and instead keep `chatGenerationUUID` / `status` on
    /// `composerData` — peek that blob only while the header is recent enough to matter.
    fileprivate static func generation(for header: [String: Any], db: CursorHeaderDB, now: Date)
        -> ComposerGeneration
    {
        let headerUnfinished = CursorSession.milliseconds(header["unfinishedRunAt"])
        let headerBlocking = (header["hasBlockingPendingActions"] as? Bool) == true
        let headerPlan = (header["hasPendingPlan"] as? Bool) == true
        let activity =
            [
                CursorSession.milliseconds(header["conversationCheckpointLastUpdatedAt"]),
                CursorSession.milliseconds(header["lastUpdatedAt"]),
            ]
            .compactMap { $0 }
            .max()
        let age = activity.map { now.timeIntervalSince($0) }
        let recentEnough = age.map { $0 <= waitingWindow } ?? false
        // Interrupted markers already mean "active" for facts; still peek when recent so a clean
        // first turn that never wrote unfinishedRunAt can light green during a tool wait.
        if headerUnfinished != nil, !recentEnough {
            return ComposerGeneration(
                unfinishedRunAt: headerUnfinished, headerBlocking: headerBlocking, headerPlan: headerPlan)
        }
        guard recentEnough, let id = header["composerId"] as? String, !id.isEmpty else {
            return ComposerGeneration(
                unfinishedRunAt: headerUnfinished, headerBlocking: headerBlocking, headerPlan: headerPlan)
        }
        var peeked = db.composerGeneration(id: id) ?? ComposerGeneration()
        if peeked.unfinishedRunAt == nil { peeked.unfinishedRunAt = headerUnfinished }
        peeked.headerBlocking = headerBlocking
        peeked.headerPlan = headerPlan
        // AskQuestion often never flips hasBlockingPendingActions on the header (Cursor notifies from
        // in-memory state). An open ask_question tool bubble with status loading/pending is orange.
        let alreadyWaiting = peeked.blocksUser
        if !alreadyWaiting, peeked.isActive {
            peeked.awaitsQuestion = db.hasPendingAskQuestion(id: id, keysCache: &toolBubbleKeys)
        }
        return peeked
    }
}

/// Live-generation fields from `composerData:<id>`. Kept separate from the 1 KB header row.
struct ComposerGeneration: Sendable {
    var unfinishedRunAt: Date? = nil
    var chatGenerationUUID: String? = nil
    var status: String? = nil
    var hasGeneratingBubbles: Bool = false
    var dataBlocking: Bool = false
    var dataPlan: Bool = false
    var headerBlocking: Bool = false
    var headerPlan: Bool = false
    /// Open AskQuestion (or similar) tool still waiting on the user.
    var awaitsQuestion: Bool = false

    /// Cursor's own `generating` flag: status is generating, or generatingBubbleIds is non-empty.
    var isGeneratingFlag: Bool {
        if (status ?? "").lowercased() == "generating" { return true }
        return hasGeneratingBubbles
    }

    /// A turn Cursor is still working on. `chatGenerationUUID` is set for clean in-progress turns
    /// (including shell waits) and cleared when the turn completes; `unfinishedRunAt` stays on
    /// interrupted chats.
    var isActive: Bool {
        unfinishedRunAt != nil || isGeneratingFlag || !(chatGenerationUUID ?? "").isEmpty || awaitsQuestion
    }

    var blocksUser: Bool { headerBlocking || dataBlocking || awaitsQuestion }
    var hasPlan: Bool { headerPlan || dataPlan }
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
    /// Open/query hit a busy lock. Keep the previous live rows — clearing them blanks the ring until the panel opens.
    var readFailed: Bool
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
    fileprivate init?(header: [String: Any], generation: ComposerGeneration) {
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
            unfinished: generation.isActive,
            activity: activity
        )
    }
}

extension CursorSession {
    fileprivate init?(header: [String: Any], generation: ComposerGeneration, now: Date) {
        if (header["isDraft"] as? Bool) == true { return nil }
        let activity =
            [
                Self.milliseconds(header["conversationCheckpointLastUpdatedAt"]),
                Self.milliseconds(header["lastUpdatedAt"]),
            ]
            .compactMap { $0 }
            .max()
        guard let activity else { return nil }
        let age = now.timeIntervalSince(activity)
        let waiting = generation.blocksUser || generation.hasPlan
        // Clean in-progress turns keep chatGenerationUUID (or status=generating) and clear it when
        // done, so they do not need the interrupted-run age gate. unfinishedRunAt alone can linger
        // after an abort, so those still need a fresh checkpoint.
        let liveGenerating =
            generation.isGeneratingFlag || !(generation.chatGenerationUUID ?? "").isEmpty
            || generation.awaitsQuestion
        let interruptedFresh =
            generation.unfinishedRunAt != nil && age <= CursorSessionFiles.runningWindow
        let running = liveGenerating || interruptedFresh
        if waiting {
            guard age <= CursorSessionFiles.waitingWindow else { return nil }
        } else if !running {
            return nil
        }

        let cwd = Self.workspacePath(header)
        let project = URL(fileURLWithPath: cwd).lastPathComponent
        let trimmedName = (header["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let id = header["composerId"] as? String ?? UUID().uuidString
        let waitingFor: String? = {
            if generation.blocksUser { return "input needed" }
            if generation.hasPlan { return "plan" }
            return nil
        }()
        self.init(
            id: id,
            name: trimmedName.isEmpty ? (project.isEmpty ? "Cursor" : project) : trimmedName,
            project: project.isEmpty ? "—" : project,
            cwd: cwd,
            mode: header["unifiedMode"] as? String ?? "",
            subtitle: (header["subtitle"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
            status: running && !waiting ? "running" : "waiting",
            waitingFor: waitingFor,
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

/// Read-only access to Cursor's composer header table. Full conversation blobs are never opened;
/// `composerData` is only json_extract'd for a few generation fields on recent chats.
private final class CursorHeaderDB {
    private var db: OpaquePointer?
    private static let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    func open() -> Bool {
        if db != nil { return true }
        let path = CursorSessionFiles.databaseURL.path
        guard FileManager.default.fileExists(atPath: path) else { return false }
        var handle: OpaquePointer?
        guard sqlite3_open_v2(path, &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else {
            sqlite3_close(handle)
            return false
        }
        // The DB can be multi-GB and briefly locked while Cursor writes; 200 ms was too tight.
        sqlite3_busy_timeout(handle, 500)
        db = handle
        return true
    }

    func close() {
        if let db { sqlite3_close(db) }
        db = nil
    }

    func headerJSON() -> (values: [String], busy: Bool) {
        guard let db else { return ([], true) }
        let sql = "SELECT value FROM composerHeaders WHERE isArchived = 0 AND isSubagent = 0"
        var statement: OpaquePointer?
        let prepare = sqlite3_prepare_v2(db, sql, -1, &statement, nil)
        if prepare == SQLITE_BUSY || prepare == SQLITE_LOCKED { return ([], true) }
        guard prepare == SQLITE_OK else { return ([], true) }
        defer { sqlite3_finalize(statement) }
        var values: [String] = []
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_ROW {
                guard let text = sqlite3_column_text(statement, 0) else { continue }
                let json = String(cString: text)
                // Headers are about 1 KB. Anything larger is not the summary row we show.
                if json.utf8.count <= 65_536 { values.append(json) }
            } else if step == SQLITE_BUSY || step == SQLITE_LOCKED {
                return ([], true)
            } else {
                break
            }
        }
        return (values, false)
    }

    /// Cheap generation peek. Avoids loading the full composerData blob into Swift.
    func composerGeneration(id: String) -> ComposerGeneration? {
        guard let db else { return nil }
        let sql = """
            SELECT
              json_extract(CAST(value AS TEXT), '$.unfinishedRunAt'),
              json_extract(CAST(value AS TEXT), '$.chatGenerationUUID'),
              json_extract(CAST(value AS TEXT), '$.status'),
              json_extract(CAST(value AS TEXT), '$.generatingBubbleIds'),
              json_extract(CAST(value AS TEXT), '$.hasBlockingPendingActions'),
              json_extract(CAST(value AS TEXT), '$.hasPendingPlan')
            FROM cursorDiskKV WHERE key = ?
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        let key = "composerData:" + id
        guard sqlite3_bind_text(statement, 1, key, -1, Self.sqliteTransient) == SQLITE_OK else { return nil }
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }

        let unfinishedMS = Self.columnDouble(statement, 0)
        let chatGen = Self.columnText(statement, 1)
        let status = Self.columnText(statement, 2)
        let bubblesJSON = Self.columnText(statement, 3)
        var hasBubbles = false
        if let bubblesJSON, let data = bubblesJSON.data(using: .utf8),
            let arr = try? JSONSerialization.jsonObject(with: data) as? [Any]
        {
            hasBubbles = !arr.isEmpty
        }
        return ComposerGeneration(
            unfinishedRunAt: unfinishedMS.flatMap { ms in
                ms > 1_000_000_000_000 ? Date(timeIntervalSince1970: ms / 1000) : nil
            },
            chatGenerationUUID: chatGen.flatMap { $0.isEmpty ? nil : $0 },
            status: status.flatMap { $0.isEmpty ? nil : $0 },
            hasGeneratingBubbles: hasBubbles,
            dataBlocking: Self.columnBool(statement, 4),
            dataPlan: Self.columnBool(statement, 5)
        )
    }

    /// True when an `ask_question` tool bubble is still loading/pending (Cursor's questionnaire wait).
    func hasPendingAskQuestion(id: String, keysCache: inout [String: [String]]) -> Bool {
        let now = Date()
        let cached = keysCache[id] ?? []
        for key in cached where toolAwaitsQuestion(key: key) { return true }
        let agedOut =
            CursorSessionFiles.toolBubbleKeysAt[id]
            .map { now.timeIntervalSince($0) >= CursorSessionFiles.toolKeyRediscoverInterval } ?? true
        // Prefix scans of cursorDiskKV are expensive; reuse keys unless the cache is cold/stale.
        guard cached.isEmpty || agedOut else { return false }
        let keys = toolBubbleKeys(for: id)
        guard !keys.isEmpty else { return false }
        keysCache[id] = keys
        CursorSessionFiles.toolBubbleKeysAt[id] = now
        for key in keys where toolAwaitsQuestion(key: key) { return true }
        return false
    }

    private func toolBubbleKeys(for id: String) -> [String] {
        guard let db else { return [] }
        let sql = "SELECT key FROM cursorDiskKV WHERE key LIKE ? ESCAPE '\\'"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }
        // Escape LIKE wildcards in the composer id (UUIDs are safe; still be strict).
        let escaped = id
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
        let pattern = "bubbleId:" + escaped + "%/t:%"
        guard sqlite3_bind_text(statement, 1, pattern, -1, Self.sqliteTransient) == SQLITE_OK else { return [] }
        var keys: [String] = []
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_ROW {
                guard let text = sqlite3_column_text(statement, 0) else { continue }
                keys.append(String(cString: text))
                if keys.count >= 32 { break }
            } else {
                break
            }
        }
        return keys
    }

    private func toolAwaitsQuestion(key: String) -> Bool {
        guard let db else { return false }
        let sql = """
            SELECT
              json_extract(CAST(value AS TEXT), '$.toolFormerData.name'),
              json_extract(CAST(value AS TEXT), '$.toolFormerData.status'),
              json_extract(CAST(value AS TEXT), '$.toolFormerData.additionalData.status')
            FROM cursorDiskKV WHERE key = ?
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_bind_text(statement, 1, key, -1, Self.sqliteTransient) == SQLITE_OK else { return false }
        guard sqlite3_step(statement) == SQLITE_ROW else { return false }
        let name = (Self.columnText(statement, 0) ?? "").lowercased()
        guard name == "ask_question" else { return false }
        let status = (Self.columnText(statement, 1) ?? "").lowercased()
        let extra = (Self.columnText(statement, 2) ?? "").lowercased()
        // Matches Cursor's getHasPendingQuestionnaireAwaitingInput (pending/loading).
        if status == "loading" || status == "pending" { return true }
        if extra == "loading" || extra == "pending" { return true }
        return false
    }

    private static func columnText(_ statement: OpaquePointer?, _ index: Int32) -> String? {
        guard let statement, sqlite3_column_type(statement, index) != SQLITE_NULL,
            let text = sqlite3_column_text(statement, index)
        else { return nil }
        return String(cString: text)
    }

    private static func columnDouble(_ statement: OpaquePointer?, _ index: Int32) -> Double? {
        guard let statement, sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
        return sqlite3_column_double(statement, index)
    }

    private static func columnBool(_ statement: OpaquePointer?, _ index: Int32) -> Bool {
        guard let statement, sqlite3_column_type(statement, index) != SQLITE_NULL else { return false }
        switch sqlite3_column_type(statement, index) {
        case SQLITE_INTEGER, SQLITE_FLOAT:
            return sqlite3_column_int(statement, index) != 0
        case SQLITE_TEXT:
            let text = String(cString: sqlite3_column_text(statement, index)).lowercased()
            return text == "true" || text == "1"
        default:
            return false
        }
    }
}
