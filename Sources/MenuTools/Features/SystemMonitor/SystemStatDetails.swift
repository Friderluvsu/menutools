import Darwin
import Foundation
import IOKit

/// Which dashboard stat tile is open. The detail page shows one of these at a time.
enum StatTopic: String, Equatable {
    case cpu
    case gpu
    case memory
    case temperature
    case network
    case battery
    case disk
    case fan

    var title: String {
        switch self {
        case .cpu: return "CPU"
        case .gpu: return "GPU"
        case .memory: return "Memory"
        case .temperature: return "Temp"
        case .network: return "Network"
        case .battery: return "Battery"
        case .disk: return "Disk"
        case .fan: return "Fan"
        }
    }
}

/// One mounted volume. `availableBytes` is the space Finder would call available.
struct DiskVolume: Equatable, Identifiable, Sendable {
    let id: String
    let name: String
    let totalBytes: UInt64
    let availableBytes: UInt64
    let isStartup: Bool
    let isRemovable: Bool

    var usedBytes: UInt64 {
        totalBytes > availableBytes ? totalBytes - availableBytes : 0
    }

    var usedFraction: Double {
        guard totalBytes > 0 else { return 0 }
        return min(1, Double(usedBytes) / Double(totalBytes))
    }
}

struct ProcessStat: Identifiable, Equatable, Sendable {
    let pid: Int32
    let name: String
    let cpuPercent: Double
    let memoryBytes: UInt64

    var id: Int32 { pid }
}

/// One published snapshot so a detail tick is a single render, and the dashboard never observes it.
struct SystemStatSnapshot: Equatable {
    var cpuUsage: Double = 0
    var cpuUser: Double = 0
    var cpuSystem: Double = 0
    var cpuIdle: Double = 0
    var cpuPerformance: Double?
    var cpuEfficiency: Double?
    var load1: Double = 0
    var load5: Double = 0
    var load15: Double = 0
    var uptime: TimeInterval = 0
    var cpuHistory: [Double] = []

    var memoryUsedGB: Double = 0
    var memoryTotalGB: Double = 0
    var memoryPercent: Double = 0
    var memoryAppGB: Double = 0
    var memoryWiredGB: Double = 0
    var memoryCompressedGB: Double = 0
    var memoryCachedGB: Double = 0
    var swapUsedBytes: UInt64 = 0
    var memoryPressure: String?
    var memoryHistory: [Double] = []

    var temperature: Double = 0
    var temperatureHistory: [Double] = []

    var downloadKBps: Double = 0
    var uploadKBps: Double = 0
    var bytesIn: UInt64 = 0
    var bytesOut: UInt64 = 0
    var downloadHistory: [Double] = []
    var uploadHistory: [Double] = []

    var gpuUsage: Double?
    var gpuRenderer: Double?
    var gpuTiler: Double?
    var gpuMemoryBytes: UInt64 = 0
    var gpuAllocatedBytes: UInt64 = 0
    var gpuModel: String?
    var gpuCores: Int?
    var gpuTemperature: Double?
    var gpuHistory: [Double] = []

    /// Primary link, such as "Wi-Fi" or "Ethernet". Not an address.
    var interfaceLabel: String?
    /// Latest round trip to 1.1.1.1, and how much that round trip has been moving.
    var latencyMs: Double?
    var jitterMs: Double?

    var topCPU: [ProcessStat] = []
    var topMemory: [ProcessStat] = []
    /// `cpuPercent` is the process's share of the GPU.
    var topGPU: [ProcessStat] = []

    /// Startup volume first, then other mounts the user can see.
    var disks: [DiskVolume] = []

    /// Ten minutes at the 2 s history tick.
    static let historyLimit = 300

    mutating func push(_ value: Double, into path: WritableKeyPath<SystemStatSnapshot, [Double]>) {
        var values = self[keyPath: path]
        values.append(value)
        if values.count > Self.historyLimit {
            values.removeFirst(values.count - Self.historyLimit)
        }
        self[keyPath: path] = values
    }
}

@MainActor
final class SystemStatDetails: ObservableObject {
    @Published private(set) var snapshot = SystemStatSnapshot()

