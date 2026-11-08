import SwiftUI

/// Compact detail for one dashboard stat. Replaces the dashboard the same way Sessions does.
struct StatDetailPage: View {
    let topic: StatTopic
    @ObservedObject var details: SystemStatDetails
    let fan: FanControlManager
    let battery: BatteryManager

    var body: some View {
        MacToolsCard(padding: 8) {
            switch topic {
            case .cpu:
                CPUDetail(snapshot: details.snapshot)
            case .gpu:
                GPUDetail(snapshot: details.snapshot)
            case .memory:
                MemoryDetail(snapshot: details.snapshot)
            case .temperature:
                TemperatureDetail(snapshot: details.snapshot, fan: fan)
            case .network:
                NetworkDetail(snapshot: details.snapshot)
            case .battery:
                BatteryDetail(battery: battery)
            case .disk:
                DiskDetail(snapshot: details.snapshot)
            case .fan:
                FanControlPickerView(fanControl: fan)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Pages

private struct CPUDetail: View {
    let snapshot: SystemStatSnapshot

    private var meters: [Meter] {
        var items = [
            Meter(
                id: "system", label: "System", value: StatFormat.wholePercent(snapshot.cpuSystem),
                fraction: snapshot.cpuSystem / 100, color: StatPalette.system),
            Meter(
                id: "user", label: "User", value: StatFormat.wholePercent(snapshot.cpuUser),
                fraction: snapshot.cpuUser / 100, color: StatPalette.user),
            Meter(
                id: "idle", label: "Idle", value: StatFormat.wholePercent(snapshot.cpuIdle),
                fraction: snapshot.cpuIdle / 100, color: StatPalette.idle),
        ]
        if let performance = snapshot.cpuPerformance {
            items.append(
                Meter(
                    id: "performance", label: "Performance", value: StatFormat.wholePercent(performance),
                    fraction: performance / 100, color: StatPalette.performance))
        }
        if let efficiency = snapshot.cpuEfficiency {
            items.append(
                Meter(
                    id: "efficiency", label: "Efficiency", value: StatFormat.wholePercent(efficiency),
                    fraction: efficiency / 100, color: StatPalette.efficiency))
        }
        return items
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(StatFormat.wholePercent(snapshot.cpuUsage))
                    .font(.system(size: 22, weight: .semibold, design: .monospaced))
                Spacer(minLength: 8)
                Text(StatFormat.uptime(snapshot.uptime))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            UsageChart(values: snapshot.cpuHistory, color: StatPalette.cpu)
            MeterGrid(items: meters)
            LoadTiles(one: snapshot.load1, five: snapshot.load5, fifteen: snapshot.load15)
            ProcessList(
                title: "Top",
                tint: StatPalette.cpu,
                rows: snapshot.topCPU.map { ($0.id, $0.name, StatFormat.tenths($0.cpuPercent), $0.cpuPercent) })
        }
    }
}

private struct GPUDetail: View {
    let snapshot: SystemStatSnapshot

    private var meters: [Meter] {
        var items: [Meter] = []
        if let renderer = snapshot.gpuRenderer {
            items.append(
                Meter(
                    id: "renderer", label: "Renderer", value: StatFormat.wholePercent(renderer),
                    fraction: renderer / 100, color: StatPalette.performance))
        }
        if let tiler = snapshot.gpuTiler {
            items.append(
                Meter(
                    id: "tiler", label: "Tiler", value: StatFormat.wholePercent(tiler),
                    fraction: tiler / 100, color: StatPalette.efficiency))
        }
        return items
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(snapshot.gpuUsage.map(StatFormat.wholePercent) ?? "—")
                    .font(.system(size: 22, weight: .semibold, design: .monospaced))
                Spacer(minLength: 8)
                if let model = snapshot.gpuModel {
                    Text(model)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            UsageChart(values: snapshot.gpuHistory, color: StatPalette.gpu)
            if !meters.isEmpty {
                MeterGrid(items: meters)
            }
            if !facts.isEmpty {
                FactGrid(items: facts)
            }
            ProcessList(
                title: "Top",
                tint: StatPalette.performance,
                rows: snapshot.topGPU.map { ($0.id, $0.name, StatFormat.tenths($0.cpuPercent), $0.cpuPercent) })
        }
    }

    private var facts: [Fact] {
        var items: [Fact] = []
        if snapshot.gpuMemoryBytes > 0 {
            items.append(
                Fact(
                    id: "memory", label: "In use", value: StatFormat.bytes(snapshot.gpuMemoryBytes),
                    tint: StatPalette.performance))
        }
        if snapshot.gpuAllocatedBytes > 0 {
            items.append(
                Fact(
                    id: "alloc", label: "Allocated", value: StatFormat.bytes(snapshot.gpuAllocatedBytes),
                    tint: .secondary))
        }
        if let cores = snapshot.gpuCores {
            items.append(Fact(id: "cores", label: "Cores", value: "\(cores)", tint: .secondary))
        }
        if let temp = snapshot.gpuTemperature {
            items.append(Fact(id: "temp", label: "Temp", value: StatFormat.temperature(temp), tint: .orange))
        }
        return items
    }
}

private struct MemoryDetail: View {
    let snapshot: SystemStatSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(StatFormat.gigabytes(snapshot.memoryUsedGB))
                    .font(.system(size: 22, weight: .semibold, design: .monospaced))
                Text("of \(StatFormat.gigabytes(snapshot.memoryTotalGB))")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Text(StatFormat.wholePercent(snapshot.memoryPercent))
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
            }
            MiniBar(fraction: snapshot.memoryPercent / 100, color: StatPalette.memory, height: 4)
            UsageChart(values: snapshot.memoryHistory, color: StatPalette.memory)
            MeterGrid(items: memoryMeters)
            if !memoryFacts.isEmpty {
                FactGrid(items: memoryFacts)
            }
            ProcessList(
                title: "Top",
                tint: StatPalette.memory,
                rows: snapshot.topMemory.map {
                    ($0.id, $0.name, StatFormat.bytes($0.memoryBytes), Double($0.memoryBytes))
                })
        }
    }

