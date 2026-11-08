import AppKit
import SwiftUI

/// How many live + ended rows the dashboard will show inline before collapsing to a Sessions page.
enum SessionDashboardLayout {
    static let maxInlineRows = 3
    static let pageAnimation = Animation.easeOut(duration: 0.2)
    /// Height, fade and chevron for a session's details drawer. One drawer is open at a time.
    static let detailAnimation = Animation.smooth(duration: 0.3, extraBounce: 0)
    /// Filter bar, including its 2pt inset. The list scrolls in the room left under it.
    static let filterBarHeight: CGFloat = 28
    /// Room left of the vertical scroller so it does not sit on the row controls.
    static let scrollerGutter: CGFloat = 16

    /// Header 34, divider 1, page padding, filter bar, and the gap before the list.
    /// Matches `PanelHeader` and the padding around `SessionsPage`.
    static var sessionsListChrome: CGFloat {
        34 + 1 + MacToolsTheme.outerPadding * 2 + filterBarHeight + MacToolsTheme.sectionSpacing
    }

    /// Tallest the session list can be before the panel would pass the menu-bar screen.
    /// A few points of slack keep the scroll view inside the window cap in `AppDelegate`.
    static var maxSessionListHeight: CGFloat {
        let screen =
            NSApp.keyWindow?.screen
            ?? NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) }
            ?? NSScreen.main
            ?? NSScreen.screens.first
        let panelCap = (screen?.visibleFrame.height ?? 900) - 8
        return max(160, panelCap - sessionsListChrome - 4)
    }
}

struct SessionPageHeightKey: PreferenceKey {
    static var defaultValue: [String: CGFloat] = [:]

    static func reduce(value: inout [String: CGFloat], nextValue: () -> [String: CGFloat]) {
        value.merge(nextValue(), uniquingKeysWith: { max($0, $1) })
    }
}

extension View {
    func reportsSessionPageHeight(_ name: String) -> some View {
        background(
            GeometryReader { proxy in
                Color.clear.preference(key: SessionPageHeightKey.self, value: [name: proxy.size.height])
            }
        )
    }
}

/// Kept so a future stack reveal can opt in. Page changes fade only; rows do not move.
struct SessionStackReveal: ViewModifier {
    let index: Int
    let revealed: Bool?

    func body(content: Content) -> some View {
        content
    }
}

extension View {
    func sessionStackReveal(index: Int, revealed: Bool?, base: Int = 0) -> some View {
        modifier(SessionStackReveal(index: base + index, revealed: revealed))
    }
}

/// Cluster of session cards. Observes the four session managers only (not AppState),
/// so a CPU tick never re-renders this section.
struct DashboardSessionsSection: View {
    @ObservedObject var claude: ClaudeSessionsManager
    @ObservedObject var cursor: CursorSessionsManager
    @ObservedObject var codex: CodexSessionsManager
    @ObservedObject var antigravity: AntigravitySessionsManager
    let openSessions: () -> Void

    var body: some View {
        if counts.total == 0 {
            EmptyView()
        } else if counts.total > SessionDashboardLayout.maxInlineRows {
            SessionsSummaryCard(
                counts: counts, tally: tally, border: borderMix, openSessions: openSessions)
        } else {
            VStack(spacing: MacToolsTheme.sectionSpacing) {
                if counts.claude > 0 {
                    ClaudeSessionsCard(manager: claude)
                }
                if counts.cursor > 0 {
                    CursorSessionsCard(manager: cursor)
                }
                if counts.codex > 0 {
                    CodexSessionsCard(manager: codex)
                }
                if counts.antigravity > 0 {
                    AntigravitySessionsCard(manager: antigravity)
                }
            }
        }
    }

    private var counts: SessionDashboardCounts {
        SessionDashboardCounts(
            claude: claude.sessions.count,
            cursor: cursor.sessions.count + cursor.ended.count,
            codex: codex.sessions.count + codex.ended.count,
            antigravity: antigravity.sessions.count + antigravity.ended.count)
    }

