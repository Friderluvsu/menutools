import AppKit
import Foundation
import SwiftUI

/// Collects subscription usage for Claude Code, Codex, Antigravity and Cursor.
/// Everything is read locally (CLI credentials / local session) — no extra login.
@MainActor
final class AILimitsManager: ObservableObject {
    @Published private(set) var usage: [AIProvider: AIProviderUsage] = [:]
    @Published private(set) var isRefreshing = false
    @Published private(set) var lastRefresh: Date?
    @Published private(set) var enabledProviders: Set<AIProvider>

    private let previewMode: Bool
    private var timer: Timer?
    private var cache: [AIProvider: AILimitsCache.Entry] = [:]
    private var lastAttempt: [AIProvider: Date] = [:]
    /// Soft back-off after errors: skipped by background polls, ignored by the refresh button.
    private var retryNotBefore: [AIProvider: Date] = [:]
    /// Hard back-off after HTTP 429 (honours `Retry-After`): never bypassed, persisted across launches.
    private var blockedUntil: [AIProvider: Date] = [:]
    private var failures: [AIProvider: Int] = [:]

    private static let staleInterval: TimeInterval = 120
    private static let backgroundInterval: TimeInterval = 300
    /// Even the refresh button never hits the same provider more often than this.
    private static let minimumGap: TimeInterval = 10
    /// Data older than this (e.g. Codex session-log fallback) is shown as cached.
    private static let staleAfter: TimeInterval = 900

    init(previewMode: Bool = false) {
        self.previewMode = previewMode
        enabledProviders = Set(AIProvider.allCases.filter(\.isEnabled))
        if previewMode {
            usage = Self.sampleUsage
            return
        }

        cache = AILimitsCache.load()
        let now = Date.now
        for (provider, entry) in cache {
            if let until = entry.blockedUntil, until > now { blockedUntil[provider] = until }
            guard !entry.windows.isEmpty else { continue }
            usage[provider] = AIProviderUsage(
                provider: provider, plan: entry.plan, windows: entry.windows, status: .ok,
                fetchedAt: entry.fetchedAt, isStale: true)
        }
        lastRefresh = usage.values.map(\.fetchedAt).max()
    }

    var visibleProviders: [AIProvider] {
        AIProvider.allCases.filter { enabledProviders.contains($0) }
    }

    func setEnabled(_ provider: AIProvider, _ enabled: Bool) {
        provider.isEnabled = enabled
        if enabled {
            enabledProviders.insert(provider)
            Task { await refresh(force: true) }
        } else {
            enabledProviders.remove(provider)
        }
    }

