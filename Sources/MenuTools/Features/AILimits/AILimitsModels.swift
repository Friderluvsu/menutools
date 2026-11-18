import Foundation

enum AIProvider: String, CaseIterable, Identifiable, Sendable, Codable {
    case claude
    case codex
    case antigravity
    case cursor

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .claude: return "Claude Code"
        case .codex: return "Codex"
        case .antigravity: return "Antigravity"
        case .cursor: return "Cursor"
        }
    }

    var icon: String {
        switch self {
        case .claude: return "asterisk"
        case .codex: return "chevron.left.forwardslash.chevron.right"
        case .antigravity: return "arrow.up.forward.circle"
        case .cursor: return "cursorarrow"
        }
    }

    var setupHint: String {
        switch self {
        case .claude: return "Sign in with `claude`"
        case .codex: return "Sign in with `codex`"
        case .antigravity: return "Open Antigravity"
        case .cursor: return "Sign in with `agent`"
        }
    }

    /// CLI that renews this provider's own login when run in Terminal.
    var loginCommand: String {
        switch self {
        case .claude: return "claude"
        case .codex: return "codex login"
        case .antigravity: return "agy"
        case .cursor: return "agent login"
        }
    }

    var renewsInTerminal: Bool { true }

    private var enabledKey: String { "AILimits.enabled.\(rawValue)" }

    var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }
        nonmutating set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }
}

/// One rate-limit window (e.g. 5-hour session, weekly, per-model quota).
struct AIUsageWindow: Identifiable, Equatable, Sendable, Codable {
    var id: String { label }
    let label: String
    /// 0…1, share of the limit already used.
    let usedFraction: Double
    let resetsAt: Date?
}

struct AIProviderUsage: Identifiable, Equatable, Sendable {
    enum Status: Equatable, Sendable {
        case ok
        case notConnected(String)
        case failed(String)
    }

    var id: String { provider.id }
    let provider: AIProvider
    var plan: String?
    var windows: [AIUsageWindow]
    var status: Status
    var fetchedAt: Date
    /// Windows come from an earlier fetch (cache / session log) because the latest one failed.
    var isStale = false
    /// Why the data is stale (shown as a tooltip), e.g. "Login expired — run claude".
    var note: String?
    /// Set when the server rate-limited us: seconds to wait (0 = no `Retry-After` header).
    var retryAfter: TimeInterval?

    static func notConnected(_ provider: AIProvider, _ reason: String? = nil) -> AIProviderUsage {
        AIProviderUsage(
            provider: provider, plan: nil, windows: [],
            status: .notConnected(reason ?? provider.setupHint), fetchedAt: .now)
    }

    static func failed(_ provider: AIProvider, _ message: String, retryAfter: TimeInterval? = nil) -> AIProviderUsage {
        AIProviderUsage(
            provider: provider, plan: nil, windows: [], status: .failed(message), fetchedAt: .now,
            retryAfter: retryAfter)
    }

    /// Most constrained window — drives the summary color.
    var peakUsage: Double { windows.map(\.usedFraction).max() ?? 0 }

    /// Windows whose reset time has passed are known to have reset: 0% used, next reset unknown.
    func rolledOver(now: Date = .now) -> AIProviderUsage {
        guard windows.contains(where: { ($0.resetsAt ?? .distantFuture) <= now }) else { return self }
        var copy = self
        copy.windows = windows.map { window in
            guard let reset = window.resetsAt, reset <= now else { return window }
            return AIUsageWindow(label: window.label, usedFraction: 0, resetsAt: nil)
        }
        return copy
    }

    /// "cached 3h ago" — shown instead of an error while old windows are displayed.
    func staleText(now: Date = .now) -> String {
        let age = AIResetFormatter.age(of: fetchedAt, now: now)
        return age == nil ? "cached" : "cached \(age!)"
    }
}

enum AIResetFormatter {
    /// "2h 14m", "3d 4h", "now".
    static func short(until date: Date?, now: Date = .now) -> String {
        guard let date else { return "—" }
        let seconds = Int(date.timeIntervalSince(now))
        if seconds <= 0 { return "now" }
        let days = seconds / 86_400
        let hours = (seconds % 86_400) / 3_600
        let minutes = (seconds % 3_600) / 60
        if days > 0 { return hours > 0 ? "\(days)d \(hours)h" : "\(days)d" }
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return "\(max(minutes, 1))m"
    }

    /// "5m ago", "3h ago", "2d ago"; nil when under a minute.
    static func age(of date: Date, now: Date = .now) -> String? {
        let seconds = Int(now.timeIntervalSince(date))
        if seconds < 60 { return nil }
        if seconds < 3_600 { return "\(seconds / 60)m ago" }
        if seconds < 86_400 { return "\(seconds / 3_600)h ago" }
        return "\(seconds / 86_400)d ago"
    }

    static func absolute(_ date: Date?) -> String {
        guard let date else { return "Unknown reset time" }
        return "Resets " + date.formatted(.dateTime.weekday(.abbreviated).hour().minute())
    }
}
