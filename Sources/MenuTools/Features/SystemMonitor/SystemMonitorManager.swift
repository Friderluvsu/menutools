import Combine
import Foundation

@MainActor
final class SystemMonitorManager: ObservableObject {
    @Published var cpuUsage: Double = 0.0
    @Published var cpuTemperature: Double = 42.0
    @Published var memoryUsedGB: Double = 0.0
    @Published var memoryTotalGB: Double = 0.0
    @Published var memoryPercent: Double = 0.0
    @Published var downloadSpeedKBps: Double = 0.0
    @Published var uploadSpeedKBps: Double = 0.0
    @Published var localIP: String = "127.0.0.1"
    @Published var publicIP: String = "..."

    private var cancellable: AnyCancellable?
    private var warmupWorkItem: DispatchWorkItem?
    private var previousCPUInfo: host_cpu_load_info?
    private var previousBytesIn: UInt64 = 0
    private var previousBytesOut: UInt64 = 0
    private var previousTimestamp: Date = Date()
    private var isUpdating: Bool = false
    private var tickCount: Int = 0

    private var lastPublicIPFetch: Date?
    private var isFetchingPublicIP: Bool = false
    /// A successful lookup is reused this long; a failed one is retried sooner.
    private static let publicIPTTL: TimeInterval = 120
    private static let publicIPRetry: TimeInterval = 30

    init() {
        self.memoryTotalGB = Double(ProcessInfo.processInfo.physicalMemory) / (1024 * 1024 * 1024)
        updateLocalIP()
    }

