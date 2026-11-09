import AppKit
import SwiftUI

/// Panel root. Holds only page / picker / toast state and does not observe AppState:
/// every section below observes its own manager, so a CPU tick never re-renders the converter.
/// The panel is sized to the reported content height (no scrolling on the dashboard).
struct PopoverContentView: View {
    let appState: AppState
    var onHeightChange: (@MainActor (CGFloat) -> Void)?
    @State private var copiedNotice: String?
    @State private var toastToken = 0
    @State private var showSettings: Bool
    @State private var showSessions: Bool
    /// Visual fade only. Kept separate from layout so the panel height does not slide.
    @State private var sessionsOpacity: Double = 0
    @State private var settingsOpacity: Double = 0
    @State private var statTopic: StatTopic?
    @State private var showStat: Bool
    @State private var statOpacity: Double = 0
    @State private var showAntiSleepPicker: Bool
    @State private var antiSleepPickerMode: AntiSleepManager.Mode = .awake
    @State private var visibleHeight: CGFloat = 0
    @State private var dashboardHeight: CGFloat = 0
    @State private var sessionsHeight: CGFloat = 0
    @State private var statHeights: [String: CGFloat] = [:]
    @State private var settingsHeight: CGFloat = 0
    @State private var pageHeight: CGFloat = 0
    @State private var sessionsMounted = false
    @State private var settingsMounted = false
    @State private var statMounted = false
    @State private var settingsFadeToken = 0
    @StateObject private var sessionDetails: SessionDetailSelection

    init(
        appState: AppState,
        showSettings: Bool = false,
        showSessions: Bool = false,
        showStat: StatTopic? = nil,
        showAntiSleepPicker: Bool = false,
        antiSleepPickerMode: AntiSleepManager.Mode = .awake,
        openSessionDetail: String? = nil,
        onHeightChange: (@MainActor (CGFloat) -> Void)? = nil
    ) {
        self.appState = appState
        self.onHeightChange = onHeightChange
        _sessionDetails = StateObject(wrappedValue: SessionDetailSelection(openID: openSessionDetail))
        _showSettings = State(initialValue: showSettings)
        _showSessions = State(initialValue: showSessions)
        _sessionsMounted = State(initialValue: showSessions)
        _sessionsOpacity = State(initialValue: showSessions ? 1 : 0)
        _settingsMounted = State(initialValue: showSettings)
        _settingsOpacity = State(initialValue: showSettings ? 1 : 0)
        _statTopic = State(initialValue: showStat)
        _showStat = State(initialValue: showStat != nil)
        _statMounted = State(initialValue: showStat != nil)
        _statOpacity = State(initialValue: showStat != nil ? 1 : 0)
        _showAntiSleepPicker = State(initialValue: showAntiSleepPicker)
        _antiSleepPickerMode = State(initialValue: antiSleepPickerMode)
    }

    var body: some View {
        ThemeHost { panel }
    }

