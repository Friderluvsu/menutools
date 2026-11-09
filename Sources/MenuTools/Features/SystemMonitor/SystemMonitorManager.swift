import Combine
import Foundation
import SystemConfiguration

@MainActor
final class SystemMonitorManager: ObservableObject {
    @Published var cpuUsage: Double = 0.0
    @Published var cpuTemperature: Double = 42.0
    @Published var memoryUsedGB: Double = 0.0
    @Published var memoryTotalGB: Double = 0.0
    @Published var memoryPercent: Double = 0.0
    @Published var downloadSpeedKBps: Double = 0.0
    @Published var uploadSpeedKBps: Double = 0.0
    /// Nil until the accelerator has reported a utilization.
    @Published var gpuUsage: Double?

    /// Latest sample for the menu bar items, updated every tick even while the panel is closed.
    /// Not published: the dashboard must not re-render on these ticks.
    struct MenuBarStats: Equatable {
        var cpu: Double = 0
        var temperature: Double?
        var memory: Double = 0
        var downKBps: Double = 0
    }
    private(set) var menuBarStats = MenuBarStats()
    /// Called after each sample (AppDelegate refreshes the title when a stat item is shown).
    var onSample: (() -> Void)?
    /// Nil until the startup volume has been read. Free and total stay 0 until then.
    @Published var diskUsedPercent: Double?
    @Published var diskFreeBytes: UInt64 = 0
    @Published var diskTotalBytes: UInt64 = 0
    @Published var diskName: String = ""
    @Published var localIP: String = "127.0.0.1"
    @Published var publicIP: String = "..."

    /// Detail page state. The dashboard tiles do not observe this.
    let details = SystemStatDetails()

    /// History keeps running while the panel is closed. Tile publishes wait until it is open.
    private var panelOpen = false
    private var cancellable: AnyCancellable?
    private var warmupWorkItem: DispatchWorkItem?
    private var previousCPUInfo: host_cpu_load_info?
    private var previousBytesIn: UInt64 = 0
    private var previousBytesOut: UInt64 = 0
    private var previousTimestamp: Date = Date()
    private var isUpdating: Bool = false
    private var tickCount: Int = 0
    private var previousCoreTicks: [Int32] = []
    private var coreLayout: CoreLayout?
    private let processSampler = ProcessSampler()
    private let gpuProcessSampler = GPUProcessSampler()
    private var samplingProcesses = false
    private var samplingGPU = false
    private var processFollowUp: DispatchWorkItem?
    private var latencyCancellable: AnyCancellable?
    private var latencySamples: [Double] = []
    private var pingInFlight = false

    private var lastPublicIPFetch: Date?
    private var isFetchingPublicIP: Bool = false
    /// A successful lookup is reused this long; a failed one is retried sooner.
    private static let publicIPTTL: TimeInterval = 120
    private static let publicIPRetry: TimeInterval = 30

    init() {
        self.memoryTotalGB = Double(ProcessInfo.processInfo.physicalMemory) / (1024 * 1024 * 1024)
        updateLocalIP()
    }

