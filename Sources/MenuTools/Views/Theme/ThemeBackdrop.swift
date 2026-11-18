import SwiftUI

/// Panel background for the current theme: optional material, the theme gradient and a static
/// texture. The Canvas has no timeline, so it redraws only when the panel size changes.
struct ThemeBackdrop: View {
    let theme: AppTheme

    var body: some View {
        ZStack {
            if theme.usesMaterial {
                Rectangle().fill(.ultraThinMaterial)
            }
            if !theme.backdrop.isEmpty {
                LinearGradient(colors: theme.backdrop, startPoint: .top, endPoint: .bottom)
            }
            if theme.texture != .none {
                let texture = theme.texture
                Canvas(rendersAsynchronously: true) { context, size in
                    ThemeTexturePainter.draw(texture, in: &context, size: size)
                }
                .allowsHitTesting(false)
            }
        }
    }
}

/// Deterministic pseudo-random in 0..<1, stable across redraws.
func themeNoise(_ index: Int, _ salt: Int = 0) -> Double {
    let value = sin(Double(index) * 12.9898 + Double(salt) * 78.233) * 43758.5453
    return value - value.rounded(.down)
}

enum ThemeTexturePainter {
    static func draw(_ texture: ThemeTexture, in context: inout GraphicsContext, size: CGSize) {
        switch texture {
        case .none:
            break
        case .nightSky:
            for index in 0..<55 {
                let radius = 0.35 + themeNoise(index, 101) * 0.75
                let rect = CGRect(
                    x: themeNoise(index, 102) * size.width, y: themeNoise(index, 103) * size.height * 0.7,
                    width: radius * 2, height: radius * 2)
                context.fill(
                    Path(ellipseIn: rect), with: .color(.white.opacity(0.12 + themeNoise(index, 104) * 0.3)))
            }
            blob(&context, CGPoint(x: size.width * 0.85, y: 0), 160, Color(hex: 0x6C8EEF).opacity(0.12))
        case .skyline:
            blob(&context, CGPoint(x: size.width * 0.5, y: size.height + 20), 260, Color(hex: 0xFF9E64).opacity(0.1))
            var city = Path()
            var x: CGFloat = 0
            var index = 0
            while x < size.width {
                let width = 14 + CGFloat(themeNoise(index, 107)) * 20
                let height = 16 + CGFloat(themeNoise(index, 108)) * 46
                city.addRect(CGRect(x: x, y: size.height - height, width: width - 2, height: height))
                x += width
                index += 1
            }
            context.fill(city, with: .color(Color.black.opacity(0.22)))
        case .neonEdge:
            var top = Path()
            top.addRect(CGRect(x: 0, y: 0, width: size.width, height: 1.5))
            context.fill(
                top,
                with: .linearGradient(
                    Gradient(colors: [Color(hex: 0xFF2BD6), Color(hex: 0x00E1FF)]), startPoint: .zero,
                    endPoint: CGPoint(x: size.width, y: 0)))
            blob(&context, CGPoint(x: 0, y: 0), 160, Color(hex: 0xFF2BD6).opacity(0.1))
            blob(&context, CGPoint(x: size.width, y: size.height), 200, Color(hex: 0x00E1FF).opacity(0.08))
        case .nebula:
            blob(
                &context, CGPoint(x: size.width * 0.15, y: size.height * 0.25), 200, Color(hex: 0xC04CFD).opacity(0.18))
            blob(&context, CGPoint(x: size.width * 0.85, y: size.height * 0.6), 220, Color(hex: 0x3A86FF).opacity(0.16))
            blob(&context, CGPoint(x: size.width * 0.4, y: size.height * 0.95), 180, Color(hex: 0xFF4D9D).opacity(0.12))
            for index in 0..<70 {
                let radius = 0.4 + themeNoise(index, 152) * 0.9
                context.fill(
                    Path(
                        ellipseIn: CGRect(
                            x: themeNoise(index, 153) * size.width, y: themeNoise(index, 154) * size.height,
                            width: radius * 2, height: radius * 2)),
                    with: .color(.white.opacity(0.2 + themeNoise(index, 155) * 0.4)))
            }
            let planet = CGPoint(x: size.width - 34, y: 70)
            context.fill(
                Path(ellipseIn: CGRect(x: planet.x - 16, y: planet.y - 16, width: 32, height: 32)),
                with: .linearGradient(
                    Gradient(colors: [Color(hex: 0xFFB4E6).opacity(0.35), Color(hex: 0x9C8CFF).opacity(0.15)]),
                    startPoint: CGPoint(x: planet.x - 16, y: planet.y - 16),
                    endPoint: CGPoint(x: planet.x + 16, y: planet.y + 16)))
            var ring = context
            ring.translateBy(x: planet.x, y: planet.y)
            ring.rotate(by: .degrees(-18))
            ring.stroke(
                Path(ellipseIn: CGRect(x: -28, y: -6, width: 56, height: 12)),
                with: .color(Color(hex: 0xFFE38A).opacity(0.3)), lineWidth: 1.2)
        }
    }

    static func blob(_ context: inout GraphicsContext, _ center: CGPoint, _ radius: CGFloat, _ color: Color) {
        context.fill(
            Path(CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)),
            with: .radialGradient(
                Gradient(colors: [color, color.opacity(0)]), center: center, startRadius: 0, endRadius: radius))
    }
}
