import Combine
import Foundation
import IOKit
import IOKit.ps

@MainActor
final class BatteryManager: ObservableObject {
    @Published var percentage: Int = 100
    @Published var isCharging: Bool = false
    @Published var isPluggedIn: Bool = true
    @Published var isLowPowerMode: Bool = false
    @Published var hasBattery: Bool = false
    @Published var timeRemainingFormatted: String?
    /// "94%" when design and nominal capacity are both known, otherwise Good / Fair / Poor.
    @Published var healthText: String?
    @Published var cycleCount: Int?
    @Published var powerWatts: Double?
    @Published var batteryTemperatureC: Double?
    @Published var capacityMaxMah: Int?
    @Published var capacityDesignMah: Int?
    @Published var voltageMillivolts: Int?
    /// Signed. Positive is charging, negative is discharging.
    @Published var currentMilliamps: Int?

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
            apply(found: false, percentage: 100, charging: nil, pluggedIn: true, remaining: nil, extras: nil)
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
                remaining: remaining,
                extras: Self.extras(from: desc)
            )
            return
        }

        apply(found: false, percentage: percentage, charging: nil, pluggedIn: isPluggedIn, remaining: nil, extras: nil)
    }

    private struct Extras {
        var health: String?
        var cycles: Int?
        var watts: Double?
        var temperature: Double?
        var capacityMax: Int?
        var capacityDesign: Int?
        var millivolts: Int?
        var milliamps: Int?
    }

    /// Health, cycles, watts and temperature. IOPS is sparse on Apple batteries; the
    /// AppleSmartBattery registry entry carries the rest and is read on the same power event.
    private static func extras(from desc: [String: Any]) -> Extras {
        let registry = smartBattery()
        func value(_ key: String) -> Int? { number(registry, key) ?? number(desc, key) }

        var health: String?
        let design = value("DesignCapacity")
        let full = value("AppleRawMaxCapacity") ?? value("NominalChargeCapacity") ?? value(kIOPSNominalCapacityKey as String)
        if let design, let full, design > 100, full > 0 {
            let percent = Int((Double(full) / Double(design) * 100).rounded())
            if (40...100).contains(percent) { health = "\(percent)%" }
        }
        if health == nil, let word = desc[kIOPSBatteryHealthKey as String] as? String, !word.isEmpty {
            health = word
        }

        let cycles = value("CycleCount") ?? number(desc, "Cycle Count")

        var watts: Double?
        let millivolts = value("Voltage")
        let milliamps = value("Amperage") ?? number(desc, kIOPSCurrentKey as String)
        if let millivolts, let milliamps, millivolts > 0, milliamps != 0, abs(milliamps) < 20_000 {
            watts = Double(abs(milliamps)) * Double(millivolts) / 1_000_000
        }

        var temperature: Double?
        if let raw = value("Temperature") {
            let celsius = raw > 200 ? Double(raw) / 100 : Double(raw)
            if (10...80).contains(celsius) { temperature = celsius }
        }

        let designMah = design.flatMap { $0 > 100 ? $0 : nil }
        let maxMah = full.flatMap { $0 > 100 ? $0 : nil }
        return Extras(
            health: health,
            cycles: cycles.flatMap { $0 > 0 ? $0 : nil },
            watts: watts,
            temperature: temperature,
            capacityMax: maxMah,
            capacityDesign: designMah,
            millivolts: millivolts.flatMap { $0 > 0 ? $0 : nil },
            milliamps: milliamps.flatMap { abs($0) < 20_000 ? $0 : nil })
    }

    private static func smartBattery() -> [String: Any] {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return [:] }
        defer { IOObjectRelease(service) }
        var unmanaged: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &unmanaged, kCFAllocatorDefault, 0) == KERN_SUCCESS,
            let unmanaged
        else { return [:] }
        return unmanaged.takeRetainedValue() as? [String: Any] ?? [:]
    }

    private static func number(_ desc: [String: Any], _ key: String) -> Int? {
        guard let number = desc[key] as? NSNumber else { return nil }
        let bits = number.uint64Value
        // Negative current is stored as a full-width unsigned value.
        if bits > UInt64(Int64.max) { return Int(Int64(bitPattern: bits)) }
        return Int(truncatingIfNeeded: bits)
    }

    private func apply(
        found: Bool, percentage: Int, charging: Bool?, pluggedIn: Bool, remaining: String?, extras: Extras?
    ) {
        if self.percentage != percentage { self.percentage = percentage }
        if let charging, isCharging != charging { isCharging = charging }
        if isPluggedIn != pluggedIn { isPluggedIn = pluggedIn }
        if timeRemainingFormatted != remaining { timeRemainingFormatted = remaining }
        if hasBattery != found { hasBattery = found }
        if healthText != extras?.health { healthText = extras?.health }
        if cycleCount != extras?.cycles { cycleCount = extras?.cycles }
        if powerWatts != extras?.watts { powerWatts = extras?.watts }
        if batteryTemperatureC != extras?.temperature { batteryTemperatureC = extras?.temperature }
        if capacityMaxMah != extras?.capacityMax { capacityMaxMah = extras?.capacityMax }
        if capacityDesignMah != extras?.capacityDesign { capacityDesignMah = extras?.capacityDesign }
        if voltageMillivolts != extras?.millivolts { voltageMillivolts = extras?.millivolts }
        if currentMilliamps != extras?.milliamps { currentMilliamps = extras?.milliamps }
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