    private var panel: some View {
        VStack(spacing: 0) {
            PanelHeader(
                appState: appState,
                systemUtils: appState.systemUtils,
                isSettings: showSettings,
                isSessions: showSessions && !showSettings && !showStat,
                statTitle: showStat ? statTopic?.title : nil,
                onTrailing: handleHeaderTrailing
            )
            .animation(nil, value: showSessions)
            .animation(nil, value: showSettings)
            .animation(nil, value: showStat)
            Divider().opacity(0.35)

            settingsCrossfade
        }
        .environmentObject(sessionDetails)
        .fixedSize(horizontal: false, vertical: true)
        .reportsPanelHeight()
        .frame(width: MacToolsTheme.popoverWidth)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(PanelBackdrop())
        .overlay(ThemeEasterEggLayer())
        .overlay(alignment: .bottom) {
            if let copiedNotice {
                Text(copiedNotice)
                    .font(.system(size: 11, weight: .semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(.regularMaterial, in: Capsule())
                    .padding(.bottom, 8)
                    .transition(.opacity)
            }
        }
        .overlay {
            if showAntiSleepPicker {
                AntiSleepPickerOverlay(antiSleep: appState.antiSleep, mode: antiSleepPickerMode) {
                    showAntiSleepPicker = false
                }
            }
        }
        .modifier(PanelFrame())
        .onPreferenceChange(PanelHeightKey.self) { height in
            MainActor.assumeIsolated { onHeightChange?(height) }
        }
        .onAppear {
            if showSessions {
                sessionsMounted = true
                sessionsOpacity = 1
            }
            if showSettings {
                settingsMounted = true
                settingsOpacity = 1
            } else if !settingsMounted {
                // Build Settings hidden once the dashboard is on screen, so the gear click only
                // fades. Its view graph took 250–400 ms to build on the click before.
                DispatchQueue.main.asyncAfter(deadline: .now() + Self.settingsPrewarmDelay) {
                    settingsMounted = true
                }
            }
            noteSessionsPageVisible()
        }
        .onPreferenceChange(SessionPageHeightKey.self) { values in
            MainActor.assumeIsolated { applyMeasuredHeights(values) }
        }
        .onChange(of: dashboardHeight) { _, height in
            guard !showSessions, !showSettings, !showStat else { return }
            setVisibleHeight(height)
        }
        .onChange(of: sessionsHeight) { _, height in
            guard showSessions, !showSettings, !showStat else { return }
            setVisibleHeight(height)
        }
        .onChange(of: settingsHeight) { _, height in
            guard showSettings else { return }
            setPageHeight(height)
        }
    }

    /// Settings sits on top of the dashboard fade. Height is committed before the opacity changes.
    private var settingsCrossfade: some View {
        ZStack(alignment: .top) {
            sessionCrossfade
                .opacity(1 - settingsOpacity)
                .allowsHitTesting(!showSettings)

            if settingsMounted {
                SettingsTabView(appState: appState)
                    .padding(MacToolsTheme.outerPadding)
                    .fixedSize(horizontal: false, vertical: true)
                    .reportsSessionPageHeight("settings")
                    .opacity(settingsOpacity)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .allowsHitTesting(showSettings)
            }
        }
        .frame(maxWidth: .infinity, alignment: .top)
        .frame(height: pageHeight > 1 ? pageHeight : nil, alignment: .top)
        .animation(nil, value: pageHeight)
        .clipped()
    }

    private var sessionCrossfade: some View {
        ZStack(alignment: .top) {
            DashboardView(
                appState: appState,
                toast: showToast,
                openAntiSleepPicker: { mode in
                    antiSleepPickerMode = mode
                    showAntiSleepPicker = true
                },
                openFanPicker: { openStat(.fan) },
                openSessions: openSessions,
                openStat: openStat
            )
            .padding(MacToolsTheme.outerPadding)
            .fixedSize(horizontal: false, vertical: true)
            .reportsSessionPageHeight("dashboard")
            .environment(\.dashboardOnScreen, !showSessions && !showStat && !showSettings)
            .opacity(1 - max(sessionsOpacity, statOpacity))
            .animation(SessionDashboardLayout.pageAnimation, value: sessionsOpacity)
            .animation(SessionDashboardLayout.pageAnimation, value: statOpacity)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .allowsHitTesting(!showSessions && !showStat)

            if sessionsMounted {
                SessionsPage(
                    claude: appState.claudeSessions,
                    cursor: appState.cursorSessions,
                    codex: appState.codexSessions,
                    antigravity: appState.antigravitySessions,
                    stackRevealed: true,
                    onEmpty: closeSessions
                )
                .padding(MacToolsTheme.outerPadding)
                .fixedSize(horizontal: false, vertical: true)
                .reportsSessionPageHeight("sessions")
                .opacity(sessionsOpacity)
                .animation(SessionDashboardLayout.pageAnimation, value: sessionsOpacity)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .allowsHitTesting(showSessions && !showStat)
            }

            if statMounted, let statTopic {
                StatDetailPage(
                    topic: statTopic,
                    details: appState.systemMonitor.details,
                    fan: appState.fanControl,
                    battery: appState.battery
                )
                .padding(MacToolsTheme.outerPadding)
                .fixedSize(horizontal: false, vertical: true)
                .reportsSessionPageHeight("stat")
                .opacity(statOpacity)
                .animation(SessionDashboardLayout.pageAnimation, value: statOpacity)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .allowsHitTesting(showStat)
                .id(statTopic)
            }
        }
        .frame(maxWidth: .infinity, alignment: .top)
        .frame(height: visibleHeight > 1 ? visibleHeight : nil, alignment: .top)
        .animation(nil, value: visibleHeight)
        .clipped()
    }

    private func applyMeasuredHeights(_ values: [String: CGFloat]) {
        if let height = values["dashboard"], height > 1 { dashboardHeight = height }
        if let height = values["sessions"], height > 1 { sessionsHeight = height }
        if let height = values["stat"], height > 1, let topic = statTopic?.rawValue {
            statHeights[topic] = height
            if showStat, !showSettings { setVisibleHeight(height) }
        }
        if let height = values["settings"], height > 1 { settingsHeight = height }
        if visibleHeight < 1, !showSettings {
            let initial: CGFloat
            if showStat, let topic = statTopic?.rawValue, let height = statHeights[topic], height > 1 {
                initial = height
            } else if showSessions, sessionsHeight > 1 {
                initial = sessionsHeight
            } else {
                initial = dashboardHeight
            }
            setVisibleHeight(initial)
        }
        if pageHeight < 1 {
            setPageHeight(
                showSettings
                    ? (settingsHeight > 1 ? settingsHeight : dashboardHeight)
                    : (visibleHeight > 1 ? visibleHeight : dashboardHeight))
        }
    }

    /// Height changes resize the window from its top edge. Animating this frame as well
    /// makes the dashboard look like it is sliding up from the bottom.
    private func setVisibleHeight(_ height: CGFloat) {
        guard height > 1, abs(height - visibleHeight) > 0.5 else { return }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { visibleHeight = height }
        if !showSettings { setPageHeight(height) }
    }

    private func setPageHeight(_ height: CGFloat) {
        guard height > 1, abs(height - pageHeight) > 0.5 else { return }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { pageHeight = height }
    }

    private func handleHeaderTrailing() {
        resignHeaderFocus()
        if showSettings {
            setSettings(false)
        } else if showStat {
            closeStat()
        } else if showSessions {
            closeSessions()
        } else {
            setSettings(true)
            appState.iMessage.refreshPermissions()
        }
    }

    private func setSettings(_ show: Bool) {
        settingsFadeToken += 1
        let token = settingsFadeToken
        if show {
            settingsMounted = true
            if settingsHeight > 1 { setPageHeight(settingsHeight) }
        } else {
            let cached = statTopic.flatMap { statHeights[$0.rawValue] } ?? 0
            let back = showStat && cached > 1 ? cached : (showSessions ? sessionsHeight : dashboardHeight)
            if back > 1 {
                setPageHeight(back)
                setVisibleHeight(back)
            }
        }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { showSettings = show }
        noteSessionsPageVisible()
        DispatchQueue.main.async {
            guard token == settingsFadeToken else { return }
            withAnimation(SessionDashboardLayout.pageAnimation) {
                settingsOpacity = show ? 1 : 0
            }
        }
        // Closed Settings stays mounted (hidden, no hit testing), so the next open is a fade only.
    }

    /// Settings is prewarmed this long after the dashboard first appears.
    private static let settingsPrewarmDelay: TimeInterval = 0.6

    /// The Sessions page is showing, so its ended rows count as seen. The dashboard summary does not.
    private func noteSessionsPageVisible() {
        let visible = showSessions && !showSettings && !showStat
        let becameVisible = visible && !appState.sessionsPageVisible
        appState.sessionsPageVisible = visible
        if becameVisible { appState.acknowledgeEndedSessions() }
    }

    private func openSessions() {
        resignHeaderFocus()
        sessionsMounted = true
        if sessionsHeight > 1 { setVisibleHeight(sessionsHeight) }
        var layout = Transaction()
        layout.disablesAnimations = true
        withTransaction(layout) { showSessions = true }
        noteSessionsPageVisible()
        // Fade after the height has been committed, so the crossfade cannot move the panel.
        DispatchQueue.main.async {
            withAnimation(SessionDashboardLayout.pageAnimation) { sessionsOpacity = 1 }
        }
    }

    private func closeSessions() {
        resignHeaderFocus()
        if dashboardHeight > 1 { setVisibleHeight(dashboardHeight) }
        var layout = Transaction()
        layout.disablesAnimations = true
        withTransaction(layout) { showSessions = false }
        noteSessionsPageVisible()
        DispatchQueue.main.async {
            withAnimation(SessionDashboardLayout.pageAnimation) { sessionsOpacity = 0 }
        }
        // Drop the page after the fade, like the stat page, so it stops rebuilding on session ticks.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            if !showSessions { sessionsMounted = false }
        }
    }

    private func openStat(_ topic: StatTopic) {
        resignHeaderFocus()
        statTopic = topic
        statMounted = true
        appState.systemMonitor.setStatFocus(topic)
        if let height = statHeights[topic.rawValue], height > 1 { setVisibleHeight(height) }
        var layout = Transaction()
        layout.disablesAnimations = true
        withTransaction(layout) { showStat = true }
        noteSessionsPageVisible()
        DispatchQueue.main.async {
            withAnimation(SessionDashboardLayout.pageAnimation) { statOpacity = 1 }
        }
    }

    private func closeStat() {
        resignHeaderFocus()
        appState.systemMonitor.setStatFocus(nil)
        if dashboardHeight > 1 { setVisibleHeight(dashboardHeight) }
        var layout = Transaction()
        layout.disablesAnimations = true
        withTransaction(layout) { showStat = false }
        noteSessionsPageVisible()
        DispatchQueue.main.async {
            withAnimation(SessionDashboardLayout.pageAnimation) { statOpacity = 0 }
        }
        // Drop the page after the fade so its 2 s snapshot updates do not keep rendering.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            if !showStat { statMounted = false }
        }
    }

