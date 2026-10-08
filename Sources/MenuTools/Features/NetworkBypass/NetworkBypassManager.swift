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
    /// Discovered once; `scutil --nc list` is not needed again while the id keeps working.
    private var cachedVPNUUID: String?
    private var lastInterfaceLookup: Date?

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
        guard pollCancellable == nil else { return }
        refreshStatus()
        pollCancellable = Timer.publish(every: 5.0, tolerance: 1.5, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.refreshStatus() }
    }

    func stopPolling() {
        pollCancellable?.cancel()
        pollCancellable = nil
    }

    func refreshStatus() {
        guard !isVPNTransitioning && !isSpoofTransitioning && !isRefreshing else { return }
        isRefreshing = true

        let knownUUID = cachedVPNUUID
        // The service name almost never changes; look it up at most every 5 minutes.
        let needsInterface = lastInterfaceLookup.map { Date().timeIntervalSince($0) > 300 } ?? true

        Task.detached(priority: .utility) { [weak self] in
            var interface = ""
            if needsInterface {
                let out = Self.exec("/usr/sbin/networksetup", ["-listallnetworkservices"])
                interface =
                    out.split(separator: "\n").first(where: { !$0.contains("An asterisk") })
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
            }

            var vpnUUID = knownUUID
            if vpnUUID == nil {
                vpnUUID = Self.lookupVPNUUID()
            }
            var vpnIsConnected = false
            if let uuid = vpnUUID {
                let statusOut = Self.exec("/usr/sbin/scutil", ["--nc", "status", uuid])
                vpnIsConnected = Self.firstLine(statusOut).lowercased() == "connected"
            }

            // In-process process-table lookup instead of spawning pgrep.
            let spoofIsRunning = Self.isProcessRunning(named: "spoofdpi")
            let foundInterface = interface
            let foundUUID = vpnUUID
            let connected = vpnIsConnected

            await MainActor.run { [weak self] in
                guard let self else { return }
                if needsInterface {
                    self.lastInterfaceLookup = Date()
                    if !foundInterface.isEmpty && self.activeNetworkInterface != foundInterface {
                        self.activeNetworkInterface = foundInterface
                    }
                }
                if self.cachedVPNUUID != foundUUID { self.cachedVPNUUID = foundUUID }
                if self.isVPNConnected != connected { self.isVPNConnected = connected }
                if self.isSpoofDPIRunning != spoofIsRunning { self.isSpoofDPIRunning = spoofIsRunning }
                self.isRefreshing = false
            }
        }
    }

    // MARK: - Cheap system queries

    nonisolated private static func exec(_ path: String, _ arguments: [String]) -> String {
        ProcessLookup.output(of: path, arguments)
    }

    nonisolated private static func firstLine(_ text: String) -> String {
        text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: true).first
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
    }

    /// Finds the VanyaVPN configuration id in `scutil --nc list`; nil when it is not installed.
    nonisolated private static func lookupVPNUUID() -> String? {
        let list = exec("/usr/sbin/scutil", ["--nc", "list"])
        guard
            let line = list.split(separator: "\n").first(where: { $0.contains("com.vanyavpn.macos.client") })
        else { return nil }
        return extractVPNUUID(from: String(line))
    }

    nonisolated private static func isProcessRunning(named name: String) -> Bool {
        ProcessLookup.isRunning(named: name)
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

    /// Uses the cached id when known; otherwise falls back to the bundle id like before.
    nonisolated private static func resolveVPNUUID(cached: String?) -> String {
        cached ?? lookupVPNUUID() ?? "com.vanyavpn.macos.client"
    }

    // MARK: - VPN Actions

    func toggleVPN() {
        isVPNConnected ? disconnectVPN() : connectVPN()
    }

    func connectVPN() {
        isVPNTransitioning = true
        let knownUUID = cachedVPNUUID

        Task.detached(priority: .userInitiated) { [weak self] in
            let vpnUUID = Self.resolveVPNUUID(cached: knownUUID)

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
        let knownUUID = cachedVPNUUID

        Task.detached(priority: .userInitiated) { [weak self] in
            let vpnUUID = Self.resolveVPNUUID(cached: knownUUID)

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
            let isRunning = Self.isProcessRunning(named: "spoofdpi")
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
