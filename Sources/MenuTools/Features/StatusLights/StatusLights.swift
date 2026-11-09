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
    case cube = "Cube"
    case orbit = "Orbit"
    case pulse = "Pulse"
    case buddy = "Buddy"
    case constellation = "Stars"
    case venn = "Venn"
    case signal = "Signal"
    case hive = "Hive"
    case pixel = "Pixel"
    case lantern = "Lantern"
    case halo = "Halo"
    case pills = "Pills"
    case moons = "Moons"
    case galaxy = "Galaxy"
    case gauge = "Gauge"
    case matrix = "Matrix"
    case timeline = "Timeline"
    case badge = "Badge"
    case radar = "Radar"
    case meter = "Meter"

    var id: String { rawValue }

    /// Picker sections.
    enum Group: String, CaseIterable {
        case lights = "Lights"
        case counts = "Counts"
        case pro = "Professional"
    }

    var group: Group {
        switch self {
        case .halo, .pills, .moons, .galaxy: return .counts
        case .gauge, .matrix, .timeline, .badge, .radar, .meter: return .pro
        default: return .lights
        }
    }

    /// One mark per session (up to 3 per state) instead of one light per state; see `CountLayout`.
    var isCounting: Bool { group != .lights }

    /// Count styles drawn as little pictures (`SceneLights.swift`).
    var isScene: Bool { group == .pro }

    /// The first six styles have their own bitmap drawing; the rest draw from `StatusLightGeometry`.
    var isClassic: Bool { [.ring, .dots, .stack, .triad, .bars, .pie].contains(self) }

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
        case .pulse: return NSSize(width: 22, height: 18)
        case .lantern: return NSSize(width: 12, height: 18)
        case .pills: return NSSize(width: 20, height: 18)
        case .timeline: return NSSize(width: 22, height: 18)
        case .meter: return NSSize(width: 8, height: 18)
        default: return NSSize(width: 18, height: 18)
        }
    }

    /// What plays when the panel opens.
    var openMotion: StatusLightOpenMotion {
        switch self {
        case .ring, .pie, .triad, .cube, .orbit, .halo, .moons, .galaxy: return .spin
        case .signal: return .waveInward
        case .buddy: return .blink
        case .venn: return .slide
        case .hive: return .flip
        case .radar: return .sweep
        default: return .wave
        }
    }

    var spinsOnOpen: Bool { openMotion == .spin }
}

enum StatusLightOpenMotion {
    /// The whole icon turns once.
    case spin
    /// Each light swells in turn (input first).
    case wave
    /// Wave from the last light to the first (Signal: inner arc outward).
    case waveInward
    /// Buddy's eyes close and open; the antenna pops.
    case blink
    /// Venn circles slide in from outside.
    case slide
    /// Hive tiles flip one after another.
    case flip
    /// Radar: a beam turns once around the dial.
    case sweep
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

    /// Quiet icon makes a small gesture about once a minute; a long input wait gets a reminder pop.
    @Published var idleLife: Bool {
        didSet {
            guard idleLife != oldValue else { return }
            UserDefaults.standard.set(idleLife, forKey: "StatusLightIdleLife")
        }
    }

    /// Extras: a hairline that fills over an hour of continuous work, soft sounds for input and done,
    /// a session card on hover, and a sparkle burst when the last run finishes.
    @Published var busyTimer: Bool { didSet { save(busyTimer, oldValue, "StatusLightBusyTimer") } }
    @Published var sounds: Bool { didSet { save(sounds, oldValue, "StatusLightSounds") } }
    @Published var hoverPeek: Bool { didSet { save(hoverPeek, oldValue, "StatusLightHoverPeek") } }
    @Published var celebrate: Bool { didSet { save(celebrate, oldValue, "StatusLightCelebrate") } }

    private func save(_ value: Bool, _ old: Bool, _ key: String) {
        guard value != old else { return }
        UserDefaults.standard.set(value, forKey: key)
    }

