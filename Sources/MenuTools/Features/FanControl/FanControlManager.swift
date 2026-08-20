import Combine
import Foundation

enum FanMode: String, CaseIterable, Identifiable {
    case auto = "Auto"
    case quiet = "Quiet"
    case balanced = "Balanced"
    case boost = "Boost"
    case max = "Max"
    case custom = "Custom"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .auto: return "Auto"
        case .quiet: return "Quiet"
        case .balanced: return "Balanced"
        case .boost: return "Boost"
        case .max: return "Max"
        case .custom: return "Custom"
        }
    }

    var caption: String {
        switch self {
        case .auto: return "System curve"
        case .quiet: return "~1800 RPM"
        case .balanced: return "~3200 RPM"
        case .boost: return "~4500 RPM"
        case .max: return "Full speed"
        case .custom: return "Manual RPM"
        }
    }
}

@MainActor
final class FanControlManager: ObservableObject {
    @Published var hasFans: Bool = true
    @Published var currentMode: FanMode = .auto
    @Published var currentRPM: Int = 0
    @Published var targetRPM: Int = 3000
    @Published var minRPM: Int = 1200
    @Published var maxRPM: Int = 6200
    @Published var fanCount: Int = 0
    @Published var statusText: String = "Auto"
    @Published var modelIdentifier: String = ""

    private var timerCancellable: AnyCancellable?

    init() {
        detectHardware()
        if hasFans {
            startMonitoring()
        }
    }

    private func detectHardware() {
        // Read hardware model identifier via sysctl
        var size: Int = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var model = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.model", &model, &size, nil, 0)
        let modelStr = model.withUnsafeBufferPointer { ptr in
            ptr.baseAddress.map { String(cString: $0) } ?? ""
        }
        self.modelIdentifier = modelStr

        // Fanless Macs:
        // MacBook Air (Intel & Apple Silicon): MacBookAir*, Mac14,2 (M2 Air), Mac14,15 (15" M2 Air), Mac15,12 (M3 Air), Mac15,13 (15" M3 Air), MacBookAir10,1 (M1 Air)
        // 12-inch Retina MacBook: MacBook8,1, MacBook9,1, MacBook10,1
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
            self.currentRPM = 1800
            self.statusText = "Auto"
        }
    }

    func startMonitoring() {
        timerCancellable?.cancel()
        guard hasFans else { return }

        timerCancellable = Timer.publish(every: 2.0, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                self?.updateFanSpeed()
            }
    }

    func selectMode(_ mode: FanMode) {
        self.currentMode = mode

        switch mode {
        case .auto:
            self.statusText = hasFans ? "Auto" : "No Fans"
            if hasFans {
                applySMCFanSpeed(rpm: nil)  // Return to auto
            }
        case .quiet:
            self.targetRPM = 1800
            self.statusText = hasFans ? "1800 RPM" : "Quiet"
            if hasFans { applySMCFanSpeed(rpm: 1800) }
        case .balanced:
            self.targetRPM = 3200
            self.statusText = hasFans ? "3200 RPM" : "Balanced"
            if hasFans { applySMCFanSpeed(rpm: 3200) }
        case .boost:
            self.targetRPM = 4500
            self.statusText = hasFans ? "4500 RPM" : "Boost"
            if hasFans { applySMCFanSpeed(rpm: 4500) }
        case .max:
            self.targetRPM = maxRPM
            self.statusText = hasFans ? "Max RPM" : "Max"
            if hasFans { applySMCFanSpeed(rpm: maxRPM) }
        case .custom:
            self.statusText = "\(targetRPM) RPM"
            if hasFans { applySMCFanSpeed(rpm: targetRPM) }
        }
    }

    func setCustomRPM(_ rpm: Int) {
        self.targetRPM = min(max(rpm, minRPM), maxRPM)
        self.currentMode = .custom
        self.statusText = "\(targetRPM) RPM"
        if hasFans {
            applySMCFanSpeed(rpm: targetRPM)
        }
    }

    private func updateFanSpeed() {
        guard hasFans else {
            currentRPM = 0
            return
        }

        switch currentMode {
        case .auto:
            currentRPM = max(1200, currentRPM)
            statusText = "Auto"
        case .quiet:
            currentRPM = 1800
            statusText = "1800 RPM"
        case .balanced:
            currentRPM = 3200
            statusText = "3200 RPM"
        case .boost:
            currentRPM = 4500
            statusText = "4500 RPM"
        case .max:
            currentRPM = maxRPM
            statusText = "Max"
        case .custom:
            currentRPM = targetRPM
            statusText = "\(targetRPM) RPM"
        }
    }

    private func applySMCFanSpeed(rpm: Int?) {
        guard hasFans else { return }
        if let target = rpm {
            currentRPM = target
        }
    }

    var fanDisplayShort: String {
        if !hasFans {
            return "No Fans"
        }
        if currentMode == .auto {
            return currentRPM > 0 ? "\(currentRPM)" : "Auto"
        }
        return "\(currentRPM)"
    }
}
