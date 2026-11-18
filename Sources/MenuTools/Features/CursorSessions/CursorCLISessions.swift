import Darwin
import Foundation
import SQLite3

/// Cursor's terminal agent (`cursor-agent`, `agent`). Its chats live in
/// `~/.cursor/chats/<md5 of the folder>/<chat id>/` (`meta.json`, `store.db`) with encrypted
/// messages, so the state comes from the process: a live CLI keeps its chat's `store.db` open, and
/// it redraws its spinner while it works (several percent of a core) but sits near 0.1% at the prompt.
///
/// Cost while no CLI runs: one process-table walk every `walkInterval`. Per live CLI and poll: one
/// CPU sample, one open-file listing and two `stat`s; the chat is opened only when it changed.
@MainActor
final class CursorCLIScanner {
    struct Scan {
        var live: [CursorSession]
        var facts: [CursorComposerFact]
        /// A CLI is open, so the manager keeps polling fast.
        var present: Bool
    }

    /// CPU share over one poll that counts as working.
    nonisolated static let busyShare = 0.02
    /// How often the process table is searched for new CLIs.
    nonisolated static let walkInterval: TimeInterval = 6

    private struct Sample {
        var cpu: UInt64
        var at: Date
    }

    private struct Chat {
        var pid: pid_t
        var meta: CursorCLIMeta
        var signature: [Double]
        var blobs: Int
        var run = CursorCLIRun()
    }

    private var pids: [pid_t] = []
    private var nextWalk = Date.distantPast
    private var samples: [pid_t: Sample] = [:]
    private var chats: [String: Chat] = [:]
    private var folders: [pid_t: (folder: String, at: Date)] = [:]

    static var chatsRoot: String { NSHomeDirectory() + "/.cursor/chats/" }

    func scan(now: Date = Date()) -> Scan {
        let walked = now >= nextWalk
        if now >= nextWalk {
            pids = ProcessLookup.liveCursorCLIPids()
            nextWalk = now.addingTimeInterval(Self.walkInterval)
        } else {
            pids = pids.filter(ProcessLookup.isCursorCLI)
        }
        var live: [CursorSession] = []
        var facts: [CursorComposerFact] = []
        var seen: Set<String> = []
        for pid in pids {
            // A failed probe is a missed poll, not the CLI quitting: only a gone pid ends a chat.
            let cpu = CursorCLIProcess.cpuNanoseconds(pid)
            var share: Double?
            if let cpu {
                share = samples[pid].flatMap { last -> Double? in
                    let elapsed = now.timeIntervalSince(last.at)
                    guard elapsed > 0.2, cpu >= last.cpu else { return nil }
                    return Double(cpu - last.cpu) / 1e9 / elapsed
                }
                samples[pid] = Sample(cpu: cpu, at: now)
            }
            guard let folder = resolveFolder(pid: pid, now: now, rewalk: walked) else {
                if let held = chats.first(where: { $0.value.pid == pid }), seen.insert(held.key).inserted {
                    facts.append(Self.fact(id: held.key, chat: held.value))
                    live.append(Self.session(id: held.key, chat: held.value))
                }
                continue
            }
            let id = URL(fileURLWithPath: folder).lastPathComponent
            guard !seen.contains(id) else { continue }
            seen.insert(id)
            let signature = CursorCLIStore.signature(folder)
            var chat: Chat
            if var known = chats[id], known.pid == pid {
                let wrote = known.signature != signature
                var grew = false
                if wrote {
                    let blobs = CursorCLIStore.blobCount(folder) ?? known.blobs
                    grew = blobs > known.blobs
                    known.blobs = max(known.blobs, blobs)
                    known.signature = signature
                    known.meta = CursorCLIMeta.read(folder) ?? known.meta
                }
                known.run.step(now: now, busy: share.map { $0 >= Self.busyShare } ?? false, wrote: wrote, grew: grew)
                chat = known
            } else {
                // First sight (a new CLI, `/new`, or MenuTools starting): a baseline, never a turn.
                chat = Chat(
                    pid: pid, meta: CursorCLIMeta.read(folder) ?? CursorCLIMeta(), signature: signature,
                    blobs: CursorCLIStore.blobCount(folder) ?? 0)
            }
            chats[id] = chat
            facts.append(Self.fact(id: id, chat: chat))
            live.append(Self.session(id: id, chat: chat))
        }
        // The CLI quit or moved to another chat: a turn in progress has ended. Reported once.
        for (id, chat) in chats where !seen.contains(id) {
            var ended = Self.fact(id: id, chat: chat)
            ended.unfinished = false
            facts.append(ended)
            chats[id] = nil
        }
        samples = samples.filter { pids.contains($0.key) }
        folders = folders.filter { pids.contains($0.key) }
        return Scan(live: live, facts: facts, present: !pids.isEmpty)
    }

