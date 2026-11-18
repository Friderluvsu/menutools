import AppKit

/// Geometry for the newer status-light styles (Cube, Orbit, Pulse, Buddy, Stars, Venn, Signal,
/// Hive, Pixel, Lantern). Light order is always input, running, ended. Coordinates are in the
/// style's content box, y up. Each light path is relative to its anchor so a scale pops it in place.
/// `decor` is drawn under the lights in the menu bar colour and never changes colour.
extension StatusLightGeometry {
    struct Decor {
        var path: CGPath
        var lineWidth: CGFloat = 0
        var filled: Bool
        var alpha: CGFloat = 1
    }

    static func decor(style: StatusLightStyle) -> [Decor] {
        switch style {
        case .orbit, .moons:
            return [
                Decor(path: circle(CGPoint(x: 9, y: 9), 6.6), lineWidth: 0.8, filled: false, alpha: 0.45),
                Decor(path: circle(CGPoint(x: 9, y: 9), 2.6), filled: true),
            ]
        case .pulse:
            let line = CGMutablePath()
            line.move(to: CGPoint(x: 0.8, y: 9))
            line.addLine(to: CGPoint(x: 21.2, y: 9))
            return [Decor(path: line, lineWidth: 1.2, filled: false, alpha: 0.55)]
        case .buddy:
            let head = CGPath(
                roundedRect: CGRect(x: 2.2, y: 1.6, width: 13.6, height: 11.2), cornerWidth: 3.6, cornerHeight: 3.6,
                transform: nil)
            let antenna = CGMutablePath()
            antenna.move(to: CGPoint(x: 9, y: 12.8))
            antenna.addLine(to: CGPoint(x: 9, y: 14.5))
            return [
                Decor(path: head, lineWidth: 1.3, filled: false),
                Decor(path: antenna, lineWidth: 1.2, filled: false),
            ]
        case .constellation:
            let stars = constellationPoints
            let lines = CGMutablePath()
            for (a, b) in [(0, 1), (1, 2), (2, 0)] {
                let start = stars[a]
                let end = stars[b]
                let length = hypot(end.x - start.x, end.y - start.y)
                let trim: CGFloat = 2.7 / length
                lines.move(to: CGPoint(x: start.x + (end.x - start.x) * trim, y: start.y + (end.y - start.y) * trim))
                lines.addLine(
                    to: CGPoint(x: end.x - (end.x - start.x) * trim, y: end.y - (end.y - start.y) * trim))
            }
            return [Decor(path: lines, lineWidth: 0.8, filled: false, alpha: 0.45)]
        case .signal:
            return [Decor(path: circle(signalBase, 1.5), filled: true)]
        case .lantern:
            let cap = CGPath(
                roundedRect: CGRect(x: 3.5, y: 14.3, width: 5, height: 1.8), cornerWidth: 0.8, cornerHeight: 0.8,
                transform: nil)
            let base = CGMutablePath()
            base.move(to: CGPoint(x: 3, y: 0.9))
            base.addLine(to: CGPoint(x: 9, y: 0.9))
            return [
                Decor(path: cap, filled: true),
                Decor(path: base, lineWidth: 1.2, filled: false),
            ]
        default:
            return CountLayout.sceneDecor(style: style)
        }
    }

