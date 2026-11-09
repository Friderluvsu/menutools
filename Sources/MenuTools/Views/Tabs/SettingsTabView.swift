import AppKit
import SwiftUI

/// Settings is split into short pages so the panel always fits its content without scrolling.
enum SettingsSection: String, CaseIterable, Identifiable {
    case general = "General"
    case look = "Look"
    case windows = "Windows"
    case mouse = "Mouse"
    case messages = "Messages"
    case network = "Network"

    var id: String { rawValue }

    /// SF Symbol for the tab (filled when selected). Mouse is drawn by `MouseGlyph`.
    func symbol(selected: Bool) -> String? {
        switch self {
        case .general: return selected ? "gearshape.fill" : "gearshape"
        case .look: return selected ? "paintpalette.fill" : "paintpalette"
        case .windows: return "macwindow.on.rectangle"
        case .mouse: return nil
        case .messages: return selected ? "bubble.left.and.bubble.right.fill" : "bubble.left.and.bubble.right"
        case .network: return "globe"
        }
    }
}

/// Icon tabs with a small label, equal widths. A text segmented control with six pages is wider
/// than the panel and pushes every page out to the edges.
private struct SettingsTabBar: View {
    @Binding var selection: SettingsSection
    @Environment(\.appTheme) private var theme

    var body: some View {
        HStack(spacing: 2) {
            ForEach(SettingsSection.allCases) { section in
                let isSelected = section == selection
                Button {
                    selection = section
                } label: {
                    VStack(spacing: 2) {
                        Group {
                            if let symbol = section.symbol(selected: isSelected) {
                                Image(systemName: symbol)
                                    .font(.system(size: 13, weight: .medium))
                            } else {
                                MouseGlyph(filled: isSelected)
                                    .frame(width: 10.5, height: 15)
                            }
                        }
                        .frame(height: 16)
                        Text(section.rawValue)
                            .font(.system(size: 9.5, weight: isSelected ? .semibold : .medium))
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                    .foregroundStyle(isSelected ? AnyShapeStyle(theme.accent) : AnyShapeStyle(.secondary))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 5)
                    .background(
                        isSelected ? theme.accent.opacity(0.14) : Color.clear,
                        in: RoundedRectangle(cornerRadius: theme.radius(7), style: .continuous)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .suppressesFocusRing()
                .help(section.rawValue)
            }
        }
        .padding(2)
        .background(theme.tileFill, in: RoundedRectangle(cornerRadius: theme.radius(9), style: .continuous))
    }
}

/// A mouse with a small wheel pill and no button split line. Filled: solid body, wheel cut out.
struct MouseGlyph: View {
    var filled = false

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let body = RoundedRectangle(cornerRadius: size.width * 0.5, style: .continuous)
            let wheel = Capsule()
                .frame(width: max(1.6, size.width * 0.16), height: size.height * 0.24)
                .offset(y: -size.height * 0.2)
            if filled {
                body
                    .fill(.foreground)
                    .overlay(wheel.blendMode(.destinationOut))
                    .compositingGroup()
            } else {
                ZStack {
                    body.strokeBorder(.foreground, lineWidth: max(1.2, size.width * 0.13))
                    wheel
                }
            }
        }
    }
}

private struct SettingsSectionHeightKey: PreferenceKey {
    static var defaultValue: [SettingsSection: CGFloat] = [:]

    static func reduce(value: inout [SettingsSection: CGFloat], nextValue: () -> [SettingsSection: CGFloat]) {
        value.merge(nextValue(), uniquingKeysWith: { max($0, $1) })
    }
}

struct SettingsTabView: View {
    @ObservedObject var appState: AppState
    @AppStorage("SettingsSection") private var section: SettingsSection = .general
    @State private var isAddingCustomException = false
    @State private var customBundleId = ""
    @State private var sectionHeights: [SettingsSection: CGFloat] = [:]