    private func resignHeaderFocus() {
        NSApp.keyWindow?.makeFirstResponder(nil)
    }

    private func showToast(_ text: String) {
        toastToken += 1
        let token = toastToken
        withAnimation(.easeOut(duration: 0.12)) { copiedNotice = text }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            guard token == toastToken else { return }
            withAnimation(.easeIn(duration: 0.12)) { copiedNotice = nil }
        }
    }
}

// MARK: - Header

/// Title + system actions as icon buttons. Follows only the icon style (not all of AppState, which
/// republishes on every session and battery tick).
private struct PanelHeader: View {
    @Environment(\.appTheme) private var theme
    let appState: AppState
    @State private var iconSymbol: String?
    @ObservedObject var systemUtils: SystemUtilsManager
    let isSettings: Bool
    let isSessions: Bool
    var statTitle: String?
    let onTrailing: () -> Void
    @State private var secretTaps: [Date] = []

    private var showsBack: Bool { isSettings || isSessions || statTitle != nil }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: iconSymbol ?? appState.menuBarIconStyle.symbolName)
                .font(.system(size: 11, weight: .regular))
                .foregroundStyle(theme.isFeatured ? AnyShapeStyle(.secondary) : AnyShapeStyle(theme.accent))
                .frame(width: 22, height: 22)
                .background(theme.accent.opacity(0.1), in: RoundedRectangle(cornerRadius: theme.radius(6)))
                .contentShape(Rectangle())
                .onTapGesture(perform: countSecretTap)

            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .italic(theme.titleItalic && !showsBack)
                .tracking(showsBack ? 0 : theme.titleTracking)
                .lineLimit(1)

            Spacer(minLength: 6)

            if !showsBack {
                Group {
                    if systemUtils.isActionRunning {
                        ProgressView().controlSize(.mini)
                    }
                    HeaderIconButton(symbol: "eject", help: "Eject disks") { systemUtils.ejectAllDisks() }
                    HeaderIconButton(symbol: "trash", help: "Empty Trash") { systemUtils.emptyTrash() }
                }
                .transition(.opacity)
            }
            HeaderIconButton(
                symbol: showsBack ? "xmark" : "gearshape",
                help: showsBack ? "Back" : "Settings",
                action: onTrailing
            )
            .id(showsBack ? "back" : "settings")
        }
        .padding(.horizontal, MacToolsTheme.outerPadding + 2)
        .frame(height: 34)
        .onReceive(appState.$menuBarIconStyle.removeDuplicates()) { style in
            if iconSymbol != style.symbolName { iconSymbol = style.symbolName }
        }
    }

    private var title: String {
        if isSettings { return "Settings" }
        if let statTitle { return statTitle }
        if isSessions { return "Sessions" }
        return theme.title
    }

    /// Five quick clicks on the header icon play the theme's easter egg.
    private func countSecretTap() {
        let now = Date()
        secretTaps = secretTaps.filter { now.timeIntervalSince($0) < 2 } + [now]
        if secretTaps.count >= 5 {
            secretTaps = []
            ThemeManager.shared.playEasterEgg()
        }
    }
}

