import AppKit
import SwiftUI

/// One line in the hover peek: a live or unseen-ended session.
struct SessionPeekRow: Identifiable, Equatable {
    let id: String
    let provider: String
    let name: String
    let project: String
    /// 0 needs input, 1 running, 2 done (unseen).
    let state: Int
}

extension AppState {
    /// Sessions the menu bar lights count, most urgent first. Idle sessions are left out.
    var sessionPeek: [SessionPeekRow] {
        var rows: [SessionPeekRow] = []
        for session in claudeSessions.sessions {
            let done = claudeSessions.finished[session.id].map { !$0.seen } ?? false
            let state = session.needsInput ? 0 : (session.isWorking ? 1 : (done ? 2 : -1))
            guard state >= 0 else { continue }
            rows.append(
                SessionPeekRow(
                    id: "claude:\(session.id)", provider: "Claude", name: session.name, project: session.project,
                    state: state))
        }
        for session in cursorSessions.sessions {
            let state = session.needsInput ? 0 : (session.status == "running" ? 1 : -1)
            guard state >= 0 else { continue }
            rows.append(
                SessionPeekRow(
                    id: "cursor:\(session.id)", provider: "Cursor", name: session.name, project: session.project,
                    state: state))
        }
        for ended in cursorSessions.ended where !ended.seen {
            rows.append(
                SessionPeekRow(
                    id: "cursor-ended:\(ended.id)", provider: "Cursor", name: ended.name, project: ended.project,
                    state: 2))
        }
        for session in codexSessions.sessions {
            rows.append(
                SessionPeekRow(
                    id: "codex:\(session.id)", provider: "Codex", name: session.name, project: session.project,
                    state: 1))
        }
        for ended in codexSessions.ended where !ended.seen {
            rows.append(
                SessionPeekRow(
                    id: "codex-ended:\(ended.id)", provider: "Codex", name: ended.name, project: ended.project,
                    state: 2))
        }
        for session in antigravitySessions.sessions {
            let state = session.needsInput ? 0 : (session.status == "running" ? 1 : -1)
            guard state >= 0 else { continue }
            rows.append(
                SessionPeekRow(
                    id: "agy:\(session.id)", provider: "Antigravity", name: session.name, project: session.project,
                    state: state))
        }
        for ended in antigravitySessions.ended where !ended.seen {
            rows.append(
                SessionPeekRow(
                    id: "agy-ended:\(ended.id)", provider: "Antigravity", name: ended.name, project: ended.project,
                    state: 2))
        }
        return rows.sorted { $0.state < $1.state }
    }
}

/// A small card under the menu bar icon while the pointer rests on it (Settings → Hover peek).
/// Non-activating and never key, so it does not steal focus; it closes when the pointer leaves or
/// the panel opens.
@MainActor
final class SessionPeekController {
    private var window: NSPanel?
    private var pending: DispatchWorkItem?
    private var shownRows: [SessionPeekRow] = []
    private weak var shownButton: NSStatusBarButton?
    private var spaceObserver: NSObjectProtocol?

    func hover(_ inside: Bool, button: NSStatusBarButton, rows: @escaping () -> [SessionPeekRow]) {
        pending?.cancel()
        guard inside else {
            hide()
            return
        }
        let work = DispatchWorkItem { [weak self, weak button] in
            guard let self, let button else { return }
            self.show(rows: rows(), under: button)
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
    }

    /// New rows while the card is up (a session started or finished under the pointer).
    func refresh(_ rows: [SessionPeekRow]) {
        guard let window, window.isVisible, rows != shownRows, let button = shownButton else { return }
        show(rows: rows, under: button)
    }

    func hide() {
        pending?.cancel()
        pending = nil
        window?.orderOut(nil)
    }

    private func show(rows: [SessionPeekRow], under button: NSStatusBarButton) {
        guard let buttonWindow = button.window else { return }
        shownRows = rows
        shownButton = button
        let host = NSHostingView(rootView: SessionPeekCard(rows: rows))
        host.layoutSubtreeIfNeeded()
        let size = host.fittingSize
        let panel = window ?? makeWindow()
        panel.contentView = host
        let anchor = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        let screen = buttonWindow.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        var x = anchor.midX - size.width / 2
        x = min(max(x, screen.minX + 6), screen.maxX - size.width - 6)
        panel.setFrame(
            NSRect(x: x, y: anchor.minY - size.height - 4, width: size.width, height: size.height), display: true)
        panel.orderFrontRegardless()
    }

    private func makeWindow() -> NSPanel {
        let panel = NSPanel(
            contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.animationBehavior = .none
        window = panel
        // A Space switch or an auto-hiding menu bar may never send mouseExited.
        spaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.hide() } }
        return panel
    }
}

private struct SessionPeekCard: View {
    let rows: [SessionPeekRow]

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if rows.isEmpty {
                Text("No active sessions")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(rows.prefix(8)) { row in
                    HStack(spacing: 7) {
                        Circle()
                            .fill(Color(nsColor: StatusLightPalette.all[row.state]))
                            .frame(width: 7, height: 7)
                        Text(row.name)
                            .font(.system(size: 11.5, weight: .medium))
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Spacer(minLength: 6)
                        Text(row.project.isEmpty ? row.provider : "\(row.provider) · \(row.project)")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                if rows.count > 8 {
                    Text("+\(rows.count - 8) more")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(width: 280, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))
    }
}