    func apply(_ body: (inout SystemStatSnapshot) -> Void) {
        var next = snapshot
        body(&next)
        if next != snapshot { snapshot = next }
    }

    func resetHistory() {
        apply {
            $0.cpuHistory = []
            $0.memoryHistory = []
            $0.temperatureHistory = []
            $0.downloadHistory = []
            $0.uploadHistory = []
            $0.gpuHistory = []
            $0.topCPU = []
            $0.topMemory = []
            $0.topGPU = []
        }
    }

    /// Layout-only numbers for the offscreen preview. Not a live sample.
    func seedPreview() {
        snapshot = .preview
    }
}

extension SystemStatSnapshot {
    fileprivate static var preview: SystemStatSnapshot {
        var snap = SystemStatSnapshot()
        snap.cpuUsage = 19
        snap.cpuUser = 11
        snap.cpuSystem = 8
        snap.cpuIdle = 81
        snap.cpuPerformance = 13
        snap.cpuEfficiency = 25
        snap.load1 = 1.84
        snap.load5 = 1.62
        snap.load15 = 1.41
        snap.uptime = 86_400 + 21 * 3_600
        snap.cpuHistory = series(seed: 2, base: 16, swing: 6, spike: 48)
        snap.memoryUsedGB = 12.4
        snap.memoryTotalGB = 16
        snap.memoryPercent = 78
        snap.memoryAppGB = 7.2
        snap.memoryWiredGB = 2.1
        snap.memoryCompressedGB = 1.4
        snap.memoryCachedGB = 3.2
        snap.memoryPressure = "Normal"
        snap.memoryHistory = series(seed: 5, base: 74, swing: 3, spike: 0)
        snap.temperature = 54
        snap.temperatureHistory = series(seed: 8, base: 50, swing: 4, spike: 8)
        snap.downloadKBps = 2_400
        snap.uploadKBps = 180
        snap.bytesIn = 4_500_000_000
        snap.bytesOut = 800_000_000
        snap.interfaceLabel = "Wi-Fi"
        snap.latencyMs = 18.4
        snap.jitterMs = 2.1
        snap.downloadHistory = series(seed: 3, base: 900, swing: 700, spike: 2_200)
        snap.uploadHistory = series(seed: 6, base: 140, swing: 60, spike: 400)
        snap.gpuUsage = 23
        snap.gpuRenderer = 18
        snap.gpuTiler = 6
        snap.gpuMemoryBytes = 420_000_000
        snap.gpuAllocatedBytes = 3_200_000_000
        snap.gpuModel = "Apple M1"
        snap.gpuCores = 8
        snap.gpuTemperature = 46
        snap.gpuHistory = series(seed: 4, base: 8, swing: 5, spike: 62)
        let processes = [
            ProcessStat(pid: 1, name: "WindowServer", cpuPercent: 18.4, memoryBytes: 220_000_000),
            ProcessStat(pid: 2, name: "Cursor Helper", cpuPercent: 8.4, memoryBytes: 640_000_000),
            ProcessStat(pid: 3, name: "Cursor Helper (Renderer)", cpuPercent: 6.1, memoryBytes: 890_000_000),
            ProcessStat(pid: 4, name: "kernel_task", cpuPercent: 3.2, memoryBytes: 1_100_000_000),
            ProcessStat(pid: 5, name: "syspolicyd", cpuPercent: 1.4, memoryBytes: 42_000_000),
            ProcessStat(pid: 6, name: "Stats", cpuPercent: 1.1, memoryBytes: 180_000_000),
            ProcessStat(pid: 7, name: "app_inkwell", cpuPercent: 0.8, memoryBytes: 96_000_000),
            ProcessStat(pid: 8, name: "Google Chrome Helper", cpuPercent: 0.6, memoryBytes: 310_000_000),
        ]
        snap.topCPU = processes
        snap.topMemory = processes.sorted { $0.memoryBytes > $1.memoryBytes }
        snap.topGPU = [
            ProcessStat(pid: 11, name: "WindowServer", cpuPercent: 24.7, memoryBytes: 0),
            ProcessStat(pid: 12, name: "Cursor Helper", cpuPercent: 2.5, memoryBytes: 0),
            ProcessStat(pid: 13, name: "Google Chrome", cpuPercent: 1.4, memoryBytes: 0),
            ProcessStat(pid: 14, name: "Safari", cpuPercent: 0.8, memoryBytes: 0),
            ProcessStat(pid: 15, name: "Stats", cpuPercent: 0.4, memoryBytes: 0),
            ProcessStat(pid: 16, name: "Telegram", cpuPercent: 0.3, memoryBytes: 0),
            ProcessStat(pid: 17, name: "Finder", cpuPercent: 0.2, memoryBytes: 0),
            ProcessStat(pid: 18, name: "ControlCenter", cpuPercent: 0.1, memoryBytes: 0),
        ]
        snap.disks = [
            DiskVolume(
                id: "boot", name: "Macintosh HD", totalBytes: 494_000_000_000, availableBytes: 30_500_000_000,
                isStartup: true, isRemovable: false),
            DiskVolume(
                id: "backup", name: "Backup", totalBytes: 2_000_000_000_000, availableBytes: 780_000_000_000,
                isStartup: false, isRemovable: true),
        ]
        return snap
    }