    /// The chat folder a CLI has open. The fd listing is the costly part, so the answer is reused
    /// until the process walk re-runs, `store.db` stops existing, or `walkInterval` passes.
    private func resolveFolder(pid: pid_t, now: Date, rewalk: Bool) -> String? {
        if !rewalk, let cached = folders[pid], now.timeIntervalSince(cached.at) < Self.walkInterval,
            CursorCLIStore.signature(cached.folder)[0] > 0
        {
            return cached.folder
        }
        guard let folder = CursorCLIProcess.openChat(pid: pid, under: Self.chatsRoot) else {
            folders[pid] = nil
            return nil
        }
        folders[pid] = (folder, now)
        return folder
    }

    private static func fact(id: String, chat: Chat) -> CursorComposerFact {
        CursorComposerFact(
            id: id, name: chat.meta.displayName, project: chat.meta.project, cwd: chat.meta.cwd,
            subtitle: "", unfinished: chat.run.running, activity: chat.run.startedAt)
    }

    /// Every open CLI chat is listed, like a Claude or Codex terminal: running during a turn, done
    /// after one, idle before the first.
    private static func session(id: String, chat: Chat) -> CursorSession {
        let status = chat.run.running ? "running" : chat.run.finished ? "done" : "idle"
        return CursorSession(
            id: id, name: chat.meta.displayName, project: chat.meta.project, cwd: chat.meta.cwd, mode: "cli",
            subtitle: "", status: status, waitingFor: nil, startedAt: chat.run.startedAt, filesChanged: 0,
            pid: chat.pid)
    }

    /// `--cursor-cli-diagnose`: samples live CLIs for a few seconds. Ids, CPU share and counts only.
    static func diagnose(seconds: Int = 6) -> [String] {
        var lines = ["chats_root=\(chatsRoot)", "run_checks=\(CursorCLIRun.selfCheck() ? "ok" : "FAILED")"]
        let pids = ProcessLookup.liveCursorCLIPids()
        lines.append("cli_processes=\(pids.count)")
        var first: [pid_t: UInt64] = [:]
        for pid in pids { first[pid] = CursorCLIProcess.cpuNanoseconds(pid) }
        Thread.sleep(forTimeInterval: TimeInterval(seconds))
        for pid in pids {
            let folder = CursorCLIProcess.openChat(pid: pid, under: chatsRoot)
            let share = both(first[pid], CursorCLIProcess.cpuNanoseconds(pid)).map {
                Double($1 &- $0) / 1e9 / Double(seconds) * 100
            }
            let id = folder.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "none"
            let blobs = folder.flatMap(CursorCLIStore.blobCount).map(String.init) ?? "?"
            let project = folder.flatMap(CursorCLIMeta.read)?.project ?? "?"
            lines.append(
                "pid=\(pid) chat=\(id) project=\(project) blobs=\(blobs) cpu=\(share.map { String(format: "%.1f%%", $0) } ?? "?")"
                    + " busy=\(share.map { $0 >= busyShare * 100 } ?? false)")
        }
        return lines
    }
}

private func both(_ a: UInt64?, _ b: UInt64?) -> (UInt64, UInt64)? {
    guard let a, let b else { return nil }
    return (a, b)
}

/// One CLI chat's turn, from activity samples. Busy CPU or a write opens a tentative run; it counts
/// once the chat gains messages, so typing at the prompt or starting the CLI never reads as a turn.
/// It ends after `quietGrace` with neither CPU work nor writes.
struct CursorCLIRun: Equatable, Sendable {
    static let quietGrace: TimeInterval = 12

    private(set) var startedAt: Date?
    /// A turn ended since the last one started.
    private(set) var finished = false
    private var active = false
    private var confirmed = false
    private var lastActive: Date?

    var running: Bool { active && confirmed }

    mutating func step(now: Date, busy: Bool, wrote: Bool, grew: Bool) {
        if busy || wrote || grew { lastActive = now }
        if !active {
            guard busy || grew else { return }
            active = true
            startedAt = now
        }
        if grew {
            confirmed = true
            finished = false
        }
        if let lastActive, now.timeIntervalSince(lastActive) >= Self.quietGrace {
            let ended = confirmed || finished
            self = CursorCLIRun()
            finished = ended
        }
    }

