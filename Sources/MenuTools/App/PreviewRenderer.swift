import AppKit
import SwiftUI

@MainActor
enum PreviewRenderer {
    static func render(
        to outputURL: URL, showSettings: Bool, showSessions: Bool = false, showAntiSleepPicker: Bool = false,
        showFanPicker: Bool = false, stat: StatTopic? = nil, openSessionDetail: String? = nil
    ) -> Bool {
        let appState = AppState(previewMode: true)
        if stat != nil {
            appState.systemMonitor.details.seedPreview()
        } else {
            appState.systemMonitor.diskUsedPercent = 62
            appState.systemMonitor.diskFreeBytes = 180_400_000_000
            appState.systemMonitor.diskTotalBytes = 494_000_000_000
            appState.systemMonitor.diskName = "Macintosh HD"
        }
        if CommandLine.arguments.contains("--sample-tasks") {
            // Layout check for the converter queue (not used by `make preview`).
            let folder = URL(fileURLWithPath: "/tmp")
            appState.converter.tasks = [
                MediaTask(
                    inputURL: folder.appendingPathComponent("Voice memo 2026-10-09.m4a"), category: .audio,
                    outputFormat: AudioPreset.mp3High.rawValue, status: .completed(outputURL: folder)),
                MediaTask(
                    inputURL: folder.appendingPathComponent("screen-recording.mov"), category: .video,
                    outputFormat: VideoPreset.compressDiscord.rawValue,
                    status: .converting(progress: 0.42, speed: "2.1x")),
                MediaTask(
                    inputURL: folder.appendingPathComponent("photo.heic"), category: .image,
                    outputFormat: ImagePreset.webp.rawValue),
            ]
        }
        // Rendered at its natural height, exactly like the live panel (which fits its content).
        final class HeightBox { var value: CGFloat = 0 }
        let reported = HeightBox()
        let rootView = PopoverContentView(
            appState: appState,
            showSettings: showSettings,
            showSessions: showSessions,
            showStat: stat ?? (showFanPicker ? .fan : nil),
            showAntiSleepPicker: showAntiSleepPicker || CommandLine.arguments.contains("--lid-picker"),
            antiSleepPickerMode: CommandLine.arguments.contains("--lid-picker") ? .lid : .awake,
            openSessionDetail: openSessionDetail,
            onHeightChange: { reported.value = $0 }
        )
        let hostingView = NSHostingView(rootView: rootView)
        hostingView.sizingOptions = []
        var size = NSSize(width: MacToolsTheme.popoverWidth, height: 1200)
        hostingView.frame = NSRect(origin: .zero, size: size)

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = hostingView
        window.backgroundColor = .windowBackgroundColor
        window.appearance = ThemeManager.shared.theme.appearance.flatMap(NSAppearance.init(named:))
        window.layoutIfNeeded()
        hostingView.layoutSubtreeIfNeeded()
        // Preference callbacks may land on the next run loop turn.
        RunLoop.current.run(until: Date().addingTimeInterval(0.15))

        if reported.value > 1 {
            size.height = reported.value.rounded(.up)
        }
        window.setContentSize(size)
        hostingView.frame = NSRect(origin: .zero, size: size)
        window.layoutIfNeeded()
        hostingView.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        hostingView.displayIfNeeded()

        guard let bitmap = hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds) else { return false }
        hostingView.cacheDisplay(in: hostingView.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { return false }

        do {
            try data.write(to: outputURL, options: .atomic)
            print("Preview height: \(Int(size.height))pt")
            return true
        } catch {
            fputs("Preview render failed: \(error.localizedDescription)\n", stderr)
            return false
        }
    }