    /// Dense 10-minute preview. Spikes keep the filled chart readable at this sample count.
    fileprivate static func series(seed: Int, base: Double, swing: Double, spike: Double) -> [Double] {
        (0..<historyLimit).map { index in
            let wave = sin(Double(index + seed) / 11) * swing
            let hit = (index + seed) % 29 == 0 ? spike : ((index + seed) % 13 == 0 ? spike * 0.4 : 0)
            return max(0, base + wave + hit)
        }
    }
}

/// Efficiency and performance core indexes in `host_processor_info` order.
/// Read from the device tree: on Apple Silicon, perflevel 0 is the performance cluster, but the
/// processor list is not in that order (M1 lists efficiency cores first).
struct CoreLayout: Equatable, Sendable {
    var efficiency: [Int]
    var performance: [Int]

    static let empty = CoreLayout(efficiency: [], performance: [])

    var hasSplit: Bool { !efficiency.isEmpty && !performance.isEmpty }

    static func read() -> CoreLayout {
        let entry = IORegistryEntryFromPath(kIOMainPortDefault, "IODeviceTree:/cpus")
        guard entry != 0 else { return .empty }
        defer { IOObjectRelease(entry) }
        var layout = CoreLayout.empty
        collect(entry, into: &layout)
        return layout
    }

    private static func collect(_ entry: io_registry_entry_t, into layout: inout CoreLayout) {
        if let props = properties(of: entry), let index = integer(props["logical-cpu-id"]) {
            switch letter(props["cluster-type"]) {
            case "E": layout.efficiency.append(index)
            case "P": layout.performance.append(index)
            default: break
            }
        }
        var iterator: io_iterator_t = 0
        guard IORegistryEntryGetChildIterator(entry, kIODeviceTreePlane, &iterator) == KERN_SUCCESS else { return }
        defer { IOObjectRelease(iterator) }
        while case let child = IOIteratorNext(iterator), child != 0 {
            defer { IOObjectRelease(child) }
            collect(child, into: &layout)
        }
    }

    private static func properties(of entry: io_registry_entry_t) -> [String: Any]? {
        var unmanaged: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(entry, &unmanaged, kCFAllocatorDefault, 0) == KERN_SUCCESS,
            let unmanaged
        else { return nil }
        return unmanaged.takeRetainedValue() as? [String: Any]
    }

    private static func integer(_ value: Any?) -> Int? {
        if let number = value as? NSNumber { return number.intValue }
        if let number = value as? Int { return number }
        return nil
    }

    private static func letter(_ value: Any?) -> String? {
        let data: Data?
        if let bytes = value as? Data {
            data = bytes
        } else if let bytes = value as? NSData {
            data = bytes as Data
        } else {
            data = nil
        }
        guard let data, let text = String(data: data, encoding: .utf8) else { return nil }
        let trimmed = text.trimmingCharacters(in: .controlCharacters.union(.whitespacesAndNewlines))
        return trimmed.isEmpty ? nil : trimmed
    }
}

struct CoreSample: Sendable {
    var performance: Double?
    var efficiency: Double?
    var ticks: [Int32]
}