    /// The transitions the scanner relies on, for the diagnose.
    static func selfCheck() -> Bool {
        let start = Date(timeIntervalSince1970: 1_000_000)
        func at(_ seconds: TimeInterval) -> Date { start.addingTimeInterval(seconds) }

        var typing = CursorCLIRun()
        typing.step(now: at(0), busy: true, wrote: false, grew: false)
        typing.step(now: at(2), busy: true, wrote: false, grew: false)
        let typingHidden = !typing.running
        typing.step(now: at(20), busy: false, wrote: false, grew: false)
        let typingDropped = typing == CursorCLIRun()

        var turn = CursorCLIRun()
        turn.step(now: at(0), busy: true, wrote: true, grew: true)
        let startsOnMessages = turn.running && turn.startedAt == at(0)
        turn.step(now: at(30), busy: true, wrote: false, grew: false)
        turn.step(now: at(40), busy: false, wrote: false, grew: false)
        let toolWaitKeepsRunning = turn.running
        turn.step(now: at(52), busy: false, wrote: false, grew: false)
        let endsAfterQuiet = !turn.running && turn.finished
        turn.step(now: at(60), busy: true, wrote: true, grew: true)
        let nextTurnClearsDone = turn.running && !turn.finished

        var metaOnly = CursorCLIRun()
        metaOnly.step(now: at(0), busy: false, wrote: true, grew: false)
        let writeAloneIsNotATurn = !metaOnly.running

        return typingHidden && typingDropped && startsOnMessages && toolWaitKeepsRunning && endsAfterQuiet
            && nextTurnClearsDone && writeAloneIsNotATurn
    }
}

/// `meta.json` of a CLI chat: title, folder and creation time. No message text.
struct CursorCLIMeta: Equatable, Sendable {
    var title = ""
    var cwd = ""

    var project: String {
        let folder = URL(fileURLWithPath: cwd).lastPathComponent
        return cwd.isEmpty || folder.isEmpty ? "—" : folder
    }

    var displayName: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        return project == "—" ? "Cursor CLI" : project
    }

    static func read(_ folder: String) -> CursorCLIMeta? {
        let url = URL(fileURLWithPath: folder).appendingPathComponent("meta.json")
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe), data.count < 64 * 1024,
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return CursorCLIMeta(title: json["title"] as? String ?? "", cwd: json["cwd"] as? String ?? "")
    }
}

enum CursorCLIStore {
    /// Modification time and size of `store.db` and its WAL.
    static func signature(_ folder: String) -> [Double] {
        let path = folder + "/store.db"
        return [path, path + "-wal"].flatMap { file -> [Double] in
            var info = stat()
            guard stat(file, &info) == 0 else { return [0, 0] }
            let mtime = Double(info.st_mtimespec.tv_sec) + Double(info.st_mtimespec.tv_nsec) / 1e9
            return [mtime, Double(info.st_size)]
        }
    }

    /// Highest blob rowid: it only grows with messages, so "more than before" means a new message.
    /// Read-only first (cheap, short wait); a read-only connection cannot always use the WAL the CLI
    /// holds open, so it falls back to a read-write open plus `query_only`.
    static func blobCount(_ folder: String) -> Int? {
        let path = folder + "/store.db"
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        return query(path, flags: SQLITE_OPEN_READONLY) ?? query(path, flags: SQLITE_OPEN_READWRITE)
    }

    private static func query(_ path: String, flags: Int32) -> Int? {
        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, flags | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return nil
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 20)
        guard sqlite3_exec(db, "PRAGMA query_only=ON;", nil, nil, nil) == SQLITE_OK else { return nil }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT max(rowid) FROM blobs", -1, &statement, nil) == SQLITE_OK else {
            return nil
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return Int(sqlite3_column_int64(statement, 0))
    }
}

enum CursorCLIProcess {
    /// User plus system CPU time of a process, in nanoseconds.
    nonisolated static func cpuNanoseconds(_ pid: pid_t) -> UInt64? {
        var info = rusage_info_v0()
        let status: Int32 = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V0, $0) }
        }
        guard status == 0 else { return nil }
        let ticks = info.ri_user_time + info.ri_system_time
        return ticks * UInt64(timebase.numer) / UInt64(max(timebase.denom, 1))
    }

    nonisolated private static let timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()

    /// The chat folder whose `store.db` this process has open, if any.
    nonisolated static func openChat(pid: pid_t, under root: String) -> String? {
        let bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard bytes > 0 else { return nil }
        let stride = MemoryLayout<proc_fdinfo>.stride
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(bytes) / stride + 8)
        let filled = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, Int32(fds.count * stride))
        guard filled > 0 else { return nil }
        for fd in fds.prefix(Int(filled) / stride) where fd.proc_fdtype == UInt32(PROX_FDTYPE_VNODE) {
            var info = vnode_fdinfowithpath()
            let size = Int32(MemoryLayout<vnode_fdinfowithpath>.stride)
            guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDVNODEPATHINFO, &info, size) == size else { continue }
            let path = withUnsafeBytes(of: &info.pvip.vip_path) { raw in
                raw.baseAddress.map { String(cString: $0.assumingMemoryBound(to: CChar.self)) } ?? ""
            }
            if path.hasPrefix(root), path.hasSuffix("/store.db") {
                return (path as NSString).deletingLastPathComponent
            }
        }
        return nil
    }
}
