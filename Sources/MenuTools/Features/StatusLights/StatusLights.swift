import AppKit
import Combine

/// Menu bar status lights: three session lights (input, running, unseen ended) drawn in one of
/// several styles. Changes and panel opens animate; the timer runs only while an animation plays.

enum StatusLightStyle: String, CaseIterable, Identifiable {
    case ring = "Ring"
    case dots = "Dots"
    case stack = "Stack"
    case triad = "Triad"
    case bars = "Bars"
    case pie = "Pie"

    var id: String { rawValue }

    /// Transparent margin so a popping light and its halo are not clipped. Height stays at 22pt,
    /// the menu bar's thickness, so AppKit never scales the image down.
    static let padding = NSSize(width: 3, height: 2)

    /// Full image size: drawing area plus padding. Constant per style, so the item never changes width mid-animation.
    var canvas: NSSize {
        let content = contentSize
        return NSSize(
            width: content.width + Self.padding.width * 2, height: content.height + Self.padding.height * 2)
    }

    var contentSize: NSSize {
        switch self {
        case .ring, .triad, .pie: return NSSize(width: 18, height: 18)
        case .dots: return NSSize(width: 22, height: 18)
        case .stack: return NSSize(width: 10, height: 18)
        case .bars: return NSSize(width: 18, height: 18)
        }
    }

    /// Ring, Pie and Triad spin when the panel opens; the others run a wave through the lights.
    var spinsOnOpen: Bool { self == .ring || self == .pie || self == .triad }
}

/// Persisted choices (UserDefaults `StatusLightsEnabled`, `StatusLightStyle`, `StatusLightAnimations`). Publishes only on change.
@MainActor
final class StatusLightSettings: ObservableObject {
    static let shared = StatusLightSettings()

    @Published var style: StatusLightStyle {
        didSet {
            guard style != oldValue else { return }
            UserDefaults.standard.set(style.rawValue, forKey: "StatusLightStyle")
        }
    }

    /// On: the colour session lights. Off: the plain static icon picked in "Menu bar icon".
    @Published var enabled: Bool {
        didSet {
            guard enabled != oldValue else { return }
            UserDefaults.standard.set(enabled, forKey: "StatusLightsEnabled")
        }
    }

    @Published var animations: Bool {
        didSet {
            guard animations != oldValue else { return }
            UserDefaults.standard.set(animations, forKey: "StatusLightAnimations")
        }
    }

    /// Bumped by the Settings "Test" button; the menu bar plays a demo.
    @Published private(set) var demoToken = 0

    private init() {
        let defaults = UserDefaults.standard
        style = defaults.string(forKey: "StatusLightStyle").flatMap(StatusLightStyle.init(rawValue:)) ?? .ring
        animations =
            defaults.object(forKey: "StatusLightAnimations") == nil
            ? true : defaults.bool(forKey: "StatusLightAnimations")
        enabled =
            defaults.object(forKey: "StatusLightsEnabled") == nil ? true : defaults.bool(forKey: "StatusLightsEnabled")
    }

    func playDemo() { demoToken += 1 }
}

// MARK: - Frame model

/// One light in one frame.
struct StatusLightFrame {
    /// 0 = off, 1 = on (cross-faded in between).
    var level: CGFloat = 0
    /// Size multiplier (pop on change, wave on open).
    var scale: CGFloat = 1
    /// Expanding halo, 0...1 progress; nil when none.
    var halo: CGFloat?
}

enum StatusLightPalette {
    static let input = NSColor(srgbRed: 1.0, green: 0.624, blue: 0.039, alpha: 1)
    static let running = NSColor(srgbRed: 0.188, green: 0.820, blue: 0.345, alpha: 1)
    static let ended = NSColor(srgbRed: 0.039, green: 0.518, blue: 1.0, alpha: 1)
    static let all = [input, running, ended]
}

// MARK: - Renderer