    private var memoryMeters: [Meter] {
        let total = max(snapshot.memoryTotalGB, 0.1)
        return [
            Meter(
                id: "app", label: "App", value: StatFormat.gigabytes(snapshot.memoryAppGB),
                fraction: snapshot.memoryAppGB / total, color: StatPalette.memory),
            Meter(
                id: "wired", label: "Wired", value: StatFormat.gigabytes(snapshot.memoryWiredGB),
                fraction: snapshot.memoryWiredGB / total, color: StatPalette.performance),
            Meter(
                id: "compressed", label: "Compressed", value: StatFormat.gigabytes(snapshot.memoryCompressedGB),
                fraction: snapshot.memoryCompressedGB / total, color: .orange),
            Meter(
                id: "cached", label: "Cached", value: StatFormat.gigabytes(snapshot.memoryCachedGB),
                fraction: snapshot.memoryCachedGB / total, color: StatPalette.efficiency),
        ]
    }

    private var memoryFacts: [Fact] {
        var items: [Fact] = []
        if snapshot.swapUsedBytes >= 50 * 1_048_576 {
            items.append(
                Fact(id: "swap", label: "Swap", value: StatFormat.bytes(snapshot.swapUsedBytes), tint: .orange))
        }
        if let pressure = snapshot.memoryPressure {
            let tint: Color = pressure == "Normal" ? .secondary : (pressure == "Warning" ? .orange : .red)
            items.append(Fact(id: "pressure", label: "Pressure", value: pressure, tint: tint))
        }
        return items
    }
}

private struct TemperatureDetail: View {
    let snapshot: SystemStatSnapshot
    @ObservedObject var fan: FanControlManager

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(snapshot.temperature > 0 ? StatFormat.temperature(snapshot.temperature) : "—")
                .font(.system(size: 22, weight: .semibold, design: .monospaced))
                .foregroundStyle(snapshot.temperature >= 90 ? Color.red : Color.primary)
            UsageChart(values: snapshot.temperatureHistory, color: StatPalette.temperature)
            if fan.hasFans {
                FactGrid(items: [
                    Fact(
                        id: "fan", label: "Fan",
                        value: fan.currentRPM > 0 ? "\(fan.currentRPM) RPM" : fan.fanDisplayShort, tint: StatPalette.fan
                    )
                ])
            }
        }
    }
}

