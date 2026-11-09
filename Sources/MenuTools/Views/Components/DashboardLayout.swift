import SwiftUI

/// Dashboard sections the user can reorder and hide (Settings → Look → Layout).
enum DashboardSection: String, CaseIterable, Identifiable {
    case metrics
    case aiLimits
    case sessions
    case toggles
    case converter
    case shelf
    case clipboard

    var id: String { rawValue }

    var title: String {
        switch self {
        case .metrics: return "Stats"
        case .aiLimits: return "AI Limits"
        case .sessions: return "Sessions"
        case .toggles: return "Quick toggles"
        case .converter: return "Converter"
        case .shelf: return "Shelf"
        case .clipboard: return "Clipboard"
        }
    }

    var symbol: String {
        switch self {
        case .metrics: return "gauge.with.dots.needle.33percent"
        case .aiLimits: return "sparkles"
        case .sessions: return "rectangle.stack"
        case .toggles: return "switch.2"
        case .converter: return "arrow.triangle.2.circlepath"
        case .shelf: return "tray.full"
        case .clipboard: return "doc.on.clipboard"
        }
    }
}

/// Order and hidden set, persisted in UserDefaults (`DashboardLayout`, `DashboardHidden`).
/// Publishes only on change; the dashboard observes it, nothing else on the hot path does.
@MainActor
final class DashboardLayoutStore: ObservableObject {
    static let shared = DashboardLayoutStore()

    private enum Keys {
        static let order = "DashboardLayout"
        static let hidden = "DashboardHidden"
    }

    @Published private(set) var order: [DashboardSection]
    @Published private(set) var hidden: Set<DashboardSection>

    var visible: [DashboardSection] { order.filter { !hidden.contains($0) } }
    var isDefault: Bool { order == DashboardSection.allCases && hidden.isEmpty }

    private init() {
        let defaults = UserDefaults.standard
        let saved = (defaults.stringArray(forKey: Keys.order) ?? []).compactMap(DashboardSection.init(rawValue:))
        // Keep the saved order, drop unknown ids, append sections added in later versions.
        var order = saved.reduce(into: [DashboardSection]()) { if !$0.contains($1) { $0.append($1) } }
        order += DashboardSection.allCases.filter { !order.contains($0) }
        self.order = order
        hidden = Set((defaults.stringArray(forKey: Keys.hidden) ?? []).compactMap(DashboardSection.init(rawValue:)))
    }

    func move(_ section: DashboardSection, before target: DashboardSection) {
        guard section != target, let from = order.firstIndex(of: section),
            let to = order.firstIndex(of: target)
        else { return }
        var next = order
        next.remove(at: from)
        next.insert(section, at: to)
        setOrder(next)
    }

    func move(_ section: DashboardSection, by offset: Int) {
        guard let from = order.firstIndex(of: section) else { return }
        let to = min(max(from + offset, 0), order.count - 1)
        guard to != from else { return }
        var next = order
        next.remove(at: from)
        next.insert(section, at: to)
        setOrder(next)
    }

    func setHidden(_ section: DashboardSection, _ isHidden: Bool) {
        var next = hidden
        if isHidden { next.insert(section) } else { next.remove(section) }
        guard next != hidden else { return }
        hidden = next
        UserDefaults.standard.set(next.map(\.rawValue).sorted(), forKey: Keys.hidden)
    }

    func reset() {
        setOrder(DashboardSection.allCases)
        if !hidden.isEmpty {
            hidden = []
            UserDefaults.standard.removeObject(forKey: Keys.hidden)
        }
    }

    private func setOrder(_ next: [DashboardSection]) {
        guard next != order else { return }
        order = next
        UserDefaults.standard.set(next.map(\.rawValue), forKey: Keys.order)
    }
}

// MARK: - Settings card

/// Drag a row (or use the arrows) to reorder; the eye hides a section. Changes apply to the
/// dashboard at once. The drag is a local gesture, not a system drag session: no floating copy of
/// the row, no pasteboard, and other drag-aware apps (Dropzone, the Shelf) are not triggered.
/// The order is committed on release, so rows never swap back and forth mid-drag.
struct DashboardLayoutCard: View {
    @ObservedObject private var store = DashboardLayoutStore.shared
    @Environment(\.appTheme) private var theme
    @State private var dragging: DashboardSection?
    @State private var dragOffset: CGFloat = 0

    private let rowHeight: CGFloat = 26
    private let rowSpacing: CGFloat = 3
    private var pitch: CGFloat { rowHeight + rowSpacing }

