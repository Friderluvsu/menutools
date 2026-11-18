import Foundation

/// Token totals of a Codex thread, from the rollout log the CLI appends to
/// (`~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl`, path in `state_*.sqlite` `threads.rollout_path`).
/// Each turn ends with a `token_count` event whose `total_token_usage` is cumulative, so only the
/// file's tail is read, and only when the file has grown.
enum CodexRolloutUsage {
    private struct Cached {
        var size: UInt64
        var readAt: Date
        var usage: SessionUsage?
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [String: Cached] = [:]
    private static let tailBytes: UInt64 = 256 * 1024
    /// The Codex poll is synchronous on the main actor and the log grows all through a turn, so a
    /// grown file is re-read at most this often.
    private static let minimumInterval: TimeInterval = 5

    static func usage(rolloutPath: String) -> SessionUsage? {
        guard !rolloutPath.isEmpty else { return nil }
        lock.lock()
        let cached = cache[rolloutPath]
        lock.unlock()
        let now = Date()
        if let cached, now.timeIntervalSince(cached.readAt) < minimumInterval { return cached.usage }
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: rolloutPath),
            let size = (attributes[.size] as? NSNumber)?.uint64Value
        else { return nil }
        if let cached, cached.size == size { return cached.usage }
        let usage = read(rolloutPath, size: size)
        lock.lock()
        if cache.count > 100 { cache.removeAll() }
        cache[rolloutPath] = Cached(size: size, readAt: now, usage: usage)
        lock.unlock()
        return usage
    }

    private static func read(_ path: String, size: UInt64) -> SessionUsage? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        let start = size > tailBytes ? size - tailBytes : 0
        guard (try? handle.seek(toOffset: start)) != nil, let data = try? handle.readToEnd(), !data.isEmpty else {
            return nil
        }
        var usage: SessionUsage?
        var model: String?
        let decoder = JSONDecoder()
        var lines = data.split(separator: 0x0A, omittingEmptySubsequences: true)
        if start > 0, !lines.isEmpty { lines.removeFirst() }  // a partial line
        for line in lines.reversed() {
            if usage == nil, line.range(of: tokenCountMarker) != nil,
                let event = try? decoder.decode(RolloutEvent.self, from: line),
                event.payload?.type == "token_count", let info = event.payload?.info, let total = info.totalTokenUsage
            {
                let cached = total.cachedInputTokens ?? 0
                var next = SessionUsage()
                next.input = max(0, (total.inputTokens ?? 0) - cached)
                next.cacheRead = cached
                next.cacheWrite = total.cacheWriteInputTokens ?? 0
                next.output = total.outputTokens ?? 0
                next.context = info.lastTokenUsage?.totalTokens
                next.contextLimit = info.modelContextWindow
                usage = next
            }
            if model == nil, line.range(of: modelMarker) != nil,
                let event = try? decoder.decode(RolloutEvent.self, from: line), let found = event.payload?.model,
                !found.isEmpty
            {
                model = found
            }
            if usage != nil, model != nil { break }
        }
        usage?.model = model
        return usage
    }

    private static let tokenCountMarker = Data("\"token_count\"".utf8)
    private static let modelMarker = Data("\"model\":".utf8)
}

private struct RolloutEvent: Decodable {
    let type: String?
    let payload: RolloutPayload?
}

private struct RolloutPayload: Decodable {
    let type: String?
    let info: RolloutTokenInfo?
    /// `turn_context` events name the model.
    let model: String?
}

private struct RolloutTokenInfo: Decodable {
    let totalTokenUsage: RolloutTokenUsage?
    let lastTokenUsage: RolloutTokenUsage?
    let modelContextWindow: Int?

    enum CodingKeys: String, CodingKey {
        case totalTokenUsage = "total_token_usage"
        case lastTokenUsage = "last_token_usage"
        case modelContextWindow = "model_context_window"
    }
}

private struct RolloutTokenUsage: Decodable {
    let inputTokens: Int?
    let cachedInputTokens: Int?
    let cacheWriteInputTokens: Int?
    let outputTokens: Int?
    let totalTokens: Int?

    enum CodingKeys: String, CodingKey {
        case inputTokens = "input_tokens"
        case cachedInputTokens = "cached_input_tokens"
        case cacheWriteInputTokens = "cache_write_input_tokens"
        case outputTokens = "output_tokens"
        case totalTokens = "total_tokens"
    }
}