enum StatusLightsRenderer {
    /// Bitmap image (status items composite drawing-handler images as templates until the app activates).
    /// `template` is used only for the resting quiet state, so the system tints it like any menu bar icon.
    static func image(
        style: StatusLightStyle, lights: [StatusLightFrame], rotation: CGFloat = 0, isDark: Bool,
        template: Bool = false, scale: CGFloat = 1
    ) -> NSImage {
        let size = style.canvas
        let image = NSImage(size: NSSize(width: size.width * scale, height: size.height * scale))
        image.lockFocus()
        if let ctx = NSGraphicsContext.current?.cgContext {
            ctx.scaleBy(x: scale, y: scale)
            ctx.translateBy(x: StatusLightStyle.padding.width, y: StatusLightStyle.padding.height)
            let off: NSColor = template ? .black : (isDark ? .white : .black)
            draw(style: style, lights: lights, rotation: rotation, off: off, in: ctx, size: style.contentSize)
        }
        image.unlockFocus()
        image.isTemplate = template
        image.accessibilityDescription = "MenuTools"
        return image
    }

    private static func draw(
        style: StatusLightStyle, lights: [StatusLightFrame], rotation: CGFloat, off: NSColor, in ctx: CGContext,
        size: NSSize
    ) {
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        func light(_ index: Int) -> StatusLightFrame { index < lights.count ? lights[index] : StatusLightFrame() }
        func on(_ index: Int) -> NSColor { StatusLightPalette.all[index] }

        switch style {
        case .ring, .pie:
            // 0° is east. Top is input, lower right is running, lower left is ended.
            let mids: [CGFloat] = [90, -30, 210]
            for index in 0..<3 {
                let item = light(index)
                let mid = (mids[index] + rotation) * .pi / 180
                if style == .ring {
                    let half: CGFloat = 27 * .pi / 180 * min(item.scale, 1.25)
                    let width = 3.3 * item.scale
                    if let halo = item.halo {
                        arc(
                            ctx, center, 5.85 + halo * 2.5, mid, half * 1.3, 2 * (1 - halo),
                            on(index).withAlphaComponent(0.8 * (1 - halo)))
                    }
                    arc(ctx, center, 5.85, mid, half, width, off.withAlphaComponent(1 - item.level))
                    arc(ctx, center, 5.85, mid, half, width, on(index).withAlphaComponent(item.level))
                } else {
                    let radius = 7.2 * min(item.scale, 1.2)
                    let half: CGFloat = 53 * .pi / 180
                    if let halo = item.halo {
                        wedge(
                            ctx, center, radius + halo * 2.5, mid, half, on(index).withAlphaComponent(0.45 * (1 - halo))
                        )
                    }
                    wedge(ctx, center, radius, mid, half, off.withAlphaComponent(1 - item.level))
                    wedge(ctx, center, radius, mid, half, on(index).withAlphaComponent(item.level))
                }
            }
        case .dots, .stack, .triad:
            let points: [CGPoint]
            let radius: CGFloat
            switch style {
            case .dots:
                points = [CGPoint(x: 4, y: 9), CGPoint(x: 11, y: 9), CGPoint(x: 18, y: 9)]
                radius = 2.9
            case .stack:
                points = [CGPoint(x: 5, y: 14.4), CGPoint(x: 5, y: 9), CGPoint(x: 5, y: 3.6)]
                radius = 2.35
            default:
                points = [CGPoint(x: 9, y: 13.4), CGPoint(x: 12.8, y: 6.8), CGPoint(x: 5.2, y: 6.8)]
                radius = 2.75
            }
            for index in 0..<3 {
                let item = light(index)
                var point = points[index]
                if rotation != 0 {
                    let theta = rotation * .pi / 180
                    let dx = point.x - center.x
                    let dy = point.y - center.y
                    point = CGPoint(
                        x: center.x + dx * cos(theta) - dy * sin(theta), y: center.y + dx * sin(theta) + dy * cos(theta)
                    )
                }
                let r = radius * item.scale
                if let halo = item.halo {
                    let hr = radius + halo * 2.6
                    ctx.setStrokeColor(on(index).withAlphaComponent(0.85 * (1 - halo)).cgColor)
                    ctx.setLineWidth(1.4 * (1 - halo) + 0.3)
                    ctx.strokeEllipse(in: CGRect(x: point.x - hr, y: point.y - hr, width: hr * 2, height: hr * 2))
                }
                let rect = CGRect(x: point.x - r, y: point.y - r, width: r * 2, height: r * 2)
                if item.level < 1 {
                    ctx.setStrokeColor(off.withAlphaComponent(1 - item.level).cgColor)
                    ctx.setLineWidth(1.3)
                    ctx.strokeEllipse(in: rect.insetBy(dx: 0.65, dy: 0.65))
                }
                if item.level > 0 {
                    ctx.setFillColor(on(index).withAlphaComponent(item.level).cgColor)
                    ctx.fillEllipse(in: rect)
                }
            }
        case .bars:
            let xs: [CGFloat] = [4, 9, 14]
            for index in 0..<3 {
                let item = light(index)
                let width: CGFloat = 3.2
                let height = 12 * item.scale
                let rect = CGRect(x: xs[index] - width / 2 + 0.5, y: 9 - height / 2, width: width, height: height)
                if let halo = item.halo {
                    let grow = halo * 2.3
                    let glow = CGPath(
                        roundedRect: rect.insetBy(dx: -grow, dy: -grow), cornerWidth: width / 2 + grow,
                        cornerHeight: width / 2 + grow, transform: nil)
                    ctx.addPath(glow)
                    ctx.setStrokeColor(on(index).withAlphaComponent(0.8 * (1 - halo)).cgColor)
                    ctx.setLineWidth(1)
                    ctx.strokePath()
                }
                let capsule = CGPath(
                    roundedRect: rect, cornerWidth: width / 2, cornerHeight: width / 2, transform: nil)
                if item.level < 1 {
                    let inset = CGPath(
                        roundedRect: rect.insetBy(dx: 0.6, dy: 0.6), cornerWidth: width / 2 - 0.6,
                        cornerHeight: width / 2 - 0.6, transform: nil)
                    ctx.addPath(inset)
                    ctx.setStrokeColor(off.withAlphaComponent(1 - item.level).cgColor)
                    ctx.setLineWidth(1.2)
                    ctx.strokePath()
                }
                if item.level > 0 {
                    ctx.addPath(capsule)
                    ctx.setFillColor(on(index).withAlphaComponent(item.level).cgColor)
                    ctx.fillPath()
                }
            }
        }
    }

