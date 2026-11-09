import Foundation

/// One live Claude Code process, read from `~/.claude/sessions/<pid>.json`.
struct ClaudeSession: Identifiable, Equatable, Sendable {
    let pid: pid_t
    let sessionId: String
    let name: String
    let project: String
    /// Working directory the session was started in.
    let cwd: String
    /// Claude's main-loop word: "idle", "busy", "waiting". Idle while a subagent runs.
    let status: String
    /// Why the main loop is paused, e.g. "input needed". Nil while it is generating.
    let waitingFor: String?
    /// Unfinished `subagents/*.meta.json` under the transcript dir. Main can be idle then.
    let hasActiveWork: Bool
    let kind: String
    let entrypoint: String
    let version: String?
    let startedAt: Date?

    var id: String { "\(pid)" }

    var needsInput: Bool {
        let reason = (waitingFor ?? "").lowercased()
        return reason.contains("input") || reason.contains("permission") || status.lowercased() == "waiting"
    }

    /// Main is generating, or waiting on a subagent / other delegated work.
    var isWorking: Bool {
        if needsInput { return false }
        if hasActiveWork { return true }
        switch status.lowercased() {
        case "busy", "running", "working": return true
        default: return false
        }
    }

    /// The thing the row should shout: "Input needed", "Running", otherwise the status word.
    var statusTitle: String {
        if needsInput {
            if let waitingFor, !waitingFor.isEmpty { return Self.leadingCapital(waitingFor) }
            return "Input needed"
        }
        if isWorking { return "Running" }
        if let waitingFor, !waitingFor.isEmpty { return Self.leadingCapital(waitingFor) }
        if status.isEmpty { return "Live" }
        return Self.leadingCapital(status)
    }

    var shortCwd: String {
        let home = NSHomeDirectory()
        if cwd.hasPrefix(home) { return "~" + cwd.dropFirst(home.count) }
        return cwd
    }

    func uptime(now: Date) -> String {
        guard let startedAt else { return "—" }
        let seconds = Int(now.timeIntervalSince(startedAt))
        if seconds < 60 { return "now" }
        return AIResetFormatter.short(until: now.addingTimeInterval(TimeInterval(seconds)), now: now)
    }

    var tooltip: String {
        var lines = [name, cwd, statusTitle]
        if !isWorking, !status.isEmpty, Self.leadingCapital(status).caseInsensitiveCompare(statusTitle) != .orderedSame
        {
            lines.append(Self.leadingCapital(status))
        }
        var meta = [String]()
        if !kind.isEmpty { meta.append(Self.leadingCapital(kind)) }
        if !entrypoint.isEmpty { meta.append(entrypoint.lowercased() == "cli" ? "CLI" : entrypoint) }
        if let version, !version.isEmpty { meta.append(version) }
        if !meta.isEmpty { lines.append(meta.joined(separator: " · ")) }
        lines.append("pid \(pid)")
        lines.append(sessionId)
        return lines.joined(separator: "\n")
    }

    private static func leadingCapital(_ raw: String) -> String {
        guard let first = raw.first else { return raw }
        return first.uppercased() + raw.dropFirst()
    }

    static let samples: [ClaudeSession] = [
        ClaudeSession(
            pid: 83592,
            sessionId: "11111111-2222-4333-8444-555555555555",
            name: "salesiq-fd",
            project: "salesiq",
            cwd: "/Users/me/projects/salesiq",
            status: "waiting",
            waitingFor: "input needed",
            hasActiveWork: false,
            kind: "interactive",
            entrypoint: "cli",
            version: "2.1.316",
            startedAt: Date(timeIntervalSinceNow: -35 * 60)
        ),
        ClaudeSession(
            pid: 12004,
            sessionId: "66666666-7777-4888-8999-aaaaaaaaaaaa",
            name: "menutools",
            project: "menutools",
            cwd: "/Users/me/projects/menutools",
            status: "idle",
            waitingFor: nil,
            hasActiveWork: true,
            kind: "interactive",
            entrypoint: "cli",
            version: "2.1.316",
            startedAt: Date(timeIntervalSinceNow: -8 * 60)
        ),
        // Finished run: the preview marks it Done.
        ClaudeSession(
            pid: 12077,
            sessionId: "bbbbbbbb-cccc-4ddd-8eee-ffffffffffff",
            name: "refactor build script",
            project: "menutools",
            cwd: "/Users/me/projects/menutools",
            status: "idle",
            waitingFor: nil,
            hasActiveWork: false,
            kind: "interactive",
            entrypoint: "cli",
            version: "2.1.316",
            startedAt: Date(timeIntervalSinceNow: -26 * 60)
        ),
    ]
}

enum ClaudeSessionFiles {
    /// `$CLAUDE_CONFIG_DIR/sessions`, or `~/.claude/sessions`.
    static var directory: URL {
        let root =
            ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"]
            ?? (NSHomeDirectory() as NSString).appendingPathComponent(".claude")
        return URL(fileURLWithPath: root, isDirectory: true).appendingPathComponent("sessions", isDirectory: true)
    }