    private var tally: SessionStatusTally {
        SessionStatusTally.claude(claude.sessions, finished: claude.finished)
            + .cursor(cursor.sessions, ended: cursor.ended.count)
            + .codex(live: codex.sessions.count, ended: codex.ended.count)
            + .antigravity(antigravity.sessions, ended: antigravity.ended.count)
    }

    /// One light per waiting or running session, and one per ended row still highlighted blue.
    /// Checked ended rows stay in the tally and off the border.
    private var borderMix: SessionBorderMix {
        SessionBorderMix(input: tally.input, running: tally.running, ended: uncheckedEnded)
    }

    /// Same rows the list paints blue: not yet seen, or still fresh from this visit.
    private var uncheckedEnded: Int {
        claude.sessions.filter { claude.isFreshFinish($0.id) && !$0.isWorking && !$0.needsInput }.count
            + cursor.ended.filter { !$0.seen || cursor.freshEnded.contains($0.id) }.count
            + codex.ended.filter { !$0.seen || codex.freshEnded.contains($0.id) }.count
            + antigravity.ended.filter { !$0.seen || antigravity.freshEnded.contains($0.id) }.count
    }
}

/// Which provider the Sessions page is showing. Empty providers are left off the bar.
private enum SessionProviderFilter: String, CaseIterable, Identifiable {
    case all
    case claude
    case cursor
    case codex
    case antigravity

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: "All"
        case .claude: "Claude"
        case .cursor: "Cursor"
        case .codex: "Codex"
        case .antigravity: "Antigravity"
        }
    }

    var help: String {
        switch self {
        case .all: "All sessions"
        case .claude: "Claude sessions"
        case .cursor: "Cursor sessions"
        case .codex: "Codex sessions"
        case .antigravity: "Antigravity sessions"
        }
    }
}

private struct SessionListHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// Full lists, grouped by app. A filter stays pinned; the list scrolls once it outgrows the screen.
struct SessionsPage: View {
    @ObservedObject var claude: ClaudeSessionsManager
    @ObservedObject var cursor: CursorSessionsManager
    @ObservedObject var codex: CodexSessionsManager
    @ObservedObject var antigravity: AntigravitySessionsManager
    var stackRevealed: Bool
    var onEmpty: () -> Void

    @State private var filter: SessionProviderFilter = .all
    /// Natural height of the cards. Zero until the first layout.
    @State private var listHeight: CGFloat = 0

