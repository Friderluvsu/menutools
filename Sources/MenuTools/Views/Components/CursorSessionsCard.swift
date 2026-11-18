import SwiftUI

/// One row per live Cursor agent chat: name, status, and the project it is working in.
struct CursorSessionsCard: View {
    @ObservedObject var manager: CursorSessionsManager
    @EnvironmentObject private var listState: SessionListState
    var stackRevealed: Bool? = nil
    var stackIndexBase: Int = 0

    private enum Item: Identifiable {
        case live(CursorSession)
        case ended(CursorEndedSession)

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

        var tone: SessionStatusTone {
            switch self {
            case .live(let session): .live(needsInput: session.needsInput, isRunning: session.status == "running")
            case .ended(let item): item.seen ? .idle : .ended
            }
        }
    }

    var body: some View {
        let tally = SessionStatusTally.cursor(manager.sessions, ended: manager.ended)
        MacToolsCard(padding: 7) {
            TimelineView(.periodic(from: .now, by: 30)) { context in
                VStack(alignment: .leading, spacing: 4) {
                    SessionCardHeader(kind: .cursor, tally: tally, listState: listState) {
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
                            kind: .cursor, items: items, tally: tally, tone: \.tone, project: \.project
                        ) { item in
                            row(item, now: context.date)
                        }
                    }
                }
            }
        }
    }

    /// Ended rows newest first, then live chats.
    private var items: [Item] {
        manager.ended.sorted { $0.endedAt > $1.endedAt }.map(Item.ended) + manager.sessions.map(Item.live)
    }

    @ViewBuilder
    private func row(_ item: Item, now: Date) -> some View {
        switch item {
        case .ended(let ended):
            AgentEndedRow(
                expansionID: "cursor-ended:\(ended.id)",
                name: ended.name,
                project: ended.project,
                details: SessionDetailFields.cursorEnded(ended),
                unchecked: !ended.seen,
                when: endedAgo(ended.endedAt, now: now),
                helpNote: "Chat ended. Click to show this project in Cursor"
            ) {
                manager.revealEnded(ended)
            } onCheck: {
                manager.check(ended.id)
            } onDismiss: {
                manager.dismiss(ended.id)
            }
        case .live(let session):
            AgentLiveRow(
                expansionID: "cursor:\(session.id)",
                name: session.name,
                statusTitle: session.statusTitle,
                needsInput: session.needsInput,
                isRunning: session.status == "running",
                project: session.project,
                uptime: session.uptime(now: now),
                details: SessionDetailFields.cursor(session),
                tooltip: session.tooltip,
                revealHint: "Click to show this project in Cursor",
                usage: session.usage
            ) {
                manager.reveal(session)
            }
        }
    }
}
