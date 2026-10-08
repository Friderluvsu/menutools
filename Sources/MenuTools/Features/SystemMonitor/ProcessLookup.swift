import Darwin
import Foundation

/// In-process queries on the kernel process table (no `pgrep`/zsh spawn).
enum ProcessLookup {
    /// Exact process-name match, same semantics as `pgrep -x`.
    nonisolated static func isRunning(named name: String) -> Bool {
        let capacity = Int(proc_listallpids(nil, 0))
        guard capacity > 0 else { return false }
        var pids = [pid_t](repeating: 0, count: capacity + 16)
        let count = Int(proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size)))
        guard count > 0 else { return false }

        var buffer = [CChar](repeating: 0, count: 64)
        for pid in pids.prefix(count) where pid > 0 {
            if proc_name(pid, &buffer, UInt32(buffer.count)) > 0, String(cString: buffer) == name {
                return true
            }
        }
        return false
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
}
