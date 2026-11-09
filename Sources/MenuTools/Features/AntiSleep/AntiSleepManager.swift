import Combine
import Foundation
import IOKit.ps
import IOKit.pwr_mgt
import UserNotifications

/// Two independent sessions:
/// - **Awake**: the Mac (and, by default, the display) does not idle-sleep. Power assertions only; no admin.
///   Closing the lid still sleeps.
/// - **Closed-lid**: the Mac keeps running with the lid closed, on battery too. Same assertions plus
///   `pmset disablesleep 1` through the privileged helper. A battery guard turns it off at a chosen level.
///
/// Only MenuTools' own assertions count. Other apps' `caffeinate` (Claude Code runs one) is never
/// adopted or killed. Sessions are saved and resumed after a relaunch within the same boot.
@MainActor
final class AntiSleepManager: ObservableObject {
    enum Mode: String {
        case awake
        case lid
    }

    private enum Keys {
        static let preventDisplaySleep = "AntiSleep_PreventDisplaySleep"
        static let preventLidSleep = "AntiSleep_PreventLidSleep"
        static let selectedDuration = "AntiSleep_SelectedDuration"
        static let lidDuration = "AntiSleep_LidDuration"
        static let lidBatteryGuard = "AntiSleep_LidBatteryGuard"
        static let session = "AntiSleep_Session"
    }

    // MARK: Published state

    /// Awake session on.
    @Published private(set) var awakeOn = false
    /// Closed-lid session on (pmset disablesleep applied).
    @Published private(set) var lidOn = false
    /// Closed-lid is being switched on or off (helper call in flight).
    @Published private(set) var lidWorking = false
    /// Either session on. Kept for the menu bar label and legacy views.
    @Published private(set) var isActive = false

    @Published private(set) var awakeRemaining = 0
    @Published private(set) var lidRemaining = 0
    /// Short countdown for the Awake tile ("12:04", "1h 05m", "On"), and the legacy label.
    @Published private(set) var statusText = "OFF"
    @Published private(set) var lidStatusText = "OFF"

    /// Duration last picked for Awake (0 = until turned off).
    @Published var selectedDuration: Int = 0 {
        didSet { UserDefaults.standard.set(selectedDuration, forKey: Keys.selectedDuration) }
    }
    /// Duration last picked for Closed-lid (0 = until turned off).
    @Published var lidDuration: Int = 0 {
        didSet { UserDefaults.standard.set(lidDuration, forKey: Keys.lidDuration) }
    }
    @Published var preventDisplaySleep: Bool = true {
        didSet {
            UserDefaults.standard.set(preventDisplaySleep, forKey: Keys.preventDisplaySleep)
            refreshAssertions()
        }
    }
    /// Closed-lid stops when the battery (not charging) reaches this percent. 0 turns the guard off.
    @Published var lidBatteryGuard: Int = 15 {
        didSet {
            UserDefaults.standard.set(lidBatteryGuard, forKey: Keys.lidBatteryGuard)
            checkBatteryGuard()
        }
    }
    /// Legacy views bind to this; the dashboard uses the separate Closed-lid button instead.
    @Published var preventLidSleep: Bool = true {
        didSet { UserDefaults.standard.set(preventLidSleep, forKey: Keys.preventLidSleep) }
    }

    @Published var lastError: String?
    /// Closed-lid problem shown on its tile (admin cancelled, battery too low, restore failed).
    @Published private(set) var lidError: String?
    /// `pmset disablesleep 1` is still set but no session wants it (restore failed). The tile offers a retry.
    @Published private(set) var sleepRestoreFailed = false

    static let durations: [(label: String, seconds: Int)] = [
        ("∞", 0), ("15m", 900), ("30m", 1800), ("1h", 3600), ("2h", 7200), ("5h", 18000),
    ]
    static let batteryGuardOptions = [0, 10, 15, 20, 30, 50]

    // MARK: Private state

