import AppKit

if let previewFlagIndex = CommandLine.arguments.firstIndex(of: "--render-preview"),
    CommandLine.arguments.indices.contains(previewFlagIndex + 1)
{
    let outputURL = URL(fileURLWithPath: CommandLine.arguments[previewFlagIndex + 1])
    let showSettings = CommandLine.arguments.contains("--settings")
    let showAntiSleepPicker = CommandLine.arguments.contains("--anti-sleep-picker")
    let showFanPicker = CommandLine.arguments.contains("--fan-picker")
    let rendered = MainActor.assumeIsolated {
        PreviewRenderer.render(
            to: outputURL,
            showSettings: showSettings,
            showAntiSleepPicker: showAntiSleepPicker,
            showFanPicker: showFanPicker
        )
    }
    exit(rendered ? 0 : 1)
}

if let batteryIconsFlagIndex = CommandLine.arguments.firstIndex(of: "--render-battery-icons"),
    CommandLine.arguments.indices.contains(batteryIconsFlagIndex + 1)
{
    let outputDir = URL(fileURLWithPath: CommandLine.arguments[batteryIconsFlagIndex + 1])
    let rendered = MainActor.assumeIsolated {
        PreviewRenderer.renderBatteryPreviews(to: outputDir)
    }
    exit(rendered ? 0 : 1)
}

if CommandLine.arguments.contains("--window-diagnose") {
    let trusted = AXIsProcessTrusted()
    let mask = CGEventMask(1 << CGEventType.leftMouseDown.rawValue)
    let tap = CGEvent.tapCreate(
        tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
        eventsOfInterest: mask, callback: { _, _, event, _ in Unmanaged.passUnretained(event) }, userInfo: nil)
    print("accessibility_trusted=\(trusted) session_tap_created=\(tap != nil)")
    exit(0)
}

if CommandLine.arguments.contains("--ai-limits-diagnose") {
    let semaphore = DispatchSemaphore(value: 0)
    Task.detached {
        for line in await AIFetchSupport.diagnose() { print(line) }
        semaphore.signal()
    }
    semaphore.wait()
    exit(0)
}

// Prevent multiple running instances of MenuTools
let currentPID = ProcessInfo.processInfo.processIdentifier
let bundleID = Bundle.main.bundleIdentifier ?? "com.frider.MenuTools"
let otherInstances = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
    .filter { $0.processIdentifier != currentPID }

if !otherInstances.isEmpty {
    exit(0)
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}