/// Panel background: material and/or theme gradient plus the static texture.
private struct PanelBackdrop: View {
    @Environment(\.appTheme) private var theme

    var body: some View {
        ThemeBackdrop(theme: theme)
    }
}

/// Outer clip and hairline in the theme's corner and stroke colour.
private struct PanelFrame: ViewModifier {
    @Environment(\.appTheme) private var theme

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: max(4, theme.radius(14)), style: .continuous)
        content
            .clipShape(shape)
            .overlay(shape.stroke(theme.panelStroke, lineWidth: theme.isFeatured ? 0.5 : 1))
    }
}

private struct HeaderIconButton: View {
    @Environment(\.appTheme) private var theme
    let symbol: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .regular))
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 22)
                .background(theme.controlFill, in: RoundedRectangle(cornerRadius: theme.radius(6)))
                .contentShape(Rectangle())
                .hoverHighlight(cornerRadius: 6)
        }
        .buttonStyle(.plain)
        .suppressesFocusRing()
        .help(help)
    }
}

// MARK: - Dashboard

/// Sections render in the user's order (Settings → Look → Layout); hidden ones are skipped.
/// Observes only the layout store, which changes when the user rearranges.
private struct DashboardView: View {
    let appState: AppState
    let toast: (String) -> Void
    let openAntiSleepPicker: (AntiSleepManager.Mode) -> Void
    let openFanPicker: () -> Void
    let openSessions: () -> Void
    let openStat: (StatTopic) -> Void
    @ObservedObject private var layout = DashboardLayoutStore.shared

    var body: some View {
        VStack(spacing: MacToolsTheme.sectionSpacing) {
            ForEach(layout.visible) { section in
                view(for: section)
            }
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func view(for section: DashboardSection) -> some View {
        switch section {
        case .metrics:
            MetricsCard(
                monitor: appState.systemMonitor,
                fanControl: appState.fanControl,
                battery: appState.battery,
                openFanPicker: openFanPicker,
                openStat: openStat,
                toast: toast
            )
        case .aiLimits:
            AILimitsCard(manager: appState.aiLimits)
        case .sessions:
            DashboardSessionsSection(
                claude: appState.claudeSessions,
                cursor: appState.cursorSessions,
                codex: appState.codexSessions,
                antigravity: appState.antigravitySessions,
                openSessions: openSessions
            )
        case .toggles:
            HStack(spacing: MacToolsTheme.sectionSpacing) {
                AntiSleepToggle(antiSleep: appState.antiSleep) { openAntiSleepPicker(.awake) }
                ClosedLidToggle(antiSleep: appState.antiSleep) { openAntiSleepPicker(.lid) }
                LowPowerToggle(battery: appState.battery)
                VPNToggle(network: appState.network, monitor: appState.systemMonitor)
                SpoofToggle(network: appState.network, monitor: appState.systemMonitor)
            }
        case .converter:
            ConverterCard(converter: appState.converter)
        case .shelf:
            ShelfSection(shelf: ShelfManager.shared)
        case .clipboard:
            ClipboardCard(clipboard: appState.clipboard, toast: toast)
        }
    }
}

// MARK: - Metrics

private struct MetricsCard: View {
    @ObservedObject var monitor: SystemMonitorManager
    let fanControl: FanControlManager
    let battery: BatteryManager
    let openFanPicker: () -> Void
    let openStat: (StatTopic) -> Void
    let toast: (String) -> Void

    var body: some View {
        MacToolsCard(padding: 6) {
            VStack(spacing: 4) {
                HStack(spacing: 4) {
                    MetricButton(title: "CPU", value: "\(Int(monitor.cpuUsage.rounded()))%", help: "CPU details") {
                        openStat(.cpu)
                    }
                    MetricButton(title: "GPU", value: gpuText, help: "GPU details") { openStat(.gpu) }
                    MetricButton(
                        title: "RAM", value: String(format: "%.1fG", monitor.memoryUsedGB),
                        help: String(format: "%.1f of %.0f GB", monitor.memoryUsedGB, monitor.memoryTotalGB)
                    ) { openStat(.memory) }
                }
                HStack(spacing: 4) {
                    MetricButton(
                        title: "TEMP", value: "\(Int(monitor.cpuTemperature.rounded()))°C", help: "Temperature"
                    ) { openStat(.temperature) }
                    MetricButton(
                        title: "NET",
                        value: "↓\(Self.speed(monitor.downloadSpeedKBps)) ↑\(Self.speed(monitor.uploadSpeedKBps))",
                        help:
                            "Down \(Self.speed(monitor.downloadSpeedKBps))B/s · Up \(Self.speed(monitor.uploadSpeedKBps))B/s"
                    ) { openStat(.network) }
                    BatteryMetricButton(battery: battery) { openStat(.battery) }
                }
                diskRow
                HStack(spacing: 4) {
                    IPButton(label: "LAN", value: monitor.localIP) { copy(monitor.localIP, "LAN copied") }
                    IPButton(label: "WAN", value: monitor.publicIP) { copy(monitor.publicIP, "WAN copied") }
                }
            }
        }
    }

    private var gpuText: String {
        guard let usage = monitor.gpuUsage else { return "—" }
        return "\(Int(usage.rounded()))%"
    }

    /// Fan keeps one column. Disk uses the other two so the free-space figure fits.
    private var diskRow: some View {
        GeometryReader { proxy in
            let gap: CGFloat = 4
            let third = max(0, (proxy.size.width - gap) / 3)
            HStack(spacing: gap) {
                FanTile(fanControl: fanControl, action: openFanPicker)
                    .frame(width: third)
                MetricButton(title: "DISK", value: diskText, help: diskHelp, tint: diskTint) {
                    openStat(.disk)
                }
                .frame(width: third * 2)
            }
        }
        .frame(height: 24)
    }

    private var diskText: String {
        guard let percent = monitor.diskUsedPercent else { return "—" }
        return "\(Int(percent.rounded()))% · \(StatFormat.bytes(monitor.diskFreeBytes)) free"
    }

    private var diskHelp: String {
        guard monitor.diskUsedPercent != nil, monitor.diskTotalBytes > 0 else { return "Disk" }
        let name = monitor.diskName.isEmpty ? "Disk" : monitor.diskName
        let used = monitor.diskTotalBytes > monitor.diskFreeBytes ? monitor.diskTotalBytes - monitor.diskFreeBytes : 0
        return "\(name) · \(StatFormat.bytes(used)) of \(StatFormat.bytes(monitor.diskTotalBytes))"
    }

    private var diskTint: Color? {
        (monitor.diskUsedPercent ?? 0) >= 90 ? .orange : nil
    }

    private func copy(_ value: String, _ notice: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
        toast(notice)
    }

    /// "80K", "1.2M", "12M".
    static func speed(_ kilobytesPerSecond: Double) -> String {
        if kilobytesPerSecond >= 10 * 1024 { return String(format: "%.0fM", kilobytesPerSecond / 1024) }
        if kilobytesPerSecond >= 1000 { return String(format: "%.1fM", kilobytesPerSecond / 1024) }
        return String(format: "%.0fK", kilobytesPerSecond)
    }
}

private struct MetricButton: View {
    let title: String
    let value: String
    var help: String?
    var tint: Color?
    var accessory: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            MetricTile(title: title, value: value, help: help, tint: tint, accessory: accessory)
                .hoverHighlight(cornerRadius: 6)
        }
        .buttonStyle(.plain)
        .suppressesFocusRing()
    }
}

