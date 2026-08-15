import SwiftUI

struct SearchableAction: Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let icon: String
    let iconTint: Color
    let action: () -> Void
}

struct UnifiedSearchPalette: View {
    @ObservedObject var appState: AppState
    @Binding var isPresented: Bool
    @State private var query: String = ""
    @FocusState private var isFocused: Bool

    var allActions: [SearchableAction] {
        [
            SearchableAction(
                id: "anti-sleep",
                title: "Toggle Anti-Sleep (Caffeinate)",
                subtitle: appState.antiSleep.isActive
                    ? "Currently ON (\(appState.antiSleep.statusText))" : "Currently OFF",
                icon: "cup.and.saucer.fill",
                iconTint: .orange,
                action: { appState.antiSleep.toggle() }
            ),
            SearchableAction(
                id: "vpn",
                title: "Toggle VanyaVPN",
                subtitle: appState.network.isVPNConnected ? "Connected" : "Disconnected",
                icon: "shield.lefthalf.filled",
                iconTint: .green,
                action: { appState.network.toggleVPN() }
            ),
            SearchableAction(
                id: "spoof",
                title: "Toggle SpoofDPI (SOCKS5 127.0.0.1:1080)",
                subtitle: appState.network.isSpoofDPIRunning ? "Running" : "Stopped",
                icon: "bolt.horizontal.fill",
                iconTint: .cyan,
                action: { appState.network.toggleSpoofDPI() }
            ),
            SearchableAction(
                id: "converter",
                title: "Open Permute Media Converter",
                subtitle: "Convert Video, Audio, GIF, Images",
                icon: "arrow.triangle.2.circlepath",
                iconTint: .pink,
                action: { appState.selectedTab = .features }
            ),
            SearchableAction(
                id: "clipboard",
                title: "Open Clipboard HUD (⌥⌘V)",
                subtitle: "Search and paste from clipboard history",
                icon: "doc.on.clipboard.fill",
                iconTint: .yellow,
                action: { ClipboardHUDWindowController.shared.show() }
            ),
            SearchableAction(
                id: "imessage",
                title: "Toggle iMessage Navigation Shortcuts",
                subtitle: "Up/Down chat navigation and Option+Delete removal",
                icon: "message.fill",
                iconTint: .blue,
                action: { appState.iMessage.isEnabled.toggle() }
            ),
            SearchableAction(
                id: "eject",
                title: "Eject All External Disks",
                subtitle: "Safely unmount all USB and external volumes",
                icon: "eject.fill",
                iconTint: .red,
                action: { appState.systemUtils.ejectAllDisks() }
            ),
            SearchableAction(
                id: "empty-trash",
                title: "Empty Trash",
                subtitle: "Permanently delete files in macOS Trash",
                icon: "trash.fill",
                iconTint: .orange,
                action: { appState.systemUtils.emptyTrash() }
            ),
            SearchableAction(
                id: "reset-gdrive",
                title: "Reset Google Drive Sync Helper",
                subtitle: "pluginkit ignore com.google.drivefs",
                icon: "arrow.triangle.2.circlepath",
                iconTint: .purple,
                action: { appState.systemUtils.resetGoogleDriveHelper() }
            ),
            SearchableAction(
                id: "flush-dns",
                title: "Flush DNS Cache",
                subtitle: "Clear resolver cache and restart mDNSResponder",
                icon: "network.badge.shield.half.filled",
                iconTint: .teal,
                action: { appState.systemUtils.flushDNS() }
            ),
            SearchableAction(
                id: "hidden-files",
                title: "Toggle Hidden Files in Finder",
                subtitle: appState.systemUtils.isHiddenFilesShown ? "Hide dotfiles" : "Show dotfiles",
                icon: "eye.fill",
                iconTint: .indigo,
                action: { appState.systemUtils.toggleHiddenFiles() }
            ),
            SearchableAction(
                id: "dock",
                title: "Toggle Dock Auto-hide",
                subtitle: appState.systemUtils.isDockAutohideEnabled ? "Disable autohide" : "Enable autohide",
                icon: "dock.rectangle",
                iconTint: .mint,
                action: { appState.systemUtils.toggleDockAutohide() }
            ),
        ]
    }

    var filteredActions: [SearchableAction] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if q.isEmpty { return allActions }
        return allActions.filter {
            $0.title.lowercased().contains(q) || $0.subtitle.lowercased().contains(q)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Search field header
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)

                TextField("Search actions, tools, macros...", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .focused($isFocused)

                Button(action: { isPresented = false }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.white.opacity(0.04))

            Divider().background(Color.white.opacity(0.08))

            // Results list
            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(filteredActions) { item in
                        Button(action: {
                            item.action()
                            isPresented = false
                        }) {
                            HStack(spacing: 10) {
                                Image(systemName: item.icon)
                                    .font(.system(size: 12, weight: .bold))
                                    .foregroundColor(item.iconTint)
                                    .frame(width: 24, height: 24)
                                    .background(item.iconTint.opacity(0.15))
                                    .clipShape(RoundedRectangle(cornerRadius: 6))

                                VStack(alignment: .leading, spacing: 1) {
                                    Text(item.title)
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundColor(.primary)
                                    Text(item.subtitle)
                                        .font(.system(size: 9.5))
                                        .foregroundColor(.secondary)
                                }

                                Spacer()

                                Image(systemName: "return")
                                    .font(.system(size: 9))
                                    .foregroundColor(.secondary.opacity(0.6))
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 6)
                            .background(Color.white.opacity(0.02))
                            .cornerRadius(6)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(8)
            }
        }
        .onAppear {
            isFocused = true
        }
    }
}
