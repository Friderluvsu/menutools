import Foundation
import Security

// Usage sources (same approach as CodexBar):
// • Claude Code — OAuth token from Keychain "Claude Code-credentials" → api.anthropic.com/api/oauth/usage
// • Codex — ~/.codex/auth.json → chatgpt.com/backend-api/wham/usage, fallback: ~/.codex/sessions rollout logs
// • Antigravity — local language server RPC when the IDE is open (csrf token from its process arguments),
//   otherwise the `agy` CLI login (Keychain "gemini"/"antigravity") → cloudcode-pa quota API
//
// Claude token policy: Claude Code owns OAuth rotation, so we never run the refresh-token exchange and never
// write its Keychain item. No documented non-interactive, non-inference `claude` command refreshes it either
// (`claude auth status` only reports state — verified: expiresAt stays unchanged; `/status` and `/usage` are
// TUI-only, not available with -p). While the token is expired we skip the doomed request and rely on the
// cached numbers (AILimitsManager) until Claude Code rewrites the Keychain item.



// MARK: - Claude Code

enum ClaudeUsageFetcher {
    private struct Credentials: Decodable {
        struct OAuth: Decodable {
            let accessToken: String?
            let expiresAt: Double?
            let subscriptionType: String?
            let rateLimitTier: String?

            /// `expiresAt` is epoch milliseconds.
            var expiryDate: Date? { expiresAt.map { Date(timeIntervalSince1970: $0 / 1000) } }
            var isExpired: Bool { (expiryDate ?? .distantFuture).timeIntervalSinceNow < 30 }
        }
        let claudeAiOauth: OAuth?
    }

    private struct Window: Decodable {
        let utilization: Double?
        let resets_at: String?
    }

    private struct Limit: Decodable {
        struct Scope: Decodable {
            struct Model: Decodable { let display_name: String? }
            let model: Model?
        }
        let kind: String?
        let percent: Double?
        let resets_at: String?
        let scope: Scope?
    }

    private struct UsageResponse: Decodable {
        let five_hour: Window?
        let seven_day: Window?
        let seven_day_opus: Window?
        let seven_day_sonnet: Window?
        let limits: [Limit]?
    }

