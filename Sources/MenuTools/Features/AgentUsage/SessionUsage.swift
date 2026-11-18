import Foundation

/// Token spend of one agent chat, read from the agent's own logs (Claude transcripts, Codex rollouts)
/// or its chat store (Cursor context fill). All counts are cumulative for that chat.
struct SessionUsage: Equatable, Codable, Sendable {
    /// Uncached input tokens.
    var input = 0
    var output = 0
    var cacheRead = 0
    var cacheWrite = 0
    /// Assistant messages (one per API call).
    var turns = 0
    /// Estimate at public API rates, for the turns whose model has a known price. Nil when none has.
    var costUSD: Double?
    /// Turns whose model had no price. The cost then shows a trailing "+".
    var unpricedTurns = 0
    /// Last model id seen, e.g. `claude-opus-5-5`.
    var model: String?
    /// Prompt size of the last request (what the next turn carries), or the chat's context fill.
    var context: Int?
    var contextLimit: Int?

    var total: Int { input + output + cacheRead + cacheWrite }

    var isEmpty: Bool { total == 0 && context == nil }

    /// Short text for the row, next to uptime: cost when known, otherwise tokens, otherwise context fill.
    var badge: String? {
        if let costUSD, costUSD > 0 {
            return TokenFormat.cost(costUSD) + (unpricedTurns > 0 ? "+" : "")
        }
        if total > 0 { return TokenFormat.short(total) + " tok" }
        if let context, let contextLimit, contextLimit > 0 {
            return "\(Int((Double(context) / Double(contextLimit) * 100).rounded()))% ctx"
        }
        return nil
    }

    /// "Opus 5.5", "Fable 5.1", "gpt-5.6" — the model id without the vendor prefix and date suffix.
    var modelTitle: String? {
        guard let model, !model.isEmpty, model != "<synthetic>" else { return nil }
        if let parsed = ClaudePricing.parse(model) {
            let family = parsed.family.prefix(1).uppercased() + parsed.family.dropFirst()
            return "\(family) \(ClaudePricing.versionText(parsed.version))"
        }
        return model
    }

    /// Drawer rows, in reading order. Empty when nothing is known.
    var detailLines: [(label: String, value: String)] {
        var lines: [(String, String)] = []
        if total > 0 {
            let turnWord = turns == 1 ? "turn" : "turns"
            let totalText = TokenFormat.short(total)
            lines.append(("Tokens", turns > 0 ? "\(totalText) · \(turns) \(turnWord)" : totalText))
            lines.append(("In / out", "\(TokenFormat.short(input)) in · \(TokenFormat.short(output)) out"))
            if cacheRead > 0 || cacheWrite > 0 {
                var parts = [String]()
                if cacheRead > 0 { parts.append("\(TokenFormat.short(cacheRead)) read") }
                if cacheWrite > 0 { parts.append("\(TokenFormat.short(cacheWrite)) written") }
                lines.append(("Cache", parts.joined(separator: " · ")))
            }
        }
        if let costUSD, costUSD > 0 {
            lines.append(("Cost", "\(TokenFormat.cost(costUSD))\(unpricedTurns > 0 ? "+" : "") at API rates"))
        }
        if let modelTitle { lines.append(("Model", modelTitle)) }
        if let context, context > 0 {
            if let contextLimit, contextLimit > 0 {
                let percent = Int((Double(context) / Double(contextLimit) * 100).rounded())
                let fill = "\(TokenFormat.short(context)) of \(TokenFormat.short(contextLimit))"
                lines.append(("Context", "\(fill) · \(percent)%"))
            } else {
                lines.append(("Context", TokenFormat.short(context)))
            }
        }
        return lines
    }

    static let claudeSample = SessionUsage(
        input: 294, output: 19_619, cacheRead: 760_969, cacheWrite: 155_661, turns: 24,
        costUSD: 4.12, model: "claude-opus-5-5", context: 84_200)
    static let codexSample = SessionUsage(
        input: 6_849, output: 1_230, cacheRead: 11_008, turns: 3, model: "gpt-5.6", context: 17_880,
        contextLimit: 258_400)
}

