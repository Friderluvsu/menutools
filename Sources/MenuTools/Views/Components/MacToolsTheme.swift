import AppKit
import SwiftUI

enum MacToolsTheme {
    static let popoverWidth: CGFloat = 360
    /// Initial panel height before SwiftUI reports the real one; the panel is sized to fit its content.
    static let popoverHeight: CGFloat = 480
    static let cornerRadius: CGFloat = 10
    static let outerPadding: CGFloat = 8
    static let sectionSpacing: CGFloat = 6
    static let controlHeight: CGFloat = 28

    static var panelBackground: Color {
        Color(nsColor: .windowBackgroundColor).opacity(0.85)
    }

    static var cardBackground: Color {
        Color(nsColor: .controlBackgroundColor).opacity(0.42)
    }

    static var controlBackground: Color {
        Color.white.opacity(0.05)
    }

    static var hoverBackground: Color {
        Color.white.opacity(0.09)
    }

    static var borderColor: Color {
        Color.white.opacity(0.06)
    }

    static var borderHoverColor: Color {
        Color.white.opacity(0.14)
    }
}

struct MacToolsCard<Content: View>: View {
    let content: Content
    var padding: CGFloat = 8
    var cornerRadius: CGFloat = MacToolsTheme.cornerRadius

    init(padding: CGFloat = 8, cornerRadius: CGFloat = MacToolsTheme.cornerRadius, @ViewBuilder content: () -> Content)
    {
        self.padding = padding
        self.cornerRadius = cornerRadius
        self.content = content()
    }

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(MacToolsTheme.cardBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(MacToolsTheme.borderColor, lineWidth: 1)
            )
    }
}

// MARK: - Shared building blocks

/// Thin capsule progress bar (shape-based, no GeometryReader).
struct MiniBar: View {
    let fraction: Double
    var color: Color
    var height: CGFloat = 3

    var body: some View {
        ZStack {
            Capsule().fill(Color.primary.opacity(0.08))
            BarFillShape(fraction: fraction)
                .fill(color)
                .opacity(fraction > 0 ? 1 : 0)
        }
        .frame(height: height)
        .animation(.easeOut(duration: 0.3), value: fraction)
    }
}

private struct BarFillShape: Shape {
    var fraction: Double

    var animatableData: Double {
        get { fraction }
        set { fraction = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let width = max(rect.height, rect.width * min(max(fraction, 0), 1))
        return Path(
            roundedRect: CGRect(x: rect.minX, y: rect.minY, width: width, height: rect.height),
            cornerRadius: rect.height / 2)
    }
}

// MARK: - Panel fitting

/// Natural height of the panel content (max of the page and any open picker). The panel is sized to it.
struct PanelHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

extension View {
    /// Reports this view's height (+ `extra`) so the panel can fit it without scrolling.
    func reportsPanelHeight(extra: CGFloat = 0) -> some View {
        background(
            GeometryReader { proxy in
                Color.clear.preference(key: PanelHeightKey.self, value: proxy.size.height + extra)
            }
        )
    }
}

/// Subtle hover highlight for plain buttons and rows.
struct HoverHighlight: ViewModifier {
    var cornerRadius: CGFloat = 8
    @State private var isHovered = false

    func body(content: Content) -> some View {
        content
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Color.primary.opacity(isHovered ? 0.05 : 0))
                    .allowsHitTesting(false)
            )
            .onHover { hovering in
                withAnimation(.easeOut(duration: 0.12)) { isHovered = hovering }
            }
            .onDisappear { isHovered = false }
    }
}

extension View {
    func hoverHighlight(cornerRadius: CGFloat = 8) -> some View {
        modifier(HoverHighlight(cornerRadius: cornerRadius))
    }

    /// Clicks in the panel should not draw the accent focus ring.
    func suppressesFocusRing() -> some View {
        focusable(false).focusEffectDisabled()
    }
}
