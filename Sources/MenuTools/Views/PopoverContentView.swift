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
    @State private var showAntiSleepPicker: Bool
    @State private var showFanControlPicker: Bool

    init(
        appState: AppState,
        showSettings: Bool = false,
        showAntiSleepPicker: Bool = false,
        showFanControlPicker: Bool = false,
        onHeightChange: (@MainActor (CGFloat) -> Void)? = nil
    ) {
        self.appState = appState
        self.onHeightChange = onHeightChange
        _showSettings = State(initialValue: showSettings)
        _showAntiSleepPicker = State(initialValue: showAntiSleepPicker)
        _showFanControlPicker = State(initialValue: showFanControlPicker)
    }

    var body: some View {
        VStack(spacing: 0) {
            PanelHeader(
                appState: appState,
                systemUtils: appState.systemUtils,
                isSettings: showSettings,
                toggleSettings: {
                    showSettings.toggle()
                    if showSettings { appState.iMessage.refreshPermissions() }
                }
            )
            Divider().opacity(0.35)

            if showSettings {
                SettingsTabView(appState: appState)
                    .padding(MacToolsTheme.outerPadding)
            } else {
                DashboardView(
                    appState: appState,
                    toast: showToast,
                    openAntiSleepPicker: { showAntiSleepPicker = true },
                    openFanPicker: { showFanControlPicker = true }
                )
                .padding(MacToolsTheme.outerPadding)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .reportsPanelHeight()
        .frame(width: MacToolsTheme.popoverWidth)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(.ultraThinMaterial)
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
                AntiSleepPickerOverlay(antiSleep: appState.antiSleep) { showAntiSleepPicker = false }
            }
            if showFanControlPicker {
                FanControlPickerView(fanControl: appState.fanControl) { showFanControlPicker = false }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.white.opacity(0.12), lineWidth: 0.5)
        )
        .onPreferenceChange(PanelHeightKey.self) { height in
            MainActor.assumeIsolated { onHeightChange?(height) }
        }
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

/// Title + system actions as icon buttons. Observes AppState only for the icon style.
private struct PanelHeader: View {
    @ObservedObject var appState: AppState
    @ObservedObject var systemUtils: SystemUtilsManager
    let isSettings: Bool
    let toggleSettings: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: appState.menuBarIconStyle.symbolName)
                .font(.system(size: 11, weight: .regular))
                .foregroundStyle(.secondary)
                .frame(width: 22, height: 22)
                .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))

            Text(isSettings ? "Settings" : "MenuTools")
                .font(.system(size: 12, weight: .semibold))

            Spacer(minLength: 6)

            if !isSettings {
                if systemUtils.isActionRunning {
                    ProgressView().controlSize(.mini)
                }
                HeaderIconButton(symbol: "eject", help: "Eject disks") { systemUtils.ejectAllDisks() }
                HeaderIconButton(symbol: "trash", help: "Empty Trash") { systemUtils.emptyTrash() }
            }
            HeaderIconButton(symbol: isSettings ? "xmark" : "gearshape", help: isSettings ? "Back" : "Settings") {
                toggleSettings()
            }
        }
        .padding(.horizontal, MacToolsTheme.outerPadding + 2)
        .frame(height: 34)
    }
}

private struct HeaderIconButton: View {
    let symbol: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .regular))
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 22)
                .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
                .hoverHighlight(cornerRadius: 6)
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

// MARK: - Dashboard

private struct DashboardView: View {
    let appState: AppState
    let toast: (String) -> Void
    let openAntiSleepPicker: () -> Void
    let openFanPicker: () -> Void

