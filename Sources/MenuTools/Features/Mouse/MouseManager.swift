import AppKit
import Combine

/// Settings → Mouse: smooth wheel scrolling, scroll modifiers, button actions and pointer speed for
/// external mice, with per-app exceptions. Needs Accessibility (the event tap) for scroll and buttons;
/// pointer speed needs no permission.
@MainActor
final class MouseManager: ObservableObject {
    private static let defaultsKey = "MouseSettings"

    @Published var prefs: MousePrefs {
        didSet {
            guard prefs != oldValue else { return }
            save()
            apply(previous: oldValue)
        }
    }
    @Published private(set) var isTapActive = false
    @Published private(set) var isAccessibilityGranted = AXIsProcessTrusted()
    @Published private(set) var isCapturing = false
    @Published private(set) var mouseCount = 0

    private let previewMode: Bool
    private let engine = MouseEventEngine()
    private let pointer: PointerController?
    private var frontmost: String?
    private var pointerApplied = false
    private var saveWork: DispatchWorkItem?
    private var pointerWork: DispatchWorkItem?
    private var captureTimeout: DispatchWorkItem?
    private var keepButtonsUntil: Date?
    /// macOS screen zoom owns ⌃ + wheel; read at launch and when permissions are refreshed.
    private var zoomTaken = MouseManager.screenZoomUsesScroll()
    private var observers: [NSObjectProtocol] = []

