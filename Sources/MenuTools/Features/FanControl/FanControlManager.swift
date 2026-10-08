import Combine
import Foundation

public enum FanControlMode: String, CaseIterable, Identifiable, Codable {
    case auto = "Auto"
    case curve = "Sensor-based"
    case constant = "Constant RPM"

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .auto: return "Auto (macOS)"
        case .curve: return "Sensor-based"
        case .constant: return "Constant RPM"
        }
    }

    public var icon: String {
        switch self {
        case .auto: return "sparkles"
        case .curve: return "chart.xyaxis.line"
        case .constant: return "gauge.with.needle.fill"
        }
    }
}

public enum ConstantPreset: String, CaseIterable, Identifiable {
    case quiet = "Quiet"
    case balanced = "Balanced"
    case boost = "Boost"
    case max = "Max"

    public var id: String { rawValue }

    public var label: String { rawValue }

    public var caption: String {
        switch self {
        case .quiet: return "Min RPM"
        case .balanced: return "Moderate"
        case .boost: return "High airflow"
        case .max: return "Full speed"
        }
    }
}

@MainActor
final class FanControlManager: ObservableObject {
    @Published var hasFans: Bool = true
    @Published var controlMode: FanControlMode = .auto {
        didSet {
            UserDefaults.standard.set(controlMode.rawValue, forKey: Keys.controlMode)
            applyModeChange()
        }
    }

    @Published var selectedSensor: ThermalSensorGroup = .cpuPerformance {
        didSet {
            UserDefaults.standard.set(selectedSensor.rawValue, forKey: Keys.selectedSensor)
            if controlMode == .curve { updateCurveCalculation(forceApply: true) }
        }
    }

    @Published var curveStartTemp: Int = 45 {
        didSet {
            UserDefaults.standard.set(curveStartTemp, forKey: Keys.curveStartTemp)
            if controlMode == .curve { updateCurveCalculation(forceApply: true) }
        }
    }

    @Published var curveMaxTemp: Int = 75 {
        didSet {
            UserDefaults.standard.set(curveMaxTemp, forKey: Keys.curveMaxTemp)
            if controlMode == .curve { updateCurveCalculation(forceApply: true) }
        }
    }

    @Published var currentSensorTemp: Double = 45.0
    @Published var currentRPM: Int = 0
    @Published var targetRPM: Int = 3000
    @Published var minRPM: Int = 1200
    @Published var maxRPM: Int = 6200
    @Published var fanCount: Int = 0
    @Published var statusText: String = "Auto"
    @Published var modelIdentifier: String = ""
    @Published var isApplying: Bool = false
    @Published var selectedPreset: ConstantPreset? = nil

    private enum Keys {
        static let controlMode = "FanControl.ControlMode"
        static let selectedSensor = "FanControl.SelectedSensor"
        static let curveStartTemp = "FanControl.CurveStartTemp"
        static let curveMaxTemp = "FanControl.CurveMaxTemp"
        static let targetRPM = "FanControl.TargetRPM"
    }

    private var timerCancellable: AnyCancellable?
    private var isForegroundPolling = false
    /// Unrounded sensor reading used by the curve; `currentSensorTemp` is published only on visible change.
    private var rawSensorTemp: Double = 45.0
    private var lastAppliedRPM: Int = -1
    private let smc = SMCDriver.shared
    private let helper = SMCHelperManager.shared

    init() {
        loadSavedSettings()
        detectHardware()
        if hasFans && controlMode == .curve {
            // Curve control keeps running with the panel closed, at a relaxed cadence.
            schedulePolling(foreground: false)
        } else if !hasFans {
            stopMonitoring()
        }
    }

    private func loadSavedSettings() {
        let defaults = UserDefaults.standard
        if let rawMode = defaults.string(forKey: Keys.controlMode),
           let mode = FanControlMode(rawValue: rawMode) {
            self.controlMode = mode
        }
        if let rawSensor = defaults.string(forKey: Keys.selectedSensor),
           let sensor = ThermalSensorGroup(rawValue: rawSensor) {
            self.selectedSensor = sensor
        }
        if defaults.object(forKey: Keys.curveStartTemp) != nil {
            self.curveStartTemp = defaults.integer(forKey: Keys.curveStartTemp)
        }
        if defaults.object(forKey: Keys.curveMaxTemp) != nil {
            self.curveMaxTemp = defaults.integer(forKey: Keys.curveMaxTemp)
        }
        if defaults.object(forKey: Keys.targetRPM) != nil {
            let savedRPM = defaults.integer(forKey: Keys.targetRPM)
            if savedRPM > 0 { self.targetRPM = savedRPM }
        }
    }