private struct NetworkDetail: View {
    let snapshot: SystemStatSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                rate(label: "Down", value: snapshot.downloadKBps)
                Spacer(minLength: 12)
                rate(label: "Up", value: snapshot.uploadKBps)
            }
            UsageChart(
                series: [snapshot.downloadHistory, snapshot.uploadHistory],
                colors: [StatPalette.down, StatPalette.up],
                anchorsZero: true,
                split: true)
            FactGrid(items: networkFacts)
        }
    }

    private var networkFacts: [Fact] {
        var items = [
            Fact(id: "in", label: "Received", value: StatFormat.bytes(snapshot.bytesIn), tint: StatPalette.down),
            Fact(id: "out", label: "Sent", value: StatFormat.bytes(snapshot.bytesOut), tint: StatPalette.up),
        ]
        if let link = snapshot.interfaceLabel {
            items.append(Fact(id: "link", label: "Link", value: link, tint: StatPalette.down))
        }
        if let peak = snapshot.downloadHistory.max(), peak >= 1 {
            items.append(
                Fact(id: "peak-down", label: "Peak down", value: StatFormat.speed(peak), tint: StatPalette.down))
        }
        if let peak = snapshot.uploadHistory.max(), peak >= 1 {
            items.append(Fact(id: "peak-up", label: "Peak up", value: StatFormat.speed(peak), tint: StatPalette.up))
        }
        items.append(
            Fact(
                id: "latency",
                label: "Latency",
                value: snapshot.latencyMs.map(StatFormat.milliseconds) ?? "—",
                tint: StatPalette.down,
                help: "Round trip to 1.1.1.1"))
        items.append(
            Fact(
                id: "jitter",
                label: "Jitter",
                value: snapshot.jitterMs.map(StatFormat.milliseconds) ?? "—",
                tint: .secondary,
                help: "How much that round trip changes between pings"))
        return items
    }

    private func rate(label: String, value: Double) -> some View {
        let upward = label == "Up"
        return VStack(alignment: upward ? .trailing : .leading, spacing: 1) {
            Text(label)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(upward ? StatPalette.up : StatPalette.down)
            Text(StatFormat.speed(value))
                .font(.system(size: 16, weight: .semibold, design: .monospaced))
                .foregroundStyle(upward ? StatPalette.up : StatPalette.down)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
    }
}

private struct DiskDetail: View {
    let snapshot: SystemStatSnapshot

    private var startup: DiskVolume? {
        snapshot.disks.first { $0.isStartup } ?? snapshot.disks.first
    }

