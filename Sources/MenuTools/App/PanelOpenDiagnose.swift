import AppKit
import Combine

/// `--panel-open-diagnose`: opens and closes the panel a few times and prints where the time between
/// the click and the window being on screen goes, in milliseconds per step (`open_ms`), then what
/// runs after the first frame (`after_ms`: key focus and the manager scans). Numbers only.
@MainActor
enum PanelOpenDiagnose {
    static let enabled = CommandLine.arguments.contains("--panel-open-diagnose")
    /// Opens a stat page as a tile click would (E below). Sent only by this diagnose.
    static let statRequests = PassthroughSubject<StatTopic, Never>()
    private static var steps: [(String, Double)] = []
    private static var began: Double = 0
    private static let launched = ProcessInfo.processInfo.systemUptime

    static func begin() {
        guard enabled else { return }
        began = ProcessInfo.processInfo.systemUptime
        steps = []
    }

    static func measure<T>(_ label: String, _ body: () -> T) -> T {
        guard enabled else { return body() }
        let start = ProcessInfo.processInfo.systemUptime
        let value = body()
        steps.append((label, (ProcessInfo.processInfo.systemUptime - start) * 1000))
        return value
    }

    static func end(_ tag: String) {
        guard enabled else { return }
        let total = (ProcessInfo.processInfo.systemUptime - began) * 1000
        let parts = steps.map { String(format: "%@=%.1f", $0.0, $0.1) }
        let uptime = ProcessInfo.processInfo.systemUptime - launched
        print(String(format: "t=%.1f %@_ms=%.1f %@", uptime, tag, total, parts.joined(separator: " ")))
        fflush(stdout)
    }

    /// Prints when the run loop next reaches "before waiting", where AppKit draws and commits the
    /// frame, relative to `begin()`: the panel's first frame cannot reach the screen earlier.
    static func markFrame(_ label: String) {
        guard enabled else { return }
        let start = began
        let observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue, false, 0) { _, _ in
            let ms = (ProcessInfo.processInfo.systemUptime - start) * 1000
            print(String(format: "  %@_frame_ms=%.1f", label, ms))
            fflush(stdout)
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            CFRunLoopObserverInvalidate(observer)
        }
    }

    static func run(delegate: AppDelegate) {
        Task { @MainActor in
            // After the launch prebuild and the hidden Settings / Sessions prewarm.
            await sleep(7)
            // A: the click path, same icon each time.
            for _ in 1...3 {
                delegate.showPanel()
                await sleep(0.6)
                delegate.hidePanel()
                await sleep(0.4)
            }
            // C: the manager refresh alone, panel left open.
            if let state = delegate.appStateForDiagnose {
                delegate.showPanel()
                await sleep(0.6)
                for _ in 1...3 {
                    begin()
                    measure("willShow") { state.onPopoverWillShow() }
                    measure("didShow") { state.onPopoverDidShow() }
                    measure("layout") { delegate.panelForDiagnose?.contentView?.layoutSubtreeIfNeeded() }
                    print("C ", terminator: "")
                    end("open")
                    await sleep(0.6)
                }
                delegate.hidePanel()
                await sleep(0.4)
            }
            // D: alternating icons, when there is a Sessions item.
            for cycle in 1...4 {
                let anchor = cycle % 2 == 1 ? delegate.sessionsItemForDiagnose : nil
                print("D ", terminator: "")
                delegate.showPanel(anchor: anchor)
                await sleep(0.6)
                delegate.hidePanel()
                await sleep(0.4)
            }
            // E: close on the CPU page, then open from the Sessions item (the stat page must not
            // show first).
            if let sessions = delegate.sessionsItemForDiagnose {
                for _ in 1...3 {
                    delegate.showPanel()
                    await sleep(0.4)
                    statRequests.send(.cpu)
                    await sleep(1.0)
                    delegate.hidePanel()
                    await sleep(0.6)
                    print("E ", terminator: "")
                    delegate.showPanel(anchor: sessions)
                    await sleep(0.6)
                    delegate.hidePanel()
                    await sleep(0.4)
                }
            }
            NSApp.terminate(nil)
        }
    }

    private static func sleep(_ seconds: Double) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }
}
