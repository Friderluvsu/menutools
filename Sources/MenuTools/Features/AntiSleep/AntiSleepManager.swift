import Combine
import Foundation
import IOKit.pwr_mgt

@MainActor
final class AntiSleepManager: ObservableObject {
    @Published var isActive: Bool = false
    @Published var selectedDuration: Int = 0  // in seconds (0 = ∞)
    @Published var remainingSeconds: Int = 0
    @Published var preventDisplaySleep: Bool = true
    @Published var preventLidSleep: Bool = false
    @Published var statusText: String = "OFF"

    private var assertionID: IOPMAssertionID = 0
    private var displayAssertionID: IOPMAssertionID = 0
    private var timerCancellable: AnyCancellable?

    static let durations: [(label: String, seconds: Int)] = [
        ("∞", 0),
        ("15m", 900),
        ("30m", 1800),
        ("1h", 3600),
        ("2h", 7200),
        ("5h", 18000),
    ]

    init() {
        checkSystemSleepState()
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

        // Prevent idle system sleep
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            reason,
            &assertionID
        )

        if result == kIOReturnSuccess {
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
                Shell.run("sudo pmset -a disablesleep 1")
            }

            isActive = true
            remainingSeconds = selectedDuration
            startTimer()
            updateStatusText()
        } else {
            print("Failed to create IOPM assertion: \(result)")
        }
    }

    func deactivate() {
        deactivateAssertions()

        if preventLidSleep {
            Shell.run("sudo pmset -a disablesleep 0")
        }

        // Also terminate any stray caffeinate processes started by previous utilities
        Shell.run("killall caffeinate 2>/dev/null")

        timerCancellable?.cancel()
        timerCancellable = nil
        isActive = false
        remainingSeconds = 0
        updateStatusText()
    }

    private func deactivateAssertions() {
        if assertionID != 0 {
            IOPMAssertionRelease(assertionID)
            assertionID = 0
        }
        if displayAssertionID != 0 {
            IOPMAssertionRelease(displayAssertionID)
            displayAssertionID = 0
        }
    }

    private func startTimer() {
        timerCancellable?.cancel()
        guard selectedDuration > 0 else { return }

        timerCancellable = Timer.publish(every: 1.0, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                guard let self = self else { return }
                if self.remainingSeconds > 1 {
                    self.remainingSeconds -= 1
                    self.updateStatusText()
                } else {
                    self.deactivate()
                }
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
            statusText = "OFF"
            return
        }
        if selectedDuration == 0 {
            statusText = "ON (∞)"
        } else {
            let m = remainingSeconds / 60
            let s = remainingSeconds % 60
            if m >= 60 {
                let h = m / 60
                let remM = m % 60
                statusText = String(format: "%dh %02dm", h, remM)
            } else {
                statusText = String(format: "%02d:%02d", m, s)
            }
        }
    }

    func checkSystemSleepState() {
        let (output, _) = Shell.run("pgrep -x caffeinate")
        let (pmsetOutput, _) = Shell.run("pmset -g | grep -q 'SleepDisabled.*1'")
        if !output.isEmpty || pmsetOutput.contains("1") {
            // Already active outside
            isActive = true
            updateStatusText()
        }
    }
}