    /// Starts the 2 s history sampler. Called once at launch so the graphs already have samples when the panel opens.
    func startHistorySampling() {
        guard cancellable == nil else { return }
        updateStats()
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

    func startMonitoring() {
        panelOpen = true
        if cancellable == nil { startHistorySampling() } else { updateStats() }
        fetchPublicIPIfStale()
        updateLocalIP()
        startLatencyProbe()
    }

    func stopMonitoring() {
        panelOpen = false
        processFollowUp?.cancel()
        processFollowUp = nil
        processSampler.reset()
        gpuProcessSampler.reset()
        stopLatencyProbe()
    }

    /// CPU and Memory pages walk processes. The GPU page reads accelerator clients instead.
    func setStatFocus(_ topic: StatTopic?) {
        let wantsProcesses = topic == .cpu || topic == .memory
        let wantsGPU = topic == .gpu
        processFollowUp?.cancel()
        processFollowUp = nil
        if wantsProcesses != samplingProcesses {
            samplingProcesses = wantsProcesses
            processSampler.reset()
            if !wantsProcesses {
                details.apply {
                    $0.topCPU = []
                    $0.topMemory = []
                }
            }
        }
        if wantsGPU != samplingGPU {
            samplingGPU = wantsGPU
            gpuProcessSampler.reset()
            if !wantsGPU {
                details.apply { $0.topGPU = [] }
            }
        }
        guard wantsProcesses || wantsGPU else { return }
        sampleFocusedLists()
        let follow = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.sampleFocusedLists() }
        }
        processFollowUp = follow
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7, execute: follow)
    }

    private func sampleFocusedLists() {
        if samplingProcesses { sampleProcesses() }
        if samplingGPU { sampleGPUProcesses() }
    }

    private func sampleProcesses() {
        guard samplingProcesses else { return }
        let sampler = processSampler
        Task.detached(priority: .utility) { [weak self] in
            let ranked = sampler.sample()
            await MainActor.run { [weak self] in
                guard let self, self.samplingProcesses else { return }
                self.details.apply {
                    $0.topCPU = ranked.cpu
                    $0.topMemory = ranked.memory
                }
            }
        }
    }

    private func sampleGPUProcesses() {
        guard samplingGPU else { return }
        let sampler = gpuProcessSampler
        Task.detached(priority: .utility) { [weak self] in
            let ranked = sampler.sample()
            await MainActor.run { [weak self] in
                guard let self, self.samplingGPU else { return }
                self.details.apply { $0.topGPU = ranked }
            }
        }
    }

    /// Free space moves in small steps. Ignore anything under about 50 MB so the tile stays still.
    private func publishDisk(_ disk: DiskVolume) {
        let percent = disk.usedFraction * 100
        if diskUsedPercent == nil || abs((diskUsedPercent ?? 0) - percent) >= 0.5 {
            diskUsedPercent = percent
        }
        if Self.byteGap(diskFreeBytes, disk.availableBytes) >= 50_000_000 {
            diskFreeBytes = disk.availableBytes
        }
        if Self.byteGap(diskTotalBytes, disk.totalBytes) >= 50_000_000 {
            diskTotalBytes = disk.totalBytes
        }
        if diskName != disk.name { diskName = disk.name }
    }

    private static func byteGap(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
        lhs > rhs ? lhs - rhs : rhs - lhs
    }

    /// Assign only when the displayed value would actually change, so idle ticks do not re-render SwiftUI.
    private func setIfChanged(
        _ keyPath: ReferenceWritableKeyPath<SystemMonitorManager, Double>, _ value: Double, epsilon: Double
    ) {
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
        let prevTicks = previousCoreTicks
        let knownLayout = coreLayout
        let includeProcesses = samplingProcesses
        let includeGPU = samplingGPU
        let sampler = processSampler
        let gpuSampler = gpuProcessSampler

        Task.detached(priority: .utility) { [weak self] in
            // 1. CPU
            var newCPU: Double?
            var cpuUser: Double?
            var cpuSystem: Double?
            var cpuIdle: Double?
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
                        cpuUser = min(100, max(0, (user + nice) / total * 100))
                        cpuSystem = min(100, max(0, sys / total * 100))
                        cpuIdle = min(100, max(0, idle / total * 100))
                    }
                }
                prevCPU = cpuInfo
            }

            // 2. RAM
            var newUsedGB: Double = 0.0
            var newMemPercent: Double = 0.0
            var appGB = 0.0
            var wiredGB = 0.0
            var compressedGB = 0.0
            var cachedGB = 0.0
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
                let gigabyte = 1024.0 * 1024.0 * 1024.0
                let internalBytes = Double(vmStat.internal_page_count) * pageSize
                let purgeable = Double(vmStat.purgeable_count) * pageSize
                let external = Double(vmStat.external_page_count) * pageSize
                appGB = max(0, internalBytes - purgeable) / gigabyte
                wiredGB = wired / gigabyte
                compressedGB = compressed / gigabyte
                cachedGB = (purgeable + external) / gigabyte
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
            let gpuTemp: Double? = readTemperature ? SMCDriver.shared.readGPUTemperature() : nil
            let gpu = GPUSampler.read()
            let link = NetworkLink.label()

            let layout = knownLayout ?? CoreLayout.read()
            let cores = CoreSampler.read(previous: prevTicks, layout: layout)
            let load = StatSampler.loads()
            let pressure = StatSampler.pressureLabel()
            let swap = StatSampler.swapUsedBytes()
            let uptime = ProcessInfo.processInfo.systemUptime
            let ranked: ProcessRanking? = includeProcesses ? sampler.sample() : nil
            let gpuProcesses: [ProcessStat]? = includeGPU ? gpuSampler.sample() : nil
            let disks = DiskSampler.read()

            await MainActor.run {
                [
                    weak self, newCPU, cpuUser, cpuSystem, cpuIdle, newUsedGB, newMemPercent, downSpeed, upSpeed,
                    totalBytesIn, totalBytesOut, appGB, wiredGB, compressedGB, cachedGB,
                ] in
                guard let self = self else { return }
                if let newCPU { self.menuBarStats.cpu = newCPU }
                if let realTemp { self.menuBarStats.temperature = realTemp }
                self.menuBarStats.memory = newMemPercent
                if let downSpeed { self.menuBarStats.downKBps = downSpeed }
                self.onSample?()
                if self.panelOpen {
                    if let newCPU { self.setIfChanged(\.cpuUsage, newCPU, epsilon: 0.1) }
                    if let realTemp { self.setIfChanged(\.cpuTemperature, realTemp, epsilon: 0.5) }
                    self.setIfChanged(\.memoryUsedGB, newUsedGB, epsilon: 0.05)
                    self.setIfChanged(\.memoryPercent, newMemPercent, epsilon: 0.5)
                    // Speeds jitter every sample; ignore sub-0.5 KB/s or sub-3% moves.
                    if let downSpeed, abs(self.downloadSpeedKBps - downSpeed) >= max(0.5, self.downloadSpeedKBps * 0.03)
                    {
                        self.downloadSpeedKBps = downSpeed
                    }
                    if let upSpeed, abs(self.uploadSpeedKBps - upSpeed) >= max(0.5, self.uploadSpeedKBps * 0.03) {
                        self.uploadSpeedKBps = upSpeed
                    }
                    if let device = gpu.device, self.gpuUsage == nil || abs((self.gpuUsage ?? 0) - device) >= 0.5 {
                        self.gpuUsage = device
                    }
                    if let startup = disks.first(where: \.isStartup) ?? disks.first {
                        self.publishDisk(startup)
                    }
                }
                self.previousCPUInfo = prevCPU
                self.previousBytesIn = totalBytesIn
                self.previousBytesOut = totalBytesOut
                self.previousTimestamp = now
                if self.coreLayout != layout { self.coreLayout = layout }
                self.previousCoreTicks = cores.ticks
                self.details.apply { snap in
                    if let newCPU {
                        snap.cpuUsage = newCPU
                        snap.push(newCPU, into: \.cpuHistory)
                    }
                    if let cpuUser { snap.cpuUser = cpuUser }
                    if let cpuSystem { snap.cpuSystem = cpuSystem }
                    if let cpuIdle { snap.cpuIdle = cpuIdle }
                    snap.cpuPerformance = cores.performance
                    snap.cpuEfficiency = cores.efficiency
                    if let load {
                        snap.load1 = load.0
                        snap.load5 = load.1
                        snap.load15 = load.2
                    }
                    snap.uptime = uptime
                    snap.memoryUsedGB = newUsedGB
                    snap.memoryTotalGB = totalGB
                    snap.memoryPercent = newMemPercent
                    snap.memoryAppGB = appGB
                    snap.memoryWiredGB = wiredGB
                    snap.memoryCompressedGB = compressedGB
                    snap.memoryCachedGB = cachedGB
                    snap.swapUsedBytes = swap
                    snap.memoryPressure = pressure
                    snap.push(newMemPercent, into: \.memoryHistory)
                    if let realTemp {
                        snap.temperature = realTemp
                        snap.push(realTemp, into: \.temperatureHistory)
                    }
                    if let downSpeed {
                        snap.downloadKBps = downSpeed
                        snap.push(downSpeed, into: \.downloadHistory)
                    }
                    if let upSpeed {
                        snap.uploadKBps = upSpeed
                        snap.push(upSpeed, into: \.uploadHistory)
                    }
                    snap.bytesIn = totalBytesIn
                    snap.bytesOut = totalBytesOut
                    if let link { snap.interfaceLabel = link }
                    if let device = gpu.device {
                        snap.gpuUsage = device
                        snap.push(device, into: \.gpuHistory)
                    }
                    snap.gpuRenderer = gpu.renderer
                    snap.gpuTiler = gpu.tiler
                    if let used = gpu.inUseBytes { snap.gpuMemoryBytes = used }
                    if let allocated = gpu.allocatedBytes { snap.gpuAllocatedBytes = allocated }
                    if let model = gpu.model { snap.gpuModel = model }
                    if let cores = gpu.cores { snap.gpuCores = cores }
                    if let gpuTemp { snap.gpuTemperature = gpuTemp }
                    if let ranked, self.samplingProcesses {
                        snap.topCPU = ranked.cpu
                        snap.topMemory = ranked.memory
                    }
                    if let gpuProcesses, self.samplingGPU {
                        snap.topGPU = gpuProcesses
                    }
                    if !disks.isEmpty { snap.disks = disks }
                }
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

    /// One ping every few seconds while the panel is open. Jitter is how much the round trip moves.
    private func startLatencyProbe() {
        guard latencyCancellable == nil else { return }
        probeLatency()
        latencyCancellable = Timer.publish(every: 3, tolerance: 1, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.probeLatency() }
    }

    private func stopLatencyProbe() {
        latencyCancellable?.cancel()
        latencyCancellable = nil
        pingInFlight = false
    }

    private func probeLatency() {
        guard panelOpen, !pingInFlight else { return }
        pingInFlight = true
        Task.detached(priority: .utility) { [weak self] in
            let milliseconds = Self.pingMilliseconds()
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.pingInFlight = false
                guard self.panelOpen, let milliseconds else { return }
                self.latencySamples.append(milliseconds)
                if self.latencySamples.count > 8 { self.latencySamples.removeFirst(self.latencySamples.count - 8) }
                let jitter = Self.jitter(self.latencySamples)
                self.details.apply {
                    $0.latencyMs = milliseconds
                    $0.jitterMs = jitter
                }
            }
        }
    }

    /// Mean change between successive round trips. Nil until two pings have landed.
    private static func jitter(_ samples: [Double]) -> Double? {
        guard samples.count >= 2 else { return nil }
        var sum = 0.0
        for index in 1..<samples.count {
            sum += abs(samples[index] - samples[index - 1])
        }
        return sum / Double(samples.count - 1)
    }

    nonisolated private static func pingMilliseconds() -> Double? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/sbin/ping")
        process.arguments = ["-c", "1", "-W", "1000", "1.1.1.1"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return nil
        }
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let text = String(data: data, encoding: .utf8),
            let expression = try? NSRegularExpression(pattern: #"time=([0-9]+(?:\.[0-9]+)?)"#)
        else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = expression.firstMatch(in: text, range: range), match.numberOfRanges > 1,
            let valueRange = Range(match.range(at: 1), in: text)
        else { return nil }
        return Double(text[valueRange])
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

/// Primary interface kind. Addresses stay on the LAN and WAN chips.
enum NetworkLink {
    static func label() -> String? {
        guard let store = SCDynamicStoreCreate(nil, "MenuTools.stats" as CFString, nil, nil) else { return nil }
        let global = "State:/Network/Global/IPv4" as CFString
        guard let ipv4 = SCDynamicStoreCopyValue(store, global) as? [String: Any],
            let name = ipv4["PrimaryInterface"] as? String, !name.isEmpty
        else { return nil }
        let airport = "State:/Network/Interface/\(name)/AirPort" as CFString
        if SCDynamicStoreCopyValue(store, airport) != nil { return "Wi-Fi" }
        if name.hasPrefix("en") { return "Ethernet" }
        if name.hasPrefix("utun") || name.hasPrefix("ipsec") { return "VPN" }
        return name
    }
}