    /// Sessions whose pid is still a live Claude Code process. Needs-input, then working, then idle.
    static func load() -> [ClaudeSession] {
        let dir = directory
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return [] }
        var sessions: [ClaudeSession] = []
        for name in names where name.hasSuffix(".json") {
            let url = dir.appendingPathComponent(name)
            guard let data = try? Data(contentsOf: url),
                let raw = try? JSONDecoder().decode(RawSession.self, from: data),
                ProcessLookup.isLiveClaude(raw.pid)
            else { continue }
            sessions.append(raw.session)
        }
        return sessions.sorted { lhs, rhs in
            if lhs.needsInput != rhs.needsInput { return lhs.needsInput }
            if lhs.isWorking != rhs.isWorking { return lhs.isWorking }
            return (lhs.startedAt ?? .distantPast) > (rhs.startedAt ?? .distantPast)
        }
    }

    /// Claude's session JSON is the main loop only (`idle` / `busy` / `waiting`).
    /// Subagents live under `projects/<cwd-as-dashes>/<sessionId>/subagents/*.meta.json`.
    /// A meta without `finished` is only active work if it was not stopped by the user (Esc leaves
    /// no `finished`) and it or its transcript changed in the last 10 minutes: stale metas from an
    /// interrupted or resumed session would otherwise keep the session Running forever.
    static func hasUnfinishedSubagent(sessionId: String, cwd: String) -> Bool {
        guard let dir = subagentDirectory(sessionId: sessionId, cwd: cwd),
            let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path)
        else { return false }
        let now = Date()
        for name in names where name.hasSuffix(".meta.json") {
            let url = dir.appendingPathComponent(name)
            guard let modified = modificationDate(url), let meta = cachedMeta(url, modified: modified),
                meta.finished != true, meta.stoppedByUser != true
            else { continue }
            let transcript = dir.appendingPathComponent(String(name.dropLast(".meta.json".count)) + ".jsonl")
            let lastActivity = max(modified, modificationDate(transcript) ?? .distantPast)
            if now.timeIntervalSince(lastActivity) < 600 { return true }
        }
        return false
    }

    private static func modificationDate(_ url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    /// Decoded metas by path, reused while the file's modification date is unchanged (polled every 2 s).
    private static let metaLock = NSLock()
    nonisolated(unsafe) private static var metaCache: [String: (modified: Date, meta: SubagentMeta)] = [:]
    nonisolated(unsafe) private static var directoryCache: [String: URL] = [:]
    nonisolated(unsafe) private static var missedAt: [String: Date] = [:]

    private static func cachedMeta(_ url: URL, modified: Date) -> SubagentMeta? {
        metaLock.lock()
        let cached = metaCache[url.path]
        metaLock.unlock()
        if let cached, cached.modified == modified { return cached.meta }
        guard let data = try? Data(contentsOf: url), let meta = try? JSONDecoder().decode(SubagentMeta.self, from: data)
        else { return nil }
        metaLock.lock()
        if metaCache.count > 400 { metaCache.removeAll() }
        metaCache[url.path] = (modified, meta)
        metaLock.unlock()
        return meta
    }

    private static func subagentDirectory(sessionId: String, cwd: String) -> URL? {
        metaLock.lock()
        let known = directoryCache[sessionId]
        let missed = missedAt[sessionId]
        metaLock.unlock()
        if let known { return known }
        // No subagent folder yet: look again at most every 10 s (the scan below lists all projects).
        if let missed, Date().timeIntervalSince(missed) < 10 { return nil }
        let projects = directory.deletingLastPathComponent().appendingPathComponent("projects", isDirectory: true)
        // Claude Code turns every character other than a letter or digit into "-".
        let encoded = String(cwd.map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "-" })
        var candidates = [encoded, cwd.replacingOccurrences(of: "/", with: "-")]
        var found: URL?
        var isDir: ObjCBool = false
        for name in candidates {
            let url = projects.appendingPathComponent(name, isDirectory: true)
                .appendingPathComponent(sessionId, isDirectory: true)
                .appendingPathComponent("subagents", isDirectory: true)
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
                found = url
                break
            }
        }
        if found == nil {
            candidates = (try? FileManager.default.contentsOfDirectory(atPath: projects.path)) ?? []
            for name in candidates {
                let url = projects.appendingPathComponent(name, isDirectory: true)
                    .appendingPathComponent(sessionId, isDirectory: true)
                    .appendingPathComponent("subagents", isDirectory: true)
                if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
                    found = url
                    break
                }
            }
        }
        // Hits are kept; misses are retried after 10 s (the folder appears with the first subagent).
        metaLock.lock()
        if directoryCache.count > 200 { directoryCache.removeAll() }
        if missedAt.count > 200 { missedAt.removeAll() }
        if let found {
            directoryCache[sessionId] = found
            missedAt[sessionId] = nil
        } else {
            missedAt[sessionId] = Date()
        }
        metaLock.unlock()
        return found
    }
}

private struct SubagentMeta: Decodable {
    let finished: Bool?
    let stoppedByUser: Bool?
}

private struct RawSession: Decodable {
    let pid: Int32
    let sessionId: String
    let cwd: String?
    let startedAt: Double?
    let version: String?
    let kind: String?
    let entrypoint: String?
    let name: String?
    let status: String?
    let waitingFor: String?

    var session: ClaudeSession {
        let directory = cwd ?? ""
        let project = URL(fileURLWithPath: directory).lastPathComponent
        let trimmedName = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let started = startedAt.map { Date(timeIntervalSince1970: $0 / 1000) }
        return ClaudeSession(
            pid: pid,
            sessionId: sessionId,
            name: trimmedName.isEmpty ? (project.isEmpty ? sessionId : project) : trimmedName,
            project: project.isEmpty ? "—" : project,
            cwd: directory,
            status: status ?? "",
            waitingFor: waitingFor.flatMap { $0.isEmpty ? nil : $0 },
            hasActiveWork: ClaudeSessionFiles.hasUnfinishedSubagent(sessionId: sessionId, cwd: directory),
            kind: kind ?? "",
            entrypoint: entrypoint ?? "",
            version: version,
            startedAt: started
        )
    }
}
