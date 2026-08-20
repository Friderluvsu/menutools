import AppKit
import SwiftUI

struct PopoverContentView: View {
    @ObservedObject var appState: AppState
    @State private var isDropTargeted = false
    @State private var copiedNotice: String?
    @State private var showSettings: Bool
    @State private var showAntiSleepPicker: Bool
    @State private var showFanControlPicker: Bool
    @State private var showMediaPresetPicker = false

    private let twoColumns = [
        GridItem(.flexible(), spacing: MacToolsTheme.sectionSpacing),
        GridItem(.flexible(), spacing: MacToolsTheme.sectionSpacing),
    ]

    init(
        appState: AppState,
        showSettings: Bool = false,
        showAntiSleepPicker: Bool = false,
        showFanControlPicker: Bool = false
    ) {
        self.appState = appState
        _showSettings = State(initialValue: showSettings)
        _showAntiSleepPicker = State(initialValue: showAntiSleepPicker)
        _showFanControlPicker = State(initialValue: showFanControlPicker)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.35)

            ScrollView(.vertical, showsIndicators: true) {
                Group {
                    if showSettings {
                        SettingsTabView(appState: appState)
                    } else {
                        dashboard
                    }
                }
                .padding(MacToolsTheme.outerPadding)
            }
        }
        .frame(width: MacToolsTheme.popoverWidth, height: MacToolsTheme.popoverHeight)
        .background(.ultraThinMaterial)
        .overlay(alignment: .bottom) {
            if let copiedNotice {
                Text(copiedNotice)
                    .font(.system(size: 11, weight: .semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(.regularMaterial, in: Capsule())
                    .padding(.bottom, 10)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .overlay {
            if showAntiSleepPicker {
                antiSleepPickerOverlay
                    .transition(.opacity.combined(with: .scale(scale: 0.97)))
            }
            if showFanControlPicker {
                fanControlPickerOverlay
                    .transition(.opacity.combined(with: .scale(scale: 0.97)))
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: appState.menuBarIconStyle.symbolName)
                .font(.system(size: 11.5, weight: .regular))
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 24)
                .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))

            VStack(alignment: .leading, spacing: 1) {
                Text(showSettings ? "Settings" : "MenuTools")
                    .font(.system(size: 12, weight: .semibold))
                Text(headerSubtitle)
                    .font(.system(size: 9, weight: .regular))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            if appState.antiSleep.isActive {
                StatusBadge(text: appState.antiSleep.statusText, color: .orange)
            }
            if appState.network.isVPNConnected {
                StatusBadge(text: "VPN", color: .green)
            }

            Button {
                withAnimation(.easeOut(duration: 0.15)) {
                    showSettings.toggle()
                }
                if showSettings {
                    appState.iMessage.refreshPermissions()
                }
            } label: {
                Image(systemName: showSettings ? "xmark" : "gearshape")
                    .font(.system(size: 11, weight: .regular))
                    .frame(width: 24, height: 24)
                    .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 7))
            }
            .buttonStyle(.plain)
            .help(showSettings ? "Back to tools" : "Settings")
        }
        .padding(.horizontal, MacToolsTheme.outerPadding)
        .frame(height: 42)
    }

    private var headerSubtitle: String {
        if showSettings { return "Permissions and preferences" }
        if appState.iMessage.isMessagesActive { return "Messages is active" }
        return "System utilities"
    }

    private var dashboard: some View {
        VStack(spacing: MacToolsTheme.sectionSpacing) {
            metricsCard
            quickToggles
            converterCard
            clipboardCard
            systemActions
        }
        .frame(maxWidth: .infinity)
    }

    private var metricsCard: some View {
        MacToolsCard(padding: 8) {
            VStack(spacing: 6) {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 5), count: 4), spacing: 5) {
                    MetricTile(title: "CPU", value: "\(Int(appState.systemMonitor.cpuUsage))%")
                    MetricTile(title: "RAM", value: String(format: "%.1fG", appState.systemMonitor.memoryUsedGB))
                    MetricTile(title: "TEMP", value: "\(Int(appState.systemMonitor.cpuTemperature))°C")
                    MetricTile(
                        title: "FAN",
                        value: appState.fanControl.hasFans ? "\(appState.fanControl.fanDisplayShort) RPM" : "No Fans",
                        isInteractive: true,
                        action: {
                            withAnimation(.easeOut(duration: 0.16)) {
                                showFanControlPicker = true
                            }
                        }
                    )
                }

                HStack(spacing: 6) {
                    IPButton(label: "LAN", value: appState.systemMonitor.localIP) {
                        copy(appState.systemMonitor.localIP, notice: "LAN address copied")
                    }
                    IPButton(label: "WAN", value: appState.systemMonitor.publicIP) {
                        copy(appState.systemMonitor.publicIP, notice: "WAN address copied")
                    }
                }
            }
        }
    }

    private var quickToggles: some View {
        LazyVGrid(columns: twoColumns, spacing: MacToolsTheme.sectionSpacing) {
            ToolToggleCard(
                title: "Anti-Sleep",
                status: appState.antiSleep.isActive ? appState.antiSleep.statusText : "Off",
                icon: "cup.and.saucer",
                color: .orange,
                isActive: appState.antiSleep.isActive,
                action: {
                    if appState.antiSleep.isActive {
                        appState.antiSleep.deactivate()
                    } else {
                        withAnimation(.easeOut(duration: 0.16)) {
                            showAntiSleepPicker = true
                        }
                    }
                }
            )
            ToolToggleCard(
                title: "Messages Nav",
                status: iMessageStatus,
                icon: "message",
                color: .blue,
                isActive: appState.iMessage.isEnabled && appState.iMessage.isEventTapActive,
                action: { appState.iMessage.isEnabled.toggle() }
            )
            ToolToggleCard(
                title: "VanyaVPN",
                status: appState.network.isVPNTransitioning
                    ? "Updating…" : (appState.network.isVPNConnected ? "Connected" : "Off"),
                icon: "shield",
                color: .green,
                isActive: appState.network.isVPNConnected,
                isWorking: appState.network.isVPNTransitioning,
                action: appState.network.toggleVPN
            )
            ToolToggleCard(
                title: "SpoofDPI",
                status: appState.network.isSpoofTransitioning
                    ? "Updating…" : (appState.network.isSpoofDPIRunning ? "Running" : "Off"),
                icon: "bolt.horizontal",
                color: .cyan,
                isActive: appState.network.isSpoofDPIRunning,
                isWorking: appState.network.isSpoofTransitioning,
                action: appState.network.toggleSpoofDPI
            )
        }
    }

    private var iMessageStatus: String {
        if !appState.iMessage.isEnabled { return "Off" }
        if appState.iMessage.isMessagesActive { return "Messages active" }
        if appState.iMessage.isEventTapActive { return "Ready · ↑/↓" }
        return "Needs access"
    }

    private var converterCard: some View {
        MacToolsCard(padding: 9) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Label("Media Converter", systemImage: "arrow.triangle.2.circlepath")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.primary)

                    Spacer()

                    if appState.converter.isConverting {
                        ProgressView().controlSize(.small)
                    }

                    if !appState.converter.tasks.isEmpty {
                        Menu {
                            Button("Clear completed") { appState.converter.clearCompleted() }
                            Button("Clear queue", role: .destructive) { appState.converter.clearAll() }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                                .font(.system(size: 12))
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                    }
                }

                mediaCategorySelector
                mediaPresetMenu

                dropZone

                if !appState.converter.tasks.isEmpty {
                    VStack(spacing: 5) {
                        ForEach(appState.converter.tasks) { task in
                            MediaTaskRow(task: task) {
                                appState.converter.removeTask(id: task.id)
                            }
                        }
                    }
                }
            }
        }
    }

    private var dropZone: some View {
        Button(action: selectFiles) {
            HStack(spacing: 7) {
                Image(systemName: "square.and.arrow.down")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.pink)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Drop files here or choose files")
                        .font(.system(size: 9.5, weight: .medium))
                        .lineLimit(1)
                    Text("Video, audio, GIF and images")
                        .font(.system(size: 8.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 8.5, weight: .regular))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, minHeight: 40)
            .background(isDropTargeted ? Color.pink.opacity(0.12) : Color.white.opacity(0.035))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(
                        isDropTargeted ? Color.pink.opacity(0.7) : Color.white.opacity(0.10),
                        style: StrokeStyle(dash: [4]))
            )
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted, perform: handleDrop)
    }

    private var clipboardCard: some View {
        MacToolsCard(padding: 9) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Label("Clipboard", systemImage: "doc.on.clipboard")
                        .font(.system(size: 11, weight: .semibold))
                    Spacer()
                    Button("Open HUD  ⌥⌘V") { ClipboardHUDWindowController.shared.show() }
                        .font(.system(size: 9, weight: .regular))
                        .buttonStyle(.borderless)
                }

                let recentClips = Array(appState.clipboard.items.prefix(3))
                if recentClips.isEmpty {
                    Text("Copied text will appear here")
                        .font(.system(size: 9.5))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 25, alignment: .leading)
                } else {
                    ForEach(Array(recentClips.enumerated()), id: \.element.id) { index, item in
                        Button {
                            appState.clipboard.copyAndPaste(item: item, simulatePaste: false)
                            showToast("Copied clip #\(index + 1)")
                        } label: {
                            HStack(spacing: 6) {
                                Text("\(index + 1)")
                                    .font(.system(size: 8.5, weight: .medium, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 14)

                                if item.isPinned {
                                    Image(systemName: "pin.fill")
                                        .font(.system(size: 7.5))
                                        .foregroundStyle(.yellow)
                                }

                                Text(item.snippet)
                                    .font(.system(size: 9.5))
                                    .lineLimit(1)
                                    .truncationMode(.tail)

                                Spacer(minLength: 0)

                                Text(item.timeAgoFormatted)
                                    .font(.system(size: 8))
                                    .foregroundStyle(.tertiary)
                            }
                            .padding(.horizontal, 7)
                            .frame(maxWidth: .infinity, minHeight: 24)
                            .background(Color.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 6))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private var antiSleepPickerOverlay: some View {
        ZStack {
            Color.black.opacity(0.42)
                .ignoresSafeArea()
                .onTapGesture {
                    withAnimation(.easeIn(duration: 0.12)) { showAntiSleepPicker = false }
                }

            MacToolsCard(padding: 12, cornerRadius: 12) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        Image(systemName: "cup.and.saucer")
                            .font(.system(size: 12, weight: .regular))
                            .foregroundStyle(.orange)
                            .frame(width: 28, height: 28)
                            .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))

                        VStack(alignment: .leading, spacing: 1) {
                            Text("Keep Mac awake")
                                .font(.system(size: 12, weight: .semibold))
                            Text("Choose how long Anti-Sleep should run")
                                .font(.system(size: 9))
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        Button {
                            withAnimation(.easeIn(duration: 0.12)) { showAntiSleepPicker = false }
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 9, weight: .medium))
                                .frame(width: 22, height: 22)
                                .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
                        }
                        .buttonStyle(.plain)
                    }

                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3), spacing: 6) {
                        ForEach(AntiSleepManager.durations, id: \.seconds) { duration in
                            Button {
                                appState.antiSleep.activate(duration: duration.seconds)
                                withAnimation(.easeIn(duration: 0.12)) { showAntiSleepPicker = false }
                            } label: {
                                VStack(spacing: 2) {
                                    Text(duration.label)
                                        .font(.system(size: 11, weight: .medium))
                                    Text(antiSleepDurationCaption(duration.seconds))
                                        .font(.system(size: 8))
                                        .foregroundStyle(.secondary)
                                }
                                .frame(maxWidth: .infinity, minHeight: 38)
                                .background(Color.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 8))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8)
                                        .strokeBorder(Color.white.opacity(0.06))
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    Toggle(
                        "Keep display awake too",
                        isOn: Binding(
                            get: { appState.antiSleep.preventDisplaySleep },
                            set: { appState.antiSleep.preventDisplaySleep = $0 }
                        )
                    )
                    .font(.system(size: 9.5))
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                }
            }
            .frame(width: 300)
            .background(
                Color(nsColor: .windowBackgroundColor).opacity(0.96),
                in: RoundedRectangle(cornerRadius: 12)
            )
            .shadow(color: .black.opacity(0.28), radius: 22, y: 8)
        }
    }

    private func antiSleepDurationCaption(_ seconds: Int) -> String {
        switch seconds {
        case 0: return "Until stopped"
        case 900: return "15 minutes"
        case 1800: return "30 minutes"
        case 3600: return "1 hour"
        case 7200: return "2 hours"
        case 18000: return "5 hours"
        default: return "Timer"
        }
    }

    private var fanControlPickerOverlay: some View {
        FanControlPickerView(fanControl: appState.fanControl) {
            withAnimation(.easeIn(duration: 0.12)) {
                showFanControlPicker = false
            }
        }
    }

    private var systemActions: some View {
        LazyVGrid(columns: twoColumns, spacing: MacToolsTheme.sectionSpacing) {
            SystemActionButton(title: "Eject disks", icon: "eject", color: .red) {
                appState.systemUtils.ejectAllDisks()
            }
            SystemActionButton(title: "Empty Trash", icon: "trash", color: .orange) {
                appState.systemUtils.emptyTrash()
            }
            SystemActionButton(title: "Reset Google Drive", icon: "arrow.triangle.2.circlepath", color: .purple) {
                appState.systemUtils.resetGoogleDriveHelper()
            }
            SystemActionButton(title: "Flush DNS", icon: "network", color: .blue) {
                appState.systemUtils.flushDNS()
            }
        }
    }

    private var mediaCategorySelector: some View {
        HStack(spacing: 0) {
            ForEach(MediaCategory.allCases) { category in
                Button {
                    appState.converter.selectedCategory = category
                } label: {
                    Text(category.rawValue)
                        .font(
                            .system(
                                size: 10,
                                weight: appState.converter.selectedCategory == category ? .medium : .regular
                            )
                        )
                        .foregroundStyle(
                            appState.converter.selectedCategory == category ? Color.primary : Color.secondary
                        )
                        .frame(maxWidth: .infinity, minHeight: 24)
                        .background(
                            appState.converter.selectedCategory == category
                                ? Color.white.opacity(0.18)
                                : Color.clear,
                            in: RoundedRectangle(cornerRadius: 6)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if category != MediaCategory.allCases.last {
                    Divider()
                        .frame(height: 12)
                        .opacity(0.45)
                }
            }
        }
        .padding(2)
        .frame(maxWidth: .infinity)
        .background(MacToolsTheme.controlBackground, in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(MacToolsTheme.borderColor)
        )
    }

    private var mediaPresetMenu: some View {
        Button {
            showMediaPresetPicker.toggle()
        } label: {
            HStack(spacing: 8) {
                Text("Format")
                    .font(.system(size: 9, weight: .regular))
                    .foregroundStyle(.secondary)

                Spacer(minLength: 8)

                Text(currentPresetTitle)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 9)
            .frame(maxWidth: .infinity, minHeight: 28)
            .background(MacToolsTheme.controlBackground, in: RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(MacToolsTheme.borderColor)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showMediaPresetPicker, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 3) {
                Text("OUTPUT FORMAT")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.bottom, 2)

                ForEach(Array(currentPresetOptions.enumerated()), id: \.offset) { _, option in
                    Button {
                        selectPreset(option)
                        showMediaPresetPicker = false
                    } label: {
                        HStack(spacing: 8) {
                            Text(option)
                                .font(.system(size: 10))
                                .lineLimit(1)
                            Spacer(minLength: 8)
                            if option == currentPresetTitle {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 8, weight: .semibold))
                                    .foregroundStyle(Color.accentColor)
                            }
                        }
                        .padding(.horizontal, 7)
                        .frame(maxWidth: .infinity, minHeight: 24)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(8)
            .frame(width: 250)
        }
    }

    private var currentPresetTitle: String {
        switch appState.converter.selectedCategory {
        case .video: return appState.converter.selectedVideoPreset.rawValue
        case .audio: return appState.converter.selectedAudioPreset.rawValue
        case .gif: return appState.converter.selectedGIFPreset.rawValue
        case .image: return appState.converter.selectedImagePreset.rawValue
        }
    }

    private var currentPresetOptions: [String] {
        switch appState.converter.selectedCategory {
        case .video: return VideoPreset.allCases.map(\.rawValue)
        case .audio: return AudioPreset.allCases.map(\.rawValue)
        case .gif: return GIFQualityPreset.allCases.map(\.rawValue)
        case .image: return ImagePreset.allCases.map(\.rawValue)
        }
    }

    private func selectPreset(_ rawValue: String) {
        switch appState.converter.selectedCategory {
        case .video:
            if let preset = VideoPreset(rawValue: rawValue) {
                appState.converter.selectedVideoPreset = preset
            }
        case .audio:
            if let preset = AudioPreset(rawValue: rawValue) {
                appState.converter.selectedAudioPreset = preset
            }
        case .gif:
            if let preset = GIFQualityPreset(rawValue: rawValue) {
                appState.converter.selectedGIFPreset = preset
            }
        case .image:
            if let preset = ImagePreset(rawValue: rawValue) {
                appState.converter.selectedImagePreset = preset
            }
        }
    }

    private func selectFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        if panel.runModal() == .OK {
            appState.converter.addFiles(panel.urls)
        }
    }

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        for provider in providers {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                DispatchQueue.main.async { appState.converter.addFiles([url]) }
            }
        }
        return !providers.isEmpty
    }

    private func copy(_ value: String, notice: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
        showToast(notice)
    }

    private func showToast(_ text: String) {
        withAnimation(.easeOut(duration: 0.15)) { copiedNotice = text }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
            withAnimation(.easeIn(duration: 0.15)) { copiedNotice = nil }
        }
    }

    private func formatSpeed(_ kilobytesPerSecond: Double) -> String {
        kilobytesPerSecond >= 1024
            ? String(format: "%.1fM", kilobytesPerSecond / 1024)
            : String(format: "%.0fK", kilobytesPerSecond)
    }
}

