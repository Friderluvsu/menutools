import SwiftUI

/// Same meaning on every agent card. Finished chats are blue so orange stays "needs you".
enum SessionStatusTone {
    case running, input, idle, ended

    var color: Color {
        switch self {
        case .running: return .green
        case .input: return .orange
        case .idle: return .secondary
        case .ended: return .blue
        }
    }

    var rowFill: Color {
        switch self {
        case .running: return Color.green.opacity(0.12)
        case .input: return Color.orange.opacity(0.12)
        case .idle: return Color.white.opacity(0.03)
        case .ended: return Color.blue.opacity(0.12)
        }
    }

    static func live(needsInput: Bool, isRunning: Bool) -> SessionStatusTone {
        if needsInput { return .input }
        if isRunning { return .running }
        return .idle
    }

    /// List order: needs you, working, unchecked finish, then the quiet rows.
    var rank: Int {
        switch self {
        case .input: 0
        case .running: 1
        case .ended: 2
        case .idle: 3
        }
    }
}

/// Counts shown beside an app icon, and on the collapsed Sessions row. `ended` counts unchecked
/// finishes only; a checked one is quiet and counts as idle.
struct SessionStatusTally: Equatable {
    var running = 0
    var input = 0
    var idle = 0
    var ended = 0

    var isEmpty: Bool { running + input + idle + ended == 0 }

    var spoken: String {
        var parts: [String] = []
        if input > 0 { parts.append("\(input) need input") }
        if running > 0 { parts.append("\(running) running") }
        if idle > 0 { parts.append("\(idle) idle") }
        if ended > 0 { parts.append("\(ended) to check") }
        return parts.joined(separator: ", ")
    }

    func count(_ tone: SessionStatusTone) -> Int {
        switch tone {
        case .running: running
        case .input: input
        case .idle: idle
        case .ended: ended
        }
    }

    mutating func add(_ tone: SessionStatusTone) {
        switch tone {
        case .running: running += 1
        case .input: input += 1
        case .idle: idle += 1
        case .ended: ended += 1
        }
    }

    static func + (lhs: SessionStatusTally, rhs: SessionStatusTally) -> SessionStatusTally {
        SessionStatusTally(
            running: lhs.running + rhs.running,
            input: lhs.input + rhs.input,
            idle: lhs.idle + rhs.idle,
            ended: lhs.ended + rhs.ended
        )
    }

    /// A live session whose last run finished and is unchecked counts as ended (blue), like another
    /// app's unchecked Ended row.
    static func claude(_ sessions: [ClaudeSession], finished: [String: ClaudeFinish] = [:]) -> SessionStatusTally {
        var tally = SessionStatusTally()
        for session in sessions {
            if finished[session.id] != nil, !session.isWorking, !session.needsInput {
                tally.add(.ended)
            } else {
                tally.add(.live(needsInput: session.needsInput, isRunning: session.isWorking))
            }
        }
        return tally
    }

    /// Unchecked ended rows are blue; checked ones are quiet.
    static func ended(unchecked: Int, checked: Int) -> SessionStatusTally {
        SessionStatusTally(idle: checked, ended: unchecked)
    }

    static func cursor(_ sessions: [CursorSession], ended: [CursorEndedSession]) -> SessionStatusTally {
        var tally = SessionStatusTally.ended(
            unchecked: ended.filter { !$0.seen }.count, checked: ended.filter(\.seen).count)
        for session in sessions {
            tally.add(.live(needsInput: session.needsInput, isRunning: session.status == "running"))
        }
        return tally
    }

    static func codex(live: Int, ended: [CodexEndedSession]) -> SessionStatusTally {
        var tally = SessionStatusTally.ended(
            unchecked: ended.filter { !$0.seen }.count, checked: ended.filter(\.seen).count)
        tally.running += live
        return tally
    }

    static func antigravity(_ sessions: [AntigravitySession], ended: [AntigravityEndedSession]) -> SessionStatusTally {
        var tally = SessionStatusTally.ended(
            unchecked: ended.filter { !$0.seen }.count, checked: ended.filter(\.seen).count)
        for session in sessions {
            tally.add(.live(needsInput: session.needsInput, isRunning: session.status == "running"))
        }
        return tally
    }
}

/// Colored dot and count. A zero bucket is omitted, so a quiet card shows one mark.
/// With `onSelect`, each mark is a filter button: the card then lists only that state.
struct SessionStatusMarks: View {
    let tally: SessionStatusTally
    var selected: SessionStatusTone? = nil
    var onSelect: ((SessionStatusTone) -> Void)? = nil