    private func detectHardware() {
        var size: Int = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var model = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.model", &model, &size, nil, 0)
        let modelStr = model.withUnsafeBufferPointer { ptr in
            ptr.baseAddress.map { String(cString: $0) } ?? ""
        }
        self.modelIdentifier = modelStr

        let detectedFans = smc.readFanCount()
        if detectedFans > 0 {
            self.hasFans = true
            self.fanCount = detectedFans
            let realMin = smc.readFanMinRPM(0)
            let realMax = smc.readFanMaxRPM(0)
            if realMin > 0 { self.minRPM = realMin }
            if realMax > realMin { self.maxRPM = realMax }
            if targetRPM < minRPM || targetRPM > maxRPM {
                self.targetRPM = minRPM + Int(Double(maxRPM - minRPM) * 0.25)
            }
            self.currentRPM = smc.readFanActualRPM(0)
            self.currentSensorTemp = smc.readTemperature(for: selectedSensor)
            self.rawSensorTemp = self.currentSensorTemp
            updateStatusText()
            return
        }

        let fanlessModels = [
            "Mac14,2", "Mac14,15", "Mac15,12", "Mac15,13", "MacBookAir10,1",
            "MacBook8,1", "MacBook9,1", "MacBook10,1",
        ]

        if modelStr.hasPrefix("MacBookAir") || fanlessModels.contains(modelStr) {
            self.hasFans = false
            self.fanCount = 0
            self.currentRPM = 0
            self.statusText = "No Fans"
        } else {
            self.hasFans = true
            self.fanCount = modelStr.contains("MacBookPro") ? 2 : 1
            self.currentRPM = smc.readFanActualRPM(0)
            updateStatusText()
        }
    }

    /// Panel is open: live readout (2s).
    func startMonitoring() {
        guard hasFans else { return }
        if timerCancellable != nil && isForegroundPolling { return }
        updateFanSpeed()
        schedulePolling(foreground: true)
    }

    func stopMonitoring() {
        timerCancellable?.cancel()
        timerCancellable = nil
        isForegroundPolling = false
    }

    /// Panel closed: stop polling, except sensor-based control which needs a slow background loop (5s).
    func enterBackground() {
        if controlMode == .curve && hasFans {
            schedulePolling(foreground: false)
        } else {
            stopMonitoring()
        }
    }

    private func schedulePolling(foreground: Bool) {
        guard hasFans else { return }
        if timerCancellable != nil && isForegroundPolling == foreground { return }
        timerCancellable?.cancel()
        isForegroundPolling = foreground
        let interval: TimeInterval = foreground ? 2.0 : 5.0
        timerCancellable = Timer.publish(every: interval, tolerance: interval * 0.3, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                self?.updateFanSpeed()
            }
    }

    private func updateFanSpeed() {
        guard hasFans else {
            if currentRPM != 0 { currentRPM = 0 }
            return
        }

        let actual = smc.readFanActualRPM(0)
        if actual > 0, currentRPM != actual {
            currentRPM = actual
        }

        rawSensorTemp = smc.readTemperature(for: selectedSensor)
        if abs(currentSensorTemp - rawSensorTemp) >= 0.5 {
            currentSensorTemp = rawSensorTemp
        }

        switch controlMode {
        case .auto:
            setStatus("Auto")
        case .curve:
            updateCurveCalculation(forceApply: false)
        case .constant:
            setStatus("\(targetRPM) RPM")
        }
    }

    private func setStatus(_ text: String) {
        if statusText != text { statusText = text }
    }