    private var others: [DiskVolume] {
        let primary = startup?.id
        return Array(snapshot.disks.filter { $0.id != primary }.prefix(4))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let startup {
                HStack(alignment: .firstTextBaseline) {
                    Text(StatFormat.wholePercent(startup.usedFraction * 100))
                        .font(.system(size: 22, weight: .semibold, design: .monospaced))
                        .foregroundStyle(startup.usedFraction >= 0.9 ? Color.orange : Color.primary)
                    Spacer(minLength: 8)
                    Text(startup.name)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                MiniBar(
                    fraction: startup.usedFraction,
                    color: startup.usedFraction >= 0.9 ? .orange : StatPalette.disk,
                    height: 4)
                FactGrid(items: [
                    Fact(id: "used", label: "Used", value: StatFormat.bytes(startup.usedBytes), tint: StatPalette.disk),
                    Fact(id: "free", label: "Free", value: StatFormat.bytes(startup.availableBytes), tint: .secondary),
                    Fact(id: "total", label: "Total", value: StatFormat.bytes(startup.totalBytes), tint: .secondary),
                    Fact(
                        id: "media", label: "Drive", value: startup.isRemovable ? "External" : "Internal",
                        tint: .secondary),
                ])
                if !others.isEmpty {
                    Text("Other")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.secondary)
                    VStack(spacing: 6) {
                        ForEach(others) { volume in
                            DiskVolumeRow(volume: volume)
                        }
                    }
                }
            } else {
                Text("—")
                    .font(.system(size: 22, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct DiskVolumeRow: View {
    let volume: DiskVolume

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(volume.name)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                Spacer(minLength: 6)
                Text(StatFormat.wholePercent(volume.usedFraction * 100))
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                Text("\(StatFormat.bytes(volume.availableBytes)) free")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            MiniBar(
                fraction: volume.usedFraction,
                color: volume.usedFraction >= 0.9 ? .orange : StatPalette.disk,
                height: 3)
        }
    }
}

private struct BatteryDetail: View {
    @ObservedObject var battery: BatteryManager

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(battery.hasBattery ? "\(battery.percentage)%" : "AC")
                    .font(.system(size: 22, weight: .semibold, design: .monospaced))
                Spacer(minLength: 8)
                Text(source)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            if battery.hasBattery {
                MiniBar(fraction: Double(battery.percentage) / 100, color: barColor, height: 4)
            }
            FactGrid(items: batteryFacts)
        }
    }

    private var batteryFacts: [Fact] {
        var items: [Fact] = []
        if let remaining = battery.timeRemainingFormatted, !remaining.isEmpty {
            items.append(Fact(id: "time", label: "Time", value: remaining, tint: .secondary))
        }
        if let health = battery.healthText {
            let tint: Color = health.hasSuffix("%") && (Int(health.dropLast()) ?? 100) < 80 ? .orange : .green
            items.append(Fact(id: "health", label: "Health", value: health, tint: tint))
        }
        if let cycles = battery.cycleCount {
            items.append(Fact(id: "cycles", label: "Cycles", value: "\(cycles)", tint: .secondary))
        }
        if let watts = battery.powerWatts {
            items.append(Fact(id: "power", label: "Power", value: String(format: "%.1f W", watts), tint: .yellow))
        }
        if let current = battery.currentMilliamps {
            let charging = current > 0
            let text = current == 0 ? "0 mA" : String(format: "%@%d mA", charging ? "+" : "−", abs(current))
            items.append(Fact(id: "current", label: "Current", value: text, tint: charging ? .yellow : .secondary))
        }
        if let millivolts = battery.voltageMillivolts, millivolts > 0 {
            items.append(
                Fact(
                    id: "voltage", label: "Voltage", value: String(format: "%.1f V", Double(millivolts) / 1000),
                    tint: .secondary))
        }
        if let maxMah = battery.capacityMaxMah, let design = battery.capacityDesignMah {
            items.append(Fact(id: "capacity", label: "Capacity", value: "\(maxMah) / \(design) mAh", tint: .green))
        }
        if let temp = battery.batteryTemperatureC {
            items.append(Fact(id: "temp", label: "Temp", value: StatFormat.temperature(temp), tint: .orange))
        }
        items.append(
            Fact(
                id: "low",
                label: "Low Power",
                value: battery.isLowPowerMode ? "On" : "Off",
                tint: battery.isLowPowerMode ? .yellow : .secondary))
        return items
    }

    private var source: String {
        guard battery.hasBattery else { return "Power adapter" }
        if battery.isCharging { return "Charging" }
        return battery.isPluggedIn ? "On power" : "On battery"
    }

    private var barColor: Color {
        if battery.isCharging { return .green }
        if battery.percentage <= 20 { return .red }
        if battery.isLowPowerMode { return .yellow }
        return .green
    }
}

// MARK: - Pieces

@MainActor
private enum StatPalette {
    private static var charts: ChartPalette { ThemeManager.shared.theme.charts }
    static var cpu: Color { charts.cpu }
    static var gpu: Color { charts.gpu }
    static var memory: Color { charts.memory }
    static var temperature: Color { charts.temperature }
    static var fan: Color { charts.fan }
    static var system: Color { charts.system }
    static var user: Color { charts.user }
    static let idle = Color.primary.opacity(0.38)
    static var performance: Color { charts.performance }
    static var efficiency: Color { charts.efficiency }
    static var down: Color { charts.down }
    static var up: Color { charts.up }
    static var disk: Color { charts.disk }
    static var lineWidth: CGFloat { charts.lineWidth }
    static var fillOpacity: Double { charts.fillOpacity }
}

private struct Meter: Identifiable {
    let id: String
    let label: String
    let value: String
    let fraction: Double
    let color: Color
}

private struct Fact: Identifiable {
    let id: String
    let label: String
    let value: String
    var tint: Color = .secondary
    var help: String?
}

/// Two-column meters: a colored dot, the figure, and a short bar so the mix is visible at a glance.
private struct MeterGrid: View {
    let items: [Meter]

