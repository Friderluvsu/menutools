import AppKit
import Combine

/// Things shown beside the menu bar icon (Settings → General → Menu bar). Each is a monochrome SF
/// Symbol in the menu bar's text colour, filled (or full strength) when that thing is on, with a
/// short value where it has one.
enum MenuBarItem: String, CaseIterable, Identifiable {
    case awake
    case lid
    case vpn
    case spoof
    case cpu
    case temperature
    case memory
    case network

    var id: String { rawValue }

    var title: String {
        switch self {
        case .awake: return "Awake"
        case .lid: return "Closed-lid"
        case .vpn: return "VPN"
        case .spoof: return "SpoofDPI"
        case .cpu: return "CPU"
        case .temperature: return "Temperature"
        case .memory: return "Memory"
        case .network: return "Download speed"
        }
    }

    /// Settings chip symbol.
    var symbol: String {
        switch self {
        case .awake: return "cup.and.saucer"
        case .lid: return "laptopcomputer"
        case .vpn: return "lock.shield"
        case .spoof: return "bolt.horizontal"
        case .cpu: return "cpu"
        case .temperature: return "thermometer.medium"
        case .memory: return "memorychip"
        case .network: return "arrow.down"
        }
    }

    /// Values that come from the system monitor's 2 s sampler.
    var isStat: Bool { [.cpu, .temperature, .memory, .network].contains(self) }
    var isNetworkBypass: Bool { self == .vpn || self == .spoof }
}

/// One piece of the menu bar title.
struct MenuBarSegment: Equatable {
    var symbol: String
    /// false draws the symbol dimmed (used where the symbol has no filled form).
    var strong = true
    var text: String?
}

/// Which items are on, in the fixed order of `MenuBarItem.allCases` (UserDefaults `MenuBarItems`).
@MainActor
final class MenuBarItemsStore: ObservableObject {
    static let shared = MenuBarItemsStore()
    private static let key = "MenuBarItems"

    @Published private(set) var items: Set<MenuBarItem>

    private init() {
        let defaults = UserDefaults.standard
        if let saved = defaults.stringArray(forKey: Self.key) {
            items = Set(saved.compactMap(MenuBarItem.init(rawValue:)))
        } else {
            // Older builds had one "Menu bar label" choice.
            switch defaults.string(forKey: "StatusDisplayMode") {
            case "Icon + Anti-Sleep Timer": items = [.awake]
            case "Icon + VPN / Spoof Status": items = [.vpn, .spoof]
            default: items = []
            }
        }
    }

    func toggle(_ item: MenuBarItem) {
        if items.contains(item) { items.remove(item) } else { items.insert(item) }
        UserDefaults.standard.set(MenuBarItem.allCases.filter(items.contains).map(\.rawValue), forKey: Self.key)
    }

    var ordered: [MenuBarItem] { MenuBarItem.allCases.filter(items.contains) }
    var needsStats: Bool { items.contains { $0.isStat } }
    var needsNetworkBypass: Bool { items.contains { $0.isNetworkBypass } }
}

extension AppState {
    /// The menu bar title pieces for the chosen items.
    func menuBarSegments(_ items: [MenuBarItem]) -> [MenuBarSegment] {
        let stats = systemMonitor.menuBarStats
        return items.map { item in
            switch item {
            case .awake:
                return MenuBarSegment(
                    symbol: antiSleep.awakeOn ? "cup.and.saucer.fill" : "cup.and.saucer",
                    text: antiSleep.awakeOn ? countdown(antiSleep.statusText) : nil)
            case .lid:
                return MenuBarSegment(
                    symbol: "laptopcomputer", strong: antiSleep.lidOn,
                    text: antiSleep.lidOn ? countdown(antiSleep.lidStatusText) : nil)
            case .vpn:
                return MenuBarSegment(symbol: network.isVPNConnected ? "lock.shield.fill" : "lock.shield")
            case .spoof:
                return MenuBarSegment(
                    symbol: network.isSpoofDPIRunning ? "bolt.horizontal.fill" : "bolt.horizontal")
            case .cpu:
                return MenuBarSegment(symbol: "cpu", text: Self.fixed("\(Int(stats.cpu.rounded()))%", width: 4))
            case .temperature:
                return MenuBarSegment(
                    symbol: "thermometer.medium",
                    text: Self.fixed(stats.temperature.map { "\(Int($0.rounded()))°" } ?? "–", width: 4))
            case .memory:
                return MenuBarSegment(symbol: "memorychip", text: Self.fixed("\(Int(stats.memory.rounded()))%", width: 4))
            case .network:
                return MenuBarSegment(symbol: "arrow.down", text: Self.fixed(Self.speed(stats.downKBps), width: 4))
            }
        }
    }

    /// Only a running countdown is written; an open-ended session is shown by the filled symbol.
    private func countdown(_ text: String) -> String? {
        text == "On" || text == "OFF" ? nil : text
    }

    /// Left-padded with figure spaces (digit width), so "9%" → "10%" does not resize the status item
    /// and shift every menu bar item to its left.
    private static func fixed(_ text: String, width: Int) -> String {
        String(repeating: "\u{2007}", count: max(0, width - text.count)) + text
    }

    private static func speed(_ kbps: Double) -> String {
        if kbps >= 1024 * 10 { return String(format: "%.0fM", kbps / 1024) }
        if kbps >= 1024 { return String(format: "%.1fM", kbps / 1024) }
        return String(format: "%.0fK", kbps)
    }
}

enum MenuBarTitleRenderer {
    /// Symbols and values as one attributed title. Symbols are drawn in `labelColor` at draw time,
    /// so they follow a dark or light menu bar.
    static func title(_ segments: [MenuBarSegment], font: NSFont) -> NSAttributedString {
        let text = NSMutableAttributedString()
        let digits = NSFont.monospacedDigitSystemFont(ofSize: font.pointSize, weight: .regular)
        let config = NSImage.SymbolConfiguration(pointSize: font.pointSize - 1, weight: .medium)
        for segment in segments {
            text.append(NSAttributedString(string: text.length == 0 ? " " : "  ", attributes: [.font: font]))
            if let glyph = NSImage(systemSymbolName: segment.symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(config)
            {
                let alpha: CGFloat = segment.strong ? 1 : 0.45
                let icon = NSImage(size: glyph.size, flipped: false) { rect in
                    glyph.draw(in: rect)
                    NSColor.labelColor.withAlphaComponent(alpha).set()
                    rect.fill(using: .sourceAtop)
                    return true
                }
                let attachment = NSTextAttachment()
                attachment.image = icon
                attachment.bounds = CGRect(
                    x: 0, y: (font.capHeight - glyph.size.height) / 2, width: glyph.size.width,
                    height: glyph.size.height)
                text.append(NSAttributedString(attachment: attachment))
            }
            if let value = segment.text {
                text.append(
                    NSAttributedString(
                        string: " " + value, attributes: [.font: digits, .foregroundColor: NSColor.labelColor]))
            }
        }
        return text
    }
}
