import Foundation

/// Last successful usage per provider, so the card is never empty after a failed fetch or a relaunch.
/// Stored as a small JSON file in Application Support/MenuTools/ai-limits-cache.json.
enum AILimitsCache {
    struct Entry: Codable, Equatable, Sendable {
        var plan: String?
        var windows: [AIUsageWindow]
        var fetchedAt: Date
        /// Rate-limit back-off survives relaunches so a restart never hammers a 429ing endpoint.
        var blockedUntil: Date?
    }

    private struct File: Codable {
        var version = 1
        var entries: [String: Entry] = [:]
    }

    private static let queue = DispatchQueue(label: "com.frider.MenuTools.ai-limits-cache", qos: .utility)

    private static var fileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MenuTools", isDirectory: true)
            .appendingPathComponent("ai-limits-cache.json")
    }

    static func load() -> [AIProvider: Entry] {
        guard let data = try? Data(contentsOf: fileURL) else { return [:] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        guard let file = try? decoder.decode(File.self, from: data) else { return [:] }
        var result: [AIProvider: Entry] = [:]
        for (key, entry) in file.entries {
            if let provider = AIProvider(rawValue: key) { result[provider] = entry }
        }
        return result
    }

    /// Writes off the main thread; the file is a few hundred bytes.
    static func save(_ entries: [AIProvider: Entry]) {
        let file = File(entries: Dictionary(uniqueKeysWithValues: entries.map { ($0.key.rawValue, $0.value) }))
        queue.async {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .secondsSince1970
            guard let data = try? encoder.encode(file) else { return }
            let url = fileURL
            try? FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
        }
    }
}
