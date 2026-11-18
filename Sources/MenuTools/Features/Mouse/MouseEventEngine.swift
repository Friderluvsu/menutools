import AppKit
import os

/// Session event tap for the mouse wheel and the extra buttons. Runs on its own thread with its own
/// run loop, so a busy main thread (SwiftUI, the panel) never delays a scroll frame.
///
/// - Wheel: only line-based (non-continuous) events are touched; trackpads and Magic Mouse send
///   continuous events and pass through. Each tick is consumed and replaced by pixel events, either
///   at once or spread over `scrollDuration` with an exponential ease-out (smooth scroll).
/// - Buttons: a bound button's down / drag / up are consumed and its action runs on press.
/// - Our own posted events carry `marker` in `eventSourceUserData` and are passed through.
final class MouseEventEngine: @unchecked Sendable {
    static let marker: Int64 = 0x4D54_4D53  // "MTMS"

    /// Everything an event needs, resolved on the main thread for the frontmost app. A class, so the
    /// per-event read under the lock is one retain instead of copying the prefs and their arrays.
    final class Config: @unchecked Sendable {
        let prefs: MousePrefs
        let scrollOn: Bool
        let buttonsOn: Bool
        let bindings: [Int64: MouseButtonBinding]

        init(prefs: MousePrefs = MousePrefs(), frontmost: String? = nil) {
            self.prefs = prefs
            let rule = frontmost.flatMap { id in prefs.appRules.first { $0.id == id } }
            scrollOn = prefs.scrollEnabled && rule?.scrollOff != true
            buttonsOn = prefs.buttonsEnabled && rule?.buttonsOff != true
            bindings = Dictionary(
                prefs.bindings.filter { $0.action != .none }.map { (Int64($0.button), $0) },
                uniquingKeysWith: { first, _ in first })
        }
    }

    struct Shared {
        var config = Config()
        var capturing = false
        var zoomGestureTaken = false  // Accessibility zoom uses Ctrl + wheel
    }

    let shared = OSAllocatedUnfairLock(initialState: Shared())
    /// Called on the main queue with the button number pressed while capturing.
    var onCapture: (@MainActor (Int) -> Void)?
    /// Called on the main queue when the tap starts or stops.
    var onActiveChange: (@MainActor (Bool) -> Void)?

    // Engine-thread state.
    private var thread: Thread?
    private var runLoop: CFRunLoop?
    private var tap: CFMachPort?
    private var tapSource: CFRunLoopSource?
    private var mask: CGEventMask = 0
    private var frameTimer: CFRunLoopTimer?
    private var frameInterval: CFTimeInterval = 1.0 / 120
    private var lastFrame: CFTimeInterval = 0
    private var remaining = (x: 0.0, y: 0.0)
    private var carry = (x: 0.0, y: 0.0)
    private var postFlags: CGEventFlags = []
    private var lastTick: CFTimeInterval = 0
    private var lastSign = 0
    private var streak = 0
    private var heldButtons: [Int64: MouseAction] = [:]

    // MARK: Lifecycle (main thread)

    /// Starts, restarts or stops the tap so it listens to exactly `newMask` (0 stops it).
    func setMask(_ newMask: CGEventMask, refreshRate: Int) {
        let interval = 1.0 / Double(max(60, min(refreshRate, 240)))
        if newMask == 0 {
            stop()
            return
        }
        if runLoop != nil, newMask == mask { return }
        stop()
        mask = newMask
        frameInterval = interval
        let ready = DispatchSemaphore(value: 0)
        let thread = Thread { [weak self] in
            self?.runThread(ready: ready)
        }
        thread.name = "MenuTools.Mouse"
        thread.qualityOfService = .userInteractive
        self.thread = thread
        thread.start()
        ready.wait()
    }

