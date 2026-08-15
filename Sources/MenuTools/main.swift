import AppKit

if let previewFlagIndex = CommandLine.arguments.firstIndex(of: "--render-preview"),
    CommandLine.arguments.indices.contains(previewFlagIndex + 1)
{
    let outputURL = URL(fileURLWithPath: CommandLine.arguments[previewFlagIndex + 1])
    let showSettings = CommandLine.arguments.contains("--settings")
    let rendered = MainActor.assumeIsolated {
        PreviewRenderer.render(to: outputURL, showSettings: showSettings)
    }
    exit(rendered ? 0 : 1)
}

// Prevent multiple running instances of MenuTools
let currentPID = ProcessInfo.processInfo.processIdentifier
let bundleID = Bundle.main.bundleIdentifier ?? "com.frider.MenuTools"
let otherInstances = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
    .filter { $0.processIdentifier != currentPID }

if !otherInstances.isEmpty {
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