    init(previewMode: Bool = false) {
        self.previewMode = previewMode
        prefs = MousePrefs.load(from: UserDefaults.standard.data(forKey: Self.defaultsKey))
        pointer = previewMode ? nil : PointerController()
        guard !previewMode else { return }

        engine.onActiveChange = { [weak self] active in
            guard let self, self.isTapActive != active else { return }
            self.isTapActive = active
        }
        engine.onCapture = { [weak self] button in self?.finishCapture(button) }
        pointer?.onDeviceAdded = { [weak self] in self?.applyPointer(force: true) }

        frontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let center = NSWorkspace.shared.notificationCenter
        observers.append(
            center.addObserver(
                forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
            ) { [weak self] note in
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                MainActor.assumeIsolated { self?.frontmostChanged(app?.bundleIdentifier) }
            })
        // Sleep can reset the mouse's HID settings; put ours back after wake.
        observers.append(
            center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    MainActor.assumeIsolated { self?.applyPointer(force: false) }
                }
            })
        mouseCount = pointer?.countMice() ?? 0
        if !prefs.cursorEnabled { pointer?.restoreLeftovers() }
        apply(previous: nil)
    }

    // MARK: Public

    func refreshPermissions() {
        let taken = Self.screenZoomUsesScroll()
        if taken != zoomTaken {
            zoomTaken = taken
            engine.shared.withLock { $0.zoomGestureTaken = taken }
        }
        let granted = AXIsProcessTrusted()
        if granted != isAccessibilityGranted { isAccessibilityGranted = granted }
        updateTap()
        let count = pointer?.countMice() ?? 0
        if count != mouseCount { mouseCount = count }
    }

    func requestAccessibility() {
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.refreshPermissions() }
    }

    /// The next extra mouse button pressed is added to the list (or selected if already there).
    func startCapture() {
        guard !isCapturing else { return }
        isCapturing = true
        engine.shared.withLock { $0.capturing = true }
        updateTap()
        // A forgotten capture must not eat a Back press hours later.
        let timeout = DispatchWorkItem { [weak self] in self?.cancelCapture() }
        captureTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 15, execute: timeout)
    }

    func cancelCapture() {
        captureTimeout?.cancel()
        captureTimeout = nil
        guard isCapturing else { return }
        isCapturing = false
        engine.shared.withLock { $0.capturing = false }
        updateTap()
    }

    func setAction(_ action: MouseAction, for button: Int) {
        guard let index = prefs.bindings.firstIndex(where: { $0.button == button }) else { return }
        prefs.bindings[index].action = action
    }

    func setShortcut(_ combo: KeyCombo, for button: Int) {
        guard let index = prefs.bindings.firstIndex(where: { $0.button == button }) else { return }
        prefs.bindings[index].action = .shortcut
        prefs.bindings[index].shortcut = combo
    }

    func removeBinding(_ button: Int) {
        prefs.bindings.removeAll { $0.button == button }
    }

    func addRule(bundleId: String, name: String) {
        guard !prefs.appRules.contains(where: { $0.id == bundleId }) else { return }
        prefs.appRules.append(MouseAppRule(id: bundleId, name: name))
    }

    func removeRule(_ bundleId: String) {
        prefs.appRules.removeAll { $0.id == bundleId }
    }

    /// Called on quit: pointer values go back to the device defaults.
    func prepareForTermination() {
        if saveWork != nil { saveNow() }
        engine.stop()
        pointer?.restore()
    }

    // MARK: Apply

    /// Coalesced: a slider drag changes prefs dozens of times a second.
    private func save() {
        guard !previewMode else { return }
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.saveNow() }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    private func saveNow() {
        saveWork = nil
        guard let data = try? JSONEncoder().encode(prefs) else { return }
        UserDefaults.standard.set(data, forKey: Self.defaultsKey)
    }

    private func apply(previous: MousePrefs?) {
        guard !previewMode else { return }
        let prefs = prefs
        let frontmost = frontmost
        let zoomTaken = zoomTaken
        let config = MouseEventEngine.Config(prefs: prefs, frontmost: frontmost)
        engine.shared.withLock {
            $0.config = config
            $0.zoomGestureTaken = zoomTaken
        }
        updateTap()
        let pointerChanged =
            previous.map {
                $0.cursorEnabled != prefs.cursorEnabled || $0.cursorSpeed != prefs.cursorSpeed
                    || $0.cursorAcceleration != prefs.cursorAcceleration || $0.cursorLinear != prefs.cursorLinear
                    || $0.appRules != prefs.appRules
            } ?? true
        guard pointerChanged else { return }
        // Slider drags arrive many times a second; each apply walks every HID service.
        pointerWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.applyPointer(force: true) }
        pointerWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (previous == nil ? 0 : 0.12), execute: work)
    }

    private func updateTap() {
        var mask: CGEventMask = 0
        if prefs.scrollEnabled { mask |= 1 << CGEventType.scrollWheel.rawValue }
        if prefs.buttonsEnabled || isCapturing || keepButtonsUntil.map({ $0 > Date() }) == true {
            mask |= 1 << CGEventType.otherMouseDown.rawValue
            mask |= 1 << CGEventType.otherMouseUp.rawValue
            mask |= 1 << CGEventType.otherMouseDragged.rawValue
        }
        if !isAccessibilityGranted { mask = 0 }
        engine.setMask(mask, refreshRate: NSScreen.main?.maximumFramesPerSecond ?? 120)
        if mask == 0, isTapActive { isTapActive = false }
    }

    private func frontmostChanged(_ bundleId: String?) {
        guard bundleId != frontmost else { return }
        let oldRule = rule(for: frontmost)
        frontmost = bundleId
        let config = MouseEventEngine.Config(prefs: prefs, frontmost: bundleId)
        engine.shared.withLock { $0.config = config }
        if oldRule?.cursorOff == true || rule(for: bundleId)?.cursorOff == true {
            applyPointer(force: false)
        }
    }

    private func rule(for bundleId: String?) -> MouseAppRule? {
        bundleId.flatMap { id in prefs.appRules.first { $0.id == id } }
    }

    private func applyPointer(force: Bool) {
        guard let pointer else { return }
        let wanted = prefs.cursorEnabled && rule(for: frontmost)?.cursorOff != true
        if wanted {
            pointer.apply(
                speed: prefs.cursorSpeed, acceleration: prefs.cursorLinear ? nil : prefs.cursorAcceleration)
            pointerApplied = true
        } else if pointerApplied || force {
            pointer.restore()
            pointerApplied = false
        }
        if pointer.mouseCount != mouseCount { mouseCount = pointer.mouseCount }
    }

    private func finishCapture(_ button: Int) {
        captureTimeout?.cancel()
        captureTimeout = nil
        isCapturing = false
        // Keep listening to buttons briefly, so the captured button's release is swallowed too instead
        // of reaching the app without its press (the tap would restart if Buttons is off).
        keepButtonsUntil = Date().addingTimeInterval(3)
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.1) { [weak self] in self?.updateTap() }
        // Left and right are never taken over.
        guard button >= 2, !prefs.bindings.contains(where: { $0.button == button }) else { return }
        prefs.bindings.append(MouseButtonBinding(button: button, action: .none))
        prefs.bindings.sort { $0.button < $1.button }
    }

    /// macOS screen zoom ("Use scroll gesture with modifier keys to zoom") owns Ctrl + wheel.
    private static func screenZoomUsesScroll() -> Bool {
        let value = CFPreferencesCopyAppValue(
            "closeViewScrollWheelToggle" as CFString, "com.apple.universalaccess" as CFString)
        return (value as? Bool) ?? false
    }
}
