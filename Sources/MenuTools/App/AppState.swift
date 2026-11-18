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

/// Counts behind the menu bar ring. Idle sessions are left out.
struct SessionMenuMarks: Equatable {
    var inputCount = 0
    var runningCount = 0
    var endedCount = 0

    var needsInput: Bool { inputCount > 0 }
    var running: Bool { runningCount > 0 }
    var endedUnseen: Bool { endedCount > 0 }
    var isQuiet: Bool { inputCount == 0 && runningCount == 0 && endedCount == 0 }

    var tooltip: String {
        var parts: [String] = []
        if inputCount > 0 { parts.append("\(inputCount) need input") }
        if runningCount > 0 { parts.append("\(runningCount) running") }
        if endedCount > 0 { parts.append("\(endedCount) ended") }
        return parts.joined(separator: ", ")
    }
}

extension Notification.Name {
    /// Posted after a session refresh has stored its rows. The menu bar ring paints from this, with the panel closed.
    static let sessionMenuMarksChanged = Notification.Name("MenuToolsSessionMenuMarksChanged")
}

@MainActor
final class AppState: ObservableObject {
    @Published var selectedTab: UnifiedTab = .components
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

    let antiSleep: AntiSleepManager
    let network = NetworkBypassManager()
    let clipboard = ClipboardManager()
    let iMessage = IMessageHelper()
    let converter: MediaConverterManager
    let systemMonitor = SystemMonitorManager()
    let systemUtils = SystemUtilsManager()
    let fanControl = FanControlManager()
    let battery = BatteryManager()
    let windowManager = WindowManager()
    let mouse: MouseManager
    let universalControl = UniversalControlManager()
    let aiLimits: AILimitsManager
    let claudeSessions: ClaudeSessionsManager
    let cursorSessions: CursorSessionsManager
    let codexSessions: CodexSessionsManager
    let antigravitySessions: AntigravitySessionsManager
    private let previewMode: Bool
    lazy var restMode = RestModeManager(battery: battery, previewMode: previewMode)
    /// Sleep when done and Wake me when done.
    lazy var afterDone = AfterDoneManager(app: self, previewMode: previewMode)
    private var teraxLink: TeraxLinkServer?
    private var teraxLinkRetry: DispatchSourceTimer?

    private var cancellables = Set<AnyCancellable>()

    init(previewMode: Bool = false) {
        self.previewMode = previewMode
        // Preview renders must never take power assertions or touch pmset.
        antiSleep = AntiSleepManager(previewMode: previewMode)
        mouse = MouseManager(previewMode: previewMode)
        converter = MediaConverterManager(requestNotifications: !previewMode)
        aiLimits = AILimitsManager(previewMode: previewMode)
        claudeSessions = ClaudeSessionsManager(previewMode: previewMode)
        cursorSessions = CursorSessionsManager(previewMode: previewMode)
        codexSessions = CodexSessionsManager(previewMode: previewMode)
        antigravitySessions = AntigravitySessionsManager(previewMode: previewMode)
        if let iconRaw = UserDefaults.standard.string(forKey: "MenuBarIconStyle") {
            if let style = MenuBarIconStyle(rawValue: iconRaw) {
                self.menuBarIconStyle = style
            } else if iconRaw == "Battery Bar" {
                self.menuBarIconStyle = .batteryBar
            } else if iconRaw == "Battery Bar + %" {
                self.menuBarIconStyle = .batteryBarPercentage
            } else if iconRaw == "Battery Bar + Charge" || iconRaw == "Battery Bar + Charge (Native macOS)"
                || iconRaw == "Battery Bar + Charge (No %)"
            {
                self.menuBarIconStyle = .batteryBarCharge
            } else if iconRaw == "Battery Charge" || iconRaw == "Battery Charge (No %)" || iconRaw == "Battery Level"
                || iconRaw == "Battery (No %)"
            {
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
        // Anti-Sleep is not forwarded either: its countdown publishes every second, which would rebuild
        // Settings while it is open. AppDelegate and the tiles observe it directly.
        network.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)
        battery.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)
        windowManager.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)
        universalControl.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(
            in: &cancellables)
        // Session managers are not forwarded: they publish every 2 s while a session is live, and
        // everything observing AppState (Settings, the header) would rebuild with them. The menu bar
        // follows them through `sessionMenuMarksChanged`; dashboard sections observe them directly.

