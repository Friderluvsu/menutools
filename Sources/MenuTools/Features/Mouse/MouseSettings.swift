import AppKit

/// What a mouse button does. `none` leaves the button to macOS and the app.
enum MouseAction: String, Codable, CaseIterable, Identifiable, Sendable {
    case none
    case back
    case forward
    case middleClick
    case missionControl
    case appWindows
    case showDesktop
    case spaceLeft
    case spaceRight
    case shortcut

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: return "Default"
        case .back: return "Back"
        case .forward: return "Forward"
        case .middleClick: return "Middle click"
        case .missionControl: return "Mission Control"
        case .appWindows: return "App windows"
        case .showDesktop: return "Show desktop"
        case .spaceLeft: return "Space left"
        case .spaceRight: return "Space right"
        case .shortcut: return "Shortcut…"
        }
    }
}

/// A recorded key combination for `MouseAction.shortcut`.
struct KeyCombo: Codable, Equatable, Sendable {
    var keyCode: UInt16
    /// `CGEventFlags` raw value (modifier bits only).
    var flags: UInt64
    var display: String
}

struct MouseButtonBinding: Codable, Equatable, Identifiable, Sendable {
    /// CGEvent `mouseEventButtonNumber`: 2 middle, 3 back, 4 forward, 5+ extra buttons.
    var button: Int
    var action: MouseAction
    var shortcut: KeyCombo?

    var id: Int { button }

    var buttonTitle: String {
        switch button {
        case 2: return "Middle"
        case 3: return "Back button"
        case 4: return "Forward button"
        default: return "Button \(button + 1)"
        }
    }
}

/// Per-app rule. `true` turns that feature off while the app is frontmost.
struct MouseAppRule: Codable, Equatable, Identifiable, Sendable {
    var id: String  // bundle id
    var name: String
    var scrollOff = true
    var buttonsOff = true
    var cursorOff = true
}

/// Everything the user sets on Settings → Mouse. Stored as one JSON blob (`MouseSettings`).
struct MousePrefs: Codable, Equatable, Sendable {
    // Scroll (physical wheel only; trackpads and Magic Mouse are never touched)
    var scrollEnabled = false
    var smoothScroll = true
    var scrollSpeed = 1.0  // 0.3 ... 4
    var scrollAcceleration = 0.5  // 0 ... 1
    var scrollDuration = 0.3  // s, 0.1 ... 0.7
    var reverseVertical = false
    var horizontalSpeed = 1.0
    var reverseHorizontal = false
    var shiftHorizontal = true
    var commandFast = true
    var controlZoom = true
    var fastGain = 3.0  // 1.5 ... 8

    // Buttons
    var buttonsEnabled = false
    var bindings: [MouseButtonBinding] = [
        MouseButtonBinding(button: 2, action: .none),
        MouseButtonBinding(button: 3, action: .back),
        MouseButtonBinding(button: 4, action: .forward),
    ]

    // Cursor (external mice only)
    var cursorEnabled = false
    var cursorSpeed = 1.0  // multiplier on the device's own resolution, 0.3 ... 4
    var cursorAcceleration = 0.6875  // macOS scale, 0 ... 3
    var cursorLinear = false  // acceleration off

    var appRules: [MouseAppRule] = []

    /// Saved JSON laid over the defaults, so fields added later keep their default.
    static func load(from data: Data?) -> MousePrefs {
        let base = MousePrefs()
        guard let data,
            let saved = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let defaultData = try? JSONEncoder().encode(base),
            var merged = try? JSONSerialization.jsonObject(with: defaultData) as? [String: Any]
        else { return base }
        merged.merge(saved) { _, new in new }
        guard let mergedData = try? JSONSerialization.data(withJSONObject: merged),
            let prefs = try? JSONDecoder().decode(MousePrefs.self, from: mergedData)
        else { return base }
        return prefs
    }
}
