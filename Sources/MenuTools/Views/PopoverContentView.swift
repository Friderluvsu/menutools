import AppKit
import SwiftUI

struct PopoverContentView: View {
    @ObservedObject var appState: AppState
    @State private var isDropTargeted = false
    @State private var copiedNotice: String?
    @State private var showSettings: Bool

    private let twoColumns = [
        GridItem(.flexible(), spacing: MacToolsTheme.sectionSpacing),
        GridItem(.flexible(), spacing: MacToolsTheme.sectionSpacing),
    ]

    init(appState: AppState, showSettings: Bool = false) {
        self.appState = appState
        _showSettings = State(initialValue: showSettings)
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
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "wrench.and.screwdriver")
                .font(.system(size: 11, weight: .regular))
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
            antiSleepPresets
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
                    MetricTile(title: "DOWN", value: formatSpeed(appState.systemMonitor.downloadSpeedKBps))
                    MetricTile(title: "UP", value: formatSpeed(appState.systemMonitor.uploadSpeedKBps))
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
                action: appState.antiSleep.toggle
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
            ToolToggleCard(
                title: "Messages Nav",
                status: iMessageStatus,
                icon: "message",
                color: .blue,
                isActive: appState.iMessage.isEnabled && appState.iMessage.isEventTapActive,
                action: { appState.iMessage.isEnabled.toggle() }
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

                Picker(
                    "Category",
                    selection: Binding(
                        get: { appState.converter.selectedCategory },
                        set: { appState.converter.selectedCategory = $0 }
                    )
                ) {
                    ForEach(MediaCategory.allCases) { category in
                        Text(category.rawValue).tag(category)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)

                HStack(spacing: 8) {
                    Text("Format")
                        .font(.system(size: 9, weight: .regular))
                        .foregroundStyle(.secondary)
                        .frame(width: 38, alignment: .leading)
                    currentPresetPicker
                        .frame(maxWidth: .infinity)
                        .controlSize(.small)
                }

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

                let recentClips = Array(appState.clipboard.items.prefix(2))
                if recentClips.isEmpty {
                    Text("Copied text will appear here")
                        .font(.system(size: 9.5))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 25, alignment: .leading)
                } else {
                    ForEach(Array(recentClips.enumerated()), id: \.element.id) { index, item in
                        Button {
                            appState.clipboard.copyAndPaste(item: item, simulatePaste: false)
                            showToast("Copied item \(index + 1)")
                        } label: {
                            HStack(spacing: 7) {
                                Text("\(index + 1)")
                                    .font(.system(size: 8.5, weight: .medium, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 14)
                                Text(item.snippet)
                                    .font(.system(size: 9.5))
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 7)
                            .frame(maxWidth: .infinity, minHeight: 25)
                            .background(Color.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 7))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private var antiSleepPresets: some View {
        MacToolsCard(padding: 9) {
            VStack(alignment: .leading, spacing: 6) {
                Text("ANTI-SLEEP TIMER")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.secondary)

                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 5), count: 6), spacing: 5) {
                    ForEach(AntiSleepManager.durations, id: \.seconds) { duration in
                        Button(duration.label) { appState.antiSleep.selectDuration(duration.seconds) }
                            .font(.system(size: 9, weight: .medium))
                            .frame(maxWidth: .infinity, minHeight: 24)
                            .background(
                                appState.antiSleep.isActive && appState.antiSleep.selectedDuration == duration.seconds
                                    ? Color.orange.opacity(0.20)
                                    : Color.white.opacity(0.05),
                                in: RoundedRectangle(cornerRadius: 6)
                            )
                            .buttonStyle(.plain)
                    }
                }
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

    @ViewBuilder
    private var currentPresetPicker: some View {
        switch appState.converter.selectedCategory {
        case .video:
            Picker(
                "",
                selection: Binding(
                    get: { appState.converter.selectedVideoPreset },
                    set: { appState.converter.selectedVideoPreset = $0 }
                )
            ) {
                ForEach(VideoPreset.allCases) { Text($0.rawValue).tag($0) }
            }
        case .audio:
            Picker(
                "",
                selection: Binding(
                    get: { appState.converter.selectedAudioPreset },
                    set: { appState.converter.selectedAudioPreset = $0 }
                )
            ) {
                ForEach(AudioPreset.allCases) { Text($0.rawValue).tag($0) }
            }
        case .gif:
            Picker(
                "",
                selection: Binding(
                    get: { appState.converter.selectedGIFPreset },
                    set: { appState.converter.selectedGIFPreset = $0 }
                )
            ) {
                ForEach(GIFQualityPreset.allCases) { Text($0.rawValue).tag($0) }
            }
        case .image:
            Picker(
                "",
                selection: Binding(
                    get: { appState.converter.selectedImagePreset },
                    set: { appState.converter.selectedImagePreset = $0 }
                )
            ) {
                ForEach(ImagePreset.allCases) { Text($0.rawValue).tag($0) }
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

    var body: some View {
        VStack(spacing: 2) {
            Text(title)
                .font(.system(size: 7.5, weight: .medium))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, minHeight: 32)
        .background(Color.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 7))
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
