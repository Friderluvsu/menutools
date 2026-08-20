import SwiftUI

struct NetworkTabView: View {
    @ObservedObject var network: NetworkBypassManager

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                // VPN Card
                GlassCard {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Image(systemName: "shield.lefthalf.filled")
                                .font(.system(size: 16, weight: .bold))
                                .foregroundColor(network.isVPNConnected ? .green : .secondary)
                                .frame(width: 30, height: 30)
                                .background((network.isVPNConnected ? Color.green : Color.white).opacity(0.12))
                                .clipShape(Circle())

                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text("VanyaVPN")
                                        .font(.system(size: 13, weight: .bold))
                                    Text("V")
                                        .font(.system(size: 8, weight: .bold))
                                        .padding(.horizontal, 4)
                                        .padding(.vertical, 1)
                                        .background(Color.white.opacity(0.08))
                                        .cornerRadius(3)
                                }

                                Text(network.isVPNConnected ? "Connected to VPN server" : "VPN is disconnected")
                                    .font(.system(size: 10))
                                    .foregroundColor(.secondary)
                            }

                            Spacer()

                            if network.isVPNTransitioning {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Button(action: { network.toggleVPN() }) {
                                    Text(network.isVPNConnected ? "Disconnect" : "Connect")
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundColor(network.isVPNConnected ? .red : .green)
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 4)
                                        .background((network.isVPNConnected ? Color.red : Color.green).opacity(0.12))
                                        .cornerRadius(6)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }

                // SpoofDPI Card
                GlassCard {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Image(systemName: "bolt.horizontal.fill")
                                .font(.system(size: 16, weight: .bold))
                                .foregroundColor(network.isSpoofDPIRunning ? .cyan : .secondary)
                                .frame(width: 30, height: 30)
                                .background((network.isSpoofDPIRunning ? Color.cyan : Color.white).opacity(0.12))
                                .clipShape(Circle())

                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text("SpoofDPI SOCKS5")
                                        .font(.system(size: 13, weight: .bold))
                                    Text("S")
                                        .font(.system(size: 8, weight: .bold))
                                        .padding(.horizontal, 4)
                                        .padding(.vertical, 1)
                                        .background(Color.white.opacity(0.08))
                                        .cornerRadius(3)
                                }

                                Text(
                                    network.isSpoofDPIRunning
                                        ? "Proxy active at \(network.spoofEndpoint)"
                                        : "DPI bypass is stopped"
                                )
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                            }

                            Spacer()

                            if network.isSpoofTransitioning {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Button(action: { network.toggleSpoofDPI() }) {
                                    Text(network.isSpoofDPIRunning ? "Stop" : "Start")
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundColor(network.isSpoofDPIRunning ? .red : .cyan)
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 4)
                                        .background((network.isSpoofDPIRunning ? Color.red : Color.cyan).opacity(0.12))
                                        .cornerRadius(6)
                                }
                                .buttonStyle(.plain)
                            }
                        }

                        Divider().background(Color.white.opacity(0.06))

                        // Interface and Port settings
                        HStack {
                            Text("Network service:")
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                            Text(network.activeNetworkInterface)
                                .font(.system(size: 10, weight: .semibold))

                            Spacer()

                            Text("DNS: \(network.spoofDNSMode.title)")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundColor(.secondary)
                        }
                    }
                }

                // Status summary
                HStack(spacing: 8) {
                    Circle()
                        .fill(network.isVPNConnected || network.isSpoofDPIRunning ? Color.green : Color.red)
                        .frame(width: 8, height: 8)
                    Text(
                        network.isVPNConnected && network.isSpoofDPIRunning
                            ? "Both VPN and SpoofDPI are active"
                            : (network.isVPNConnected
                                ? "VPN is active"
                                : (network.isSpoofDPIRunning ? "SpoofDPI is active" : "All bypass tools are idle"))
                    )
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 8)
            }
            .padding(14)
        }
    }
}