    static func fetch() async -> AIProviderUsage {
        let expiredMessage = "Login expired — run claude"
        let items = keychainItems()
        let stamp = keychainStamp(items)
        // Same Keychain items as the last expired read: nothing to re-read, nothing to ask.
        if ExpiredGate.shared.isStillExpired(stamp: stamp) { return .failed(.claude, expiredMessage) }

        guard let oauth = await loadCredentials(services: items.map(\.service)), let token = oauth.accessToken, !token.isEmpty else {
            return .notConnected(.claude)
        }
        if oauth.isExpired {
            ExpiredGate.shared.markExpired(stamp: stamp)
            return .failed(.claude, expiredMessage)
        }
        ExpiredGate.shared.clear()

        var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        request.timeoutInterval = 15
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("claude-code/2.1.0", forHTTPHeaderField: "User-Agent")

        let plan = planName(oauth)
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let http = response as? HTTPURLResponse
            let status = http?.statusCode ?? 0
            switch status {
            case 200: break
            case 401: return .failed(.claude, expiredMessage)
            case 403: return .failed(.claude, "Token lacks usage scope")
            case 429:
                return .failed(.claude, "Rate limited, retry later", retryAfter: AIFetchSupport.retryAfter(http))
            default: return .failed(.claude, "HTTP \(status)")
            }
            let usage = try JSONDecoder().decode(UsageResponse.self, from: data)
            return AIProviderUsage(
                provider: .claude, plan: plan, windows: windows(from: usage), status: .ok, fetchedAt: .now)
        } catch {
            return .failed(.claude, AIFetchSupport.describe(error))
        }
    }

    /// Remembers that the Keychain items held an expired token, keyed by their modification dates
    /// (attribute query only — no secret, no prompt). Claude Code rewriting the item changes the stamp.
    private final class ExpiredGate: @unchecked Sendable {
        static let shared = ExpiredGate()
        private let lock = NSLock()
        private var stamp: String?
        private var since = Date.distantPast

        func isStillExpired(stamp current: String) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            return !current.isEmpty && stamp == current && Date.now.timeIntervalSince(since) < 1800
        }

        func markExpired(stamp current: String) {
            lock.lock()
            defer { lock.unlock() }
            stamp = current
            since = .now
        }

        func clear() {
            lock.lock()
            defer { lock.unlock() }
            stamp = nil
        }
    }

    /// Empty when a credentials file exists, so the gate never hides a file-based login.
    private static func keychainStamp(_ items: [(service: String, modified: Date)]) -> String {
        if FileManager.default.fileExists(atPath: credentialsFileURL.path) { return "" }
        return items.map { "\($0.service)@\($0.modified.timeIntervalSince1970)" }.joined(separator: "|")
    }

    private static func windows(from usage: UsageResponse) -> [AIUsageWindow] {
        var result: [AIUsageWindow] = []
        func add(_ label: String, _ window: Window?) {
            guard let window, let utilization = window.utilization else { return }
            result.append(
                AIUsageWindow(
                    label: label,
                    usedFraction: utilization / 100,
                    resetsAt: AIFetchSupport.parseDate(window.resets_at)))
        }
        add("Session", usage.five_hour)
        add("Week", usage.seven_day)

        // Newer responses put model-scoped weekly caps into `limits[]`.
        let scoped = (usage.limits ?? []).filter { $0.kind == "weekly_scoped" }
        if scoped.isEmpty {
            add("Week Opus", usage.seven_day_opus)
            add("Week Sonnet", usage.seven_day_sonnet)
        } else {
            for limit in scoped {
                guard let percent = limit.percent else { continue }
                let model = limit.scope?.model?.display_name ?? "Model"
                result.append(
                    AIUsageWindow(
                        label: "Week \(model)",
                        usedFraction: percent / 100,
                        resetsAt: AIFetchSupport.parseDate(limit.resets_at)))
            }
        }
        return result
    }

    private static func planName(_ oauth: Credentials.OAuth) -> String? {
        let tier = oauth.rateLimitTier?.lowercased() ?? ""
        if tier.contains("max_20x") { return "MAX 20×" }
        if tier.contains("max_5x") { return "MAX 5×" }
        return oauth.subscriptionType?.uppercased()
    }

    /// Claude Code stores credentials via `security`, so reading through the same tool
    /// avoids an extra Keychain prompt. `~/.claude/.credentials.json` is the legacy fallback.
    private static func loadCredentials(services: [String]) async -> Credentials.OAuth? {
        for service in services.isEmpty ? ["Claude Code-credentials"] : services {
            let keychain = await AIFetchSupport.run("/usr/bin/security", ["find-generic-password", "-s", service, "-w"])
            if keychain.status == 0, let oauth = decode(keychain.output), oauth.accessToken != nil {
                return oauth
            }
        }

        if let data = try? Data(contentsOf: credentialsFileURL) {
            return decode(data)
        }
        return nil
    }

    private static var credentialsFileURL: URL {
        let configDir =
            ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"]
            ?? (NSHomeDirectory() as NSString).appendingPathComponent(".claude")
        return URL(fileURLWithPath: configDir).appendingPathComponent(".credentials.json")
    }

    /// Service is "Claude Code-credentials", plus a hash suffix when CLAUDE_CONFIG_DIR is used
    /// (e.g. "Claude Code-credentials-1a2b3c4d"). Only attributes are queried — no secret, no prompt.
    static func keychainServices() -> [String] {
        let services = keychainItems().map(\.service)
        return services.isEmpty ? ["Claude Code-credentials"] : services
    }

    /// Newest-modified first.
    private static func keychainItems() -> [(service: String, modified: Date)] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true,
        ]
        var result: CFTypeRef?
        var found: [(service: String, modified: Date)] = []
        if SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
            let items = result as? [[String: Any]]
        {
            for item in items {
                guard let service = item[kSecAttrService as String] as? String,
                    service.hasPrefix("Claude Code"), service.contains("credentials")
                else { continue }
                found.append((service, item[kSecAttrModificationDate as String] as? Date ?? .distantPast))
            }
        }
        var items: [(service: String, modified: Date)] = []
        for entry in found.sorted(by: { $0.modified > $1.modified }) where !items.contains(where: { $0.service == entry.service }) {
            items.append(entry)
        }
        return items
    }

    static func diagnostics() async -> [String] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        let items = (result as? [[String: Any]]) ?? []
        let claudeItems = items.filter { ($0[kSecAttrService as String] as? String)?.lowercased().contains("claude") == true }
        let credentialsFile = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude/.credentials.json")
        var lines = [
            "[claude] keychain scan status=\(status) items=\(items.count) claude-items=\(claudeItems.compactMap { $0[kSecAttrService as String] as? String }) credentials.json=\(FileManager.default.fileExists(atPath: credentialsFile.path))"
        ]
        for service in keychainServices() {
            let keychain = await AIFetchSupport.run("/usr/bin/security", ["find-generic-password", "-s", service, "-w"])
            let oauth = keychain.status == 0 ? decode(keychain.output) : nil
            lines.append(
                "[claude] service=\"\(service)\" exit=\(keychain.status) oauth=\(oauth != nil) token=\(oauth?.accessToken != nil) expired=\(oauth?.isExpired ?? false) expires-in=\(oauth?.expiryDate.map { String(Int($0.timeIntervalSinceNow / 60)) + "m" } ?? "-")"
            )
        }
        return lines
    }

    private static func decode(_ data: Data) -> Credentials.OAuth? {
        let trimmed = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return (try? JSONDecoder().decode(Credentials.self, from: Data(trimmed.utf8)))?.claudeAiOauth
    }
}

