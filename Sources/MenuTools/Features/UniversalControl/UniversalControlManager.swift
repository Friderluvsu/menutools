import Combine
import AppKit
import CoreFoundation
import Foundation

@MainActor
final class UniversalControlManager: ObservableObject {
    private enum Keys {
        static let autoEnable = "UniversalControlAutoEnable"
    }

    private let preferenceDomain = "com.apple.universalcontrol" as CFString
    private let disabledPreference = "Disable" as CFString
    /// Safety net only: changes are picked up from file events and wake notifications.
    private var timer: AnyCancellable?
    private var watchSource: DispatchSourceFileSystemObject?
    private var wakeObserver: NSObjectProtocol?
    private var pendingCheck: DispatchWorkItem?

    @Published var isAutoEnableEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isAutoEnableEnabled, forKey: Keys.autoEnable)
            if isAutoEnableEnabled {
                startMonitoring()
                reenableIfNeeded()
            } else {
                stopMonitoring()
            }
        }
    }

    @Published private(set) var isUniversalControlEnabled = true

    init() {
        isAutoEnableEnabled = UserDefaults.standard.bool(forKey: Keys.autoEnable)
        refreshStatus()
        if isAutoEnableEnabled {
            startMonitoring()
        }
    }

    func startMonitoring() {
        guard timer == nil else { return }

        // cfprefsd persists per-host preferences into ~/Library/Preferences/ByHost; a write there means
        // the switch may have flipped. Directory events are rare, so this costs nothing while idle.
        let byHost = NSHomeDirectory() + "/Library/Preferences/ByHost"
        let fd = open(byHost, O_EVTONLY)
        if fd >= 0 {
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: fd, eventMask: [.write], queue: .main)
            source.setEventHandler { [weak self] in
                MainActor.assumeIsolated { self?.scheduleCheck() }
            }
            source.setCancelHandler { close(fd) }
            source.resume()
            watchSource = source
        }

        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleCheck() }
        }

        // Without the directory watcher fall back to a modest poll; with it, just a rare safety check.
        let interval: TimeInterval = fd >= 0 ? 120 : 15
        timer = Timer.publish(every: interval, tolerance: interval * 0.3, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                self?.reenableIfNeeded()
            }
    }

    func stopMonitoring() {
        timer?.cancel()
        timer = nil
        watchSource?.cancel()
        watchSource = nil
        pendingCheck?.cancel()
        pendingCheck = nil
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
            self.wakeObserver = nil
        }
    }

    /// Coalesces bursts of preference writes into one check.
    private func scheduleCheck() {
        pendingCheck?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.reenableIfNeeded() }
        }
        pendingCheck = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: work)
    }

    private func reenableIfNeeded() {
        guard isAutoEnableEnabled else { return }

        if isUniversalControlDisabled {
            // macOS stores this switch in a per-host preference. `Disable` is an
            // undocumented key, so keep the write narrowly scoped to that switch.
            CFPreferencesSetValue(
                disabledPreference,
                kCFBooleanFalse,
                preferenceDomain,
                kCFPreferencesCurrentUser,
                kCFPreferencesCurrentHost
            )
            CFPreferencesSynchronize(
                preferenceDomain,
                kCFPreferencesCurrentUser,
                kCFPreferencesCurrentHost
            )
        }

        refreshStatus()
    }

    private var isUniversalControlDisabled: Bool {
        CFPreferencesSynchronize(
            preferenceDomain,
            kCFPreferencesCurrentUser,
            kCFPreferencesCurrentHost
        )
        let value = CFPreferencesCopyValue(
            disabledPreference,
            preferenceDomain,
            kCFPreferencesCurrentUser,
            kCFPreferencesCurrentHost
        )
        return (value as? Bool) ?? false
    }

    private func refreshStatus() {
        let enabled = !isUniversalControlDisabled
        if isUniversalControlEnabled != enabled { isUniversalControlEnabled = enabled }
    }
}