    func startMonitoring() {
        guard cancellable == nil else { return }
        // Drop counters from the previous session so the first sample is a clean baseline
        // instead of an average over the whole time the panel was closed.
        previousCPUInfo = nil
        previousBytesIn = 0
        previousBytesOut = 0
        tickCount = 0
        updateStats()
        fetchPublicIPIfStale()
        updateLocalIP()

        // Quick second sample so speeds and CPU show real values right after opening.
        let warmup = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.updateStats() }
        }
        warmupWorkItem = warmup
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7, execute: warmup)

        cancellable = Timer.publish(every: 2.0, tolerance: 0.5, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                self?.updateStats()
            }
    }

    func stopMonitoring() {
        warmupWorkItem?.cancel()
        warmupWorkItem = nil
        cancellable?.cancel()
        cancellable = nil
    }

    /// Assign only when the displayed value would actually change, so idle ticks do not re-render SwiftUI.
    private func setIfChanged(_ keyPath: ReferenceWritableKeyPath<SystemMonitorManager, Double>, _ value: Double, epsilon: Double) {
        if abs(self[keyPath: keyPath] - value) >= epsilon {
            self[keyPath: keyPath] = value
        }
    }

    func updateStats() {
        guard !isUpdating else { return }
        isUpdating = true

        let totalGB = self.memoryTotalGB
        var prevCPU = self.previousCPUInfo
        let prevBytesIn = self.previousBytesIn
        let prevBytesOut = self.previousBytesOut
        let prevTime = self.previousTimestamp
        // Temperature walks ~36 SMC keys; it moves slowly, so sample it every other tick.
        let readTemperature = tickCount % 2 == 0
        tickCount &+= 1

        Task.detached(priority: .utility) { [weak self] in
            // 1. CPU
            var newCPU: Double?
            var count = mach_msg_type_number_t(
                MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
            var cpuInfo = host_cpu_load_info()

            let cpuResult = withUnsafeMutablePointer(to: &cpuInfo) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                    host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
                }
            }

            if cpuResult == KERN_SUCCESS {
                if let prev = prevCPU {
                    let user = Double(cpuInfo.cpu_ticks.0 - prev.cpu_ticks.0)
                    let sys = Double(cpuInfo.cpu_ticks.1 - prev.cpu_ticks.1)
                    let idle = Double(cpuInfo.cpu_ticks.2 - prev.cpu_ticks.2)
                    let nice = Double(cpuInfo.cpu_ticks.3 - prev.cpu_ticks.3)

                    let total = user + sys + idle + nice
                    if total > 0 {
                        let usage = ((user + sys + nice) / total) * 100.0
                        newCPU = min(100.0, max(0.0, usage))
                    }
                }
                prevCPU = cpuInfo
            }

            // 2. RAM
            var newUsedGB: Double = 0.0
            var newMemPercent: Double = 0.0
            var vmCount = mach_msg_type_number_t(
                MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
            var vmStat = vm_statistics64()

            let memResult = withUnsafeMutablePointer(to: &vmStat) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(vmCount)) {
                    host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &vmCount)
                }
            }

            if memResult == KERN_SUCCESS {
                let pageSize = Double(getpagesize())
                let active = Double(vmStat.active_count) * pageSize
                let wired = Double(vmStat.wire_count) * pageSize
                let compressed = Double(vmStat.compressor_page_count) * pageSize
                let usedBytes = active + wired + compressed
                newUsedGB = usedBytes / (1024 * 1024 * 1024)
                if totalGB > 0 {
                    newMemPercent = min(100.0, (newUsedGB / totalGB) * 100.0)
                }
            }

            // 3. Network Bandwidth
            var ifaddr: UnsafeMutablePointer<ifaddrs>?
            var totalBytesIn: UInt64 = 0
            var totalBytesOut: UInt64 = 0

            if getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr {
                var ptr: UnsafeMutablePointer<ifaddrs>? = firstAddr
                while let current = ptr {
                    let flags = Int32(current.pointee.ifa_flags)
                    if (flags & IFF_UP) == IFF_UP && (flags & IFF_LOOPBACK) == 0 {
                        if let data = current.pointee.ifa_data {
                            let networkData = data.assumingMemoryBound(to: if_data.self)
                            totalBytesIn += UInt64(networkData.pointee.ifi_ibytes)
                            totalBytesOut += UInt64(networkData.pointee.ifi_obytes)
                        }
                    }
                    ptr = current.pointee.ifa_next
                }
                freeifaddrs(ifaddr)
            }

            let now = Date()
            let timeDelta = now.timeIntervalSince(prevTime)
            var downSpeed: Double?
            var upSpeed: Double?

            if prevBytesIn > 0 && timeDelta > 0 {
                let inDelta = Double(totalBytesIn >= prevBytesIn ? totalBytesIn - prevBytesIn : 0)
                let outDelta = Double(totalBytesOut >= prevBytesOut ? totalBytesOut - prevBytesOut : 0)
                downSpeed = (inDelta / 1024.0) / timeDelta
                upSpeed = (outDelta / 1024.0) / timeDelta
            }

            // Read real hardware CPU temperature from SMC
            let realTemp: Double? = readTemperature ? SMCDriver.shared.readCPUTemperature() : nil

            await MainActor.run {
                [weak self, newCPU, newUsedGB, newMemPercent, downSpeed, upSpeed, totalBytesIn, totalBytesOut] in
                guard let self = self else { return }
                if let newCPU { self.setIfChanged(\.cpuUsage, newCPU, epsilon: 0.1) }
                if let realTemp { self.setIfChanged(\.cpuTemperature, realTemp, epsilon: 0.5) }
                self.setIfChanged(\.memoryUsedGB, newUsedGB, epsilon: 0.05)
                self.setIfChanged(\.memoryPercent, newMemPercent, epsilon: 0.5)
                // Speeds jitter every sample; ignore sub-0.5 KB/s or sub-3% moves.
                if let downSpeed, abs(self.downloadSpeedKBps - downSpeed) >= max(0.5, self.downloadSpeedKBps * 0.03) {
                    self.downloadSpeedKBps = downSpeed
                }
                if let upSpeed, abs(self.uploadSpeedKBps - upSpeed) >= max(0.5, self.uploadSpeedKBps * 0.03) {
                    self.uploadSpeedKBps = upSpeed
                }
                self.previousCPUInfo = prevCPU
                self.previousBytesIn = totalBytesIn
                self.previousBytesOut = totalBytesOut
                self.previousTimestamp = now
                self.isUpdating = false
            }
        }
    }

    func updateLocalIP() {
        Task.detached(priority: .utility) { [weak self] in
            var address: String?
            var ifaddr: UnsafeMutablePointer<ifaddrs>?
            if getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr {
                var ptr: UnsafeMutablePointer<ifaddrs>? = firstAddr
                while let current = ptr {
                    let interface = current.pointee
                    if let addr = interface.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET) {
                        let name = String(cString: interface.ifa_name)
                        if name == "en0" || name == "en1" {
                            var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                            if getnameinfo(
                                addr,
                                socklen_t(addr.pointee.sa_len),
                                &hostname,
                                socklen_t(hostname.count),
                                nil,
                                0,
                                NI_NUMERICHOST
                            ) == 0 {
                                let ip = hostname.withUnsafeBufferPointer { ptr in
                                    ptr.baseAddress.map { String(cString: $0) }
                                }
                                if let validIP = ip {
                                    if name == "en0" {
                                        address = validIP
                                        break
                                    } else if address == nil {
                                        address = validIP
                                    }
                                }
                            }
                        }
                    }
                    ptr = current.pointee.ifa_next
                }
                freeifaddrs(ifaddr)
            }

            let resolvedIP = address ?? "127.0.0.1"
            await MainActor.run { [weak self] in
                guard let self, self.localIP != resolvedIP else { return }
                self.localIP = resolvedIP
                // Network changed: the cached WAN address is probably stale.
                if self.cancellable != nil { self.fetchPublicIP() } else { self.lastPublicIPFetch = nil }
            }
        }
    }

    /// Fetches only when there is no recent result; used on every panel open.
    func fetchPublicIPIfStale() {
        let ttl = publicIP == "Offline" || publicIP == "..." ? Self.publicIPRetry : Self.publicIPTTL
        if let last = lastPublicIPFetch, Date().timeIntervalSince(last) < ttl { return }
        fetchPublicIP()
    }

    /// Drops the cache (e.g. after a VPN toggle); the next panel open refetches.
    func invalidatePublicIP() {
        lastPublicIPFetch = nil
    }

    /// Forced refresh (manual refresh button). Uses URLSession instead of spawning zsh + curl.
    func fetchPublicIP() {
        guard !isFetchingPublicIP else { return }
        isFetchingPublicIP = true

        Task.detached(priority: .utility) { [weak self] in
            var resolved: String?
            for endpoint in ["https://api.ipify.org", "https://ifconfig.me/ip"] {
                if let ip = await Self.requestIP(endpoint) {
                    resolved = ip
                    break
                }
            }
            let value = resolved ?? "Offline"
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.isFetchingPublicIP = false
                self.lastPublicIPFetch = Date()
                if self.publicIP != value { self.publicIP = value }
            }
        }
    }

    nonisolated private static func requestIP(_ urlString: String) async -> String? {
        guard let url = URL(string: urlString) else { return nil }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 3)
        request.setValue("curl/8.0", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
            (response as? HTTPURLResponse)?.statusCode == 200,
            data.count < 64,
            let text = String(data: data, encoding: .utf8)
        else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let allowed = CharacterSet(charactersIn: "0123456789abcdefABCDEF.:")
        guard !trimmed.isEmpty, trimmed.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return nil }
        return trimmed
    }
}
