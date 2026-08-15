import Combine
import Foundation

@MainActor
final class NetworkBypassManager: ObservableObject {
    @Published var isVPNConnected: Bool = false
    @Published var isSpoofDPIRunning: Bool = false
    @Published var isVPNTransitioning: Bool = false
    @Published var isSpoofTransitioning: Bool = false
    @Published var activeNetworkInterface: String = "Wi-Fi"
    @Published var spoofPort: Int = 1080
    @Published var errorMessage: String?

    private var pollCancellable: AnyCancellable?
    private var isRefreshing: Bool = false

    init() {
        refreshStatus()
        startPolling()
    }

    func startPolling() {
        pollCancellable?.cancel()
        pollCancellable = Timer.publish(every: 3.0, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                self?.refreshStatus()
            }
    }

    func refreshStatus() {
        guard !isVPNTransitioning && !isSpoofTransitioning && !isRefreshing else { return }
        isRefreshing = true

        Task.detached(priority: .utility) { [weak self] in
            // 1. Detect Network Interface (if not set)
            let (interfaceOut, _) = Shell.run(
                "networksetup -listallnetworkservices | grep -v 'An asterisk' | head -n 1")
            let iface = interfaceOut.trimmingCharacters(in: .whitespacesAndNewlines)

            // 2. Check VPN Status with exact match (avoiding 'Disconnected' matching 'Connected')
            let (listOut, _) = Shell.run("scutil --nc list | grep 'com.vanyavpn.macos.client' | head -n 1")
            var vpnUUID = "com.vanyavpn.macos.client"
            if let regex = try? NSRegularExpression(
                pattern: "([0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12})", options: .caseInsensitive)
            {
                let nsString = listOut as NSString
                if let match = regex.firstMatch(
                    in: listOut, options: [], range: NSRange(location: 0, length: nsString.length))
                {
                    vpnUUID = nsString.substring(with: match.range)
                }
            }

            let (vpnOut, _) = Shell.run("scutil --nc status \"\(vpnUUID)\" | head -n 1")
            let vpnStatusLine = vpnOut.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let vpnIsConnected = (vpnStatusLine == "connected")

            // 3. Check SpoofDPI Status
            let (spoofOut, _) = Shell.run("pgrep -x spoofdpi")
            let spoofIsRunning = !spoofOut.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

            await MainActor.run { [weak self] in
                guard let self = self else { return }
                if !iface.isEmpty {
                    self.activeNetworkInterface = iface
                }
                self.isVPNConnected = vpnIsConnected
                self.isSpoofDPIRunning = spoofIsRunning
                self.isRefreshing = false
            }
        }
    }

    private func getVanyaVPNUUID() -> String {
        let (listOut, _) = Shell.run("scutil --nc list | grep 'com.vanyavpn.macos.client' | head -n 1")
        if let regex = try? NSRegularExpression(
            pattern: "([0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12})", options: .caseInsensitive)
        {
            let nsString = listOut as NSString
            if let match = regex.firstMatch(
                in: listOut, options: [], range: NSRange(location: 0, length: nsString.length))
            {
                return nsString.substring(with: match.range)
            }
        }
        return "com.vanyavpn.macos.client"
    }

    // MARK: - VPN Actions
    func toggleVPN() {
        if isVPNConnected {
            disconnectVPN()
        } else {
            connectVPN()
        }
    }

    func connectVPN() {
        isVPNTransitioning = true

        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self = self else { return }
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
            guard let self = self else { return }
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
        if isSpoofDPIRunning {
            stopSpoofDPI()
        } else {
            startSpoofDPI()
        }
    }

    func startSpoofDPI() {
        isSpoofTransitioning = true
        let interface = activeNetworkInterface
        let port = spoofPort

        Task.detached(priority: .userInitiated) { [weak self] in
            Shell.run("sudo killall spoofdpi 2>/dev/null; pkill -f spoofdpi 2>/dev/null")

            let spoofPath = Shell.which("spoofdpi") ?? "/opt/homebrew/bin/spoofdpi"
            Shell.run(
                "nohup \(spoofPath) --app-mode socks5 --dns-mode system --port \(port) > /tmp/menutools_spoofdpi.log 2>&1 &"
            )

            Shell.run("sudo networksetup -setsocksfirewallproxy \"\(interface)\" 127.0.0.1 \(port)")
            Shell.run("sudo networksetup -setsocksfirewallproxystate \"\(interface)\" on")

            try? await Task.sleep(nanoseconds: 800_000_000)

            await MainActor.run { [weak self] in
                self?.isSpoofTransitioning = false
                self?.refreshStatus()
            }
        }
    }

    func stopSpoofDPI() {
        isSpoofTransitioning = true
        let interface = activeNetworkInterface

        Task.detached(priority: .userInitiated) { [weak self] in
            Shell.run("sudo networksetup -setsocksfirewallproxystate \"\(interface)\" off")
            Shell.run("sudo killall spoofdpi 2>/dev/null; pkill -f spoofdpi 2>/dev/null")

            try? await Task.sleep(nanoseconds: 500_000_000)

            await MainActor.run { [weak self] in
                self?.isSpoofTransitioning = false
                self?.refreshStatus()
            }
        }
    }
}
