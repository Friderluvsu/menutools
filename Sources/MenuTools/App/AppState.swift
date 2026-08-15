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

    private var cancellables = Set<AnyCancellable>()

    init(previewMode: Bool = false) {
        converter = MediaConverterManager(requestNotifications: !previewMode)
        if let modeRaw = UserDefaults.standard.string(forKey: "StatusDisplayMode"),
            let mode = StatusItemDisplayMode(rawValue: modeRaw)
        {
            self.statusDisplayMode = mode
        }

        checkLaunchAtLogin()

        // Forward changes from sub-managers to trigger menu bar icon updates
        antiSleep.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)
        network.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)

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
}
