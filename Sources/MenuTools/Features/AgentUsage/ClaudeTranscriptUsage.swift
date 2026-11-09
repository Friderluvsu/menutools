import Foundation

/// Token totals of live Claude Code sessions, summed from the transcripts Claude writes itself:
/// `projects/<cwd as dashes>/<sessionId>.jsonl` plus `<sessionId>/subagents/*.jsonl` under it.
/// Every assistant line carries the message's `usage`; a message is repeated once per content block
/// with the same id and the same usage, so each message id is counted once. Files are append-only,
/// so after the first pass only the new bytes are read on each refresh.
final class ClaudeTranscriptUsage: @unchecked Sendable {
    static let shared = ClaudeTranscriptUsage()

    private struct FileCursor {
        var offset: UInt64 = 0
        /// Bytes after the last newline, waiting for the rest of that line.
        var tail = Data()
    }

    private struct SessionState {
        var transcriptDirectory: URL?
        var missedAt: Date?
        var files: [String: FileCursor] = [:]
        var seen: Set<String> = []
        var usage = SessionUsage()
        var subagentsCheckedAt: Date = .distantPast
    }

    private let lock = NSLock()
    private var states: [String: SessionState] = [:]

    private static let chunkSize = 4 * 1024 * 1024
    private static let missRetry: TimeInterval = 10
    private static let subagentListInterval: TimeInterval = 2

    /// Usage keyed by session id (pid) for the sessions given. Sessions no longer listed are forgotten.
    func usage(for sessions: [ClaudeSession]) -> [String: SessionUsage] {
        lock.lock()
        defer { lock.unlock() }
        let ids = Set(sessions.map(\.id))
        states = states.filter { ids.contains($0.key) }
        var result: [String: SessionUsage] = [:]
        for session in sessions {
            var state = states[session.id] ?? SessionState()
            refresh(&state, session: session)
            states[session.id] = state
            if !state.usage.isEmpty { result[session.id] = state.usage }
        }
        return result
    }

