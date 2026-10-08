import Combine
import Foundation
import ServiceManagement
import SwiftUI

enum UnifiedTab: String, CaseIterable, Identifiable {
    case components = "Dashboard"
    case features = "Tools"

    var id: String { rawValue }
    var icon: String {
        switch self {
        case .components: return "square.grid.2x2.fill"
        case .features: return "list.bullet"
        }
    }
}

enum MenuBarIconStyle: String, CaseIterable, Identifiable {
    case batteryRing = "Battery Ring (Dynamic Color)"
    case batteryRingNumber = "Battery Ring + %"
    case batteryBar = "Battery Bar (Native macOS)"
    case batteryBarPercentage = "Battery Bar + % (Native macOS)"
    case batteryBarCharge = "Battery Bar + Charge (No %)"
    case batteryCharge = "Battery Charge (No %)"
    case batteryBarGoldenGate = "Battery Bar (macOS 27 Golden Gate)"
    case batteryBarGoldenGatePercent = "Battery Bar % Inside (macOS 27 Golden Gate)"
    case tools = "Tools"
    case cpu = "Apple Silicon CPU"
    case fan = "Cooling Fan"
    case flame = "Performance Flame"
    case bolt = "Power Lightning"
    case iceCube = "Ice Cube (Solid)"
    case iceCubeOutline = "Ice Cube (Outline)"
    case sliders = "Sliders / Controls"
    case gauge = "System Gauge"
    case terminal = "Terminal / Dev"
    case sparkles = "Sparkles"
    case dots = "Dots (Ice style)"
    case chevron = "Chevron (Ice style)"

    var id: String { rawValue }

    var isBatteryStyle: Bool {
        switch self {
        case .batteryRing,
            .batteryRingNumber,
            .batteryBar,
            .batteryBarPercentage,
            .batteryBarCharge,
            .batteryCharge,
            .batteryBarGoldenGate,
            .batteryBarGoldenGatePercent:
            return true
        default:
            return false
        }
    }

    var symbolName: String {
        switch self {
        case .batteryRing,
            .batteryRingNumber,
            .batteryBar,
            .batteryBarPercentage,
            .batteryBarCharge,
            .batteryCharge,
            .batteryBarGoldenGate,
            .batteryBarGoldenGatePercent:
            return "battery.100"
        case .tools:
            return "wrench.and.screwdriver.fill"
        case .cpu:
            return "cpu"
        case .fan:
            return "fanblades.fill"
        case .flame:
            return "flame.fill"
        case .bolt:
            return "bolt.fill"
        case .iceCube:
            return "cube.fill"
        case .iceCubeOutline:
            return "cube"
        case .sliders:
            return "slider.horizontal.3"
        case .gauge:
            return "gauge.with.needle.fill"
        case .terminal:
            return "terminal.fill"
        case .sparkles:
            return "sparkles"
        case .dots:
            return "ellipsis"
        case .chevron:
            return "chevron.left"
        }
    }
}

enum StatusItemDisplayMode: String, CaseIterable, Identifiable {
    case iconOnly = "Icon Only"
    case iconAndAntiSleep = "Icon + Anti-Sleep Timer"
    case iconAndNetworkStatus = "Icon + VPN / Spoof Status"

    var id: String { rawValue }
}

@MainActor
final class AppState: ObservableObject {
    @Published var selectedTab: UnifiedTab = .components
    @Published var statusDisplayMode: StatusItemDisplayMode = .iconOnly
    @Published var menuBarIconStyle: MenuBarIconStyle = .iceCube {
        didSet {
            UserDefaults.standard.set(menuBarIconStyle.rawValue, forKey: "MenuBarIconStyle")
            objectWillChange.send()
        }
    }
    @Published var launchAtLogin: Bool = false
    @Published var isShowingSettings: Bool = false
    @Published var isShowingSearch: Bool = false
    @Published var globalSearchQuery: String = ""

    let antiSleep = AntiSleepManager()
    let network = NetworkBypassManager()
    let clipboard = ClipboardManager()
    let iMessage = IMessageHelper()
    let converter: MediaConverterManager
    let systemMonitor = SystemMonitorManager()
    let systemUtils = SystemUtilsManager()
    let fanControl = FanControlManager()
    let battery = BatteryManager()
    let windowManager = WindowManager()
    let universalControl = UniversalControlManager()
    let aiLimits: AILimitsManager

