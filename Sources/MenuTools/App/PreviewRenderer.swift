import AppKit
import SwiftUI

@MainActor
enum PreviewRenderer {
    static func render(
        to outputURL: URL, showSettings: Bool, showAntiSleepPicker: Bool = false, showFanPicker: Bool = false
    ) -> Bool {
        let appState = AppState(previewMode: true)
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
            showAntiSleepPicker: showAntiSleepPicker,
            showFanControlPicker: showFanPicker,
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

    static func renderBatteryPreviews(to dirURL: URL) -> Bool {
        let testCases: [(name: String, image: NSImage)] = [
            ("battery-charge-85-dark", BatteryIconRenderer.renderChargeOnly(percentage: 85, isCharging: false, isLowPowerMode: false, isDarkMode: true)),
            ("battery-charge-85-light", BatteryIconRenderer.renderChargeOnly(percentage: 85, isCharging: false, isLowPowerMode: false, isDarkMode: false)),
            ("battery-charge-100-dark", BatteryIconRenderer.renderChargeOnly(percentage: 100, isCharging: false, isLowPowerMode: false, isDarkMode: true)),
            ("battery-charge-charging-85-dark", BatteryIconRenderer.renderChargeOnly(percentage: 85, isCharging: true, isLowPowerMode: false, isDarkMode: true)),
            ("battery-charge-low-15-dark", BatteryIconRenderer.renderChargeOnly(percentage: 15, isCharging: false, isLowPowerMode: false, isDarkMode: true)),
            ("battery-charge-lowpower-85-dark", BatteryIconRenderer.renderChargeOnly(percentage: 85, isCharging: false, isLowPowerMode: true, isDarkMode: true)),
            ("battery-bar-charge-85-dark", BatteryIconRenderer.renderBar(percentage: 85, isCharging: false, isLowPowerMode: false, showPercentage: true, showPercentSymbol: false, isDarkMode: true)),
            ("battery-bar-charge-charging-85-dark", BatteryIconRenderer.renderBar(percentage: 85, isCharging: true, isLowPowerMode: false, showPercentage: true, showPercentSymbol: false, isDarkMode: true)),
            ("battery-gg-percent-80-dark", BatteryIconRenderer.renderGoldenGateBar(percentage: 80, isCharging: false, isLowPowerMode: false, showPercentInside: true, isDarkMode: true)),
            ("battery-gg-percent-80-light", BatteryIconRenderer.renderGoldenGateBar(percentage: 80, isCharging: false, isLowPowerMode: false, showPercentInside: true, isDarkMode: false)),
            ("battery-gg-percent-15-dark", BatteryIconRenderer.renderGoldenGateBar(percentage: 15, isCharging: false, isLowPowerMode: false, showPercentInside: true, isDarkMode: true)),
        ]

        for (name, img) in testCases {
            let scale: CGFloat = 3.0
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
                NSColor(white: 0.12, alpha: 1.0).setFill()
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
