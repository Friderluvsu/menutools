import AppKit

/// `--panel-memory-diagnose [seconds]`: measures the physical footprint (the `vmmap` "Physical footprint"
/// value) at launch, after the panel's monitors run, after open/close cycles and while the panel stays
/// open (default 180 s, sampled every 20 s), then quits. Prints numbers only.
@MainActor
enum PanelMemoryDiagnose {
    static func run(delegate: AppDelegate) {
        let args = CommandLine.arguments
        let openSeconds = args.firstIndex(of: "--panel-memory-diagnose")
            .flatMap { args.indices.contains($0 + 1) ? Int(args[$0 + 1]) : nil } ?? 180

        Task { @MainActor in
            await sleep(3)
            report("launch, panel never opened")
            if let state = delegate.appStateForDiagnose {
                state.onPopoverWillShow()
                await sleep(4)
                state.onPopoverDidClose()
                await sleep(1)
                report("monitors ran 4 s, no UI")
            }

            for _ in 1...10 {
                delegate.showPanel()
                await sleep(0.3)
                delegate.hidePanel()
                await sleep(0.2)
            }
            report("after 10 open/close")

            delegate.showPanel()
            for elapsed in stride(from: 20, through: openSeconds, by: 20) {
                await sleep(20)
                report("open \(elapsed) s")
            }
            delegate.hidePanel()
            await sleep(2)
            report("closed")
            NSApp.terminate(nil)
        }
    }

    private static func sleep(_ seconds: Double) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    private static func report(_ phase: String) {
        print(String(format: "footprint_mb=%.1f cpu_s=%.2f phase=%@", footprintMB(), cpuSeconds(), phase))
        fflush(stdout)
    }

    private static func cpuSeconds() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
            + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
    }

    private static func footprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return -1 }
        return Double(info.phys_footprint) / 1_048_576
    }
}