    private static func arc(
        _ ctx: CGContext, _ center: CGPoint, _ radius: CGFloat, _ mid: CGFloat, _ half: CGFloat, _ width: CGFloat,
        _ color: NSColor
    ) {
        guard color.alphaComponent > 0.001 else { return }
        ctx.setLineWidth(width)
        ctx.setLineCap(.round)
        ctx.setStrokeColor(color.cgColor)
        ctx.beginPath()
        ctx.addArc(center: center, radius: radius, startAngle: mid - half, endAngle: mid + half, clockwise: false)
        ctx.strokePath()
    }

    private static func wedge(
        _ ctx: CGContext, _ center: CGPoint, _ radius: CGFloat, _ mid: CGFloat, _ half: CGFloat, _ color: NSColor
    ) {
        guard color.alphaComponent > 0.001 else { return }
        ctx.setFillColor(color.cgColor)
        ctx.beginPath()
        ctx.move(to: center)
        ctx.addArc(center: center, radius: radius, startAngle: mid - half, endAngle: mid + half, clockwise: false)
        ctx.closePath()
        ctx.fillPath()
    }
}

// MARK: - Live view (Core Animation)

/// The lights in the menu bar. Each light is a small layer tree (off shape, on shape, halo) and
/// every animation is a Core Animation animation, so frames are produced by the render server:
/// no timer, no bitmap per frame, no main-thread work while a light pops or the icon spins.
/// `StatusLightsRenderer` draws the same geometry as bitmaps for Settings and previews.
final class StatusLightsView: NSView {
    private struct Light {
        let group = CALayer()
        let off = CAShapeLayer()
        let on = CAShapeLayer()
        let halo = CAShapeLayer()
    }

    private let container = CALayer()
    private var lights: [Light] = []
    private(set) var style: StatusLightStyle = .ring
    private var states = [false, false, false]
    private var isDark = true

    override var isFlipped: Bool { false }

    init(style: StatusLightStyle) {
        super.init(frame: NSRect(origin: .zero, size: style.canvas))
        wantsLayer = true
        layer?.masksToBounds = false
        layer?.addSublayer(container)
        self.style = style
        build()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Clicks and drags go to the status button underneath.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        applyScale()
    }

    // MARK: Public

    func setStyle(_ style: StatusLightStyle) {
        guard style != self.style else { return }
        self.style = style
        setFrameSize(style.canvas)
        build()
    }

    func setDark(_ dark: Bool) {
        guard dark != isDark else { return }
        isDark = dark
        withoutActions {
            lights.forEach {
                $0.off.strokeColor = offColor.cgColor
                $0.off.fillColor = offFill
            }
        }
        lights.indices.forEach(styleOff)
    }