private struct MetricTile: View {
    @Environment(\.appTheme) private var theme
    let title: String
    let value: String
    var help: String?
    var tint: Color?
    var accessory: String?

    var body: some View {
        HStack(spacing: 3) {
            Text(title)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(tint ?? .secondary)
            Spacer(minLength: 2)
            if let accessory {
                Image(systemName: accessory)
                    .font(.system(size: 8.5, weight: .semibold))
                    .foregroundStyle(tint ?? .secondary)
            }
            Text(value)
                .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                .foregroundStyle(tint ?? .primary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .padding(.horizontal, 7)
        .frame(maxWidth: .infinity, minHeight: 24, maxHeight: 24)
        .background(
            tint.map { $0.opacity(0.10) } ?? theme.tileFill,
            in: RoundedRectangle(cornerRadius: theme.radius(6), style: .continuous)
        )
        .contentShape(Rectangle())
        .help(help ?? "")
    }
}

private struct FanTile: View {
    @Environment(\.appTheme) private var theme
    @ObservedObject var fanControl: FanControlManager
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            MetricTile(
                title: "FAN",
                value: fanControl.hasFans ? fanControl.fanDisplayShort : "—",
                help: fanControl.hasFans ? "Fan: \(fanControl.statusText)" : "No fans",
                tint: fanControl.hasFans ? theme.charts.fan : nil
            )
            .hoverHighlight(cornerRadius: 6)
        }
        .buttonStyle(.plain)
        .suppressesFocusRing()
    }
}

private struct BatteryMetricButton: View {
    @ObservedObject var battery: BatteryManager
    let action: () -> Void

    var body: some View {
        MetricButton(
            title: "BAT",
            value: battery.hasBattery ? "\(battery.percentage)%" : "AC",
            help: helpText,
            accessory: battery.hasBattery && battery.isCharging ? "bolt.fill" : nil,
            action: action
        )
    }

    private var helpText: String {
        guard battery.hasBattery else { return "Battery" }
        if let remaining = battery.timeRemainingFormatted, !remaining.isEmpty { return remaining }
        return battery.isCharging ? "Charging" : (battery.isPluggedIn ? "On power" : "On battery")
    }
}

private struct IPButton: View {
    @Environment(\.appTheme) private var theme
    let label: String
    let value: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Text(label)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.system(size: 10, weight: .regular, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
                Image(systemName: "doc.on.doc")
                    .font(.system(size: 8.5))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 7)
            .frame(maxWidth: .infinity, minHeight: 22, maxHeight: 22)
            .background(theme.tileFill, in: RoundedRectangle(cornerRadius: theme.radius(6), style: .continuous))
            .contentShape(Rectangle())
            .hoverHighlight(cornerRadius: 6)
        }
        .buttonStyle(.plain)
        .suppressesFocusRing()
        .help("Copy")
    }
}

// MARK: - Quick toggles (each observes only its own manager)

private struct QuickToggle: View {
    @Environment(\.appTheme) private var theme
    let title: String
    let icon: String
    let color: Color
    let isActive: Bool
    var isWorking = false
    var help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Group {
                    if isWorking {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: icon)
                            .font(.system(size: 12, weight: .regular))
                    }
                }
                .frame(height: 14)
                Text(title)
                    .font(.system(size: 9.5, weight: .medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            .foregroundStyle(isActive ? color : .secondary)
            .frame(maxWidth: .infinity, minHeight: 38, maxHeight: 38)
            .background(
                isActive ? color.opacity(0.12) : theme.cardFill,
                in: RoundedRectangle(cornerRadius: theme.radius(8), style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: theme.radius(8), style: .continuous)
                    .strokeBorder(isActive ? color.opacity(0.35) : theme.cardStroke, lineWidth: theme.strokeWidth)
            )
            .contentShape(Rectangle())
            .hoverHighlight(cornerRadius: 8)
        }
        .buttonStyle(.plain)
        .suppressesFocusRing()
        .help(help)
    }
}