    var body: some View {
        HStack(spacing: onSelect == nil ? 7 : 2) {
            mark(.input, "need input")
            mark(.running, "running")
            mark(.ended, "to check")
            mark(.idle, "idle")
        }
        .accessibilityElement(children: onSelect == nil ? .ignore : .contain)
        .accessibilityLabel(tally.spoken)
    }

    @ViewBuilder
    private func mark(_ tone: SessionStatusTone, _ word: String) -> some View {
        let count = tally.count(tone)
        if count > 0 {
            let label = HStack(spacing: 3) {
                Circle()
                    .fill(tone.color)
                    .frame(width: 6, height: 6)
                Text("\(count)")
                    .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                    .foregroundStyle(tone.color)
            }
            if let onSelect {
                let isOn = selected == tone
                Button {
                    onSelect(tone)
                } label: {
                    label
                        .padding(.horizontal, 4)
                        .frame(height: 16)
                        .background(Capsule().fill(isOn ? tone.color.opacity(0.22) : Color.clear))
                        .overlay(Capsule().strokeBorder(isOn ? tone.color.opacity(0.5) : Color.clear, lineWidth: 0.5))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .suppressesFocusRing()
                .help(isOn ? "Show all" : "Only \(word) (\(count))")
                .accessibilityLabel("\(count) \(word)")
                .accessibilityAddTraits(isOn ? .isSelected : [])
            } else {
                label.help("\(count) \(word)")
            }
        }
    }
}

/// Per card: the state filter picked from its header marks, and whether its quiet rows are open.
/// Shared by the dashboard and the Sessions page; kept while MenuTools runs.
@MainActor
final class SessionListState: ObservableObject {
    @Published private(set) var filters: [SessionCardHeader.Kind: SessionStatusTone] = [:]
    @Published private(set) var quietOpen: Set<SessionCardHeader.Kind> = []

    /// The picked filter, or nil when nothing in the card has that state any more.
    func filter(for kind: SessionCardHeader.Kind, tally: SessionStatusTally) -> SessionStatusTone? {
        guard let tone = filters[kind], tally.count(tone) > 0 else { return nil }
        return tone
    }

    /// The same mark again clears the filter.
    func toggleFilter(_ tone: SessionStatusTone, for kind: SessionCardHeader.Kind, tally: SessionStatusTally) {
        withAnimation(SessionDashboardLayout.detailAnimation) {
            filters[kind] = filter(for: kind, tally: tally) == tone ? nil : tone
        }
    }

    func toggleQuiet(_ kind: SessionCardHeader.Kind) {
        withAnimation(SessionDashboardLayout.detailAnimation) {
            if quietOpen.contains(kind) { quietOpen.remove(kind) } else { quietOpen.insert(kind) }
        }
    }
}

/// A card's rows: what needs you first (input, running, unchecked finish), then one line that folds
/// the quiet rows (idle, checked). A header filter shows one state only, quiet rows included.
struct SessionRowList<Item: Identifiable, Row: View>: View {
    @EnvironmentObject private var state: SessionListState

    let kind: SessionCardHeader.Kind
    let items: [Item]
    let tally: SessionStatusTally
    let tone: (Item) -> SessionStatusTone
    let project: (Item) -> String
    @ViewBuilder let row: (Item) -> Row

    var body: some View {
        let ordered = items.enumerated()
            .sorted { lhs, rhs in
                let left = tone(lhs.element).rank
                let right = tone(rhs.element).rank
                return left == right ? lhs.offset < rhs.offset : left < right
            }
            .map(\.element)
        if let filter = state.filter(for: kind, tally: tally) {
            ForEach(ordered.filter { tone($0) == filter }) { item in
                row(item)
            }
        } else {
            let quiet = ordered.filter { tone($0) == .idle }
            ForEach(ordered.filter { tone($0) != .idle }) { item in
                row(item)
            }
            if !quiet.isEmpty {
                let open = state.quietOpen.contains(kind)
                SessionQuietToggle(count: quiet.count, projects: quiet.map(project), isOpen: open) {
                    state.toggleQuiet(kind)
                }
                if open {
                    ForEach(quiet) { item in
                        row(item)
                    }
                }
            }
        }
    }
}

/// "+5 idle · menutools, translator, …" with a chevron. Stays put while its rows open under it.
private struct SessionQuietToggle: View {
    let count: Int
    let projects: [String]
    let isOpen: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(isOpen ? "\(count) idle" : "+\(count) idle")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .fixedSize()
                if !names.isEmpty {
                    Text("· " + names)
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(isOpen ? 180 : 0))
                    .frame(width: 18)
            }
            .padding(.horizontal, 6)
            .frame(height: 20)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .suppressesFocusRing()
        .hoverHighlight(cornerRadius: 6)
        .help(isOpen ? "Hide idle sessions" : "Show idle sessions")
        .accessibilityLabel(isOpen ? "Hide \(count) idle sessions" : "Show \(count) idle sessions")
    }

    /// Distinct projects in list order.
    private var names: String {
        var seen = Set<String>()
        return projects.filter { !$0.isEmpty && $0 != "—" && seen.insert($0).inserted }.joined(separator: ", ")
    }
}

