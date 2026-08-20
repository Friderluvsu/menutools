import Combine
import Foundation

enum SpoofDNSMode: String, CaseIterable, Identifiable {
    case system
    case udp
    case https

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return "System"
        case .udp: return "UDP"
        case .https: return "HTTPS"
        }
    }
}

@MainActor
final class NetworkBypassManager: ObservableObject {
    @Published var isVPNConnected: Bool = false
    @Published var isSpoofDPIRunning: Bool = false
    @Published var isVPNTransitioning: Bool = false
    @Published var isSpoofTransitioning: Bool = false
    @Published var activeNetworkInterface: String = "Automatic"
    @Published var errorMessage: String?

    @Published var spoofPort: Int = 1080 {
        didSet { UserDefaults.standard.set(spoofPort, forKey: Keys.spoofPort) }
    }
    @Published var spoofDNSMode: SpoofDNSMode = .system {
        didSet { UserDefaults.standard.set(spoofDNSMode.rawValue, forKey: Keys.spoofDNSMode) }
    }
    @Published var configureSystemProxy: Bool = true {
        didSet { UserDefaults.standard.set(configureSystemProxy, forKey: Keys.configureSystemProxy) }
    }

    private enum Keys {
        static let spoofPort = "SpoofDPI.Port"
        static let spoofDNSMode = "SpoofDPI.DNSMode"
        static let configureSystemProxy = "SpoofDPI.ConfigureSystemProxy"
    }

    private var pollCancellable: AnyCancellable?
    private var isRefreshing: Bool = false

    init() {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: Keys.spoofPort) != nil {
            spoofPort = min(max(defaults.integer(forKey: Keys.spoofPort), 1024), 65535)
        }
        if let rawMode = defaults.string(forKey: Keys.spoofDNSMode),
            let mode = SpoofDNSMode(rawValue: rawMode)
        {
            spoofDNSMode = mode
        }
        if defaults.object(forKey: Keys.configureSystemProxy) != nil {
            configureSystemProxy = defaults.bool(forKey: Keys.configureSystemProxy)
        }