enum CoreSampler {
    static func read(previous: [Int32], layout: CoreLayout) -> CoreSample {
        var cpuCount: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        let result = host_processor_info(
            mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &cpuCount, &info, &infoCount)
        guard result == KERN_SUCCESS, let info else {
            return CoreSample(performance: nil, efficiency: nil, ticks: previous)
        }
        defer {
            let bytes = vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride)
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info), bytes)
        }

        let cores = Int(cpuCount)
        let states = Int(CPU_STATE_MAX)
        guard cores > 0, Int(infoCount) >= cores * states else {
            return CoreSample(performance: nil, efficiency: nil, ticks: previous)
        }

        var ticks = [Int32](repeating: 0, count: cores * states)
        var usage = [Double](repeating: 0, count: cores)
        let hasPrevious = previous.count == ticks.count
        for cpu in 0..<cores {
            let base = cpu * states
            let user = info[base + Int(CPU_STATE_USER)]
            let system = info[base + Int(CPU_STATE_SYSTEM)]
            let idle = info[base + Int(CPU_STATE_IDLE)]
            let nice = info[base + Int(CPU_STATE_NICE)]
            ticks[base] = user
            ticks[base + 1] = system
            ticks[base + 2] = idle
            ticks[base + 3] = nice
            guard hasPrevious else { continue }
            let userDelta = tickDelta(user, previous[base])
            let systemDelta = tickDelta(system, previous[base + 1])
            let idleDelta = tickDelta(idle, previous[base + 2])
            let niceDelta = tickDelta(nice, previous[base + 3])
            let total = userDelta + systemDelta + idleDelta + niceDelta
            if total > 0 {
                usage[cpu] = (userDelta + systemDelta + niceDelta) / total * 100
            }
        }

        func average(_ indexes: [Int]) -> Double? {
            guard hasPrevious, !indexes.isEmpty else { return nil }
            let values = indexes.compactMap { usage.indices.contains($0) ? usage[$0] : nil }
            guard values.count == indexes.count else { return nil }
            return values.reduce(0, +) / Double(values.count)
        }

        return CoreSample(
            performance: layout.hasSplit ? average(layout.performance) : nil,
            efficiency: layout.hasSplit ? average(layout.efficiency) : nil,
            ticks: ticks)
    }

    private static func tickDelta(_ now: Int32, _ then: Int32) -> Double {
        Double(UInt32(bitPattern: now) &- UInt32(bitPattern: then))
    }
}

struct ProcessRanking: Sendable {
    var cpu: [ProcessStat]
    var memory: [ProcessStat]
}

/// Per-process CPU (share of one core) and physical footprint. Sampled only while a detail page needs it.
final class ProcessSampler: @unchecked Sendable {
    private let lock = NSLock()
    private var previous: [pid_t: (user: UInt64, system: UInt64)] = [:]
    private var previousTime: UInt64 = 0
    private let listed = 8

    func reset() {
        lock.lock()
        previous.removeAll(keepingCapacity: true)
        previousTime = 0
        lock.unlock()
    }

