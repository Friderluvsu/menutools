import AppKit

/// Count styles (Halo, Pills, Moons, Galaxy): one mark per session, up to 3 per state, laid out by
/// how many there are. One session alone fills the icon; more split it. Marks of one state sit
/// together (input, running, ended, in that order). Quiet shows a plain outline in the menu bar colour.
enum CountLayout {
    static let maxPerState = 3

    struct Item {
        enum Kind {
            /// Fractions of the ring, clockwise from the top.
            case arc(start: CGFloat, end: CGFloat)
            case pill(CGRect)
            /// Unit shape (circle or sparkle) scaled to `size` at `center`.
            case dot(center: CGPoint, size: CGFloat)
            /// Any shape, for the scene styles (`SceneLights.swift`).
            case mark(Mark)
        }

        let key: String
        let state: Int
        let kind: Kind
    }

    static let ringCenter = CGPoint(x: 9, y: 9)
    static let ringRadius: CGFloat = 5.9
    static let ringWidth: CGFloat = 3.3
    static let orbitRadius: CGFloat = 6.6

    /// Counts as received (up to 99 each); layouts cap marks themselves.
    static func raw(_ counts: [Int]) -> [Int] {
        (0..<3).map { index in min(max(index < counts.count ? counts[index] : 0, 0), 99) }
    }

    static func clamp(_ counts: [Int]) -> [Int] {
        (0..<3).map { index in min(max(index < counts.count ? counts[index] : 0, 0), maxPerState) }
    }

    /// (state, slot) for every mark, in drawing order.
    static func marks(_ counts: [Int]) -> [(state: Int, slot: Int)] {
        clamp(counts).enumerated().flatMap { state, count in (0..<count).map { (state, $0) } }
    }

    static func items(style: StatusLightStyle, counts: [Int]) -> [Item] {
        if style.isScene { return sceneItems(style: style, counts: raw(counts)) }
        let marks = marks(counts)
        let n = marks.count
        guard n > 0 else { return [] }
        func key(_ mark: (state: Int, slot: Int)) -> String { "\(mark.state)-\(mark.slot)" }

        switch style {
        case .halo:
            // The same small gap between every pair of arcs (the ring closes, so n gaps); one mark
            // is a closed ring.
            guard n > 1 else { return [Item(key: key(marks[0]), state: marks[0].state, kind: .arc(start: 0, end: 1))] }
            let gap: CGFloat = 0.022
            let length = (1 - CGFloat(n) * gap) / CGFloat(n)
            return marks.enumerated().map { index, mark in
                let start = gap / 2 + CGFloat(index) * (length + gap)
                return Item(key: key(mark), state: mark.state, kind: .arc(start: start, end: start + length))
            }
        case .pills:
            // One wide pill split into equal pills with the same small gap between all of them.
            let width = style.contentSize.width
            let height: CGFloat = 11
            let gap: CGFloat = 1.2
            let pill = (width - CGFloat(n - 1) * gap) / CGFloat(n)
            return marks.enumerated().map { index, mark in
                let x = CGFloat(index) * (pill + gap)
                return Item(
                    key: key(mark), state: mark.state,
                    kind: .pill(CGRect(x: x, y: 9 - height / 2, width: pill, height: height)))
            }
        case .moons:
            let size: CGFloat = n == 1 ? 2.7 : (n <= 3 ? 2.3 : (n <= 6 ? 1.85 : 1.5))
            return marks.enumerated().map { index, mark in
                let angle = .pi / 2 - CGFloat(index) / CGFloat(n) * 2 * .pi
                let center = CGPoint(
                    x: ringCenter.x + cos(angle) * orbitRadius, y: ringCenter.y + sin(angle) * orbitRadius)
                return Item(key: key(mark), state: mark.state, kind: .dot(center: center, size: size))
            }
        default:  // .galaxy
            let points = galaxyPoints(n)
            let size: CGFloat = [7.6, 4.8, 3.9, 3.3, 3.0, 2.7, 2.45, 2.25, 2.1][n - 1]
            return marks.enumerated().map { index, mark in
                Item(key: key(mark), state: mark.state, kind: .dot(center: points[index], size: size))
            }
        }
    }

    private static func galaxyPoints(_ n: Int) -> [CGPoint] {
        switch n {
        case 1: return [CGPoint(x: 9, y: 9)]
        case 2: return [CGPoint(x: 5.4, y: 12.2), CGPoint(x: 12.6, y: 5.8)]
        case 3: return [CGPoint(x: 9, y: 13.8), CGPoint(x: 13.6, y: 5.4), CGPoint(x: 4.4, y: 5.4)]
        default:
            // A ring of stars, first at the top, plus one in the middle when the count is odd.
            let middle = n.isMultiple(of: 2) ? 0 : 1
            let around = n - middle
            let radius: CGFloat = n <= 5 ? 5.8 : 6.4
            var points = (0..<around).map { index -> CGPoint in
                let angle = .pi / 2 - CGFloat(index) / CGFloat(around) * 2 * .pi
                return CGPoint(x: 9 + cos(angle) * radius, y: 9 + sin(angle) * radius)
            }
            if middle == 1 { points.append(CGPoint(x: 9, y: 9)) }
            return points
        }
    }