    /// New light states. Lights that changed pop on (with a halo) or shrink off.
    func set(_ newStates: [Bool], animated: Bool) {
        let old = states
        states = newStates
        for index in 0..<3 where old[index] != newStates[index] {
            let light = lights[index]
            withoutActions {
                light.on.opacity = newStates[index] ? 1 : 0
                light.off.opacity = newStates[index] ? 0 : 1
            }
            guard animated else { continue }
            fade(light.on, from: newStates[index] ? 0 : 1, to: newStates[index] ? 1 : 0, duration: 0.25)
            fade(light.off, from: newStates[index] ? 1 : 0, to: newStates[index] ? 0 : 1, duration: 0.25)
            if newStates[index] {
                pulse(light.group, values: [0.55, 1.32, 0.94, 1], times: [0, 0.4, 0.72, 1], duration: 0.5)
                ripple(light.halo)
            } else {
                pulse(light.group, values: [1, 0.68, 1], times: [0, 0.45, 1], duration: 0.4)
            }
        }
    }

    /// Panel opened: Ring, Pie and Triad spin once; Dots, Stack and Bars run a wave through the lights.
    func playOpen() {
        let now = CACurrentMediaTime()
        if style.spinsOnOpen {
            let spin = CABasicAnimation(keyPath: "transform.rotation.z")
            spin.fromValue = 0
            spin.toValue = -2 * Double.pi
            spin.duration = 0.6
            spin.timingFunction = CAMediaTimingFunction(controlPoints: 0.65, 0, 0.35, 1)
            container.add(spin, forKey: "open")
        }
        for (index, light) in lights.enumerated() {
            let wave = CAKeyframeAnimation(keyPath: "transform.scale")
            let peak = style.spinsOnOpen ? 1.12 : 1.32
            wave.values = [1, peak, 1]
            wave.keyTimes = [0, 0.45, 1]
            wave.duration = 0.34
            wave.beginTime = now + Double(index) * 0.1
            wave.timingFunctions = [
                CAMediaTimingFunction(name: .easeOut), CAMediaTimingFunction(name: .easeInEaseOut),
            ]
            light.group.add(wave, forKey: "wave")
        }
    }

    // MARK: Build

    private var offColor: NSColor { isDark ? .white : .black }

    /// Filled off shapes (Ring arcs are strokes, Pie wedges are fills); dot and bar styles show an outline.
    private var offFill: CGColor? { style == .pie ? offColor.cgColor : nil }

    private func build() {
        container.sublayers?.forEach { $0.removeFromSuperlayer() }
        lights = []
        let content = style.contentSize
        withoutActions {
            container.bounds = CGRect(origin: .zero, size: content)
            container.anchorPoint = CGPoint(x: 0.5, y: 0.5)
            container.position = CGPoint(
                x: StatusLightStyle.padding.width + content.width / 2,
                y: StatusLightStyle.padding.height + content.height / 2)
            for index in 0..<3 {
                let light = Light()
                let shape = StatusLightGeometry.shape(style: style, index: index)
                light.group.bounds = CGRect(x: -0.5, y: -0.5, width: 1, height: 1)
                light.group.position = shape.anchor
                for layer in [light.off, light.on, light.halo] {
                    layer.path = shape.path
                    layer.position = .zero
                    layer.bounds = .zero
                    layer.lineCap = .round
                    light.group.addSublayer(layer)
                }
                let color = StatusLightPalette.all[index].cgColor
                if shape.stroked {
                    light.on.fillColor = nil
                    light.on.strokeColor = color
                    light.on.lineWidth = shape.lineWidth
                } else {
                    light.on.fillColor = color
                    light.on.strokeColor = nil
                }
                light.off.path = shape.offPath
                light.off.lineWidth = shape.offLineWidth
                light.halo.path = shape.haloPath
                light.halo.fillColor = nil
                light.halo.strokeColor = color
                light.halo.lineWidth = 1.2
                light.halo.opacity = 0
                light.on.opacity = states[index] ? 1 : 0
                light.off.opacity = states[index] ? 0 : 1
                container.addSublayer(light.group)
                lights.append(light)
            }
        }
        lights.indices.forEach(styleOff)
        applyScale()
    }

