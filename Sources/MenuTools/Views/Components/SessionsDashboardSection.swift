import AppKit
import SwiftUI

/// How many live + ended rows the dashboard will show inline before collapsing to a Sessions page.
enum SessionDashboardLayout {
    static let maxInlineRows = 3
    static let pageAnimation = Animation.easeOut(duration: 0.2)
    /// Height, fade and chevron for a session's details drawer. One drawer is open at a time.
    static let detailAnimation = Animation.smooth(duration: 0.3, extraBounce: 0)
    /// Filter bar, including its 2pt inset. The list scrolls in the room left under it.
    static let filterBarHeight: CGFloat = 28

    /// Header 34, divider 1, page padding, filter bar, and the gap before the list.
    /// Matches `PanelHeader` and the padding around `SessionsPage`.
    static var sessionsListChrome: CGFloat {
        34 + 1 + MacToolsTheme.outerPadding * 2 + filterBarHeight + MacToolsTheme.sectionSpacing
    }

    /// Tallest the session list can be before the panel would pass the menu-bar screen.
    /// A few points of slack keep the scroll view inside the window cap in `AppDelegate`.
    static var maxSessionListHeight: CGFloat {
        let screen =
            NSApp.keyWindow?.screen
            ?? NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) }
            ?? NSScreen.main
            ?? NSScreen.screens.first
        let panelCap = (screen?.visibleFrame.height ?? 900) - 8
        return max(160, panelCap - sessionsListChrome - 4)
    }
}

struct SessionPageHeightKey: PreferenceKey {
    static var defaultValue: [String: CGFloat] = [:]

    static func reduce(value: inout [String: CGFloat], nextValue: () -> [String: CGFloat]) {
        value.merge(nextValue(), uniquingKeysWith: { max($0, $1) })
    }
}

extension View {
    func reportsSessionPageHeight(_ name: String) -> some View {
        background(
            GeometryReader { proxy in
                Color.clear.preference(key: SessionPageHeightKey.self, value: [name: proxy.size.height])
            }
        )
    }
}

/// Kept so a future stack reveal can opt in. Page changes fade only; rows do not move.
struct SessionStackReveal: ViewModifier {
    let index: Int
    let revealed: Bool?

    func body(content: Content) -> some View {
        content
    }
}

extension View {
    func sessionStackReveal(index: Int, revealed: Bool?, base: Int = 0) -> some View {
        modifier(SessionStackReveal(index: base + index, revealed: revealed))
    }
}

/// Cluster of session cards. Observes the four session managers only (not AppState),
/// so a CPU tick never re-renders this section.
struct DashboardSessionsSection: View {
    @ObservedObject var claude: ClaudeSessionsManager
    @ObservedObject var cursor: CursorSessionsManager
    @ObservedObject var codex: CodexSessionsManager
    @ObservedObject var antigravity: AntigravitySessionsManager
    let openSessions: () -> Void

    var body: some View {
        if counts.total == 0 {
            EmptyView()
        } else if counts.total > SessionDashboardLayout.maxInlineRows {
            SessionsSummaryCard(counts: counts, tally: tally, openSessions: openSessions)
        } else {
            VStack(spacing: MacToolsTheme.sectionSpacing) {
                if counts.claude > 0 {
                    ClaudeSessionsCard(manager: claude)
                }
                if counts.cursor > 0 {
                    CursorSessionsCard(manager: cursor)
                }
                if counts.codex > 0 {
                    CodexSessionsCard(manager: codex)
                }
                if counts.antigravity > 0 {
                    AntigravitySessionsCard(manager: antigravity)
                }
            }
        }
    }

    private var counts: SessionDashboardCounts {
        SessionDashboardCounts(
            claude: claude.sessions.count,
            cursor: cursor.sessions.count + cursor.ended.count,
            codex: codex.sessions.count + codex.ended.count,
            antigravity: antigravity.sessions.count + antigravity.ended.count)
    }