    var body: some View {
        VStack(spacing: MacToolsTheme.sectionSpacing) {
            SettingsTabBar(selection: $section)
                .padding(.bottom, 2)

            // All pages are built with Settings. A tab click only changes which
            // one is visible, and the well stays at the tallest page so the panel
            // window is not resized.
            ZStack(alignment: .top) {
                ForEach(SettingsSection.allCases) { page in
                    SettingsSectionPage(
                        page: page,
                        appState: appState,
                        isAddingCustomException: $isAddingCustomException,
                        customBundleId: $customBundleId
                    )
                    .opacity(page == section ? 1 : 0)
                    .allowsHitTesting(page == section)
                    .accessibilityHidden(page != section)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                }
            }
            .frame(maxWidth: .infinity, alignment: .top)
            .frame(height: lockedContentHeight, alignment: .top)
            .animation(nil, value: section)
            .clipped()
        }
        .frame(maxWidth: .infinity)
        .onPreferenceChange(SettingsSectionHeightKey.self) { heights in
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                for (page, height) in heights where height > 1 {
                    sectionHeights[page] = height
                }
            }
        }
        .onAppear {
            appState.iMessage.refreshPermissions()
            appState.windowManager.refreshPermissions()
            appState.mouse.refreshPermissions()
        }
    }

    /// Tallest measured page. Tab switches must not change this, or the window relayouts.
    private var lockedContentHeight: CGFloat? {
        sectionHeights.values.filter { $0 > 1 }.max()
    }
}

/// One settings page. Its inputs do not include the selected tab, so a tab click
/// does not rebuild its cards.
private struct SettingsSectionPage: View {
    let page: SettingsSection
    @ObservedObject var appState: AppState
    @ObservedObject private var iMessage: IMessageHelper
    @ObservedObject private var shelf = ShelfManager.shared
    @Binding var isAddingCustomException: Bool
    @Binding var customBundleId: String

    init(
        page: SettingsSection,
        appState: AppState,
        isAddingCustomException: Binding<Bool>,
        customBundleId: Binding<String>
    ) {
        self.page = page
        self.appState = appState
        _iMessage = ObservedObject(wrappedValue: appState.iMessage)
        _isAddingCustomException = isAddingCustomException
        _customBundleId = customBundleId
    }

    var body: some View {
        VStack(spacing: MacToolsTheme.sectionSpacing) {
            switch page {
            case .general:
                generalCard
                shelfCard
                ClipboardSettingsCard(clipboard: appState.clipboard)
                AILimitsSettingsCard(manager: appState.aiLimits)
                appInfoCard
            case .look:
                ThemeGallery()
                DashboardLayoutCard()
            case .windows:
                permissionsCard
                windowControlsCard
            case .mouse:
                MouseSettingsPage(mouse: appState.mouse)
            case .messages:
                messagesCard
                shortcutsCard
            case .network:
                spoofDPICard
                requirementsCard
            }
        }
        .frame(maxWidth: .infinity, alignment: .top)
        .fixedSize(horizontal: false, vertical: true)
        .background(
            GeometryReader { proxy in
                Color.clear.preference(key: SettingsSectionHeightKey.self, value: [page: proxy.size.height])
            }
        )
    }

    // MARK: - Permissions

    private var permissionsCard: some View {
        SettingsCard(title: "Permissions", icon: "hand.raised", color: .orange) {
            PermissionRow(
                title: "Accessibility",
                isGranted: appState.windowManager.isAccessibilityGranted || appState.iMessage.isAccessibilityGranted,
                action: appState.windowManager.openAccessibilitySettings
            )
            Divider().opacity(0.35)
            PermissionRow(
                title: "Input Monitoring",
                isGranted: appState.iMessage.isInputMonitoringGranted,
                action: appState.iMessage.openInputMonitoringSettings
            )
            Divider().opacity(0.35)
            PermissionRow(
                title: "Keyboard Control",
                isGranted: appState.iMessage.isKeystrokePostingGranted,
                action: appState.iMessage.requestPermissions
            )

            HStack(spacing: 6) {
                Button("Request All") {
                    appState.windowManager.requestPermissions()
                    appState.iMessage.requestPermissions()
                }
                .buttonStyle(.borderedProminent)
                Button("Refresh") {
                    appState.windowManager.refreshPermissions()
                    appState.iMessage.refreshPermissions()
                }
                .buttonStyle(.bordered)
            }
            .controlSize(.small)
            .padding(.top, 2)
        }
    }

