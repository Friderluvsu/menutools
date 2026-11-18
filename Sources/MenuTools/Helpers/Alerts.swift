import AppKit
import UserNotifications

/// Every MenuTools notification and alert sound goes through here, so Rest mode can keep the Mac
/// silent: a notification would play a sound and light the display nobody is looking at.
@MainActor
enum Alerts {
    /// True while Rest mode is on. Alerts raised meanwhile are dropped, not queued: the session
    /// lists still show what needs input once someone is back.
    static var silenced = false

    static func post(_ request: UNNotificationRequest) {
        guard !silenced else { return }
        UNUserNotificationCenter.current().add(request)
    }

    static func play(_ name: String) {
        guard !silenced else { return }
        NSSound(named: NSSound.Name(name))?.play()
    }
}