    private var tally: SessionStatusTally {
        SessionStatusTally.claude(claude.sessions)
            + .cursor(cursor.sessions, ended: cursor.ended.count)
            + .codex(live: codex.sessions.count, ended: codex.ended.count)
            + .antigravity(antigravity.sessions, ended: antigravity.ended.count)
    }
}

/// Which provider the Sessions page is showing. Empty providers are left off the bar.
private enum SessionProviderFilter: String, CaseIterable, Identifiable {
    case all
    case claude
    case cursor
    case codex
    case antigravity

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: "All"
        case .claude: "Claude"
        case .cursor: "Cursor"
        case .codex: "Codex"
        case .antigravity: "Antigravity"
        }
    }

    var help: String {
        switch self {
        case .all: "All sessions"
        case .claude: "Claude sessions"
        case .cursor: "Cursor sessions"
        case .codex: "Codex sessions"
        case .antigravity: "Antigravity sessions"
        }
    }
}

private struct SessionListHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// Full lists, grouped by app. A filter stays pinned; the list scrolls once it outgrows the screen.
struct SessionsPage: View {
    @ObservedObject var claude: ClaudeSessionsManager
    @ObservedObject var cursor: CursorSessionsManager
    @ObservedObject var codex: CodexSessionsManager
    @ObservedObject var antigravity: AntigravitySessionsManager
    var stackRevealed: Bool
    var onEmpty: () -> Void

    @State private var filter: SessionProviderFilter = .all
    /// Natural height of the cards. Zero until the first layout.
    @State private var listHeight: CGFloat = 0