    // MARK: - Window controls

    private var windowControlsCard: some View {
        SettingsCard(title: "Window Controls", icon: "macwindow", color: .green) {
            SettingsRow(title: "Maximize on green click") {
                toggle(
                    get: { appState.windowManager.isMaximizeOnGreenEnabled },
                    set: { appState.windowManager.isMaximizeOnGreenEnabled = $0 })
            }

            if appState.windowManager.isMaximizeOnGreenEnabled {
                SettingsRow(title: "Smooth animation", isSecondary: true) {
                    toggle(
                        get: { appState.windowManager.isAnimateResizeEnabled },
                        set: { appState.windowManager.isAnimateResizeEnabled = $0 })
                }
                .padding(.leading, 12)
            }

            Divider().opacity(0.35)

            SettingsRow(title: "Quit on red click") {
                toggle(
                    get: { appState.windowManager.isQuitOnCloseEnabled },
                    set: { appState.windowManager.isQuitOnCloseEnabled = $0 })
            }

            if appState.windowManager.isQuitOnCloseEnabled {
                SettingsRow(title: "Quit mode", isSecondary: true) {
                    Picker(
                        "",
                        selection: Binding(
                            get: { appState.windowManager.quitOnCloseMode },
                            set: { appState.windowManager.quitOnCloseMode = $0 })
                    ) {
                        ForEach(QuitOnCloseMode.allCases) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .controlSize(.small)
                    .frame(width: 130)
                }
                .padding(.leading, 12)
            }

            Divider().opacity(0.35)

            DiagnosticRow(
                label: "Listener",
                value: appState.windowManager.isEventTapActive
                    ? "Running"
                    : (appState.windowManager.isAccessibilityGranted ? "Off" : "No access"),
                isHealthy: appState.windowManager.isEventTapActive)

            if !appState.windowManager.isAccessibilityGranted
                && (appState.windowManager.isMaximizeOnGreenEnabled || appState.windowManager.isQuitOnCloseEnabled)
            {
                HStack {
                    Text("Needs Accessibility")
                        .font(.system(size: 11))
                        .foregroundStyle(.orange)
                    Spacer()
                    Button("Grant") { appState.windowManager.requestPermissions() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                }
            }

            Divider().opacity(0.35)

            excludedApps
        }
    }

    private var excludedApps: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Excluded apps")
                    .font(.system(size: 11, weight: .medium))
                Spacer()
                RunningAppsMenu(
                    title: "Add", taken: Set(appState.windowManager.exceptions.map(\.id)),
                    custom: { isAddingCustomException.toggle() }
                ) { id, name in
                    appState.windowManager.addException(bundleId: id, name: name)
                }
            }

            if isAddingCustomException {
                HStack(spacing: 6) {
                    TextField("com.example.app", text: $customBundleId)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11, design: .monospaced))
                    Button("Add") {
                        let id = customBundleId.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !id.isEmpty {
                            appState.windowManager.addException(bundleId: id, name: id)
                            customBundleId = ""
                            isAddingCustomException = false
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(customBundleId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .controlSize(.small)
                }
            }

            if appState.windowManager.exceptions.isEmpty {
                Text("None")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 4) {
                    ForEach(appState.windowManager.exceptions) { exception in
                        HStack(spacing: 6) {
                            Text(exception.name)
                                .font(.system(size: 11, weight: .medium))
                                .lineLimit(1)
                            Text(exception.id)
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer(minLength: 4)
                            Button {
                                appState.windowManager.removeException(bundleId: exception.id)
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
                    }
                }
            }
        }
    }

    // MARK: - Messages

    private var messagesCard: some View {
        SettingsCard(title: "Messages", icon: "message", color: .blue) {
            SettingsRow(title: "Navigation shortcuts") {
                toggle(
                    get: { appState.iMessage.isEnabled },
                    set: { appState.iMessage.isEnabled = $0 })
            }

            Divider().opacity(0.35)

            DiagnosticRow(
                label: "Listener",
                value: appState.iMessage.isEventTapActive ? "Running" : "Stopped",
                isHealthy: appState.iMessage.isEventTapActive)
            DiagnosticRow(
                label: "Status",
                value: appState.iMessage.permissionSummary,
                isHealthy: appState.iMessage.isEventTapActive)
            if let lastShortcut = appState.iMessage.lastShortcut {
                DiagnosticRow(label: "Last event", value: lastShortcut, isHealthy: true)
            }

            if let errorMessage = appState.iMessage.errorMessage {
                Text(errorMessage)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 8) {
                Button("Test Prev") { appState.iMessage.testPreviousInMessages() }
                Button("Test Next") { appState.iMessage.testNextInMessages() }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    // MARK: - SpoofDPI

    private var spoofDPICard: some View {
        SettingsCard(title: "SpoofDPI", icon: "bolt.horizontal", color: .cyan) {
            SettingsRow(title: "Port") {
                Stepper(
                    value: Binding(
                        get: { appState.network.spoofPort },
                        set: { appState.network.spoofPort = min(max($0, 1024), 65535) }
                    ),
                    in: 1024...65535
                ) {
                    Text(String(appState.network.spoofPort))
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                }
                .controlSize(.small)
                .disabled(appState.network.isSpoofDPIRunning)
            }

            Divider().opacity(0.35)

            SettingsRow(title: "DNS") {
                Picker(
                    "",
                    selection: Binding(
                        get: { appState.network.spoofDNSMode },
                        set: { appState.network.spoofDNSMode = $0 })
                ) {
                    ForEach(SpoofDNSMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .labelsHidden()
                .controlSize(.small)
                .frame(width: 100)
                .disabled(appState.network.isSpoofDPIRunning)
            }

            SettingsRow(title: "System proxy") {
                toggle(
                    get: { appState.network.configureSystemProxy },
                    set: { appState.network.configureSystemProxy = $0 }
                )
                .disabled(appState.network.isSpoofDPIRunning)
            }

            Divider().opacity(0.35)

            HStack(spacing: 7) {
                Circle()
                    .fill(appState.network.isSpoofDPIRunning ? Color.green : Color.secondary.opacity(0.45))
                    .frame(width: 7, height: 7)
                Text(appState.network.isSpoofDPIRunning ? appState.network.spoofEndpoint : "Stopped")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
            }

            if let error = appState.network.errorMessage {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Requirements

    private var requirementsCard: some View {
        SettingsCard(title: "Requirements", icon: "checklist", color: .green) {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 2) {
                GridRow {
                    RequirementRow(
                        title: "FFmpeg", isAvailable: ffmpegIsAvailable, help: appState.converter.ffmpegPath)
                    RequirementRow(
                        title: "SpoofDPI",
                        isAvailable: appState.network.isSpoofDPIAvailable,
                        help: appState.network.spoofDPIPath)
                }
                GridRow {
                    RequirementRow(title: "macOS 14.0+", isAvailable: true)
                    RequirementRow(title: "VanyaVPN", isAvailable: true, isOptional: true)
                }
            }
        }
    }

    // MARK: - General

    private var generalCard: some View {
        SettingsCard(title: "General", icon: "gearshape", color: .secondary) {
            StatusLightsRows(appState: appState)

            Divider().opacity(0.35)

            MenuBarItemsRow()

            Divider().opacity(0.35)

            LidBatteryGuardRow(antiSleep: appState.antiSleep)

            Divider().opacity(0.35)

            SettingsRow(title: "Universal Control auto-enable") {
                toggle(
                    get: { appState.universalControl.isAutoEnableEnabled },
                    set: { appState.universalControl.isAutoEnableEnabled = $0 })
            }

            SettingsRow(title: "Launch at login") {
                toggle(
                    get: { appState.launchAtLogin },
                    set: { _ in appState.toggleLaunchAtLogin() })
            }
        }
    }

    // MARK: - Shelf

    private var shelfCard: some View {
        SettingsCard(title: "Shelf", icon: "tray.full", color: .secondary) {
            SettingsRow(title: "Enabled") {
                toggle(get: { shelf.isEnabled }, set: { shelf.isEnabled = $0 })
            }
            SettingsRow(title: "Show on file drag", isSecondary: true) {
                toggle(get: { shelf.showOnDrag }, set: { shelf.showOnDrag = $0 })
                    .disabled(!shelf.isEnabled)
            }
            .padding(.leading, 12)
        }
    }

    // MARK: - Shortcuts & info

    private var shortcutsCard: some View {
        SettingsCard(title: "Shortcuts", icon: "keyboard", color: .purple) {
            ShortcutRow(shortcut: "⌥⌘V", description: "Clipboard")
            ShortcutRow(shortcut: "⇧⌥⌘V", description: "Paste plain")
            ShortcutRow(shortcut: "↑ ↓", description: "Previous / next chat")
            ShortcutRow(shortcut: "⌥⌫", description: "Delete chat")
            ShortcutRow(shortcut: "Green click", description: "Maximize")
            ShortcutRow(shortcut: "Red click", description: "Close / quit")
        }
    }

    private var appInfoCard: some View {
        MacToolsCard(padding: 8) {
            HStack {
                Text("MenuTools 1.0")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .tint(.red)
            }
        }
    }

    // MARK: - Helpers

    private var ffmpegIsAvailable: Bool {
        guard let path = appState.converter.ffmpegPath else { return false }
        return FileManager.default.isExecutableFile(atPath: path)
    }

    private func toggle(get: @escaping () -> Bool, set: @escaping (Bool) -> Void) -> some View {
        Toggle("", isOn: Binding(get: get, set: set))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)
    }
}

// MARK: - Closed-lid battery guard

/// Closed-lid turns itself off when the battery (unplugged) reaches this level.
private struct LidBatteryGuardRow: View {
    @ObservedObject var antiSleep: AntiSleepManager

    var body: some View {
        SettingsRow(title: "Closed-lid battery stop") {
            Picker("", selection: $antiSleep.lidBatteryGuard) {
                ForEach(AntiSleepManager.batteryGuardOptions, id: \.self) { level in
                    Text(level == 0 ? "Off" : "\(level)%").tag(level)
                }
            }
            .labelsHidden()
            .controlSize(.small)
            .frame(width: 80)
            .help("Closed-lid turns off at this battery level when unplugged")
        }
    }
}

// MARK: - Status lights

/// Menu bar icon. "Status lights" on: colour session lights (style, animation, demo) and a separate
/// panel icon. Off: one static icon, which also shows in the panel header.
private struct StatusLightsRows: View {
    @ObservedObject var appState: AppState
    @ObservedObject private var settings = StatusLightSettings.shared
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        SettingsRow(title: "Status lights") {
            HStack(spacing: 6) {
                if settings.enabled {
                    Button("Test") { settings.playDemo() }
                        .controlSize(.small)
                        .fixedSize()
                        .help("Play a demo in the menu bar")
                }
                Toggle("", isOn: $settings.enabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .help("Colour lights for sessions. Off shows a static icon.")
            }
        }
        if settings.enabled {
            SettingsRow(title: "Style", isSecondary: true) {
                Picker("", selection: $settings.style) {
                    ForEach(StatusLightStyle.Group.allCases, id: \.self) { group in
                        Section(group.rawValue) {
                            ForEach(StatusLightStyle.allCases.filter { $0.group == group }) { style in
                                Label {
                                    Text(style.rawValue)
                                } icon: {
                                    Image(nsImage: preview(style))
                                }
                                .tag(style)
                            }
                        }
                    }
                }
                .labelsHidden()
                .controlSize(.small)
                .frame(width: 128)
            }
            .padding(.leading, 12)
            SettingsRow(title: "Animate", isSecondary: true) {
                Toggle("", isOn: $settings.animations)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }
            .padding(.leading, 12)
            SettingsRow(title: "Extras", isSecondary: true) {
                HStack(spacing: 4) {
                    ExtraToggle(symbol: "timer", help: Self.busyHelp, isOn: $settings.busyTimer)
                    ExtraToggle(symbol: "speaker.wave.2", help: Self.soundsHelp, isOn: $settings.sounds)
                    ExtraToggle(
                        symbol: "eye", help: "Hover peek: hover the icon to see sessions", isOn: $settings.hoverPeek)
                    ExtraToggle(
                        symbol: "sparkles", help: "Celebrate when the last run finishes", isOn: $settings.celebrate)
                }
            }
            .padding(.leading, 12)
            if settings.animations {
                SettingsRow(title: "Idle life", isSecondary: true) {
                    Toggle("", isOn: $settings.idleLife)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .help("A small gesture now and then; a reminder pop when input waits over 2 min")
                }
                .padding(.leading, 12)
            }
        }
        Divider().opacity(0.35)
        SettingsRow(title: settings.enabled ? "Panel icon" : "Menu bar icon") {
            Picker(
                "",
                selection: Binding(
                    get: { appState.menuBarIconStyle },
                    set: { appState.menuBarIconStyle = $0 })
            ) {
                ForEach(MenuBarIconStyle.allCases) { style in
                    Label(style.rawValue, systemImage: style.symbolName).tag(style)
                }
            }
            .labelsHidden()
            .controlSize(.small)
            .frame(width: 190)
        }
    }

    private static let busyHelp = "Busy timer: a line under the icon fills over an hour of work"
    private static let soundsHelp = "Sounds: a chime for input, a tick when a run is done"

    /// Two lights on, so the menu shows how each style reads (count styles: 1 input, 2 running).
    private func preview(_ style: StatusLightStyle) -> NSImage {
        StatusLightsRenderer.image(
            style: style,
            lights: [StatusLightFrame(level: 1), StatusLightFrame(level: 1), StatusLightFrame(level: 0)],
            isDark: scheme == .dark, counts: [1, 2, 0])
    }
}

/// Items shown beside the menu bar icon: one switch per item, lit when shown.
private struct MenuBarItemsRow: View {
    @ObservedObject private var store = MenuBarItemsStore.shared

    var body: some View {
        SettingsRow(title: "Menu bar") {
            HStack(spacing: 3) {
                ForEach(MenuBarItem.allCases) { item in
                    ExtraToggle(
                        symbol: item.symbol, help: item.title,
                        isOn: Binding(get: { store.items.contains(item) }, set: { _ in store.toggle(item) }))
                }
            }
        }
    }
}

/// Small icon switch: lit when on.
private struct ExtraToggle: View {
    let symbol: String
    let help: String
    @Binding var isOn: Bool
    @Environment(\.appTheme) private var theme

    var body: some View {
        Button {
            isOn.toggle()
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(isOn ? AnyShapeStyle(theme.accent) : AnyShapeStyle(.tertiary))
                .frame(width: 24, height: 20)
                .background(
                    isOn ? theme.accent.opacity(0.15) : Color.primary.opacity(0.05),
                    in: RoundedRectangle(cornerRadius: 5, style: .continuous)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("\(help) (\(isOn ? "on" : "off"))")
    }
}

// MARK: - AI Limits

private struct AILimitsSettingsCard: View {
    @ObservedObject var manager: AILimitsManager

    var body: some View {
        SettingsCard(title: "AI Limits", icon: "sparkles", color: .secondary) {
            ForEach(Array(AIProvider.allCases.enumerated()), id: \.element) { index, provider in
                if index > 0 { Divider().opacity(0.35) }
                SettingsRow(title: provider.displayName) {
                    Toggle(
                        "",
                        isOn: Binding(
                            get: { manager.enabledProviders.contains(provider) },
                            set: { manager.setEnabled(provider, $0) })
                    )
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                }
            }
        }
    }
}

// MARK: - Building blocks

/// Card with a readable header; every settings section uses this so spacing and type stay consistent.
struct SettingsCard<Content: View>: View {
    let title: String
    let icon: String
    let color: Color
    @ViewBuilder let content: Content

    var body: some View {
        MacToolsCard(padding: 8) {
            VStack(alignment: .leading, spacing: 5) {
                Label(title, systemImage: icon)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(color)
                content
            }
        }
    }
}

/// Single row: title on the left, control on the right.
struct SettingsRow<Trailing: View>: View {
    let title: String
    var isSecondary = false
    @ViewBuilder let trailing: Trailing

    var body: some View {
        HStack(spacing: 10) {
            Text(title)
                .font(.system(size: 11.5, weight: isSecondary ? .regular : .medium))
                .foregroundStyle(isSecondary ? .secondary : .primary)
                .lineLimit(1)
            Spacer(minLength: 8)
            trailing
        }
        .frame(minHeight: 22)
    }
}

private struct PermissionRow: View {
    let title: String
    let isGranted: Bool
    let action: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: isGranted ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(isGranted ? .green : .orange)
                .font(.system(size: 13))
            Text(title)
                .font(.system(size: 11.5, weight: .medium))
            Spacer(minLength: 6)
            if isGranted {
                Text("Granted")
                    .font(.system(size: 11))
                    .foregroundStyle(.green)
            } else {
                Button("Open", action: action)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
        .frame(minHeight: 24)
    }
}

struct DiagnosticRow: View {
    let label: String
    let value: String
    let isHealthy: Bool

    var body: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(isHealthy ? Color.green : Color.orange)
                .frame(width: 7, height: 7)
            Text(label)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(isHealthy ? Color.primary : Color.orange)
                .lineLimit(1)
        }
        .frame(minHeight: 22)
    }
}

private struct RequirementRow: View {
    let title: String
    let isAvailable: Bool
    var isOptional = false
    var help: String? = nil

    var body: some View {
        HStack(spacing: 8) {
            Image(
                systemName: isAvailable
                    ? "checkmark.circle.fill" : (isOptional ? "minus.circle.fill" : "xmark.circle.fill")
            )
            .font(.system(size: 13))
            .foregroundStyle(isAvailable ? .green : (isOptional ? .secondary : .red))
            Text(title)
                .font(.system(size: 11.5, weight: .medium))
            Spacer(minLength: 0)
        }
        .frame(minHeight: 22)
        .help(help ?? "")
    }
}

private struct ClipboardSettingsCard: View {
    @ObservedObject var clipboard: ClipboardManager

    var body: some View {
        SettingsCard(title: "Clipboard", icon: "doc.on.clipboard", color: .secondary) {
            SettingsRow(title: "Images") {
                Toggle("", isOn: $clipboard.captureImages)
                    .labelsHidden().toggleStyle(.switch).controlSize(.small)
            }
            SettingsRow(title: "Files") {
                Toggle("", isOn: $clipboard.captureFiles)
                    .labelsHidden().toggleStyle(.switch).controlSize(.small)
            }
            SettingsRow(title: "Plain paste ⇧⌥⌘V") {
                Toggle("", isOn: $clipboard.plainPasteHotkey)
                    .labelsHidden().toggleStyle(.switch).controlSize(.small)
            }
        }
    }
}

private struct ShortcutRow: View {
    let shortcut: String
    let description: String

    var body: some View {
        HStack(spacing: 8) {
            Text(shortcut)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .padding(.horizontal, 7)
                .frame(minWidth: 62, minHeight: 20)
                .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 5))
            Text(description)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
    }
}
