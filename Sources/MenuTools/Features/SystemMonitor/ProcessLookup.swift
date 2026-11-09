import Darwin
import Foundation

/// In-process queries on the kernel process table (no `pgrep`/zsh spawn).
enum ProcessLookup {
    /// Exact process-name match, same semantics as `pgrep -x`.
    /// `missRetry` > 0 skips the full process walk for that long after a miss (session pollers only).
    nonisolated static func isRunning(named name: String, missRetry: TimeInterval = 0) -> Bool {
        cachedMatch("name:" + name, missRetry: missRetry) { pid in
            var buffer = [CChar](repeating: 0, count: 64)
            return proc_name(pid, &buffer, UInt32(buffer.count)) > 0 && String(cString: buffer) == name
        }
    }

    /// Runs a binary directly (no zsh) and returns trimmed stdout+stderr; empty on launch failure.
    nonisolated static func output(of path: String, _ arguments: [String]) -> String {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            return ""
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (String(data: data, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Claude Code's binary is named after its version (`2.1.316`); the install path carries `claude`.
    nonisolated static func isLiveClaude(_ pid: pid_t) -> Bool {
        guard pid > 0 else { return false }
        var path = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard proc_pidpath(pid, &path, UInt32(path.count)) > 0 else { return false }
        return String(cString: path).split(separator: "/").contains {
            $0.caseInsensitiveCompare("claude") == .orderedSame
        }
    }

    /// Codex CLI binary is named `codex` (mise shim or install dir). ChatGPT.app is not this.
    nonisolated static func isLiveCodex(_ pid: pid_t) -> Bool {
        guard pid > 0 else { return false }
        var path = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard proc_pidpath(pid, &path, UInt32(path.count)) > 0 else { return false }
        let full = String(cString: path)
        if full.contains("ChatGPT.app") { return false }
        return URL(fileURLWithPath: full).lastPathComponent.caseInsensitiveCompare("codex") == .orderedSame
    }

    nonisolated static func liveCodexPids() -> [pid_t] {
        pids { isLiveCodex($0) }
    }

    /// Antigravity IDE (Electron) or the `agy` hub. A miss is trusted for 4 s, so the 2 s session
    /// poll does not walk the whole process table on every tick while Antigravity is closed.
    nonisolated static func isLiveAntigravity() -> Bool {
        cachedMatch("antigravity", missRetry: 4) { pid in
            var path = [CChar](repeating: 0, count: Int(MAXPATHLEN))
            guard proc_pidpath(pid, &path, UInt32(path.count)) > 0 else { return false }
            let full = String(cString: path)
            // The IDE binary lives in "Antigravity IDE.app", so the component is not exactly "Antigravity".
            if full.split(separator: "/").contains(where: {
                $0.range(of: "antigravity", options: .caseInsensitive) != nil
            }) {
                return true
            }
            return URL(fileURLWithPath: full).lastPathComponent.caseInsensitiveCompare("agy") == .orderedSame
        }
    }

    // MARK: - Match cache

    /// Last pid that matched each query. Re-checking that one pid is a single syscall; the full
    /// walk (one `proc_pidpath` per process, ~800 on a busy Mac) runs only when it stops matching.
    nonisolated(unsafe) private static var matchedPid: [String: pid_t] = [:]
    nonisolated(unsafe) private static var missUntil: [String: Date] = [:]
    nonisolated private static let matchLock = NSLock()

    nonisolated private static func cachedMatch(
        _ key: String, missRetry: TimeInterval, _ matches: (pid_t) -> Bool
    ) -> Bool {
        matchLock.lock()
        let known = matchedPid[key]
        let quietUntil = missUntil[key]
        matchLock.unlock()

        if let known, matches(known) { return true }
        if known == nil, let quietUntil, quietUntil > Date() { return false }

        let found = firstPid(matching: matches)
        matchLock.lock()
        matchedPid[key] = found
        missUntil[key] = found == nil && missRetry > 0 ? Date().addingTimeInterval(missRetry) : nil
        matchLock.unlock()
        return found != nil
    }

    nonisolated private static func firstPid(matching: (pid_t) -> Bool) -> pid_t? {
        let capacity = Int(proc_listallpids(nil, 0))
        guard capacity > 0 else { return nil }
        var list = [pid_t](repeating: 0, count: capacity + 16)
        let count = Int(proc_listallpids(&list, Int32(list.count * MemoryLayout<pid_t>.size)))
        guard count > 0 else { return nil }
        return list.prefix(count).first { $0 > 0 && matching($0) }
    }

    /// Current working directory of a process, or nil if it is gone.
    nonisolated static func workingDirectory(_ pid: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.stride)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) > 0 else { return nil }
        return withUnsafeBytes(of: &info.pvi_cdir.vip_path) { raw in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: CChar.self) else { return nil }
            let path = String(cString: base)
            return path.isEmpty ? nil : path
        }
    }

    nonisolated static func isAlive(_ pid: pid_t) -> Bool {
        guard pid > 0 else { return false }
        var path = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        return proc_pidpath(pid, &path, UInt32(path.count)) > 0
    }

    nonisolated private static func pids(matching: (pid_t) -> Bool) -> [pid_t] {
        let capacity = Int(proc_listallpids(nil, 0))
        guard capacity > 0 else { return [] }
        var list = [pid_t](repeating: 0, count: capacity + 16)
        let count = Int(proc_listallpids(&list, Int32(list.count * MemoryLayout<pid_t>.size)))
        guard count > 0 else { return [] }
        return list.prefix(count).filter { $0 > 0 && matching($0) }
    }

    /// Parent pid, or nil when the process is gone or is init.
    nonisolated static func parentPid(_ pid: pid_t) -> pid_t? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let parent = info.kp_eproc.e_ppid
        return parent > 1 ? parent : nil
    }
}
