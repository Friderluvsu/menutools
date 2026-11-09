import SwiftUI

/// Each theme's hidden animation. Triggered by clicking the panel header icon five times quickly.
/// The timeline exists only while an egg plays (~5 s), so it costs nothing at rest.
struct ThemeEasterEggLayer: View {
    @ObservedObject private var manager = ThemeManager.shared
    @State private var startedAt: Date?
    @State private var playing: AppThemeID = .classic
    @State private var playToken = 0

    static let duration: TimeInterval = 5.2
    /// `--render-preview ... --egg-at <seconds>` draws one still frame of the egg.
    nonisolated(unsafe) static var previewElapsed: Double?

    var body: some View {
        ZStack {
            if let elapsed = Self.previewElapsed {
                let theme = manager.theme.id
                Canvas { context, size in
                    ThemeEasterEggPainter.draw(theme, elapsed: elapsed, in: &context, size: size)
                }
            } else if let startedAt {
                let theme = playing
                TimelineView(.animation) { timeline in
                    let elapsed = timeline.date.timeIntervalSince(startedAt)
                    Canvas { context, size in
                        ThemeEasterEggPainter.draw(theme, elapsed: elapsed, in: &context, size: size)
                    }
                }
                .transition(.opacity)
            }
        }
        .allowsHitTesting(false)
        .onChange(of: manager.easterEggToken) { _, _ in start() }
    }

    private func start() {
        playToken += 1
        let token = playToken
        playing = manager.theme.id
        startedAt = Date()
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.duration) {
            guard token == playToken else { return }
            startedAt = nil
        }
    }
}

enum ThemeEasterEggPainter {
    static func draw(_ id: AppThemeID, elapsed t: Double, in context: inout GraphicsContext, size: CGSize) {
        let total = ThemeEasterEggLayer.duration
        let fade = min(1, t / 0.35, max(0, (total - t) / 0.5))
        context.opacity = fade
        switch id {
        case .classic: hello(&context, size, t)
        default: drawCatalog(id, elapsed: t, in: &context, size: size)
        }
    }

    // MARK: Helpers

    private static func dim(_ context: inout GraphicsContext, _ size: CGSize, _ color: Color, _ opacity: Double) {
        context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(color.opacity(opacity)))
    }

    private static func caption(
        _ context: inout GraphicsContext, _ text: String, _ font: Font, _ color: Color, at point: CGPoint,
        opacity: Double = 1
    ) {
        var copy = context
        copy.opacity *= max(0, min(1, opacity))
        copy.draw(Text(text).font(font).foregroundColor(color), at: point)
    }

    private static func ramp(_ t: Double, from start: Double, over length: Double) -> Double {
        max(0, min(1, (t - start) / length))
    }

    // MARK: Classic — six-colour stripes sweep the panel and it says hello

    private static func hello(_ context: inout GraphicsContext, _ size: CGSize, _ t: Double) {
        dim(&context, size, .black, 0.75)
        let stripes: [Color] = [
            Color(hex: 0x61BB46), Color(hex: 0xFDB827), Color(hex: 0xF5821F), Color(hex: 0xE03A3E),
            Color(hex: 0x963D97), Color(hex: 0x009DDC),
        ]
        let band: CGFloat = 9
        let sweep = CGFloat(ramp(t, from: 0.1, over: 1.2)) * (size.width + 80) - 40
        let top = size.height / 2 - band * 3 - 34
        for (index, color) in stripes.enumerated() {
            let rect = CGRect(x: 0, y: top + CGFloat(index) * band, width: max(0, sweep), height: band)
            context.fill(Path(rect), with: .color(color.opacity(0.9)))
        }
        let ring = Path(roundedRect: CGRect(origin: .zero, size: size).insetBy(dx: 2, dy: 2), cornerRadius: 13)
        context.stroke(
            ring,
            with: .conicGradient(
                Gradient(colors: stripes + [stripes[0]]), center: CGPoint(x: size.width / 2, y: size.height / 2),
                angle: .degrees(t * 90)),
            lineWidth: 3)
        let appear = ramp(t, from: 1.1, over: 0.9)
        caption(
            &context, "hello.", .system(size: 56, weight: .bold).italic(), .white,
            at: CGPoint(x: size.width / 2, y: size.height / 2 + 40), opacity: appear)
    }

}