    func sample() -> ProcessRanking {
        lock.lock()
        defer { lock.unlock() }

        let now = mach_absolute_time()
        let elapsed = previousTime > 0 && now > previousTime ? now &- previousTime : 0
        let seen = previous
        previousTime = now

        let capacity = Int(proc_listallpids(nil, 0))
        guard capacity > 0 else { return ProcessRanking(cpu: [], memory: []) }
        var pids = [pid_t](repeating: 0, count: capacity + 16)
        let count = Int(proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size)))
        guard count > 0 else { return ProcessRanking(cpu: [], memory: []) }

        var next: [pid_t: (user: UInt64, system: UInt64)] = [:]
        next.reserveCapacity(count)
        var rows: [(pid: pid_t, cpu: Double, bytes: UInt64)] = []
        rows.reserveCapacity(count)
        let ceiling = Double(max(ProcessInfo.processInfo.activeProcessorCount, 1)) * 100

        for pid in pids.prefix(count) where pid > 0 {
            guard let usage = Self.usage(pid) else { continue }
            next[pid] = (usage.user, usage.system)
            var cpu = 0.0
            if elapsed > 0, let prior = seen[pid], usage.user >= prior.user, usage.system >= prior.system {
                let delta = (usage.user - prior.user) + (usage.system - prior.system)
                cpu = min(ceiling, Double(delta) / Double(elapsed) * 100)
            }
            rows.append((pid, cpu, usage.footprint))
        }
        previous = next

        let cpuRows = Array(rows.sorted { $0.cpu > $1.cpu }.filter { $0.cpu >= 0.1 }.prefix(listed))
        let memoryRows = Array(rows.sorted { $0.bytes > $1.bytes }.filter { $0.bytes > 0 }.prefix(listed))
        let named = Set(cpuRows.map(\.pid) + memoryRows.map(\.pid))
        var names: [pid_t: String] = [:]
        for pid in named { names[pid] = Self.name(pid) }

        func stats(_ rows: [(pid: pid_t, cpu: Double, bytes: UInt64)]) -> [ProcessStat] {
            rows.map { row in
                ProcessStat(
                    pid: row.pid, name: names[row.pid] ?? "Process", cpuPercent: row.cpu, memoryBytes: row.bytes)
            }
        }
        return ProcessRanking(cpu: elapsed > 0 ? stats(cpuRows) : [], memory: stats(memoryRows))
    }

    /// `ri_user_time` / `ri_system_time` are mach absolute ticks (same clock as `mach_absolute_time`).
    private static func usage(_ pid: pid_t) -> (user: UInt64, system: UInt64, footprint: UInt64)? {
        var info = rusage_info_v0()
        let status: Int32 = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { rebound in
                proc_pid_rusage(pid, RUSAGE_INFO_V0, rebound)
            }
        }
        guard status == 0 else { return nil }
        return (info.ri_user_time, info.ri_system_time, info.ri_phys_footprint)
    }

    private static func name(_ pid: pid_t) -> String {
        var path = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        if proc_pidpath(pid, &path, UInt32(path.count)) > 0 {
            let last = URL(fileURLWithPath: String(cString: path)).lastPathComponent
            if !last.isEmpty { return last }
        }
        var buffer = [CChar](repeating: 0, count: 64)
        if proc_name(pid, &buffer, UInt32(buffer.count)) > 0 {
            let short = String(cString: buffer)
            if !short.isEmpty { return short }
        }
        return "Process"
    }
}

/// Startup disk plus other mounts a person can see. System volumes under `/System` are left out.
enum DiskSampler {
    private static let keys: Set<URLResourceKey> = [
        .volumeLocalizedNameKey,
        .volumeNameKey,
        .volumeTotalCapacityKey,
        .volumeAvailableCapacityForImportantUsageKey,
        .volumeAvailableCapacityKey,
        .volumeUUIDStringKey,
        .volumeIsRootFileSystemKey,
        .volumeIsRemovableKey,
        .volumeIsEjectableKey,
    ]

    static func read() -> [DiskVolume] {
        let listed =
            FileManager.default.mountedVolumeURLs(
                includingResourceValuesForKeys: Array(keys), options: [.skipHiddenVolumes])
            ?? []
        var volumes: [DiskVolume] = []
        var seen = Set<String>()
        for url in listed {
            guard let volume = make(url, seen: &seen) else { continue }
            volumes.append(volume)
        }
        if !volumes.contains(where: \.isStartup), let root = make(URL(fileURLWithPath: "/"), seen: &seen) {
            volumes.insert(root, at: 0)
        }
        volumes.sort { lhs, rhs in
            if lhs.isStartup != rhs.isStartup { return lhs.isStartup }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
        return volumes
    }

    private static func make(_ url: URL, seen: inout Set<String>) -> DiskVolume? {
        let path = url.path
        if path != "/", path.hasPrefix("/System") || path == "/dev" || path.hasPrefix("/dev/") { return nil }
        guard let values = try? url.resourceValues(forKeys: keys) else { return nil }
        guard let total = values.volumeTotalCapacity, total > 100_000_000 else { return nil }
        let rawAvailable =
            values.volumeAvailableCapacityForImportantUsage ?? Int64(values.volumeAvailableCapacity ?? 0)
        let available = rawAvailable > 0 ? UInt64(rawAvailable) : 0
        let identity = values.volumeUUIDString ?? path
        guard seen.insert(identity).inserted else { return nil }
        let rawName = values.volumeLocalizedName ?? values.volumeName ?? ""
        let startup = path == "/" || values.volumeIsRootFileSystem == true
        let removable = values.volumeIsRemovable == true || values.volumeIsEjectable == true
        return DiskVolume(
            id: identity,
            name: rawName.isEmpty ? "Disk" : rawName,
            totalBytes: UInt64(total),
            availableBytes: min(available, UInt64(total)),
            isStartup: startup,
            isRemovable: removable)
    }
}

enum StatSampler {
    static func loads() -> (Double, Double, Double)? {
        var values = [Double](repeating: 0, count: 3)
        guard getloadavg(&values, 3) == 3 else { return nil }
        return (values[0], values[1], values[2])
    }