/// Which session drawer is open. Shared by every card so a second click closes the first.
@MainActor
final class SessionDetailSelection: ObservableObject {
    @Published var openID: String?

    init(openID: String? = nil) {
        self.openID = openID
    }

    func toggle(_ id: String) {
        withAnimation(SessionDashboardLayout.detailAnimation) {
            openID = openID == id ? nil : id
        }
    }
}

struct SessionDetailField: Identifiable, Equatable {
    let label: String
    let value: String
    var mono = false
    /// Paths and ids keep both ends. Prose keeps the start.
    var middle = false
    var id: String { label }
}

struct AgentLiveRow: View {
    let expansionID: String
    let name: String
    let statusTitle: String
    let needsInput: Bool
    let isRunning: Bool
    let project: String
    let uptime: String
    let details: [SessionDetailField]
    let tooltip: String
    var revealHint: String = "Click to show this project"
    /// Claude: the session is still open and its last run finished unchecked ("4m ago"). Shown as a
    /// blue Done row until checked; a checked one is a plain Idle row.
    var done: String? = nil
    /// Tokens so far; the row shows its badge (cost, tokens or context fill) before the uptime.
    var usage: SessionUsage? = nil
    /// Marks the Done row checked without bringing its window forward.
    var onCheck: (() -> Void)? = nil
    let onReveal: () -> Void

    var body: some View {
        if let done, !needsInput, !isRunning {
            AgentSessionRow(
                expansionID: expansionID,
                name: name,
                statusTitle: "Done",
                statusColor: SessionStatusTone.ended.color,
                dotColor: SessionStatusTone.ended.color,
                project: project,
                uptime: done,
                badge: usage?.badge,
                details: details,
                fill: SessionStatusTone.ended.rowFill,
                helpText: tooltip + "\nFinished " + done + "\n" + revealHint,
                onReveal: onReveal,
                onCheck: onCheck
            )
        } else {
            let tone = SessionStatusTone.live(needsInput: needsInput, isRunning: isRunning)
            AgentSessionRow(
                expansionID: expansionID,
                name: name,
                statusTitle: statusTitle,
                statusColor: tone.color,
                dotColor: tone.color,
                project: project,
                uptime: uptime,
                badge: usage?.badge,
                details: details,
                fill: tone.rowFill,
                helpText: tooltip + "\n" + revealHint,
                onReveal: onReveal
            )
        }
    }
}

/// "just now", "4m ago", "2h ago", "1d ago". Shown where a live row shows uptime.
func endedAgo(_ date: Date, now: Date) -> String {
    let whole = Int(max(0, now.timeIntervalSince(date)))
    if whole < 45 { return "just now" }
    if whole < 3_600 { return "\(max(whole / 60, 1))m ago" }
    if whole < 86_400 { return "\(whole / 3_600)h ago" }
    return "\(whole / 86_400)d ago"
}

struct AgentEndedRow: View {
    let expansionID: String
    let name: String
    let project: String
    let details: [SessionDetailField]
    /// Not checked yet: blue, with a ✓. A checked row is grey, quiet, and can be dismissed.
    var unchecked: Bool = false
    /// Same slot as a live row's uptime: "just now", "4m ago".
    var when: String? = nil
    var helpNote: String = "Chat ended. Click to show this project"
    var usage: SessionUsage? = nil
    let onReveal: () -> Void
    let onCheck: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        AgentSessionRow(
            expansionID: expansionID,
            name: name,
            statusTitle: "Ended",
            statusColor: unchecked ? SessionStatusTone.ended.color : Color.secondary,
            dotColor: unchecked ? SessionStatusTone.ended.color : Color.secondary,
            project: project,
            uptime: when,
            badge: usage?.badge,
            details: details,
            fill: unchecked ? SessionStatusTone.ended.rowFill : SessionStatusTone.idle.rowFill,
            helpText: helpNote,
            onReveal: onReveal,
            onCheck: unchecked ? onCheck : nil,
            onDismiss: unchecked ? nil : onDismiss
        )
    }
}

/// Chat name, status and a project chip. The chevron opens the rest; the row click still reveals the app.
private struct AgentSessionRow: View {
    @EnvironmentObject private var selection: SessionDetailSelection

