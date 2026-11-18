import AppKit
import Combine
import SwiftUI

/// Panel themes. Classic is the original look and is featured; the others change the backdrop,
/// type, accent, chart colours and texture, and each hides its own easter egg.
/// Gallery order follows the case order.
enum AppThemeID: String, CaseIterable, Identifiable {
    case classic
    case graphite
    case obsidian
    case midnight
    case carbon
    case neon
    case dusk
    case cosmos

    var id: String { rawValue }
    var theme: AppTheme { AppTheme.all[self] ?? .classic }
}

/// Static texture drawn once behind the panel content (no animation, redrawn only on resize).
enum ThemeTexture {
    case none
    case nightSky
    case skyline
    case neonEdge
    case nebula
}

/// Colours for the stat pages: charts, meters and fact tints.
struct ChartPalette {
    var cpu: Color
    var gpu: Color
    var memory: Color
    var temperature: Color
    var down: Color
    var up: Color
    var disk: Color
    var fan: Color
    var system: Color
    var user: Color
    var performance: Color
    var efficiency: Color
    /// Line width of the history charts.
    var lineWidth: CGFloat = 1.25
    /// Area fill under the chart line.
    var fillOpacity: Double = 0.16
}

struct AppTheme: Equatable {
    let id: AppThemeID
    let name: String
    let tagline: String
    let symbol: String
    /// Forced panel appearance; nil follows the system.
    var appearance: NSAppearance.Name?
    var fontDesign: Font.Design = .default
    var accent: Color
    /// Header title text.
    var title: String = "MenuTools"
    var titleTracking: CGFloat = 0
    var titleItalic = false
    /// Keep the translucent material under the theme gradient.
    var usesMaterial = true
    /// Gradient laid over (or instead of) the material, top to bottom.
    var backdrop: [Color] = []
    var texture: ThemeTexture = .none
    var cardFill: Color
    var cardStroke: Color
    var controlFill: Color
    var tileFill: Color
    var hoverFill: Color = Color.primary.opacity(0.05)
    var panelStroke: Color = Color.white.opacity(0.12)
    var strokeWidth: CGFloat = 1
    /// Multiplies the corner radii (Carbon is square, Cosmos is extra round).
    var cornerScale: CGFloat = 1
    /// Soft coloured shadow under cards.
    var glow: Color?
    var charts: ChartPalette
    /// Colours used in the settings swatch.
    var swatch: [Color]

    static func == (lhs: AppTheme, rhs: AppTheme) -> Bool { lhs.id == rhs.id }

    func radius(_ base: CGFloat) -> CGFloat { (base * cornerScale).rounded() }

    var isFeatured: Bool { id == .classic }
}

// MARK: - Catalogue

extension AppTheme {
    static let all: [AppThemeID: AppTheme] = Dictionary(
        uniqueKeysWithValues: [
            classic, graphite, obsidian, midnight, carbon, neon, dusk, cosmos,
        ].map { ($0.id, $0) })

    static let classic = AppTheme(
        id: .classic,
        name: "Classic",
        tagline: "The original glass",
        symbol: "macwindow",
        accent: .accentColor,
        cardFill: Color(nsColor: .controlBackgroundColor).opacity(0.42),
        cardStroke: Color.white.opacity(0.06),
        controlFill: Color.white.opacity(0.05),
        tileFill: Color.white.opacity(0.035),
        charts: ChartPalette(
            cpu: .pink, gpu: Color(red: 0.64, green: 0.45, blue: 1), memory: .blue, temperature: .orange,
            down: Color(red: 0.28, green: 0.62, blue: 1), up: Color(red: 1, green: 0.38, blue: 0.34),
            disk: Color(red: 0.93, green: 0.62, blue: 0.22), fan: .teal,
            system: Color(red: 0.98, green: 0.38, blue: 0.42), user: Color(red: 0.35, green: 0.62, blue: 1),
            performance: Color(red: 0.64, green: 0.45, blue: 1), efficiency: Color(red: 0.25, green: 0.78, blue: 0.72)),
        swatch: [Color(white: 0.28), Color(white: 0.4), .blue]
    )

}

// MARK: - Store

/// Selected theme. Persisted in UserDefaults (`AppTheme`). Publishes only on change.
@MainActor
final class ThemeManager: ObservableObject {
    static let shared = ThemeManager()
    private static let defaultsKey = "AppTheme"

    @Published private(set) var theme: AppTheme
    /// Bumped to play the current theme's easter egg.
    @Published private(set) var easterEggToken = 0

    private var persists = true

    private init() {
        let stored = UserDefaults.standard.string(forKey: Self.defaultsKey).flatMap(AppThemeID.init(rawValue:))
        theme = (stored ?? .classic).theme
    }

    func select(_ id: AppThemeID) {
        guard id != theme.id else { return }
        theme = id.theme
        if persists { UserDefaults.standard.set(id.rawValue, forKey: Self.defaultsKey) }
    }

    /// Preview renders pick a theme without touching the saved choice.
    func previewOverride(_ id: AppThemeID) {
        persists = false
        theme = id.theme
    }

    func playEasterEgg() {
        easterEggToken += 1
    }
}

// MARK: - Environment

private struct AppThemeKey: EnvironmentKey {
    static let defaultValue: AppTheme = .classic
}

extension EnvironmentValues {
    var appTheme: AppTheme {
        get { self[AppThemeKey.self] }
        set { self[AppThemeKey.self] = newValue }
    }
}

/// Injects the selected theme into the environment. Only this view observes ThemeManager,
/// so a theme switch re-renders just the views that read `\.appTheme`.
struct ThemeHost<Content: View>: View {
    @ObservedObject private var manager = ThemeManager.shared
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .environment(\.appTheme, manager.theme)
            .fontDesign(manager.theme.fontDesign)
            .tint(manager.theme.accent)
    }
}

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: opacity)
    }
}