        ClipboardHUDWindowController.shared.setup(clipboardManager: clipboard)
        if !previewMode {
            systemMonitor.startHistorySampling()
            startTeraxLink()
        }
    }

    /// Terax phone access reads sessions, stats and power state through this socket. On unless
    /// `defaults write com.frider.MenuTools TeraxLinkEnabled -bool false`.
    private func startTeraxLink() {
        guard UserDefaults.standard.object(forKey: "TeraxLinkEnabled") as? Bool ?? true else { return }
        let service = TeraxLinkService(app: self)
        let server = TeraxLinkServer { line in await service.handle(line) }
        if (try? server.start()) != nil {
            teraxLink = server
            teraxLinkRetry?.cancel()
            teraxLinkRetry = nil
            return
        }
        // Another instance holds the socket (a dev build next to the installed app): try again
        // every 30 s until it quits, instead of staying without a link until relaunch.
        guard teraxLinkRetry == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 30, repeating: 30, leeway: .seconds(5))
        timer.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.startTeraxLink() }
        }
        timer.resume()
        teraxLinkRetry = timer
    }

    /// Synchronous, for app termination.
    func stopTeraxLink() {
        teraxLink?.stop()
        teraxLink = nil
        teraxLinkRetry?.cancel()
        teraxLinkRetry = nil
        restMode.prepareForTermination()
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

    var hasSessionAlert: Bool {
        claudeSessions.hasUnseenFinished || cursorSessions.hasUnseenEnded || codexSessions.hasUnseenEnded
            || antigravitySessions.hasUnseenEnded
    }

    /// True while the Sessions page is the page on screen. The dashboard summary is not.
    var sessionsPageVisible = false

    enum PanelPage { case dashboard, sessions }
    /// Which page the panel should show, sent by the status item that was clicked (the Sessions
    /// item opens Sessions, the main icon the dashboard). The panel view listens; nothing observes.
    let panelPageRequests = PassthroughSubject<PanelPage, Never>()

    /// Live + ended rows across the four providers. Above this, the dashboard shows a summary.
    var sessionRowCount: Int {
        claudeSessions.sessions.count + cursorSessions.sessions.count + cursorSessions.ended.count
            + codexSessions.sessions.count + codexSessions.ended.count + antigravitySessions.sessions.count
            + antigravitySessions.ended.count
    }

    /// Terax focused the pane whose shell is `shell`: finished sessions under it count as checked.
    /// Opening the panel never checks anything; only explicit actions do.
    @discardableResult
    func checkSessions(underShell shell: pid_t) -> Int {
        claudeSessions.check(underShell: shell)
    }

    /// Menu bar ring. A session that is waiting counts as input, not also as running.
    var sessionMarks: SessionMenuMarks {
        var marks = SessionMenuMarks()
        func add(needsInput: Bool, isRunning: Bool) {
            if needsInput {
                marks.inputCount += 1
            } else if isRunning {
                marks.runningCount += 1
            }
        }
        for session in claudeSessions.sessions {
            add(needsInput: session.needsInput, isRunning: session.isWorking)
        }
        for session in cursorSessions.sessions {
            add(needsInput: session.needsInput, isRunning: session.status == "running")
        }
        for _ in codexSessions.sessions {
            add(needsInput: false, isRunning: true)
        }
        for session in antigravitySessions.sessions {
            add(needsInput: session.needsInput, isRunning: session.status == "running")
        }
        marks.endedCount =
            claudeSessions.finished.values.filter { !$0.seen }.count
            + cursorSessions.ended.filter { !$0.seen }.count + codexSessions.ended.filter { !$0.seen }.count
            + antigravitySessions.ended.filter { !$0.seen }.count
        return marks
    }

    /// Before the first layout: only what the first frame needs and what is cheap (under 2 ms).
    func onPopoverWillShow() {
        systemMonitor.startMonitoring()
        network.startPolling()
        battery.refreshBatteryState()
    }

    /// After the window is on screen: the session scans, SMC and permission reads (20–70 ms together)
    /// would otherwise sit between the click and the first frame. Rows are at most one background
    /// tick old at that point; a new one grows the panel from its bottom edge a frame later.
    func onPopoverDidShow() {
        func t(_ label: String, _ body: () -> Void) { PanelOpenDiagnose.measure(label, body) }
        t("fan") { fanControl.startMonitoring() }
        t("window") { windowManager.refreshPermissions() }
        t("mouse") { mouse.refreshPermissions() }
        t("limits") { aiLimits.startMonitoring() }
        t("claude") { claudeSessions.startMonitoring() }
        t("cursor") { cursorSessions.startMonitoring() }
        t("codex") { codexSessions.startMonitoring() }
        t("antigravity") { antigravitySessions.startMonitoring() }
        afterDone.panelOpened()
    }

    func onPopoverDidClose() {
        mouse.cancelCapture()
        systemMonitor.stopMonitoring()
        network.stopPolling()
        aiLimits.stopMonitoring()
        claudeSessions.stopMonitoring()
        cursorSessions.stopMonitoring()
        codexSessions.stopMonitoring()
        antigravitySessions.stopMonitoring()
        // Curve mode keeps a slow 5s loop; other modes stop polling.
        fanControl.enterBackground()
    }
}
