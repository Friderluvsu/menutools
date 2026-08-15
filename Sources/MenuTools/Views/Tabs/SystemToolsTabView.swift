import SwiftUI

struct SystemToolsTabView: View {
    @ObservedObject var systemUtils: SystemUtilsManager

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                // Action notification banner
                if let result = systemUtils.lastActionResult {
                    HStack(spacing: 6) {
                        Image(systemName: "info.circle.fill")
                            .font(.system(size: 11))
                            .foregroundColor(.blue)
                        Text(result)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.primary)
                        Spacer()
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color.blue.opacity(0.12))
                    .cornerRadius(6)
                }

                // Disk & Storage Section
                VStack(alignment: .leading, spacing: 6) {
                    Text("STORAGE & DRIVES")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 4)

                    VStack(spacing: 6) {
                        ToolActionRow(
                            title: "Eject All External Disks",
                            subtitle: "Safely unmounts and ejects all USB and external volumes",
                            icon: "eject.fill",
                            color: .red,
                            action: { systemUtils.ejectAllDisks() }
                        )

                        ToolActionRow(
                            title: "Empty Trash",
                            subtitle: "Permanently delete files in macOS Trash",
                            icon: "trash.fill",
                            color: .orange,
                            action: { systemUtils.emptyTrash() }
                        )
                    }
                }

                // System & Network Tweaks
                VStack(alignment: .leading, spacing: 6) {
                    Text("SYSTEM & PERFORMANCE")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 4)

                    VStack(spacing: 6) {
                        ToolActionRow(
                            title: "Reset Google Drive Finder Helper",
                            subtitle: "Ignore com.google.drivefs FinderSync extension",
                            icon: "arrow.triangle.2.circlepath",
                            color: .purple,
                            action: { systemUtils.resetGoogleDriveHelper() }
                        )

                        ToolActionRow(
                            title: "Flush DNS Cache",
                            subtitle: "Clear local DNS resolver cache and restart mDNSResponder",
                            icon: "network.badge.shield.half.filled",
                            color: .blue,
                            action: { systemUtils.flushDNS() }
                        )
                    }
                }

                // UI & Finder Preferences
                VStack(alignment: .leading, spacing: 6) {
                    Text("FINDER & DESKTOP")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 4)

                    VStack(spacing: 6) {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Show Hidden Files in Finder")
                                    .font(.system(size: 12, weight: .medium))
                                Text("Toggle visibility of dotfiles (.)")
                                    .font(.system(size: 10))
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            Toggle(
                                "",
                                isOn: Binding(
                                    get: { systemUtils.isHiddenFilesShown },
                                    set: { _ in systemUtils.toggleHiddenFiles() }
                                )
                            )
                            .toggleStyle(.switch)
                            .labelsHidden()
                            .controlSize(.small)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(Color.white.opacity(0.02))
                        .cornerRadius(8)

                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Auto-hide Dock")
                                    .font(.system(size: 12, weight: .medium))
                                Text("Automatically hide and show the macOS Dock")
                                    .font(.system(size: 10))
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            Toggle(
                                "",
                                isOn: Binding(
                                    get: { systemUtils.isDockAutohideEnabled },
                                    set: { _ in systemUtils.toggleDockAutohide() }
                                )
                            )
                            .toggleStyle(.switch)
                            .labelsHidden()
                            .controlSize(.small)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(Color.white.opacity(0.02))
                        .cornerRadius(8)
                    }
                }
            }
            .padding(14)
        }
    }
}

struct ToolActionRow: View {
    let title: String
    let subtitle: String
    let icon: String
    var color: Color = .blue
    let action: () -> Void

    @State private var isHovered: Bool = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(color)
                .frame(width: 26, height: 26)
                .background(color.opacity(0.15))
                .clipShape(RoundedRectangle(cornerRadius: 6))

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.primary)
                Text(subtitle)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }

            Spacer()

            Button("Run") {
                action()
            }
            .font(.system(size: 10, weight: .semibold))
            .controlSize(.small)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isHovered ? Color.white.opacity(0.05) : Color.white.opacity(0.02))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.white.opacity(isHovered ? 0.08 : 0.03), lineWidth: 1)
        )
        .onHover { isHovered = $0 }
    }
}
