import AppKit

@MainActor
enum BatteryIconRenderer {
    static func renderBar(
        percentage: Int,
        isCharging: Bool,
        isLowPowerMode: Bool,
        showPercentage: Bool = false,
        showPercentSymbol: Bool = true,
        isDarkMode: Bool = true
    ) -> NSImage {
        let canvasSize: NSSize
        let barOriginX: CGFloat
        let textToDraw: (text: NSString, attrs: [NSAttributedString.Key: Any], point: CGPoint)?

        if showPercentage {
            let text = (showPercentSymbol ? "\(percentage)%" : "\(percentage)") as NSString
            let font = NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .regular)
            let textColor = isDarkMode ? NSColor.white : NSColor(white: 0.0, alpha: 0.85)
            let textAttrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: textColor,
            ]
            let textSize = text.size(withAttributes: textAttrs)
            let textWidth = textSize.width
            let spacing: CGFloat = 5.0
            canvasSize = NSSize(width: textWidth + spacing + 26.5, height: 18.0)
            barOriginX = textWidth + spacing
            let textPoint = CGPoint(x: 0, y: (18.0 - textSize.height) / 2.0)
            textToDraw = (text, textAttrs, textPoint)
        } else {
            canvasSize = NSSize(width: 27.0, height: 18.0)
            barOriginX = 1.0
            textToDraw = nil
        }

        let image = NSImage(size: canvasSize, flipped: false) { _ in
            // 1. Draw percentage text if requested
            if let textInfo = textToDraw {
                textInfo.text.draw(at: textInfo.point, withAttributes: textInfo.attrs)
            }

            // 2. Battery Geometry: Body outer rect & terminal cap
            let bodyRect = CGRect(x: barOriginX, y: 3.25, width: 22.0, height: 11.5)
            let capRect = CGRect(x: bodyRect.maxX + 1.2, y: 6.75, width: 1.5, height: 4.5)
            let shellColor =
                isDarkMode
                ? NSColor(white: 1.0, alpha: 0.35)
                : NSColor(white: 0.0, alpha: 0.28)

            // Body outer rect stroke (lineWidth: 1.1, cornerRadius: 3.5)
            let lineWidth: CGFloat = 1.1
            let strokeRect = bodyRect.insetBy(dx: lineWidth / 2.0, dy: lineWidth / 2.0)
            let strokeRadius = 3.5 - (lineWidth / 2.0)
            let bodyPath = NSBezierPath(roundedRect: strokeRect, xRadius: strokeRadius, yRadius: strokeRadius)
            bodyPath.lineWidth = lineWidth
            shellColor.setStroke()
            bodyPath.stroke()

            // Terminal cap (width: 1.5, height: 4.5, cornerRadius: 1.0)
            let capPath = NSBezierPath(roundedRect: capRect, xRadius: 1.0, yRadius: 1.0)
            shellColor.setFill()
            capPath.fill()

            // 3. Cavity inner rect & fill
            let innerRect = bodyRect.insetBy(dx: 2.0, dy: 2.0)
            let clampedPct = CGFloat(max(0, min(100, percentage)))
            let fillWidth = max(percentage > 0 ? 1.5 : 0.0, innerRect.width * (clampedPct / 100.0))

            // State Colors (Apple System Palette)
            let fillColor: NSColor
            if isLowPowerMode {
                fillColor =
                    isDarkMode
                    ? NSColor(srgbRed: 1.0, green: 0.839, blue: 0.039, alpha: 1.0)
                    : NSColor(srgbRed: 0.85, green: 0.608, blue: 0.0, alpha: 1.0)
            } else if percentage <= 20 && !isCharging {
                fillColor =
                    isDarkMode
                    ? NSColor(srgbRed: 1.0, green: 0.271, blue: 0.227, alpha: 1.0)
                    : NSColor(srgbRed: 0.843, green: 0.0, blue: 0.082, alpha: 1.0)
            } else if isCharging {
                fillColor =
                    isDarkMode
                    ? NSColor(srgbRed: 0.188, green: 0.820, blue: 0.345, alpha: 1.0)
                    : NSColor(srgbRed: 0.141, green: 0.686, blue: 0.282, alpha: 1.0)
            } else {
                fillColor =
                    isDarkMode
                    ? NSColor.white
                    : NSColor(white: 0.0, alpha: 0.85)
            }

            if fillWidth > 0 {
                let innerFillRect = CGRect(
                    x: innerRect.minX, y: innerRect.minY, width: fillWidth, height: innerRect.height)
                let fillCornerRadius = min(2.0, fillWidth / 2.0)
                let fillPath = NSBezierPath(
                    roundedRect: innerFillRect, xRadius: fillCornerRadius, yRadius: fillCornerRadius)
                fillColor.setFill()
                fillPath.fill()
            }

            // 4. Centered charging bolt
            if isCharging {
                let boltColor: NSColor = isDarkMode ? .white : (percentage > 40 ? .white : .black)
                let baseConfig = NSImage.SymbolConfiguration(pointSize: 6.8, weight: .bold)
                let colorConfig = NSImage.SymbolConfiguration(paletteColors: [boltColor])
                let config = baseConfig.applying(colorConfig)
                if let bolt = NSImage(systemSymbolName: "bolt.fill", accessibilityDescription: nil)?
                    .withSymbolConfiguration(config)
                {
                    let boltRect = CGRect(
                        x: bodyRect.midX - (bolt.size.width / 2.0),
                        y: bodyRect.midY - (bolt.size.height / 2.0),
                        width: bolt.size.width,
                        height: bolt.size.height
                    )
                    bolt.draw(in: boltRect, from: .zero, operation: .sourceOver, fraction: 1.0)
                }
            }

            return true
        }

        image.isTemplate = false
        return image
    }

    static func renderChargeOnly(
        percentage: Int,
        isCharging: Bool,
        isLowPowerMode: Bool,
        hasBattery: Bool = true,
        isDarkMode: Bool = true
    ) -> NSImage {
        let text = "\(percentage)" as NSString
        let font = NSFont.monospacedDigitSystemFont(ofSize: 13.0, weight: .regular)

        let textColor: NSColor
        if isLowPowerMode {
            textColor =
                isDarkMode
                ? NSColor(srgbRed: 1.0, green: 0.839, blue: 0.039, alpha: 1.0)
                : NSColor(srgbRed: 0.85, green: 0.608, blue: 0.0, alpha: 1.0)
        } else if percentage <= 20 && !isCharging {
            textColor =
                isDarkMode
                ? NSColor(srgbRed: 1.0, green: 0.271, blue: 0.227, alpha: 1.0)
                : NSColor(srgbRed: 0.843, green: 0.0, blue: 0.082, alpha: 1.0)
        } else {
            textColor =
                isDarkMode
                ? NSColor.white
                : NSColor(white: 0.0, alpha: 0.85)
        }

        let textAttrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: textColor,
        ]
        let textSize = text.size(withAttributes: textAttrs)

        let boltImage: NSImage?
        let boltSpacing: CGFloat = 2.5
        let boltWidth: CGFloat

        if isCharging {
            let boltColor =
                isDarkMode
                ? NSColor(srgbRed: 0.188, green: 0.820, blue: 0.345, alpha: 1.0)
                : NSColor(srgbRed: 0.141, green: 0.686, blue: 0.282, alpha: 1.0)
            let baseConfig = NSImage.SymbolConfiguration(pointSize: 9.0, weight: .bold)
            let colorConfig = NSImage.SymbolConfiguration(paletteColors: [boltColor])
            boltImage = NSImage(systemSymbolName: "bolt.fill", accessibilityDescription: nil)?
                .withSymbolConfiguration(baseConfig.applying(colorConfig))
            boltWidth = (boltImage?.size.width ?? 6.0) + boltSpacing
        } else {
            boltImage = nil
            boltWidth = 0.0
        }

        let horizontalPadding: CGFloat = 1.0
        let canvasWidth = boltWidth + textSize.width + (horizontalPadding * 2)
        let canvasSize = NSSize(width: canvasWidth, height: 18.0)

        let image = NSImage(size: canvasSize, flipped: false) { _ in
            if let bolt = boltImage {
                let boltRect = CGRect(
                    x: horizontalPadding,
                    y: (18.0 - bolt.size.height) / 2.0,
                    width: bolt.size.width,
                    height: bolt.size.height
                )
                bolt.draw(in: boltRect, from: .zero, operation: .sourceOver, fraction: 1.0)
            }

            let textPoint = CGPoint(
                x: horizontalPadding + boltWidth,
                y: (18.0 - textSize.height) / 2.0
            )
            text.draw(at: textPoint, withAttributes: textAttrs)
            return true
        }

        image.isTemplate = false
        return image
    }

    /// macOS 27 battery, matched pixel by pixel to the system item (2x screenshot):
    /// 23 × 12 pt solid body, charge fill edge to edge with a straight cut, no outline,
    /// detached 1.5 × 4 pt terminal 1 pt to the right. Digits (SF Pro 11 pt medium, slightly condensed,
    /// 8 pt digit height) are knocked out of the body. `isCharging` (pass "on AC power", as the system does)
    /// adds a knocked-out bolt after the digits; without digits it draws a large outlined bolt instead.
    static func renderGoldenGateBar(
        percentage: Int,
        isCharging: Bool,
        isLowPowerMode: Bool,
        showPercentInside: Bool,
        isDarkMode: Bool = true
    ) -> NSImage {
        let canvasSize = NSSize(width: 28.0, height: 18.0)
        let image = NSImage(size: canvasSize, flipped: false) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            let bodyRect = CGRect(x: 1.5, y: 3.0, width: 23.0, height: 12.0)
            let capRect = CGRect(x: bodyRect.maxX + 1.0, y: bodyRect.midY - 2.0, width: 1.5, height: 4.0)
            let bodyPath = continuousRoundedRect(bodyRect, radius: 4.0)

            let clampedPct = CGFloat(max(0, min(100, percentage)))
            let fillRect = CGRect(
                x: bodyRect.minX, y: bodyRect.minY,
                width: (bodyRect.width * clampedPct / 100.0 * 2.0).rounded(.down) / 2.0, height: bodyRect.height)

            // System values over a black bar: fill 241, empty 116, terminal 139 (of 255).
            let emptyColor = isDarkMode ? NSColor(white: 1.0, alpha: 0.45) : NSColor(white: 0.0, alpha: 0.32)
            let capColor = isDarkMode ? NSColor(white: 1.0, alpha: 0.54) : NSColor(white: 0.0, alpha: 0.38)
            let fillColor: NSColor
            if isLowPowerMode {
                fillColor = isDarkMode
                    ? NSColor(srgbRed: 1.0, green: 0.839, blue: 0.039, alpha: 1.0)
                    : NSColor(srgbRed: 0.85, green: 0.608, blue: 0.0, alpha: 1.0)
            } else if percentage <= 20 && !isCharging {
                fillColor = isDarkMode
                    ? NSColor(srgbRed: 1.0, green: 0.271, blue: 0.227, alpha: 1.0)
                    : NSColor(srgbRed: 0.843, green: 0.0, blue: 0.082, alpha: 1.0)
            } else {
                fillColor = isDarkMode ? NSColor(white: 1.0, alpha: 0.945) : NSColor(white: 0.0, alpha: 0.85)
            }

            // Terminal: flat on the left, rounded on the right.
            let cap = NSBezierPath()
            let r = capRect.width
            cap.move(to: CGPoint(x: capRect.minX, y: capRect.minY))
            cap.line(to: CGPoint(x: capRect.minX, y: capRect.maxY))
            cap.appendArc(
                withCenter: CGPoint(x: capRect.minX, y: capRect.maxY - r), radius: r,
                startAngle: 90, endAngle: 0, clockwise: true)
            cap.line(to: CGPoint(x: capRect.maxX, y: capRect.minY + r))
            cap.appendArc(
                withCenter: CGPoint(x: capRect.minX, y: capRect.minY + r), radius: r,
                startAngle: 0, endAngle: -90, clockwise: true)
            cap.close()
            capColor.setFill()
            cap.fill()

            ctx.saveGState()
            ctx.addPath(bodyPath)
            ctx.clip()
            ctx.setFillColor(emptyColor.cgColor)
            ctx.fill(CGRect(x: fillRect.maxX, y: bodyRect.minY, width: bodyRect.maxX - fillRect.maxX, height: bodyRect.height))
            ctx.setFillColor(fillColor.cgColor)
            ctx.fill(fillRect)
            ctx.restoreGState()

            if showPercentInside {
                // Knock the digits (and the small bolt on AC) out of the body so the menu bar shows through.
                ctx.saveGState()
                ctx.setBlendMode(.destinationOut)
                drawCenteredDigits("\(percentage)", withBolt: isCharging, in: ctx, bodyRect: bodyRect)
                ctx.restoreGState()
            } else if isCharging {
                drawGoldenGateBolt(in: ctx, bodyRect: bodyRect, color: fillColor)
            }
            return true
        }

        image.isTemplate = false
        return image
    }

    /// Digits centred on the body by glyph bounds, so the digit height (not the line height) is centred.
    /// On AC a bolt as tall as the digits follows them, and the pair is centred as a group.
    private static func drawCenteredDigits(_ text: String, withBolt: Bool, in ctx: CGContext, bodyRect: CGRect) {
        let gap: CGFloat = withBolt ? 0.75 : 0
        var fontSize: CGFloat = 11.0
        var line: CTLine
        var bounds: CGRect
        var boltWidth: CGFloat = 0
        repeat {
            let font = NSFont.systemFont(ofSize: fontSize, weight: .medium, width: NSFont.Width(rawValue: -0.1))
            let attributed = NSAttributedString(
                string: text, attributes: [.font: font, .foregroundColor: NSColor.black])
            line = CTLineCreateWithAttributedString(attributed)
            bounds = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
            boltWidth = withBolt ? bounds.height * 0.625 : 0
            fontSize -= 0.5
        } while bounds.width + gap + boltWidth > bodyRect.width - 3.0 && fontSize > 6

        let groupMinX = bodyRect.midX - (bounds.width + gap + boltWidth) / 2.0
        // 0.25 pt above centre, as the system draws them.
        let glyphMinY = bodyRect.midY - bounds.height / 2.0 + 0.25
        ctx.textMatrix = .identity
        ctx.textPosition = CGPoint(x: groupMinX - bounds.minX, y: glyphMinY - bounds.minY)
        CTLineDraw(line, ctx)
        if withBolt {
            // The sharp tips overshoot the digits by 0.5 pt so they read as tall after antialiasing.
            let box = CGRect(
                x: groupMinX + bounds.width + gap, y: glyphMinY - 0.5, width: boltWidth, height: bounds.height + 1.0)
            ctx.addPath(smallBoltPath(in: box))
            ctx.fillPath()
        }
    }

    /// The system's small bolt, traced from a 2x screenshot (5 × 8 pt next to 8 pt digits).
    private static func smallBoltPath(in box: CGRect) -> CGPath {
        let points: [(CGFloat, CGFloat)] = [(0.8, 1.0), (0.0, 0.47), (0.5, 0.47), (0.2, 0.0), (1.0, 0.59), (0.5, 0.59)]
        let path = CGMutablePath()
        path.addLines(between: points.map { CGPoint(x: box.minX + $0.0 * box.width, y: box.minY + $0.1 * box.height) })
        path.closeSubpath()
        return path
    }

    /// Bolt over the body: 1 pt outline knocked out, filled with the charge colour, overhanging the body.
    private static func drawGoldenGateBolt(in ctx: CGContext, bodyRect: CGRect, color: NSColor) {
        guard
            let symbol = NSImage(systemSymbolName: "bolt.fill", accessibilityDescription: nil)?
                .withSymbolConfiguration(
                    NSImage.SymbolConfiguration(pointSize: boltPointSize, weight: .regular)
                        .applying(NSImage.SymbolConfiguration(paletteColors: [color])))
        else { return }
        let size = symbol.size
        let rect = CGRect(
            x: bodyRect.midX - size.width / 2.0, y: bodyRect.midY - size.height / 2.0 + 0.5,
            width: size.width, height: size.height)
        let steps = 16
        for i in 0..<steps {
            let angle = CGFloat(i) / CGFloat(steps) * 2.0 * .pi
            symbol.draw(
                in: rect.offsetBy(dx: cos(angle), dy: sin(angle)),
                from: .zero, operation: .destinationOut, fraction: 1.0)
        }
        symbol.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1.0)
    }

    private static let boltPointSize: CGFloat = 12.5

    /// Apple's continuous ("squircle") corner, as drawn by `UIBezierPath(roundedRect:cornerRadius:)`.
    /// The corner spans 1.52866 × radius per side; the radius is clamped so two corners fit the short side.
    private static func continuousRoundedRect(_ rect: CGRect, radius: CGFloat) -> CGPath {
        let r = min(radius, min(rect.width, rect.height) / 2.0 / 1.52866483)
        let path = CGMutablePath()
        // One corner in a local frame where the corner sits at the origin and the edges run along +x and +y.
        func corner(_ origin: CGPoint, _ ux: CGVector, _ uy: CGVector) {
            func p(_ a: CGFloat, _ b: CGFloat) -> CGPoint {
                CGPoint(x: origin.x + ux.dx * a * r + uy.dx * b * r, y: origin.y + ux.dy * a * r + uy.dy * b * r)
            }
            path.addLine(to: p(1.52866483, 0))
            path.addCurve(to: p(0.66993427, 0.06549600), control1: p(1.08849323, 0), control2: p(0.86840689, 0))
            path.addCurve(
                to: p(0.06549600, 0.66993427), control1: p(0.37282392, 0.16905899),
                control2: p(0.16905899, 0.37282392))
            path.addCurve(to: p(0, 1.52866483), control1: p(0, 0.86840689), control2: p(0, 1.08849323))
        }
        path.move(to: CGPoint(x: rect.minX + 1.52866483 * r, y: rect.maxY))
        corner(CGPoint(x: rect.maxX, y: rect.maxY), CGVector(dx: -1, dy: 0), CGVector(dx: 0, dy: -1))
        corner(CGPoint(x: rect.maxX, y: rect.minY), CGVector(dx: 0, dy: 1), CGVector(dx: -1, dy: 0))
        corner(CGPoint(x: rect.minX, y: rect.minY), CGVector(dx: 1, dy: 0), CGVector(dx: 0, dy: 1))
        corner(CGPoint(x: rect.minX, y: rect.maxY), CGVector(dx: 0, dy: -1), CGVector(dx: 1, dy: 0))
        path.closeSubpath()
        return path
    }

    static func renderRing(
        percentage: Int,
        isCharging: Bool,
        isLowPowerMode: Bool,
        hasBattery: Bool = true,
        showPercentageNumber: Bool = false,
        isDarkMode: Bool = true
    ) -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }

            let center = CGPoint(x: rect.midX, y: rect.midY)
            let radius: CGFloat = 6.8
            let lineWidth: CGFloat = 2.0

            // 1. Determine active tint color
            let activeColor: NSColor
            if isLowPowerMode {
                // Yellow for macOS Low Power Mode
                activeColor =
                    isDarkMode
                    ? NSColor(srgbRed: 1.0, green: 0.80, blue: 0.18, alpha: 1.0)
                    : NSColor(srgbRed: 0.85, green: 0.60, blue: 0.05, alpha: 1.0)
            } else if percentage <= 20 && !isCharging {
                // Red for low battery (<20%)
                activeColor =
                    isDarkMode
                    ? NSColor(srgbRed: 1.0, green: 0.30, blue: 0.30, alpha: 1.0)
                    : NSColor(srgbRed: 0.85, green: 0.18, blue: 0.18, alpha: 1.0)
            } else {
                // Green for normal operation / charging
                activeColor =
                    isDarkMode
                    ? NSColor(srgbRed: 0.22, green: 0.85, blue: 0.45, alpha: 1.0)
                    : NSColor(srgbRed: 0.12, green: 0.65, blue: 0.30, alpha: 1.0)
            }

            // 2. Draw background track ring
            context.setLineWidth(lineWidth)
            context.setLineCap(.round)
            let trackColor =
                isDarkMode
                ? NSColor.white.withAlphaComponent(0.24)
                : NSColor.black.withAlphaComponent(0.20)
            context.setStrokeColor(trackColor.cgColor)
            context.addArc(center: center, radius: radius, startAngle: 0, endAngle: CGFloat.pi * 2, clockwise: false)
            context.strokePath()

            // 3. Draw foreground progress arc
            let pct = max(0.0, min(1.0, Double(percentage) / 100.0))
            if pct > 0 {
                context.setStrokeColor(activeColor.cgColor)
                // Start from top (90 degrees / pi/2), draw clockwise
                let startAngle = CGFloat.pi / 2.0
                let endAngle = startAngle - CGFloat(pct * Double.pi * 2.0)
                context.addArc(
                    center: center, radius: radius, startAngle: startAngle, endAngle: endAngle, clockwise: true)
                context.strokePath()
            }

            // 4. Center glyph
            if isCharging {
                // Charging bolt glyph in center with high contrast palette
                let baseConfig = NSImage.SymbolConfiguration(pointSize: 7.0, weight: .bold)
                let colorConfig = NSImage.SymbolConfiguration(paletteColors: [isDarkMode ? .white : .black])
                let config = baseConfig.applying(colorConfig)
                if let bolt = NSImage(systemSymbolName: "bolt.fill", accessibilityDescription: nil)?
                    .withSymbolConfiguration(config)
                {
                    let boltRect = CGRect(x: center.x - 3.5, y: center.y - 4.5, width: 7.0, height: 9.0)
                    bolt.draw(in: boltRect, from: .zero, operation: .sourceOver, fraction: 1.0)
                }
            } else if showPercentageNumber && percentage < 100 {
                // Tiny percentage text
                let font = NSFont.monospacedDigitSystemFont(ofSize: 6.5, weight: .bold)
                let text = "\(percentage)" as NSString
                let textColor = isDarkMode ? NSColor.white : NSColor.black.withAlphaComponent(0.88)
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: font,
                    .foregroundColor: textColor,
                ]
                let textSize = text.size(withAttributes: attrs)
                let textRect = CGRect(
                    x: center.x - (textSize.width / 2.0),
                    y: center.y - (textSize.height / 2.0) - 0.5,
                    width: textSize.width,
                    height: textSize.height
                )
                text.draw(in: textRect, withAttributes: attrs)
            }

            return true
        }

        image.isTemplate = false
        return image
    }

    static func render(
        percentage: Int,
        isCharging: Bool,
        isLowPowerMode: Bool,
        hasBattery: Bool = true,
        showPercentageNumber: Bool = false,
        isDarkMode: Bool = true
    ) -> NSImage {
        renderRing(
            percentage: percentage,
            isCharging: isCharging,
            isLowPowerMode: isLowPowerMode,
            hasBattery: hasBattery,
            showPercentageNumber: showPercentageNumber,
            isDarkMode: isDarkMode
        )
    }
}

extension NSFont {
    fileprivate static func systemFont(
        ofSize size: CGFloat,
        weight: NSFont.Weight,
        design: NSFontDescriptor.SystemDesign
    ) -> NSFont {
        let base = NSFont.systemFont(ofSize: size, weight: weight)
        if let descriptor = base.fontDescriptor.withDesign(design),
            let font = NSFont(descriptor: descriptor, size: size)
        {
            return font
        }
        return NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight)
    }
}
