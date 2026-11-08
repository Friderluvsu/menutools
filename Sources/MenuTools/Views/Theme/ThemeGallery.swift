import SwiftUI

/// Settings → Themes. Classic is featured on top; the other themes sit in a four-column grid
/// of swatches. The line under the grid names the hovered (or selected) theme.
struct ThemeGallery: View {
    @ObservedObject private var manager = ThemeManager.shared
    @State private var hovered: AppThemeID?

    private let themes = AppThemeID.allCases.filter { $0 != .classic }

    private var described: AppTheme { (hovered ?? manager.theme.id).theme }

    var body: some View {
        MacToolsCard(padding: 8) {
            VStack(alignment: .leading, spacing: 6) {
                ThemeTile(theme: .classic, isSelected: manager.theme.id == .classic, featured: true) {
                    manager.select(.classic)
                }
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 5), count: 4), spacing: 5) {
                    ForEach(themes) { id in
                        ThemeSwatch(theme: id.theme, isSelected: manager.theme.id == id) { manager.select(id) }
                            .onHover { inside in
                                if inside { hovered = id } else if hovered == id { hovered = nil }
                            }
                    }
                }
                HStack(spacing: 4) {
                    Text(described.name)
                        .font(.system(size: 10, weight: .semibold))
                    Text("· \(described.tagline)")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 4)
                    Text("Every theme hides a secret.")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }
                .lineLimit(1)
                .padding(.horizontal, 2)
            }
        }
    }
}

/// Compact tile for the grid: the theme's own backdrop, its icon and name in its type.
private struct ThemeSwatch: View {
    let theme: AppTheme
    let isSelected: Bool
    let action: () -> Void

    @Environment(\.colorScheme) private var systemScheme

    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: theme.symbol)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(theme.accent)
                    .frame(height: 15)
                Text(theme.name)
                    .font(.system(size: 9.5, weight: .semibold, design: theme.fontDesign))
                    .italic(theme.titleItalic)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity, minHeight: 44)
            .background {
                ThemeBackdrop(theme: theme)
                    .background(Color(nsColor: .windowBackgroundColor))
            }
            .environment(\.colorScheme, scheme)
            .clipShape(RoundedRectangle(cornerRadius: max(3, theme.radius(7)), style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: max(3, theme.radius(7)), style: .continuous)
                    .strokeBorder(
                        isSelected ? theme.accent : theme.panelStroke.opacity(0.6),
                        lineWidth: isSelected ? 1.5 : 0.75)
            )
            .overlay(alignment: .topTrailing) {
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(theme.accent)
                        .padding(3)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .suppressesFocusRing()
        .help("\(theme.name) · \(theme.tagline)")
    }

    private var scheme: ColorScheme {
        switch theme.appearance {
        case .some(.aqua): return .light
        case .some(.darkAqua): return .dark
        default: return systemScheme
        }
    }
}

/// A miniature of the theme: its own backdrop, texture, type and accent, so each tile looks like the panel.
private struct ThemeTile: View {
    let theme: AppTheme
    let isSelected: Bool
    var featured = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: theme.symbol)
                    .font(.system(size: featured ? 13 : 11, weight: .semibold))
                    .foregroundStyle(theme.accent)
                    .frame(width: featured ? 26 : 20, height: featured ? 26 : 20)
                    .background(theme.accent.opacity(0.16), in: RoundedRectangle(cornerRadius: theme.radius(6)))
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 5) {
                        Text(theme.name)
                            .font(.system(size: featured ? 12 : 11, weight: .semibold, design: theme.fontDesign))
                            .italic(theme.titleItalic)
                            .lineLimit(1)
                        if featured {
                            Text("FEATURED")
                                .font(.system(size: 7.5, weight: .heavy))
                                .tracking(0.6)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1.5)
                                .background(Color.yellow.opacity(0.85), in: Capsule())
                                .foregroundStyle(.black)
                        }
                    }
                    Text(theme.tagline)
                        .font(.system(size: 9, design: theme.fontDesign))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                }
                Spacer(minLength: 0)
                if featured {
                    swatch
                }
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(theme.accent)
                }
            }
            .padding(.horizontal, 7)
            .frame(maxWidth: .infinity, minHeight: featured ? 40 : 36, alignment: .leading)
            .background {
                ThemeBackdrop(theme: theme)
                    .background(Color(nsColor: .windowBackgroundColor))
            }
            .environment(\.colorScheme, scheme)
            .clipShape(RoundedRectangle(cornerRadius: max(4, theme.radius(8)), style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: max(4, theme.radius(8)), style: .continuous)
                    .strokeBorder(
                        isSelected ? theme.accent : theme.panelStroke.opacity(0.6),
                        lineWidth: isSelected ? 1.5 : 0.75)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .suppressesFocusRing()
        .help(theme.name)
    }

    private var swatch: some View {
        HStack(spacing: -4) {
            ForEach(Array(theme.swatch.enumerated()), id: \.offset) { _, color in
                Circle().fill(color).frame(width: 12, height: 12)
                    .overlay(Circle().strokeBorder(Color.white.opacity(0.4), lineWidth: 0.5))
            }
        }
    }

    @Environment(\.colorScheme) private var systemScheme

    private var scheme: ColorScheme {
        switch theme.appearance {
        case .some(.aqua): return .light
        case .some(.darkAqua): return .dark
        default: return systemScheme
        }
    }
}