    // MARK: Shapes

    /// The track `.arc` fractions run along: centre, radius, start angle and clockwise sweep.
    struct Track {
        var center: CGPoint
        var radius: CGFloat
        var start: CGFloat
        var sweep: CGFloat
        var width: CGFloat

        var path: CGPath {
            let path = CGMutablePath()
            path.addArc(center: center, radius: radius, startAngle: start, endAngle: start - sweep, clockwise: true)
            return path
        }

        func angle(at fraction: CGFloat) -> CGFloat { start - fraction * sweep }
    }

    /// Halo: a full ring from the top, clockwise, so stroke fractions read like a clock. Gauge: a 240° dial.
    static func track(style: StatusLightStyle) -> Track {
        if style == .gauge {
            return Track(
                center: CGPoint(x: 9, y: 8), radius: 7, start: 210 * .pi / 180, sweep: 240 * .pi / 180, width: 2.3)
        }
        return Track(center: ringCenter, radius: ringRadius, start: .pi / 2, sweep: 2 * .pi, width: ringWidth)
    }

    static var ringPath: CGPath { track(style: .halo).path }

    /// Unit circle (Moons) or unit four-point star (Galaxy), scaled by the item size.
    static func unitPath(style: StatusLightStyle) -> CGPath {
        if style == .galaxy {
            let path = CGMutablePath()
            path.addLines(
                between: (0..<8).map { step in
                    let angle = CGFloat(step) * .pi / 4 + .pi / 2
                    let radius: CGFloat = step.isMultiple(of: 2) ? 1 : 0.3
                    return CGPoint(x: cos(angle) * radius, y: sin(angle) * radius)
                })
            path.closeSubpath()
            return path
        }
        return CGPath(ellipseIn: CGRect(x: -1, y: -1, width: 2, height: 2), transform: nil)
    }

    /// Shown in the menu bar colour while there is nothing to count.
    struct Quiet {
        var path: CGPath
        var filled: Bool
        var lineWidth: CGFloat = 0
    }

    static func quiet(style: StatusLightStyle) -> Quiet? {
        switch style {
        case .halo:
            return Quiet(path: ringPath, filled: false, lineWidth: 1.6)
        case .pills:
            let width = style.contentSize.width
            let rect = CGRect(x: 0.7, y: 9 - 5.5 + 0.7, width: width - 1.4, height: 11 - 1.4)
            return Quiet(
                path: CGPath(roundedRect: rect, cornerWidth: 4.8, cornerHeight: 4.8, transform: nil), filled: false,
                lineWidth: 1.3)
        case .galaxy:
            var transform = CGAffineTransform(translationX: 9, y: 9).scaledBy(x: 6.4, y: 6.4)
            return Quiet(path: unitPath(style: .galaxy).copy(using: &transform) ?? ringPath, filled: true)
        case .moons:
            return nil  // the planet and orbit decor stay
        default:
            return sceneQuiet(style: style)
        }
    }

    // MARK: Bitmap

    static func draw(style: StatusLightStyle, counts: [Int], off: NSColor, in ctx: CGContext) {
        ctx.setLineJoin(.round)
        for decor in StatusLightGeometry.decor(style: style) {
            ctx.addPath(decor.path)
            if decor.filled {
                ctx.setFillColor(off.withAlphaComponent(decor.alpha).cgColor)
                ctx.fillPath()
            } else {
                ctx.setStrokeColor(off.withAlphaComponent(decor.alpha).cgColor)
                ctx.setLineWidth(decor.lineWidth)
                ctx.strokePath()
            }
        }
        let items = items(style: style, counts: counts)
        if items.isEmpty, let quiet = quiet(style: style) {
            ctx.addPath(quiet.path)
            if quiet.filled {
                ctx.setFillColor(off.cgColor)
                ctx.fillPath()
            } else {
                ctx.setStrokeColor(off.cgColor)
                ctx.setLineWidth(quiet.lineWidth)
                ctx.strokePath()
            }
            return
        }
        let unit = unitPath(style: style)
        for item in items {
            let color = StatusLightPalette.all[item.state].cgColor
            switch item.kind {
            case .arc(let start, let end):
                ctx.saveGState()
                let track = track(style: style)
                let path = CGMutablePath()
                path.addArc(
                    center: track.center, radius: track.radius, startAngle: track.angle(at: start),
                    endAngle: track.angle(at: end), clockwise: true)
                ctx.addPath(path)
                ctx.setStrokeColor(color)
                ctx.setLineWidth(track.width)
                ctx.setLineCap(.butt)
                ctx.strokePath()
                ctx.restoreGState()
            case .pill(let rect):
                let radius = min(rect.width, rect.height) / 2
                ctx.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
                ctx.setFillColor(color)
                ctx.fillPath()
            case .dot(let center, let size):
                var transform = CGAffineTransform(translationX: center.x, y: center.y).scaledBy(x: size, y: size)
                if let path = unit.copy(using: &transform) {
                    ctx.addPath(path)
                    ctx.setFillColor(color)
                    ctx.fillPath()
                }
            case .mark(let mark):
                drawMark(mark, color: color, in: ctx)
            }
        }
    }
}