// MARK: - Codex

enum CodexUsageFetcher {
    private struct AuthFile: Decodable {
        struct Tokens: Decodable {
            let access_token: String?
            let account_id: String?
        }
        let tokens: Tokens?
    }

    private struct UsageResponse: Decodable {
        struct RateLimit: Decodable {
            let primary_window: Window?
            let secondary_window: Window?
        }
        struct Window: Decodable {
            let used_percent: Double?
            let limit_window_seconds: Double?
            let reset_at: Double?
            let reset_after_seconds: Double?
        }
        let plan_type: String?
        let rate_limit: RateLimit?
    }

    private struct RolloutLine: Decodable {
        struct Payload: Decodable {
            let type: String?
            let rate_limits: RateLimits?
        }
        struct RateLimits: Decodable {
            let primary: Window?
            let secondary: Window?
            let plan_type: String?
        }
        struct Window: Decodable {
            let used_percent: Double?
            let window_minutes: Double?
            let resets_at: Double?
            let resets_in_seconds: Double?
        }
        let timestamp: String?
        let type: String?
        let payload: Payload?
    }

    private static var codexHome: URL {
        if let custom = ProcessInfo.processInfo.environment["CODEX_HOME"], !custom.isEmpty {
            return URL(fileURLWithPath: custom)
        }
        return URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".codex")
    }

    static func fetch() async -> AIProviderUsage {
        let online = await fetchOnline()
        if let online, online.status == .ok { return online }
        if var offline = fetchFromRollouts() {
            offline.retryAfter = online?.retryAfter  // keep the 429 back-off even when the log fallback works
            return offline
        }
        return online ?? .notConnected(.codex)
    }

    private static func fetchOnline() async -> AIProviderUsage? {
        let authURL = codexHome.appendingPathComponent("auth.json")
        guard let data = try? Data(contentsOf: authURL),
            let auth = try? JSONDecoder().decode(AuthFile.self, from: data),
            let token = auth.tokens?.access_token, !token.isEmpty
        else { return nil }

        var request = URLRequest(url: URL(string: "https://chatgpt.com/backend-api/wham/usage")!)
        request.timeoutInterval = 15
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("MenuTools", forHTTPHeaderField: "User-Agent")
        if let account = auth.tokens?.account_id, !account.isEmpty {
            request.setValue(account, forHTTPHeaderField: "ChatGPT-Account-Id")
        }

        do {
            let (body, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200 else {
                switch status {
                case 401: return .failed(.codex, "Login expired — run codex")
                case 429:
                    return .failed(
                        .codex, "Rate limited, retry later",
                        retryAfter: AIFetchSupport.retryAfter(response as? HTTPURLResponse))
                default: return .failed(.codex, "HTTP \(status)")
                }
            }
            let usage = try JSONDecoder().decode(UsageResponse.self, from: body)
            let windows = [usage.rate_limit?.primary_window, usage.rate_limit?.secondary_window]
                .compactMap { $0 }
                .compactMap { window -> AIUsageWindow? in
                    guard let used = window.used_percent else { return nil }
                    let reset =
                        window.reset_at.map { Date(timeIntervalSince1970: $0) }
                        ?? window.reset_after_seconds.map { Date.now.addingTimeInterval($0) }
                    return AIUsageWindow(
                        label: label(minutes: window.limit_window_seconds.map { $0 / 60 }),
                        usedFraction: used / 100, resetsAt: reset)
                }
            return AIProviderUsage(
                provider: .codex, plan: planName(usage.plan_type), windows: sorted(windows), status: .ok,
                fetchedAt: .now)
        } catch {
            return .failed(.codex, AIFetchSupport.describe(error))
        }
    }

    /// Offline fallback: the CLI logs a `token_count` event with `rate_limits` after every turn.
    private static func fetchFromRollouts() -> AIProviderUsage? {
        let sessions = codexHome.appendingPathComponent("sessions")
        let fileManager = FileManager.default
        let calendar = Calendar.current

        var files: [(url: URL, modified: Date)] = []
        for dayOffset in 0..<7 {
            guard let day = calendar.date(byAdding: .day, value: -dayOffset, to: .now) else { continue }
            let parts = calendar.dateComponents([.year, .month, .day], from: day)
            let dir = sessions.appendingPathComponent(
                String(format: "%04d/%02d/%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0))
            guard
                let entries = try? fileManager.contentsOfDirectory(
                    at: dir, includingPropertiesForKeys: [.contentModificationDateKey])
            else { continue }
            for url in entries where url.lastPathComponent.hasPrefix("rollout-") && url.pathExtension == "jsonl" {
                let modified =
                    (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                    ?? .distantPast
                files.append((url, modified))
            }
        }

        let decoder = JSONDecoder()
        for file in files.sorted(by: { $0.modified > $1.modified }) {
            guard let text = try? String(contentsOf: file.url, encoding: .utf8) else { continue }
            for line in text.split(separator: "\n").reversed() where line.contains("\"token_count\"") {
                guard let entry = try? decoder.decode(RolloutLine.self, from: Data(line.utf8)),
                    entry.type == "event_msg", entry.payload?.type == "token_count",
                    let limits = entry.payload?.rate_limits
                else { continue }

                let loggedAt = AIFetchSupport.parseDate(entry.timestamp) ?? file.modified
                let windows = [limits.primary, limits.secondary].compactMap { $0 }.compactMap {
                    window -> AIUsageWindow? in
                    guard let used = window.used_percent else { return nil }
                    let reset =
                        window.resets_at.map { Date(timeIntervalSince1970: $0) }
                        ?? window.resets_in_seconds.map { loggedAt.addingTimeInterval($0) }
                    // Window already rolled over since the log was written.
                    let isStale = reset.map { $0 < .now } ?? false
                    return AIUsageWindow(
                        label: label(minutes: window.window_minutes),
                        usedFraction: isStale ? 0 : used / 100,
                        resetsAt: isStale ? nil : reset)
                }
                guard !windows.isEmpty else { continue }
                return AIProviderUsage(
                    provider: .codex, plan: planName(limits.plan_type), windows: sorted(windows), status: .ok,
                    fetchedAt: loggedAt)
            }
        }
        return nil
    }

    private static func label(minutes: Double?) -> String {
        guard let minutes else { return "Limit" }
        switch Int(minutes.rounded()) {
        case 300: return "5h"
        case 10_080: return "Week"
        case let m where m % 1440 == 0: return "\(m / 1440)d"
        case let m where m % 60 == 0: return "\(m / 60)h"
        case let m: return "\(m)m"
        }
    }

    private static func sorted(_ windows: [AIUsageWindow]) -> [AIUsageWindow] {
        windows.sorted { ($0.label == "Week" ? 1 : 0) < ($1.label == "Week" ? 1 : 0) }
    }

    private static func planName(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty, raw != "unknown" else { return nil }
        return raw.replacingOccurrences(of: "_", with: " ").uppercased()
    }
}

// MARK: - Antigravity

enum AntigravityUsageFetcher {
    private struct ServerProcess {
        let pid: Int32
        let csrfToken: String
        let extensionPort: Int?
        let extensionToken: String?
    }

    static func fetch() async -> AIProviderUsage {
        let local = await fetchFromLocalServer()
        if let local, local.status == .ok { return local }
        if let cli = await fetchFromCLI() { return cli }
        return local ?? .notConnected(.antigravity, "Open Antigravity or sign in with agy")
    }

    /// nil when the IDE is not running.
    private static func fetchFromLocalServer() async -> AIProviderUsage? {
        guard let server = await findServer() else { return nil }

        var endpoints: [(base: String, token: String)] = await listeningPorts(pid: server.pid)
            .filter { $0 != server.extensionPort }
            .map { ("https://127.0.0.1:\($0)", server.csrfToken) }
        // Plain-HTTP extension server is the fallback transport.
        if let port = server.extensionPort {
            endpoints.append(("http://127.0.0.1:\(port)", server.extensionToken ?? server.csrfToken))
        }
        guard !endpoints.isEmpty else { return .failed(.antigravity, "Language server port not found") }

        let session = LocalhostSession.shared.session
        for endpoint in endpoints {
            let base = endpoint.base + "/exa.language_server_pb.LanguageServerService/"
            let status = await call(session, base + "GetUserStatus", token: endpoint.token, body: metadataBody)
            guard let status else { continue }

            let plan = planName(status)
            if let summary = await call(
                session, base + "RetrieveUserQuotaSummary", token: endpoint.token, body: ["forceRefresh": true]),
                let windows = quotaSummaryWindows(summary), !windows.isEmpty
            {
                return AIProviderUsage(provider: .antigravity, plan: plan, windows: windows, status: .ok, fetchedAt: .now)
            }
            return AIProviderUsage(
                provider: .antigravity, plan: plan, windows: modelConfigWindows(status), status: .ok, fetchedAt: .now)
        }
        return .failed(.antigravity, "Language server did not respond")
    }

    private static let metadataBody: [String: Any] = [
        "metadata": [
            "ideName": "antigravity", "extensionName": "antigravity", "ideVersion": "unknown", "locale": "en",
        ]
    ]

    // MARK: Process & port discovery

    private static func findServer() async -> ServerProcess? {
        let ps = await AIFetchSupport.run("/bin/ps", ["-ax", "-o", "pid=,command="])
        guard ps.status == 0 else { return nil }

        for rawLine in String(decoding: ps.output, as: UTF8.self).split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            let lower = line.lowercased()
            guard lower.range(of: #"(^|[/\\ ])language[_-]server([_-][a-z0-9]+)*(\s|$)"#, options: .regularExpression) != nil,
                lower.contains("antigravity"),
                let token = flag("--csrf_token", in: line),
                let pidString = line.split(separator: " ").first, let pid = Int32(pidString)
            else { continue }
            return ServerProcess(
                pid: pid,
                csrfToken: token,
                extensionPort: flag("--extension_server_port", in: line).flatMap(Int.init),
                extensionToken: flag("--extension_server_csrf_token", in: line))
        }
        return nil
    }

    private static func flag(_ name: String, in line: String) -> String? {
        guard let range = line.range(of: "\(name)[=\\s]+(\\S+)", options: .regularExpression) else { return nil }
        let match = line[range]
        let value = match.dropFirst(name.count).drop { $0 == "=" || $0 == " " }
        return value.isEmpty ? nil : String(value)
    }

    private static func listeningPorts(pid: Int32) async -> [Int] {
        let lsof = await AIFetchSupport.run(
            "/usr/sbin/lsof", ["-nP", "-iTCP", "-sTCP:LISTEN", "-a", "-p", String(pid), "-Fn"])
        var ports: [Int] = []
        for line in String(decoding: lsof.output, as: UTF8.self).split(separator: "\n") where line.hasPrefix("n") {
            if let portString = line.split(separator: ":").last, let port = Int(portString), !ports.contains(port) {
                ports.append(port)
            }
        }
        return ports
    }

    // MARK: RPC

    private static func call(_ session: URLSession, _ url: String, token: String, body: [String: Any]) async
        -> [String: Any]?
    {
        guard let url = URL(string: url) else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 6
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
        request.setValue(token, forHTTPHeaderField: "X-Codeium-Csrf-Token")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        guard let (data, response) = try? await session.data(for: request),
            (response as? HTTPURLResponse)?.statusCode == 200
        else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    // MARK: Parsing

    private static func planName(_ status: [String: Any]) -> String? {
        let user = status["userStatus"] as? [String: Any]
        let tier = (user?["userTier"] as? [String: Any])?["name"] as? String
        let info = ((user?["planStatus"] as? [String: Any])?["planInfo"] as? [String: Any]) ?? [:]
        let name =
            tier
            ?? ["planDisplayName", "displayName", "productName", "planName", "planShortName"]
            .lazy.compactMap { info[$0] as? String }.first
        return name?
            .replacingOccurrences(of: "Google AI ", with: "")
            .uppercased()
    }

    /// Groups (Gemini / Claude+GPT) with 5-hour and weekly buckets.
    /// Accepts camelCase (RPC / REST) and snake_case (`agy /usage` JSON) keys.
    static func quotaSummaryWindows(_ json: [String: Any]) -> [AIUsageWindow]? {
        let root = (json["response"] as? [String: Any]) ?? (json["summary"] as? [String: Any]) ?? json
        guard let groups = root["groups"] as? [[String: Any]] else { return nil }

        var result: [AIUsageWindow] = []
        for group in groups {
            let groupName = shortGroupName(field(group, "displayName", "display_name", "name") as? String ?? "")
            for bucket in group["buckets"] as? [[String: Any]] ?? [] {
                if bucket["disabled"] as? Bool == true { continue }
                guard let remaining = remainingFraction(bucket) else { continue }
                let cadence = cadenceLabel(bucket)
                result.append(
                    AIUsageWindow(
                        label: "\(groupName) \(cadence)",
                        usedFraction: 1 - remaining,
                        resetsAt: AIFetchSupport.parseDate(field(bucket, "resetTime", "reset_time"))))
            }
        }
        return result
    }

    private static func field(_ dict: [String: Any], _ keys: String...) -> Any? {
        keys.lazy.compactMap { dict[$0] }.first
    }

    /// Legacy servers: per-model quota; show the most constrained model per pool.
    private static func modelConfigWindows(_ status: [String: Any]) -> [AIUsageWindow] {
        let configs =
            (((status["userStatus"] as? [String: Any])?["cascadeModelConfigData"] as? [String: Any])?[
                "clientModelConfigs"] as? [[String: Any]]) ?? []

        var pools: [String: AIUsageWindow] = [:]
        for config in configs {
            guard let quota = config["quotaInfo"] as? [String: Any],
                let remaining = (quota["remainingFraction"] as? NSNumber)?.doubleValue
            else { continue }
            let pool = shortGroupName(config["label"] as? String ?? "")
            let window = AIUsageWindow(
                label: pool, usedFraction: 1 - remaining, resetsAt: AIFetchSupport.parseDate(quota["resetTime"]))
            if let existing = pools[pool], existing.usedFraction >= window.usedFraction { continue }
            pools[pool] = window
        }
        return pools.values.sorted { $0.label < $1.label }
    }

    private static func remainingFraction(_ bucket: [String: Any]) -> Double? {
        if let value = field(bucket, "remainingFraction", "remaining_fraction") as? NSNumber { return value.doubleValue }
        guard let remaining = bucket["remaining"] as? [String: Any] else { return nil }
        if let value = field(remaining, "remainingFraction", "remaining_fraction") as? NSNumber {
            return value.doubleValue
        }
        if remaining["case"] as? String == "remainingFraction", let value = remaining["value"] as? NSNumber {
            return value.doubleValue
        }
        return nil
    }

    private static func cadenceLabel(_ bucket: [String: Any]) -> String {
        let hint = [
            bucket["window"], field(bucket, "bucketId", "bucket_id", "id"), field(bucket, "displayName", "display_name"),
        ]
        .compactMap { $0 as? String }.joined(separator: " ").lowercased()
        if hint.contains("week") || hint.contains("7d") { return "Wk" }
        if hint.contains("5h") || hint.contains("five") || hint.contains("hour") || hint.contains("session") {
            return "5h"
        }
        return ""
    }

    private static func shortGroupName(_ name: String) -> String {
        let lower = name.lowercased()
        if lower.contains("gemini") { return "Gemini" }
        if lower.contains("claude") || lower.contains("gpt") || lower.hasPrefix("3p") { return "Claude/GPT" }
        return name.replacingOccurrences(of: " models", with: "", options: .caseInsensitive)
    }

    /// The language server uses a self-signed certificate on 127.0.0.1 only.
    private final class LocalhostSession: NSObject, URLSessionDelegate, @unchecked Sendable {
        static let shared = LocalhostSession()
        private(set) lazy var session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: nil)

        func urlSession(
            _ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
            completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
        ) {
            let space = challenge.protectionSpace
            if space.authenticationMethod == NSURLAuthenticationMethodServerTrust,
                space.host == "127.0.0.1" || space.host == "localhost",
                let trust = space.serverTrust
            {
                completionHandler(.useCredential, URLCredential(trust: trust))
            } else {
                completionHandler(.performDefaultHandling, nil)
            }
        }
    }
}

// MARK: - Antigravity CLI (agy)

extension AntigravityUsageFetcher {
    private struct CLIToken {
        let accessToken: String
        let expiry: Date?

        var isFresh: Bool { (expiry ?? .distantFuture).timeIntervalSinceNow > 60 }
    }

    private static let cloudHosts = [
        "https://cloudcode-pa.googleapis.com", "https://daily-cloudcode-pa.googleapis.com",
    ]

    /// nil when agy is not signed in on this Mac.
    fileprivate static func fetchFromCLI() async -> AIProviderUsage? {
        guard let token = await readCLIToken() else { return nil }
        if token.isFresh {
            switch await fetchFromCloud(token.accessToken) {
            case .success(let usage): return usage
            case .failure(.unavailable): return .failed(.antigravity, "Quota API unavailable")
            case .failure(.unauthorized): break
            }
        }

        // Token expired (agy refreshes it only while running): let agy refresh it and report usage itself.
        guard let agy = agyPath() else { return .failed(.antigravity, "Login expired — run agy") }
        let output = await runAgyUsage(agy)
        if let refreshed = await readCLIToken(), refreshed.isFresh,
            case .success(let usage) = await fetchFromCloud(refreshed.accessToken)
        {
            return usage
        }
        if let output, let windows = quotaSummaryWindows(output), !windows.isEmpty {
            return AIProviderUsage(provider: .antigravity, plan: nil, windows: windows, status: .ok, fetchedAt: .now)
        }
        return .failed(.antigravity, "Login expired — run agy")
    }

    /// agy stores a Go `oauth2.Token` via go-keyring: `{"token":{"access_token","expiry",…},"auth_method":…}`.
    private static func readCLIToken() async -> CLIToken? {
        let keychain = await AIFetchSupport.run(
            "/usr/bin/security", ["find-generic-password", "-s", "gemini", "-a", "antigravity", "-w"])
        if keychain.status == 0, let token = parseCLIToken(keychain.output) { return token }

        let configDir =
            ProcessInfo.processInfo.environment["ANTIGRAVITY_CONFIG_DIR"]
            ?? (NSHomeDirectory() as NSString).appendingPathComponent(".gemini/antigravity-cli")
        let file = URL(fileURLWithPath: configDir).appendingPathComponent("antigravity-oauth-token")
        return (try? Data(contentsOf: file)).flatMap(parseCLIToken)
    }

    private static func parseCLIToken(_ data: Data) -> CLIToken? {
        var text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("go-keyring-base64:") {
            guard let decoded = Data(base64Encoded: String(text.dropFirst("go-keyring-base64:".count))) else {
                return nil
            }
            text = String(decoding: decoded, as: UTF8.self)
        } else if text.hasPrefix("go-keyring-encoded:") {
            text = String(decoding: hexDecoded(String(text.dropFirst("go-keyring-encoded:".count))), as: UTF8.self)
        }

        guard let json = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else { return nil }
        let token = (json["token"] as? [String: Any]) ?? json
        guard let access = token["access_token"] as? String, !access.isEmpty else { return nil }
        let expiry =
            AIFetchSupport.parseDate(token["expiry"])
            ?? (token["expiry_date"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue / 1000) }
        return CLIToken(accessToken: access, expiry: expiry)
    }

    private static func hexDecoded(_ hex: String) -> Data {
        var data = Data()
        var index = hex.startIndex
        while let next = hex.index(index, offsetBy: 2, limitedBy: hex.endIndex), index < hex.endIndex {
            if let byte = UInt8(hex[index..<next], radix: 16) { data.append(byte) }
            index = next
        }
        return data
    }

    private static func fetchFromCloud(_ accessToken: String) async -> Result<AIProviderUsage, CloudError> {
        for host in cloudHosts {
            let assist = await cloudCall(
                host, "loadCodeAssist", accessToken,
                body: ["metadata": ["ideType": "ANTIGRAVITY", "platform": "PLATFORM_UNSPECIFIED", "pluginType": "GEMINI"]])
            guard case .success(let info) = assist else {
                if case .failure(.unauthorized) = assist { return .failure(.unauthorized) }
                continue
            }

            let project: Any? = {
                let raw = info["cloudaicompanionProject"]
                if let id = raw as? String { return id }
                let dict = raw as? [String: Any]
                return dict?["id"] ?? dict?["projectId"]
            }()
            let body: [String: Any] = project.map { ["project": $0] } ?? [:]
            let plan = cloudPlanName(info)

            if case .success(let summary) = await cloudCall(host, "retrieveUserQuotaSummary", accessToken, body: body),
                let windows = quotaSummaryWindows(summary), !windows.isEmpty
            {
                return .success(
                    AIProviderUsage(provider: .antigravity, plan: plan, windows: windows, status: .ok, fetchedAt: .now))
            }
            if case .success(let models) = await cloudCall(host, "fetchAvailableModels", accessToken, body: body) {
                return .success(
                    AIProviderUsage(
                        provider: .antigravity, plan: plan, windows: availableModelWindows(models), status: .ok,
                        fetchedAt: .now))
            }
        }
        return .failure(.unavailable)
    }

    private enum CloudError: Error { case unauthorized, unavailable }

    private static func cloudCall(_ host: String, _ method: String, _ token: String, body: [String: Any]) async
        -> Result<[String: Any], CloudError>
    {
        guard let url = URL(string: "\(host)/v1internal:\(method)") else { return .failure(.unavailable) }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("antigravity/hub/2.9.1 darwin/arm64", forHTTPHeaderField: "User-Agent")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        guard let (data, response) = try? await URLSession.shared.data(for: request) else {
            return .failure(.unavailable)
        }
        switch (response as? HTTPURLResponse)?.statusCode {
        case 200:
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            return json.map { .success($0) } ?? .failure(.unavailable)
        case 401: return .failure(.unauthorized)
        default: return .failure(.unavailable)
        }
    }

    private static func cloudPlanName(_ info: [String: Any]) -> String? {
        let name =
            (info["paidTier"] as? [String: Any])?["name"] as? String
            ?? (info["currentTier"] as? [String: Any])?["name"] as? String
        return name?.replacingOccurrences(of: "Google AI ", with: "").uppercased()
    }

    /// `models` is a map keyed by model id; keep the most constrained model per pool.
    private static func availableModelWindows(_ json: [String: Any]) -> [AIUsageWindow] {
        var pools: [String: AIUsageWindow] = [:]
        for (id, value) in json["models"] as? [String: Any] ?? [:] {
            guard let model = value as? [String: Any], model["isInternal"] as? Bool != true,
                let quota = model["quotaInfo"] as? [String: Any],
                let remaining = (quota["remainingFraction"] as? NSNumber)?.doubleValue
            else { continue }
            let pool = shortGroupName(model["displayName"] as? String ?? id)
            let window = AIUsageWindow(
                label: pool, usedFraction: 1 - remaining, resetsAt: AIFetchSupport.parseDate(quota["resetTime"]))
            if let existing = pools[pool], existing.usedFraction >= window.usedFraction { continue }
            pools[pool] = window
        }
        return pools.values.sorted { $0.label < $1.label }
    }

    private static func agyPath() -> String? {
        let home = NSHomeDirectory()
        return ["\(home)/.local/bin/agy", "/opt/homebrew/bin/agy", "/usr/local/bin/agy"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// `agy -p /usage --output-format json` → `{"command":{"data":{"groups":[…]}}}`. Slow, so used only
    /// when the stored token has expired; it also refreshes the token for the next direct call.
    private static func runAgyUsage(_ agy: String) async -> [String: Any]? {
        let result = await AIFetchSupport.run(
            agy, ["-p", "/usage", "--output-format", "json"], timeout: 90,
            directory: FileManager.default.temporaryDirectory)
        let text = String(decoding: result.output, as: UTF8.self)
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"),
            let json = try? JSONSerialization.jsonObject(with: Data(text[start...end].utf8)) as? [String: Any]
        else { return nil }
        let command = json["command"] as? [String: Any]
        return (command?["data"] as? [String: Any]) ?? json
    }

    static func diagnostics() async -> [String] {
        let keychain = await AIFetchSupport.run(
            "/usr/bin/security", ["find-generic-password", "-s", "gemini", "-a", "antigravity", "-w"])
        let token = keychain.status == 0 ? parseCLIToken(keychain.output) : nil
        let expiry = token?.expiry.map { AIResetFormatter.short(until: $0) } ?? "-"
        return [
            "[antigravity] ide-running=\(await findServer() != nil) cli-keychain exit=\(keychain.status) token=\(token != nil) fresh=\(token?.isFresh ?? false) expires-in=\(expiry) agy=\(agyPath() ?? "not found")"
        ]
    }
}

// MARK: - Shared helpers

enum AIFetchSupport {
    /// Prints per-provider status without any secrets (`MenuTools --ai-limits-diagnose`).
    static func diagnose() async -> [String] {
        var lines = await ClaudeUsageFetcher.diagnostics() + AntigravityUsageFetcher.diagnostics()
        for provider in AIProvider.allCases {
            let usage: AIProviderUsage
            switch provider {
            case .claude: usage = await ClaudeUsageFetcher.fetch()
            case .codex: usage = await CodexUsageFetcher.fetch()
            case .antigravity: usage = await AntigravityUsageFetcher.fetch()
            }
            let windows = usage.windows.map {
                "\($0.label)=\(Int($0.usedFraction * 100))% reset=\(AIResetFormatter.short(until: $0.resetsAt))"
            }
            lines.append("[\(provider.rawValue)] status=\(usage.status) plan=\(usage.plan ?? "-") \(windows.joined(separator: ", "))")
        }
        let cached = AILimitsCache.load()
        for provider in AIProvider.allCases {
            guard let entry = cached[provider] else { continue }
            let blocked = entry.blockedUntil.map { AIResetFormatter.short(until: $0) } ?? "-"
            lines.append(
                "[cache] \(provider.rawValue) windows=\(entry.windows.count) age=\(AIResetFormatter.age(of: entry.fetchedAt) ?? "now") blocked-for=\(blocked)"
            )
        }
        return lines
    }

    /// Runs a tool with explicit arguments (no shell) off the main thread.
    static func run(
        _ executable: String, _ arguments: [String], timeout: TimeInterval = 10, directory: URL? = nil
    ) async -> (output: Data, status: Int32) {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = arguments
                process.currentDirectoryURL = directory
                process.standardInput = FileHandle.nullDevice
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = FileHandle.nullDevice
                do {
                    try process.run()
                } catch {
                    continuation.resume(returning: (Data(), -1))
                    return
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                    if process.isRunning { process.terminate() }
                }
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                continuation.resume(returning: (data, process.terminationStatus))
            }
        }
    }

    /// ISO-8601 with or without (any-length) fractional seconds, or epoch seconds.
    static func parseDate(_ value: Any?) -> Date? {
        if let number = value as? NSNumber { return Date(timeIntervalSince1970: number.doubleValue) }
        guard let string = value as? String, !string.isEmpty else { return nil }
        if let seconds = Double(string) { return Date(timeIntervalSince1970: seconds) }

        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: string) { return date }

        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        if let date = plain.date(from: string) { return date }

        let stripped = string.replacingOccurrences(of: #"\.\d+"#, with: "", options: .regularExpression)
        return plain.date(from: stripped)
    }

    /// `Retry-After` as seconds from now (delta-seconds or HTTP-date); 0 when absent.
    static func retryAfter(_ response: HTTPURLResponse?) -> TimeInterval {
        guard let value = response?.value(forHTTPHeaderField: "Retry-After")?.trimmingCharacters(in: .whitespaces)
        else { return 0 }
        if let seconds = Double(value) { return max(seconds, 0) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter.date(from: value).map { max($0.timeIntervalSinceNow, 0) } ?? 0
    }

    static func describe(_ error: Error) -> String {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet, .networkConnectionLost: return "Offline"
            case .timedOut: return "Timed out"
            default: return "Network error"
            }
        }
        if error is DecodingError { return "Unexpected response" }
        return error.localizedDescription
    }
}
