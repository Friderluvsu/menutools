import SwiftUI

struct CodexSessionsCard: View {
    @ObservedObject var manager: CodexSessionsManager
    @EnvironmentObject private var listState: SessionListState
    var stackRevealed: Bool? = nil
    var stackIndexBase: Int = 0

    private enum Item: Identifiable {
        case live(CodexSession)
        case ended(CodexEndedSession)

        var id: String {
            switch self {
            case .live(let session): "live:\(session.id)"
            case .ended(let item): "ended:\(item.id)"
            }
        }

        var project: String {
            switch self {
            case .live(let session): session.project
            case .ended(let item): item.project
            }
        }

        /// A live Codex process has no idle state: it counts as running.
        var tone: SessionStatusTone {
            switch self {
            case .live: .running
            case .ended(let item): item.seen ? .idle : .ended
            }
        }
    }

    var body: some View {
        let tally = SessionStatusTally.codex(live: manager.sessions.count, ended: manager.ended)
        MacToolsCard(padding: 7) {
            TimelineView(.periodic(from: .now, by: 30)) { context in
                VStack(alignment: .leading, spacing: 4) {
                    SessionCardHeader(kind: .codex, tally: tally, listState: listState) {
                        manager.checkAll()
                    }
                    .sessionStackReveal(index: 0, revealed: stackRevealed, base: stackIndexBase)

                    if manager.sessions.isEmpty && manager.ended.isEmpty {
                        Text("No live sessions")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, minHeight: 20, alignment: .leading)
                    } else {
                        SessionRowList(
                            kind: .codex, items: items, tally: tally, tone: \.tone, project: \.project
                        ) { item in
                            row(item, now: context.date)
                        }
                    }
                }
            }
        }
    }

    /// Ended rows newest first, then live processes.
    private var items: [Item] {
        manager.ended.sorted { $0.endedAt > $1.endedAt }.map(Item.ended) + manager.sessions.map(Item.live)
    }

    @ViewBuilder
    private func row(_ item: Item, now: Date) -> some View {
        switch item {
        case .ended(let ended):
            AgentEndedRow(
                expansionID: "codex-ended:\(ended.id)",
                name: ended.name,
                project: ended.project,
                details: SessionDetailFields.codexEnded(ended),
                unchecked: !ended.seen,
                when: endedAgo(ended.endedAt, now: now),
                usage: ended.usage
            ) {
                manager.revealEnded(ended)
            } onCheck: {
                manager.check(ended.id)
            } onDismiss: {
                manager.dismiss(ended.id)
            }
        case .live(let session):
            AgentLiveRow(
                expansionID: "codex:\(session.id)",
                name: session.name,
                statusTitle: session.statusTitle,
                needsInput: false,
                isRunning: true,
                project: session.project,
                uptime: session.uptime(now: now),
                details: SessionDetailFields.codex(session),
                tooltip: session.tooltip,
                usage: session.usage
            ) {
                manager.reveal(session)
            }
        }
    }
}
