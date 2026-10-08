import AppKit
import ApplicationServices
import Combine
import CoreGraphics

private final class IMessageShortcutRuntime: @unchecked Sendable {
    private let lock = NSLock()
    private var enabled = false
    private var messagesIsFrontmost = false

    func update(enabled: Bool? = nil, messagesIsFrontmost: Bool? = nil) {
        lock.withLock {
            if let enabled { self.enabled = enabled }
            if let messagesIsFrontmost { self.messagesIsFrontmost = messagesIsFrontmost }
        }
    }

    var shouldHandleShortcuts: Bool {
        lock.withLock { enabled && messagesIsFrontmost }
    }
}

@MainActor
final class IMessageHelper: ObservableObject {
    @Published var isEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: "iMessageShortcutsEnabled")
            runtime.update(enabled: isEnabled)
            updateMonitoring()
        }
    }

    @Published private(set) var isMessagesActive = false
    @Published private(set) var isAccessibilityGranted = false
    @Published private(set) var isInputMonitoringGranted = false
    @Published private(set) var isKeystrokePostingGranted = false
    @Published private(set) var isEventTapActive = false
    @Published private(set) var lastShortcut: String?
    @Published private(set) var errorMessage: String?

    private let runtime = IMessageShortcutRuntime()
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var workspaceObservers: [NSObjectProtocol] = []

    private static let messagesBundleIdentifiers: Set<String> = [
        "com.apple.MobileSMS",
        "com.apple.iChat",
    ]

    init() {
        isEnabled = UserDefaults.standard.object(forKey: "iMessageShortcutsEnabled") as? Bool ?? true
        runtime.update(enabled: isEnabled)
        updateFrontmostApplication(NSWorkspace.shared.frontmostApplication)
        installWorkspaceObservers()
        refreshPermissions(restartMonitoring: false)
        updateMonitoring()
    }

    var permissionSummary: String {
        if isEventTapActive && isKeystrokePostingGranted {
            return "Ready"
        }
        if !isAccessibilityGranted {
            return "Accessibility required"
        }
        if !isInputMonitoringGranted {
            return "Input Monitoring required"
        }
        if !isKeystrokePostingGranted {
            return "Keyboard control required"
        }
        return errorMessage ?? "Restart MenuTools"
    }

    func refreshPermissions(restartMonitoring: Bool = true) {
        isAccessibilityGranted = AXIsProcessTrusted()
        isInputMonitoringGranted = CGPreflightListenEventAccess()
        isKeystrokePostingGranted = CGPreflightPostEventAccess()

        if restartMonitoring {
            updateMonitoring()
        }
    }

    func requestPermissions() {
        let promptKey = "AXTrustedCheckOptionPrompt" as CFString
        _ = AXIsProcessTrustedWithOptions([promptKey: true] as CFDictionary)
        _ = CGRequestListenEventAccess()
        _ = CGRequestPostEventAccess()

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.refreshPermissions()
        }
    }

    func openAccessibilitySettings() {
        openPrivacyPane("Privacy_Accessibility")
    }

    func openInputMonitoringSettings() {
        openPrivacyPane("Privacy_ListenEvent")
    }

    /// The keyboard tap sees every keystroke system-wide, so it only exists while Messages is frontmost.
    /// `isEventTapActive` stays true while the listener is armed (enabled + permissions) so Settings
    /// keeps showing "Running" even though the tap itself is installed on demand.
    func updateMonitoring() {
        guard isEnabled else {
            stopEventTap()
            setTapActive(false)
            errorMessage = nil
            return
        }

        guard isMessagesActive else {
            stopEventTap()
            setTapActive(isAccessibilityGranted && isInputMonitoringGranted)
            return
        }

        if let tap = eventTap, CGEvent.tapIsEnabled(tap: tap) {
            setTapActive(true)
            return
        }
        stopEventTap()
        errorMessage = nil
        startEventTap()
    }

    private func setTapActive(_ active: Bool) {
        if isEventTapActive != active { isEventTapActive = active }
    }

    func triggerNext() {
        Self.postTabShortcut(flags: [.maskControl])
        recordShortcut("↓  →  ⌃Tab")
    }

    func triggerPrevious() {
        Self.postTabShortcut(flags: [.maskControl, .maskShift])
        recordShortcut("↑  →  ⌃⇧Tab")
    }

    func testNextInMessages() {
        activateMessagesAndPost(flags: [.maskControl], description: "Test  ↓  →  ⌃Tab")
    }

    func testPreviousInMessages() {
        activateMessagesAndPost(flags: [.maskControl, .maskShift], description: "Test  ↑  →  ⌃⇧Tab")
    }

    private func installWorkspaceObservers() {
        let center = NSWorkspace.shared.notificationCenter

        workspaceObservers.append(
            center.addObserver(
                forName: NSWorkspace.didActivateApplicationNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                MainActor.assumeIsolated { self?.updateFrontmostApplication(app) }
            })

        workspaceObservers.append(
            center.addObserver(
                forName: NSWorkspace.didTerminateApplicationNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.updateFrontmostApplication(NSWorkspace.shared.frontmostApplication)
                }
            })
    }

    private func updateFrontmostApplication(_ application: NSRunningApplication?) {
        let bundleIdentifier = application?.bundleIdentifier ?? ""
        let active = Self.messagesBundleIdentifiers.contains(bundleIdentifier)
        runtime.update(messagesIsFrontmost: active)
        guard isMessagesActive != active else { return }
        isMessagesActive = active
        updateMonitoring()
    }

    private func startEventTap() {
        let eventMask = CGEventMask(1) << CGEventType.keyDown.rawValue
        let observer = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())

        guard
            let tap = CGEvent.tapCreate(
                tap: .cgSessionEventTap,
                place: .headInsertEventTap,
                options: .defaultTap,
                eventsOfInterest: eventMask,
                callback: { _, type, event, userInfo in
                    guard let userInfo else { return Unmanaged.passUnretained(event) }
                    let helper = Unmanaged<IMessageHelper>.fromOpaque(userInfo).takeUnretainedValue()
                    return helper.processEvent(type: type, event: event)
                },
                userInfo: observer
            )
        else {
            setTapActive(false)
            errorMessage = "macOS blocked the keyboard listener. Grant permissions and restart MenuTools."
            return
        }

        eventTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        setTapActive(CGEvent.tapIsEnabled(tap: tap))
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
        runLoopSource = nil
    }

    nonisolated private func processEvent(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            Task { @MainActor [weak self] in
                self?.reenableEventTap()
            }
            return Unmanaged.passUnretained(event)
        }

        guard type == .keyDown, runtime.shouldHandleShortcuts else {
            return Unmanaged.passUnretained(event)
        }

        let flags = event.flags.intersection([.maskCommand, .maskControl, .maskAlternate, .maskShift])
        let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))

        if keyCode == 126 && flags.isEmpty {
            Self.postTabShortcut(flags: [.maskControl, .maskShift])
            Task { @MainActor [weak self] in self?.recordShortcut("↑  →  ⌃⇧Tab") }
            return nil
        }

        if keyCode == 125 && flags.isEmpty {
            Self.postTabShortcut(flags: [.maskControl])
            Task { @MainActor [weak self] in self?.recordShortcut("↓  →  ⌃Tab") }
            return nil
        }

        if keyCode == 51 && flags == [.maskAlternate] {
            DispatchQueue.global(qos: .userInteractive).async {
                Self.pressDeleteConversationMenuItem()
            }
            Task { @MainActor [weak self] in self?.recordShortcut("⌥⌫  →  Delete Conversation") }
            return nil
        }

        return Unmanaged.passUnretained(event)
    }

    private func reenableEventTap() {
        guard let tap = eventTap else {
            updateMonitoring()
            return
        }
        CGEvent.tapEnable(tap: tap, enable: true)
        setTapActive(CGEvent.tapIsEnabled(tap: tap))
        if !isEventTapActive {
            errorMessage = "The keyboard listener was disabled by macOS."
        }
    }

    private func recordShortcut(_ description: String) {
        lastShortcut = description
        errorMessage = nil
    }

    private func activateMessagesAndPost(flags: CGEventFlags, description: String) {
        guard let messages = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.MobileSMS").first
        else {
            errorMessage = "Open Messages before running the shortcut test."
            return
        }

        messages.activate(options: [.activateAllWindows])
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            Self.postTabShortcut(flags: flags)
            self?.recordShortcut(description)
        }
    }

    nonisolated private static func postTabShortcut(flags: CGEventFlags) {
        guard let source = CGEventSource(stateID: .combinedSessionState),
            let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 48, keyDown: true),
            let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 48, keyDown: false)
        else {
            return
        }

        keyDown.flags = flags
        keyUp.flags = flags
        keyDown.post(tap: .cgSessionEventTap)
        usleep(8_000)
        keyUp.post(tap: .cgSessionEventTap)
    }

    nonisolated private static func pressDeleteConversationMenuItem() {
        guard
            let messages = NSRunningApplication.runningApplications(
                withBundleIdentifier: "com.apple.MobileSMS"
            ).first
        else { return }

        let application = AXUIElementCreateApplication(messages.processIdentifier)
        var menuBarValue: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(
                application,
                kAXMenuBarAttribute as CFString,
                &menuBarValue
            ) == .success,
            let menuBarValue
        else { return }

        let menuBar = menuBarValue as! AXUIElement
        let acceptedTitles = [
            "Delete Conversation",
            "Delete Conversation…",
            "Delete Conversation...",
            "Удалить разговор",
            "Удалить беседу",
        ]

        if let item = findAccessibilityElement(in: menuBar, acceptedTitles: acceptedTitles) {
            AXUIElementPerformAction(item, kAXPressAction as CFString)
        }
    }

    nonisolated private static func findAccessibilityElement(
        in element: AXUIElement,
        acceptedTitles: [String]
    ) -> AXUIElement? {
        var titleValue: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &titleValue) == .success,
            let title = titleValue as? String,
            acceptedTitles.contains(where: { title.hasPrefix($0) })
        {
            return element
        }

        var childrenValue: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(
                element,
                kAXChildrenAttribute as CFString,
                &childrenValue
            ) == .success,
            let children = childrenValue as? [AXUIElement]
        else { return nil }

        for child in children {
            if let match = findAccessibilityElement(in: child, acceptedTitles: acceptedTitles) {
                return match
            }
        }
        return nil
    }

    private func openPrivacyPane(_ anchor: String) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") else { return }
        NSWorkspace.shared.open(url)
    }
}