    var body: some View {
        MacToolsCard(padding: 8) {
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Label("Layout", systemImage: "square.3.layers.3d")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Reset") {
                        withAnimation(.easeOut(duration: 0.2)) { store.reset() }
                    }
                    .controlSize(.small)
                    .disabled(store.isDefault)
                }
                VStack(spacing: rowSpacing) {
                    ForEach(Array(store.order.enumerated()), id: \.element) { index, section in
                        row(section, index: index)
                            .offset(y: offset(for: section, index: index))
                            .zIndex(dragging == section ? 1 : 0)
                            .gesture(drag(section, index: index))
                    }
                }
                Text("Drag to reorder · eye hides a section")
                    .onDisappear {
                        // A drag cut off by the panel closing never gets onEnded.
                        dragging = nil
                        dragOffset = 0
                    }
                    .font(.system(size: 9.5))
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .center)
            }
        }
    }

    // MARK: Drag

    private var dragStartIndex: Int? { dragging.flatMap { store.order.firstIndex(of: $0) } }

    /// Index the dragged row would land on if released now.
    private var dropIndex: Int? {
        guard let start = dragStartIndex else { return nil }
        let steps = Int((dragOffset / pitch).rounded())
        return min(max(start + steps, 0), store.order.count - 1)
    }

    /// The dragged row follows the pointer; rows between its start and drop slot move one pitch aside.
    private func offset(for section: DashboardSection, index: Int) -> CGFloat {
        guard let start = dragStartIndex, let target = dropIndex else { return 0 }
        if section == dragging { return dragOffset }
        if start < target, index > start, index <= target { return -pitch }
        if target < start, index >= target, index < start { return pitch }
        return 0
    }

    private func drag(_ section: DashboardSection, index: Int) -> some Gesture {
        DragGesture(minimumDistance: 3, coordinateSpace: .global)
            .onChanged { value in
                if dragging != section {
                    var transaction = Transaction()
                    transaction.disablesAnimations = true
                    withTransaction(transaction) { dragging = section }
                }
                // Keep the row within the list (index read now: the order may have changed).
                let current = store.order.firstIndex(of: section) ?? index
                let maxUp = -CGFloat(current) * pitch
                let maxDown = CGFloat(store.order.count - 1 - current) * pitch
                let clamped = min(max(value.translation.height, maxUp), maxDown)
                withAnimation(.interactiveSpring(response: 0.22, dampingFraction: 0.86)) { dragOffset = clamped }
            }
            .onEnded { _ in
                let target = dropIndex
                let current = store.order.firstIndex(of: section) ?? index
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    if let target, target != current { store.move(section, by: target - current) }
                    dragging = nil
                    dragOffset = 0
                }
            }
    }

    // MARK: Row

    private func row(_ section: DashboardSection, index: Int) -> some View {
        let isHidden = store.hidden.contains(section)
        let isDragged = dragging == section
        return HStack(spacing: 7) {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(isDragged ? AnyShapeStyle(theme.accent) : AnyShapeStyle(.tertiary))
                .frame(width: 12)
            Image(systemName: section.symbol)
                .font(.system(size: 10.5))
                .foregroundStyle(isHidden ? AnyShapeStyle(.tertiary) : AnyShapeStyle(theme.accent))
                .frame(width: 16)
            Text(section.title)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(isHidden ? .secondary : .primary)
                .strikethrough(isHidden, color: .secondary)
            Spacer(minLength: 4)
            arrow("chevron.up", enabled: index > 0) { store.move(section, by: -1) }
            arrow("chevron.down", enabled: index < store.order.count - 1) { store.move(section, by: 1) }
            Button {
                withAnimation(.easeOut(duration: 0.15)) { store.setHidden(section, !isHidden) }
            } label: {
                Image(systemName: isHidden ? "eye.slash" : "eye")
                    .font(.system(size: 10.5))
                    .foregroundStyle(isHidden ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.secondary))
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .suppressesFocusRing()
            .help(isHidden ? "Show on dashboard" : "Hide from dashboard")
        }
        .padding(.horizontal, 6)
        .frame(height: rowHeight)
        .background(
            isDragged ? theme.accent.opacity(0.16) : theme.tileFill,
            in: RoundedRectangle(cornerRadius: theme.radius(6), style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: theme.radius(6), style: .continuous)
                .strokeBorder(isDragged ? theme.accent.opacity(0.5) : .clear, lineWidth: 1)
        )
        .shadow(color: .black.opacity(isDragged ? 0.35 : 0), radius: 6, y: 2)
        .scaleEffect(isDragged ? 1.02 : 1)
        .contentShape(Rectangle())
    }

    private func arrow(_ symbol: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button {
            withAnimation(.easeOut(duration: 0.18)) { action() }
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .semibold))
                .frame(width: 18, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .suppressesFocusRing()
        .foregroundStyle(.secondary)
        .opacity(enabled ? 1 : 0.25)
        .disabled(!enabled)
    }
}
