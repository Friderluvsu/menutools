import AppKit
@preconcurrency import ApplicationServices
import Combine
import CoreGraphics
import Foundation

public final class WindowManagerRuntime: @unchecked Sendable {
    private let lock = NSLock()
    private var _maximizeEnabled: Bool = true
    private var _quitEnabled: Bool = true
    private var _quitMode: QuitOnCloseMode = .lastWindow
    private var _exceptionBundleIds: Set<String> = []
    private var _isZoomClickInProgress: Bool = false
    private var _animateEnabled: Bool = true

    public init(
        maximizeEnabled: Bool = true,
        quitEnabled: Bool = true,
        quitMode: QuitOnCloseMode = .lastWindow,
        exceptionBundleIds: Set<String> = [],
        animateEnabled: Bool = true
    ) {
        self._maximizeEnabled = maximizeEnabled
        self._quitEnabled = quitEnabled
        self._quitMode = quitMode
        self._exceptionBundleIds = exceptionBundleIds
        self._animateEnabled = animateEnabled
    }

    public var maximizeEnabled: Bool {
        lock.withLock { _maximizeEnabled }
    }

    public var quitEnabled: Bool {
        lock.withLock { _quitEnabled }
    }

    public var quitMode: QuitOnCloseMode {
        lock.withLock { _quitMode }
    }

    public var exceptionBundleIds: Set<String> {
        lock.withLock { _exceptionBundleIds }
    }

    public var animateEnabled: Bool {
        lock.withLock { _animateEnabled }
    }

    public var isZoomClickInProgress: Bool {
        get { lock.withLock { _isZoomClickInProgress } }
        set { lock.withLock { _isZoomClickInProgress = newValue } }
    }

    private var _previousFrames: [String: CGRect] = [:]

    public func previousFrame(for key: String) -> CGRect? {
        lock.withLock { _previousFrames[key] }
    }

    public func setPreviousFrame(_ frame: CGRect, for key: String) {
        lock.withLock {
            if _previousFrames.count > 100 {
                _previousFrames.removeAll()
            }
            _previousFrames[key] = frame
        }
    }

    public func removePreviousFrame(for key: String) {
        _ = lock.withLock { _previousFrames.removeValue(forKey: key) }
    }

    public func update(
        maximizeEnabled: Bool? = nil,
        quitEnabled: Bool? = nil,
        quitMode: QuitOnCloseMode? = nil,
        exceptionBundleIds: Set<String>? = nil,
        animateEnabled: Bool? = nil
    ) {
        lock.withLock {
            if let maximizeEnabled { self._maximizeEnabled = maximizeEnabled }
            if let quitEnabled { self._quitEnabled = quitEnabled }
            if let quitMode { self._quitMode = quitMode }
            if let exceptionBundleIds { self._exceptionBundleIds = exceptionBundleIds }
            if let animateEnabled { self._animateEnabled = animateEnabled }
        }
    }

    public func isException(bundleId: String) -> Bool {
        lock.withLock { _exceptionBundleIds.contains(bundleId) }
    }
}

@MainActor
public final class WindowManager: ObservableObject {
    public static let defaultExceptions: [WindowExceptionApp] = [
        WindowExceptionApp(id: "com.apple.finder", name: "Finder"),
        WindowExceptionApp(id: "com.apple.desktopservices", name: "Desktop Services"),
    ]

    private enum UserDefaultsKeys {
        static let maximizeOnGreen = "WindowManager_MaximizeOnGreen"
        static let quitOnClose = "WindowManager_QuitOnClose"
        static let quitMode = "WindowManager_QuitOnCloseMode"
        static let exceptions = "WindowManager_Exceptions"
        static let animateResize = "WindowManager_AnimateResize"
    }