private struct StatusBadge: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.system(size: 8.5, weight: .semibold, design: .monospaced))
            .foregroundStyle(color)
            .lineLimit(1)
            .padding(.horizontal, 7)
            .frame(height: 20)
            .background(color.opacity(0.12), in: Capsule())
    }
}

private struct MetricTile: View {
    let title: String
    let value: String
    var isInteractive: Bool = false
    var action: (() -> Void)? = nil

    var body: some View {
        Group {
            if let action {
                Button(action: action) {
                    content
                }
                .buttonStyle(.plain)
            } else {
                content
            }
        }
    }

    private var content: some View {
        VStack(spacing: 2) {
            Text(title)
                .font(.system(size: 7.5, weight: .medium))
                .foregroundStyle(isInteractive ? Color.teal : Color.secondary)
            Text(value)
                .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                .foregroundStyle(isInteractive ? Color.teal : Color.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .frame(maxWidth: .infinity, minHeight: 32)
        .background(
            isInteractive ? Color.teal.opacity(0.10) : Color.white.opacity(0.035),
            in: RoundedRectangle(cornerRadius: 7)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7)
                .strokeBorder(isInteractive ? Color.teal.opacity(0.35) : Color.clear, lineWidth: 1)
        )
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
                    .font(.system(size: 8, weight: .medium))
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.system(size: 9, weight: .regular, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
                Image(systemName: "doc.on.doc")
                    .font(.system(size: 8))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 7)
            .frame(maxWidth: .infinity, minHeight: 25)
            .background(Color.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
    }
}

private struct ToolToggleCard: View {
    let title: String
    let status: String
    let icon: String
    let color: Color
    let isActive: Bool
    var isWorking = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(isActive ? color : .secondary)
                    .frame(width: 26, height: 26)
                    .background(
                        (isActive ? color : Color.secondary).opacity(0.08), in: RoundedRectangle(cornerRadius: 7))

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 10, weight: .medium))
                        .lineLimit(1)
                    Text(status)
                        .font(.system(size: 8.5, weight: .regular))
                        .foregroundStyle(isActive ? color : .secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                Spacer(minLength: 2)
                if isWorking {
                    ProgressView().controlSize(.mini)
                } else {
                    Circle()
                        .fill(isActive ? color : Color.secondary.opacity(0.35))
                        .frame(width: 5, height: 5)
                }
            }
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, minHeight: 46)
            .background(MacToolsTheme.cardBackground, in: RoundedRectangle(cornerRadius: MacToolsTheme.cornerRadius))
            .overlay(RoundedRectangle(cornerRadius: MacToolsTheme.cornerRadius).strokeBorder(MacToolsTheme.borderColor))
        }
        .buttonStyle(.plain)
    }
}

private struct SystemActionButton: View {
    let title: String
    let icon: String
    let color: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .regular))
                    .foregroundStyle(color)
                    .frame(width: 22)
                Text(title)
                    .font(.system(size: 9.5, weight: .regular))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, minHeight: MacToolsTheme.controlHeight)
            .background(MacToolsTheme.cardBackground, in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(MacToolsTheme.borderColor))
        }
        .buttonStyle(.plain)
    }
}
