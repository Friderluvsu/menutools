import Darwin
import Foundation
import IOKit

/// One read of the active GPU. Utilization comes from the accelerator's performance statistics,
/// which Apple publishes without extra permission. Missing keys stay nil.
struct GPUReading: Sendable, Equatable {
    var model: String?
    var cores: Int?
    var device: Double?
    var renderer: Double?
    var tiler: Double?
    var inUseBytes: UInt64?
    var allocatedBytes: UInt64?
}

enum GPUSampler {
    static func read() -> GPUReading {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator) == KERN_SUCCESS
        else { return GPUReading() }
        defer { IOObjectRelease(iterator) }

        var best = GPUReading()
        var found = false
        while true {
            let entry = IOIteratorNext(iterator)
            if entry == 0 { break }
            defer { IOObjectRelease(entry) }
            guard let sample = reading(entry), sample.device != nil || sample.inUseBytes != nil else { continue }
            if !found || (sample.device ?? 0) > (best.device ?? 0) {
                best = sample
                found = true
            }
        }
        return best
    }

    private static func reading(_ entry: io_registry_entry_t) -> GPUReading? {
        var unmanaged: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(entry, &unmanaged, kCFAllocatorDefault, 0) == KERN_SUCCESS,
            let unmanaged,
            let props = unmanaged.takeRetainedValue() as? [String: Any]
        else { return nil }

        var sample = GPUReading()
        if let model = props["model"] as? String, !model.isEmpty { sample.model = model }
        if let cores = props["gpu-core-count"] as? NSNumber, cores.intValue > 0 {
            sample.cores = cores.intValue
        }
        guard let stats = props["PerformanceStatistics"] as? [String: Any] else { return sample }
        sample.device = percent(stats, "Device Utilization %")
        sample.renderer = percent(stats, "Renderer Utilization %")
        sample.tiler = percent(stats, "Tiler Utilization %")
        sample.inUseBytes = bytes(stats, "In use system memory")
        sample.allocatedBytes = bytes(stats, "Alloc system memory")
        return sample
    }

    private static func percent(_ stats: [String: Any], _ key: String) -> Double? {
        guard let number = stats[key] as? NSNumber else { return nil }
        let value = number.doubleValue
        guard value.isFinite, (0...100).contains(value) else { return nil }
        return value
    }

    private static func bytes(_ stats: [String: Any], _ key: String) -> UInt64? {
        guard let number = stats[key] as? NSNumber else { return nil }
        let value = number.uint64Value
        return value > 0 ? value : nil
    }
}

/// Top GPU users. `accumulatedGPUTime` on each accelerator client is nanoseconds; the share is
/// that delta divided by the wall-clock delta. Names come from the pid, because the registry
/// truncates them.
final class GPUProcessSampler: @unchecked Sendable {
    private let lock = NSLock()
    private var previous: [pid_t: UInt64] = [:]
    private var previousTicks: UInt64 = 0
    private let listed = 8

    func reset() {
        lock.lock()
        previous.removeAll(keepingCapacity: true)
        previousTicks = 0
        lock.unlock()
    }

    func sample() -> [ProcessStat] {
        lock.lock()
        defer { lock.unlock() }

        let now = mach_absolute_time()
        let elapsedTicks = previousTicks > 0 && now > previousTicks ? now &- previousTicks : 0
        let seen = previous
        previousTicks = now
        let totals = Self.totals()
        previous = totals
        let elapsedNs = Double(elapsedTicks) * Self.nanosPerTick
        guard elapsedNs > 0 else { return [] }

        var rows: [(pid: pid_t, percent: Double)] = []
        for (pid, total) in totals {
            guard let prior = seen[pid], total >= prior else { continue }
            let percent = min(100, Double(total - prior) / elapsedNs * 100)
            if percent >= 0.1 { rows.append((pid, percent)) }
        }
        let top = rows.sorted { $0.percent > $1.percent }.prefix(listed)
        return top.map { row in
            ProcessStat(pid: row.pid, name: Self.name(row.pid), cpuPercent: row.percent, memoryBytes: 0)
        }
    }

    private static let nanosPerTick: Double = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        guard info.denom > 0 else { return 1 }
        return Double(info.numer) / Double(info.denom)
    }()

    /// Sum of GPU time per pid. The user clients are not registered services, so the walk starts at
    /// the accelerator and follows its children. One process can hold several clients.
    private static func totals() -> [pid_t: UInt64] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator) == KERN_SUCCESS
        else { return [:] }
        defer { IOObjectRelease(iterator) }
        var totals: [pid_t: UInt64] = [:]
        while true {
            let entry = IOIteratorNext(iterator)
            if entry == 0 { break }
            defer { IOObjectRelease(entry) }
            collect(entry, into: &totals, depth: 0)
        }
        return totals
    }

    private static func collect(_ entry: io_registry_entry_t, into totals: inout [pid_t: UInt64], depth: Int) {
        if let (pid, time) = client(entry) {
            totals[pid, default: 0] &+= time
        }
        guard depth < 6 else { return }
        var children: io_iterator_t = 0
        guard IORegistryEntryGetChildIterator(entry, kIOServicePlane, &children) == KERN_SUCCESS else { return }
        defer { IOObjectRelease(children) }
        while true {
            let child = IOIteratorNext(children)
            if child == 0 { break }
            defer { IOObjectRelease(child) }
            collect(child, into: &totals, depth: depth + 1)
        }
    }

    private static func client(_ entry: io_registry_entry_t) -> (pid_t, UInt64)? {
        var unmanaged: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(entry, &unmanaged, kCFAllocatorDefault, 0) == KERN_SUCCESS,
            let unmanaged,
            let props = unmanaged.takeRetainedValue() as? [String: Any],
            let creator = props["IOUserClientCreator"] as? String,
            let pid = pid(from: creator)
        else { return nil }
        var total: UInt64 = 0
        let usages = (props["AppUsage"] as? [Any]) ?? (props["AppUsage"] as? NSArray as? [Any]) ?? []
        for usage in usages {
            let record = usage as? [String: Any]
            let number = record?["accumulatedGPUTime"] as? NSNumber ?? (usage as? NSDictionary)?["accumulatedGPUTime"] as? NSNumber
            if let number { total &+= number.uint64Value }
        }
        return (pid, total)
    }

    private static func pid(from creator: String) -> pid_t? {
        guard creator.hasPrefix("pid ") else { return nil }
        let rest = creator.dropFirst(4)
        guard let comma = rest.firstIndex(of: ",") else { return nil }
        return pid_t(rest[..<comma].trimmingCharacters(in: .whitespaces))
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
