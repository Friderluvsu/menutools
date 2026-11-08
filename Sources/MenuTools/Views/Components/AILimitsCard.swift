import SwiftUI

/// Compact AI limits: one ~26pt row per provider with its two most constrained windows.
struct AILimitsCard: View {
    @ObservedObject var manager: AILimitsManager

    var body: some View {
        MacToolsCard(padding: 7) {
            // One timeline for the whole card: rollover, reset countdowns and "cached Xh ago" every 30s.
            TimelineView(.periodic(from: .now, by: 30)) { context in
                VStack(alignment: .leading, spacing: 4) {
                    header(now: context.date)

                    if manager.visibleProviders.isEmpty {
                        Text("All hidden in Settings")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, minHeight: 20, alignment: .leading)
                    } else {
                        ForEach(manager.visibleProviders) { provider in
                            AIProviderRow(
                                provider: provider,
                                usage: manager.usage[provider]?.rolledOver(now: context.date),
                                now: context.date,
                                onLogin: { manager.openLoginTerminal(for: provider) })
                        }
                    }
                }
            }
        }
    }

    private func header(now: Date) -> some View {
        HStack(spacing: 6) {
            Label("AI Limits", systemImage: "sparkles")
                .font(.system(size: 10.5, weight: .semibold))
            Spacer()
            if let lastRefresh = manager.lastRefresh {
                Text(AIResetFormatter.age(of: lastRefresh, now: now) ?? "just now")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }
            Button {
                Task { await manager.refresh(force: true) }
            } label: {
                Group {
                    if manager.isRefreshing {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 10.5))
                    }
                }
                .frame(width: 16, height: 16)
                .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .suppressesFocusRing()
            .disabled(manager.isRefreshing)
            .help("Refresh")
        }
        .frame(height: 16)
    }
}

private extension AIProvider {
    var shortName: String {
        switch self {
        case .claude: return "Claude"
        case .codex: return "Codex"
        case .antigravity: return "Antigravity"
        case .cursor: return "Cursor"
        }
    }
}

private struct AIProviderRow: View {
    @Environment(\.appTheme) private var theme
    let provider: AIProvider
    let usage: AIProviderUsage?
    let now: Date
    let onLogin: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(provider.shortName)
                        .font(.system(size: 11.5, weight: .medium))
                        .lineLimit(1)
                    subtitle
                }
                .frame(width: 76, alignment: .leading)

                content
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            // Old numbers after a failed fetch: say why, so they are never read as fresh.
            if let usage, usage.status == .ok, usage.isStale, let note = usage.note {
                HStack(spacing: 6) {
                    Text(note)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if Self.needsLogin(note) {
                        Spacer(minLength: 4)
                        loginButton
                    }
                }
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .frame(maxWidth: .infinity, minHeight: 30)
        .background(theme.tileFill, in: RoundedRectangle(cornerRadius: theme.radius(6)))
        .help(tooltip)
    }

    @ViewBuilder
    private var subtitle: some View {
        if let usage, usage.status == .ok, usage.isStale {
            Text(usage.staleText(now: now))
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
        } else if let plan = usage?.plan, !plan.isEmpty {
            Text(plan)
                .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch usage?.status {
        case nil:
            ProgressView().controlSize(.mini)
        case .ok:
            if let usage, !usage.windows.isEmpty {
                HStack(spacing: 8) {
                    ForEach(Self.topWindows(usage.windows)) { window in
                        AIWindowCell(window: window, now: now)
                    }
                }
                .opacity(usage.isStale ? 0.55 : 1)
            } else {
                statusText("No limits", color: .secondary)
            }
        case .notConnected(let hint):
            HStack(spacing: 6) {
                statusText(hint.replacingOccurrences(of: "`", with: ""), color: .secondary)
                if provider != .antigravity {
                    Spacer(minLength: 4)
                    loginButton
                }
            }
        case .failed(let message):
            HStack(spacing: 6) {
                statusText(message, color: .orange)
                if Self.needsLogin(message) {
                    Spacer(minLength: 4)
                    loginButton
                }
            }
        }
    }

    /// One tap so the provider renews its own login: Terminal for the CLIs, the app itself for Cursor.
    private var loginButton: some View {
        Button(action: onLogin) {
            Label(
                provider.renewsInTerminal ? "Run" : "Open",
                systemImage: provider.renewsInTerminal ? "terminal" : "arrow.up.forward.app"
            )
            .font(.system(size: 10.5, weight: .medium))
        }
        .buttonStyle(.bordered)
        .suppressesFocusRing()
        .controlSize(.small)
        .help(
            provider.renewsInTerminal
                ? "Run \(provider.loginCommand) in Terminal"
                : "Open Cursor"
        )
    }

    private static func needsLogin(_ message: String) -> Bool {
        message.hasPrefix("Login expired")
    }

    private func statusText(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(color)
            .lineLimit(1)
            .truncationMode(.tail)
    }

    /// The two most constrained windows, kept in their original order.
    static func topWindows(_ windows: [AIUsageWindow]) -> [AIUsageWindow] {
        guard windows.count > 2 else { return windows }
        return windows.enumerated()
            .sorted {
                $0.element.usedFraction != $1.element.usedFraction
                    ? $0.element.usedFraction > $1.element.usedFraction
                    : $0.offset < $1.offset
            }
            .prefix(2)
            .sorted { $0.offset < $1.offset }
            .map(\.element)
    }

    /// Full detail on hover: plan, every window and why data is cached.
    private var tooltip: String {
        guard let usage else { return provider.displayName }
        var lines = [provider.displayName + (usage.plan.map { " · \($0)" } ?? "")]
        for window in usage.windows {
            let percent = Int((window.usedFraction * 100).rounded())
            lines.append("\(window.label) \(percent)% · \(AIResetFormatter.short(until: window.resetsAt, now: now))")
        }
        switch usage.status {
        case .failed(let message): lines.append(message)
        case .notConnected(let hint): lines.append(hint.replacingOccurrences(of: "`", with: ""))
        case .ok: break
        }
        if usage.isStale { lines.append(usage.note ?? "Showing last known limits") }
        return lines.joined(separator: "\n")
    }
}

private struct AIWindowCell: View {
    let window: AIUsageWindow
    let now: Date

    var body: some View {
        VStack(spacing: 3) {
            HStack(spacing: 3) {
                Text(window.label)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 2)
                Text("\(Int((window.usedFraction * 100).rounded()))%")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(window.usedFraction >= 0.75 ? barColor : .primary)
            }
            HStack(spacing: 4) {
                MiniBar(fraction: window.usedFraction, color: barColor, height: 2.5)
                Text(AIResetFormatter.short(until: window.resetsAt, now: now))
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize()
            }
        }
        .frame(maxWidth: .infinity)
    }

    /// Neutral by default; only highlights when a limit is close.
    private var barColor: Color {
        switch window.usedFraction {
        case 0.9...: return .red
        case 0.75...: return .orange
        default: return Color.primary.opacity(0.45)
        }
    }
}