    private func styleOff(_ index: Int) {
        let shape = StatusLightGeometry.shape(style: style, index: index)
        withoutActions {
            if shape.offFilled {
                lights[index].off.fillColor = offColor.cgColor
                lights[index].off.strokeColor = nil
            } else {
                lights[index].off.fillColor = nil
                lights[index].off.strokeColor = offColor.cgColor
            }
        }
    }

    private func applyScale() {
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        for light in lights {
            for layer in [light.group, light.off, light.on, light.halo] { layer.contentsScale = scale }
        }
        container.contentsScale = scale
    }

    // MARK: Animation helpers

    private func withoutActions(_ body: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        body()
        CATransaction.commit()
    }

    private func fade(_ layer: CALayer, from: Float, to: Float, duration: CFTimeInterval) {
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = from
        fade.toValue = to
        fade.duration = duration
        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(fade, forKey: "fade")
    }

    private func pulse(_ layer: CALayer, values: [Double], times: [NSNumber], duration: CFTimeInterval) {
        let pop = CAKeyframeAnimation(keyPath: "transform.scale")
        pop.values = values
        pop.keyTimes = times
        pop.duration = duration
        pop.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(pop, forKey: "pop")
    }

    private func ripple(_ halo: CAShapeLayer) {
        let grow = CABasicAnimation(keyPath: "transform.scale")
        grow.fromValue = 1
        grow.toValue = 1.9
        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = [0.9, 0.6, 0]
        fade.keyTimes = [0, 0.4, 1]
        let group = CAAnimationGroup()
        group.animations = [grow, fade]
        group.duration = 0.6
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        halo.add(group, forKey: "ripple")
    }
}

/// Shapes shared by the live view. Each light's path is relative to its anchor, so scaling the
/// light's layer pops it in place.
enum StatusLightGeometry {
    struct Shape {
        var anchor: CGPoint
        var path: CGPath
        var offPath: CGPath
        var haloPath: CGPath
        var stroked: Bool
        var lineWidth: CGFloat = 0
        var offFilled: Bool
        var offLineWidth: CGFloat
    }

    static func shape(style: StatusLightStyle, index: Int) -> Shape {
        let content = style.contentSize
        let center = CGPoint(x: content.width / 2, y: content.height / 2)
        switch style {
        case .ring:
            let mid = [90.0, -30.0, 210.0][index] * .pi / 180
            let radius: CGFloat = 5.85
            let anchor = CGPoint(x: center.x + cos(mid) * radius, y: center.y + sin(mid) * radius)
            let half = 27 * CGFloat.pi / 180
            let arc = CGMutablePath()
            arc.addArc(
                center: CGPoint(x: center.x - anchor.x, y: center.y - anchor.y), radius: radius,
                startAngle: mid - half, endAngle: mid + half, clockwise: false)
            let stroked = arc.copy(strokingWithWidth: 3.3, lineCap: .round, lineJoin: .round, miterLimit: 1)
            return Shape(
                anchor: anchor, path: arc, offPath: stroked, haloPath: stroked, stroked: true, lineWidth: 3.3,
                offFilled: true, offLineWidth: 0)
        case .pie:
            let mid = [90.0, -30.0, 210.0][index] * .pi / 180
            let radius: CGFloat = 7.2
            let anchor = CGPoint(x: center.x + cos(mid) * radius * 0.45, y: center.y + sin(mid) * radius * 0.45)
            let wedge = CGMutablePath()
            let origin = CGPoint(x: center.x - anchor.x, y: center.y - anchor.y)
            wedge.move(to: origin)
            wedge.addArc(
                center: origin, radius: radius, startAngle: mid - 53 * .pi / 180, endAngle: mid + 53 * .pi / 180,
                clockwise: false)
            wedge.closeSubpath()
            return Shape(
                anchor: anchor, path: wedge, offPath: wedge, haloPath: wedge, stroked: false, offFilled: true,
                offLineWidth: 0)
        case .dots, .stack, .triad:
            let points: [CGPoint]
            let radius: CGFloat
            switch style {
            case .dots:
                points = [CGPoint(x: 4, y: 9), CGPoint(x: 11, y: 9), CGPoint(x: 18, y: 9)]
                radius = 2.9
            case .stack:
                points = [CGPoint(x: 5, y: 14.4), CGPoint(x: 5, y: 9), CGPoint(x: 5, y: 3.6)]
                radius = 2.35
            default:
                points = [CGPoint(x: 9, y: 13.4), CGPoint(x: 12.8, y: 6.8), CGPoint(x: 5.2, y: 6.8)]
                radius = 2.75
            }
            let dot = CGPath(
                ellipseIn: CGRect(x: -radius, y: -radius, width: radius * 2, height: radius * 2), transform: nil)
            let ring = CGPath(
                ellipseIn: CGRect(
                    x: -radius + 0.65, y: -radius + 0.65, width: radius * 2 - 1.3, height: radius * 2 - 1.3),
                transform: nil)
            return Shape(
                anchor: points[index], path: dot, offPath: ring, haloPath: dot, stroked: false, offFilled: false,
                offLineWidth: 1.3)
        case .bars:
            let width: CGFloat = 3.2
            let height: CGFloat = 12
            let x = [4.0, 9.0, 14.0][index] + 0.5
            let rect = CGRect(x: -width / 2, y: -height / 2, width: width, height: height)
            let capsule = CGPath(
                roundedRect: rect, cornerWidth: width / 2, cornerHeight: width / 2, transform: nil)
            let outline = CGPath(
                roundedRect: rect.insetBy(dx: 0.6, dy: 0.6), cornerWidth: width / 2 - 0.6,
                cornerHeight: width / 2 - 0.6, transform: nil)
            return Shape(
                anchor: CGPoint(x: x, y: 9), path: capsule, offPath: outline, haloPath: capsule, stroked: false,
                offFilled: false, offLineWidth: 1.2)
        }
    }
}