    var body: some View {
        VStack(spacing: 4) {
            ForEach(Array(stride(from: 0, to: items.count, by: 2)), id: \.self) { index in
                if index + 1 < items.count {
                    HStack(spacing: 4) {
                        MeterChip(item: items[index])
                        MeterChip(item: items[index + 1])
                    }
                } else {
                    MeterChip(item: items[index])
                }
            }
        }
    }
}

private struct MeterChip: View {
    @Environment(\.appTheme) private var theme
    let item: Meter

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Circle().fill(item.color).frame(width: 6, height: 6)
                Text(item.label)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text(item.value)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .lineLimit(1)
            }
            MiniBar(fraction: min(max(item.fraction, 0), 1), color: item.color, height: 3)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.tileFill, in: RoundedRectangle(cornerRadius: theme.radius(7), style: .continuous))
    }
}

private struct LoadTiles: View {
    @Environment(\.appTheme) private var theme
    let one: Double
    let five: Double
    let fifteen: Double

    var body: some View {
        HStack(spacing: 4) {
            tile("1m", one)
            tile("5m", five)
            tile("15m", fifteen)
        }
    }

    private func tile(_ label: String, _ value: Double) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.tertiary)
            Text(StatFormat.load(value))
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(theme.tileFill, in: RoundedRectangle(cornerRadius: theme.radius(7), style: .continuous))
    }
}

private struct FactGrid: View {
    let items: [Fact]

    var body: some View {
        VStack(spacing: 4) {
            ForEach(Array(stride(from: 0, to: items.count, by: 2)), id: \.self) { index in
                if index + 1 < items.count {
                    HStack(spacing: 4) {
                        FactChip(item: items[index])
                        FactChip(item: items[index + 1])
                    }
                } else {
                    FactChip(item: items[index])
                }
            }
        }
    }
}

private struct FactChip: View {
    @Environment(\.appTheme) private var theme
    let item: Fact

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 5) {
                Circle().fill(item.tint).frame(width: 5, height: 5)
                Text(item.label)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Text(item.value)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(theme.tileFill, in: RoundedRectangle(cornerRadius: theme.radius(7), style: .continuous))
        .help(item.help ?? "")
    }
}

private struct ProcessList: View {
    @Environment(\.appTheme) private var theme
    let title: String
    let tint: Color
    /// pid, name, formatted value, raw magnitude used for the bar.
    let rows: [(Int32, String, String, Double)]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.tertiary)
            if rows.isEmpty {
                FactChip(item: Fact(id: "sampling", label: "Processes", value: "Sampling", tint: .secondary))
            } else {
                let peak = rows.map(\.3).max() ?? 1
                let order = rows.map(\.0)
                VStack(spacing: 1) {
                    ForEach(Array(rows.enumerated()), id: \.element.0) { index, row in
                        ProcessRow(
                            rank: index + 1,
                            name: row.1,
                            value: row.2,
                            fraction: peak > 0 ? row.3 / peak : 0,
                            tint: tint
                        )
                        .transition(.opacity.combined(with: .offset(y: 6)))
                    }
                }
                .padding(.vertical, 2)
                .background(theme.tileFill, in: RoundedRectangle(cornerRadius: theme.radius(8), style: .continuous))
                .animation(.smooth(duration: 0.4, extraBounce: 0), value: order)
            }
        }
    }
}