    var body: some View {
        VStack(spacing: MacToolsTheme.sectionSpacing) {
            SessionFilterBar(filters: filters, selection: $filter)

            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    sessionList
                        .fixedSize(horizontal: false, vertical: true)
                        .background {
                            GeometryReader { geo in
                                Color.clear.preference(key: SessionListHeightKey.self, value: geo.size.height)
                            }
                        }
                }
                .frame(height: listViewport)
                .scrollIndicators(needsScroll ? .visible : .hidden, axes: .vertical)
                .scrollDisabled(!needsScroll)
                .onChange(of: filter) { _, _ in
                    DispatchQueue.main.async {
                        proxy.scrollTo("sessions-top", anchor: .top)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
        .onPreferenceChange(SessionListHeightKey.self) { height in
            guard height > 1, abs(height - listHeight) > 0.5 else { return }
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { listHeight = height }
        }
        .onChange(of: rosterToken) { _, _ in
            if filter != .all, !includes(filter) { filter = .all }
        }
        .onChange(of: isEmpty) { _, empty in
            if empty { onEmpty() }
        }
    }

    /// Unconstrained until measured, then the smaller of the cards and the screen.
    /// The first pass reports the real card height; the next pass caps it.
    private var listViewport: CGFloat? {
        guard listHeight > 1 else { return nil }
        return min(listHeight, SessionDashboardLayout.maxSessionListHeight)
    }

    private var needsScroll: Bool {
        listHeight > SessionDashboardLayout.maxSessionListHeight + 0.5
    }

    private var sessionList: some View {
        VStack(spacing: MacToolsTheme.sectionSpacing) {
            Color.clear.frame(height: 1).id("sessions-top")
            if shows(.claude) {
                ClaudeSessionsCard(
                    manager: claude, stackRevealed: stackRevealed, stackIndexBase: claudeBase)
            }
            if shows(.cursor) {
                CursorSessionsCard(
                    manager: cursor, stackRevealed: stackRevealed, stackIndexBase: cursorBase)
            }
            if shows(.codex) {
                CodexSessionsCard(
                    manager: codex, stackRevealed: stackRevealed, stackIndexBase: codexBase)
            }
            if shows(.antigravity) {
                AntigravitySessionsCard(
                    manager: antigravity, stackRevealed: stackRevealed, stackIndexBase: antigravityBase)
            }
        }
        .padding(.vertical, 1)
    }

    private var filters: [SessionProviderFilter] {
        var items: [SessionProviderFilter] = [.all]
        for provider in SessionProviderFilter.allCases where provider != .all && includes(provider) {
            items.append(provider)
        }
        return items
    }

    private func shows(_ provider: SessionProviderFilter) -> Bool {
        guard includes(provider) else { return false }
        return filter == .all || filter == provider
    }

    private func includes(_ provider: SessionProviderFilter) -> Bool {
        switch provider {
        case .all:
            !isEmpty
        case .claude:
            !claude.sessions.isEmpty
        case .cursor:
            !cursor.sessions.isEmpty || !cursor.ended.isEmpty
        case .codex:
            !codex.sessions.isEmpty || !codex.ended.isEmpty
        case .antigravity:
            !antigravity.sessions.isEmpty || !antigravity.ended.isEmpty
        }
    }

    private var claudeBase: Int { 0 }
    private var cursorBase: Int { shows(.claude) ? 1 + claude.sessions.count : 0 }
    private var codexBase: Int {
        cursorBase + (shows(.cursor) ? 1 + cursor.sessions.count + cursor.ended.count : 0)
    }
    private var antigravityBase: Int {
        codexBase + (shows(.codex) ? 1 + codex.sessions.count + codex.ended.count : 0)
    }

    private var isEmpty: Bool {
        claude.sessions.isEmpty
            && cursor.sessions.isEmpty && cursor.ended.isEmpty
            && codex.sessions.isEmpty && codex.ended.isEmpty
            && antigravity.sessions.isEmpty && antigravity.ended.isEmpty
    }

    private var rosterToken: String {
        "\(claude.sessions.count) \(cursor.sessions.count) \(cursor.ended.count) \(codex.sessions.count) \(codex.ended.count) \(antigravity.sessions.count) \(antigravity.ended.count)"
    }
}

/// Equal-width provider tabs. The selected one filters the list under it.
private struct SessionFilterBar: View {
    let filters: [SessionProviderFilter]
    @Binding var selection: SessionProviderFilter

    var body: some View {
        HStack(spacing: 2) {
            ForEach(filters) { filter in
                let selected = selection == filter
                Button {
                    selection = filter
                } label: {
                    Text(filter.title)
                        .font(.system(size: 11, weight: selected ? .semibold : .medium))
                        .foregroundStyle(selected ? Color.primary : Color.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .frame(maxWidth: .infinity)
                        .frame(height: 24)
                        .background {
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(selected ? Color.accentColor.opacity(0.22) : Color.clear)
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity)
                .suppressesFocusRing()
                .help(filter.help)
                .accessibilityLabel(filter.help)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(2)
        .frame(height: SessionDashboardLayout.filterBarHeight)
        .background(MacToolsTheme.controlBackground, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(MacToolsTheme.borderColor, lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Session filters")
    }
}

private struct SessionDashboardCounts {
    let claude: Int
    let cursor: Int
    let codex: Int
    let antigravity: Int

    var total: Int { claude + cursor + codex + antigravity }

    var summaryLine: String {
        var parts: [String] = []
        if claude > 0 { parts.append("Claude \(claude)") }
        if cursor > 0 { parts.append("Cursor \(cursor)") }
        if codex > 0 { parts.append("Codex \(codex)") }
        if antigravity > 0 { parts.append("Antigravity \(antigravity)") }
        return parts.joined(separator: " · ")
    }
}

private struct SessionsSummaryCard: View {
    let counts: SessionDashboardCounts
    let tally: SessionStatusTally
    let openSessions: () -> Void

    var body: some View {
        Button(action: openSessions) {
            MacToolsCard(padding: 7) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Label("Sessions", systemImage: "rectangle.stack")
                            .font(.system(size: 10.5, weight: .semibold))
                        Spacer(minLength: 6)
                        SessionStatusMarks(tally: tally)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .frame(height: 16)

                    Text(counts.summaryLine)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, minHeight: 20, alignment: .leading)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .suppressesFocusRing()
        .hoverHighlight(cornerRadius: MacToolsTheme.cornerRadius)
        .help(tally.spoken.isEmpty ? "Show all sessions" : "Show all sessions. \(tally.spoken)")
    }
}
