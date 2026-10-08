import Combine
import Foundation
import IOKit.ps
import IOKit.pwr_mgt

@MainActor
final class AntiSleepManager: ObservableObject {
    private enum Keys {
        static let preventDisplaySleep = "AntiSleep_PreventDisplaySleep"
        static let preventLidSleep = "AntiSleep_PreventLidSleep"
        static let selectedDuration = "AntiSleep_SelectedDuration"
    }

    @Published var isActive: Bool = false
    @Published var selectedDuration: Int = 0 {
        didSet {
            UserDefaults.standard.set(selectedDuration, forKey: Keys.selectedDuration)
        }
    }
    @Published var remainingSeconds: Int = 0
    @Published var preventDisplaySleep: Bool = true {
        didSet {
            UserDefaults.standard.set(preventDisplaySleep, forKey: Keys.preventDisplaySleep)
            if isActive {
                updateDisplayAssertion()
            }
        }
    }
    @Published var preventLidSleep: Bool = true {
        didSet {
            UserDefaults.standard.set(preventLidSleep, forKey: Keys.preventLidSleep)
            if isActive {
                updateLidSleepState()
            }
        }
    }
    @Published var statusText: String = "OFF"
    @Published var lastError: String?
    /// Anti-Sleep is off but `pmset disablesleep 1` could not be undone (admin prompt cancelled).
    @Published private(set) var sleepRestoreFailed = false

    private var assertionID: IOPMAssertionID = 0
    private var systemSleepAssertionID: IOPMAssertionID = 0
    private var displayAssertionID: IOPMAssertionID = 0
    private var countdownTimer: DispatchSourceTimer?
    private var endDate: Date?
    private var caffeinateProcess: Process?
    private var powerRunLoopSource: CFRunLoopSource?
    private var lastOnACPower: Bool?
    /// A caffeinate left over from a previous run (found at launch) that we do not own and must kill by name.
    private var adoptedExternalCaffeinate = false
    /// `pmset disablesleep` as we last set it (or found it at launch), and the state we want.
    /// One worker applies the latest target, so quick on/off toggles can never finish out of order.
    private var lidSleepApplied = false
    private var lidSleepTarget = false
    private var lidSleepWorker: Task<Void, Never>?

    static let durations: [(label: String, seconds: Int)] = [
        ("∞", 0),
        ("15m", 900),
        ("30m", 1800),
        ("1h", 3600),
        ("2h", 7200),
        ("5h", 18000),
    ]

    init() {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: Keys.preventDisplaySleep) != nil {
            self.preventDisplaySleep = defaults.bool(forKey: Keys.preventDisplaySleep)
        }
        if defaults.object(forKey: Keys.preventLidSleep) != nil {
            self.preventLidSleep = defaults.bool(forKey: Keys.preventLidSleep)
        } else {
            self.preventLidSleep = true
        }
        if defaults.object(forKey: Keys.selectedDuration) != nil {
            self.selectedDuration = defaults.integer(forKey: Keys.selectedDuration)
        }