    @Published public var isMaximizeOnGreenEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isMaximizeOnGreenEnabled, forKey: UserDefaultsKeys.maximizeOnGreen)
            runtime.update(maximizeEnabled: isMaximizeOnGreenEnabled)
            updateMonitoring()
        }
    }

    @Published public var isAnimateResizeEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isAnimateResizeEnabled, forKey: UserDefaultsKeys.animateResize)
            runtime.update(animateEnabled: isAnimateResizeEnabled)
        }
    }

    @Published public var isQuitOnCloseEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isQuitOnCloseEnabled, forKey: UserDefaultsKeys.quitOnClose)
            runtime.update(quitEnabled: isQuitOnCloseEnabled)
            updateMonitoring()
        }
    }

    @Published public var quitOnCloseMode: QuitOnCloseMode {
        didSet {
            UserDefaults.standard.set(quitOnCloseMode.rawValue, forKey: UserDefaultsKeys.quitMode)
            runtime.update(quitMode: quitOnCloseMode)
        }
    }

    @Published public var exceptions: [WindowExceptionApp] {
        didSet {
            saveExceptions()
            runtime.update(exceptionBundleIds: Set(exceptions.map(\.id)))
        }
    }

    @Published public private(set) var isEventTapActive: Bool = false
    @Published public private(set) var isAccessibilityGranted: Bool = false

    private var animationTimers: [String: DispatchSourceTimer] = [:]

    private let runtime: WindowManagerRuntime
    private var eventTap: CFMachPort?
    private var eventTapMask: CGEventMask = 0
    private var runLoopSource: CFRunLoopSource?
    private var appActiveObserver: NSObjectProtocol?

    /// Reused for every hit test; the short messaging timeout keeps a hung app from stalling the tap
    /// (macOS disables a tap whose callback takes too long).
    nonisolated private static let systemWideElement: AXUIElement = {
        let element = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(element, 0.5)
        return element
    }()

    /// All Accessibility IPC beyond the hit test runs here, never inside the event tap callback.
    nonisolated private static let axQueue = DispatchQueue(label: "MenuTools.WindowAX", qos: .userInteractive)

    public init() {
        let maxEnabled = UserDefaults.standard.object(forKey: UserDefaultsKeys.maximizeOnGreen) as? Bool ?? true
        let quitEnabled = UserDefaults.standard.object(forKey: UserDefaultsKeys.quitOnClose) as? Bool ?? true
        let animEnabled = UserDefaults.standard.object(forKey: UserDefaultsKeys.animateResize) as? Bool ?? true

        let mode: QuitOnCloseMode
        if let modeRaw = UserDefaults.standard.string(forKey: UserDefaultsKeys.quitMode),
            let parsedMode = QuitOnCloseMode(rawValue: modeRaw)
        {
            mode = parsedMode
        } else {
            mode = .lastWindow
        }

        let loadedExceptions = Self.loadSavedExceptions()

        self.isMaximizeOnGreenEnabled = maxEnabled
        self.isAnimateResizeEnabled = animEnabled
        self.isQuitOnCloseEnabled = quitEnabled
        self.quitOnCloseMode = mode
        self.exceptions = loadedExceptions

        self.runtime = WindowManagerRuntime(
            maximizeEnabled: maxEnabled,
            quitEnabled: quitEnabled,
            quitMode: mode,
            exceptionBundleIds: Set(loadedExceptions.map(\.id)),
            animateEnabled: animEnabled
        )

        self.isAccessibilityGranted = AXIsProcessTrusted()

        installAppActiveObserver()
        updateMonitoring()
    }

    deinit {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
    }

    public func refreshPermissions() {
        let granted = AXIsProcessTrusted()
        if isAccessibilityGranted != granted { isAccessibilityGranted = granted }
        updateMonitoring()
    }

    public func requestPermissions() {
        let promptKey = "AXTrustedCheckOptionPrompt" as CFString
        _ = AXIsProcessTrustedWithOptions([promptKey: true] as CFDictionary)

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.refreshPermissions()
        }
    }

    public func openAccessibilitySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
        else { return }
        NSWorkspace.shared.open(url)
    }

    public func addException(bundleId: String, name: String) {
        let trimmedId = bundleId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedId.isEmpty else { return }
        guard !exceptions.contains(where: { $0.id == trimmedId }) else { return }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let appName = trimmedName.isEmpty ? trimmedId : trimmedName
        exceptions.append(WindowExceptionApp(id: trimmedId, name: appName))
    }

    public func removeException(bundleId: String) {
        exceptions.removeAll(where: { $0.id == bundleId })
    }

    public func getRunningGUIApps() -> [(bundleId: String, name: String)] {
        let existingIds = Set(exceptions.map(\.id))
        let currentAppId = Bundle.main.bundleIdentifier ?? ""
        var seenIds = Set<String>()
        var result: [(bundleId: String, name: String)] = []

        for app in NSWorkspace.shared.runningApplications {
            guard app.activationPolicy == .regular else { continue }
            guard let bundleId = app.bundleIdentifier, !bundleId.isEmpty else { continue }
            guard bundleId != currentAppId else { continue }
            guard !existingIds.contains(bundleId) else { continue }
            guard !seenIds.contains(bundleId) else { continue }

            seenIds.insert(bundleId)
            let name = app.localizedName ?? bundleId
            result.append((bundleId: bundleId, name: name))
        }

        result.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        return result
    }

    /// Events the tap needs: mouseDown for either feature, mouseUp only to swallow a maximize click.
    private func desiredEventMask() -> CGEventMask? {
        guard isAccessibilityGranted else { return nil }
        var mask: CGEventMask = 0
        if isMaximizeOnGreenEnabled || isQuitOnCloseEnabled {
            mask |= 1 << CGEventType.leftMouseDown.rawValue
        }
        if isMaximizeOnGreenEnabled {
            mask |= 1 << CGEventType.leftMouseUp.rawValue
        }
        return mask == 0 ? nil : mask
    }

    /// Idempotent: called on every panel open and app activation, so an already-correct tap is left alone.
    public func updateMonitoring() {
        guard let mask = desiredEventMask() else {
            if eventTap != nil { stopEventTap() }
            if isEventTapActive { isEventTapActive = false }
            return
        }

        if let tap = eventTap, eventTapMask == mask {
            if !CGEvent.tapIsEnabled(tap: tap) { CGEvent.tapEnable(tap: tap, enable: true) }
            let active = CGEvent.tapIsEnabled(tap: tap)
            if isEventTapActive != active { isEventTapActive = active }
            return
        }

        stopEventTap()
        startEventTap(mask: mask)
    }

    private func startEventTap(mask eventMask: CGEventMask) {
        guard eventTap == nil else { return }

        let observer = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())

        guard
            let tap = CGEvent.tapCreate(
                tap: .cgSessionEventTap,
                place: .headInsertEventTap,
                options: .defaultTap,
                eventsOfInterest: eventMask,
                callback: { _, type, event, userInfo in
                    guard let userInfo else { return Unmanaged.passUnretained(event) }
                    let manager = Unmanaged<WindowManager>.fromOpaque(userInfo).takeUnretainedValue()
                    return manager.processEvent(type: type, event: event)
                },
                userInfo: observer
            )
        else {
            isEventTapActive = false
            return
        }

        eventTap = tap
        eventTapMask = eventMask
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        isEventTapActive = CGEvent.tapIsEnabled(tap: tap)
    }

    private func stopEventTap() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        eventTap = nil
        eventTapMask = 0
        runLoopSource = nil
        isEventTapActive = false
    }

    private func reenableEventTap() {
        guard let tap = eventTap else {
            updateMonitoring()
            return
        }
        CGEvent.tapEnable(tap: tap, enable: true)
        isEventTapActive = CGEvent.tapIsEnabled(tap: tap)
    }

    nonisolated private func processEvent(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            Task { @MainActor [weak self] in
                self?.reenableEventTap()
            }
            return Unmanaged.passUnretained(event)
        }

        // Fast path: a mouseUp matters only as the partner of a consumed zoom mouseDown.
        if type == .leftMouseUp {
            guard runtime.isZoomClickInProgress else { return Unmanaged.passUnretained(event) }
            runtime.isZoomClickInProgress = false
            return nil
        }

        guard type == .leftMouseDown else {
            return Unmanaged.passUnretained(event)
        }

        // A new press means any earlier mouseUp was lost; do not keep swallowing.
        if runtime.isZoomClickInProgress { runtime.isZoomClickInProgress = false }

        let maximizeEnabled = runtime.maximizeEnabled
        let quitEnabled = runtime.quitEnabled
        guard maximizeEnabled || quitEnabled else {
            return Unmanaged.passUnretained(event)
        }

        // Coordinates in screen space
        let point = event.location

        // Most clicks are nowhere near a window's top-left corner or hit our own panel; skip the
        // Accessibility IPC (which also wakes the clicked app) for those.
        guard Self.mayHitTrafficLights(event: event, point: point) else {
            return Unmanaged.passUnretained(event)
        }

        var elementRef: AXUIElement?
        let axError = AXUIElementCopyElementAtPosition(
            Self.systemWideElement, Float(point.x), Float(point.y), &elementRef)
        guard axError == .success, let element = elementRef else {
            return Unmanaged.passUnretained(event)
        }

        // Read kAXSubroleAttribute as CFString
        var subroleValue: AnyObject?
        let subroleError = AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subroleValue)
        guard subroleError == .success, let subrole = subroleValue as? String else {
            return Unmanaged.passUnretained(event)
        }

        let isZoomButton =
            (subrole == (kAXZoomButtonSubrole as String) || subrole == "AXZoomButton"
                || subrole == "AXFullScreenButton")
        let isCloseButton = (subrole == (kAXCloseButtonSubrole as String) || subrole == "AXCloseButton")

        guard isZoomButton || isCloseButton else {
            return Unmanaged.passUnretained(event)
        }

        // Read pid_t via AXUIElementGetPid
        var pid: pid_t = 0
        let pidError = AXUIElementGetPid(element, &pid)
        guard pidError == .success, pid > 0 else {
            return Unmanaged.passUnretained(event)
        }

        // Skip if it belongs to MenuTools
        if pid == ProcessInfo.processInfo.processIdentifier {
            return Unmanaged.passUnretained(event)
        }

        // Resolve NSRunningApplication(processIdentifier: pid) and bundle ID
        guard let app = NSRunningApplication(processIdentifier: pid) else {
            return Unmanaged.passUnretained(event)
        }

        let bundleId = app.bundleIdentifier ?? ""
        if bundleId.isEmpty || bundleId == Bundle.main.bundleIdentifier {
            return Unmanaged.passUnretained(event)
        }

        // Skip if target app's bundle ID is in exceptionBundleIds
        if runtime.isException(bundleId: bundleId) {
            return Unmanaged.passUnretained(event)
        }

        // Handle Zoom / FullScreen Button (True Maximize without Spaces)
        if isZoomButton && maximizeEnabled {
            runtime.isZoomClickInProgress = true
            // Consume the click right away; the Accessibility reads and the resize happen off the tap.
            Self.axQueue.async { [weak self] in
                guard let self, let windowElement = self.getWindowElement(from: element, pid: pid) else { return }
                self.prepareToggleMaximize(windowElement: windowElement, pid: pid)
            }
            return nil  // Consume click: prevents entering Spaces fullscreen
        }

        // Handle Close Button (Quit on close)
        if isCloseButton && quitEnabled {
            let quitMode = runtime.quitMode
            // Every window-count read happens on axQueue; the tap only did the hit test above.
            Self.axQueue.async { [weak self] in
                guard let self else { return }
                let before = quitMode == .always ? nil : self.getVisibleWindowCount(pid: pid)
                self.quitIfClosed(app: app, pid: pid, quitMode: quitMode, before: before, delay: 0.2, retry: true)
            }
        }

        return Unmanaged.passUnretained(event)
    }

    /// Cheap pre-check using the window the click landed on (one window-server lookup, no app IPC).
    /// Returns false only when it is certain the click is outside a normal window's title-bar corner
    /// or inside MenuTools itself; anything uncertain falls through to the Accessibility hit test.
    nonisolated private static func mayHitTrafficLights(event: CGEvent, point: CGPoint) -> Bool {
        let windowID = event.getIntegerValueField(.mouseEventWindowUnderMousePointer)
        guard windowID > 0 else { return true }

        var rawID: UnsafeRawPointer? = UnsafeRawPointer(bitPattern: UInt(windowID))
        guard let ids = CFArrayCreate(kCFAllocatorDefault, &rawID, 1, nil),
            let list = CGWindowListCreateDescriptionFromArray(ids) as? [[String: Any]],
            let info = list.first
        else { return true }

        if let ownerPID = info[kCGWindowOwnerPID as String] as? Int32,
            ownerPID == ProcessInfo.processInfo.processIdentifier
        {
            return false
        }

        // Only plain layer-0 windows have title-bar traffic lights; overlays and bars fall through.
        guard (info[kCGWindowLayer as String] as? Int) == 0,
            let boundsInfo = info[kCGWindowBounds as String] as? NSDictionary,
            let bounds = CGRect(dictionaryRepresentation: boundsInfo as CFDictionary)
        else { return true }

        let dx = point.x - bounds.minX
        let dy = point.y - bounds.minY
        guard dx >= 0, dy >= 0 else { return true }
        // Traffic lights sit within ~80pt of the left edge and ~40pt of the top, even with tall toolbars.
        return dx <= 160 && dy <= 90
    }

    nonisolated private func prepareToggleMaximize(windowElement: AXUIElement, pid: pid_t) {
        guard let currentFrame = getWindowFrame(windowElement: windowElement) else { return }

        let windowKey: String = {
            var titleVal: AnyObject?
            if AXUIElementCopyAttributeValue(windowElement, kAXTitleAttribute as CFString, &titleVal) == .success,
                let title = titleVal as? String, !title.isEmpty
            {
                return "\(pid)_\(title)"
            }
            return "\(pid)_\(CFHash(windowElement))"
        }()

        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                self?.toggleMaximize(
                    windowElement: windowElement, currentFrame: currentFrame, windowKey: windowKey)
            }
        }
    }

    /// Quits only once the app really has no windows left. A close that was cancelled (e.g. a "Save changes?"
    /// sheet) keeps the count unchanged, and a failed Accessibility read (nil) never counts as "no windows".
    nonisolated private func quitIfClosed(
        app: NSRunningApplication, pid: pid_t, quitMode: QuitOnCloseMode, before: Int?, delay: TimeInterval,
        retry: Bool
    ) {
        Self.axQueue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, !app.isTerminated else { return }
            if quitMode == .always {
                _ = app.terminate()
                return
            }
            guard let after = self.getVisibleWindowCount(pid: pid) else { return }
            if after == 0 {
                // AX lists only the current Space; a full-screen window lives in its own Space.
                guard !Self.hasFullScreenWindowElsewhere(pid: pid) else { return }
                _ = app.terminate()
            } else if retry, let before, after >= before {
                // Nothing closed yet (slow close animation): look once more before giving up.
                self.quitIfClosed(app: app, pid: pid, quitMode: quitMode, before: before, delay: 0.4, retry: false)
            }
        }
    }

    nonisolated private func getVisibleWindowCount(pid: pid_t) -> Int? {
        let appElement = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appElement, 0.5)
        var windowsValue: AnyObject?
        guard AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsValue) == .success,
            let windows = windowsValue as? [AXUIElement]
        else {
            return nil
        }

        var visibleCount = 0
        for window in windows {
            // Minimized windows are still open: closing the last visible one must not quit the app.
            var minimizedValue: AnyObject?
            if AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute as CFString, &minimizedValue) == .success,
                let isMinimized = minimizedValue as? Bool, isMinimized
            {
                visibleCount += 1
                continue
            }

            var sizeValue: AnyObject?
            if AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeValue) == .success,
                let value = sizeValue
            {
                var size = CGSize.zero
                if CFGetTypeID(value) == AXValueGetTypeID() {
                    let axVal = value as! AXValue
                    if AXValueGetType(axVal) == .cgSize && AXValueGetValue(axVal, .cgSize, &size) {
                        if size.width <= 10 || size.height <= 10 {
                            continue
                        }
                    }
                }
            }

            visibleCount += 1
        }
        return visibleCount
    }

    /// Off-screen, screen-sized layer-0 window of `pid`: a full-screen window in another Space.
    /// Plain off-screen windows are not counted: almost every app keeps hidden helper windows.
    nonisolated private static func hasFullScreenWindowElsewhere(pid: pid_t) -> Bool {
        var displayCount: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &displayCount) == .success, displayCount > 0 else { return false }
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(displayCount))
        guard CGGetActiveDisplayList(displayCount, &displays, &displayCount) == .success else { return false }
        let screens = displays.prefix(Int(displayCount)).map { CGDisplayBounds($0) }

        guard
            let list = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]]
        else { return false }
        for info in list {
            guard (info[kCGWindowOwnerPID as String] as? Int32) == pid,
                (info[kCGWindowLayer as String] as? Int) == 0,
                (info[kCGWindowIsOnscreen as String] as? Bool) != true,
                let boundsInfo = info[kCGWindowBounds as String] as? NSDictionary,
                let bounds = CGRect(dictionaryRepresentation: boundsInfo as CFDictionary)
            else { continue }
            if screens.contains(where: {
                abs($0.minX - bounds.minX) <= 1 && abs($0.minY - bounds.minY) <= 1
                    && abs($0.width - bounds.width) <= 1 && abs($0.height - bounds.height) <= 1
            }) {
                return true
            }
        }
        return false
    }

    nonisolated private func getWindowElement(from buttonElement: AXUIElement, pid: pid_t) -> AXUIElement? {
        var windowVal: AnyObject?
        if AXUIElementCopyAttributeValue(buttonElement, kAXWindowAttribute as CFString, &windowVal) == .success,
            let window = windowVal
        {
            return (window as! AXUIElement)
        }

        var topVal: AnyObject?
        if AXUIElementCopyAttributeValue(buttonElement, kAXTopLevelUIElementAttribute as CFString, &topVal) == .success,
            let top = topVal
        {
            return (top as! AXUIElement)
        }

        var current = buttonElement
        for _ in 0..<6 {
            var parentVal: AnyObject?
            guard AXUIElementCopyAttributeValue(current, kAXParentAttribute as CFString, &parentVal) == .success,
                let parent = parentVal
            else { break }
            let parentElem = parent as! AXUIElement
            var roleVal: AnyObject?
            if AXUIElementCopyAttributeValue(parentElem, kAXRoleAttribute as CFString, &roleVal) == .success,
                let role = roleVal as? String, role == (kAXWindowRole as String)
            {
                return parentElem
            }
            current = parentElem
        }

        let appElement = AXUIElementCreateApplication(pid)
        var focusedVal: AnyObject?
        if AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &focusedVal) == .success,
            let focused = focusedVal
        {
            return (focused as! AXUIElement)
        }

        return nil
    }

    nonisolated private func getWindowFrame(windowElement: AXUIElement) -> CGRect? {
        var posValue: AnyObject?
        var sizeValue: AnyObject?

        guard AXUIElementCopyAttributeValue(windowElement, kAXPositionAttribute as CFString, &posValue) == .success,
            AXUIElementCopyAttributeValue(windowElement, kAXSizeAttribute as CFString, &sizeValue) == .success,
            let posVal = posValue, let sizeVal = sizeValue
        else {
            return nil
        }

        var origin = CGPoint.zero
        var size = CGSize.zero

        guard CFGetTypeID(posVal) == AXValueGetTypeID(),
            AXValueGetValue(posVal as! AXValue, .cgPoint, &origin),
            CFGetTypeID(sizeVal) == AXValueGetTypeID(),
            AXValueGetValue(sizeVal as! AXValue, .cgSize, &size)
        else {
            return nil
        }

        return CGRect(origin: origin, size: size)
    }

    nonisolated private func setWindowFrame(windowElement: AXUIElement, to rect: CGRect) {
        var position = rect.origin
        var size = rect.size

        if let posVal = AXValueCreate(.cgPoint, &position) {
            AXUIElementSetAttributeValue(windowElement, kAXPositionAttribute as CFString, posVal)
        }
        if let sizeVal = AXValueCreate(.cgSize, &size) {
            AXUIElementSetAttributeValue(windowElement, kAXSizeAttribute as CFString, sizeVal)
        }
        if let posVal = AXValueCreate(.cgPoint, &position) {
            AXUIElementSetAttributeValue(windowElement, kAXPositionAttribute as CFString, posVal)
        }
    }

    @MainActor
    private func targetScreenRect(forFrame currentFrame: CGRect) -> CGRect {
        guard let primaryScreen = NSScreen.screens.first else {
            return NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        }
        let primaryHeight = primaryScreen.frame.height

        let windowCenter = CGPoint(x: currentFrame.midX, y: currentFrame.midY)

        var bestScreen: NSScreen = NSScreen.main ?? primaryScreen
        var maxIntersectionArea: CGFloat = -1

        for screen in NSScreen.screens {
            let screenTopEdge = screen.frame.origin.y + screen.frame.height
            let axScreenRect = CGRect(
                x: screen.frame.origin.x,
                y: primaryHeight - screenTopEdge,
                width: screen.frame.width,
                height: screen.frame.height
            )

            if axScreenRect.contains(windowCenter) {
                bestScreen = screen
                break
            }

            let intersection = currentFrame.intersection(axScreenRect)
            let area = intersection.isNull ? 0 : (intersection.width * intersection.height)
            if area > maxIntersectionArea {
                maxIntersectionArea = area
                bestScreen = screen
            }
        }

        let visibleTopEdge = bestScreen.visibleFrame.origin.y + bestScreen.visibleFrame.height
        return CGRect(
            x: bestScreen.visibleFrame.origin.x,
            y: primaryHeight - visibleTopEdge,
            width: bestScreen.visibleFrame.width,
            height: bestScreen.visibleFrame.height
        )
    }

    nonisolated private func isFrameMaximized(_ current: CGRect, target: CGRect) -> Bool {
        abs(current.origin.x - target.origin.x) <= 30
            && abs(current.origin.y - target.origin.y) <= 30
            && abs(current.size.width - target.size.width) <= 30
            && abs(current.size.height - target.size.height) <= 30
    }

    /// Accessibility writes are IPC calls into the target app; they run on a dedicated queue so the
    /// main thread never blocks and the timer keeps a steady 60 fps cadence.
    private static let animationQueue = DispatchQueue(label: "MenuTools.WindowAnimation", qos: .userInteractive)

    @MainActor
    private func animateWindowFrame(
        windowElement: AXUIElement,
        from: CGRect,
        to: CGRect,
        windowKey: String
    ) {
        if let existing = animationTimers[windowKey] {
            existing.cancel()
            animationTimers.removeValue(forKey: windowKey)
        }

        guard isAnimateResizeEnabled else {
            Self.animationQueue.async { [weak self] in
                self?.setWindowFrame(windowElement: windowElement, to: to)
            }
            return
        }

        let duration: Double = 0.22
        let frameInterval: Int = 16
        let startTime = DispatchTime.now().uptimeNanoseconds

        let timer = DispatchSource.makeTimerSource(queue: Self.animationQueue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(frameInterval), leeway: .milliseconds(1))

        timer.setEventHandler { [weak self] in
            // Progress is time-based: a slow AX call makes a frame late, never the whole animation longer.
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - startTime) / 1_000_000_000
            let progress = min(elapsed / duration, 1.0)
            let ease = 1.0 - pow(1.0 - progress, 3.0)

            let rect = CGRect(
                x: from.origin.x + (to.origin.x - from.origin.x) * ease,
                y: from.origin.y + (to.origin.y - from.origin.y) * ease,
                width: from.size.width + (to.size.width - from.size.width) * ease,
                height: from.size.height + (to.size.height - from.size.height) * ease
            )

            if progress >= 1.0 {
                timer.cancel()
                self?.setWindowFrame(windowElement: windowElement, to: to)
                DispatchQueue.main.async { [weak self] in
                    MainActor.assumeIsolated {
                        // A newer animation for the same window may already have replaced this timer.
                        if let current = self?.animationTimers[windowKey], current === timer {
                            self?.animationTimers.removeValue(forKey: windowKey)
                        }
                    }
                }
            } else {
                self?.setFrameFast(windowElement: windowElement, to: rect)
            }
        }

        animationTimers[windowKey] = timer
        timer.resume()
    }

    /// Two AX writes per frame (size, then position). The final exact frame is applied by `setWindowFrame`.
    nonisolated private func setFrameFast(windowElement: AXUIElement, to rect: CGRect) {
        var position = rect.origin
        var size = rect.size
        if let sizeVal = AXValueCreate(.cgSize, &size) {
            AXUIElementSetAttributeValue(windowElement, kAXSizeAttribute as CFString, sizeVal)
        }
        if let posVal = AXValueCreate(.cgPoint, &position) {
            AXUIElementSetAttributeValue(windowElement, kAXPositionAttribute as CFString, posVal)
        }
    }

    @MainActor
    private func toggleMaximize(windowElement: AXUIElement, currentFrame: CGRect, windowKey: String) {
        let targetRect = targetScreenRect(forFrame: currentFrame)

        let isMaximized = isFrameMaximized(currentFrame, target: targetRect)

        if isMaximized {
            if let saved = runtime.previousFrame(for: windowKey) {
                animateWindowFrame(windowElement: windowElement, from: currentFrame, to: saved, windowKey: windowKey)
                runtime.removePreviousFrame(for: windowKey)
            } else {
                let fallbackWidth = targetRect.width * 0.8
                let fallbackHeight = targetRect.height * 0.8
                let fallbackRect = CGRect(
                    x: targetRect.origin.x + (targetRect.width - fallbackWidth) / 2,
                    y: targetRect.origin.y + (targetRect.height - fallbackHeight) / 2,
                    width: fallbackWidth,
                    height: fallbackHeight
                )
                animateWindowFrame(
                    windowElement: windowElement, from: currentFrame, to: fallbackRect, windowKey: windowKey)
            }
        } else {
            runtime.setPreviousFrame(currentFrame, for: windowKey)
            animateWindowFrame(windowElement: windowElement, from: currentFrame, to: targetRect, windowKey: windowKey)
        }
    }

    private func installAppActiveObserver() {
        appActiveObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshPermissions() }
        }
    }

    private func saveExceptions() {
        if let data = try? JSONEncoder().encode(exceptions) {
            UserDefaults.standard.set(data, forKey: UserDefaultsKeys.exceptions)
        }
    }

    private static func loadSavedExceptions() -> [WindowExceptionApp] {
        if let data = UserDefaults.standard.data(forKey: UserDefaultsKeys.exceptions),
            let decoded = try? JSONDecoder().decode([WindowExceptionApp].self, from: data)
        {
            return decoded
        }
        return defaultExceptions
    }
}