/// Awake: no idle sleep, display kept on (optional). Closing the lid still sleeps.
private struct AntiSleepToggle: View {
    @ObservedObject var antiSleep: AntiSleepManager
    let openPicker: () -> Void

    var body: some View {
        QuickToggle(
            title: antiSleep.awakeOn ? antiSleep.statusText : "Awake",
            icon: antiSleep.lastError == nil ? "cup.and.saucer" : "exclamationmark.triangle",
            color: .orange,
            isActive: antiSleep.awakeOn,
            help: antiSleep.lastError
                ?? (antiSleep.awakeOn ? "Awake on · click to stop" : "Keep the Mac and screen awake"),
            action: {
                if antiSleep.awakeOn { antiSleep.deactivate() } else { openPicker() }
            }
        )
    }
}

/// Closed-lid: keeps running with the lid closed (pmset disablesleep), stops at the battery guard.
private struct ClosedLidToggle: View {
    @ObservedObject var antiSleep: AntiSleepManager
    let openPicker: () -> Void

    var body: some View {
        if !antiSleep.lidOn && antiSleep.sleepRestoreFailed {
            // Off, but pmset still blocks sleep: stay highlighted until the restore succeeds.
            QuickToggle(
                title: "Retry",
                icon: "exclamationmark.triangle",
                color: .orange,
                isActive: true,
                help: "Sleep still disabled · click to restore",
                action: { antiSleep.retryRestoreSleep() }
            )
        } else {
            QuickToggle(
                title: antiSleep.lidOn ? antiSleep.lidStatusText : "Lid",
                icon: antiSleep.lidError == nil || antiSleep.lidOn ? "laptopcomputer" : "exclamationmark.triangle",
                color: .indigo,
                isActive: antiSleep.lidOn,
                isWorking: antiSleep.lidWorking,
                help: help,
                action: {
                    if antiSleep.lidOn { antiSleep.deactivateLid() } else { openPicker() }
                }
            )
        }
    }

    private var help: String {
        if antiSleep.lidOn {
            let guardText = antiSleep.lidBatteryGuard > 0 ? " · stops at \(antiSleep.lidBatteryGuard)%" : ""
            return "Closed-lid on\(guardText) · click to stop"
        }
        return antiSleep.lidError ?? "Keep running with the lid closed"
    }
}

private struct LowPowerToggle: View {
    @ObservedObject var battery: BatteryManager

    var body: some View {
        QuickToggle(
            title: "Low Power",
            icon: "leaf",
            color: .yellow,
            isActive: battery.isLowPowerMode,
            help: "Low Power Mode",
            action: { battery.toggleLowPowerMode() }
        )
    }
}

private struct VPNToggle: View {
    @ObservedObject var network: NetworkBypassManager
    let monitor: SystemMonitorManager

    var body: some View {
        QuickToggle(
            title: "VPN",
            icon: "shield",
            color: .green,
            isActive: network.isVPNConnected,
            isWorking: network.isVPNTransitioning,
            help: network.isVPNConnected ? "VanyaVPN connected" : "VanyaVPN",
            action: {
                network.toggleVPN()
                monitor.invalidatePublicIP()
            }
        )
    }
}

private struct SpoofToggle: View {
    @ObservedObject var network: NetworkBypassManager
    let monitor: SystemMonitorManager

    var body: some View {
        QuickToggle(
            title: "SpoofDPI",
            icon: "bolt.horizontal",
            color: .cyan,
            isActive: network.isSpoofDPIRunning,
            isWorking: network.isSpoofTransitioning,
            help: network.isSpoofDPIRunning ? "SpoofDPI \(network.spoofEndpoint)" : "SpoofDPI",
            action: {
                network.toggleSpoofDPI()
                monitor.invalidatePublicIP()
            }
        )
    }
}

// MARK: - Media converter

private struct ConverterCard: View {
    @Environment(\.appTheme) private var theme
    @ObservedObject var converter: MediaConverterManager
    @State private var isDropTargeted = false

    private let maxVisibleTasks = 4