/// Plain text on purpose: `.numericText()` rolls are rasterised on the CPU with a blur, and with
/// 8 rows re-ranking every 2 s they cost 25–45% CPU while the page was open.
private struct ProcessRow: View {
    let rank: Int
    let name: String
    let value: String
    let fraction: Double
    let tint: Color

    var body: some View {
        HStack(spacing: 6) {
            Text("\(rank)")
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundStyle(.tertiary)
                .frame(width: 12, alignment: .trailing)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(name)
                        .font(.system(size: 11))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 4)
                    Text(value)
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .lineLimit(1)
                }
                MiniBar(fraction: fraction, color: tint, height: 2)
            }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
    }
}

private struct UsageChart: View {
    @Environment(\.appTheme) private var theme
    var values: [Double] = []
    var series: [[Double]]?
    var color: Color = .primary
    var colors: [Color]?
    /// CPU, memory and temperature scale to the recent samples. Network draws upload above the
    /// center line and download below it, each on its own scale.
    var anchorsZero = false
    var split = false

    /// Previous sample set. The newest point eases in from the last one; a full buffer scrolls.
    @State private var fromLines: [[Double]] = []
    @State private var toLines: [[Double]] = []
    @State private var progress: Double = 1

    private var target: [[Double]] {
        series ?? [values]
    }

    var body: some View {
        let lines = plotted
        let paints = colors ?? [color]
        let shared = bounds(lines.flatMap { $0.map(\.value) })
        let lineWidth = theme.charts.lineWidth
        let fillOpacity = theme.charts.fillOpacity
        Canvas { context, size in
            if split, lines.count >= 2 {
                drawSplit(lines, paints: paints, lineWidth: lineWidth, in: context, size: size)
            } else {
                let slots = CGFloat(SystemStatSnapshot.historyLimit - 1)
                let span = max(shared.ceiling - shared.lower, 0.001)
                for (index, line) in lines.enumerated() where line.count >= 2 {
                    let paint = paints[min(index, paints.count - 1)]
                    var stroke = Path()
                    var fill = Path()
                    for (offset, sample) in line.enumerated() {
                        let x = CGFloat(sample.slot) / slots * size.width
                        let fraction = min(max((sample.value - shared.lower) / span, 0), 1)
                        let point = CGPoint(x: x, y: size.height - CGFloat(fraction) * size.height)
                        if offset == 0 {
                            stroke.move(to: point)
                            fill.move(to: CGPoint(x: 0, y: size.height))
                            fill.addLine(to: point)
                        } else {
                            stroke.addLine(to: point)
                            fill.addLine(to: point)
                        }
                    }
                    if index == 0 {
                        fill.addLine(to: CGPoint(x: size.width, y: size.height))
                        fill.closeSubpath()
                        context.fill(fill, with: .color(paint.opacity(fillOpacity)))
                    }
                    context.stroke(stroke, with: .color(paint.opacity(0.9)), lineWidth: lineWidth)
                }
            }
        }
        .frame(height: split ? 120 : 56)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
        .onAppear {
            guard toLines.isEmpty else { return }
            fromLines = target
            toLines = target
        }
        .onChange(of: target) { _, new in
            let previous = toLines
            guard !previous.isEmpty, Self.canAnimate(from: previous, to: new) else {
                var snap = Transaction()
                snap.disablesAnimations = true
                withTransaction(snap) {
                    fromLines = new
                    toLines = new
                    progress = 1
                }
                return
            }
            var snap = Transaction()
            snap.disablesAnimations = true
            withTransaction(snap) {
                fromLines = previous
                toLines = new
                progress = 0
            }
            // Next turn, so the reset to the previous tip is not merged into the ease.
            DispatchQueue.main.async {
                withAnimation(.smooth(duration: 0.7, extraBounce: 0)) {
                    progress = 1
                }
            }
        }
    }

    private var plotted: [[PlotPoint]] {
        let end = toLines.isEmpty ? target : toLines
        let start = fromLines.count == end.count ? fromLines : end
        let amount = toLines.isEmpty ? 1 : progress
        return zip(start, end).map { pair in
            Self.plot(from: pair.0, to: pair.1, progress: amount)
        }
    }

