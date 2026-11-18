import AppKit
import CoreText

/// Scene styles: count styles drawn as little pictures: Gauge, Matrix, Timeline, Badge, Radar, Meter.
/// Every mark is keyed by state and slot (or by state for single-mark scenes), so the live view can
/// glide, pop and fade marks exactly like Halo and Pills. Ambient motion (Radar's glowing blips) is a
/// repeating Core Animation animation on that mark only.
extension CountLayout {
    enum Ambient: Equatable {
        case glow
    }

    struct Mark {
        /// Layer position; `path` is relative to it.
        var center: CGPoint
        var path: CGPath
        var stroked = false
        var lineWidth: CGFloat = 0
        var evenOdd = false
        /// Repeating motion on the whole mark.
        var ambient: Ambient?
        /// A soft halo of the mark's own colour, whatever the theme.
        var glow = false
    }

    // MARK: Layouts

    static func sceneItems(style: StatusLightStyle, counts: [Int]) -> [Item] {
        let marks = marks(counts)
        let n = marks.count
        func key(_ mark: (state: Int, slot: Int)) -> String { "\(mark.state)-\(mark.slot)" }
        func item(_ mark: (state: Int, slot: Int), _ shape: Mark) -> Item {
            Item(key: key(mark), state: mark.state, kind: .mark(shape))
        }

        switch style {
        case .gauge:
            guard n > 0 else { return [] }
            let gap: CGFloat = n > 1 ? 0.03 : 0
            let length = (1 - CGFloat(n - 1) * gap) / CGFloat(n)
            var result = marks.enumerated().map { index, mark in
                let start = CGFloat(index) * (length + gap)
                return Item(key: key(mark), state: mark.state, kind: .arc(start: start, end: start + length))
            }
            // The needle points at the middle of the busiest state's arcs (input wins a tie).
            let busiest =
                (0..<3).max { a, b in
                    let ca = min(counts[a], maxPerState)
                    let cb = min(counts[b], maxPerState)
                    return ca == cb ? a > b : ca < cb
                } ?? 1
            let indices = marks.indices.filter { marks[$0].state == busiest }
            if let first = indices.first, let last = indices.last {
                let middle = (CGFloat(first) * (length + gap) + CGFloat(last) * (length + gap) + length) / 2
                let track = track(style: style)
                let angle = track.angle(at: middle)
                let needle = CGMutablePath()
                needle.move(to: .zero)
                needle.addLine(to: CGPoint(x: cos(angle) * 4.6, y: sin(angle) * 4.6))
                result.append(
                    Item(
                        key: "needle-\(busiest)", state: busiest,
                        kind: .mark(Mark(center: track.center, path: needle, stroked: true, lineWidth: 1.5))))
            }
            return result
        case .matrix:
            return marks.map { mark in
                let center = CGPoint(x: 3.5 + CGFloat(mark.slot) * 5.5, y: 14.5 - CGFloat(mark.state) * 5.5)
                return item(
                    mark,
                    Mark(center: center, path: roundedRect(CGRect(x: -2.2, y: -2.2, width: 4.4, height: 4.4), 1.2)))
            }
        case .timeline:
            // One bar per state; its length is the share of 3 sessions.
            return (0..<3).compactMap { state in
                let count = min(counts[state], maxPerState)
                guard count > 0 else { return nil }
                let width = 20 * CGFloat(count) / CGFloat(maxPerState)
                let rect = CGRect(x: 1, y: [14.0, 9.0, 4.0][state] - 1.7, width: width, height: 3.4)
                return Item(key: "\(state)-0", state: state, kind: .pill(rect))
            }
        case .badge:
            guard let state = (0..<3).first(where: { counts[$0] > 0 }) else { return [] }
            let count = counts[state]
            let text = count > 9 ? "9+" : "\(count)"
            let square = CGMutablePath()
            square.addPath(roundedRect(CGRect(x: -7.6, y: -7.6, width: 15.2, height: 15.2), 4.2))
            square.addPath(textPath(text, size: count > 9 ? 9 : 11.5))
            return [
                Item(
                    key: "badge-\(state)-\(text)", state: state,
                    kind: .mark(Mark(center: CGPoint(x: 9, y: 9), path: square, evenOdd: true)))
            ]
        case .radar:
            let sectors: [CGFloat] = [90, -30, 210]
            let spread: [CGFloat] = [0, 26, -26]
            let radii: [CGFloat] = [5.2, 3.0, 6.3]
            return marks.map { mark in
                let angle = (sectors[mark.state] + spread[mark.slot]) * .pi / 180
                let radius = radii[mark.slot]
                var shape = Mark(
                    center: CGPoint(x: 9 + cos(angle) * radius, y: 9 + sin(angle) * radius), path: circle(.zero, 1.45))
                shape.glow = true
                if mark.state == 1 { shape.ambient = .glow }
                return item(mark, shape)
            }
        case .meter:
            guard n > 0 else { return [] }
            let gap: CGFloat = 1.2
            let segment = (18 - CGFloat(n - 1) * gap) / CGFloat(n)
            return marks.enumerated().map { index, mark in
                let y = 18 - CGFloat(index + 1) * segment - CGFloat(index) * gap
                return Item(
                    key: key(mark), state: mark.state, kind: .pill(CGRect(x: 1, y: y, width: 6, height: segment)))
            }
        default:
            return []
        }
    }