    /// Asks the provider to renew its own login in Terminal. MenuTools never writes a provider token.
    func openLoginTerminal(for provider: AIProvider) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("MenuTools-\(provider.rawValue)-login.command")
        let script = "#!/bin/zsh\nclear\n\(provider.loginCommand)\n"
        do {
            try script.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        } catch {
            return
        }
        NSWorkspace.shared.open(url)
        // Next panel open re-checks right away instead of waiting out the error back-off.
        lastAttempt[provider] = nil
        retryNotBefore[provider] = nil
    }

    /// Called when the panel opens: refresh if stale and keep refreshing while visible.
    func startMonitoring() {
        guard !previewMode else { return }
        Task { await refresh(force: false) }
        timer?.invalidate()
        let timer = Timer.scheduledTimer(withTimeInterval: Self.backgroundInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refresh(force: false) }
        }
        timer.tolerance = 30
        self.timer = timer
    }

    func stopMonitoring() {
        timer?.invalidate()
        timer = nil
    }

    /// `force` = user pressed refresh: skips the staleness check and soft back-off, never a 429 block.
    func refresh(force: Bool) async {
        guard !previewMode, !isRefreshing else { return }
        let now = Date.now

        var due: [AIProvider] = []
        for provider in visibleProviders {
            if let until = blockedUntil[provider], until > now {
                if usage[provider] == nil {
                    usage[provider] = .failed(
                        provider, "Rate limited — retry in \(AIResetFormatter.short(until: until, now: now))")
                }
                continue
            }
            if let last = lastAttempt[provider],
                now.timeIntervalSince(last) < (force ? Self.minimumGap : Self.staleInterval)
            {
                continue
            }
            if !force, let retry = retryNotBefore[provider], retry > now { continue }
            due.append(provider)
        }
        guard !due.isEmpty else { return }

        isRefreshing = true
        defer { isRefreshing = false }

        for provider in due { lastAttempt[provider] = now }
        await withTaskGroup(of: AIProviderUsage.self) { group in
            for provider in due {
                group.addTask { await Self.fetch(provider) }
            }
            for await result in group {
                apply(result)
            }
        }
    }

    // MARK: Result handling

    private func apply(_ result: AIProviderUsage) {
        let provider = result.provider
        let now = Date.now
        updateBackoff(for: result, now: now)

        let previous = cache[provider]
        let previousHasWindows = previous?.windows.isEmpty == false
        let hasData = result.status == .ok && !(result.windows.isEmpty && previousHasWindows)
        let isNewer = previous.map { result.fetchedAt >= $0.fetchedAt } ?? true

        if hasData, isNewer || !previousHasWindows {
            var fresh = result
            fresh.plan = fresh.plan ?? previous?.plan
            fresh.retryAfter = nil
            if now.timeIntervalSince(fresh.fetchedAt) > Self.staleAfter { fresh.isStale = true }
            usage[provider] = fresh
            cache[provider] = AILimitsCache.Entry(
                plan: fresh.plan, windows: fresh.windows, fetchedAt: fresh.fetchedAt, blockedUntil: nil)
            if !fresh.isStale { lastRefresh = now }
        } else if let previous, previousHasWindows {
            // Fetch failed (expired login, offline, rate limit…): keep the last good numbers, marked stale.
            usage[provider] = AIProviderUsage(
                provider: provider, plan: previous.plan, windows: previous.windows, status: .ok,
                fetchedAt: previous.fetchedAt, isStale: true, note: Self.reason(for: result))
        } else {
            usage[provider] = result
        }
        persist(now: now)
    }

    private func updateBackoff(for result: AIProviderUsage, now: Date) {
        let provider = result.provider
        if let retryAfter = result.retryAfter {
            let count = (failures[provider] ?? 0) + 1
            failures[provider] = count
            let delay =
                retryAfter > 0
                ? min(max(retryAfter, 60), 3600)
                : min(300 * pow(2, Double(min(count - 1, 4))), 3600)
            blockedUntil[provider] = now.addingTimeInterval(delay)
        } else if case .failed = result.status {
            let count = (failures[provider] ?? 0) + 1
            failures[provider] = count
            retryNotBefore[provider] = now.addingTimeInterval(min(60 * pow(2, Double(min(count - 1, 4))), 900))
            blockedUntil[provider] = nil
        } else {
            failures[provider] = 0
            retryNotBefore[provider] = nil
            blockedUntil[provider] = nil
        }
    }

    private static func reason(for result: AIProviderUsage) -> String? {
        switch result.status {
        case .failed(let message), .notConnected(let message): return message
        case .ok: return nil
        }
    }

    private func persist(now: Date) {
        var entries = cache
        for provider in AIProvider.allCases {
            let until = blockedUntil[provider].flatMap { $0 > now ? $0 : nil }
            if var entry = entries[provider] {
                entry.blockedUntil = until
                entries[provider] = entry
            } else if let until {
                entries[provider] = AILimitsCache.Entry(
                    plan: nil, windows: [], fetchedAt: Date(timeIntervalSince1970: 0), blockedUntil: until)
            }
        }
        AILimitsCache.save(entries)
    }

    nonisolated private static func fetch(_ provider: AIProvider) async -> AIProviderUsage {
        switch provider {
        case .claude: return await ClaudeUsageFetcher.fetch()
        case .codex: return await CodexUsageFetcher.fetch()
        case .antigravity: return await AntigravityUsageFetcher.fetch()
        case .cursor: return await CursorUsageFetcher.fetch()
        }
    }

    private static var sampleUsage: [AIProvider: AIProviderUsage] {
        let now = Date.now
        return [
            // Expired login with nothing cached (the common Claude Code case): message plus Run button.
            .claude: .failed(.claude, "Login expired — run claude"),
            .codex: AIProviderUsage(
                provider: .codex, plan: "PLUS",
                windows: [
                    AIUsageWindow(label: "5h", usedFraction: 0.12, resetsAt: now.addingTimeInterval(4 * 3600)),
                    AIUsageWindow(label: "Week", usedFraction: 0.91, resetsAt: now.addingTimeInterval(86400 + 7200)),
                ],
                // Shows the stale state in previews: last known numbers plus the reason.
                status: .ok, fetchedAt: now.addingTimeInterval(-2 * 3600), isStale: true,
                note: "Login expired — run codex"),
            .antigravity: AIProviderUsage(
                provider: .antigravity, plan: "PRO",
                windows: [
                    AIUsageWindow(label: "Gemini Pro", usedFraction: 0.3, resetsAt: now.addingTimeInterval(3 * 3600)),
                    AIUsageWindow(label: "Claude", usedFraction: 0.75, resetsAt: now.addingTimeInterval(5 * 3600)),
                ],
                status: .ok, fetchedAt: now),
            .cursor: AIProviderUsage(
                provider: .cursor, plan: "PRO",
                windows: [
                    AIUsageWindow(label: "Included", usedFraction: 0.42, resetsAt: now.addingTimeInterval(12 * 86400)),
                ],
                status: .ok, fetchedAt: now),
        ]
    }
}
