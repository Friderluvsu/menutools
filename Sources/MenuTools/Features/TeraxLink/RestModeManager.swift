import AppKit
import CoreGraphics
import Foundation
import IOKit.pwr_mgt

/// Rest mode, for stepping away while agents keep working: Low Power Mode on (when the helper is
/// installed, so no admin prompt can appear with nobody at the Mac), system sleep held off so
/// terminals and agents keep running, MenuTools' notifications and sounds silenced, and the display
/// turned off.
///
/// It lasts until the phone turns it off (which also turns the display back on) or someone uses the
/// Mac's keyboard or trackpad. A display woken by anything else, such as a notification, goes dark
/// again: input typed from the phone reaches terminals, not the HID system, so it never counts.
@MainActor
final class RestModeManager: ObservableObject {
    @Published private(set) var isOn = false
    private(set) var since: Date?

    /// Local input this recent at a wake means someone is at the Mac.
    nonisolated static let presenceWindow: TimeInterval = 3
    /// How long a display woken without local input may stay lit (a notification) before going dark.
    nonisolated static let redarkenDelay: TimeInterval = 15

    private let battery: BatteryManager
    private let previewMode: Bool
    private var assertion: IOPMAssertionID = 0
    private var turnedOnLowPower = false
    private var wakeObserver: NSObjectProtocol?
    private var redarken: DispatchWorkItem?

    init(battery: BatteryManager, previewMode: Bool) {
        self.battery = battery
        self.previewMode = previewMode
    }

    func start() {
        guard !previewMode else { return }
        guard !isOn else {
            Self.turnDisplayOff()
            return
        }
        let reason = "MenuTools Rest mode: agents keep running" as CFString
        let created = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn), reason, &assertion)
        if created != kIOReturnSuccess { assertion = 0 }
        if SMCHelperManager.isHelperInstalledSync, !battery.isLowPowerMode {
            battery.setLowPowerMode(enabled: true, allowPrompt: false)
            turnedOnLowPower = true
        }
        isOn = true
        since = Date()
        Alerts.silenced = true
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.displayWoke() }
        }
        Self.turnDisplayOff()
    }

    /// `wakeDisplay` is true when the phone ends Rest mode, so the Mac is ready to use.
    func stop(wakeDisplay: Bool = false) {
        guard isOn else { return }
        if assertion != 0 {
            IOPMAssertionRelease(assertion)
            assertion = 0
        }
        if turnedOnLowPower {
            battery.setLowPowerMode(enabled: false, allowPrompt: false)
            turnedOnLowPower = false
        }
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        wakeObserver = nil
        redarken?.cancel()
        redarken = nil
        isOn = false
        since = nil
        Alerts.silenced = false
        if wakeDisplay { Self.turnDisplayOn() }
    }

    /// Quit or logout: the process exits before any Task runs, so Low Power Mode is restored here,
    /// blocking, through the helper or `sudo -n` only.
    func prepareForTermination() {
        if turnedOnLowPower {
            SMCHelperManager.restoreLowPowerSync()
            turnedOnLowPower = false
        }
        stop()
    }

    private func displayWoke() {
        guard isOn else { return }
        if Self.someoneIsHere() {
            stop()
            return
        }
        scheduleRedarken()
    }

    /// A notification lights the display for a while; Awake's "keep display awake" would keep it lit
    /// for good. Input in the meantime means someone came to read it, which ends Rest mode instead.
    private func scheduleRedarken() {
        redarken?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.isOn else { return }
                self.redarken = nil
                if Self.secondsSinceLocalInput() < Self.redarkenDelay {
                    self.stop()
                } else {
                    Self.turnDisplayOff()
                }
            }
        }
        redarken = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.redarkenDelay, execute: work)
    }

    nonisolated static func someoneIsHere() -> Bool {
        secondsSinceLocalInput() < presenceWindow
    }

    /// Time since the last keyboard, trackpad or mouse event in the HID system. Synthetic and
    /// remote input (the phone typing into a terminal) does not reset it.
    nonisolated static func secondsSinceLocalInput() -> TimeInterval {
        guard let anyInput = CGEventType(rawValue: ~0) else { return .infinity }
        return CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: anyInput)
    }

    nonisolated static func turnDisplayOff() {
        run("/usr/bin/pmset", ["displaysleepnow"])
    }

    /// Declares user activity, which lights the display (the lock screen, if a password is required).
    nonisolated static func turnDisplayOn() {
        var id: IOPMAssertionID = 0
        let result = IOPMAssertionDeclareUserActivity(
            "MenuTools Rest mode ended from Terax" as CFString, kIOPMUserActiveLocal, &id)
        if result != kIOReturnSuccess { run("/usr/bin/caffeinate", ["-u", "-t", "2"]) }
    }

    nonisolated private static func run(_ path: String, _ arguments: [String]) {
        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = arguments
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try? process.run()
            process.waitUntilExit()
        }
    }
}