    private func refresh(_ state: inout SessionState, session: ClaudeSession) {
        if state.transcriptDirectory == nil {
            if let missed = state.missedAt, Date().timeIntervalSince(missed) < Self.missRetry { return }
            guard let directory = Self.transcriptDirectory(sessionId: session.sessionId, cwd: session.cwd) else {
                state.missedAt = Date()
                return
            }
            state.transcriptDirectory = directory
            state.missedAt = nil
        }
        guard let directory = state.transcriptDirectory else { return }
        let main = directory.appendingPathComponent(session.sessionId + ".jsonl")
        read(main, state: &state, isMain: true)

        let now = Date()
        guard now.timeIntervalSince(state.subagentsCheckedAt) >= Self.subagentListInterval else { return }
        state.subagentsCheckedAt = now
        let subagents = directory.appendingPathComponent(session.sessionId, isDirectory: true)
            .appendingPathComponent("subagents", isDirectory: true)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: subagents.path) else { return }
        for name in names where name.hasSuffix(".jsonl") {
            read(subagents.appendingPathComponent(name), state: &state, isMain: false)
        }
    }

    /// Reads the bytes added since the last pass and folds any new assistant messages into the totals.
    private func read(_ url: URL, state: inout SessionState, isMain: Bool) {
        var cursor = state.files[url.path] ?? FileCursor()
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
            let size = (attributes[.size] as? NSNumber)?.uint64Value
        else { return }
        if size < cursor.offset {
            // Truncated or replaced: start over for this file (totals from it stay; it is rare).
            cursor = FileCursor()
        }
        guard size > cursor.offset, let handle = FileHandle(forReadingAtPath: url.path) else { return }
        defer { try? handle.close() }
        do {
            try handle.seek(toOffset: cursor.offset)
            while cursor.offset < size {
                guard let chunk = try handle.read(upToCount: Self.chunkSize), !chunk.isEmpty else { break }
                cursor.offset += UInt64(chunk.count)
                var buffer = cursor.tail
                buffer.append(chunk)
                var start = buffer.startIndex
                while let newline = buffer[start...].firstIndex(of: 0x0A) {
                    absorb(buffer[start..<newline], state: &state, isMain: isMain)
                    start = newline + 1
                }
                cursor.tail = start < buffer.endIndex ? Data(buffer[start...]) : Data()
            }
        } catch {
            // Keep what was read; the next pass retries from the stored offset.
        }
        state.files[url.path] = cursor
    }

    private static let usageMarker = Data("\"usage\"".utf8)
    private static let assistantMarker = Data("\"assistant\"".utf8)
    private let decoder = JSONDecoder()

    private func absorb(_ line: Data, state: inout SessionState, isMain: Bool) {
        guard line.count > 40, line.range(of: Self.usageMarker) != nil, line.range(of: Self.assistantMarker) != nil,
            let entry = try? decoder.decode(TranscriptLine.self, from: line),
            entry.type == "assistant", let message = entry.message, let usage = message.usage
        else { return }
        let id = message.id ?? ""
        if !id.isEmpty {
            guard !state.seen.contains(id) else { return }
            state.seen.insert(id)
        }
        let input = usage.inputTokens ?? 0
        let output = usage.outputTokens ?? 0
        let cacheRead = usage.cacheReadInputTokens ?? 0
        let cacheWrite = usage.cacheCreationInputTokens ?? 0
        // Without the TTL split, price every write at the 5-minute rate.
        let write1h = usage.cacheCreation?.ephemeral1h ?? 0
        let write5m = usage.cacheCreation?.ephemeral5m ?? max(0, cacheWrite - write1h)
        state.usage.input += input
        state.usage.output += output
        state.usage.cacheRead += cacheRead
        state.usage.cacheWrite += cacheWrite
        state.usage.turns += 1
        let model = message.model ?? ""
        if !model.isEmpty, model != "<synthetic>" {
            state.usage.model = model
            if let cost = ClaudePricing.cost(
                model: model, input: input, output: output, cacheRead: cacheRead,
                cacheWrite5m: write5m, cacheWrite1h: write1h)
            {
                state.usage.costUSD = (state.usage.costUSD ?? 0) + cost
            } else {
                state.usage.unpricedTurns += 1
            }
        }
        if isMain, entry.isSidechain != true {
            state.usage.context = input + cacheRead + cacheWrite
        }
    }

    /// `--session-usage-diagnose`: one line per live session with where its transcript was found and
    /// the totals read from it. Counts only, no transcript text.
    func diagnose() -> [String] {
        let sessions = ClaudeSessionFiles.load()
        var lines = ["claude_sessions=\(sessions.count)"]
        let started = Date()
        let usage = usage(for: sessions)
        lines.append(String(format: "read_seconds=%.2f", Date().timeIntervalSince(started)))
        lock.lock()
        let snapshot = states
        lock.unlock()
        for session in sessions {
            let state = snapshot[session.id]
            let found = state?.transcriptDirectory != nil
            var parts = ["pid=\(session.pid)", "transcript_found=\(found)", "files=\(state?.files.count ?? 0)"]
            if let u = usage[session.id] {
                parts.append("turns=\(u.turns)")
                parts.append("in=\(u.input) out=\(u.output) cache_read=\(u.cacheRead) cache_write=\(u.cacheWrite)")
                parts.append("model=\(u.model ?? "-") cost=\(u.costUSD.map { TokenFormat.cost($0) } ?? "-")")
                parts.append("unpriced=\(u.unpricedTurns) context=\(u.context ?? 0) badge=\(u.badge ?? "-")")
            }
            lines.append(parts.joined(separator: " "))
        }
        for session in CodexSessionFiles.load() {
            var parts = ["codex_pid=\(session.pid)"]
            if let u = session.usage {
                parts.append("in=\(u.input) out=\(u.output) cache_read=\(u.cacheRead) model=\(u.model ?? "-")")
                parts.append("context=\(u.context ?? 0)/\(u.contextLimit ?? 0) badge=\(u.badge ?? "-")")
            } else {
                parts.append("usage=none")
            }
            lines.append(parts.joined(separator: " "))
        }
        return lines
    }

    /// `projects/<encoded cwd>/`, the folder holding `<sessionId>.jsonl`. Claude Code turns every
    /// character other than a letter or digit into "-"; the whole projects folder is scanned when
    /// that guess misses (old versions encoded differently).
    private static func transcriptDirectory(sessionId: String, cwd: String) -> URL? {
        let projects = ClaudeSessionFiles.directory.deletingLastPathComponent()
            .appendingPathComponent("projects", isDirectory: true)
        let file = sessionId + ".jsonl"
        let encoded = String(cwd.map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "-" })
        for name in [encoded, cwd.replacingOccurrences(of: "/", with: "-")] where !name.isEmpty {
            let directory = projects.appendingPathComponent(name, isDirectory: true)
            if FileManager.default.fileExists(atPath: directory.appendingPathComponent(file).path) {
                return directory
            }
        }
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: projects.path) else { return nil }
        for name in names {
            let directory = projects.appendingPathComponent(name, isDirectory: true)
            if FileManager.default.fileExists(atPath: directory.appendingPathComponent(file).path) {
                return directory
            }
        }
        return nil
    }
}

private struct TranscriptLine: Decodable {
    let type: String?
    let isSidechain: Bool?
    let message: TranscriptMessage?
}

private struct TranscriptMessage: Decodable {
    let id: String?
    let model: String?
    let usage: TranscriptUsage?
}

private struct TranscriptUsage: Decodable {
    let inputTokens: Int?
    let outputTokens: Int?
    let cacheReadInputTokens: Int?
    let cacheCreationInputTokens: Int?
    let cacheCreation: TranscriptCacheCreation?

    enum CodingKeys: String, CodingKey {
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
        case cacheReadInputTokens = "cache_read_input_tokens"
        case cacheCreationInputTokens = "cache_creation_input_tokens"
        case cacheCreation = "cache_creation"
    }
}

private struct TranscriptCacheCreation: Decodable {
    let ephemeral5m: Int?
    let ephemeral1h: Int?

    enum CodingKeys: String, CodingKey {
        case ephemeral5m = "ephemeral_5m_input_tokens"
        case ephemeral1h = "ephemeral_1h_input_tokens"
    }
}
