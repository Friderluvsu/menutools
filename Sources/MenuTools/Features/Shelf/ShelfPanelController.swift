import AppKit
import SwiftUI

final class ShelfPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Hosting view that reacts to the first click in the never-key shelf panel.
private final class ShelfHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Floating, non-activating drop target shown top-center under the menu bar.
@MainActor
final class ShelfPanelController {
    private unowned let manager: ShelfManager
    private var panel: ShelfPanel?
    private var hostingView: NSView?
    private var idleHide: DispatchWorkItem?

    /// Idle timeout before the panel tucks itself away (items stay on the shelf).
    private let idleDelay: TimeInterval = 90
    private let emptyIdleDelay: TimeInterval = 8

    var isVisible: Bool { panel?.isVisible == true }

    init(manager: ShelfManager) {
        self.manager = manager
    }

    func show() {
        let panel = panel ?? makePanel()
        fitToContent(panel)
        panel.orderFrontRegardless()
        manager.panelVisibilityChanged(true)
        scheduleIdleHide()
    }

    func hide() {
        idleHide?.cancel()
        idleHide = nil
        guard let panel, panel.isVisible else { return }
        panel.orderOut(nil)
        manager.panelVisibilityChanged(false)
    }

    /// Items changed: resize on the next run loop turn (after SwiftUI re-layout).
    func contentDidChange() {
        guard let panel, panel.isVisible else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, let panel = self.panel, panel.isVisible else { return }
            self.fitToContent(panel)
            self.scheduleIdleHide()
        }
    }

    private func makePanel() -> ShelfPanel {
        let panel = ShelfPanel(
            contentRect: NSRect(x: 0, y: 0, width: 240, height: 110),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.animationBehavior = .none
        panel.isReleasedWhenClosed = false

        let host = ShelfHostingView(rootView: ShelfPanelView(manager: manager))
        panel.contentView = host
        hostingView = host
        self.panel = panel
        return panel
    }

    /// Sizes the panel to SwiftUI's fitting size, anchored top-center under the menu bar.
    private func fitToContent(_ panel: ShelfPanel) {
        guard let host = hostingView else { return }
        host.layoutSubtreeIfNeeded()
        let size = host.fittingSize
        let mouse = NSEvent.mouseLocation
        let screen =
            (panel.isVisible ? panel.screen : nil)
            ?? NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) })
            ?? NSScreen.main
        guard let screen else { return }
        let visible = screen.visibleFrame
        let frame = NSRect(
            x: (screen.frame.midX - size.width / 2).rounded(),
            y: (visible.maxY - size.height - 6).rounded(),
            width: size.width,
            height: size.height)
        if panel.frame != frame {
            panel.setFrame(frame, display: true)
            panel.invalidateShadow()
        }
    }

    /// One-shot idle hide; re-arms itself while the cursor is over the panel or a drag is active.
    private func scheduleIdleHide() {
        idleHide?.cancel()
        let delay = manager.items.isEmpty ? emptyIdleDelay : idleDelay
        let work = DispatchWorkItem { [weak self] in
            guard let self, let panel = self.panel, panel.isVisible else { return }
            if self.manager.isFileDragActive || NSMouseInRect(NSEvent.mouseLocation, panel.frame, false) {
                self.scheduleIdleHide()
            } else {
                self.hide()
            }
        }
        idleHide = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }
}

// MARK: - Panel content

struct ShelfPanelView: View {
    @ObservedObject var manager: ShelfManager
    @State private var isTargeted = false