        refreshStatus()
        startPolling()
    }

    var spoofDPIPath: String? {
        if let bundled = Bundle.main.url(forResource: "spoofdpi", withExtension: nil, subdirectory: "bin")?.path,
            FileManager.default.isExecutableFile(atPath: bundled)
        {
            return bundled
        }
        return Shell.which("spoofdpi")
    }

    var isSpoofDPIAvailable: Bool { spoofDPIPath != nil }
    var spoofEndpoint: String { "127.0.0.1:\(spoofPort)" }

    func startPolling() {
        pollCancellable?.cancel()
        pollCancellable = Timer.publish(every: 3.0, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.refreshStatus() }
    }

    func refreshStatus() {
        guard !isVPNTransitioning && !isSpoofTransitioning && !isRefreshing else { return }
        isRefreshing = true

        Task.detached(priority: .utility) { [weak self] in
            let (interfaceOut, _) = Shell.run(
                "networksetup -listallnetworkservices | grep -v 'An asterisk' | head -n 1")
            let interface = interfaceOut.trimmingCharacters(in: .whitespacesAndNewlines)

            let (listOut, _) = Shell.run("scutil --nc list | grep 'com.vanyavpn.macos.client' | head -n 1")
            let vpnUUID = Self.extractVPNUUID(from: listOut) ?? "com.vanyavpn.macos.client"
            let (vpnOut, _) = Shell.run("scutil --nc status \"\(vpnUUID)\" | head -n 1")
            let vpnIsConnected = vpnOut.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "connected"

            let (spoofOut, _) = Shell.run("pgrep -x spoofdpi")
            let spoofIsRunning = !spoofOut.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

            await MainActor.run { [weak self] in
                guard let self else { return }
                if !interface.isEmpty { self.activeNetworkInterface = interface }
                self.isVPNConnected = vpnIsConnected
                self.isSpoofDPIRunning = spoofIsRunning
                self.isRefreshing = false
            }
        }
    }

    nonisolated private static func extractVPNUUID(from output: String) -> String? {
        guard
            let regex = try? NSRegularExpression(
                pattern: "([0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12})",
                options: .caseInsensitive
            )
        else { return nil }

        let nsString = output as NSString
        guard
            let match = regex.firstMatch(
                in: output,
                range: NSRange(location: 0, length: nsString.length)
            )
        else { return nil }
        return nsString.substring(with: match.range)
    }

    private func getVanyaVPNUUID() -> String {
        let (output, _) = Shell.run("scutil --nc list | grep 'com.vanyavpn.macos.client' | head -n 1")
        return Self.extractVPNUUID(from: output) ?? "com.vanyavpn.macos.client"
    }

    // MARK: - VPN Actions

    func toggleVPN() {
        isVPNConnected ? disconnectVPN() : connectVPN()
    }

    func connectVPN() {
        isVPNTransitioning = true

        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            let vpnUUID = await self.getVanyaVPNUUID()

            Shell.run("scutil --nc start \"\(vpnUUID)\"")
            Shell.run("open -a 'ВПН' 2>/dev/null || open -a 'VanyaVPN' 2>/dev/null")

            let script = """
                tell application "System Events"
                    tell process "VanyaVPN"
                        repeat 15 times
                            if exists window 1 then
                                click button 1 of window 1
                                exit repeat
                            end if
                            delay 0.2
                        end repeat
                    end tell
                end tell
                """
            Shell.run("osascript -e '\(script)'")
            try? await Task.sleep(nanoseconds: 1_200_000_000)

            await MainActor.run { [weak self] in
                self?.isVPNTransitioning = false
                self?.refreshStatus()
            }
        }
    }

    func disconnectVPN() {
        isVPNTransitioning = true

        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            let vpnUUID = await self.getVanyaVPNUUID()

            Shell.run("scutil --nc stop \"\(vpnUUID)\"")
            Shell.run("osascript -e 'tell application \"VanyaVPN\" to quit' 2>/dev/null")
            try? await Task.sleep(nanoseconds: 500_000_000)
            Shell.run("pkill -9 -x \"VanyaVPN\" 2>/dev/null")

            await MainActor.run { [weak self] in
                self?.isVPNTransitioning = false
                self?.refreshStatus()
            }
        }
    }

    // MARK: - SpoofDPI Actions

    func toggleSpoofDPI() {
        isSpoofDPIRunning ? stopSpoofDPI() : startSpoofDPI()
    }

    func startSpoofDPI() {
        guard let executable = spoofDPIPath else {
            errorMessage = "The bundled SpoofDPI runtime is unavailable."
            return
        }

        isSpoofTransitioning = true
        errorMessage = nil
        let port = min(max(spoofPort, 1024), 65535)
        spoofPort = port
        let dnsMode = spoofDNSMode.rawValue
        let autoConfigure = configureSystemProxy

        Task.detached(priority: .userInitiated) { [weak self] in
            Shell.run("pkill -x spoofdpi 2>/dev/null")

            var arguments = [
                "--clean",
                "--app-mode", "socks5",
                "--dns-mode", dnsMode,
                "--listen-addr", "127.0.0.1:\(port)",
                "--no-tui",
                "--log-level", "info",
            ]
            if autoConfigure { arguments.append("--auto-configure-network") }

            _ = Shell.runDetached(
                executable: executable,
                arguments: arguments,
                logPath: "/tmp/menutools_spoofdpi.log"
            )

            try? await Task.sleep(nanoseconds: 900_000_000)
            let (status, _) = Shell.run("pgrep -x spoofdpi")
            let isRunning = !status.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            let log = isRunning ? "" : Shell.run("tail -n 4 /tmp/menutools_spoofdpi.log").output

            await MainActor.run { [weak self] in
                guard let self else { return }
                self.isSpoofTransitioning = false
                self.isSpoofDPIRunning = isRunning
                if !isRunning {
                    self.errorMessage = log.isEmpty ? "SpoofDPI could not be started." : log
                }
            }
        }
    }

    func stopSpoofDPI() {
        isSpoofTransitioning = true
        errorMessage = nil

        Task.detached(priority: .userInitiated) { [weak self] in
            Shell.run("pkill -x spoofdpi 2>/dev/null")
            try? await Task.sleep(nanoseconds: 500_000_000)

            await MainActor.run { [weak self] in
                self?.isSpoofTransitioning = false
                self?.refreshStatus()
            }
        }
    }
}