    static func extendedShape(style: StatusLightStyle, index: Int) -> Shape {
        switch style {
        case .cube:
            // Isometric cube: top face is input, right face running, left face ended.
            let r: CGFloat = 7.8
            let c = CGPoint(x: 9, y: 9)
            let dx = r * cos(.pi / 6)
            let top = CGPoint(x: 9, y: 9 + r)
            let upperRight = CGPoint(x: 9 + dx, y: 9 + r / 2)
            let lowerRight = CGPoint(x: 9 + dx, y: 9 - r / 2)
            let bottom = CGPoint(x: 9, y: 9 - r)
            let lowerLeft = CGPoint(x: 9 - dx, y: 9 - r / 2)
            let upperLeft = CGPoint(x: 9 - dx, y: 9 + r / 2)
            let faces = [
                [c, upperRight, top, upperLeft],
                [c, upperRight, lowerRight, bottom],
                [c, bottom, lowerLeft, upperLeft],
            ]
            let face = faces[index]
            let anchor = centroid(face)
            let fill = polygon(face.map { relative($0, anchor, scale: 0.8) })
            let outline = polygon(face.map { relative($0, anchor, scale: 0.74) })
            return Shape(
                anchor: anchor, path: fill, offPath: outline, haloPath: fill, stroked: false, offFilled: false,
                offLineWidth: 1.1)
        case .orbit:
            let angle = [90.0, -30.0, 210.0][index] * .pi / 180
            let anchor = CGPoint(x: 9 + cos(angle) * 6.6, y: 9 + sin(angle) * 6.6)
            return Shape(
                anchor: anchor, path: circle(.zero, 2.3), offPath: circle(.zero, 1.3), haloPath: circle(.zero, 2.3),
                stroked: false, offFilled: true, offLineWidth: 0)
        case .pulse:
            let path = CGMutablePath()
            let anchor: CGPoint
            switch index {
            case 0:
                anchor = CGPoint(x: 4.5, y: 9)
                path.addLines(between: [
                    CGPoint(x: 1.5, y: 9), CGPoint(x: 3.4, y: 9), CGPoint(x: 4.5, y: 16.4), CGPoint(x: 5.6, y: 9),
                    CGPoint(x: 7.5, y: 9),
                ])
            case 1:
                anchor = CGPoint(x: 11, y: 9)
                path.addLines(between: [
                    CGPoint(x: 8, y: 9), CGPoint(x: 9.1, y: 9), CGPoint(x: 9.7, y: 11.3), CGPoint(x: 10.3, y: 9),
                    CGPoint(x: 10.8, y: 9), CGPoint(x: 11.5, y: 2.2), CGPoint(x: 12.3, y: 15.4),
                    CGPoint(x: 12.9, y: 9), CGPoint(x: 14, y: 9),
                ])
            default:
                anchor = CGPoint(x: 17.5, y: 9)
                path.move(to: CGPoint(x: 14.5, y: 9))
                path.addLine(to: CGPoint(x: 15.6, y: 9))
                path.addQuadCurve(to: CGPoint(x: 19.4, y: 9), control: CGPoint(x: 17.5, y: 14.2))
                path.addLine(to: CGPoint(x: 20.5, y: 9))
            }
            var transform = CGAffineTransform(translationX: -anchor.x, y: -anchor.y)
            let local = path.copy(using: &transform) ?? path
            return Shape(
                anchor: anchor, path: local, offPath: CGMutablePath(), haloPath: local, stroked: true, lineWidth: 1.6,
                offFilled: false, offLineWidth: 0)
        case .buddy:
            switch index {
            case 0:
                return Shape(
                    anchor: CGPoint(x: 9, y: 15.9), path: circle(.zero, 1.75), offPath: circle(.zero, 1.15),
                    haloPath: circle(.zero, 1.75), stroked: false, offFilled: true, offLineWidth: 0)
            case 1:
                let eyes = CGMutablePath()
                eyes.addPath(circle(CGPoint(x: -2.8, y: 0), 1.45))
                eyes.addPath(circle(CGPoint(x: 2.8, y: 0), 1.45))
                return Shape(
                    anchor: CGPoint(x: 9, y: 8.4), path: eyes, offPath: eyes, haloPath: eyes, stroked: false,
                    offFilled: true, offLineWidth: 0)
            default:
                let smile = CGMutablePath()
                smile.move(to: CGPoint(x: -2.6, y: 0.7))
                smile.addQuadCurve(to: CGPoint(x: 2.6, y: 0.7), control: CGPoint(x: 0, y: -2.1))
                let flat = CGMutablePath()
                flat.move(to: CGPoint(x: -2.2, y: 0))
                flat.addLine(to: CGPoint(x: 2.2, y: 0))
                return Shape(
                    anchor: CGPoint(x: 9, y: 4.9), path: smile, offPath: flat, haloPath: smile, stroked: true,
                    lineWidth: 1.4, offFilled: false, offLineWidth: 1.2)
            }
        case .constellation:
            let star = sparkle(outer: 3.4, inner: 0.95)
            return Shape(
                anchor: constellationPoints[index], path: star, offPath: circle(.zero, 1.25), haloPath: star,
                stroked: false, offFilled: true, offLineWidth: 0)
        case .venn:
            return Shape(
                anchor: vennCenters[index], path: circle(.zero, 4.4), offPath: circle(.zero, 3.85),
                haloPath: circle(.zero, 4.4), stroked: false, offFilled: false, offLineWidth: 1.1, onAlpha: 0.72)
        case .signal:
            let radius = [12.2, 8.3, 4.4][index]
            let anchor = CGPoint(x: signalBase.x, y: signalBase.y + radius)
            let arc = CGMutablePath()
            let half: CGFloat = 42 * .pi / 180
            arc.addArc(
                center: CGPoint(x: 0, y: -radius), radius: radius, startAngle: .pi / 2 - half,
                endAngle: .pi / 2 + half, clockwise: false)
            let solid = arc.copy(strokingWithWidth: 2.3, lineCap: .round, lineJoin: .round, miterLimit: 1)
            return Shape(
                anchor: anchor, path: arc, offPath: solid, haloPath: solid, stroked: true, lineWidth: 2.3,
                offFilled: true, offLineWidth: 0)
        case .hive:
            let centers = [CGPoint(x: 9, y: 12.3), CGPoint(x: 12.2, y: 6.75), CGPoint(x: 5.8, y: 6.75)]
            return Shape(
                anchor: centers[index], path: hexagon(3.45), offPath: hexagon(3.0), haloPath: hexagon(3.45),
                stroked: false, offFilled: false, offLineWidth: 1.1)
        case .pixel:
            let y = [14.0, 9.0, 4.0][index]
            let on = CGMutablePath()
            let off = CGMutablePath()
            for x in [-5.0, 0.0, 5.0] {
                on.addPath(circle(CGPoint(x: x, y: 0), 1.65))
                off.addPath(circle(CGPoint(x: x, y: 0), 0.95))
            }
            return Shape(
                anchor: CGPoint(x: 9, y: y), path: on, offPath: off, haloPath: on, stroked: false, offFilled: true,
                offLineWidth: 0)
        case .lantern:
            // One glass: the most urgent light that is on shows (input above running above ended).
            let glass = CGRect(x: -4.5, y: -5.75, width: 9, height: 11.5)
            let fill = CGPath(roundedRect: glass, cornerWidth: 4, cornerHeight: 4, transform: nil)
            let outline = CGPath(
                roundedRect: glass.insetBy(dx: 0.6, dy: 0.6), cornerWidth: 3.4, cornerHeight: 3.4, transform: nil)
            return Shape(
                anchor: CGPoint(x: 6, y: 7.75), path: fill, offPath: outline, haloPath: fill, stroked: false,
                offFilled: false, offLineWidth: 1.2, zPosition: CGFloat(3 - index))
        default:
            return shape(style: style, index: index)
        }
    }

