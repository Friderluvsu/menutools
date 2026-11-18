import SwiftUI

/// Easter eggs for the catalog themes (everything except Classic). Each runs about 5 s.
extension ThemeEasterEggPainter {
    static func drawCatalog(_ id: AppThemeID, elapsed t: Double, in context: inout GraphicsContext, size: CGSize) {
        switch id {
        case .graphite: boxBreathing(&context, size, t)
        case .obsidian: dotRipple(&context, size, t)
        case .midnight: shootingStars(&context, size, t)
        case .carbon: systemsCheck(&context, size, t)
        case .dusk: cityLights(&context, size, t)
        case .neon: neonSign(&context, size, t)
        case .cosmos: visitor(&context, size, t)
        default: break
        }
    }

    // MARK: Helpers

    private static func fill(_ context: inout GraphicsContext, _ size: CGSize, _ color: Color, _ opacity: Double) {
        context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(color.opacity(opacity)))
    }

    private static func label(
        _ context: inout GraphicsContext, _ text: String, _ font: Font, _ color: Color, _ point: CGPoint,
        _ opacity: Double = 1
    ) {
        var copy = context
        copy.opacity *= max(0, min(1, opacity))
        copy.draw(Text(text).font(font).foregroundColor(color), at: point)
    }

    private static func ease(_ t: Double, _ start: Double, _ length: Double) -> Double {
        max(0, min(1, (t - start) / length))
    }

    // MARK: Graphite — box breathing: a dot traces a square, one side per phase

    private static func boxBreathing(_ context: inout GraphicsContext, _ size: CGSize, _ t: Double) {
        fill(&context, size, Color(hex: 0x111113), 0.9)
        let side: CGFloat = 130
        let rect = CGRect(x: size.width / 2 - side / 2, y: size.height / 2 - side / 2, width: side, height: side)
        var square = Path()
        square.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        square.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
        square.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        square.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        square.closeSubpath()
        context.stroke(square, with: .color(.white.opacity(0.12)), lineWidth: 1.5)
        let progress = min(1, t / 4.8)
        context.stroke(
            square.trimmedPath(from: 0, to: progress), with: .color(Color(hex: 0x9AA8BA)),
            style: StrokeStyle(lineWidth: 2, lineCap: .round))
        if let head = square.trimmedPath(from: 0, to: max(0.001, progress)).currentPoint {
            ThemeTexturePainter.blob(&context, head, 16, Color(hex: 0x9AA8BA).opacity(0.6))
            context.fill(
                Path(ellipseIn: CGRect(x: head.x - 4, y: head.y - 4, width: 8, height: 8)), with: .color(.white))
        }
        let phases = ["breathe in", "hold", "breathe out", "hold"]
        let phase = min(3, Int(t / 1.2))
        label(
            &context, phases[phase], .system(size: 15, weight: .medium), .white,
            CGPoint(x: size.width / 2, y: size.height / 2),
            1 - abs((t.truncatingRemainder(dividingBy: 1.2)) / 1.2 - 0.5))
    }

    // MARK: Obsidian — a ripple travels through a grid of dots

    private static func dotRipple(_ context: inout GraphicsContext, _ size: CGSize, _ t: Double) {
        fill(&context, size, .black, 0.92)
        let center = CGPoint(x: size.width / 2, y: size.height * 0.42)
        let gap: CGFloat = 14
        let wave = CGFloat(t) * 150
        var dim = Path()
        var lit = Path()
        var y: CGFloat = gap / 2
        while y < size.height {
            var x: CGFloat = gap / 2
            while x < size.width {
                let distance = hypot(x - center.x, y - center.y)
                let crest = exp(-pow(Double(distance - wave) / 16, 2))
                let echo = exp(-pow(Double(distance - wave + 90) / 16, 2)) * 0.5
                let boost = CGFloat(max(crest, echo))
                let radius = 0.8 + boost * 2.6
                let dot = CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2)
                if boost > 0.35 { lit.addEllipse(in: dot) } else { dim.addEllipse(in: dot) }
                x += gap
            }
            y += gap
        }
        context.fill(dim, with: .color(.white.opacity(0.22)))
        context.fill(lit, with: .color(Color(hex: 0x4C8DFF)))
        label(
            &context, "less is more.", .system(size: 13, weight: .regular), .white,
            CGPoint(x: size.width / 2, y: size.height * 0.8), ease(t, 2.4, 0.8))
    }

    // MARK: Midnight — a crescent moon rises and stars fall

    private static func shootingStars(_ context: inout GraphicsContext, _ size: CGSize, _ t: Double) {
        let night = Color(hex: 0x0B1220)
        fill(&context, size, night, 0.9)
        for index in 0..<90 {
            let twinkle = 0.4 + 0.6 * abs(sin(t * (1 + themeNoise(index, 111) * 2) + Double(index)))
            let radius = 0.4 + themeNoise(index, 112) * 1.0
            context.fill(
                Path(
                    ellipseIn: CGRect(
                        x: themeNoise(index, 113) * size.width, y: themeNoise(index, 114) * size.height,
                        width: radius * 2, height: radius * 2)),
                with: .color(.white.opacity(0.6 * twinkle)))
        }
        let rise = 1 - pow(1 - ease(t, 0, 2), 3)
        let moon = CGPoint(x: size.width * 0.7, y: size.height * 0.36 + CGFloat(1 - rise) * 80)
        ThemeTexturePainter.blob(&context, moon, 90, Color(hex: 0xF5F3CE).opacity(0.18 * rise))
        context.fill(
            Path(ellipseIn: CGRect(x: moon.x - 30, y: moon.y - 30, width: 60, height: 60)),
            with: .color(Color(hex: 0xF5F3CE).opacity(rise)))
        context.fill(
            Path(ellipseIn: CGRect(x: moon.x - 16, y: moon.y - 38, width: 60, height: 60)), with: .color(night))
        for index in 0..<4 {
            let start = 0.6 + Double(index) * 1.05
            let local = t - start
            guard local > 0, local < 0.9 else { continue }
            let origin = CGPoint(
                x: size.width * (0.2 + themeNoise(index, 115) * 0.7),
                y: size.height * (0.05 + themeNoise(index, 116) * 0.3))
            let travel = CGFloat(local / 0.9) * 180
            let head = CGPoint(x: origin.x - travel, y: origin.y + travel * 0.55)
            let tail = CGPoint(x: head.x + 60, y: head.y - 33)
            var streak = Path()
            streak.move(to: tail)
            streak.addLine(to: head)
            context.stroke(
                streak,
                with: .linearGradient(
                    Gradient(colors: [.white.opacity(0), .white]), startPoint: tail, endPoint: head),
                style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
        }
        label(
            &context, "make a wish.", .system(size: 14, weight: .medium), Color(hex: 0xC9D6FF),
            CGPoint(x: size.width / 2, y: size.height * 0.72), ease(t, 2.2, 0.8))
    }

    // MARK: Carbon — a quiet systems check

    private static func systemsCheck(_ context: inout GraphicsContext, _ size: CGSize, _ t: Double) {
        fill(&context, size, Color(hex: 0x121212), 0.94)
        let items = ["cpu", "memory", "disk", "network", "battery", "sessions"]
        let mono = Font.system(size: 12, weight: .regular, design: .monospaced)
        let left: CGFloat = 32
        let top = size.height / 2 - CGFloat(items.count) * 11 - 30
        for (index, item) in items.enumerated() {
            let start = 0.2 + Double(index) * 0.5
            guard t > start else { continue }
            let y = top + CGFloat(index) * 22
            let dots = String(repeating: ".", count: max(0, 18 - item.count))
            let copy = context
            copy.draw(
                Text("check \(item) \(dots)").font(mono).foregroundColor(Color(white: 0.75)),
                at: CGPoint(x: left, y: y), anchor: .leading)
            let done = t > start + 0.35
            copy.draw(
                Text(done ? "OK" : "··").font(mono.weight(.bold))
                    .foregroundColor(done ? Color(hex: 0x42BE65) : Color(white: 0.5)),
                at: CGPoint(x: size.width - left, y: y), anchor: .trailing)
        }
        let barY = top + CGFloat(items.count) * 22 + 10
        let track = CGRect(x: left, y: barY, width: size.width - left * 2, height: 3)
        context.fill(Path(track), with: .color(Color(hex: 0x393939)))
        let progress = ease(t, 0.2, 3.2)
        context.fill(
            Path(CGRect(x: track.minX, y: track.minY, width: track.width * progress, height: 3)),
            with: .color(Color(hex: 0x4589FF)))
        label(
            &context, "all systems nominal", .system(size: 14, weight: .semibold), Color(hex: 0x4589FF),
            CGPoint(x: size.width / 2, y: barY + 34), ease(t, 3.5, 0.5))
    }

    // MARK: Dusk — the city lights up window by window

    private static func cityLights(_ context: inout GraphicsContext, _ size: CGSize, _ t: Double) {
        context.fill(
            Path(CGRect(origin: .zero, size: size)),
            with: .linearGradient(
                Gradient(colors: [
                    Color(hex: 0x15162A).opacity(0.95), Color(hex: 0x3B2A4A).opacity(0.95),
                    Color(hex: 0xC56B5A).opacity(0.9),
                ]),
                startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
        var x: CGFloat = 0
        var building = 0
        while x < size.width {
            let width = 26 + CGFloat(themeNoise(building, 131)) * 30
            let height = 90 + CGFloat(themeNoise(building, 132)) * size.height * 0.4
            let rect = CGRect(x: x, y: size.height - height, width: width - 3, height: height)
            context.fill(Path(rect), with: .color(Color(hex: 0x0D0E1C)))
            var row = 0
            var wy = rect.minY + 8
            while wy < rect.maxY - 8 {
                var column = 0
                var wx = rect.minX + 5
                while wx < rect.maxX - 6 {
                    let seed = building * 1000 + row * 31 + column
                    if themeNoise(seed, 133) < t / 3.6 * 0.75 {
                        context.fill(
                            Path(CGRect(x: wx, y: wy, width: 4, height: 5)),
                            with: .color(Color(hex: themeNoise(seed, 134) > 0.3 ? 0xFFD58A : 0x9FD4FF).opacity(0.9)))
                    }
                    wx += 8
                    column += 1
                }
                wy += 11
                row += 1
            }
            x += width
            building += 1
        }
        label(
            &context, "good evening.", .system(size: 18, weight: .semibold, design: .rounded), Color(hex: 0xE8E4FF),
            CGPoint(x: size.width / 2, y: size.height * 0.2), ease(t, 1.2, 1))
    }

    // MARK: Neon — a sign buzzes on, letter by letter

    private static func neonSign(_ context: inout GraphicsContext, _ size: CGSize, _ t: Double) {
        fill(&context, size, Color(hex: 0x07070C), 0.92)
        let center = CGPoint(x: size.width / 2, y: size.height * 0.42)
        let frame = CGRect(x: center.x - 120, y: center.y - 50, width: 240, height: 100)
        let frameOn = t > 0.3 && !(t > 0.5 && t < 0.62)
        if frameOn {
            var glow = context
            glow.addFilter(.shadow(color: Color(hex: 0xFF2BD6), radius: 10))
            glow.stroke(
                Path(roundedRect: frame, cornerRadius: 18), with: .color(Color(hex: 0xFF7BE8)), lineWidth: 3)
        }
        let letters = Array("OPEN LATE")
        let font = Font.system(size: 36, weight: .semibold, design: .rounded)
        let spacing: CGFloat = 25
        let startX = center.x - spacing * CGFloat(letters.count - 1) / 2
        for (index, letter) in letters.enumerated() {
            let on = t > 0.8 + Double(index) * 0.18
            let broken = index == 5 && Int(t * 9).isMultiple(of: 3)
            guard on, !broken else { continue }
            var glow = context
            glow.addFilter(.shadow(color: Color(hex: 0x00E1FF), radius: 8))
            glow.draw(
                Text(String(letter)).font(font).foregroundColor(Color(hex: 0xC8FAFF)),
                at: CGPoint(x: startX + CGFloat(index) * spacing, y: center.y))
        }
        label(
            &context, "still working? go home.", .system(size: 12, weight: .medium), Color(white: 0.75),
            CGPoint(x: center.x, y: center.y + 90), ease(t, 2.8, 0.6))
    }

    // MARK: Cosmos — a visitor drops by

    private static func visitor(_ context: inout GraphicsContext, _ size: CGSize, _ t: Double) {
        fill(&context, size, Color(hex: 0x090418), 0.9)
        for index in 0..<80 {
            let radius = 0.4 + themeNoise(index, 181) * 1
            context.fill(
                Path(
                    ellipseIn: CGRect(
                        x: themeNoise(index, 182) * size.width, y: themeNoise(index, 183) * size.height,
                        width: radius * 2, height: radius * 2)), with: .color(.white.opacity(0.6)))
        }
        let arrive = 1 - pow(1 - ease(t, 0, 1.4), 3)
        let leave = pow(ease(t, 3.8, 1.2), 2)
        let x = -60 + CGFloat(arrive) * (size.width / 2 + 60) + CGFloat(leave) * (size.width / 2 + 120)
        let y = size.height * 0.32 - CGFloat(leave) * 120 + CGFloat(sin(t * 3)) * 4
        let beamOn = t > 1.5 && t < 3.7
        if beamOn {
            var beam = Path()
            beam.move(to: CGPoint(x: x - 16, y: y + 10))
            beam.addLine(to: CGPoint(x: x + 16, y: y + 10))
            beam.addLine(to: CGPoint(x: x + 70, y: size.height * 0.85))
            beam.addLine(to: CGPoint(x: x - 70, y: size.height * 0.85))
            beam.closeSubpath()
            context.fill(
                beam,
                with: .linearGradient(
                    Gradient(colors: [Color(hex: 0x7CFFD4).opacity(0.55), Color(hex: 0x7CFFD4).opacity(0.05)]),
                    startPoint: CGPoint(x: x, y: y), endPoint: CGPoint(x: x, y: size.height * 0.85)))
            let lift = CGFloat(ease(t, 1.8, 1.8))
            let cube = CGRect(x: x - 12, y: size.height * 0.8 - lift * (size.height * 0.45), width: 24, height: 24)
            context.fill(Path(roundedRect: cube, cornerRadius: 5), with: .color(Color(hex: 0xFFB4E6)))
            context.draw(
                Text("CPU").font(.system(size: 7, weight: .bold, design: .rounded)).foregroundColor(.black),
                at: CGPoint(x: cube.midX, y: cube.midY))
        }
        context.fill(
            Path(ellipseIn: CGRect(x: x - 16, y: y - 22, width: 32, height: 26)),
            with: .color(Color(hex: 0x9CE8FF).opacity(0.8)))
        context.fill(
            Path(ellipseIn: CGRect(x: x - 44, y: y - 8, width: 88, height: 20)),
            with: .linearGradient(
                Gradient(colors: [Color(hex: 0xC9C9D9), Color(hex: 0x6E6E85)]), startPoint: CGPoint(x: x, y: y - 8),
                endPoint: CGPoint(x: x, y: y + 12)))
        for light in 0..<5 {
            let on = (Int(t * 6) + light).isMultiple(of: 2)
            context.fill(
                Path(ellipseIn: CGRect(x: x - 30 + CGFloat(light) * 14, y: y, width: 5, height: 5)),
                with: .color(on ? Color(hex: 0xFFE38A) : Color(hex: 0xFF4D9D)))
        }
        label(
            &context, "we come in peace.", .system(size: 15, weight: .semibold, design: .rounded), Color(hex: 0xFFB4E6),
            CGPoint(x: size.width / 2, y: size.height * 0.92), ease(t, 2, 0.6))
    }
}
