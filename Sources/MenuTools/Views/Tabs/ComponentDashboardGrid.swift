import SwiftUI
import UniformTypeIdentifiers

struct ComponentDashboardGrid: View {
    @ObservedObject var appState: AppState
    @State private var isDropTargeted: Bool = false
    @State private var copiedIPNotice: String?

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 8) {
                // 1. CPU & Memory Gauge Card (2 columns)
                MacToolsCard(padding: 10) {
                    HStack(spacing: 12) {
                        // CPU
                        HStack(spacing: 8) {
                            Image(systemName: "cpu")
                                .font(.system(size: 13, weight: .bold))
                                .foregroundColor(appState.systemMonitor.cpuUsage > 75 ? .red : .blue)
                                .frame(width: 26, height: 26)
                                .background(
                                    (appState.systemMonitor.cpuUsage > 75 ? Color.red : Color.blue).opacity(0.15)
                                )
                                .clipShape(Circle())

                            VStack(alignment: .leading, spacing: 2) {
                                Text("CPU")
                                    .font(.system(size: 9, weight: .semibold))
                                    .foregroundColor(.secondary)
                                Text(String(format: "%.1f%%", appState.systemMonitor.cpuUsage))
                                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)

                        Divider().frame(height: 24).background(Color.white.opacity(0.08))

                        // RAM
                        HStack(spacing: 8) {
                            Image(systemName: "memorychip")
                                .font(.system(size: 13, weight: .bold))
                                .foregroundColor(appState.systemMonitor.memoryPercent > 80 ? .orange : .purple)
                                .frame(width: 26, height: 26)
                                .background(
                                    (appState.systemMonitor.memoryPercent > 80 ? Color.orange : Color.purple).opacity(
                                        0.15)
                                )
                                .clipShape(Circle())

                            VStack(alignment: .leading, spacing: 2) {
                                Text("RAM")
                                    .font(.system(size: 9, weight: .semibold))
                                    .foregroundColor(.secondary)
                                Text(String(format: "%.1f GB", appState.systemMonitor.memoryUsedGB))
                                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)

                        Divider().frame(height: 24).background(Color.white.opacity(0.08))

                        // Network Down/Up
                        VStack(alignment: .trailing, spacing: 2) {
                            HStack(spacing: 4) {
                                Image(systemName: "arrow.down")
                                    .font(.system(size: 8, weight: .bold))
                                    .foregroundColor(.green)
                                Text(formatSpeed(appState.systemMonitor.downloadSpeedKBps))
                                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                            }
                            HStack(spacing: 4) {
                                Image(systemName: "arrow.up")
                                    .font(.system(size: 8, weight: .bold))
                                    .foregroundColor(.blue)
                                Text(formatSpeed(appState.systemMonitor.uploadSpeedKBps))
                                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                            }
                        }
                    }
                }

                // 2. IP Addresses Bar
                MacToolsCard(padding: 8) {
                    HStack(spacing: 8) {
                        Button(action: {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(appState.systemMonitor.localIP, forType: .string)
                            showCopiedToast("Local IP Copied")
                        }) {
                            HStack(spacing: 4) {
                                Circle().fill(Color.green).frame(width: 5, height: 5)
                                Text("LAN: \(appState.systemMonitor.localIP)")
                                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                                    .foregroundColor(.primary)
                            }
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(Color.white.opacity(0.04))
                            .cornerRadius(4)
                        }
                        .buttonStyle(.plain)
                        .help("Click to copy Local IP")

                        Button(action: {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(appState.systemMonitor.publicIP, forType: .string)
                            showCopiedToast("Public IP Copied")
                        }) {
                            HStack(spacing: 4) {
                                Circle().fill(Color.blue).frame(width: 5, height: 5)
                                Text("WAN: \(appState.systemMonitor.publicIP)")
                                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                                    .foregroundColor(.primary)
                            }
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(Color.white.opacity(0.04))
                            .cornerRadius(4)
                        }
                        .buttonStyle(.plain)
                        .help("Click to copy Public IP")

                        Spacer()

                        if let notice = copiedIPNotice {
                            Text(notice)
                                .font(.system(size: 9, weight: .bold))
                                .foregroundColor(.green)
                        } else {
                            Button(action: {
                                appState.systemMonitor.updateLocalIP()
                                appState.systemMonitor.fetchPublicIP()
                            }) {
                                Image(systemName: "arrow.clockwise")
                                    .font(.system(size: 10))
                                    .foregroundColor(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                // 3. Dual 2x2 Quick Control Cards (Anti-Sleep, VPN, Spoof, iMessage)
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                    // Anti-Sleep Card
                    DashboardMiniCard(
                        title: "Anti-Sleep",
                        statusText: appState.antiSleep.isActive ? appState.antiSleep.statusText : "OFF",
                        icon: "cup.and.saucer.fill",
                        color: .orange,
                        isActive: appState.antiSleep.isActive,
                        onTap: { appState.antiSleep.toggle() }
                    )

                    // VanyaVPN Card
                    DashboardMiniCard(
                        title: "VanyaVPN",
                        statusText: appState.network.isVPNConnected ? "CONNECTED" : "OFF",
                        icon: "shield.lefthalf.filled",
                        color: .green,
                        isActive: appState.network.isVPNConnected,
                        isTransitioning: appState.network.isVPNTransitioning,
                        onTap: { appState.network.toggleVPN() }
                    )

                    // SpoofDPI Card
                    DashboardMiniCard(
                        title: "SpoofDPI",
                        statusText: appState.network.isSpoofDPIRunning ? "RUNNING" : "STOPPED",
                        icon: "bolt.horizontal.fill",
                        color: .cyan,
                        isActive: appState.network.isSpoofDPIRunning,
                        isTransitioning: appState.network.isSpoofTransitioning,
                        onTap: { appState.network.toggleSpoofDPI() }
                    )

                    // iMessage Navigator Card
                    DashboardMiniCard(
                        title: "iMessage Nav",
                        statusText: appState.iMessage.isEnabled ? "ACTIVE (↑/↓)" : "OFF",
                        icon: "message.fill",
                        color: .blue,
                        isActive: appState.iMessage.isEnabled,
                        onTap: { appState.iMessage.isEnabled.toggle() }
                    )
                }

                // 4. Permute Media Converter Quick Drop Card
                MacToolsCard(padding: 10) {
                    VStack(spacing: 8) {
                        HStack {
                            Image(systemName: "arrow.triangle.2.circlepath.circle.fill")
                                .font(.system(size: 13, weight: .bold))
                                .foregroundColor(.pink)
                            Text("Permute Converter")
                                .font(.system(size: 11, weight: .bold))

                            Spacer()

                            // Category chips
                            HStack(spacing: 3) {
                                ForEach(MediaCategory.allCases) { cat in
                                    Button(action: { appState.converter.selectedCategory = cat }) {
                                        Text(cat.rawValue)
                                            .font(.system(size: 9, weight: .semibold))
                                            .padding(.horizontal, 5)
                                            .padding(.vertical, 2)
                                            .background(
                                                appState.converter.selectedCategory == cat
                                                    ? Color.pink : Color.white.opacity(0.06)
                                            )
                                            .foregroundColor(
                                                appState.converter.selectedCategory == cat ? .white : .secondary
                                            )
                                            .cornerRadius(4)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }

                        // Drag & Drop Area
                        ZStack {
                            RoundedRectangle(cornerRadius: 8)
                                .strokeBorder(
                                    isDropTargeted ? Color.pink : Color.white.opacity(0.12),
                                    style: StrokeStyle(lineWidth: 1.2, dash: [5])
                                )
                                .background(
                                    RoundedRectangle(cornerRadius: 8)
                                        .fill(isDropTargeted ? Color.pink.opacity(0.12) : Color.white.opacity(0.02))
                                )

                            HStack(spacing: 8) {
                                Image(systemName: "square.and.arrow.down")
                                    .font(.system(size: 14))
                                    .foregroundColor(.pink)
                                Text("Drop video, audio or image to convert")
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundColor(.secondary)
                            }
                            .padding(.vertical, 10)
                        }
                        .frame(height: 38)
                        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
                            for provider in providers {
                                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                                    if let url = url {
                                        DispatchQueue.main.async {
                                            appState.converter.addFiles([url])
                                        }
                                    }
                                }
                            }
                            return true
                        }

                        // Active / Recent conversion status if any
                        if let firstTask = appState.converter.tasks.first {
                            HStack(spacing: 6) {
                                Text(firstTask.inputURL.lastPathComponent)
                                    .font(.system(size: 10))
                                    .lineLimit(1)
                                Spacer()
                                switch firstTask.status {
                                case .converting:
                                    ProgressView().controlSize(.mini)
                                case .completed(let url):
                                    Button("Show in Finder") {
                                        NSWorkspace.shared.activateFileViewerSelecting([url])
                                    }
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundColor(.green)
                                    .buttonStyle(.plain)
                                default:
                                    EmptyView()
                                }
                            }
                        }
                    }
                }

                // 5. Clipboard History Quick Card
                MacToolsCard(padding: 10) {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Image(systemName: "doc.on.clipboard.fill")
                                .font(.system(size: 12))
                                .foregroundColor(.yellow)
                            Text("Clipboard History")
                                .font(.system(size: 11, weight: .bold))

                            Spacer()

                            Button("HUD (⌥⌘V)") {
                                ClipboardHUDWindowController.shared.show()
                            }
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(.yellow)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Color.yellow.opacity(0.12))
                            .cornerRadius(4)
                            .buttonStyle(.plain)
                        }

                        // Latest 2 clips
                        let recent = Array(appState.clipboard.items.prefix(2))
                        if recent.isEmpty {
                            Text("No clips recorded yet")
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                        } else {
                            VStack(spacing: 3) {
                                ForEach(Array(recent.enumerated()), id: \.element.id) { idx, item in
                                    Button(action: {
                                        appState.clipboard.copyAndPaste(item: item, simulatePaste: false)
                                        showCopiedToast("Copied to Pasteboard")
                                    }) {
                                        HStack(spacing: 6) {
                                            Text("\(idx + 1)")
                                                .font(.system(size: 9, weight: .bold, design: .monospaced))
                                                .foregroundColor(.secondary)
                                                .frame(width: 10)
                                            Text(item.snippet)
                                                .font(.system(size: 10))
                                                .foregroundColor(.primary)
                                                .lineLimit(1)
                                            Spacer()
                                        }
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 3)
                                        .background(Color.white.opacity(0.04))
                                        .cornerRadius(4)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                }

                // 6. System Quick Actions Bar
                HStack(spacing: 6) {
                    QuickActionButton(title: "Eject Disks", icon: "eject.fill", color: .red) {
                        appState.systemUtils.ejectAllDisks()
                    }
                    QuickActionButton(title: "Empty Trash", icon: "trash.fill", color: .orange) {
                        appState.systemUtils.emptyTrash()
                    }
                    QuickActionButton(title: "Reset GDrive", icon: "arrow.triangle.2.circlepath", color: .purple) {
                        appState.systemUtils.resetGoogleDriveHelper()
                    }
                    QuickActionButton(title: "Flush DNS", icon: "network", color: .blue) {
                        appState.systemUtils.flushDNS()
                    }
                }
            }
            .padding(MacToolsTheme.outerPadding)
        }
    }

    private func showCopiedToast(_ text: String) {
        copiedIPNotice = text
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            copiedIPNotice = nil
        }
    }

    private func formatSpeed(_ kbps: Double) -> String {
        if kbps >= 1024.0 {
            return String(format: "%.1fM", kbps / 1024.0)
        }
        return String(format: "%.0fK", kbps)
    }
}

struct DashboardMiniCard: View {
    let title: String
    let statusText: String
    let icon: String
    var color: Color = .blue
    let isActive: Bool
    var isTransitioning: Bool = false
    let onTap: () -> Void

    @State private var isHovered: Bool = false

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(isActive ? color : .secondary)
                    .frame(width: 26, height: 26)
                    .background((isActive ? color : Color.white).opacity(isActive ? 0.16 : 0.05))
                    .clipShape(RoundedRectangle(cornerRadius: 6))

                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.primary)
                        .lineLimit(1)

                    if isTransitioning {
                        ProgressView().controlSize(.mini)
                    } else {
                        Text(statusText)
                            .font(.system(size: 8.5, weight: .heavy, design: .monospaced))
                            .foregroundColor(isActive ? color : .secondary)
                            .lineLimit(1)
                    }
                }

                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(isHovered ? MacToolsTheme.hoverBackground : MacToolsTheme.cardBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(isHovered ? MacToolsTheme.borderHoverColor : MacToolsTheme.borderColor, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

struct QuickActionButton: View {
    let title: String
    let icon: String
    var color: Color = .blue
    let action: () -> Void

    @State private var isHovered: Bool = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(color)
                Text(title)
                    .font(.system(size: 8.5, weight: .medium))
                    .foregroundColor(.primary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isHovered ? MacToolsTheme.hoverBackground : MacToolsTheme.cardBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(isHovered ? MacToolsTheme.borderHoverColor : MacToolsTheme.borderColor, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}