    /// Upload rises from the middle, download falls from it. Each side uses its own peak, and the
    /// samples span the full width so a short history is still readable.
    private func drawSplit(
        _ lines: [[PlotPoint]], paints: [Color], lineWidth: CGFloat, in context: GraphicsContext, size: CGSize
    ) {
        let mid = size.height / 2
        var rule = Path()
        rule.move(to: CGPoint(x: 0, y: mid))
        rule.addLine(to: CGPoint(x: size.width, y: mid))
        context.stroke(rule, with: .color(Color.primary.opacity(0.16)), lineWidth: 1)

        let download = lines[0]
        let upload = lines[1]
        trace(
            download, peak: download.map(\.value).max() ?? 0, upward: false, paint: paints[0], mid: mid,
            lineWidth: lineWidth, in: context, size: size)
        let uploadPaint = paints.count > 1 ? paints[1] : paints[0]
        trace(
            upload, peak: upload.map(\.value).max() ?? 0, upward: true, paint: uploadPaint, mid: mid,
            lineWidth: lineWidth, in: context, size: size)
    }

    private func trace(
        _ line: [PlotPoint], peak: Double, upward: Bool, paint: Color, mid: CGFloat, lineWidth: CGFloat,
        in context: GraphicsContext, size: CGSize
    ) {
        guard line.count >= 2 else { return }
        let ceiling = max(peak, 1)
        let room = mid - 6
        var stroke = Path()
        var fill = Path()
        for (offset, sample) in line.enumerated() {
            let x = CGFloat(offset) / CGFloat(line.count - 1) * size.width
            let fraction = min(max(sample.value / ceiling, 0), 1)
            let y = upward ? mid - CGFloat(fraction) * room : mid + CGFloat(fraction) * room
            let point = CGPoint(x: x, y: y)
            if offset == 0 {
                stroke.move(to: point)
                fill.move(to: CGPoint(x: x, y: mid))
                fill.addLine(to: point)
            } else {
                stroke.addLine(to: point)
                fill.addLine(to: point)
            }
        }
        fill.addLine(to: CGPoint(x: size.width, y: mid))
        fill.closeSubpath()
        context.fill(fill, with: .color(paint.opacity(0.22)))
        context.stroke(stroke, with: .color(paint), lineWidth: lineWidth + 0.35)
    }

    private func bounds(_ samples: [Double]) -> (lower: Double, ceiling: Double) {
        let dataMin = samples.min() ?? 0
        let dataMax = samples.max() ?? 0
        let pad = max((dataMax - dataMin) * 0.3, 0.5)
        let lower = anchorsZero ? 0.0 : dataMin - pad
        let ceiling = anchorsZero ? max(dataMax, 1) : dataMax + pad
        return (lower, ceiling)
    }

    /// A one-sample append, or a full-buffer shift that drops the oldest sample.
    private static func canAnimate(from: [[Double]], to: [[Double]]) -> Bool {
        guard from.count == to.count, !from.isEmpty else { return false }
        return zip(from, to).allSatisfy { pair in
            let start = pair.0
            let end = pair.1
            let appended = end.count == start.count + 1 && Array(end.dropLast()) == start
            let shifted =
                end.count == start.count && end.count >= 2
                && Array(start.dropFirst()) == Array(end.dropLast())
            return appended || shifted || start == end
        }
    }

    private static func plot(from start: [Double], to end: [Double], progress: Double) -> [PlotPoint] {
        let t = min(max(progress, 0), 1)
        if start.isEmpty || end.isEmpty { return place(end.isEmpty ? start : end) }
        if end.count == start.count + 1, Array(end.dropLast()) == start {
            return grow(start, end, t)
        }
        if end.count == start.count, end.count >= 2, Array(start.dropFirst()) == Array(end.dropLast()) {
            return scroll(start, end, t)
        }
        if end.count == start.count {
            return zip(start, end).enumerated().map { index, pair in
                PlotPoint(slot: slot(index, count: end.count), value: lerp(pair.0, pair.1, t))
            }
        }
        return place(end)
    }

