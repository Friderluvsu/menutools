import Foundation
import UserNotifications

/// The "finished" and "needs input" notifications of the Cursor, Antigravity and Codex managers.
@MainActor
enum SessionNotifier {
    private static var askedPermission = false

    static func ensurePermission() {
        guard !askedPermission else { return }
        askedPermission = true
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// `identifier` is the full request id, e.g. `cursor-ended-<chat id>`. `session` (`cursor:<id>`)
    /// makes a click on it check and reveal that row (`SessionNotificationRouter`).
    static func post(title: String, name: String, project: String, identifier: String, session: String? = nil) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = project == "—" || project.isEmpty ? name : "\(name) · \(project)"
        content.sound = .default
        if let session { content.userInfo = [SessionNotificationRouter.sessionKey: session] }
        Alerts.post(UNNotificationRequest(identifier: identifier, content: content, trigger: nil))
    }
}

/// A click on a "finished" notification checks that session and brings it forward, like a row click.
/// Other notifications only activate MenuTools, as before.
final class SessionNotificationRouter: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    static let sessionKey = "menutools.session"
    static let shared = SessionNotificationRouter()

    /// Set before launch finishes, so a click that launched the app is still delivered.
    @MainActor
    static func install(app: AppState) {
        shared.app = app
        UNUserNotificationCenter.current().delegate = shared
    }

    @MainActor private weak var app: AppState?

    func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let session = response.notification.request.content.userInfo[Self.sessionKey] as? String
        let isDefault = response.actionIdentifier == UNNotificationDefaultActionIdentifier
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                if isDefault, let session { self.open(session) }
            }
            completionHandler()
        }
    }

    /// The panel may be open (MenuTools is the active app): show the banner anyway.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list, .sound])
    }

    @MainActor
    private func open(_ session: String) {
        guard let app, let colon = session.firstIndex(of: ":") else { return }
        let id = String(session[session.index(after: colon)...])
        switch session[..<colon] {
        case "claude": app.claudeSessions.revealFinished(id: id)
        case "cursor": app.cursorSessions.revealEnded(id: id)
        case "codex": app.codexSessions.revealEnded(id: id)
        case "agy": app.antigravitySessions.revealEnded(id: id)
        default: break
        }
    }
}