    private static func flag(_ key: String, default value: Bool) -> Bool {
        UserDefaults.standard.object(forKey: key) == nil ? value : UserDefaults.standard.bool(forKey: key)
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
        idleLife =
            defaults.object(forKey: "StatusLightIdleLife") == nil ? true : defaults.bool(forKey: "StatusLightIdleLife")
        busyTimer = Self.flag("StatusLightBusyTimer", default: false)
        sounds = Self.flag("StatusLightSounds", default: false)
        hoverPeek = Self.flag("StatusLightHoverPeek", default: true)
        celebrate = Self.flag("StatusLightCelebrate", default: true)
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
        template: Bool = false, scale: CGFloat = 1, counts: [Int]? = nil
    ) -> NSImage {
        let size = style.canvas
        let image = NSImage(size: NSSize(width: size.width * scale, height: size.height * scale))
        image.lockFocus()
        if let ctx = NSGraphicsContext.current?.cgContext {
            ctx.scaleBy(x: scale, y: scale)
            ctx.translateBy(x: StatusLightStyle.padding.width, y: StatusLightStyle.padding.height)
            let off: NSColor = template ? .black : (isDark ? .white : .black)
            if style.isCounting {
                let fallback = (0..<3).map { $0 < lights.count && lights[$0].level >= 0.5 ? 1 : 0 }
                CountLayout.draw(style: style, counts: counts ?? fallback, off: off, in: ctx)
            } else {
                draw(style: style, lights: lights, rotation: rotation, off: off, in: ctx, size: style.contentSize)
            }
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
        guard style.isClassic else {
            drawShapes(style: style, lights: lights, rotation: rotation, off: off, in: ctx, size: size)
            return
        }
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
        default:
            break
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
    private var decorLayers: [(layer: CAShapeLayer, decor: StatusLightGeometry.Decor)] = []
    private var counts = [0, 0, 0]
    private var countLayers: [String: CALayer] = [:]
    private var quietLayer: CAShapeLayer?
    private var busyLayer: CALayer?
    private var glow: NSColor?
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
        styleDecor()
        styleQuiet()
    }

    /// Themes with a glow (Neon, Cosmos) give lit shapes a soft halo of their own colour.
    func setGlow(_ enabled: Bool) {
        let wanted: NSColor? = enabled ? .white : nil
        guard (wanted == nil) != (glow == nil) else { return }
        glow = wanted
        applyGlow()
    }

    /// New light states. Lights that changed pop on (with a halo) or shrink off.
    func set(_ newStates: [Bool], animated: Bool) {
        let old = states
        states = newStates
        guard !style.isCounting else { return }
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

    /// Panel opened: a short, style-specific motion (`StatusLightStyle.openMotion`).
    func playOpen() {
        let now = CACurrentMediaTime()
        switch style.openMotion {
        case .spin:
            let spin = CABasicAnimation(keyPath: "transform.rotation.z")
            spin.fromValue = 0
            spin.toValue = -2 * Double.pi
            spin.duration = 0.6
            spin.timingFunction = CAMediaTimingFunction(controlPoints: 0.65, 0, 0.35, 1)
            container.add(spin, forKey: "open")
            wave(peak: 1.12, now: now, order: [0, 1, 2])
            countWave(peak: 1.12, now: now)
        case .wave:
            wave(peak: 1.32, now: now, order: [0, 1, 2])
            countWave(peak: 1.3, now: now)
        case .waveInward:
            wave(peak: 1.28, now: now, order: [2, 1, 0])
        case .blink:
            let blink = CAKeyframeAnimation(keyPath: "transform.scale.y")
            blink.values = [1, 0.1, 1, 1, 0.1, 1]
            blink.keyTimes = [0, 0.14, 0.3, 0.55, 0.69, 0.85]
            blink.duration = 0.75
            lights[1].group.add(blink, forKey: "open")
            pulse(lights[0].group, values: [1, 1.45, 1], times: [0, 0.4, 1], duration: 0.4)
        case .slide:
            for index in lights.indices {
                let offset = StatusLightGeometry.slideOffset(style: style, index: index)
                let slide = CABasicAnimation(keyPath: "transform.translation")
                slide.fromValue = NSValue(size: NSSize(width: offset.x, height: offset.y))
                slide.toValue = NSValue(size: .zero)
                slide.duration = 0.5
                slide.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1.15)
                lights[index].group.add(slide, forKey: "open")
            }
        case .sweep:
            sweepBeam()
            countWave(peak: 1.3, now: now)
        case .flip:
            for (index, light) in lights.enumerated() {
                let flip = CAKeyframeAnimation(keyPath: "transform.scale.x")
                flip.values = [1, 0.05, 1]
                flip.keyTimes = [0, 0.5, 1]
                flip.duration = 0.36
                flip.beginTime = now + Double(index) * 0.11
                flip.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                light.group.add(flip, forKey: "open")
            }
        }
    }

    /// A small style-specific gesture while the icon is quiet (Idle life).
    func playIdle() {
        if style.isCounting {
            if let target = countLayers.values.randomElement() ?? quietLayer {
                pulse(target, values: [1, 1.18, 1], times: [0, 0.4, 1], duration: 0.45)
            }
            return
        }
        guard !lights.isEmpty else { return }
        switch style.openMotion {
        case .blink:
            let blink = CAKeyframeAnimation(keyPath: "transform.scale.y")
            blink.values = [1, 0.1, 1]
            blink.keyTimes = [0, 0.4, 1]
            blink.duration = 0.28
            lights[1].group.add(blink, forKey: "idle")
        default:
            let index = Int.random(in: 0..<lights.count)
            pulse(lights[index].group, values: [1, 1.22, 1], times: [0, 0.4, 1], duration: 0.45)
        }
    }

    /// One gentle reminder pop on the input light.
    func nudgeInput() {
        if style.isCounting {
            for layer in countLayers.values where layer.value(forKey: "state") as? Int == 0 {
                pulse(layer, values: [1, 1.3, 0.95, 1], times: [0, 0.35, 0.7, 1], duration: 0.55)
            }
            return
        }
        guard states[0], !lights.isEmpty else { return }
        pulse(lights[0].group, values: [1, 1.3, 0.95, 1], times: [0, 0.35, 0.7, 1], duration: 0.55)
        ripple(lights[0].halo)
    }

    // MARK: Count styles

    /// New per-state counts (clamped to 3 each). Marks glide to the new layout, new ones pop in,
    /// gone ones fade out.
    func setCounts(_ newCounts: [Int], animated: Bool) {
        let clamped = CountLayout.raw(newCounts)
        guard clamped != counts else { return }
        counts = clamped
        guard style.isCounting else { return }
        layoutCounts(animated: animated)
    }

    private func layoutCounts(animated: Bool) {
        let items = CountLayout.items(style: style, counts: counts)
        var seen = Set<String>()
        CATransaction.begin()
        CATransaction.setDisableActions(!animated)
        CATransaction.setAnimationDuration(0.45)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(controlPoints: 0.3, 0.9, 0.3, 1.05))
        for item in items {
            seen.insert(item.key)
            if let layer = countLayers[item.key] {
                applyCount(item, to: layer, animated: animated)
            } else {
                let layer = makeCountLayer(item)
                withoutActions {
                    container.addSublayer(layer)
                    applyCount(item, to: layer, animated: false)
                }
                countLayers[item.key] = layer
                if animated {
                    pulse(layer, values: [0.01, 1.3, 1], times: [0, 0.6, 1], duration: 0.42)
                    fade(layer, from: 0, to: 1, duration: 0.2)
                }
            }
        }
        for (key, layer) in countLayers where !seen.contains(key) {
            countLayers[key] = nil
            if animated {
                pulse(layer, values: [1, 0.01], times: [0, 1], duration: 0.3)
                fade(layer, from: 1, to: 0, duration: 0.3)
                withoutActions { layer.opacity = 0 }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.32) { layer.removeFromSuperlayer() }
            } else {
                layer.removeFromSuperlayer()
            }
        }
        quietLayer?.opacity = items.isEmpty ? 1 : 0
        CATransaction.commit()
    }

    private func makeCountLayer(_ item: CountLayout.Item) -> CALayer {
        let color = StatusLightPalette.all[item.state].cgColor
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        let layer: CALayer
        var alwaysGlow = false
        switch item.kind {
        case .pill:
            layer = CALayer()
            layer.backgroundColor = color
        case .arc:
            let track = CountLayout.track(style: style)
            let shape = CAShapeLayer()
            shape.path = track.path
            shape.bounds = CGRect(origin: .zero, size: style.contentSize)
            shape.position = CGPoint(x: style.contentSize.width / 2, y: style.contentSize.height / 2)
            shape.fillColor = nil
            shape.strokeColor = color
            shape.lineWidth = track.width
            shape.lineCap = .butt
            layer = shape
        case .dot:
            let shape = CAShapeLayer()
            shape.fillColor = color
            shape.lineJoin = .round
            layer = shape
        case .mark(let mark):
            let shape = CAShapeLayer()
            shape.lineCap = .round
            shape.lineJoin = .round
            if mark.stroked {
                shape.fillColor = nil
                shape.strokeColor = color
                shape.lineWidth = mark.lineWidth
            } else {
                shape.fillColor = color
                shape.fillRule = mark.evenOdd ? .evenOdd : .nonZero
            }
            if let ambient = mark.ambient, ambientEnabled {
                addAmbient(ambient, to: shape)
            }
            alwaysGlow = mark.glow
            layer = shape
        }
        layer.contentsScale = scale
        layer.shadowColor = color
        layer.shadowOffset = .zero
        layer.shadowRadius = alwaysGlow ? 2.4 : 2.2
        layer.shadowOpacity = alwaysGlow || glow != nil ? 0.95 : 0
        if alwaysGlow { layer.setValue(true, forKey: "alwaysGlow") }
        layer.setValue(item.state, forKey: "state")
        return layer
    }

    private func applyCount(_ item: CountLayout.Item, to layer: CALayer, animated: Bool) {
        switch item.kind {
        case .arc(let start, let end):
            guard let shape = layer as? CAShapeLayer else { return }
            shape.strokeStart = start
            shape.strokeEnd = end
        case .pill(let rect):
            layer.bounds = CGRect(origin: .zero, size: rect.size)
            layer.position = CGPoint(x: rect.midX, y: rect.midY)
            layer.cornerRadius = min(rect.width, rect.height) / 2
        case .dot(let center, let size):
            guard let shape = layer as? CAShapeLayer else { return }
            // The path itself is scaled (not the layer), so the shape stays sharp at any size.
            var transform = CGAffineTransform(scaleX: size, y: size)
            morph(shape, to: CountLayout.unitPath(style: style).copy(using: &transform), animated: animated)
            shape.position = center
        case .mark(let mark):
            guard let shape = layer as? CAShapeLayer else { return }
            morph(shape, to: mark.path, animated: animated)
            shape.position = mark.center
        }
    }

    private func morph(_ shape: CAShapeLayer, to path: CGPath?, animated: Bool) {
        if animated, let old = shape.path, let path, old != path {
            let morph = CABasicAnimation(keyPath: "path")
            morph.fromValue = old
            morph.toValue = path
            shape.add(morph, forKey: "path")
        }
        shape.path = path
    }

    /// Ambient motion runs while the mark exists: repeating CA animations, no timer. They loop
    /// forever, so each is capped at about 12 fps (`limitFrameRate`): the window server then redraws
    /// the status item a dozen times a second instead of at the display refresh rate (up to 120 Hz).
    private func addAmbient(_ ambient: CountLayout.Ambient, to layer: CALayer) {
        addAmbientAnimations(ambient, to: layer)
        for key in layer.animationKeys() ?? [] where key.hasPrefix("ambient") {
            guard let animation = layer.animation(forKey: key)?.copy() as? CAAnimation else { continue }
            Self.limitFrameRate(animation)
            layer.add(animation, forKey: key)
        }
    }

    private static func limitFrameRate(_ animation: CAAnimation) {
        animation.preferredFrameRateRange = CAFrameRateRange(minimum: 8, maximum: 15, preferred: 12)
        for child in (animation as? CAAnimationGroup)?.animations ?? [] { limitFrameRate(child) }
    }

    private func addAmbientAnimations(_ ambient: CountLayout.Ambient, to layer: CALayer) {
        let phase = CACurrentMediaTime() - Double.random(in: 0...2)
        switch ambient {
        case .glow:
            let glow = CABasicAnimation(keyPath: "opacity")
            glow.fromValue = 1
            glow.toValue = 0.5
            glow.duration = 1.2
            glow.autoreverses = true
            glow.repeatCount = .infinity
            glow.beginTime = phase
            layer.add(glow, forKey: "ambient")
        }
    }

    /// Ambient motion on or off (Animate, Reduce Motion). Rebuilds the marks.
    var ambientEnabled = true {
        didSet {
            guard ambientEnabled != oldValue, style.isScene else { return }
            build()
        }
    }

    // MARK: Extras

    /// Radar beam: one turn around the dial.
    private func sweepBeam() {
        let beam = CAShapeLayer()
        let line = CGMutablePath()
        line.move(to: .zero)
        line.addLine(to: CGPoint(x: 0, y: 7.6))
        beam.path = line
        beam.strokeColor = StatusLightPalette.running.cgColor
        beam.lineWidth = 1.3
        beam.lineCap = .round
        beam.position = CGPoint(x: 9, y: 9)
        beam.contentsScale = window?.backingScaleFactor ?? 2
        beam.shadowColor = StatusLightPalette.running.cgColor
        beam.shadowRadius = 2
        beam.shadowOpacity = 0.9
        beam.shadowOffset = .zero
        container.addSublayer(beam)
        let turn = CABasicAnimation(keyPath: "transform.rotation.z")
        turn.fromValue = 0
        turn.toValue = -2 * Double.pi
        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = [0, 1, 1, 0]
        fade.keyTimes = [0, 0.1, 0.8, 1]
        let group = CAAnimationGroup()
        group.animations = [turn, fade]
        group.duration = 0.9
        group.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        withoutActions { beam.opacity = 0 }
        beam.add(group, forKey: "sweep")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.95) { beam.removeFromSuperlayer() }
    }

    /// The last running session finished: a small burst of blue sparkles.
    func celebrate() {
        let center = CGPoint(
            x: StatusLightStyle.padding.width + style.contentSize.width / 2,
            y: StatusLightStyle.padding.height + style.contentSize.height / 2)
        let scale = window?.backingScaleFactor ?? 2
        for index in 0..<7 {
            let spark = CAShapeLayer()
            var sparkScale = CGAffineTransform(scaleX: 1.8, y: 1.8)
            spark.path = CountLayout.unitPath(style: .galaxy).copy(using: &sparkScale)
            spark.fillColor = (index.isMultiple(of: 3) ? NSColor.white : StatusLightPalette.ended).cgColor
            spark.position = center
            spark.contentsScale = scale
            layer?.addSublayer(spark)
            let angle = Double(index) / 7 * 2 * .pi + 0.3
            let distance = 8.5 + Double(index % 3)
            let fly = CABasicAnimation(keyPath: "position")
            fly.fromValue = NSValue(point: center)
            fly.toValue = NSValue(
                point: CGPoint(x: center.x + cos(angle) * distance, y: center.y + sin(angle) * distance))
            let shrink = CAKeyframeAnimation(keyPath: "transform.scale")
            shrink.values = [0.3, 1.2, 0]
            let fade = CAKeyframeAnimation(keyPath: "opacity")
            fade.values = [1, 1, 0]
            let group = CAAnimationGroup()
            group.animations = [fly, shrink, fade]
            group.duration = 0.75
            group.timingFunction = CAMediaTimingFunction(name: .easeOut)
            withoutActions { spark.opacity = 0 }
            spark.add(group, forKey: "burst")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { spark.removeFromSuperlayer() }
        }
        pulse(container, values: [1, 1.15, 1], times: [0, 0.35, 1], duration: 0.45)
    }

    /// Busy timer: a hairline under the icon that fills over an hour of continuous work.
    func setBusy(fraction: CGFloat?) {
        guard let fraction else {
            busyLayer?.removeFromSuperlayer()
            busyLayer = nil
            return
        }
        let bar: CALayer
        if let busyLayer {
            bar = busyLayer
        } else {
            bar = CALayer()
            bar.backgroundColor = StatusLightPalette.running.withAlphaComponent(0.85).cgColor
            bar.cornerRadius = 0.5
            bar.anchorPoint = CGPoint(x: 0, y: 0.5)
            layer?.addSublayer(bar)
            busyLayer = bar
        }
        // Half-point steps: session ticks call this often and must not re-animate a sub-pixel change.
        let width = (max(1.5, style.contentSize.width * min(max(fraction, 0), 1)) * 2).rounded() / 2
        guard bar.bounds.width != width else { return }
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.6)
        bar.bounds = CGRect(x: 0, y: 0, width: width, height: 1)
        bar.position = CGPoint(x: StatusLightStyle.padding.width, y: 0.9)
        CATransaction.commit()
    }

    private func countWave(peak: Double, now: CFTimeInterval) {
        let ordered = countLayers.sorted { $0.key < $1.key }.map(\.value)
        for (step, layer) in ordered.enumerated() {
            let wave = CAKeyframeAnimation(keyPath: "transform.scale")
            wave.values = [1, peak, 1]
            wave.keyTimes = [0, 0.45, 1]
            wave.duration = 0.34
            wave.beginTime = now + Double(step) * 0.06
            layer.add(wave, forKey: "wave")
        }
        if ordered.isEmpty, let quietLayer {
            pulse(quietLayer, values: [1, peak, 1], times: [0, 0.45, 1], duration: 0.36)
        }
    }

    private func styleQuiet() {
        guard let quietLayer, let quiet = CountLayout.quiet(style: style) else { return }
        withoutActions {
            quietLayer.fillColor = quiet.filled ? offColor.cgColor : nil
            quietLayer.strokeColor = quiet.filled ? nil : offColor.cgColor
        }
    }

    private func wave(peak: Double, now: CFTimeInterval, order: [Int]) {
        for (step, index) in order.enumerated() where index < lights.count {
            let wave = CAKeyframeAnimation(keyPath: "transform.scale")
            wave.values = [1, peak, 1]
            wave.keyTimes = [0, 0.45, 1]
            wave.duration = 0.34
            wave.beginTime = now + Double(step) * 0.1
            wave.timingFunctions = [
                CAMediaTimingFunction(name: .easeOut), CAMediaTimingFunction(name: .easeInEaseOut),
            ]
            lights[index].group.add(wave, forKey: "wave")
        }
    }

    // MARK: Build

    private var offColor: NSColor { isDark ? .white : .black }

    /// Filled off shapes (Ring arcs are strokes, Pie wedges are fills); dot and bar styles show an outline.
    private var offFill: CGColor? { style == .pie ? offColor.cgColor : nil }

    private func build() {
        container.sublayers?.forEach { $0.removeFromSuperlayer() }
        lights = []
        decorLayers = []
        countLayers = [:]
        quietLayer = nil
        let content = style.contentSize
        withoutActions {
            container.bounds = CGRect(origin: .zero, size: content)
            container.anchorPoint = CGPoint(x: 0.5, y: 0.5)
            container.position = CGPoint(
                x: StatusLightStyle.padding.width + content.width / 2,
                y: StatusLightStyle.padding.height + content.height / 2)
            for decor in StatusLightGeometry.decor(style: style) {
                let layer = CAShapeLayer()
                layer.path = decor.path
                layer.lineWidth = decor.lineWidth
                layer.lineCap = .round
                layer.lineJoin = .round
                layer.opacity = Float(decor.alpha)
                container.addSublayer(layer)
                decorLayers.append((layer, decor))
            }
            if style.isCounting, let quiet = CountLayout.quiet(style: style) {
                let layer = CAShapeLayer()
                layer.path = quiet.path
                layer.lineWidth = quiet.lineWidth
                layer.bounds = CGRect(origin: .zero, size: content)
                layer.position = CGPoint(x: content.width / 2, y: content.height / 2)
                container.addSublayer(layer)
                quietLayer = layer
            }
            for index in 0..<3 where !style.isCounting {
                let light = Light()
                let shape = StatusLightGeometry.shape(style: style, index: index)
                light.group.zPosition = shape.zPosition
                light.group.bounds = CGRect(x: -0.5, y: -0.5, width: 1, height: 1)
                light.group.position = shape.anchor
                for layer in [light.off, light.on, light.halo] {
                    layer.path = shape.path
                    layer.position = .zero
                    layer.bounds = .zero
                    layer.lineCap = .round
                    layer.lineJoin = .round
                    light.group.addSublayer(layer)
                }
                let color = StatusLightPalette.all[index].withAlphaComponent(CGFloat(shape.onAlpha)).cgColor
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
        styleDecor()
        styleQuiet()
        applyGlow()
        applyScale()
        if style.isCounting { layoutCounts(animated: false) }
    }

    private func styleDecor() {
        withoutActions {
            for (layer, decor) in decorLayers {
                layer.fillColor = decor.filled ? offColor.cgColor : nil
                layer.strokeColor = decor.filled ? nil : offColor.cgColor
            }
        }
    }

    private func applyGlow() {
        withoutActions {
            for (index, light) in lights.enumerated() {
                light.on.shadowColor = StatusLightPalette.all[index].cgColor
                light.on.shadowOffset = .zero
                light.on.shadowRadius = 2.2
                light.on.shadowOpacity = glow == nil ? 0 : 0.95
            }
            for layer in countLayers.values where layer.value(forKey: "alwaysGlow") == nil {
                layer.shadowOpacity = glow == nil ? 0 : 0.95
            }
        }
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
        for item in decorLayers { item.layer.contentsScale = scale }
        for layer in countLayers.values { layer.contentsScale = scale }
        quietLayer?.contentsScale = scale
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
        /// Opacity of the lit colour (Venn mixes where circles overlap).
        var onAlpha: Float = 1
        /// Draw order; higher is on top (Lantern stacks its lights in one glass).
        var zPosition: CGFloat = 0
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
        default:
            // Count styles have no per-light shapes; never bounce back into `extendedShape`.
            guard !style.isCounting else {
                return Shape(
                    anchor: .zero, path: CGMutablePath(), offPath: CGMutablePath(), haloPath: CGMutablePath(),
                    stroked: false, offFilled: true, offLineWidth: 0)
            }
            return extendedShape(style: style, index: index)
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
    private var actualCounts = [0, 0, 0]
    private var demoActive = false
    private var demoGeneration = 0
    private var cancellables = Set<AnyCancellable>()
    private var inputSince: Date?
    private var busySince: Date?
    private var runningStoppedAt: Date?
    /// False until the first counts arrive (at launch and after the lights are switched on).
    private var hasBaseline = false
    private var lifeTimer: Timer?
    private var lifeTicks = 0

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
        ThemeManager.shared.$theme
            .map { $0.glow != nil }
            .removeDuplicates()
            .sink { [weak self] glow in
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.view.setGlow(glow) } }
            }
            .store(in: &cancellables)
        settings.$animations.dropFirst().removeDuplicates()
            .sink { [weak self] _ in
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.syncAmbient() } }
            }
            .store(in: &cancellables)
        settings.$busyTimer.dropFirst().removeDuplicates()
            .sink { [weak self] _ in
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.updateBusy() } }
            }
            .store(in: &cancellables)
        NSWorkspace.shared.notificationCenter.publisher(
            for: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification
        )
        .sink { [weak self] _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.syncAmbient() } }
        }
        .store(in: &cancellables)
        syncAmbient()
        startLifeTimer()
        setActive(settings.enabled)
    }

    private func syncAmbient() {
        view.ambientEnabled = animates
    }

    private func updateBusy() {
        guard settings.enabled, settings.busyTimer, let busySince else {
            view.setBusy(fraction: nil)
            return
        }
        view.setBusy(fraction: CGFloat(Date().timeIntervalSince(busySince) / 3600))
    }

    /// 30 s tick: a reminder pop when input has waited over 2 minutes; every other tick an idle
    /// gesture while all lights are off. Each is one short Core Animation animation.
    private func startLifeTimer() {
        let timer = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.lifeTick() }
        }
        timer.tolerance = 5
        RunLoop.main.add(timer, forMode: .common)
        lifeTimer = timer
    }

    private func lifeTick() {
        lifeTicks += 1
        syncAmbient()
        updateBusy()
        guard settings.enabled, settings.idleLife, animates, !demoActive, !view.isHidden else { return }
        if actual[0], let inputSince, Date().timeIntervalSince(inputSince) >= 120 {
            view.nudgeInput()
        } else if actual == [false, false, false], lifeTicks.isMultiple(of: 2) {
            view.playIdle()
        }
    }

    /// Lights on: a transparent placeholder image sizes the item and the view draws on top.
    /// Lights off: the view hides and the static icon takes over the button image.
    func setActive(_ active: Bool) {
        view.isHidden = !active
        // Counts seen while the lights were off are not news: take the next update as a baseline.
        if active { hasBaseline = false }
        if active {
            view.setDark(isDark())
            installPlaceholder()
        }
    }

    /// Sessions per state: needs input, running, unseen ended. Light styles use on / off; count
    /// styles show one mark per session (up to 3 per state).
    func update(counts: [Int]) {
        let input = counts.first ?? 0 > 0
        if input != actual[0] { inputSince = input ? Date() : nil }
        let previous = actualCounts
        let isNews = hasBaseline
        hasBaseline = true
        if counts.count == 3 {
            if counts[1] > 0, busySince == nil { busySince = Date() }
            if counts[1] == 0 { busySince = nil }
            if previous[1] > 0, counts[1] == 0 { runningStoppedAt = Date() }
            if counts[1] > 0 { runningStoppedAt = nil }
            if isNews, settings.enabled, settings.sounds {
                if counts[0] > previous[0] {
                    NSSound(named: "Glass")?.play()
                } else if counts[2] > previous[2] {
                    NSSound(named: "Tink")?.play()
                }
            }
            // Claude marks Done a few seconds after its run stops, so the end can arrive on a later tick.
            if isNews, settings.enabled, settings.celebrate, animates, !view.isHidden, counts[1] == 0,
                counts[2] > previous[2], let stopped = runningStoppedAt, Date().timeIntervalSince(stopped) < 12
            {
                runningStoppedAt = nil
                view.celebrate()
            }
        }
        actualCounts = counts
        actual = counts.map { $0 > 0 }
        updateBusy()
        guard !demoActive else { return }
        show(counts, animated: animates)
    }

    private func show(_ counts: [Int], animated: Bool) {
        view.set(counts.map { $0 > 0 }, animated: animated)
        view.setCounts(counts, animated: animated)
    }

    func refresh(force: Bool = false) {
        view.setDark(isDark())
        if force { installPlaceholder() }
    }

    func playOpen() {
        guard animates, !view.isHidden else { return }
        view.playOpen()
    }

    /// States come and go, and counts grow and shrink, then the real state returns.
    func playDemo() {
        demoGeneration += 1
        let generation = demoGeneration
        demoActive = true
        show([0, 0, 0], animated: false)
        let steps: [(Double, [Int])] = [
            (0.25, [0, 1, 0]), (0.75, [0, 2, 0]), (1.25, [0, 3, 0]), (1.75, [1, 3, 0]),
            (2.25, [1, 2, 1]), (2.75, [0, 1, 2]), (3.25, [0, 0, 1]), (3.75, [0, 0, 0]),
        ]
        for (delay, counts) in steps {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, self.demoGeneration == generation else { return }
                self.show(counts, animated: true)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.3) { [weak self] in
            guard let self, self.demoGeneration == generation else { return }
            self.demoActive = false
            self.show(self.actualCounts, animated: true)
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