enum TokenFormat {
    /// 950, 12.3k, 1.2M.
    static func short(_ count: Int) -> String {
        let value = Double(count)
        if count < 1_000 { return "\(count)" }
        if count < 10_000 { return String(format: "%.1fk", value / 1_000).replacingOccurrences(of: ".0k", with: "k") }
        if count < 1_000_000 { return "\(count / 1_000)k" }
        if count < 10_000_000 {
            return String(format: "%.1fM", value / 1_000_000).replacingOccurrences(of: ".0M", with: "M")
        }
        return "\(count / 1_000_000)M"
    }

    /// "~$0.04", "~$4.12", "~$41". Always an estimate.
    static func cost(_ dollars: Double) -> String {
        if dollars < 0.01 { return "~$0.01" }
        if dollars < 10 { return String(format: "~$%.2f", dollars) }
        if dollars < 100 { return String(format: "~$%.1f", dollars) }
        return "~$\(Int(dollars.rounded()))"
    }
}

/// Public Claude API list prices, USD per million tokens. Cache writes are 1.25× input for the
/// 5-minute TTL and 2× for the 1-hour TTL. Unknown models price as nil.
enum ClaudePricing {
    struct Price: Sendable {
        var input: Double
        var output: Double
        var cacheRead: Double
    }

    struct Parsed: Sendable {
        var family: String
        /// Major * 10 + minor, so 5.5 → 55 and 4 → 40.
        var version: Int
    }

    static func cost(
        model: String, input: Int, output: Int, cacheRead: Int, cacheWrite5m: Int, cacheWrite1h: Int
    ) -> Double? {
        guard let price = price(for: model) else { return nil }
        let perToken = 1.0 / 1_000_000
        let tokens =
            Double(input) * price.input
            + Double(output) * price.output
            + Double(cacheRead) * price.cacheRead
            + Double(cacheWrite5m) * price.input * 1.25
            + Double(cacheWrite1h) * price.input * 2
        return tokens * perToken
    }

    static func price(for model: String) -> Price? {
        guard let parsed = parse(model) else { return nil }
        let v = parsed.version
        switch parsed.family {
        case "fable", "mythos":
            return Price(input: 10, output: 50, cacheRead: v >= 51 ? 0.25 : 1.0)
        case "opus":
            if v >= 55 { return Price(input: 4, output: 20, cacheRead: 0.2) }
            if v >= 45 { return Price(input: 5, output: 25, cacheRead: 0.5) }
            return Price(input: 15, output: 75, cacheRead: 1.5)
        case "sonnet":
            if v >= 50 { return Price(input: 2, output: 10, cacheRead: 0.2) }
            return Price(input: 3, output: 15, cacheRead: 0.3)
        case "haiku":
            if v >= 55 { return Price(input: 0.1, output: 0.5, cacheRead: 0.01) }
            if v >= 45 { return Price(input: 1, output: 5, cacheRead: 0.1) }
            if v >= 35 { return Price(input: 0.8, output: 4, cacheRead: 0.08) }
            return Price(input: 0.25, output: 1.25, cacheRead: 0.03)
        default:
            return nil
        }
    }

    /// `claude-opus-5-5`, `claude-3-5-haiku-20241022`, `claude-sonnet-4-5-20250929`.
    static func parse(_ model: String) -> Parsed? {
        let lower = model.lowercased()
        guard lower.contains("claude") else { return nil }
        let parts = lower.split(separator: "-").map(String.init)
        let families = ["fable", "mythos", "opus", "sonnet", "haiku"]
        guard let familyIndex = parts.firstIndex(where: { families.contains($0) }) else { return nil }
        let family = parts[familyIndex]
        // Version digits sit after the family (new ids) or before it (claude-3-5-haiku).
        var numbers: [Int] = []
        for part in parts[(familyIndex + 1)...] {
            guard let n = Int(part), part.count <= 2 else { break }
            numbers.append(n)
        }
        if numbers.isEmpty {
            for part in parts[..<familyIndex].reversed() {
                guard let n = Int(part), part.count <= 2 else { break }
                numbers.insert(n, at: 0)
            }
        }
        guard let major = numbers.first else { return nil }
        let minor = numbers.count > 1 ? numbers[1] : 0
        return Parsed(family: family, version: major * 10 + min(minor, 9))
    }

    static func versionText(_ version: Int) -> String {
        version % 10 == 0 ? "\(version / 10)" : "\(version / 10).\(version % 10)"
    }
}
