import Combine
import Foundation
import IOKit.ps

@MainActor
final class BatteryManager: ObservableObject {
    @Published var percentage: Int = 100
    @Published var isCharging: Bool = false
    @Published var isPluggedIn: Bool = true
    @Published var isLowPowerMode: Bool = false
    @Published var hasBattery: Bool = false
    @Published var timeRemainingFormatted: String?

    private var runLoopSource: CFRunLoopSource?
    private var cancellables = Set<AnyCancellable>()
    private var refreshPending = false

    init() {
        refreshBatteryState()
        setupPowerNotification()
        setupLowPowerModeObserver()
    }

    deinit {
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
    }

    /// Reads the power source once. Event driven (IOPS notification), never polled; every
    /// property is assigned only when it changed so unchanged notifications cause no re-render.
    func refreshBatteryState() {
        let lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        if isLowPowerMode != lowPower { isLowPowerMode = lowPower }

        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
            let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef], !list.isEmpty
        else {
            apply(found: false, percentage: 100, charging: nil, pluggedIn: true, remaining: nil)
            return
        }

        for source in list {
            guard let desc = IOPSGetPowerSourceDescription(blob, source)?.takeUnretainedValue() as? [String: Any] else {
                continue
            }

            let type = desc[kIOPSTypeKey as String] as? String
            guard type == (kIOPSInternalBatteryType as String) || desc[kIOPSCurrentCapacityKey as String] != nil
            else { continue }

            let curCap = desc[kIOPSCurrentCapacityKey as String] as? Int ?? 100
            let maxCap = desc[kIOPSMaxCapacityKey as String] as? Int ?? 100
            let charging = desc[kIOPSIsChargingKey as String] as? Bool ?? false
            let state = desc[kIOPSPowerSourceStateKey as String] as? String ?? ""

            let pct = maxCap > 0 ? Int((Double(curCap) / Double(maxCap)) * 100.0) : curCap

            var remaining: String?
            if let timeToEmpty = desc[kIOPSTimeToEmptyKey as String] as? Int, timeToEmpty > 0 {
                remaining = "\(timeToEmpty / 60)h \(timeToEmpty % 60)m remaining"
            } else if let timeToFull = desc[kIOPSTimeToFullChargeKey as String] as? Int, timeToFull > 0 {
                remaining = "\(timeToFull / 60)h \(timeToFull % 60)m until full"
            }

            apply(
                found: true,
                percentage: max(0, min(100, pct)),
                charging: charging,
                pluggedIn: (state == (kIOPSACPowerValue as String)) || charging,
                remaining: remaining
            )
            return
        }

        apply(found: false, percentage: percentage, charging: nil, pluggedIn: isPluggedIn, remaining: nil)
    }

    private func apply(found: Bool, percentage: Int, charging: Bool?, pluggedIn: Bool, remaining: String?) {
        if self.percentage != percentage { self.percentage = percentage }
        if let charging, isCharging != charging { isCharging = charging }
        if isPluggedIn != pluggedIn { isPluggedIn = pluggedIn }
        if timeRemainingFormatted != remaining { timeRemainingFormatted = remaining }
        if hasBattery != found { hasBattery = found }
    }

    private func setupPowerNotification() {
        let context = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        let source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context = context else { return }
            let manager = Unmanaged<BatteryManager>.fromOpaque(context).takeUnretainedValue()
            // The source lives on the main run loop, so this already runs on the main thread.
            MainActor.assumeIsolated { manager.scheduleRefresh() }
        }, context)?.takeRetainedValue()

        if let source = source {
            self.runLoopSource = source
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        }
    }

    /// Power notifications arrive in bursts (percent, time remaining, adapter); handle each burst once.
    private func scheduleRefresh() {
        guard !refreshPending else { return }
        refreshPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.refreshPending = false
                self.refreshBatteryState()
            }
        }
    }

    private func setupLowPowerModeObserver() {
        NotificationCenter.default.publisher(for: NSNotification.Name.NSProcessInfoPowerStateDidChange)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self = self else { return }
                let enabled = ProcessInfo.processInfo.isLowPowerModeEnabled
                if self.isLowPowerMode != enabled { self.isLowPowerMode = enabled }
            }
            .store(in: &cancellables)
    }

    func toggleLowPowerMode() {
        let target = !isLowPowerMode
        setLowPowerMode(enabled: target)
    }

    func setLowPowerMode(enabled: Bool) {
        Task { [weak self] in
            let success = await SMCHelperManager.shared.setLowPowerMode(enabled: enabled)
            guard let self = self else { return }
            if success {
                if self.isLowPowerMode != enabled { self.isLowPowerMode = enabled }
                self.refreshBatteryState()
            }
        }
    }
}