    var body: some View {
        MacToolsCard(padding: 6) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 5) {
                    categorySelector
                    presetMenu
                    if !converter.tasks.isEmpty {
                        queueMenu
                    }
                }
                dropZone
                if !converter.tasks.isEmpty {
                    tasks
                }
            }
        }
    }

    private var categorySelector: some View {
        HStack(spacing: 0) {
            ForEach(MediaCategory.allCases) { category in
                let isSelected = converter.selectedCategory == category
                Button {
                    // Instant switch: no animation, the card observes the converter directly.
                    var transaction = Transaction()
                    transaction.disablesAnimations = true
                    withTransaction(transaction) { converter.selectedCategory = category }
                } label: {
                    Text(category.rawValue)
                        .font(.system(size: 10, weight: isSelected ? .semibold : .regular))
                        .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                        .frame(maxWidth: .infinity, minHeight: 22, maxHeight: 22)
                        .background(
                            isSelected ? theme.accent.opacity(theme.isFeatured ? 0 : 0.22) : Color.clear,
                            in: RoundedRectangle(cornerRadius: theme.radius(5), style: .continuous)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .suppressesFocusRing()
            }
        }
        .padding(2)
        .frame(width: 186)
        .background(theme.controlFill, in: RoundedRectangle(cornerRadius: theme.radius(7), style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: theme.radius(7), style: .continuous).strokeBorder(theme.cardStroke))
    }

    private var presetMenu: some View {
        Menu {
            ForEach(currentPresetOptions, id: \.self) { option in
                Button {
                    selectPreset(option)
                } label: {
                    if option == currentPreset {
                        Label(option, systemImage: "checkmark")
                    } else {
                        Text(option)
                    }
                }
            }
        } label: {
            Text(Self.shortName(currentPreset))
                .font(.system(size: 10, weight: .medium))
        }
        .menuStyle(.borderlessButton)
        .suppressesFocusRing()
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 7)
        .frame(minHeight: 26, maxHeight: 26)
        .background(theme.controlFill, in: RoundedRectangle(cornerRadius: theme.radius(7), style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: theme.radius(7), style: .continuous).strokeBorder(theme.cardStroke))
        .help(currentPreset)
    }

    private var queueMenu: some View {
        Menu {
            Button("Clear completed") { converter.clearCompleted() }
            Button("Clear all", role: .destructive) { converter.clearAll() }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 22, height: 26)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .suppressesFocusRing()
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Queue")
    }

    private var dropZone: some View {
        Button(action: selectFiles) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.down.doc")
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(isDropTargeted ? Color.accentColor : .secondary)
                Text(isDropTargeted ? "Release to convert" : "Drop media or choose")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(isDropTargeted ? Color.accentColor : .secondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if converter.isConverting {
                    ProgressView().controlSize(.mini)
                }
            }
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, minHeight: 28, maxHeight: 28)
            .background(
                isDropTargeted ? Color.accentColor.opacity(0.10) : theme.tileFill,
                in: RoundedRectangle(cornerRadius: theme.radius(7), style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: theme.radius(7), style: .continuous)
                    .strokeBorder(
                        isDropTargeted ? Color.accentColor.opacity(0.7) : theme.cardStroke,
                        style: StrokeStyle(lineWidth: 1, dash: [4]))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .suppressesFocusRing()
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted, perform: handleDrop)
    }

    private var tasks: some View {
        let visible = converter.tasks.suffix(maxVisibleTasks)
        let hidden = converter.tasks.count - visible.count
        return VStack(spacing: 3) {
            ForEach(visible) { task in
                CompactTaskRow(task: task) { converter.removeTask(id: task.id) }
            }
            if hidden > 0 {
                Text("+\(hidden) more")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 4)
            }
        }
    }

    // MARK: Presets

    static func shortName(_ preset: String) -> String {
        preset.components(separatedBy: " (").first ?? preset
    }

    private var currentPreset: String {
        switch converter.selectedCategory {
        case .video: return converter.selectedVideoPreset.rawValue
        case .audio: return converter.selectedAudioPreset.rawValue
        case .gif: return converter.selectedGIFPreset.rawValue
        case .image: return converter.selectedImagePreset.rawValue
        }
    }

    private var currentPresetOptions: [String] {
        switch converter.selectedCategory {
        case .video: return VideoPreset.allCases.map(\.rawValue)
        case .audio: return AudioPreset.allCases.map(\.rawValue)
        case .gif: return GIFQualityPreset.allCases.map(\.rawValue)
        case .image: return ImagePreset.allCases.map(\.rawValue)
        }
    }

    private func selectPreset(_ rawValue: String) {
        switch converter.selectedCategory {
        case .video:
            if let preset = VideoPreset(rawValue: rawValue) { converter.selectedVideoPreset = preset }
        case .audio:
            if let preset = AudioPreset(rawValue: rawValue) { converter.selectedAudioPreset = preset }
        case .gif:
            if let preset = GIFQualityPreset(rawValue: rawValue) { converter.selectedGIFPreset = preset }
        case .image:
            if let preset = ImagePreset(rawValue: rawValue) { converter.selectedImagePreset = preset }
        }
    }

    // MARK: Files

    private func selectFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        // The modal open panel takes key focus and closes the menu bar panel; reopen it afterwards.
        if panel.runModal() == .OK {
            converter.addFiles(panel.urls)
        }
        AppDelegate.sharedInstance?.reopenPanelIfHidden()
    }

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        let converter = converter
        AppDelegate.sharedInstance?.focusPanelAfterDrop()
        for provider in providers {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { converter.addFiles([url]) }
                }
            }
        }
        return !providers.isEmpty
    }
}

private struct CompactTaskRow: View {
    @Environment(\.appTheme) private var theme
    let task: MediaTask
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: task.category.icon)
                .font(.system(size: 9.5))
                .foregroundStyle(.secondary)
                .frame(width: 14)

            Text(task.inputURL.lastPathComponent)
                .font(.system(size: 10))
                .lineLimit(1)
                .truncationMode(.middle)

            Text("→ \(ConverterCard.shortName(task.outputFormat))")
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .layoutPriority(-1)

            Spacer(minLength: 4)

            status

            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.system(size: 8.5, weight: .medium))
                    .foregroundStyle(.tertiary)
                    .frame(width: 14, height: 14)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .suppressesFocusRing()
            .help("Remove")
        }
        .padding(.horizontal, 6)
        .frame(maxWidth: .infinity, minHeight: 22, maxHeight: 22)
        .background(theme.tileFill, in: RoundedRectangle(cornerRadius: theme.radius(6), style: .continuous))
    }

    @ViewBuilder
    private var status: some View {
        switch task.status {
        case .queued:
            Text("Queued")
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
        case .converting(let progress, let speed):
            Text(progress > 0 ? "\(Int((progress * 100).rounded()))%" : "…")
                .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                .foregroundStyle(Color.accentColor)
                .help(speed)
        case .completed(let outputURL):
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([outputURL])
            } label: {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.green)
            }
            .buttonStyle(.plain)
            .suppressesFocusRing()
            .help("Show in Finder")
        case .failed(let error):
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 10))
                .foregroundStyle(.red)
                .help(error)
        }
    }
}

