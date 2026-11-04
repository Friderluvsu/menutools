import SwiftUI

/// One row per live Claude Code session: name, running / input / idle, and the project it is in.
struct ClaudeSessionsCard: View {
    @ObservedObject var manager: ClaudeSessionsManager
    var stackRevealed: Bool? = nil
    var stackIndexBase: Int = 0

    var body: some View {
        MacToolsCard(padding: 7) {
            TimelineView(.periodic(from: .now, by: 30)) { context in
                VStack(alignment: .leading, spacing: 4) {
                    SessionCardHeader(kind: .claude, tally: SessionStatusTally.claude(manager.sessions))
                        .sessionStackReveal(index: 0, revealed: stackRevealed, base: stackIndexBase)

                    if manager.sessions.isEmpty {
                        Text("No live sessions")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, minHeight: 20, alignment: .leading)
                    } else {
                        ForEach(Array(manager.sessions.enumerated()), id: \.element.id) { index, session in
                            AgentLiveRow(
                                expansionID: "claude:\(session.id)",
                                name: session.name,
                                statusTitle: session.statusTitle,
                                needsInput: session.needsInput,
                                isRunning: session.isWorking,
                                project: session.project,
                                uptime: session.uptime(now: context.date),
                                details: SessionDetailFields.claude(session),
                                tooltip: session.tooltip,
                                revealHint: "Click to show its window"
                            ) {
                                manager.reveal(session)
                            }
                            .sessionStackReveal(index: 1 + index, revealed: stackRevealed, base: stackIndexBase)
                        }
                    }
                }
            }
        }
    }
}