        lastOnACPower = Self.isOnACPower()
        checkSystemSleepState()
        setupPowerSourceObserver()
    }

    func toggle() {
        if isActive {
            deactivate()
        } else {
            activate(duration: selectedDuration)
        }
    }

    func activate(duration: Int? = nil) {
        if let dur = duration {
            selectedDuration = dur
        }

        deactivateAssertions()

        let reason = "MenuTools Anti-Sleep Session" as CFString

        // Prevent idle user sleep
        let idleResult = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            reason,
            &assertionID
        )

        // Prevent system sleep on AC power
        _ = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventSystemSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            reason,
            &systemSleepAssertionID
        )

        if idleResult == kIOReturnSuccess {
            // Prevent display sleep if configured
            if preventDisplaySleep {
                _ = IOPMAssertionCreateWithName(
                    kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                    IOPMAssertionLevel(kIOPMAssertionLevelOn),
                    reason,
                    &displayAssertionID
                )
            }

            // Lid sleep prevention via pmset if enabled
            if preventLidSleep {
                setLidSleepPrevention(enabled: true)
            }

            // Start managed caffeinate background process
            startCaffeinateProcess(timeout: selectedDuration)

            isActive = true
            remainingSeconds = selectedDuration
            endDate = selectedDuration > 0 ? Date().addingTimeInterval(TimeInterval(selectedDuration)) : nil
            startTimer()
            updateStatusText()
            lastError = nil
        } else {
            lastError = "Failed to create power assertion (code \(idleResult))"
            print("Failed to create IOPM assertion: \(idleResult)")
        }
    }

    func deactivate() {
        deactivateAssertions()
        stopCaffeinateProcess()

        lastError = nil
        // Restores system sleep only if we disabled it (no-op, and no admin prompt, otherwise).
        setLidSleepPrevention(enabled: false)

        stopTimer()
        endDate = nil
        isActive = false
        remainingSeconds = 0
        updateStatusText()
    }

    private func updateDisplayAssertion() {
        if preventDisplaySleep && displayAssertionID == 0 {
            let reason = "MenuTools Anti-Sleep Session" as CFString
            _ = IOPMAssertionCreateWithName(
                kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                reason,
                &displayAssertionID
            )
        } else if !preventDisplaySleep && displayAssertionID != 0 {
            IOPMAssertionRelease(displayAssertionID)
            displayAssertionID = 0
        }
    }

    private func updateLidSleepState() {
        if preventLidSleep {
            setLidSleepPrevention(enabled: true)
        } else {
            setLidSleepPrevention(enabled: false)
        }
    }

    private func setLidSleepPrevention(enabled: Bool) {
        lidSleepTarget = enabled
        if sleepRestoreFailed { sleepRestoreFailed = false }
        guard lidSleepWorker == nil, lidSleepApplied != enabled else { return }
        lidSleepWorker = Task { [weak self] in
            while let self = self, self.lidSleepApplied != self.lidSleepTarget {
                let target = self.lidSleepTarget
                if await SMCHelperManager.shared.setLidSleep(disabled: target) {
                    self.lidSleepApplied = target
                    self.lastError = nil
                } else if target {
                    // Enable cancelled: pmset is untouched, so there is nothing to restore later.
                    self.lidSleepTarget = self.lidSleepApplied
                    self.lastError = "Lid sleep not blocked: admin needed"
                    break
                } else {
                    self.lastError = "Sleep still disabled"
                    self.sleepRestoreFailed = true
                    break
                }
            }
            self?.lidSleepWorker = nil
        }
    }

    /// Dashboard retry after a cancelled restore prompt.
    func retryRestoreSleep() {
        setLidSleepPrevention(enabled: false)
    }

    /// Called from applicationWillTerminate: everything here is synchronous, because the process exits right after.
    func prepareForTermination() {
        if isActive {
            deactivateAssertions()
            stopCaffeinateProcess()
            stopTimer()
        }
        // Restore what was applied, or what an in-flight worker may be writing right now.
        if lidSleepApplied || lidSleepWorker != nil {
            SMCHelperManager.restoreSleepSync()
            lidSleepApplied = false
            lidSleepTarget = false
        }
    }

    private func startCaffeinateProcess(timeout: Int) {
        stopCaffeinateProcess(restarting: true)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/caffeinate")
        // -w: caffeinate exits with us, even on SIGKILL or a crash.
        var args = ["-i", "-s", "-m", "-w", String(ProcessInfo.processInfo.processIdentifier)]
        if preventDisplaySleep {
            args.append("-d")
        }
        if timeout > 0 {
            args.append(contentsOf: ["-t", "\(timeout)"])
        }
        process.arguments = args
        do {
            try process.run()
            self.caffeinateProcess = process
        } catch {
            print("Failed to start caffeinate process: \(error)")
        }
    }

    private func stopCaffeinateProcess(restarting: Bool = false) {
        if let proc = caffeinateProcess, proc.isRunning {
            proc.terminate()
        }
        caffeinateProcess = nil

        // Only a caffeinate we did not start needs a by-name kill; our own was terminated above.
        guard adoptedExternalCaffeinate else { return }
        adoptedExternalCaffeinate = false
        if restarting {
            // A new process is about to be launched, so the old one must be gone first.
            Shell.run("killall caffeinate 2>/dev/null")
        } else {
            DispatchQueue.global(qos: .utility).async {
                Shell.run("killall caffeinate 2>/dev/null")
            }
        }
    }

    private func deactivateAssertions() {
        if assertionID != 0 {
            IOPMAssertionRelease(assertionID)
            assertionID = 0
        }
        if systemSleepAssertionID != 0 {
            IOPMAssertionRelease(systemSleepAssertionID)
            systemSleepAssertionID = 0
        }
        if displayAssertionID != 0 {
            IOPMAssertionRelease(displayAssertionID)
            displayAssertionID = 0
        }
    }

    /// Countdown driven by an end date. Ticks every second only while the label shows seconds
    /// (under an hour); longer sessions wake once per displayed minute.
    private func startTimer() {
        stopTimer()
        guard endDate != nil else { return }
        scheduleNextTick()
    }

    private func stopTimer() {
        countdownTimer?.cancel()
        countdownTimer = nil
    }

    private func scheduleNextTick() {
        guard let endDate else { return }
        let remaining = endDate.timeIntervalSinceNow
        let delay: TimeInterval
        if remaining <= 3600 {
            delay = 1.0
        } else {
            // Next change of the "Xh YYm" label: the label floors to minutes of the ceiled remaining time.
            delay = remaining.truncatingRemainder(dividingBy: 60) + 1
        }

        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + delay, leeway: .milliseconds(delay > 5 ? 1000 : 150))
        timer.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.tick() }
        }
        countdownTimer?.cancel()
        countdownTimer = timer
        timer.resume()
    }

    private func tick() {
        guard let endDate else { return }
        let remaining = Int(ceil(endDate.timeIntervalSinceNow))
        if remaining > 0 {
            if remainingSeconds != remaining {
                remainingSeconds = remaining
                updateStatusText()
            }
            scheduleNextTick()
        } else {
            deactivate()
        }
    }

    func selectDuration(_ duration: Int) {
        selectedDuration = duration
        if isActive {
            activate(duration: duration)
        }
    }

    private func updateStatusText() {
        if !isActive {
            setStatusText("OFF")
            return
        }
        if selectedDuration == 0 {
            setStatusText("ON (∞)")
        } else {
            let m = remainingSeconds / 60
            let s = remainingSeconds % 60
            if m >= 60 {
                let h = m / 60
                let remM = m % 60
                setStatusText(String(format: "%dh %02dm", h, remM))
            } else {
                setStatusText(String(format: "%02d:%02d", m, s))
            }
        }
    }

    private func setStatusText(_ text: String) {
        if statusText != text { statusText = text }
    }

    /// Detects a session left over from a previous run. The probes run off the main thread
    /// (no zsh, no pipes) so launching never waits on them.
    func checkSystemSleepState() {
        Task.detached(priority: .utility) { [weak self] in
            let isCaffeinateActive = ProcessLookup.isRunning(named: "caffeinate")
            let pmset = ProcessLookup.output(of: "/usr/bin/pmset", ["-g"])
            let isSleepDisabled = pmset.split(separator: "\n").contains { line in
                line.contains("SleepDisabled") && line.split(whereSeparator: \.isWhitespace).last == "1"
            }

            guard isCaffeinateActive || isSleepDisabled else { return }
            await MainActor.run { [weak self] in
                guard let self else { return }
                // Do not clobber a session the user started while the probe was running.
                if self.caffeinateProcess == nil && isCaffeinateActive { self.adoptedExternalCaffeinate = true }
                if isSleepDisabled {
                    // Already applied: record it so deactivate restores it, without writing pmset again.
                    if self.lidSleepWorker == nil { self.lidSleepApplied = true }
                    if !self.isActive { self.lidSleepTarget = true }
                    // Set before isActive so didSet does not re-apply (and prompt) at launch.
                    if !self.preventLidSleep && !self.isActive { self.preventLidSleep = true }
                }
                if !self.isActive { self.isActive = true }
                self.updateStatusText()
            }
        }
    }

    private func setupPowerSourceObserver() {
        let context = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        let source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context = context else { return }
            let manager = Unmanaged<AntiSleepManager>.fromOpaque(context).takeUnretainedValue()
            // The source lives on the main run loop, so this already runs on the main thread.
            MainActor.assumeIsolated { manager.onPowerSourceChanged() }
        }, context)?.takeRetainedValue()

        if let source = source {
            self.powerRunLoopSource = source
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        }
    }

    private func onPowerSourceChanged() {
        // Battery percentage ticks also land here; only an AC <-> battery switch needs a re-apply.
        let onAC = Self.isOnACPower()
        guard onAC != lastOnACPower else { return }
        lastOnACPower = onAC
        guard isActive else { return }
        // pmset disablesleep is global and survives AC switches, so only caffeinate is restarted.
        // Keep the remaining time instead of restarting the full duration.
        let remaining = endDate.map { max(1, Int(ceil($0.timeIntervalSinceNow))) } ?? 0
        startCaffeinateProcess(timeout: remaining)
    }

    private static func isOnACPower() -> Bool? {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
            let type = IOPSGetProvidingPowerSourceType(blob)?.takeUnretainedValue() as String?
        else { return nil }
        return type == (kIOPSACPowerValue as String)
    }
}