    var body: some View {
        VStack(spacing: MacToolsTheme.sectionSpacing) {
            SessionFilterBar(filters: filters, selection: $filter)

            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    sessionList
                        .fixedSize(horizontal: false, vertical: true)
                        .background {
                            GeometryReader { geo in
                                Color.clear.preference(key: SessionListHeightKey.self, value: geo.size.height)
                            }
                        }
                }
                .frame(height: listViewport)
                .scrollIndicators(needsScroll ? .visible : .hidden, axes: .vertical)
                .scrollDisabled(!needsScroll)
                .onChange(of: filter) { _, _ in
                    DispatchQueue.main.async {
                        proxy.scrollTo("sessions-top", anchor: .top)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
        .onPreferenceChange(SessionListHeightKey.self) { height in
            guard height > 1, abs(height - listHeight) > 0.5 else { return }
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { listHeight = height }
        }
        .onChange(of: rosterToken) { _, _ in
            if filter != .all, !includes(filter) { filter = .all }
        }
        .onChange(of: isEmpty) { _, empty in
            if empty { onEmpty() }
        }
    }

    /// Unconstrained until measured, then the smaller of the cards and the screen.
    /// The first pass reports the real card height; the next pass caps it.
    private var listViewport: CGFloat? {
        guard listHeight > 1 else { return nil }
        return min(listHeight, SessionDashboardLayout.maxSessionListHeight)
    }

    private var needsScroll: Bool {
        listHeight > SessionDashboardLayout.maxSessionListHeight + 0.5
    }

    private var sessionList: some View {
        VStack(spacing: MacToolsTheme.sectionSpacing) {
            Color.clear.frame(height: 1).id("sessions-top")
            if shows(.claude) {
                ClaudeSessionsCard(
                    manager: claude, stackRevealed: stackRevealed, stackIndexBase: claudeBase)
            }
            if shows(.cursor) {
                CursorSessionsCard(
                    manager: cursor, stackRevealed: stackRevealed, stackIndexBase: cursorBase)
            }
            if shows(.codex) {
                CodexSessionsCard(
                    manager: codex, stackRevealed: stackRevealed, stackIndexBase: codexBase)
            }
            if shows(.antigravity) {
                AntigravitySessionsCard(
                    manager: antigravity, stackRevealed: stackRevealed, stackIndexBase: antigravityBase)
            }
        }
        .padding(.vertical, 1)
        .padding(.trailing, needsScroll ? SessionDashboardLayout.scrollerGutter : 0)
    }

    private var filters: [SessionProviderFilter] {
        var items: [SessionProviderFilter] = [.all]
        for provider in SessionProviderFilter.allCases where provider != .all && includes(provider) {
            items.append(provider)
        }
        return items
    }

    private func shows(_ provider: SessionProviderFilter) -> Bool {
        guard includes(provider) else { return false }
        return filter == .all || filter == provider
    }

    private func includes(_ provider: SessionProviderFilter) -> Bool {
        switch provider {
        case .all:
            !isEmpty
        case .claude:
            !claude.sessions.isEmpty
        case .cursor:
            !cursor.sessions.isEmpty || !cursor.ended.isEmpty
        case .codex:
            !codex.sessions.isEmpty || !codex.ended.isEmpty
        case .antigravity:
            !antigravity.sessions.isEmpty || !antigravity.ended.isEmpty
        }
    }

    private var claudeBase: Int { 0 }
    private var cursorBase: Int { shows(.claude) ? 1 + claude.sessions.count : 0 }
    private var codexBase: Int {
        cursorBase + (shows(.cursor) ? 1 + cursor.sessions.count + cursor.ended.count : 0)
    }
    private var antigravityBase: Int {
        codexBase + (shows(.codex) ? 1 + codex.sessions.count + codex.ended.count : 0)
    }

    private var isEmpty: Bool {
        claude.sessions.isEmpty
            && cursor.sessions.isEmpty && cursor.ended.isEmpty
            && codex.sessions.isEmpty && codex.ended.isEmpty
            && antigravity.sessions.isEmpty && antigravity.ended.isEmpty
    }

    private var rosterToken: String {
        "\(claude.sessions.count) \(cursor.sessions.count) \(cursor.ended.count) \(codex.sessions.count) \(codex.ended.count) \(antigravity.sessions.count) \(antigravity.ended.count)"
    }
}

/// Equal-width provider tabs. The selected one filters the list under it.
private struct SessionFilterBar: View {
    @Environment(\.appTheme) private var theme
    let filters: [SessionProviderFilter]
    @Binding var selection: SessionProviderFilter

    var body: some View {
        HStack(spacing: 2) {
            ForEach(filters) { filter in
                let selected = selection == filter
                Button {
                    selection = filter
                } label: {
                    Text(filter.title)
                        .font(.system(size: 11, weight: selected ? .semibold : .medium))
                        .foregroundStyle(selected ? Color.primary : Color.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .frame(maxWidth: .infinity)
                        .frame(height: 24)
                        .background {
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(selected ? Color.accentColor.opacity(0.22) : Color.clear)
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity)
                .suppressesFocusRing()
                .help(filter.help)
                .accessibilityLabel(filter.help)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(2)
        .frame(height: SessionDashboardLayout.filterBarHeight)
        .background(theme.controlFill, in: RoundedRectangle(cornerRadius: theme.radius(8), style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: theme.radius(8), style: .continuous)
                .strokeBorder(theme.cardStroke, lineWidth: theme.strokeWidth)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Session filters")
    }
}

private struct SessionDashboardCounts {
    let claude: Int
    let cursor: Int
    let codex: Int
    let antigravity: Int

    var total: Int { claude + cursor + codex + antigravity }

    var summaryLine: String {
        var parts: [String] = []
        if claude > 0 { parts.append("Claude \(claude)") }
        if cursor > 0 { parts.append("Cursor \(cursor)") }
        if codex > 0 { parts.append("Codex \(codex)") }
        if antigravity > 0 { parts.append("Antigravity \(antigravity)") }
        return parts.joined(separator: " · ")
    }
}

private struct SessionsSummaryCard: View {
    let counts: SessionDashboardCounts
    let tally: SessionStatusTally
    let border: SessionBorderMix
    let openSessions: () -> Void

    var body: some View {
        Button(action: openSessions) {
            MacToolsCard(padding: 7) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Label("Sessions", systemImage: "rectangle.stack")
                            .font(.system(size: 10.5, weight: .semibold))
                        Spacer(minLength: 6)
                        SessionStatusMarks(tally: tally)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .frame(height: 16)

                    Text(counts.summaryLine)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, minHeight: 20, alignment: .leading)
                }
            }
            .overlay {
                if !border.isQuiet {
                    TravelingNeonBorder(mix: border, cornerRadius: MacToolsTheme.cornerRadius)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .suppressesFocusRing()
        .hoverHighlight(cornerRadius: MacToolsTheme.cornerRadius)
        .help(tally.spoken.isEmpty ? "Show all sessions" : "Show all sessions. \(tally.spoken)")
    }
}

/// Waiting, running, and unchecked-ended counts for the summary border. Idle and checked ended rows are left out.
private struct SessionBorderMix: Equatable {
    var input: Int
    var running: Int
    var ended: Int

    var isQuiet: Bool { input + running + ended == 0 }

    /// Orange, then green, then blue, so the three colours stay in one order.
    fileprivate var bands: [(color: NeonRGBA, count: Int)] {
        [
            (NeonRGBA(r: 1.0, g: 0.624, b: 0.039, a: 1), input),
            (NeonRGBA(r: 0.188, g: 0.820, b: 0.345, a: 1), running),
            (NeonRGBA(r: 0.039, g: 0.518, b: 1.0, a: 1), ended),
        ].filter { $0.count > 0 }
    }
}

/// Proportional stroke plus one traveling light per session. The whole pattern turns together,
/// so each light stays inside its own colour.
///
/// The turn is a Core Animation rotation, so the window server animates it on the GPU and the
/// SwiftUI graph is not re-rendered per frame (that cost ~15–40% CPU while the panel was open).
/// It runs only while the dashboard is the visible page and Reduce Motion is off.
private struct TravelingNeonBorder: View {
    var mix: SessionBorderMix
    var cornerRadius: CGFloat
    @Environment(\.dashboardOnScreen) private var onScreen
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        NeonBorderLayerView(
            baseStops: baseStops,
            sparkStops: sparkStops,
            cornerRadius: cornerRadius,
            spinning: onScreen && !reduceMotion
        )
        .allowsHitTesting(false)
    }

    /// Each colour holds its share of the loop, and neighbouring colours blend across a short seam.
    private var baseStops: [NeonStop] {
        let bands = mix.bands
        let total = Double(bands.reduce(0) { $0 + $1.count })
        guard total > 0 else { return [] }
        let shares = bands.map { Double($0.count) / total }
        let seam = bands.count < 2 ? 0 : min(0.06, (shares.min() ?? 1) * 0.35)
        var raw: [NeonStop] = []
        var cursor = 0.0
        for (band, share) in zip(bands, shares) {
            let half = seam == 0 ? 0 : min(seam, share * 0.35) / 2
            let tint = band.color.opacity(0.46)
            raw.append(NeonStop(location: cursor + half, color: tint))
            raw.append(NeonStop(location: cursor + share - half, color: tint))
            cursor += share
        }
        return NeonStop.closed(raw)
    }

    /// One hot spot per session, centered in that session's slice of its colour.
    private var sparkStops: [NeonStop] {
        let bands = mix.bands
        let total = Double(bands.reduce(0) { $0 + $1.count })
        guard total > 0 else { return [] }
        var raw: [NeonStop] = []
        var cursor = 0.0
        for band in bands {
            let share = Double(band.count) / total
            let slot = share / Double(band.count)
            let width = min(0.10, slot * 0.40)
            for index in 0..<band.count {
                let center = cursor + (Double(index) + 0.5) * slot
                raw.append(NeonStop(location: center - width, color: .clear))
                raw.append(NeonStop(location: center - width * 0.42, color: band.color.opacity(0.75)))
                raw.append(NeonStop(location: center, color: .hot))
                raw.append(NeonStop(location: center + width * 0.42, color: band.color.opacity(0.75)))
                raw.append(NeonStop(location: center + width, color: .clear))
            }
            cursor += share
        }
        return NeonStop.closed(raw)
    }
}

private struct NeonBorderLayerView: NSViewRepresentable {
    var baseStops: [NeonStop]
    var sparkStops: [NeonStop]
    var cornerRadius: CGFloat
    var spinning: Bool

    func makeNSView(context: Context) -> NeonBorderNSView { NeonBorderNSView() }

    func updateNSView(_ view: NeonBorderNSView, context: Context) {
        view.update(baseStops: baseStops, sparkStops: sparkStops, cornerRadius: cornerRadius)
        view.setSpinning(spinning)
    }
}

/// Three conic gradients (base stroke, blurred glow, sharp sparks), each masked to the card's
/// border and turned by one shared repeating rotation.
private final class NeonBorderNSView: NSView {
    private static let period: CFTimeInterval = 3.2
    private static let spinKey = "neon.spin"

    private let base = NeonBorderNSView.ring(lineWidth: 1.35)
    private let glow = NeonBorderNSView.ring(lineWidth: 1.8)
    private let spark = NeonBorderNSView.ring(lineWidth: 1.35)
    private let glowHost = CALayer()
    private var cornerRadius: CGFloat = 0
    private var spinning = false
    private var lastBase: [NeonStop] = []
    private var lastSpark: [NeonStop] = []

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerUsesCoreImageFilters = true
        guard let root = layer else { return }
        root.masksToBounds = false
        glowHost.opacity = 0.55
        if let blur = CIFilter(name: "CIGaussianBlur") {
            blur.setValue(2.2, forKey: kCIInputRadiusKey)
            glowHost.filters = [blur]
        }
        glowHost.masksToBounds = false
        root.addSublayer(base.host)
        glowHost.addSublayer(glow.host)
        root.addSublayer(glowHost)
        root.addSublayer(spark.host)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func update(baseStops: [NeonStop], sparkStops: [NeonStop], cornerRadius: CGFloat) {
        guard baseStops != lastBase || sparkStops != lastSpark || cornerRadius != self.cornerRadius else { return }
        lastBase = baseStops
        lastSpark = sparkStops
        self.cornerRadius = cornerRadius
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        Self.apply(baseStops, to: base.gradient)
        Self.apply(sparkStops, to: glow.gradient)
        Self.apply(sparkStops, to: spark.gradient)
        CATransaction.commit()
        needsLayout = true
    }

    func setSpinning(_ on: Bool) {
        guard on != spinning else { return }
        spinning = on
        for ring in [base, glow, spark] {
            if on {
                let spin = CABasicAnimation(keyPath: "transform.rotation.z")
                spin.fromValue = 0
                // Negative is clockwise in an unflipped layer, matching the SwiftUI version.
                spin.toValue = -2 * Double.pi
                spin.duration = Self.period
                spin.repeatCount = .infinity
                spin.isRemovedOnCompletion = false
                ring.gradient.add(spin, forKey: Self.spinKey)
            } else {
                ring.gradient.removeAnimation(forKey: Self.spinKey)
            }
        }
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let bounds = self.bounds
        let span = max(bounds.width, bounds.height) * 1.6
        glowHost.frame = bounds
        for ring in [base, glow, spark] {
            ring.host.frame = bounds
            ring.mask.frame = bounds
            ring.mask.cornerRadius = cornerRadius
            // Set bounds and position, not frame: frame is undefined under a rotation transform.
            ring.gradient.bounds = CGRect(x: 0, y: 0, width: span, height: span)
            ring.gradient.position = CGPoint(x: bounds.midX, y: bounds.midY)
        }
        CATransaction.commit()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        let scale = window?.backingScaleFactor ?? 2
        for ring in [base, glow, spark] {
            ring.gradient.contentsScale = scale
            ring.mask.contentsScale = scale
        }
    }

    private struct Ring {
        let host: CALayer
        let gradient: CAGradientLayer
        let mask: CALayer
    }

    private static func ring(lineWidth: CGFloat) -> Ring {
        let host = CALayer()
        let gradient = CAGradientLayer()
        gradient.type = .conic
        // Flipped so the colours run clockwise from 3 o'clock, like SwiftUI's AngularGradient.
        gradient.isGeometryFlipped = true
        gradient.startPoint = CGPoint(x: 0.5, y: 0.5)
        gradient.endPoint = CGPoint(x: 1, y: 0.5)
        let mask = CALayer()
        mask.borderWidth = lineWidth
        mask.borderColor = CGColor(gray: 0, alpha: 1)
        mask.cornerCurve = .continuous
        host.mask = mask
        host.addSublayer(gradient)
        return Ring(host: host, gradient: gradient, mask: mask)
    }

    private static func apply(_ stops: [NeonStop], to layer: CAGradientLayer) {
        layer.colors = stops.map(\.color.cgColor)
        layer.locations = stops.map { NSNumber(value: $0.location) }
    }
}

private struct NeonRGBA: Equatable {
    var r, g, b, a: Double

    static let clear = NeonRGBA(r: 0, g: 0, b: 0, a: 0)
    static let hot = NeonRGBA(r: 1, g: 1, b: 1, a: 0.55)

    var cgColor: CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: a) }

    func opacity(_ value: Double) -> NeonRGBA {
        NeonRGBA(r: r, g: g, b: b, a: a * value)
    }

    func mixed(toward other: NeonRGBA, amount t: Double) -> NeonRGBA {
        NeonRGBA(
            r: r + (other.r - r) * t,
            g: g + (other.g - g) * t,
            b: b + (other.b - b) * t,
            a: a + (other.a - a) * t)
    }
}

private struct NeonStop: Equatable {
    var location: Double
    var color: NeonRGBA

    /// Sorts stops onto the loop and makes the colour at 0 match the colour at 1.
    static func closed(_ raw: [NeonStop]) -> [NeonStop] {
        let wrapped = raw.map { stop in
            var location = stop.location.truncatingRemainder(dividingBy: 1)
            if location < 0 { location += 1 }
            return NeonStop(location: location, color: stop.color)
        }
        let sorted = wrapped.sorted { $0.location < $1.location }
        var merged: [NeonStop] = []
        for stop in sorted {
            if let last = merged.last, stop.location <= last.location + 0.0008 {
                merged[merged.count - 1] = stop.color.a >= last.color.a ? stop : last
            } else {
                merged.append(stop)
            }
        }
        guard let first = merged.first, let last = merged.last else { return [] }
        var stops = merged
        if first.location > 0.0008 {
            let span = (1 - last.location) + first.location
            let t = span > 0 ? (1 - last.location) / span : 0
            let edge = last.color.mixed(toward: first.color, amount: t)
            stops.insert(NeonStop(location: 0, color: edge), at: 0)
            stops.append(NeonStop(location: 1, color: edge))
        } else {
            stops.append(NeonStop(location: 1, color: first.color))
        }
        return stops
    }
}

private struct DashboardOnScreenKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    /// False while another page (Sessions, a stat page, Settings) covers the still-mounted dashboard.
    var dashboardOnScreen: Bool {
        get { self[DashboardOnScreenKey.self] }
        set { self[DashboardOnScreenKey.self] = newValue }
    }
}