    let expansionID: String
    let name: String
    let statusTitle: String
    let statusColor: Color
    let dotColor: Color
    let project: String
    let uptime: String?
    /// "~$4.12", "18k tok" or "11% ctx", before the uptime.
    var badge: String? = nil
    let details: [SessionDetailField]
    let fill: Color
    let helpText: String
    let onReveal: () -> Void
    var onCheck: (() -> Void)? = nil
    var onDismiss: (() -> Void)?

    private var isOpen: Bool { selection.openID == expansionID }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 2) {
                Button(action: onReveal) {
                    summary
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .suppressesFocusRing()
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(helpText)

                if let onCheck {
                    Button(action: onCheck) {
                        Image(systemName: "checkmark")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(SessionStatusTone.ended.color)
                            .frame(width: 16, height: 16)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .suppressesFocusRing()
                    .help("Mark checked")
                    .accessibilityLabel("Mark checked")
                }

                detailButton

                if let onDismiss {
                    Button(action: onDismiss) {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 16, height: 16)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .suppressesFocusRing()
                    .help("Dismiss")
                }
            }

            SessionDetailDrawer(isOpen: isOpen, fields: details)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(fill, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .hoverHighlight(cornerRadius: 6)
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Circle()
                    .fill(dotColor)
                    .frame(width: 6, height: 6)
                Text(name)
                    .font(.system(size: 11.5, weight: .medium))
                    .lineLimit(1)
                Spacer(minLength: 6)
                Text(statusTitle)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(statusColor)
                    .lineLimit(1)
                    .fixedSize()
            }
            if showsProject || uptime != nil || badge != nil {
                HStack(spacing: 6) {
                    if showsProject {
                        projectChip
                            .layoutPriority(-1)
                    }
                    Spacer(minLength: 0)
                    if let badge {
                        Text(badge)
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .fixedSize()
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.primary.opacity(0.07), in: Capsule())
                    }
                    if let uptime, !uptime.isEmpty {
                        Text(uptime)
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .fixedSize()
                    }
                }
            }
        }
    }

    private var showsProject: Bool {
        !project.isEmpty && project != "—"
    }

    private var projectChip: some View {
        HStack(spacing: 3) {
            Image(systemName: "folder.fill")
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .fixedSize()
            Text(project)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(minWidth: 0, alignment: .leading)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 1.5)
        .background(Color.primary.opacity(0.12), in: Capsule())
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.14), lineWidth: 0.5))
    }

    private var detailButton: some View {
        Button {
            selection.toggle(expansionID)
        } label: {
            Image(systemName: "chevron.down")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(isOpen ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                .rotationEffect(.degrees(isOpen ? 180 : 0))
                .frame(width: 18, height: 22)
                .contentShape(Rectangle())
                .background {
                    Circle()
                        .fill(Color.primary.opacity(isOpen ? 0.14 : 0))
                        .frame(width: 16, height: 16)
                }
        }
        .buttonStyle(.plain)
        .suppressesFocusRing()
        .animation(SessionDashboardLayout.detailAnimation, value: isOpen)
        .help(isOpen ? "Hide details" : "Details")
        .accessibilityLabel(isOpen ? "Hide details" : "Show details")
    }
}

/// Grows from the top. The list is measured at full height so the clip can ease open.
private struct SessionDetailDrawer: View {
    let isOpen: Bool
    let fields: [SessionDetailField]
    @State private var fullHeight: CGFloat = 0

    var body: some View {
        Color.clear
            .frame(maxWidth: .infinity)
            .frame(height: isOpen ? fullHeight : 0)
            .overlay(alignment: .top) {
                detailList
                    .fixedSize(horizontal: false, vertical: true)
                    .opacity(isOpen ? 1 : 0)
                    .allowsHitTesting(isOpen)
            }
            .background {
                // Measured outside the clipped frame, so the open animation already knows its height.
                detailList
                    .fixedSize(horizontal: false, vertical: true)
                    .hidden()
                    .accessibilityHidden(true)
                    .background {
                        GeometryReader { proxy in
                            Color.clear.preference(key: DrawerHeightKey.self, value: proxy.size.height)
                        }
                    }
            }
            .clipped()
            .onPreferenceChange(DrawerHeightKey.self) { height in
                guard height > 1, abs(height - fullHeight) > 0.5 else { return }
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) { fullHeight = height }
            }
            .animation(SessionDashboardLayout.detailAnimation, value: isOpen)
            .accessibilityHidden(!isOpen)
    }

    private var detailList: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(fields) { field in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(field.label)
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .frame(width: 58, alignment: .leading)
                    Text(field.value)
                        .font(.system(size: 10.5, weight: .medium, design: field.mono ? .monospaced : .default))
                        .foregroundStyle(.primary.opacity(0.88))
                        .lineLimit(2)
                        .truncationMode(field.middle ? .middle : .tail)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
        )
        .padding(.top, 4)
    }
}