    private func updateCurveCalculation(forceApply: Bool) {
        guard hasFans && controlMode == .curve else { return }

        let tMin = Double(curveStartTemp)
        let tMax = Double(max(curveMaxTemp, curveStartTemp + 5))
        let currentT = rawSensorTemp

        let ratio: Double
        if currentT <= tMin {
            ratio = 0.0
        } else if currentT >= tMax {
            ratio = 1.0
        } else {
            ratio = (currentT - tMin) / (tMax - tMin)
        }

        let span = Double(maxRPM - minRPM)
        let rawTarget = minRPM + Int(ratio * span)
        let steppedTarget = (rawTarget / 50) * 50
        let calculatedRPM = min(max(steppedTarget, minRPM), maxRPM)

        if targetRPM != calculatedRPM { targetRPM = calculatedRPM }
        setStatus("\(Int(currentSensorTemp))°C → \(calculatedRPM) RPM")

        if forceApply || abs(calculatedRPM - lastAppliedRPM) >= 50 {
            self.lastAppliedRPM = calculatedRPM
            sendRPMCommand(rpm: calculatedRPM)
        }
    }

    func selectControlMode(_ mode: FanControlMode) {
        self.controlMode = mode
    }

    private func applyModeChange() {
        guard hasFans else { return }
        switch controlMode {
        case .auto:
            self.statusText = "Auto"
            self.lastAppliedRPM = -1
            if !isForegroundPolling { stopMonitoring() }  // nothing to watch while the panel is closed
            sendAutoCommand()
        case .curve:
            self.lastAppliedRPM = -1
            // Keep whichever cadence is active; start the slow loop if nothing is polling yet.
            schedulePolling(foreground: isForegroundPolling)
            updateCurveCalculation(forceApply: true)
        case .constant:
            self.statusText = "\(targetRPM) RPM"
            self.lastAppliedRPM = targetRPM
            if !isForegroundPolling { stopMonitoring() }
            sendRPMCommand(rpm: targetRPM)
        }
    }

    func selectPreset(_ preset: ConstantPreset) {
        self.selectedPreset = preset
        self.controlMode = .constant

        let span = Double(maxRPM - minRPM)
        let rpm: Int
        switch preset {
        case .quiet: rpm = minRPM
        case .balanced: rpm = minRPM + Int(span * 0.25)
        case .boost: rpm = minRPM + Int(span * 0.60)
        case .max: rpm = maxRPM
        }

        setCustomRPM(rpm)
    }

    func setCustomRPM(_ rpm: Int) {
        self.targetRPM = min(max(rpm, minRPM), maxRPM)
        UserDefaults.standard.set(self.targetRPM, forKey: Keys.targetRPM)
        self.controlMode = .constant
        self.statusText = "\(targetRPM) RPM"
        self.lastAppliedRPM = targetRPM
        sendRPMCommand(rpm: targetRPM)
    }

    private func sendRPMCommand(rpm: Int) {
        self.isApplying = true
        Task {
            let success = await helper.setFanSpeed(rpm: rpm)
            if !success && self.controlMode != .auto {
                self.controlMode = .auto
            }
            self.isApplying = false
            self.updateFanSpeed()
        }
    }

    private func sendAutoCommand() {
        self.isApplying = true
        Task {
            _ = await helper.setAuto()
            self.isApplying = false
            self.updateFanSpeed()
        }
    }

    private func updateStatusText() {
        if !hasFans {
            statusText = "No Fans"
            return
        }
        switch controlMode {
        case .auto:
            statusText = "Auto"
        case .curve:
            statusText = "\(Int(currentSensorTemp))°C → \(targetRPM) RPM"
        case .constant:
            statusText = "\(targetRPM) RPM"
        }
    }

    var fanDisplayShort: String {
        if !hasFans {
            return "No Fans"
        }
        if controlMode == .auto {
            return currentRPM > 0 ? "\(currentRPM)" : "Auto"
        }
        return "\(currentRPM)"
    }

    var curveProgressRatio: Double {
        let tMin = Double(curveStartTemp)
        let tMax = Double(max(curveMaxTemp, curveStartTemp + 5))
        if currentSensorTemp <= tMin { return 0.0 }
        if currentSensorTemp >= tMax { return 1.0 }
        return (currentSensorTemp - tMin) / (tMax - tMin)
    }
}