    var body: some View {
        VStack(spacing: MacToolsTheme.sectionSpacing) {
            MetricsCard(
                monitor: appState.systemMonitor,
                fanControl: appState.fanControl,
                battery: appState.battery,
                openFanPicker: openFanPicker,
                toast: toast
            )
            AILimitsCard(manager: appState.aiLimits)
            HStack(spacing: MacToolsTheme.sectionSpacing) {
                AntiSleepToggle(antiSleep: appState.antiSleep, openPicker: openAntiSleepPicker)
                LowPowerToggle(battery: appState.battery)
                VPNToggle(network: appState.network, monitor: appState.systemMonitor)
                SpoofToggle(network: appState.network, monitor: appState.systemMonitor)
            }
            ConverterCard(converter: appState.converter)
            ShelfSection(shelf: ShelfManager.shared)
            ClipboardCard(clipboard: appState.clipboard, toast: toast)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Metrics

private struct MetricsCard: View {
    @ObservedObject var monitor: SystemMonitorManager
    let fanControl: FanControlManager
    let battery: BatteryManager
    let openFanPicker: () -> Void
    let toast: (String) -> Void

    var body: some View {
        MacToolsCard(padding: 6) {
            VStack(spacing: 4) {
                HStack(spacing: 4) {
                    MetricTile(title: "CPU", value: "\(Int(monitor.cpuUsage.rounded()))%")
                    MetricTile(
                        title: "RAM", value: String(format: "%.1fG", monitor.memoryUsedGB),
                        help: String(format: "%.1f of %.0f GB", monitor.memoryUsedGB, monitor.memoryTotalGB))
                    MetricTile(title: "TEMP", value: "\(Int(monitor.cpuTemperature.rounded()))°C")
                }
                HStack(spacing: 4) {
                    FanTile(fanControl: fanControl, action: openFanPicker)
                    MetricTile(
                        title: "NET",
                        value: "↓\(Self.speed(monitor.downloadSpeedKBps)) ↑\(Self.speed(monitor.uploadSpeedKBps))",
                        help: "Down \(Self.speed(monitor.downloadSpeedKBps))B/s · Up \(Self.speed(monitor.uploadSpeedKBps))B/s")
                    BatteryTile(battery: battery)
                }
                HStack(spacing: 4) {
                    IPButton(label: "LAN", value: monitor.localIP) { copy(monitor.localIP, "LAN copied") }
                    IPButton(label: "WAN", value: monitor.publicIP) { copy(monitor.publicIP, "WAN copied") }
                }
            }
        }
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

private struct MetricTile: View {
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
            (tint ?? Color.white).opacity(tint == nil ? 0.035 : 0.10),
            in: RoundedRectangle(cornerRadius: 6, style: .continuous)
        )
        .contentShape(Rectangle())
        .help(help ?? "")
    }
}

private struct FanTile: View {
    @ObservedObject var fanControl: FanControlManager
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            MetricTile(
                title: "FAN",
                value: fanControl.hasFans ? fanControl.fanDisplayShort : "—",
                help: fanControl.hasFans ? "Fan: \(fanControl.statusText)" : "No fans",
                tint: fanControl.hasFans ? .teal : nil
            )
            .hoverHighlight(cornerRadius: 6)
        }
        .buttonStyle(.plain)
    }
}

private struct BatteryTile: View {
    @ObservedObject var battery: BatteryManager

    var body: some View {
        MetricTile(
            title: "BAT",
            value: battery.hasBattery ? "\(battery.percentage)%" : "AC",
            help: helpText,
            accessory: battery.hasBattery && battery.isCharging ? "bolt.fill" : nil
        )
    }

    private var helpText: String {
        guard battery.hasBattery else { return "Power adapter" }
        if let remaining = battery.timeRemainingFormatted, !remaining.isEmpty { return remaining }
        return battery.isCharging ? "Charging" : (battery.isPluggedIn ? "On power" : "On battery")
    }
}

private struct IPButton: View {
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
            .background(Color.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .contentShape(Rectangle())
            .hoverHighlight(cornerRadius: 6)
        }
        .buttonStyle(.plain)
        .help("Copy")
    }
}

// MARK: - Quick toggles (each observes only its own manager)

private struct QuickToggle: View {
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
                isActive ? color.opacity(0.12) : MacToolsTheme.cardBackground,
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(isActive ? color.opacity(0.35) : MacToolsTheme.borderColor)
            )
            .contentShape(Rectangle())
            .hoverHighlight(cornerRadius: 8)
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

