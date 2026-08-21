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
    private var previousCPUInfo: host_cpu_load_info?
    private var previousBytesIn: UInt64 = 0
    private var previousBytesOut: UInt64 = 0
    private var previousTimestamp: Date = Date()
    private var isUpdating: Bool = false

    init() {
        self.memoryTotalGB = Double(ProcessInfo.processInfo.physicalMemory) / (1024 * 1024 * 1024)
        updateLocalIP()
    }

    func startMonitoring() {
        guard cancellable == nil else { return }
        updateStats()
        fetchPublicIP()
        updateLocalIP()
        cancellable = Timer.publish(every: 2.0, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                self?.updateStats()
            }
    }

    func stopMonitoring() {
        cancellable?.cancel()
        cancellable = nil
    }

    func updateStats() {
        guard !isUpdating else { return }
        isUpdating = true

        let totalGB = self.memoryTotalGB
        var prevCPU = self.previousCPUInfo
        let prevBytesIn = self.previousBytesIn
        let prevBytesOut = self.previousBytesOut
        let prevTime = self.previousTimestamp

        Task.detached(priority: .utility) { [weak self] in
            // 1. CPU
            var newCPU: Double = 0.0
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
            var downSpeed: Double = 0.0
            var upSpeed: Double = 0.0

            if prevBytesIn > 0 && timeDelta > 0 {
                let inDelta = Double(totalBytesIn >= prevBytesIn ? totalBytesIn - prevBytesIn : 0)
                let outDelta = Double(totalBytesOut >= prevBytesOut ? totalBytesOut - prevBytesOut : 0)
                downSpeed = (inDelta / 1024.0) / timeDelta
                upSpeed = (outDelta / 1024.0) / timeDelta
            }

            // Read real hardware CPU temperature from SMC
            let realTemp = SMCDriver.shared.readCPUTemperature()

            await MainActor.run { [weak self] in
                guard let self = self else { return }
                self.cpuUsage = newCPU
                self.cpuTemperature = realTemp
                self.memoryUsedGB = newUsedGB
                self.memoryPercent = newMemPercent
                self.downloadSpeedKBps = downSpeed
                self.uploadSpeedKBps = upSpeed
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
                    let addrFamily = interface.ifa_addr.pointee.sa_family
                    if addrFamily == UInt8(AF_INET) {
                        let name = String(cString: interface.ifa_name)
                        if name == "en0" || name == "en1" {
                            var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                            if getnameinfo(
                                interface.ifa_addr,
                                socklen_t(interface.ifa_addr.pointee.sa_len),
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
                self?.localIP = resolvedIP
            }
        }
    }

    func fetchPublicIP() {
        Task.detached(priority: .utility) { [weak self] in
            let (output, _) = Shell.run(
                "curl -s --max-time 2 https://api.ipify.org || curl -s --max-time 2 https://ifconfig.me")
            let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
            await MainActor.run { [weak self] in
                if !trimmed.isEmpty && !trimmed.contains("curl:") {
                    self?.publicIP = trimmed
                } else {
                    self?.publicIP = "Offline"
                }
            }
        }
    }
}
