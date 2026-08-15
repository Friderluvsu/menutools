import SwiftUI

struct FeaturesListView: View {
    @ObservedObject var appState: AppState

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 5) {
                // 1. Anti-Sleep Feature Card
                FeatureCardRow(
                    title: "Anti-Sleep",
                    subtitle: appState.antiSleep.isActive
                        ? "Preventing sleep (\(appState.antiSleep.statusText))" : "System sleep normal",
                    icon: "cup.and.saucer.fill",
                    iconTint: .orange,
                    isSwitchOn: appState.antiSleep.isActive,
                    isExpandable: true,
                    onToggleSwitch: { appState.antiSleep.toggle() }
                ) {
                    VStack(alignment: .leading, spacing: 8) {
                        // Timer Duration Selector
                        HStack(spacing: 4) {
                            ForEach(AntiSleepManager.durations, id: \.seconds) { dur in
                                Button(action: {
                                    appState.antiSleep.selectDuration(dur.seconds)
                                }) {
                                    Text(dur.label)
                                        .font(.system(size: 10, weight: .bold))
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 4)
                                        .background(
                                            RoundedRectangle(cornerRadius: 5)
                                                .fill(
                                                    appState.antiSleep.selectedDuration == dur.seconds
                                                        ? Color.orange : Color.white.opacity(0.06))
                                        )
                                        .foregroundColor(
                                            appState.antiSleep.selectedDuration == dur.seconds ? .white : .secondary)
                                }
                                .buttonStyle(.plain)
                            }
                        }

                        // Keep display awake toggle
                        HStack {
                            Text("Keep Display Awake")
                                .font(.system(size: 11))
                            Spacer()
                            Toggle(
                                "",
                                isOn: Binding(
                                    get: { appState.antiSleep.preventDisplaySleep },
                                    set: { appState.antiSleep.preventDisplaySleep = $0 }
                                )
                            )
                            .toggleStyle(.switch)
                            .labelsHidden()
                            .controlSize(.mini)
                        }
                    }
                }

                // 2. Network Bypass (VPN + SpoofDPI) Feature Card
                FeatureCardRow(
                    title: "Network Bypass",
                    subtitle: appState.network.isVPNConnected || appState.network.isSpoofDPIRunning
                        ? "Bypass active" : "Disconnected",
                    icon: "network",
                    iconTint: .green,
                    isExpandable: true
                ) {
                    VStack(spacing: 8) {
                        // VanyaVPN Row
                        HStack {
                            Image(systemName: "shield.lefthalf.filled")
                                .foregroundColor(.green)
                            Text("VanyaVPN")
                                .font(.system(size: 11, weight: .medium))
                            Spacer()
                            if appState.network.isVPNTransitioning {
                                ProgressView().controlSize(.mini)
                            } else {
                                Toggle(
                                    "",
                                    isOn: Binding(
                                        get: { appState.network.isVPNConnected },
                                        set: { _ in appState.network.toggleVPN() }
                                    )
                                )
                                .toggleStyle(.switch)
                                .labelsHidden()
                                .controlSize(.mini)
                            }
                        }

                        Divider().background(Color.white.opacity(0.06))

                        // SpoofDPI Row
                        HStack {
                            Image(systemName: "bolt.horizontal.fill")
                                .foregroundColor(.cyan)
                            Text("SpoofDPI (127.0.0.1:1080)")
                                .font(.system(size: 11, weight: .medium))
                            Spacer()
                            if appState.network.isSpoofTransitioning {
                                ProgressView().controlSize(.mini)
                            } else {
                                Toggle(
                                    "",
                                    isOn: Binding(
                                        get: { appState.network.isSpoofDPIRunning },
                                        set: { _ in appState.network.toggleSpoofDPI() }
                                    )
                                )
                                .toggleStyle(.switch)
                                .labelsHidden()
                                .controlSize(.mini)
                            }
                        }
                    }
                }

                // 3. Permute Media Converter Feature Card
                FeatureCardRow(
                    title: "Permute Media Converter",
                    subtitle: "Universal video, audio, GIF & image converter",
                    icon: "arrow.triangle.2.circlepath.circle.fill",
                    iconTint: .pink,
                    isExpandable: true
                ) {
                    MediaConverterTabView(converter: appState.converter)
                        .frame(height: 380)
                }

                // 4. Clipboard Manager Feature Card
                FeatureCardRow(
                    title: "Clipboard History",
                    subtitle: "\(appState.clipboard.items.count) clips saved • ⌥⌘V",
                    icon: "doc.on.clipboard.fill",
                    iconTint: .yellow,
                    isExpandable: true
                ) {
                    ClipboardTabView(clipboard: appState.clipboard)
                        .frame(height: 280)
                }

                // 5. iMessage Navigator Feature Card
                FeatureCardRow(
                    title: "iMessage Navigation",
                    subtitle: appState.iMessage.isEnabled ? "↑/↓ switch chats, ⌥⌫ deletes chat" : "Disabled",
                    icon: "message.fill",
                    iconTint: .blue,
                    isSwitchOn: appState.iMessage.isEnabled,
                    onToggleSwitch: { appState.iMessage.isEnabled.toggle() }
                )

                // 6. Eject All Disks
                FeatureCardRow(
                    title: "Eject All Disks",
                    subtitle: "Safely unmount all external USB volumes",
                    icon: "eject.fill",
                    iconTint: .red,
                    actionButtonTitle: "Eject",
                    onActionButton: { appState.systemUtils.ejectAllDisks() }
                )

                // 7. Reset Google Drive
                FeatureCardRow(
                    title: "Reset Google Drive Sync",
                    subtitle: "Ignore pluginkit Google Drive finder helper",
                    icon: "arrow.triangle.2.circlepath",
                    iconTint: .purple,
                    actionButtonTitle: "Reset",
                    onActionButton: { appState.systemUtils.resetGoogleDriveHelper() }
                )

                // 8. Empty Trash
                FeatureCardRow(
                    title: "Empty Trash",
                    subtitle: "Permanently delete items in Trash",
                    icon: "trash.fill",
                    iconTint: .orange,
                    actionButtonTitle: "Empty",
                    onActionButton: { appState.systemUtils.emptyTrash() }
                )

                // 9. Flush DNS
                FeatureCardRow(
                    title: "Flush DNS Cache",
                    subtitle: "Clear resolver cache & mDNSResponder",
                    icon: "network.badge.shield.half.filled",
                    iconTint: .teal,
                    actionButtonTitle: "Flush",
                    onActionButton: { appState.systemUtils.flushDNS() }
                )

                // 10. Hidden Files
                FeatureCardRow(
                    title: "Show Hidden Files",
                    subtitle: "Toggle visibility of dotfiles in Finder",
                    icon: "eye.fill",
                    iconTint: .indigo,
                    isSwitchOn: appState.systemUtils.isHiddenFilesShown,
                    onToggleSwitch: { appState.systemUtils.toggleHiddenFiles() }
                )

                // 11. Auto-hide Dock
                FeatureCardRow(
                    title: "Auto-hide Dock",
                    subtitle: "Automatically hide and show the macOS Dock",
                    icon: "dock.rectangle",
                    iconTint: .mint,
                    isSwitchOn: appState.systemUtils.isDockAutohideEnabled,
                    onToggleSwitch: { appState.systemUtils.toggleDockAutohide() }
                )
            }
            .padding(MacToolsTheme.outerPadding)
        }
    }
}
