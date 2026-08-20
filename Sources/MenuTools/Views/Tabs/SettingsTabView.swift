import AppKit
import SwiftUI

struct SettingsTabView: View {
    @ObservedObject var appState: AppState

    var body: some View {
        VStack(spacing: MacToolsTheme.sectionSpacing) {
            permissionsCard
            iMessageDiagnosticsCard
            spoofDPISettingsCard
            requirementsCard
            generalCard
            shortcutsCard
            appInfoCard
        }
        .frame(maxWidth: .infinity)
        .onAppear {
            appState.iMessage.refreshPermissions()
        }
    }

    private var permissionsCard: some View {
        MacToolsCard(padding: 9) {
            VStack(alignment: .leading, spacing: 8) {
                SettingsSectionHeader(title: "PERMISSIONS", icon: "hand.raised", color: .orange)

                PermissionRow(
                    title: "Accessibility",
                    detail: "Intercept ↑ and ↓ in Messages",
                    isGranted: appState.iMessage.isAccessibilityGranted,
                    actionTitle: "Open"
                ) {
                    appState.iMessage.openAccessibilitySettings()
                }

                Divider().opacity(0.35)

                PermissionRow(
                    title: "Input Monitoring",
                    detail: "Listen only while Messages is active",
                    isGranted: appState.iMessage.isInputMonitoringGranted,
                    actionTitle: "Open"
                ) {
                    appState.iMessage.openInputMonitoringSettings()
                }

                Divider().opacity(0.35)

                PermissionRow(
                    title: "Keyboard control",
                    detail: "Send ⌃Tab and ⌃⇧Tab",
                    isGranted: appState.iMessage.isKeystrokePostingGranted,
                    actionTitle: "Request"
                ) {
                    appState.iMessage.requestPermissions()
                }

                HStack(spacing: 6) {
                    Button("Request required access") {
                        appState.iMessage.requestPermissions()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.mini)

                    Button("Refresh") {
                        appState.iMessage.refreshPermissions()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                }
            }
        }
    }

    private var iMessageDiagnosticsCard: some View {
        MacToolsCard(padding: 9) {
            VStack(alignment: .leading, spacing: 7) {
                SettingsSectionHeader(title: "MESSAGES SHORTCUTS", icon: "message", color: .blue)

                DiagnosticRow(
                    label: "Listener", value: appState.iMessage.isEventTapActive ? "Running" : "Stopped",
                    isHealthy: appState.iMessage.isEventTapActive)
                DiagnosticRow(
                    label: "Frontmost app", value: appState.iMessage.isMessagesActive ? "Messages" : "Another app",
                    isHealthy: appState.iMessage.isMessagesActive)
                DiagnosticRow(
                    label: "Status", value: appState.iMessage.permissionSummary,
                    isHealthy: appState.iMessage.isEventTapActive)

                if let lastShortcut = appState.iMessage.lastShortcut {
                    DiagnosticRow(label: "Last event", value: lastShortcut, isHealthy: true)
                }

                if let errorMessage = appState.iMessage.errorMessage {
                    Text(errorMessage)
                        .font(.system(size: 9, weight: .regular))
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: 8) {
                    Button("Test previous") { appState.iMessage.testPreviousInMessages() }
                    Button("Test next") { appState.iMessage.testNextInMessages() }
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)

                Text(
                    "The test activates Messages, then sends the same shortcuts as the original Keyboard Maestro macro."
                )
                .font(.system(size: 8.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var requirementsCard: some View {
        MacToolsCard(padding: 9) {
            VStack(alignment: .leading, spacing: 7) {
                SettingsSectionHeader(title: "REQUIREMENTS", icon: "checklist", color: .green)

                RequirementRow(
                    title: "FFmpeg",
                    detail: appState.converter.ffmpegPath ?? "Not found",
                    isAvailable: ffmpegIsAvailable
                )
                RequirementRow(title: "macOS", detail: "14.0 or newer", isAvailable: true)
                RequirementRow(
                    title: "VanyaVPN", detail: "Only required for the VPN toggle", isAvailable: true, isOptional: true)
                RequirementRow(
                    title: "SpoofDPI",
                    detail: appState.network.spoofDPIPath ?? "Not found",
                    isAvailable: appState.network.isSpoofDPIAvailable
                )

                Text(
                    "Finder, Trash and DNS actions may ask for Automation or administrator approval when you run them."
                )
                .font(.system(size: 8.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var spoofDPISettingsCard: some View {
        MacToolsCard(padding: 9) {
            VStack(alignment: .leading, spacing: 8) {
                SettingsSectionHeader(title: "SPOOFDPI", icon: "bolt.horizontal", color: .cyan)

                HStack(spacing: 10) {
                    SettingsLabel(title: "SOCKS5 endpoint", detail: "Local proxy address")
                    Spacer(minLength: 8)
                    Text("127.0.0.1")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Stepper(
                        value: Binding(
                            get: { appState.network.spoofPort },
                            set: { appState.network.spoofPort = min(max($0, 1024), 65535) }
                        ),
                        in: 1024...65535
                    ) {
                        Text(String(appState.network.spoofPort))
                            .font(.system(size: 9, weight: .medium, design: .monospaced))
                            .frame(width: 34, alignment: .trailing)
                    }
                    .controlSize(.mini)
                    .disabled(appState.network.isSpoofDPIRunning)
                }

                Divider().opacity(0.35)

                HStack(spacing: 10) {
                    SettingsLabel(title: "DNS", detail: "Resolution used by SpoofDPI")
                    Spacer(minLength: 8)
                    Picker(
                        "",
                        selection: Binding(
                            get: { appState.network.spoofDNSMode },
                            set: { appState.network.spoofDNSMode = $0 }
                        )
                    ) {
                        ForEach(SpoofDNSMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .controlSize(.small)
                    .frame(width: 92)
                    .disabled(appState.network.isSpoofDPIRunning)
                }

                Divider().opacity(0.35)

                HStack(spacing: 10) {
                    SettingsLabel(
                        title: "System proxy",
                        detail: "Apply SOCKS5 automatically while running"
                    )
                    Spacer(minLength: 8)
                    Toggle(
                        "",
                        isOn: Binding(
                            get: { appState.network.configureSystemProxy },
                            set: { appState.network.configureSystemProxy = $0 }
                        )
                    )
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .disabled(appState.network.isSpoofDPIRunning)
                }

                HStack(spacing: 7) {
                    Circle()
                        .fill(appState.network.isSpoofDPIRunning ? Color.green : Color.secondary.opacity(0.45))
                        .frame(width: 6, height: 6)
                    Text(
                        appState.network.isSpoofDPIRunning
                            ? "Running at \(appState.network.spoofEndpoint)"
                            : "Ready · settings apply on next start"
                    )
                    .font(.system(size: 8.5))
                    .foregroundStyle(.secondary)
                    Spacer()
                }

                if let error = appState.network.errorMessage {
                    Text(error)
                        .font(.system(size: 8.5))
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var generalCard: some View {
        MacToolsCard(padding: 9) {
            VStack(alignment: .leading, spacing: 8) {
                SettingsSectionHeader(title: "GENERAL", icon: "gearshape", color: .secondary)

                HStack(spacing: 10) {
                    SettingsLabel(title: "Menu bar icon", detail: "Icon shown in the macOS menu bar")
                    Spacer(minLength: 8)
                    Picker(
                        "",
                        selection: Binding(
                            get: { appState.menuBarIconStyle },
                            set: { appState.menuBarIconStyle = $0 }
                        )
                    ) {
                        ForEach(MenuBarIconStyle.allCases) { style in
                            Text(style.rawValue).tag(style)
                        }
                    }
                    .labelsHidden()
                    .controlSize(.small)
                    .frame(width: 160)
                }

                Divider().opacity(0.35)

                HStack(spacing: 10) {
                    SettingsLabel(title: "Launch at Login", detail: "Start MenuTools after sign-in")
                    Spacer(minLength: 8)
                    Toggle(
                        "",
                        isOn: Binding(
                            get: { appState.launchAtLogin },
                            set: { _ in appState.toggleLaunchAtLogin() }
                        )
                    )
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                }

                Divider().opacity(0.35)

                HStack(spacing: 10) {
                    SettingsLabel(title: "Menu bar text", detail: "Optional live status beside the icon")
                    Spacer(minLength: 8)
                    Picker(
                        "",
                        selection: Binding(
                            get: { appState.statusDisplayMode },
                            set: { appState.setStatusDisplayMode($0) }
                        )
                    ) {
                        ForEach(StatusItemDisplayMode.allCases) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .controlSize(.small)
                    .frame(width: 160)
                }
            }
        }
    }

    private var shortcutsCard: some View {
        MacToolsCard(padding: 9) {
            VStack(alignment: .leading, spacing: 6) {
                SettingsSectionHeader(title: "SHORTCUTS", icon: "keyboard", color: .purple)
                ShortcutRow(shortcut: "⌥⌘V", description: "Open Clipboard HUD")
                ShortcutRow(shortcut: "↑ / ↓", description: "Previous / next Messages chat")
                ShortcutRow(shortcut: "⌃⇧Tab / ⌃Tab", description: "Commands sent to Messages")
                ShortcutRow(shortcut: "⌥⌫", description: "Delete current conversation")
            }
        }
    }

    private var appInfoCard: some View {
        MacToolsCard(padding: 9) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("MenuTools 1.0")
                        .font(.system(size: 10.5, weight: .semibold))
                    Text("Native Swift · local data · menu bar only")
                        .font(.system(size: 8.5))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                    .tint(.red)
            }
        }
    }

    private var ffmpegIsAvailable: Bool {
        guard let path = appState.converter.ffmpegPath else { return false }
        return FileManager.default.isExecutableFile(atPath: path)
    }

}

private struct SettingsSectionHeader: View {
    let title: String
    let icon: String
    let color: Color

    var body: some View {
        Label(title, systemImage: icon)
            .font(.system(size: 8, weight: .semibold))
            .foregroundStyle(color)
    }
}

private struct SettingsLabel: View {
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 10, weight: .medium))
            Text(detail)
                .font(.system(size: 8.5))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }
}

private struct PermissionRow: View {
    let title: String
    let detail: String
    let isGranted: Bool
    let actionTitle: String
    let action: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: isGranted ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(isGranted ? .green : .orange)
                .font(.system(size: 12))
                .frame(width: 16)
            SettingsLabel(title: title, detail: detail)
            Spacer(minLength: 6)
            if isGranted {
                Text("Granted")
                    .font(.system(size: 8.5, weight: .semibold))
                    .foregroundStyle(.green)
            } else {
                Button(actionTitle, action: action)
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
            }
        }
    }
}

private struct DiagnosticRow: View {
    let label: String
    let value: String
    let isHealthy: Bool

    var body: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(isHealthy ? Color.green : Color.orange)
                .frame(width: 6, height: 6)
            Text(label)
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value)
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
    }
}

private struct RequirementRow: View {
    let title: String
    let detail: String
    let isAvailable: Bool
    var isOptional = false

    var body: some View {
        HStack(spacing: 8) {
            Image(
                systemName: isAvailable
                    ? "checkmark.circle.fill" : (isOptional ? "minus.circle.fill" : "xmark.circle.fill")
            )
            .foregroundStyle(isAvailable ? .green : (isOptional ? .secondary : .red))
            .frame(width: 16)
            Text(title)
                .font(.system(size: 9.5, weight: .medium))
                .frame(width: 68, alignment: .leading)
            Text(detail)
                .font(.system(size: 8.5))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
    }
}

private struct ShortcutRow: View {
    let shortcut: String
    let description: String

    var body: some View {
        HStack(spacing: 8) {
            Text(description)
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(shortcut)
                .font(.system(size: 8.5, weight: .semibold, design: .monospaced))
                .lineLimit(1)
                .padding(.horizontal, 7)
                .frame(minHeight: 20)
                .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
        }
    }
}