    /// Where Venn circles start when the panel opens (they slide together).
    static func slideOffset(style: StatusLightStyle, index: Int) -> CGPoint {
        guard style == .venn else { return .zero }
        let anchor = vennCenters[index]
        let center = CGPoint(x: 9, y: 8.6)
        return CGPoint(x: (anchor.x - center.x) * 1.1, y: (anchor.y - center.y) * 1.1)
    }

    // MARK: Points

    private static let constellationPoints = [
        CGPoint(x: 9.4, y: 14.8), CGPoint(x: 14.6, y: 5.0), CGPoint(x: 3.6, y: 4.2),
    ]
    private static let vennCenters = [CGPoint(x: 9, y: 11.3), CGPoint(x: 11.6, y: 6.9), CGPoint(x: 6.4, y: 6.9)]
    private static let signalBase = CGPoint(x: 9, y: 3.2)

    // MARK: Path helpers

    private static func circle(_ center: CGPoint, _ radius: CGFloat) -> CGPath {
        CGPath(
            ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2),
            transform: nil)
    }

    private static func polygon(_ points: [CGPoint]) -> CGPath {
        let path = CGMutablePath()
        path.addLines(between: points)
        path.closeSubpath()
        return path
    }

    private static func centroid(_ points: [CGPoint]) -> CGPoint {
        let sum = points.reduce(CGPoint.zero) { CGPoint(x: $0.x + $1.x, y: $0.y + $1.y) }
        return CGPoint(x: sum.x / CGFloat(points.count), y: sum.y / CGFloat(points.count))
    }

    private static func relative(_ point: CGPoint, _ anchor: CGPoint, scale: CGFloat) -> CGPoint {
        CGPoint(x: (point.x - anchor.x) * scale, y: (point.y - anchor.y) * scale)
    }

    private static func hexagon(_ radius: CGFloat) -> CGPath {
        polygon(
            (0..<6).map { step in
                let angle = CGFloat(step) * .pi / 3 + .pi / 2
                return CGPoint(x: cos(angle) * radius, y: sin(angle) * radius)
            })
    }

    private static func sparkle(outer: CGFloat, inner: CGFloat) -> CGPath {
        polygon(
            (0..<8).map { step in
                let angle = CGFloat(step) * .pi / 4 + .pi / 2
                let radius = step.isMultiple(of: 2) ? outer : inner
                return CGPoint(x: cos(angle) * radius, y: sin(angle) * radius)
            })
    }
}

