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

    init() {
        refreshBatteryState()
        setupPowerNotification()
        setupLowPowerModeObserver()
    }

    func refreshBatteryState() {
        self.isLowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled

        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else {
            self.hasBattery = false
            self.percentage = 100
            self.isPluggedIn = true
            return
        }

        guard let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef], !list.isEmpty else {
            self.hasBattery = false
            self.percentage = 100
            self.isPluggedIn = true
            return
        }

        var foundBattery = false

        for source in list {
            guard let desc = IOPSGetPowerSourceDescription(blob, source)?.takeUnretainedValue() as? [String: Any] else {
                continue
            }

            let type = desc[kIOPSTypeKey as String] as? String
            if type == (kIOPSInternalBatteryType as String) || desc[kIOPSCurrentCapacityKey as String] != nil {
                foundBattery = true
                let curCap = desc[kIOPSCurrentCapacityKey as String] as? Int ?? 100
                let maxCap = desc[kIOPSMaxCapacityKey as String] as? Int ?? 100
                let charging = desc[kIOPSIsChargingKey as String] as? Bool ?? false
                let state = desc[kIOPSPowerSourceStateKey as String] as? String ?? ""

                let pct = maxCap > 0 ? Int((Double(curCap) / Double(maxCap)) * 100.0) : curCap
                self.percentage = max(0, min(100, pct))
                self.isCharging = charging
                self.isPluggedIn = (state == (kIOPSACPowerValue as String)) || charging

                if let timeToEmpty = desc[kIOPSTimeToEmptyKey as String] as? Int, timeToEmpty > 0 {
                    let h = timeToEmpty / 60
                    let m = timeToEmpty % 60
                    self.timeRemainingFormatted = "\(h)h \(m)m remaining"
                } else if let timeToFull = desc[kIOPSTimeToFullChargeKey as String] as? Int, timeToFull > 0 {
                    let h = timeToFull / 60
                    let m = timeToFull % 60
                    self.timeRemainingFormatted = "\(h)h \(m)m until full"
                } else {
                    self.timeRemainingFormatted = nil
                }
                break
            }
        }

        self.hasBattery = foundBattery
    }

    private func setupPowerNotification() {
        let context = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        let source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context = context else { return }
            let manager = Unmanaged<BatteryManager>.fromOpaque(context).takeUnretainedValue()
            Task { @MainActor in
                manager.refreshBatteryState()
            }
        }, context)?.takeRetainedValue()

        if let source = source {
            self.runLoopSource = source
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        }
    }

    private func setupLowPowerModeObserver() {
        NotificationCenter.default.publisher(for: NSNotification.Name.NSProcessInfoPowerStateDidChange)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self = self else { return }
                self.isLowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
                self.objectWillChange.send()
            }
            .store(in: &cancellables)
    }
}