// MARK: - Shelf

private struct ShelfSection: View {
    @ObservedObject var shelf: ShelfManager

    var body: some View {
        if shelf.isEnabled {
            ShelfCard(manager: shelf)
        }
    }
}

// MARK: - Clipboard

private struct ClipboardCard: View {
    @ObservedObject var clipboard: ClipboardManager
    let toast: (String) -> Void

    var body: some View {
        MacToolsCard(padding: 6) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Label("Clipboard", systemImage: "doc.on.clipboard")
                        .font(.system(size: 10.5, weight: .semibold))
                    if clipboard.items.isEmpty {
                        Text("Copies show here")
                            .font(.system(size: 9.5))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    Button("⌥⌘V") { ClipboardHUDWindowController.shared.show() }
                        .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                        .buttonStyle(.borderless)
                        .help("Open history")
                }
                .frame(height: 16)
                .padding(.horizontal, 1)

                ForEach(Array(clipboard.items.prefix(3).enumerated()), id: \.element.id) { index, item in
                    ClipRow(index: index, item: item, icon: clipboard.icon(for: item)) {
                        clipboard.copyAndPaste(item: item, simulatePaste: false)
                        toast("Copied")
                    }
                }
            }
        }
    }
}

private struct ClipRow: View {
    @Environment(\.appTheme) private var theme
    let index: Int
    let item: ClipboardItem
    var icon: NSImage?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text("\(index + 1)")
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .frame(width: 10)
                if item.isPinned {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 8))
                        .foregroundStyle(.secondary)
                }
                if let icon {
                    Image(nsImage: icon)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 14, height: 14)
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                }
                Text(item.snippet)
                    .font(.system(size: 10))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 4)
                Text(item.timeAgoFormatted)
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .fixedSize()
            }
            .padding(.horizontal, 6)
            .frame(maxWidth: .infinity, minHeight: 21, maxHeight: 21)
            .background(theme.tileFill, in: RoundedRectangle(cornerRadius: theme.radius(6), style: .continuous))
            .contentShape(Rectangle())
            .hoverHighlight(cornerRadius: 6)
        }
        .buttonStyle(.plain)
        .suppressesFocusRing()
    }
}

// MARK: - Anti-Sleep picker

private struct AntiSleepPickerOverlay: View {
    @Environment(\.appTheme) private var theme
    @ObservedObject var antiSleep: AntiSleepManager
    let mode: AntiSleepManager.Mode
    let onClose: () -> Void

    private var isLid: Bool { mode == .lid }

    var body: some View {
        ZStack {
            Color.black.opacity(0.42)
                .ignoresSafeArea()
                .onTapGesture(perform: onClose)

            MacToolsCard(padding: 10, cornerRadius: 12) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Image(systemName: isLid ? "laptopcomputer" : "cup.and.saucer")
                            .font(.system(size: 12, weight: .regular))
                            .foregroundStyle(isLid ? Color.indigo : Color.orange)
                        Text(isLid ? "Closed-lid" : "Keep awake")
                            .font(.system(size: 12, weight: .semibold))
                        Spacer()
                        Button(action: onClose) {
                            Image(systemName: "xmark")
                                .font(.system(size: 9, weight: .medium))
                                .frame(width: 20, height: 20)
                                .background(theme.controlFill, in: RoundedRectangle(cornerRadius: 6))
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .suppressesFocusRing()
                    }

                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 5), count: 3), spacing: 5) {
                        ForEach(AntiSleepManager.durations, id: \.seconds) { duration in
                            Button {
                                if isLid {
                                    antiSleep.activateLid(duration: duration.seconds)
                                } else {
                                    antiSleep.activate(duration: duration.seconds)
                                }
                                onClose()
                            } label: {
                                Text(duration.label)
                                    .font(.system(size: 11, weight: .medium))
                                    .frame(maxWidth: .infinity, minHeight: 30)
                                    .background(theme.controlFill, in: RoundedRectangle(cornerRadius: 7))
                                    .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(theme.cardStroke))
                                    .contentShape(Rectangle())
                                    .hoverHighlight(cornerRadius: 7)
                            }
                            .buttonStyle(.plain)
                            .suppressesFocusRing()
                        }
                    }

                    if isLid {
                        Text(lidNote)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        Toggle("Keep display awake", isOn: $antiSleep.preventDisplaySleep)
                            .font(.system(size: 10))
                            .toggleStyle(.switch)
                            .controlSize(.mini)
                    }
                }
            }
            .frame(width: 260)
            .background(
                ThemeBackdrop(theme: theme)
                    .background(Color(nsColor: .windowBackgroundColor).opacity(0.96))
                    .clipShape(RoundedRectangle(cornerRadius: theme.radius(12)))
            )
            .shadow(color: .black.opacity(0.28), radius: 18, y: 6)
            .fixedSize(horizontal: false, vertical: true)
            .reportsPanelHeight(extra: 24)
        }
    }

    private var lidNote: String {
        let guardText =
            antiSleep.lidBatteryGuard > 0
            ? "Stops at \(antiSleep.lidBatteryGuard)% battery." : "No battery stop."
        return "Runs with the lid closed, on battery too. \(guardText) Keep it out of a closed bag."
    }
}