    private var idleAssertion: IOPMAssertionID = 0
    private var systemAssertion: IOPMAssertionID = 0
    private var displayAssertion: IOPMAssertionID = 0
    private var awakeEnd: Date?
    private var lidEnd: Date?
    private var timer: DispatchSourceTimer?
    private var powerRunLoopSource: CFRunLoopSource?
    /// What `pmset disablesleep` is set to, as far as we know.
    private var sleepDisabledApplied = false
    private var sleepDisabledTarget = false
    private var sleepWorker: Task<Void, Never>?

    init(previewMode: Bool = false) {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: Keys.preventDisplaySleep) != nil {
            preventDisplaySleep = defaults.bool(forKey: Keys.preventDisplaySleep)
        }
        if defaults.object(forKey: Keys.preventLidSleep) != nil {
            preventLidSleep = defaults.bool(forKey: Keys.preventLidSleep)
        }
        selectedDuration = defaults.integer(forKey: Keys.selectedDuration)
        lidDuration = defaults.integer(forKey: Keys.lidDuration)
        if defaults.object(forKey: Keys.lidBatteryGuard) != nil {
            lidBatteryGuard = defaults.integer(forKey: Keys.lidBatteryGuard)
        }
        guard !previewMode else { return }
        setupPowerSourceObserver()
        restoreAtLaunch()
    }

    // MARK: Awake

    func toggle() {
        if awakeOn { deactivate() } else { activate(duration: selectedDuration) }
    }

    func activate(duration: Int? = nil) {
        if let duration { selectedDuration = duration }
        awakeEnd = selectedDuration > 0 ? Date().addingTimeInterval(TimeInterval(selectedDuration)) : nil
        awakeOn = true
        lastError = nil
        sessionsChanged()
    }

    func deactivate() {
        guard awakeOn else { return }
        awakeOn = false
        awakeEnd = nil
        sessionsChanged()
    }

    func selectDuration(_ duration: Int) {
        if awakeOn { activate(duration: duration) } else { selectedDuration = duration }
    }

    // MARK: Closed-lid

    func activateLid(duration: Int? = nil) {
        if let duration { lidDuration = duration }
        if let reason = batteryGuardBlocks() {
            lidError = reason
            return
        }
        lidError = nil
        // Closed-lid needs the helper. Without it every restore (battery stop, timer end) would be an
        // admin prompt shown with the lid closed, nobody to answer it, and sleep left disabled.
        guard SMCHelperManager.isHelperInstalledSync else {
            lidWorking = true
            Task { [weak self] in
                let installed = await SMCHelperManager.shared.installHelper()
                guard let self else { return }
                self.lidWorking = false
                if installed, SMCHelperManager.isHelperInstalledSync {
                    self.activateLid()
                } else {
                    self.lidError = "Closed-lid needs admin"
                }
            }
            return
        }
        lidEnd = lidDuration > 0 ? Date().addingTimeInterval(TimeInterval(lidDuration)) : nil
        lidOn = true
        sessionsChanged()
    }

    func deactivateLid() {
        guard lidOn else { return }
        lidOn = false
        lidEnd = nil
        sessionsChanged()
    }

    /// Dashboard retry after a failed restore of system sleep.
    func retryRestoreSleep() {
        applySleepDisabled(false)
    }

    /// applicationWillTerminate: synchronous, the process exits right after. The saved session is kept,
    /// so a relaunch in the same boot resumes it; system sleep is restored until then.
    func prepareForTermination() {
        releaseAssertions()
        timer?.cancel()
        // A `disablesleep 1` spawned just before quit must not land after the restore below.
        if sleepWorker != nil { Thread.sleep(forTimeInterval: 0.3) }
        if sleepDisabledApplied || sleepWorker != nil {
            SMCHelperManager.restoreSleepSync()
            sleepDisabledApplied = false
        }
    }

    // MARK: Session plumbing

    /// One place that turns the two sessions into assertions, pmset, timer, labels and the saved state.
    private func sessionsChanged() {
        isActive = awakeOn || lidOn
        refreshAssertions()
        applySleepDisabled(lidOn)
        scheduleTimer()
        updateLabels()
        saveSession()
    }

    private func refreshAssertions() {
        let wantSystem = awakeOn || lidOn
        let wantDisplay = awakeOn && preventDisplaySleep
        set(&idleAssertion, kIOPMAssertionTypePreventUserIdleSystemSleep, wantSystem)
        // PreventSystemSleep only matters on AC; with the lid closed on battery, pmset disablesleep does the work.
        set(&systemAssertion, kIOPMAssertionTypePreventSystemSleep, wantSystem)
        set(&displayAssertion, kIOPMAssertionTypePreventUserIdleDisplaySleep, wantDisplay)
    }

    private func set(_ id: inout IOPMAssertionID, _ type: String, _ wanted: Bool) {
        if wanted, id == 0 {
            let result = IOPMAssertionCreateWithName(
                type as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn),
                "MenuTools Anti-Sleep Session" as CFString, &id)
            if result != kIOReturnSuccess {
                id = 0
                lastError = "Power assertion failed (\(result))"
            }
        } else if !wanted, id != 0 {
            IOPMAssertionRelease(id)
            id = 0
        }
    }

    private func releaseAssertions() {
        for id in [idleAssertion, systemAssertion, displayAssertion] where id != 0 { IOPMAssertionRelease(id) }
        idleAssertion = 0
        systemAssertion = 0
        displayAssertion = 0
    }

    /// One worker applies the latest target, so quick on/off toggles never finish out of order.
    private func applySleepDisabled(_ disabled: Bool) {
        sleepDisabledTarget = disabled
        if sleepRestoreFailed { sleepRestoreFailed = false }
        guard sleepWorker == nil, sleepDisabledApplied != disabled else { return }
        lidWorking = true
        sleepWorker = Task { [weak self] in
            while let self, self.sleepDisabledApplied != self.sleepDisabledTarget {
                let target = self.sleepDisabledTarget
                if await SMCHelperManager.shared.setLidSleep(disabled: target) {
                    self.sleepDisabledApplied = target
                } else if target {
                    // Could not disable sleep (admin cancelled): Closed-lid would only pretend to work.
                    self.sleepDisabledTarget = self.sleepDisabledApplied
                    self.lidOn = false
                    self.lidEnd = nil
                    self.lidError = "Closed-lid needs admin"
                    self.isActive = self.awakeOn
                    self.refreshAssertions()
                    self.updateLabels()
                    self.saveSession()
                    break
                } else {
                    self.sleepRestoreFailed = true
                    self.lidError = "Sleep still disabled"
                    break
                }
            }
            self?.lidWorking = false
            self?.sleepWorker = nil
        }
    }

    // MARK: Battery guard

    /// Reason Closed-lid may not start now, if any.
    private func batteryGuardBlocks() -> String? {
        guard lidBatteryGuard > 0, let battery = Self.batteryState(), !battery.onAC else { return nil }
        return battery.percent <= lidBatteryGuard ? "Battery under \(lidBatteryGuard)%" : nil
    }

    private func checkBatteryGuard() {
        guard lidOn, lidBatteryGuard > 0, let battery = Self.batteryState(), !battery.onAC,
            battery.percent <= lidBatteryGuard
        else { return }
        deactivateLid()
        lidError = "Stopped at \(battery.percent)%"
        notify(
            title: "Closed-lid off",
            body: "Battery reached \(battery.percent)%. The Mac can sleep again.")
    }

    private func setupPowerSourceObserver() {
        let context = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        let source = IOPSNotificationCreateRunLoopSource(
            { context in
                guard let context else { return }
                let manager = Unmanaged<AntiSleepManager>.fromOpaque(context).takeUnretainedValue()
                // The source lives on the main run loop, so this already runs on the main thread.
                MainActor.assumeIsolated { manager.checkBatteryGuard() }
            }, context)?.takeRetainedValue()
        if let source {
            powerRunLoopSource = source
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        }
    }

    static func batteryState() -> (onAC: Bool, percent: Int)? {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
            let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef]
        else { return nil }
        for source in list {
            guard
                let info = IOPSGetPowerSourceDescription(blob, source)?.takeUnretainedValue()
                    as? [String: Any],
                (info[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType,
                let current = info[kIOPSCurrentCapacityKey] as? Int,
                let max = info[kIOPSMaxCapacityKey] as? Int, max > 0
            else { continue }
            let onAC = (info[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue
            return (onAC, Int((Double(current) / Double(max) * 100).rounded()))
        }
        return nil
    }

    // MARK: Timer and labels

    private func scheduleTimer() {
        timer?.cancel()
        timer = nil
        let ends = [awakeEnd, lidEnd].compactMap { $0 }
        guard let soonest = ends.min() else { return }
        let remaining = soonest.timeIntervalSinceNow
        // Seconds are shown under an hour; longer sessions only need a tick per displayed minute.
        let delay = remaining <= 3600 ? 1.0 : remaining.truncatingRemainder(dividingBy: 60) + 1
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(
            deadline: .now() + max(0.05, min(delay, remaining)), leeway: .milliseconds(delay > 5 ? 1000 : 150))
        timer.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.tick() } }
        timer.resume()
        self.timer = timer
    }

    private func tick() {
        let now = Date()
        var changed = false
        if let awakeEnd, awakeEnd <= now {
            awakeOn = false
            self.awakeEnd = nil
            changed = true
        }
        if let lidEnd, lidEnd <= now {
            lidOn = false
            self.lidEnd = nil
            changed = true
        }
        if changed {
            sessionsChanged()
        } else {
            updateLabels()
            scheduleTimer()
        }
    }

    private func updateLabels() {
        let awakeLeft = awakeEnd.map { max(0, Int(ceil($0.timeIntervalSinceNow))) } ?? 0
        let lidLeft = lidEnd.map { max(0, Int(ceil($0.timeIntervalSinceNow))) } ?? 0
        if awakeRemaining != awakeLeft { awakeRemaining = awakeLeft }
        if lidRemaining != lidLeft { lidRemaining = lidLeft }
        let awakeText = awakeOn ? Self.format(awakeLeft, infinite: awakeEnd == nil) : "OFF"
        let lidText = lidOn ? Self.format(lidLeft, infinite: lidEnd == nil) : "OFF"
        let main = awakeOn ? awakeText : (lidOn ? lidText : "OFF")
        if statusText != main { statusText = main }
        if lidStatusText != lidText { lidStatusText = lidText }
    }

    /// Legacy label: remaining seconds of the Awake session.
    var remainingSeconds: Int { awakeRemaining }

    private static func format(_ seconds: Int, infinite: Bool) -> String {
        if infinite { return "On" }
        let minutes = seconds / 60
        if minutes >= 60 { return String(format: "%dh %02dm", minutes / 60, minutes % 60) }
        return String(format: "%02d:%02d", minutes, seconds % 60)
    }

    // MARK: Persistence

    private struct SavedSession: Codable {
        var awake: Bool
        var awakeEnd: Date?
        var lid: Bool
        var lidEnd: Date?
        var bootTime: TimeInterval
    }

    private func saveSession() {
        let defaults = UserDefaults.standard
        guard awakeOn || lidOn else {
            defaults.removeObject(forKey: Keys.session)
            return
        }
        let session = SavedSession(
            awake: awakeOn, awakeEnd: awakeEnd, lid: lidOn, lidEnd: lidEnd, bootTime: Self.bootTime())
        if let data = try? JSONEncoder().encode(session) { defaults.set(data, forKey: Keys.session) }
    }

    /// Resume a session saved in this boot (rebuild, update, quit and reopen). Anything else, including
    /// a `disablesleep 1` left by a crash with no session to own it, is put back to normal sleep.
    private func restoreAtLaunch() {
        let defaults = UserDefaults.standard
        var resumed: SavedSession?
        if let data = defaults.data(forKey: Keys.session),
            let session = try? JSONDecoder().decode(SavedSession.self, from: data),
            abs(session.bootTime - Self.bootTime()) < 5
        {
            resumed = session
        }
        let now = Date()
        if let session = resumed {
            if session.awake, session.awakeEnd.map({ $0 > now }) ?? true {
                awakeOn = true
                awakeEnd = session.awakeEnd
            }
            if session.lid, session.lidEnd.map({ $0 > now }) ?? true, SMCHelperManager.isHelperInstalledSync,
                batteryGuardBlocks() == nil
            {
                lidOn = true
                lidEnd = session.lidEnd
            }
        }
        if awakeOn || lidOn {
            sessionsChanged()
        } else {
            defaults.removeObject(forKey: Keys.session)
        }
        // A crash can leave sleep disabled with nothing owning it. Probe off the main thread.
        let ownsSleep = lidOn
        Task.detached(priority: .utility) { [weak self] in
            let pmset = ProcessLookup.output(of: "/usr/bin/pmset", ["-g"])
            let disabled = pmset.split(separator: "\n").contains { line in
                line.contains("SleepDisabled") && line.split(whereSeparator: \.isWhitespace).last == "1"
            }
            guard disabled, !ownsSleep else { return }
            await self?.restoreLeftoverSleepDisabled()
        }
    }

    /// `disablesleep 1` found at launch with no Closed-lid session to own it.
    private func restoreLeftoverSleepDisabled() {
        guard !lidOn else { return }
        sleepDisabledApplied = true
        if SMCHelperManager.isHelperInstalledSync {
            applySleepDisabled(false)
        } else {
            // Restoring would need an admin prompt at launch; offer a retry on the tile instead.
            sleepRestoreFailed = true
        }
    }

    private static func bootTime() -> TimeInterval {
        var boot = timeval()
        var size = MemoryLayout<timeval>.stride
        guard sysctlbyname("kern.boottime", &boot, &size, nil, 0) == 0 else { return 0 }
        return TimeInterval(boot.tv_sec) + TimeInterval(boot.tv_usec) / 1_000_000
    }

    private func notify(title: String, body: String) {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        center.add(UNNotificationRequest(identifier: "antisleep.lid.guard", content: content, trigger: nil))
    }
}