    /// `--render-status-lights <png>`: one row per style. Columns: quiet, mixed, all on, a light
    /// popping on (with halo), a light turning off, open spin / wave, then all on over a light menu bar.
    /// Count styles show counts instead (see `countColumns`).
    static func renderStatusLights(to outputURL: URL) -> Bool {
        let scale: CGFloat = 6
        let cell = NSSize(width: 30 * scale, height: 24 * scale)
        let styles = StatusLightStyle.allCases
        let columns = 7
        let size = NSSize(width: cell.width * CGFloat(columns), height: cell.height * CGFloat(styles.count))
        guard
            let bitmap = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height), bitsPerSample: 8,
                samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0,
                bitsPerPixel: 0)
        else { return false }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        let on = StatusLightFrame(level: 1)
        let off = StatusLightFrame(level: 0)
        for (row, style) in styles.enumerated() {
            let frames: [([StatusLightFrame], CGFloat, Bool, Bool)] = [
                ([off, off, off], 0, true, false),
                ([on, off, on], 0, true, false),
                ([on, on, on], 0, true, false),
                ([StatusLightFrame(level: 0.8, scale: 1.28, halo: 0.3), on, off], 0, true, false),
                ([on, StatusLightFrame(level: 0.35, scale: 0.75), off], 0, true, false),
                (
                    [StatusLightFrame(level: 1, scale: 1.25), StatusLightFrame(level: 1, scale: 1.1), on],
                    style.spinsOnOpen ? -130 : 0, true, false
                ),
                ([on, on, on], 0, false, true),
            ]
            for (column, frame) in frames.enumerated() {
                let rect = NSRect(
                    x: CGFloat(column) * cell.width, y: size.height - CGFloat(row + 1) * cell.height,
                    width: cell.width, height: cell.height)
                (frame.3 ? NSColor(white: 0.93, alpha: 1) : NSColor(white: 0.13, alpha: 1)).setFill()
                rect.fill()
                // Count styles: quiet, 1 / 2 / 3 running, one of each, 2-3-1, then 3-3-3 on a light bar.
                let countColumns = [[0, 0, 0], [0, 1, 0], [0, 2, 0], [0, 3, 0], [1, 1, 1], [2, 3, 1], [3, 3, 3]]
                let image = StatusLightsRenderer.image(
                    style: style, lights: frame.0, rotation: frame.1, isDark: frame.2, scale: scale,
                    counts: style.isCounting ? countColumns[column] : nil)
                let origin = NSPoint(x: rect.midX - image.size.width / 2, y: rect.midY - image.size.height / 2)
                image.draw(at: origin, from: .zero, operation: .sourceOver, fraction: 1)
            }
        }
        NSGraphicsContext.restoreGraphicsState()
        guard let data = bitmap.representation(using: .png, properties: [:]) else { return false }
        return (try? data.write(to: outputURL, options: .atomic)) != nil
    }

    static func renderBatteryPreviews(to dirURL: URL) -> Bool {
        let testCases: [(name: String, image: NSImage)] = [
            (
                "battery-charge-85-dark",
                BatteryIconRenderer.renderChargeOnly(
                    percentage: 85, isCharging: false, isLowPowerMode: false, isDarkMode: true)
            ),
            (
                "battery-charge-85-light",
                BatteryIconRenderer.renderChargeOnly(
                    percentage: 85, isCharging: false, isLowPowerMode: false, isDarkMode: false)
            ),
            (
                "battery-charge-100-dark",
                BatteryIconRenderer.renderChargeOnly(
                    percentage: 100, isCharging: false, isLowPowerMode: false, isDarkMode: true)
            ),
            (
                "battery-charge-charging-85-dark",
                BatteryIconRenderer.renderChargeOnly(
                    percentage: 85, isCharging: true, isLowPowerMode: false, isDarkMode: true)
            ),
            (
                "battery-charge-low-15-dark",
                BatteryIconRenderer.renderChargeOnly(
                    percentage: 15, isCharging: false, isLowPowerMode: false, isDarkMode: true)
            ),
            (
                "battery-charge-lowpower-85-dark",
                BatteryIconRenderer.renderChargeOnly(
                    percentage: 85, isCharging: false, isLowPowerMode: true, isDarkMode: true)
            ),
            (
                "battery-bar-charge-85-dark",
                BatteryIconRenderer.renderBar(
                    percentage: 85, isCharging: false, isLowPowerMode: false, showPercentage: true,
                    showPercentSymbol: false, isDarkMode: true)
            ),
            (
                "battery-bar-charge-charging-85-dark",
                BatteryIconRenderer.renderBar(
                    percentage: 85, isCharging: true, isLowPowerMode: false, showPercentage: true,
                    showPercentSymbol: false, isDarkMode: true)
            ),
            (
                "battery-gg-percent-80-dark",
                BatteryIconRenderer.renderGoldenGateBar(
                    percentage: 80, isCharging: false, isLowPowerMode: false, showPercentInside: true, isDarkMode: true)
            ),
            (
                "battery-gg-percent-80-light",
                BatteryIconRenderer.renderGoldenGateBar(
                    percentage: 80, isCharging: false, isLowPowerMode: false, showPercentInside: true, isDarkMode: false
                )
            ),
            (
                "battery-gg-percent-15-dark",
                BatteryIconRenderer.renderGoldenGateBar(
                    percentage: 15, isCharging: false, isLowPowerMode: false, showPercentInside: true, isDarkMode: true)
            ),
            (
                "battery-gg-percent-100-dark",
                BatteryIconRenderer.renderGoldenGateBar(
                    percentage: 100, isCharging: false, isLowPowerMode: false, showPercentInside: true, isDarkMode: true
                )
            ),
            (
                "battery-gg-plain-80-dark",
                BatteryIconRenderer.renderGoldenGateBar(
                    percentage: 80, isCharging: false, isLowPowerMode: false, showPercentInside: false, isDarkMode: true
                )
            ),
            (
                "battery-gg-bolt-80-dark",
                BatteryIconRenderer.renderGoldenGateBar(
                    percentage: 80, isCharging: true, isLowPowerMode: false, showPercentInside: true, isDarkMode: true)
            ),
            (
                "battery-gg-bigbolt-80-dark",
                BatteryIconRenderer.renderGoldenGateBar(
                    percentage: 80, isCharging: true, isLowPowerMode: false, showPercentInside: false, isDarkMode: true)
            ),
            (
                "battery-gg-bolt-100-dark",
                BatteryIconRenderer.renderGoldenGateBar(
                    percentage: 100, isCharging: true, isLowPowerMode: false, showPercentInside: true, isDarkMode: true)
            ),
            (
                "battery-gg-bolt-80-light",
                BatteryIconRenderer.renderGoldenGateBar(
                    percentage: 80, isCharging: true, isLowPowerMode: false, showPercentInside: true, isDarkMode: false)
            ),
        ]

        for (name, img) in testCases {
            let scale: CGFloat = 2.0  // menu bar backing scale; compare 1:1 with system screenshots
            let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: Int(img.size.width * scale),
                pixelsHigh: Int(img.size.height * scale),
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0
            )
            guard let rep = rep else { continue }
            rep.size = img.size
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            if name.contains("-dark") {
                NSColor(white: 0.02, alpha: 1.0).setFill()
                NSRect(origin: .zero, size: img.size).fill()
            } else {
                NSColor(white: 0.95, alpha: 1.0).setFill()
                NSRect(origin: .zero, size: img.size).fill()
            }
            img.draw(in: NSRect(origin: .zero, size: img.size), from: .zero, operation: .sourceOver, fraction: 1.0)
            NSGraphicsContext.restoreGraphicsState()

            guard let png = rep.representation(using: .png, properties: [:]) else { continue }
            let fileURL = dirURL.appendingPathComponent("\(name).png")
            try? png.write(to: fileURL)
        }
        return true
    }
}