    /// Right-aligned on the fixed 36-sample axis, so a full history still spans the chart.
    private static func slot(_ index: Int, count: Int) -> Double {
        Double(SystemStatSnapshot.historyLimit - count + index)
    }

    private static func place(_ values: [Double]) -> [PlotPoint] {
        guard let only = values.first, values.count == 1 else {
            return values.enumerated().map { PlotPoint(slot: slot($0.offset, count: values.count), value: $0.element) }
        }
        return [
            PlotPoint(slot: slot(0, count: 2), value: only),
            PlotPoint(slot: slot(1, count: 2), value: only),
        ]
    }

    /// The new vertex starts on the previous tip and extends to its own sample.
    private static func grow(_ start: [Double], _ end: [Double], _ t: Double) -> [PlotPoint] {
        guard let last = start.last, let newest = end.last else { return place(end) }
        var points = start.enumerated().map { index, value in
            PlotPoint(
                slot: lerp(slot(index, count: start.count), slot(index, count: end.count), t),
                value: value)
        }
        points.append(
            PlotPoint(
                slot: lerp(slot(start.count - 1, count: start.count), slot(end.count - 1, count: end.count), t),
                value: lerp(last, newest, t)))
        return points
    }

    /// Once the buffer is full, samples slide one slot left and the tip eases to the new value.
    private static func scroll(_ start: [Double], _ end: [Double], _ t: Double) -> [PlotPoint] {
        let combined = start + [end[end.count - 1]]
        let base = Double(SystemStatSnapshot.historyLimit - start.count)
        return (0..<start.count).map { index in
            PlotPoint(slot: base + Double(index), value: sampleAt(combined, Double(index) + t))
        }
    }

    private static func sampleAt(_ values: [Double], _ position: Double) -> Double {
        guard let first = values.first else { return 0 }
        if position <= 0 { return first }
        let upper = Double(values.count - 1)
        if position >= upper { return values[values.count - 1] }
        let lower = Int(position)
        return lerp(values[lower], values[lower + 1], position - Double(lower))
    }

    private static func lerp(_ a: Double, _ b: Double, _ t: Double) -> Double {
        a + (b - a) * t
    }
}

private struct PlotPoint {
    var slot: Double
    var value: Double
}

enum StatFormat {
    static func wholePercent(_ value: Double) -> String {
        "\(Int(value.rounded()))%"
    }

    static func tenths(_ value: Double) -> String {
        String(format: "%.1f%%", value)
    }

    static func load(_ value: Double) -> String {
        String(format: "%.2f", value)
    }

    static func gigabytes(_ value: Double) -> String {
        String(format: "%.1f GB", value)
    }

    static func temperature(_ value: Double) -> String {
        "\(Int(value.rounded()))°C"
    }

    static func uptime(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        let days = total / 86_400
        let hours = (total % 86_400) / 3_600
        let minutes = (total % 3_600) / 60
        if days > 0 { return "\(days)d \(hours)h" }
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return "\(minutes)m"
    }

    static func speed(_ kilobytesPerSecond: Double) -> String {
        if kilobytesPerSecond >= 1024 * 100 { return String(format: "%.0f MB/s", kilobytesPerSecond / 1024) }
        if kilobytesPerSecond >= 1024 { return String(format: "%.1f MB/s", kilobytesPerSecond / 1024) }
        if kilobytesPerSecond >= 10 { return String(format: "%.0f KB/s", kilobytesPerSecond) }
        return String(format: "%.1f KB/s", kilobytesPerSecond)
    }

    static func milliseconds(_ value: Double) -> String {
        if value >= 10 { return String(format: "%.0f ms", value) }
        return String(format: "%.1f ms", value)
    }

    static func bytes(_ value: UInt64) -> String {
        let number = Double(value)
        if number >= 1_099_511_627_776 { return String(format: "%.1f TB", number / 1_099_511_627_776) }
        if number >= 1_073_741_824 { return String(format: "%.1f GB", number / 1_073_741_824) }
        if number >= 1_048_576 { return String(format: "%.0f MB", number / 1_048_576) }
        return String(format: "%.0f KB", number / 1024)
    }
}