    private let tileSize = CGSize(width: 68, height: 70)
    private let spacing: CGFloat = 6
    private let maxColumns = 5
    private let maxVisibleRows = 3

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if manager.items.isEmpty {
                emptyZone
            } else {
                grid
            }
        }
        .padding(10)
        .frame(width: contentWidth + 20, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.ultraThinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(
                    isTargeted ? Color.accentColor.opacity(0.8) : MacToolsTheme.borderHoverColor,
                    lineWidth: isTargeted ? 1.5 : 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
            manager.handleDrop(providers)
        }
        .fixedSize()
    }

    private var columns: Int { max(1, min(manager.items.count, maxColumns)) }

    private var contentWidth: CGFloat {
        let gridWidth = CGFloat(columns) * tileSize.width + CGFloat(columns - 1) * spacing
        return max(gridWidth, 220)
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "tray.full")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            Text("Shelf")
                .font(.system(size: 12, weight: .semibold))
            if !manager.items.isEmpty {
                Text("\(manager.items.count)")
                    .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            if manager.items.count > 1 {
                ShelfDragAllHandle(manager: manager)
            }
            if !manager.items.isEmpty {
                headerButton("trash", help: "Clear") { manager.clear() }
            }
            headerButton("xmark", help: "Close") { manager.hidePanel() }
        }
        .frame(height: 18)
    }

    private func headerButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 20, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private var emptyZone: some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.down.doc")
                .font(.system(size: 13, weight: .semibold))
            Text("Drop files here")
                .font(.system(size: 12, weight: .medium))
        }
        .foregroundStyle(isTargeted ? Color.accentColor : .secondary)
        .frame(maxWidth: .infinity, minHeight: 56)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                .foregroundStyle(isTargeted ? Color.accentColor.opacity(0.7) : Color.secondary.opacity(0.35))
        )
    }

    @ViewBuilder
    private var grid: some View {
        let rows = Int((Double(manager.items.count) / Double(maxColumns)).rounded(.up))
        let gridItems = Array(repeating: GridItem(.fixed(tileSize.width), spacing: spacing), count: columns)
        let tiles = LazyVGrid(columns: gridItems, alignment: .leading, spacing: spacing) {
            ForEach(manager.items) { item in
                ShelfTile(item: item, manager: manager)
                    .frame(width: tileSize.width, height: tileSize.height)
            }
        }
        if rows > maxVisibleRows {
            // Only very large shelves scroll; normal use stays scroll-free.
            ScrollView(.vertical, showsIndicators: false) { tiles }
                .frame(
                    height: CGFloat(maxVisibleRows) * tileSize.height + CGFloat(maxVisibleRows - 1) * spacing
                        + tileSize.height / 2)
        } else {
            tiles
        }
    }
}

private struct ShelfTile: View {
    let item: ShelfItem
    @ObservedObject var manager: ShelfManager
    @State private var isHovered = false

    var body: some View {
        VStack(spacing: 3) {
            Image(nsImage: manager.icon(for: item))
                .resizable()
                .interpolation(.high)
                .frame(width: 36, height: 36)
            Text(item.name)
                .font(.system(size: 10))
                .lineLimit(2)
                .truncationMode(.middle)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
        }
        .padding(4)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isHovered ? MacToolsTheme.hoverBackground : Color.clear)
        )
        .overlay(
            ShelfDragSource(
                urls: { [item.url] },
                menu: { ShelfMenu.menu(for: item, manager: manager) },
                onDoubleClick: { manager.open(item) },
                onHover: { isHovered = $0 }
            )
        )
        .overlay(alignment: .topTrailing) {
            if isHovered {
                Button {
                    manager.remove(id: item.id)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .offset(x: 2, y: -2)
                .help("Remove")
            }
        }
        .help(item.url.path)
    }
}

/// Drag handle that drags every shelf item at once (right-click for Copy/Move All).
struct ShelfDragAllHandle: View {
    @ObservedObject var manager: ShelfManager
    @State private var isHovered = false

    var body: some View {
        Image(systemName: "square.stack.3d.up")
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(isHovered ? .primary : .secondary)
            .frame(width: 20, height: 18)
            .overlay(
                ShelfDragSource(
                    urls: { manager.items.map(\.url) },
                    menu: { ShelfMenu.allItemsMenu(manager: manager) },
                    onHover: { isHovered = $0 }
                )
            )
            .help("Drag all")
    }
}