/// `--anti-sleep-diagnose`: turns Awake and Closed-lid on and off and prints what macOS reports.
/// Changes `pmset disablesleep` for a moment and always puts it back.
@MainActor
enum AntiSleepDiagnose {
    static func run() {
        let manager = AntiSleepManager()
        wait(0.5)
        print("helper_installed=\(SMCHelperManager.isHelperInstalledSync)")
        if let battery = AntiSleepManager.batteryState() {
            print("battery_percent=\(battery.percent) on_ac=\(battery.onAC) guard=\(manager.lidBatteryGuard)")
        }
        report("start", manager)
        manager.activate(duration: 0)
        wait(0.3)
        report("awake_on", manager)
        manager.deactivate()
        wait(0.3)
        report("awake_off", manager)
        manager.activateLid(duration: 0)
        wait(until: { !manager.lidWorking }, timeout: 15)
        report("lid_on", manager)
        manager.deactivateLid()
        wait(until: { !manager.lidWorking }, timeout: 15)
        report("lid_off", manager)
    }

    private static func report(_ step: String, _ manager: AntiSleepManager) {
        let assertions = ProcessLookup.output(of: "/usr/bin/pmset", ["-g", "assertions"])
        let pid = ProcessInfo.processInfo.processIdentifier
        let ours = assertions.split(separator: "\n").filter { $0.contains("pid \(pid)(") }.count
        let pmset = ProcessLookup.output(of: "/usr/bin/pmset", ["-g"])
        let disabled = pmset.split(separator: "\n").contains { line in
            line.contains("SleepDisabled") && line.split(whereSeparator: \.isWhitespace).last == "1"
        }
        print(
            "\(step): awake=\(manager.awakeOn) lid=\(manager.lidOn) our_assertions=\(ours) sleep_disabled=\(disabled)"
                + (manager.lidError.map { " lid_error=\"\($0)\"" } ?? ""))
    }

    private static func wait(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    private static func wait(until done: () -> Bool, timeout: TimeInterval) {
        let deadline = Date().addingTimeInterval(timeout)
        wait(0.2)
        while !done(), Date() < deadline { wait(0.1) }
        wait(0.3)
    }
}