// MARK: - Bitmap drawing for the newer styles

extension StatusLightsRenderer {
    /// Same shapes as the live view, drawn from `StatusLightGeometry`.
    static func drawShapes(
        style: StatusLightStyle, lights: [StatusLightFrame], rotation: CGFloat, off: NSColor, in ctx: CGContext,
        size: NSSize
    ) {
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        ctx.saveGState()
        ctx.translateBy(x: center.x, y: center.y)
        ctx.rotate(by: rotation * .pi / 180)
        ctx.translateBy(x: -center.x, y: -center.y)
        ctx.setLineCap(.round)
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

        let shapes = (0..<3).map { StatusLightGeometry.extendedShape(style: style, index: $0) }
        for index in (0..<3).sorted(by: { shapes[$0].zPosition < shapes[$1].zPosition }) {
            let shape = shapes[index]
            let item = index < lights.count ? lights[index] : StatusLightFrame()
            let color = StatusLightPalette.all[index]
            ctx.saveGState()
            ctx.translateBy(x: shape.anchor.x, y: shape.anchor.y)
            ctx.scaleBy(x: item.scale, y: item.scale)
            if let halo = item.halo {
                ctx.saveGState()
                ctx.scaleBy(x: 1 + halo * 0.9, y: 1 + halo * 0.9)
                ctx.addPath(shape.haloPath)
                ctx.setStrokeColor(color.withAlphaComponent(0.85 * (1 - halo)).cgColor)
                ctx.setLineWidth(1.2)
                ctx.strokePath()
                ctx.restoreGState()
            }
            if item.level < 1 {
                ctx.addPath(shape.offPath)
                if shape.offFilled {
                    ctx.setFillColor(off.withAlphaComponent(1 - item.level).cgColor)
                    ctx.fillPath()
                } else {
                    ctx.setStrokeColor(off.withAlphaComponent(1 - item.level).cgColor)
                    ctx.setLineWidth(shape.offLineWidth)
                    ctx.strokePath()
                }
            }
            if item.level > 0 {
                ctx.addPath(shape.path)
                let onColor = color.withAlphaComponent(item.level * CGFloat(shape.onAlpha))
                if shape.stroked {
                    ctx.setStrokeColor(onColor.cgColor)
                    ctx.setLineWidth(shape.lineWidth)
                    ctx.strokePath()
                } else {
                    ctx.setFillColor(onColor.cgColor)
                    ctx.fillPath()
                }
            }
            ctx.restoreGState()
        }
        ctx.restoreGState()
    }
}
