import AppKit

@MainActor
enum BatteryIconRenderer {
    static func render(
        percentage: Int,
        isCharging: Bool,
        isLowPowerMode: Bool,
        hasBattery: Bool = true,
        showPercentageNumber: Bool = false
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
                activeColor = NSColor(srgbRed: 0.98, green: 0.76, blue: 0.18, alpha: 1.0)
            } else if percentage <= 20 && !isCharging {
                // Red for low battery (<20%)
                activeColor = NSColor(srgbRed: 0.96, green: 0.28, blue: 0.28, alpha: 1.0)
            } else {
                // Green for normal operation / charging
                activeColor = NSColor(srgbRed: 0.22, green: 0.82, blue: 0.45, alpha: 1.0)
            }

            // 2. Draw background track ring
            context.setLineWidth(lineWidth)
            context.setLineCap(.round)
            context.setStrokeColor(NSColor.labelColor.withAlphaComponent(0.18).cgColor)
            context.addArc(center: center, radius: radius, startAngle: 0, endAngle: CGFloat.pi * 2, clockwise: false)
            context.strokePath()

            // 3. Draw foreground progress arc
            let pct = max(0.0, min(1.0, Double(percentage) / 100.0))
            if pct > 0 {
                context.setStrokeColor(activeColor.cgColor)
                // Start from top (90 degrees / pi/2), draw clockwise
                let startAngle = CGFloat.pi / 2.0
                let endAngle = startAngle - CGFloat(pct * Double.pi * 2.0)
                context.addArc(center: center, radius: radius, startAngle: startAngle, endAngle: endAngle, clockwise: true)
                context.strokePath()
            }

            // 4. Center glyph
            if isCharging {
                // Charging bolt glyph in center
                let config = NSImage.SymbolConfiguration(pointSize: 7.0, weight: .bold)
                if let bolt = NSImage(systemSymbolName: "bolt.fill", accessibilityDescription: nil)?
                    .withSymbolConfiguration(config) {
                    let boltRect = CGRect(x: center.x - 3.5, y: center.y - 4.5, width: 7.0, height: 9.0)
                    bolt.draw(in: boltRect, from: .zero, operation: .sourceOver, fraction: 1.0)
                }
            } else if showPercentageNumber && percentage < 100 {
                // Tiny percentage text
                let font = NSFont.monospacedDigitSystemFont(ofSize: 6.5, weight: .bold)
                let text = "\(percentage)" as NSString
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: font,
                    .foregroundColor: NSColor.labelColor
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
}