    private var cancellables = Set<AnyCancellable>()

    init(previewMode: Bool = false) {
        converter = MediaConverterManager(requestNotifications: !previewMode)
        aiLimits = AILimitsManager(previewMode: previewMode)
        if let modeRaw = UserDefaults.standard.string(forKey: "StatusDisplayMode"),
            let mode = StatusItemDisplayMode(rawValue: modeRaw)
        {
            self.statusDisplayMode = mode
        }

        if let iconRaw = UserDefaults.standard.string(forKey: "MenuBarIconStyle") {
            if let style = MenuBarIconStyle(rawValue: iconRaw) {
                self.menuBarIconStyle = style
            } else if iconRaw == "Battery Bar" {
                self.menuBarIconStyle = .batteryBar
            } else if iconRaw == "Battery Bar + %" {
                self.menuBarIconStyle = .batteryBarPercentage
            } else if iconRaw == "Battery Bar + Charge" || iconRaw == "Battery Bar + Charge (Native macOS)" || iconRaw == "Battery Bar + Charge (No %)" {
                self.menuBarIconStyle = .batteryBarCharge
            } else if iconRaw == "Battery Charge" || iconRaw == "Battery Charge (No %)" || iconRaw == "Battery Level" || iconRaw == "Battery (No %)" {
                self.menuBarIconStyle = .batteryCharge
            } else if iconRaw == "Battery Bar (Golden Gate)" || iconRaw == "Golden Gate" {
                self.menuBarIconStyle = .batteryBarGoldenGate
            } else if iconRaw == "Battery Bar % Inside"
                || iconRaw == "Golden Gate %"
                || iconRaw == "Battery Bar (macOS 27 Golden Gate) %"
            {
                self.menuBarIconStyle = .batteryBarGoldenGatePercent
            } else if iconRaw == "Ice Cube (Ice default)" {
                self.menuBarIconStyle = .iceCube
            } else if iconRaw == "Ice Outline" {
                self.menuBarIconStyle = .iceCubeOutline
            } else if iconRaw == "Dots (Ice)" {
                self.menuBarIconStyle = .dots
            } else if iconRaw == "Chevron (Ice)" {
                self.menuBarIconStyle = .chevron
            }
        }

        checkLaunchAtLogin()

        // Forward changes that drive the menu bar icon / title (AppDelegate) and Settings.
        // Dashboard sections observe their own managers; fan / monitor / converter ticks are not forwarded.
        antiSleep.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)
        network.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)
        battery.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)
        windowManager.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)
        universalControl.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)

        ClipboardHUDWindowController.shared.setup(clipboardManager: clipboard)
    }

    func setStatusDisplayMode(_ mode: StatusItemDisplayMode) {
        self.statusDisplayMode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: "StatusDisplayMode")
    }

    func toggleLaunchAtLogin() {
        if #available(macOS 13.0, *) {
            do {
                if launchAtLogin {
                    try SMAppService.mainApp.unregister()
                    launchAtLogin = false
                } else {
                    try SMAppService.mainApp.register()
                    launchAtLogin = true
                }
            } catch {
                print("Launch at login error: \(error)")
            }
        }
    }

    private func checkLaunchAtLogin() {
        if #available(macOS 13.0, *) {
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }

    var menuBarTitle: String {
        switch statusDisplayMode {
        case .iconOnly:
            return ""
        case .iconAndAntiSleep:
            if antiSleep.isActive {
                return " ☕️ \(antiSleep.statusText)"
            }
            return ""
        case .iconAndNetworkStatus:
            let vpn = network.isVPNConnected ? "🟢 VPN" : "🔴 VPN"
            let spoof = network.isSpoofDPIRunning ? "🟢 Spoof" : "🔴 Spoof"
            return " \(vpn) | \(spoof)"
        }
    }

    func onPopoverWillShow() {
        systemMonitor.startMonitoring()
        network.startPolling()
        fanControl.startMonitoring()
        battery.refreshBatteryState()
        windowManager.refreshPermissions()
        aiLimits.startMonitoring()
    }

    func onPopoverDidClose() {
        systemMonitor.stopMonitoring()
        network.stopPolling()
        aiLimits.stopMonitoring()
        // Curve mode keeps a slow 5s loop; other modes stop polling.
        fanControl.enterBackground()
    }
}
