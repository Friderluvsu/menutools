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

    /// macOS 27 battery: translucent body, white charge fill, percentage knocked out of the fill
    /// (dark over the charge, light over the empty part). Geometry measured from the system item:
    /// 23 × 12 pt body, 1.5 × 4.5 pt terminal.
    static func renderGoldenGateBar(
        percentage: Int,
        isCharging: Bool,
        isLowPowerMode: Bool,
        showPercentInside: Bool,
        isDarkMode: Bool = true
    ) -> NSImage {
        let canvasSize = NSSize(width: 28.0, height: 18.0)
        let image = NSImage(size: canvasSize, flipped: false) { _ in
            let bodyRect = CGRect(x: 1.5, y: 3.0, width: 23.0, height: 12.0)
            let capRect = CGRect(x: bodyRect.maxX + 0.75, y: bodyRect.midY - 2.25, width: 1.5, height: 4.5)
            let bodyRadius: CGFloat = 4.0
            let inset: CGFloat = 1.5
            let innerRect = bodyRect.insetBy(dx: inset, dy: inset)

            let clampedPct = CGFloat(max(0, min(100, percentage)))
            let fillWidth = max(percentage > 0 ? 2.0 : 0.0, innerRect.width * (clampedPct / 100.0))
            let fillRect = CGRect(x: innerRect.minX, y: innerRect.minY, width: fillWidth, height: innerRect.height)

            // Shell: faint rim + translucent empty interior
            let rimColor = isDarkMode ? NSColor(white: 1.0, alpha: 0.18) : NSColor(white: 0.0, alpha: 0.30)
            let emptyColor = isDarkMode ? NSColor(white: 1.0, alpha: 0.42) : NSColor(white: 0.0, alpha: 0.22)
            let bodyPath = NSBezierPath(roundedRect: bodyRect.insetBy(dx: 0.5, dy: 0.5), xRadius: bodyRadius, yRadius: bodyRadius)
            emptyColor.setFill()
            bodyPath.fill()
            bodyPath.lineWidth = 1.0
            rimColor.setStroke()
            bodyPath.stroke()
            let capPath = NSBezierPath(roundedRect: capRect, xRadius: 0.75, yRadius: 0.75)
            rimColor.setFill()
            capPath.fill()

            // Charge fill colors (Apple system palette)
            let fillColor: NSColor
            let inkOnFill: NSColor
            if isLowPowerMode {
                fillColor = isDarkMode
                    ? NSColor(srgbRed: 1.0, green: 0.839, blue: 0.039, alpha: 1.0)
                    : NSColor(srgbRed: 0.85, green: 0.608, blue: 0.0, alpha: 1.0)
                inkOnFill = .black
            } else if percentage <= 20 && !isCharging {
                fillColor = isDarkMode
                    ? NSColor(srgbRed: 1.0, green: 0.271, blue: 0.227, alpha: 1.0)
                    : NSColor(srgbRed: 0.843, green: 0.0, blue: 0.082, alpha: 1.0)
                inkOnFill = .white
            } else if isCharging {
                fillColor = isDarkMode
                    ? NSColor(srgbRed: 0.188, green: 0.820, blue: 0.345, alpha: 1.0)
                    : NSColor(srgbRed: 0.141, green: 0.686, blue: 0.282, alpha: 1.0)
                inkOnFill = .black
            } else {
                fillColor = isDarkMode ? NSColor(white: 1.0, alpha: 0.95) : NSColor(white: 0.0, alpha: 0.85)
                inkOnFill = isDarkMode ? .black : .white
            }
            let inkOnEmpty: NSColor = isDarkMode ? .white : .black

            if fillWidth > 0 {
                let fillPath = NSBezierPath(
                    roundedRect: fillRect,
                    xRadius: min(2.0, fillWidth / 2.0),
                    yRadius: min(2.0, fillWidth / 2.0)
                )
                fillColor.setFill()
                fillPath.fill()
            }

            // Content: percentage (and bolt when charging), knocked out of the fill
            let drawContent = { (ink: NSColor) in
                let font = NSFont.systemFont(ofSize: 9.5, weight: .bold, design: .rounded)
                let bolt: NSImage? = isCharging
                    ? NSImage(systemSymbolName: "bolt.fill", accessibilityDescription: nil)?
                        .withSymbolConfiguration(
                            NSImage.SymbolConfiguration(pointSize: 6.5, weight: .bold)
                                .applying(NSImage.SymbolConfiguration(paletteColors: [ink])))
                    : nil

                var textWidth: CGFloat = 0
                var textHeight: CGFloat = 0
                let text = showPercentInside ? "\(percentage)" as NSString : nil
                let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: ink]
                if let text {
                    let size = text.size(withAttributes: attrs)
                    textWidth = size.width
                    textHeight = size.height
                }
                let gap: CGFloat = text != nil && bolt != nil ? 1.0 : 0
                let boltWidth = bolt?.size.width ?? 0
                let groupWidth = textWidth + gap + boltWidth
                var x = bodyRect.midX - groupWidth / 2.0

                if let text {
                    text.draw(
                        in: CGRect(x: x, y: bodyRect.midY - textHeight / 2.0, width: textWidth, height: textHeight),
                        withAttributes: attrs)
                    x += textWidth + gap
                }
                if let bolt {
                    bolt.draw(
                        in: CGRect(x: x, y: bodyRect.midY - bolt.size.height / 2.0, width: bolt.size.width,
                            height: bolt.size.height),
                        from: .zero, operation: .sourceOver, fraction: 1.0)
                }
            }

            if showPercentInside || isCharging {
                NSGraphicsContext.saveGraphicsState()
                NSBezierPath(rect: fillRect).addClip()
                drawContent(inkOnFill)
                NSGraphicsContext.restoreGraphicsState()

                // Empty part of the body = body minus the fill
                let emptyClip = NSBezierPath(rect: bodyRect)
                emptyClip.appendRect(fillRect)
                emptyClip.windingRule = .evenOdd
                NSGraphicsContext.saveGraphicsState()
                emptyClip.addClip()
                drawContent(inkOnEmpty)
                NSGraphicsContext.restoreGraphicsState()
            }

            return true
        }

        image.isTemplate = false
        return image
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