private struct AntiSleepToggle: View {
    @ObservedObject var antiSleep: AntiSleepManager
    let openPicker: () -> Void

    var body: some View {
        if !antiSleep.isActive && antiSleep.sleepRestoreFailed {
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
                title: antiSleep.isActive ? (antiSleep.remainingSeconds > 0 ? antiSleep.statusText : "On") : "Awake",
                icon: antiSleep.lastError == nil ? "cup.and.saucer" : "exclamationmark.triangle",
                color: .orange,
                isActive: antiSleep.isActive,
                help: antiSleep.lastError ?? (antiSleep.isActive ? "Anti-Sleep on · click to stop" : "Anti-Sleep"),
                action: {
                    if antiSleep.isActive { antiSleep.deactivate() } else { openPicker() }
                }
            )
        }
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
                            isSelected ? Color.white.opacity(0.16) : Color.clear,
                            in: RoundedRectangle(cornerRadius: 5, style: .continuous)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .frame(width: 186)
        .background(MacToolsTheme.controlBackground, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(MacToolsTheme.borderColor))
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
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 7)
        .frame(minHeight: 26, maxHeight: 26)
        .background(MacToolsTheme.controlBackground, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(MacToolsTheme.borderColor))
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
                isDropTargeted ? Color.accentColor.opacity(0.10) : Color.white.opacity(0.03),
                in: RoundedRectangle(cornerRadius: 7, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(
                        isDropTargeted ? Color.accentColor.opacity(0.7) : Color.white.opacity(0.10),
                        style: StrokeStyle(lineWidth: 1, dash: [4]))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
            .help("Remove")
        }
        .padding(.horizontal, 6)
        .frame(maxWidth: .infinity, minHeight: 22, maxHeight: 22)
        .background(Color.white.opacity(0.03), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
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
                        Text("Copied text shows here")
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
                    ClipRow(index: index, item: item) {
                        clipboard.copyAndPaste(item: item, simulatePaste: false)
                        toast("Copied")
                    }
                }
            }
        }
    }
}

private struct ClipRow: View {
    let index: Int
    let item: ClipboardItem
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
            .background(Color.white.opacity(0.03), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .contentShape(Rectangle())
            .hoverHighlight(cornerRadius: 6)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Anti-Sleep picker

private struct AntiSleepPickerOverlay: View {
    @ObservedObject var antiSleep: AntiSleepManager
    let onClose: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.42)
                .ignoresSafeArea()
                .onTapGesture(perform: onClose)

            MacToolsCard(padding: 10, cornerRadius: 12) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Image(systemName: "cup.and.saucer")
                            .font(.system(size: 12, weight: .regular))
                            .foregroundStyle(.orange)
                        Text("Keep awake")
                            .font(.system(size: 12, weight: .semibold))
                        Spacer()
                        Button(action: onClose) {
                            Image(systemName: "xmark")
                                .font(.system(size: 9, weight: .medium))
                                .frame(width: 20, height: 20)
                                .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }

                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 5), count: 3), spacing: 5) {
                        ForEach(AntiSleepManager.durations, id: \.seconds) { duration in
                            Button {
                                antiSleep.activate(duration: duration.seconds)
                                onClose()
                            } label: {
                                Text(duration.label)
                                    .font(.system(size: 11, weight: .medium))
                                    .frame(maxWidth: .infinity, minHeight: 30)
                                    .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 7))
                                    .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color.white.opacity(0.06)))
                                    .contentShape(Rectangle())
                                    .hoverHighlight(cornerRadius: 7)
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    Toggle("Keep display awake", isOn: $antiSleep.preventDisplaySleep)
                        .font(.system(size: 10))
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                }
            }
            .frame(width: 260)
            .background(
                Color(nsColor: .windowBackgroundColor).opacity(0.96),
                in: RoundedRectangle(cornerRadius: 12)
            )
            .shadow(color: .black.opacity(0.28), radius: 18, y: 6)
            .fixedSize(horizontal: false, vertical: true)
            .reportsPanelHeight(extra: 24)
        }
    }
}
