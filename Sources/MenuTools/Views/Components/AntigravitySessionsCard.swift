import SwiftUI

struct AntigravitySessionsCard: View {
    @ObservedObject var manager: AntigravitySessionsManager
    var stackRevealed: Bool? = nil
    var stackIndexBase: Int = 0

    var body: some View {
        MacToolsCard(padding: 7) {
            TimelineView(.periodic(from: .now, by: 30)) { context in
                VStack(alignment: .leading, spacing: 4) {
                    SessionCardHeader(
                        kind: .antigravity,
                        tally: SessionStatusTally.antigravity(manager.sessions, ended: manager.ended.count)
                    )
                    .sessionStackReveal(index: 0, revealed: stackRevealed, base: stackIndexBase)

                    if !manager.ended.isEmpty {
                        let rows = endedRowsFreshFirst(manager.ended) {
                            !$0.seen || manager.freshEnded.contains($0.id)
                        }
                        ForEach(Array(rows.enumerated()), id: \.element.id) { index, item in
                            AgentEndedRow(
                                expansionID: "agy-ended:\(item.id)",
                                name: item.name,
                                project: item.project,
                                details: SessionDetailFields.antigravityEnded(item),
                                fresh: !item.seen || manager.freshEnded.contains(item.id),
                                when: endedAgo(item.endedAt, now: context.date)
                            ) {
                                manager.revealEnded(item)
                            } onDismiss: {
                                manager.dismiss(item.id)
                            }
                            .sessionStackReveal(index: 1 + index, revealed: stackRevealed, base: stackIndexBase)
                        }
                    }

                    if manager.sessions.isEmpty && manager.ended.isEmpty {
                        Text("No live sessions")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, minHeight: 20, alignment: .leading)
                    } else {
                        ForEach(Array(manager.sessions.enumerated()), id: \.element.id) { index, session in
                            AgentLiveRow(
                                expansionID: "agy:\(session.id)",
                                name: session.name,
                                statusTitle: session.statusTitle,
                                needsInput: session.needsInput,
                                isRunning: session.status == "running",
                                project: session.project,
                                uptime: session.uptime(now: context.date),
                                details: SessionDetailFields.antigravity(session),
                                tooltip: session.tooltip
                            ) {
                                manager.reveal(session)
                            }
                            .sessionStackReveal(
                                index: 1 + manager.ended.count + index, revealed: stackRevealed,
                                base: stackIndexBase)
                        }
                    }
                }
            }
        }
    }
}