// MARK: - Controller

/// Owns the live lights view on the status button. No timer: state changes and the open spin are
/// Core Animation animations. The demo is a handful of scheduled state changes.
@MainActor
final class StatusLightsAnimator {
    private weak var button: NSStatusBarButton?
    private let isDark: () -> Bool
    let view: StatusLightsView
    private var actual = [false, false, false]
    private var demoActive = false
    private var demoGeneration = 0
    private var cancellables = Set<AnyCancellable>()

    private var settings: StatusLightSettings { .shared }

    private var animates: Bool {
        settings.animations && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    init(button: NSStatusBarButton, isDark: @escaping () -> Bool) {
        self.button = button
        self.isDark = isDark
        view = StatusLightsView(style: StatusLightSettings.shared.style)
        view.autoresizingMask = []
        button.addSubview(view)
        settings.$style.dropFirst().removeDuplicates()
            .sink { [weak self] style in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        self.view.setStyle(style)
                        self.installPlaceholder()
                        self.playOpen()
                    }
                }
            }
            .store(in: &cancellables)
        settings.$demoToken.dropFirst()
            .sink { [weak self] _ in
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.playDemo() } }
            }
            .store(in: &cancellables)
        setActive(settings.enabled)
    }

    /// Lights on: a transparent placeholder image sizes the item and the view draws on top.
    /// Lights off: the view hides and the static icon takes over the button image.
    func setActive(_ active: Bool) {
        view.isHidden = !active
        if active {
            view.setDark(isDark())
            installPlaceholder()
        }
    }

    func update(input: Bool, running: Bool, ended: Bool) {
        actual = [input, running, ended]
        guard !demoActive else { return }
        view.set(actual, animated: animates)
    }

    func refresh(force: Bool = false) {
        view.setDark(isDark())
        if force { installPlaceholder() }
    }

    func playOpen() {
        guard animates, !view.isHidden else { return }
        view.playOpen()
    }

    /// Lights pop on one by one, hold, then return to the real state.
    func playDemo() {
        demoGeneration += 1
        let generation = demoGeneration
        demoActive = true
        view.set([false, false, false], animated: false)
        let steps: [(Double, [Bool])] = [
            (0.25, [true, false, false]), (0.7, [true, true, false]), (1.15, [true, true, true]),
            (2.2, [false, true, true]), (2.6, [false, false, true]), (3.0, [false, false, false]),
        ]
        for (delay, state) in steps {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, self.demoGeneration == generation else { return }
                self.view.set(state, animated: true)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.6) { [weak self] in
            guard let self, self.demoGeneration == generation else { return }
            self.demoActive = false
            self.view.set(self.actual, animated: true)
        }
    }

    private func installPlaceholder() {
        guard let button, settings.enabled else { return }
        let image = NSImage(size: view.style.canvas)
        image.isTemplate = true
        image.accessibilityDescription = "MenuTools"
        button.image = image
        button.needsLayout = true
    }
}
