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
}

/// Counts shown beside an app icon, and on the collapsed Sessions row.
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
        if ended > 0 { parts.append("\(ended) ended") }
        return parts.joined(separator: ", ")
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

    /// A live session whose last run finished counts as ended (blue), like another app's Ended row.
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

    static func cursor(_ sessions: [CursorSession], ended: Int) -> SessionStatusTally {
        var tally = SessionStatusTally(ended: ended)
        for session in sessions {
            tally.add(.live(needsInput: session.needsInput, isRunning: session.status == "running"))
        }
        return tally
    }

    static func codex(live: Int, ended: Int) -> SessionStatusTally {
        SessionStatusTally(running: live, ended: ended)
    }

    static func antigravity(_ sessions: [AntigravitySession], ended: Int) -> SessionStatusTally {
        var tally = SessionStatusTally(ended: ended)
        for session in sessions {
            tally.add(.live(needsInput: session.needsInput, isRunning: session.status == "running"))
        }
        return tally
    }
}

/// Colored dot and count. A zero bucket is omitted, so a quiet card shows one mark.
struct SessionStatusMarks: View {
    let tally: SessionStatusTally

    var body: some View {
        HStack(spacing: 7) {
            mark(.input, tally.input, "need input")
            mark(.running, tally.running, "running")
            mark(.idle, tally.idle, "idle")
            mark(.ended, tally.ended, "ended")
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(tally.spoken)
    }

    @ViewBuilder
    private func mark(_ tone: SessionStatusTone, _ count: Int, _ word: String) -> some View {
        if count > 0 {
            HStack(spacing: 3) {
                Circle()
                    .fill(tone.color)
                    .frame(width: 6, height: 6)
                Text("\(count)")
                    .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                    .foregroundStyle(tone.color)
            }
            .help("\(count) \(word)")
        }
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
    /// Claude: the session is still open but its last run finished. Shown as Done, blue while unchecked.
    var done: (fresh: Bool, when: String)? = nil
    let onReveal: () -> Void

    var body: some View {
        if let done, !needsInput, !isRunning {
            AgentSessionRow(
                expansionID: expansionID,
                name: name,
                statusTitle: "Done",
                statusColor: SessionStatusTone.ended.color,
                dotColor: done.fresh ? SessionStatusTone.ended.color : Color.secondary,
                project: project,
                uptime: done.when,
                details: details,
                fill: done.fresh ? SessionStatusTone.ended.rowFill : SessionStatusTone.idle.rowFill,
                helpText: tooltip + "\nFinished " + done.when + "\n" + revealHint,
                onReveal: onReveal
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
                details: details,
                fill: tone.rowFill,
                helpText: tooltip + "\n" + revealHint,
                onReveal: onReveal
            )
        }
    }
}

/// Fresh ended rows first. `sorted` is stable, so the rest keep their order.
func endedRowsFreshFirst<Item>(_ items: [Item], isFresh: (Item) -> Bool) -> [Item] {
    items.sorted { isFresh($0) && !isFresh($1) }
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
    /// Unchecked finish. After the panel has been opened on it, the row goes grey and Ended stays blue.
    var fresh: Bool = false
    /// Same slot as a live row's uptime: "just now", "4m ago".
    var when: String? = nil
    var helpNote: String = "Chat ended. Click to show this project"
    let onReveal: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        AgentSessionRow(
            expansionID: expansionID,
            name: name,
            statusTitle: "Ended",
            statusColor: SessionStatusTone.ended.color,
            dotColor: fresh ? SessionStatusTone.ended.color : Color.secondary,
            project: project,
            uptime: when,
            details: details,
            fill: fresh ? SessionStatusTone.ended.rowFill : Color.secondary.opacity(0.14),
            helpText: helpNote,
            onReveal: onReveal,
            onDismiss: onDismiss
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
    let details: [SessionDetailField]
    let fill: Color
    let helpText: String
    let onReveal: () -> Void
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
            if showsProject || uptime != nil {
                HStack(spacing: 6) {
                    if showsProject {
                        projectChip
                            .layoutPriority(-1)
                    }
                    Spacer(minLength: 0)
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
    static func claude(_ session: ClaudeSession) -> [SessionDetailField] {
        collect([
            field("Name", session.name),
            field("Project", session.project),
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
        collect([
            field("Name", session.name),
            field("Project", session.project),
            field("Path", session.shortCwd, mono: true, middle: true),
            field("Pid", "\(session.pid)", mono: true),
            field("Kind", "CLI"),
            field("Preview", session.subtitle),
        ])
    }

    static func codexEnded(_ item: CodexEndedSession) -> [SessionDetailField] {
        collect([
            field("Name", item.name),
            field("Project", item.project),
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