private struct DrawerHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

enum SessionDetailFields {
    static func claude(_ session: ClaudeSession, usage: SessionUsage? = nil) -> [SessionDetailField] {
        collect(
            [
                field("Name", session.name),
                field("Project", session.project),
            ] + usageFields(usage) + [
                field("Path", session.shortCwd, mono: true, middle: true),
                field("Id", session.sessionId, mono: true, middle: true),
                field("Pid", "\(session.pid)", mono: true),
                field("Kind", titled(session.kind)),
                field("Entry", entryLabel(session.entrypoint)),
                field("Version", session.version ?? ""),
            ])
    }

    static func cursor(_ session: CursorSession) -> [SessionDetailField] {
        var fields = [
            field("Name", session.name),
            field("Project", session.project),
        ]
        fields += usageFields(session.usage)
        fields += [
            field("Path", session.shortCwd, mono: true, middle: true),
            field("Id", session.id, mono: true, middle: true),
            field("Mode", session.modeLabel),
            field("Activity", session.subtitle),
        ]
        if session.filesChanged > 0 {
            let noun = session.filesChanged == 1 ? "file" : "files"
            fields.append(field("Files", "\(session.filesChanged) \(noun)"))
        }
        return collect(fields)
    }

    /// Tokens, cost, model and context rows. Empty when the agent logs none.
    private static func usageFields(_ usage: SessionUsage?) -> [SessionDetailField?] {
        guard let usage else { return [] }
        return usage.detailLines.map { field($0.label, $0.value) }
    }

    static func cursorEnded(_ item: CursorEndedSession) -> [SessionDetailField] {
        collect([
            field("Name", item.name),
            field("Project", item.project),
            field("Path", item.shortCwd, mono: true, middle: true),
            field("Id", item.id, mono: true, middle: true),
            field("Activity", item.subtitle),
            field("When", item.endedAt.formatted(.relative(presentation: .named))),
        ])
    }

    static func codex(_ session: CodexSession) -> [SessionDetailField] {
        collect(
            [
                field("Name", session.name),
                field("Project", session.project),
            ] + usageFields(session.usage) + [
                field("Path", session.shortCwd, mono: true, middle: true),
                field("Pid", "\(session.pid)", mono: true),
                field("Kind", "CLI"),
                field("Preview", session.subtitle),
            ])
    }

    static func codexEnded(_ item: CodexEndedSession) -> [SessionDetailField] {
        collect(
            [
                field("Name", item.name),
                field("Project", item.project),
            ] + usageFields(item.usage) + [
                field("Path", item.shortCwd, mono: true, middle: true),
                field("Id", item.id, mono: true),
                field("Kind", "CLI"),
                field("Preview", item.subtitle),
                field("When", item.endedAt.formatted(.relative(presentation: .named))),
            ])
    }

    static func antigravity(_ session: AntigravitySession) -> [SessionDetailField] {
        collect([
            field("Name", session.name),
            field("Project", session.project),
            field("Path", session.shortCwd, mono: true, middle: true),
            field("Id", session.id, mono: true, middle: true),
            field("Preview", session.subtitle),
        ])
    }

    static func antigravityEnded(_ item: AntigravityEndedSession) -> [SessionDetailField] {
        collect([
            field("Name", item.name),
            field("Project", item.project),
            field("Path", item.shortCwd, mono: true, middle: true),
            field("Id", item.id, mono: true, middle: true),
            field("Preview", item.subtitle),
            field("When", item.endedAt.formatted(.relative(presentation: .named))),
        ])
    }

    private static func field(
        _ label: String, _ value: String, mono: Bool = false, middle: Bool = false
    ) -> SessionDetailField? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "—" else { return nil }
        return SessionDetailField(label: label, value: trimmed, mono: mono, middle: middle)
    }

    private static func collect(_ fields: [SessionDetailField?]) -> [SessionDetailField] {
        fields.compactMap { $0 }
    }

    private static func titled(_ raw: String) -> String {
        guard let first = raw.first else { return raw }
        return first.uppercased() + raw.dropFirst()
    }

    private static func entryLabel(_ raw: String) -> String {
        if raw.isEmpty { return "" }
        return raw.lowercased() == "cli" ? "CLI" : titled(raw)
    }
}