    func stop() {
        guard let runLoop else {
            thread = nil
            mask = 0
            return
        }
        let done = DispatchSemaphore(value: 0)
        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.commonModes.rawValue) { [self] in
            stopFrames()
            if let tap {
                CGEvent.tapEnable(tap: tap, enable: false)
                CFMachPortInvalidate(tap)
            }
            if let tapSource { CFRunLoopRemoveSource(runLoop, tapSource, .commonModes) }
            tap = nil
            tapSource = nil
            // A synthetic middle press must not outlive the tap (the app would see it held).
            for action in heldButtons.values where action == .middleClick {
                MouseActionRunner.releaseMiddle()
            }
            heldButtons.removeAll()
            CFRunLoopStop(runLoop)
            done.signal()
        }
        CFRunLoopWakeUp(runLoop)
        done.wait()
        self.runLoop = nil
        thread = nil
        mask = 0
        notifyActive(false)
    }

    private func runThread(ready: DispatchSemaphore) {
        let observer = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        runLoop = CFRunLoopGetCurrent()
        tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, userInfo in
                guard let userInfo else { return Unmanaged.passUnretained(event) }
                let engine = Unmanaged<MouseEventEngine>.fromOpaque(userInfo).takeUnretainedValue()
                return engine.handle(type: type, event: event)
            },
            userInfo: observer)
        if let tap {
            let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
            tapSource = source
            CFRunLoopAddSource(runLoop, source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
        }
        notifyActive(tap != nil)
        guard tap != nil else {
            // No Accessibility: nothing to run; `stop()` must not wait on this loop.
            runLoop = nil
            ready.signal()
            return
        }
        ready.signal()
        // A keep-alive source so the run loop does not return while the tap is momentarily disabled.
        let keepAlive = CFRunLoopTimerCreateWithHandler(nil, .greatestFiniteMagnitude, 0, 0, 0) { _ in }
        CFRunLoopAddTimer(runLoop, keepAlive, .commonModes)
        CFRunLoopRun()
        CFRunLoopTimerInvalidate(keepAlive)
    }

    private func notifyActive(_ active: Bool) {
        guard let onActiveChange else { return }
        DispatchQueue.main.async { MainActor.assumeIsolated { onActiveChange(active) } }
    }

    // MARK: Event handling (engine thread)

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        if event.getIntegerValueField(.eventSourceUserData) == Self.marker {
            return Unmanaged.passUnretained(event)
        }
        // Ups and drags (up to 1 kHz on gaming mice) only matter for a button we consumed.
        if type == .otherMouseUp || type == .otherMouseDragged {
            let button = event.getIntegerValueField(.mouseEventButtonNumber)
            guard let action = heldButtons[button] else { return Unmanaged.passUnretained(event) }
            if type == .otherMouseUp {
                heldButtons[button] = nil
                if action == .middleClick { MouseActionRunner.middleUp(event: event) }
            } else if action == .middleClick {
                MouseActionRunner.middleDrag(event: event)
            }
            return nil
        }
        let state = shared.withLock { $0 }
        let config = state.config

        switch type {
        case .scrollWheel:
            guard config.scrollOn else { break }
            return handleScroll(event, prefs: config.prefs, zoomTaken: state.zoomGestureTaken)
        case .otherMouseDown:
            let button = event.getIntegerValueField(.mouseEventButtonNumber)
            if state.capturing {
                shared.withLock { $0.capturing = false }
                heldButtons[button] = MouseAction.none
                if let onCapture {
                    DispatchQueue.main.async { MainActor.assumeIsolated { onCapture(Int(button)) } }
                }
                return nil
            }
            guard config.buttonsOn, let binding = config.bindings[button] else { break }
            heldButtons[button] = binding.action
            MouseActionRunner.press(binding, event: event)
            return nil
        default:
            break
        }
        return Unmanaged.passUnretained(event)
    }

    private func handleScroll(_ event: CGEvent, prefs: MousePrefs, zoomTaken: Bool) -> Unmanaged<CGEvent>? {
        // Trackpads, Magic Mouse and other precise devices (and their momentum) pass through.
        guard event.getIntegerValueField(.scrollWheelEventIsContinuous) == 0,
            event.getIntegerValueField(.scrollWheelEventScrollPhase) == 0,
            event.getIntegerValueField(.scrollWheelEventMomentumPhase) == 0
        else { return Unmanaged.passUnretained(event) }

        // Direction only: macOS already applied its own wheel acceleration to the line count.
        var vertical = Double(sign(event, .scrollWheelEventDeltaAxis1, .scrollWheelEventFixedPtDeltaAxis1))
        var horizontal = Double(sign(event, .scrollWheelEventDeltaAxis2, .scrollWheelEventFixedPtDeltaAxis2))
        guard vertical != 0 || horizontal != 0 else { return Unmanaged.passUnretained(event) }

        var flags = event.flags
        if prefs.reverseVertical { vertical = -vertical }
        if prefs.reverseHorizontal { horizontal = -horizontal }

        // Ctrl + wheel: zoom with ⌘= / ⌘- (left alone when macOS screen zoom owns that gesture).
        if prefs.controlZoom, flags.contains(.maskControl), !flags.contains(.maskCommand), !zoomTaken,
            vertical != 0
        {
            MouseActionRunner.zoom(in: vertical > 0)
            return nil
        }

        var gain = 1.0
        if prefs.shiftHorizontal, flags.contains(.maskShift) {
            // macOS may already have turned the tick sideways; either way the posted scroll is
            // horizontal and must not carry ⇧ (an app would swap the axis again).
            if horizontal == 0 {
                horizontal = vertical
                vertical = 0
            }
            flags.remove(.maskShift)
        }
        if prefs.commandFast, flags.contains(.maskCommand) {
            gain = prefs.fastGain
            flags.remove(.maskCommand)
        }

        // Our own acceleration: quick ticks in one direction build a streak.
        let now = CACurrentMediaTime()
        let tickSign = vertical != 0 ? (vertical > 0 ? 1 : -1) : (horizontal > 0 ? 2 : -2)
        if tickSign == lastSign, now - lastTick < 0.12 {
            streak = min(streak + 1, 14)
        } else {
            streak = 0
        }
        lastSign = tickSign
        lastTick = now
        let accel = 1 + prefs.scrollAcceleration * Double(streak) * 0.45

        let step = 48.0 * accel * gain
        let dy = vertical * step * prefs.scrollSpeed
        let dx = horizontal * step * prefs.horizontalSpeed

        guard prefs.smoothScroll else {
            postScroll(dy: Int32(dy.rounded()), dx: Int32(dx.rounded()), flags: flags)
            return nil
        }
        // A turn-around drops what was still queued the other way.
        if dy != 0, remaining.y * dy < 0 {
            remaining.y = 0
            carry.y = 0
        }
        if dx != 0, remaining.x * dx < 0 {
            remaining.x = 0
            carry.x = 0
        }
        remaining.y += dy
        remaining.x += dx
        postFlags = flags
        startFrames(duration: prefs.scrollDuration)
        return nil
    }

    private func sign(_ event: CGEvent, _ lines: CGEventField, _ fixed: CGEventField) -> Int {
        let value = event.getIntegerValueField(lines)
        if value != 0 { return value > 0 ? 1 : -1 }
        let precise = event.getDoubleValueField(fixed)
        return precise > 0 ? 1 : (precise < 0 ? -1 : 0)
    }

    // MARK: Smooth scroll frames (engine thread)

    private var duration = 0.3

    private func startFrames(duration: Double) {
        self.duration = max(0.08, duration)
        guard frameTimer == nil, let runLoop else { return }
        lastFrame = CACurrentMediaTime()
        // First frame now, so the response to a tick is immediate.
        frame()
        guard remaining.x != 0 || remaining.y != 0 else { return }
        let timer = CFRunLoopTimerCreateWithHandler(
            nil, CFAbsoluteTimeGetCurrent() + frameInterval, frameInterval, 0, 0
        ) { [weak self] _ in self?.frame() }
        frameTimer = timer
        CFRunLoopAddTimer(runLoop, timer, .commonModes)
    }

    private func stopFrames() {
        if let frameTimer { CFRunLoopTimerInvalidate(frameTimer) }
        frameTimer = nil
        remaining = (0, 0)
        carry = (0, 0)
    }

    private func frame() {
        let now = CACurrentMediaTime()
        let dt = min(max(now - lastFrame, frameInterval * 0.5), 0.05)
        lastFrame = now
        // Ease out: about 98% of the distance is covered in `duration`.
        let k = 1 - exp(-dt / (duration / 4))
        let stepY = abs(remaining.y) < 1 ? remaining.y : remaining.y * k
        let stepX = abs(remaining.x) < 1 ? remaining.x : remaining.x * k
        remaining.y -= stepY
        remaining.x -= stepX
        carry.y += stepY
        carry.x += stepX
        let iy = Int32(carry.y.rounded(.towardZero))
        let ix = Int32(carry.x.rounded(.towardZero))
        carry.y -= Double(iy)
        carry.x -= Double(ix)
        if iy != 0 || ix != 0 { postScroll(dy: iy, dx: ix, flags: postFlags) }
        if remaining.y == 0, remaining.x == 0 {
            if let frameTimer { CFRunLoopTimerInvalidate(frameTimer) }
            frameTimer = nil
            carry = (0, 0)
        }
    }

    private func postScroll(dy: Int32, dx: Int32, flags: CGEventFlags) {
        guard dy != 0 || dx != 0,
            let event = CGEvent(
                scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: dy, wheel2: dx, wheel3: 0)
        else { return }
        event.flags = flags
        event.setIntegerValueField(.eventSourceUserData, value: Self.marker)
        event.post(tap: .cgSessionEventTap)
    }
}