    // MARK: Decor and quiet

    static func sceneDecor(style: StatusLightStyle) -> [StatusLightGeometry.Decor] {
        typealias Decor = StatusLightGeometry.Decor
        switch style {
        case .gauge:
            let track = track(style: style)
            let ticks = CGMutablePath()
            for step in 0...4 {
                let angle = track.angle(at: CGFloat(step) / 4)
                ticks.move(to: CGPoint(x: track.center.x + cos(angle) * 8.6, y: track.center.y + sin(angle) * 8.6))
                ticks.addLine(to: CGPoint(x: track.center.x + cos(angle) * 9.4, y: track.center.y + sin(angle) * 9.4))
            }
            return [
                Decor(path: track.path, lineWidth: 1, filled: false, alpha: 0.4),
                Decor(path: ticks, lineWidth: 0.8, filled: false, alpha: 0.5),
                Decor(path: circle(track.center, 1.4), filled: true),
            ]
        case .matrix:
            let dots = CGMutablePath()
            for row in 0..<3 {
                for column in 0..<3 {
                    dots.addPath(circle(CGPoint(x: 3.5 + CGFloat(column) * 5.5, y: 14.5 - CGFloat(row) * 5.5), 0.9))
                }
            }
            return [Decor(path: dots, filled: true, alpha: 0.5)]
        case .timeline:
            let tracks = CGMutablePath()
            for y in [14.0, 9.0, 4.0] as [CGFloat] {
                tracks.move(to: CGPoint(x: 1.6, y: y))
                tracks.addLine(to: CGPoint(x: 20.4, y: y))
            }
            return [Decor(path: tracks, lineWidth: 1, filled: false, alpha: 0.35)]
        case .radar:
            let cross = CGMutablePath()
            cross.move(to: CGPoint(x: 9, y: 1.6))
            cross.addLine(to: CGPoint(x: 9, y: 16.4))
            cross.move(to: CGPoint(x: 1.6, y: 9))
            cross.addLine(to: CGPoint(x: 16.4, y: 9))
            return [
                Decor(path: circle(CGPoint(x: 9, y: 9), 7.8), lineWidth: 1.1, filled: false, alpha: 0.7),
                Decor(path: circle(CGPoint(x: 9, y: 9), 4.2), lineWidth: 0.7, filled: false, alpha: 0.35),
                Decor(path: cross, lineWidth: 0.6, filled: false, alpha: 0.3),
                Decor(path: circle(CGPoint(x: 9, y: 9), 0.9), filled: true),
            ]
        default:
            return []
        }
    }

    static func sceneQuiet(style: StatusLightStyle) -> Quiet? {
        switch style {
        case .badge:
            return Quiet(path: roundedRect(CGRect(x: 2, y: 2, width: 14, height: 14), 4), filled: false, lineWidth: 1.4)
        case .meter:
            return Quiet(
                path: roundedRect(CGRect(x: 1.6, y: 0.6, width: 4.8, height: 16.8), 2.4), filled: false, lineWidth: 1.2)
        default:
            return nil
        }
    }

    // MARK: Bitmap

    static func drawMark(_ mark: Mark, color: CGColor, in ctx: CGContext) {
        ctx.saveGState()
        ctx.translateBy(x: mark.center.x, y: mark.center.y)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.addPath(mark.path)
        if mark.stroked {
            ctx.setStrokeColor(color)
            ctx.setLineWidth(mark.lineWidth)
            ctx.strokePath()
        } else {
            ctx.setFillColor(color)
            ctx.fillPath(using: mark.evenOdd ? .evenOdd : .winding)
        }
        ctx.restoreGState()
    }

    // MARK: Path helpers

    static func circle(_ center: CGPoint, _ radius: CGFloat) -> CGPath {
        CGPath(
            ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2),
            transform: nil)
    }

    static func roundedRect(_ rect: CGRect, _ radius: CGFloat) -> CGPath {
        let r = min(radius, rect.width / 2, rect.height / 2)
        return CGPath(roundedRect: rect, cornerWidth: r, cornerHeight: r, transform: nil)
    }

    /// Bold digits centred on the origin, for the Badge cut-out.
    private static func textPath(_ text: String, size: CGFloat) -> CGPath {
        let font = NSFont.systemFont(ofSize: size, weight: .heavy) as CTFont
        let line = CTLineCreateWithAttributedString(
            NSAttributedString(string: text, attributes: [.font: font]))
        let path = CGMutablePath()
        for run in (CTLineGetGlyphRuns(line) as? [CTRun]) ?? [] {
            let count = CTRunGetGlyphCount(run)
            var glyphs = [CGGlyph](repeating: 0, count: count)
            var positions = [CGPoint](repeating: .zero, count: count)
            CTRunGetGlyphs(run, CFRange(location: 0, length: count), &glyphs)
            CTRunGetPositions(run, CFRange(location: 0, length: count), &positions)
            for index in 0..<count {
                guard let glyph = CTFontCreatePathForGlyph(font, glyphs[index], nil) else { continue }
                path.addPath(
                    glyph, transform: CGAffineTransform(translationX: positions[index].x, y: positions[index].y))
            }
        }
        let box = path.boundingBoxOfPath
        var center = CGAffineTransform(translationX: -box.midX, y: -box.midY)
        return path.copy(using: &center) ?? path
    }
}
