import AppKit

/// Runs a mouse button action. Keystrokes are posted from the engine thread; Dock actions hop to main.
enum MouseActionRunner {
    private enum Key {
        static let leftBracket: CGKeyCode = 33
        static let rightBracket: CGKeyCode = 30
        static let equal: CGKeyCode = 24
        static let minus: CGKeyCode = 27
        static let leftArrow: CGKeyCode = 123
        static let rightArrow: CGKeyCode = 124
    }

    static func press(_ binding: MouseButtonBinding, event: CGEvent) {
        switch binding.action {
        case .none:
            break
        case .back:
            keystroke(Key.leftBracket, flags: .maskCommand)
        case .forward:
            keystroke(Key.rightBracket, flags: .maskCommand)
        case .middleClick:
            postMiddle(.otherMouseDown, like: event)
        case .missionControl:
            dock("com.apple.expose.awake", fallbackArgument: nil)
        case .appWindows:
            dock("com.apple.expose.front.awake", fallbackArgument: "2")
        case .showDesktop:
            dock("com.apple.showdesktop.awake", fallbackArgument: "1")
        case .spaceLeft:
            keystroke(Key.leftArrow, flags: [.maskControl, .maskSecondaryFn, .maskNumericPad])
        case .spaceRight:
            keystroke(Key.rightArrow, flags: [.maskControl, .maskSecondaryFn, .maskNumericPad])
        case .shortcut:
            guard let combo = binding.shortcut else { return }
            keystroke(CGKeyCode(combo.keyCode), flags: CGEventFlags(rawValue: combo.flags))
        }
    }

    static func zoom(in zoomIn: Bool) {
        keystroke(zoomIn ? Key.equal : Key.minus, flags: .maskCommand)
    }

    static func middleUp(event: CGEvent) { postMiddle(.otherMouseUp, like: event) }
    static func middleDrag(event: CGEvent) { postMiddle(.otherMouseDragged, like: event) }

    /// Middle-up at the pointer, for a press whose real button-up will never arrive (tap stopped).
    static func releaseMiddle() {
        guard let here = CGEvent(source: nil) else { return }
        postMiddle(.otherMouseUp, like: here)
    }

    // MARK: Posting

    private static func keystroke(_ key: CGKeyCode, flags: CGEventFlags) {
        let source = CGEventSource(stateID: .hidSystemState)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true),
            let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false)
        else { return }
        for event in [down, up] {
            event.flags = flags
            event.setIntegerValueField(.eventSourceUserData, value: MouseEventEngine.marker)
            // HID level, so system shortcuts (Spaces) see it like a real key press.
            event.post(tap: .cghidEventTap)
        }
    }

    private static func postMiddle(_ type: CGEventType, like original: CGEvent) {
        guard
            let event = CGEvent(
                mouseEventSource: nil, mouseType: type, mouseCursorPosition: original.location,
                mouseButton: .center)
        else { return }
        event.flags = original.flags
        event.setIntegerValueField(.mouseEventButtonNumber, value: 2)
        // Apps that pan by deltas (3D, CAD, games) need the movement, not only the location.
        event.setIntegerValueField(.mouseEventDeltaX, value: original.getIntegerValueField(.mouseEventDeltaX))
        event.setIntegerValueField(.mouseEventDeltaY, value: original.getIntegerValueField(.mouseEventDeltaY))
        event.setIntegerValueField(
            .mouseEventClickState, value: max(1, original.getIntegerValueField(.mouseEventClickState)))
        event.setIntegerValueField(.eventSourceUserData, value: MouseEventEngine.marker)
        event.post(tap: .cgSessionEventTap)
    }

    // MARK: Dock

    private typealias CoreDockSendNotification = @convention(c) (CFString, Int32) -> Void

    /// The Dock's own notification (what the Mission Control keys use); `Mission Control.app`
    /// with an argument if that private call is missing.
    private static let coreDockSend: CoreDockSendNotification? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CoreDockSendNotification") else {
            return nil
        }
        return unsafeBitCast(symbol, to: CoreDockSendNotification.self)
    }()

    private static func dock(_ notification: String, fallbackArgument: String?) {
        DispatchQueue.main.async {
            if let coreDockSend {
                coreDockSend(notification as CFString, 0)
                return
            }
            let url = URL(fileURLWithPath: "/System/Applications/Mission Control.app")
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = false
            if let fallbackArgument { configuration.arguments = [fallbackArgument] }
            NSWorkspace.shared.openApplication(at: url, configuration: configuration)
        }
    }
}
