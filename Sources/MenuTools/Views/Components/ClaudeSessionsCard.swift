import SwiftUI

/// One row per live Claude Code session: name, running / input / idle, and the project it is in.
struct ClaudeSessionsCard: View {
    @ObservedObject var manager: ClaudeSessionsManager
    @EnvironmentObject private var listState: SessionListState
    var stackRevealed: Bool? = nil
    var stackIndexBase: Int = 0

    var body: some View {
        let tally = SessionStatusTally.claude(manager.sessions, finished: manager.finished)
        MacToolsCard(padding: 7) {
            TimelineView(.periodic(from: .now, by: 30)) { context in
                VStack(alignment: .leading, spacing: 4) {
                    SessionCardHeader(kind: .claude, tally: tally, listState: listState) {
                        manager.checkAll()
                    }
                    .sessionStackReveal(index: 0, revealed: stackRevealed, base: stackIndexBase)

                    if manager.sessions.isEmpty {
                        Text("No live sessions")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, minHeight: 20, alignment: .leading)
                    } else {
                        SessionRowList(
                            kind: .claude, items: newestFinishFirst, tally: tally, tone: tone, project: \.project
                        ) { session in
                            AgentLiveRow(
                                expansionID: "claude:\(session.id)",
                                name: session.name,
                                statusTitle: session.statusTitle,
                                needsInput: session.needsInput,
                                isRunning: session.isWorking,
                                project: session.project,
                                uptime: session.uptime(now: context.date),
                                details: SessionDetailFields.claude(session, usage: manager.usage[session.id]),
                                tooltip: session.tooltip,
                                revealHint: "Click to show its window",
                                done: manager.finished[session.id].map { endedAgo($0.finishedAt, now: context.date) },
                                usage: manager.usage[session.id],
                                onCheck: { manager.check(session.id) }
                            ) {
                                manager.reveal(session)
                            }
                        }
                    }
                }
            }
        }
    }

    private func tone(_ session: ClaudeSession) -> SessionStatusTone {
        if manager.finished[session.id] != nil, !session.isWorking, !session.needsInput { return .ended }
        return .live(needsInput: session.needsInput, isRunning: session.isWorking)
    }

    /// Unchecked finishes newest first; the list then orders by state and keeps this order inside one.
    private var newestFinishFirst: [ClaudeSession] {
        manager.sessions.enumerated()
            .sorted { lhs, rhs in
                let left = manager.finished[lhs.element.id]?.finishedAt ?? .distantPast
                let right = manager.finished[rhs.element.id]?.finishedAt ?? .distantPast
                return left == right ? lhs.offset < rhs.offset : left > right
            }
            .map(\.element)
    }
}