    static func pressureLabel() -> String? {
        var level: UInt32 = 0
        var size = MemoryLayout<UInt32>.size
        guard sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0 else { return nil }
        switch level {
        case 1: return "Normal"
        case 2: return "Warning"
        case 4: return "Urgent"
        case 8: return "Critical"
        default: return nil
        }
    }

    static func swapUsedBytes() -> UInt64 {
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.stride
        var mib: [Int32] = [CTL_VM, VM_SWAPUSAGE]
        guard sysctl(&mib, u_int(mib.count), &usage, &size, nil, 0) == 0 else { return 0 }
        return usage.xsu_used
    }

    /// Two samples, one interval apart, so CPU deltas and the top process list are real.
    static func diagnose() -> [String] {
        let layout = CoreLayout.read()
        let sampler = ProcessSampler()
        let gpuSampler = GPUProcessSampler()
        let first = CoreSampler.read(previous: [], layout: layout)
        _ = sampler.sample()
        _ = gpuSampler.sample()
        Thread.sleep(forTimeInterval: 0.7)
        let cores = CoreSampler.read(previous: first.ticks, layout: layout)
        let ranked = sampler.sample()
        let loads = loads()
        var lines = [
            "cores efficiency=\(layout.efficiency) performance=\(layout.performance)",
            String(
                format: "clusters performance=%@ efficiency=%@",
                cores.performance.map { String(format: "%.0f%%", $0) } ?? "n/a",
                cores.efficiency.map { String(format: "%.0f%%", $0) } ?? "n/a"),
        ]
        if let loads {
            lines.append(String(format: "load %.2f %.2f %.2f", loads.0, loads.1, loads.2))
        }
        lines.append("pressure \(pressureLabel() ?? "n/a") swap \(swapUsedBytes())")
        lines.append("link \(NetworkLink.label() ?? "n/a")")
        let disks = DiskSampler.read()
        if let startup = disks.first(where: \.isStartup) {
            lines.append(
                String(
                    format: "disk %@ used=%.0f%% free=%llu total=%llu others=%d",
                    startup.name, startup.usedFraction * 100, startup.availableBytes, startup.totalBytes,
                    max(0, disks.count - 1)))
        } else {
            lines.append("disk n/a")
        }
        let gpu = GPUSampler.read()
        let gpuTemp = SMCDriver.shared.readGPUTemperature()
        lines.append(
            String(
                format: "gpu model=%@ cores=%@ device=%@ renderer=%@ tiler=%@ memory=%llu temp=%@",
                gpu.model ?? "n/a",
                gpu.cores.map(String.init) ?? "n/a",
                gpu.device.map { String(format: "%.0f%%", $0) } ?? "n/a",
                gpu.renderer.map { String(format: "%.0f%%", $0) } ?? "n/a",
                gpu.tiler.map { String(format: "%.0f%%", $0) } ?? "n/a",
                gpu.inUseBytes ?? 0,
                gpuTemp.map { String(format: "%.0fC", $0) } ?? "n/a"))
        lines.append("top gpu")
        for process in gpuSampler.sample() {
            lines.append(String(format: "  %@ %.1f%%", process.name, process.cpuPercent))
        }
        lines.append("top cpu")
        for process in ranked.cpu {
            lines.append(String(format: "  %@ %.1f%%", process.name, process.cpuPercent))
        }
        lines.append("top memory")
        for process in ranked.memory {
            lines.append("  \(process.name) \(process.memoryBytes)")
        }
        return lines
    }
}
