import AppKit
import SwiftUI

/// Transparent AppKit overlay that turns a SwiftUI view into a real file drag source.
/// Unlike SwiftUI `.onDrag`, an `NSDraggingSource` with `.fileURL` writers lets the receiver
/// pick copy vs move with the standard modifiers (Finder: same volume moves, ⌥ copies).
struct ShelfDragSource: NSViewRepresentable {
    let urls: () -> [URL]
    var menu: (() -> NSMenu?)? = nil
    var onDoubleClick: (() -> Void)? = nil
    var onHover: ((Bool) -> Void)? = nil

    func makeNSView(context: Context) -> ShelfDragSourceView {
        let view = ShelfDragSourceView()
        update(view)
        return view
    }

    func updateNSView(_ nsView: ShelfDragSourceView, context: Context) {
        update(nsView)
    }

    private func update(_ view: ShelfDragSourceView) {
        view.urlsProvider = urls
        view.menuProvider = menu
        view.onDoubleClick = onDoubleClick
        view.onHover = onHover
    }
}

final class ShelfDragSourceView: NSView, NSDraggingSource {
    var urlsProvider: () -> [URL] = { [] }
    var menuProvider: (() -> NSMenu?)?
    var onDoubleClick: (() -> Void)?
    var onHover: ((Bool) -> Void)?

    private var mouseDownLocation: NSPoint?
    private var trackingArea: NSTrackingArea?

    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        guard onHover != nil else { return }
        // .activeAlways: the floating shelf panel never becomes key.
        let area = NSTrackingArea(
            rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { onHover?(true) }
    override func mouseExited(with event: NSEvent) { onHover?(false) }

    override func mouseDown(with event: NSEvent) {
        mouseDownLocation = event.locationInWindow
        if event.clickCount == 2 {
            mouseDownLocation = nil
            onDoubleClick?()
        }
    }

    override func mouseUp(with event: NSEvent) {
        mouseDownLocation = nil
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = mouseDownLocation else { return }
        let current = event.locationInWindow
        guard hypot(current.x - start.x, current.y - start.y) > 3 else { return }
        mouseDownLocation = nil

        let urls = urlsProvider()
        guard !urls.isEmpty else { return }
        let iconSize = NSSize(width: 40, height: 40)
        let origin = convert(event.locationInWindow, from: nil)
        let items: [NSDraggingItem] = urls.prefix(30).enumerated().map { index, url in
            let item = NSDraggingItem(pasteboardWriter: url as NSURL)
            let icon = NSWorkspace.shared.icon(forFile: url.path)
            let offset = CGFloat(min(index, 4)) * 4
            item.setDraggingFrame(
                NSRect(
                    x: origin.x - iconSize.width / 2 + offset,
                    y: origin.y - iconSize.height / 2 - offset,
                    width: iconSize.width,
                    height: iconSize.height),
                contents: icon)
            return item
        }
        let session = beginDraggingSession(with: items, event: event, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
        session.draggingFormation = .pile
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        menuProvider?() ?? super.menu(for: event)
    }

    // MARK: NSDraggingSource

    func draggingSession(
        _ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        context == .outsideApplication ? [.copy, .move, .link, .generic, .delete] : .copy
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        ShelfManager.shared.dragOutEnded(operation: operation)
    }
}

/// Builds closure-backed NSMenus (NSMenuItem.target is weak, so the action box is retained
/// through `representedObject`).
@MainActor
enum ShelfMenu {
    private final class ActionBox: NSObject {
        let handler: () -> Void
        init(_ handler: @escaping () -> Void) { self.handler = handler }
        @objc func run() { handler() }
    }

    static func item(_ title: String, symbol: String? = nil, _ handler: @escaping () -> Void) -> NSMenuItem {
        let box = ActionBox(handler)
        let item = NSMenuItem(title: title, action: #selector(ActionBox.run), keyEquivalent: "")
        item.target = box
        item.representedObject = box
        if let symbol {
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        }
        return item
    }

    static func menu(for item: ShelfItem, manager: ShelfManager) -> NSMenu {
        let menu = NSMenu()
        menu.addItem(Self.item("Open", symbol: "arrow.up.forward.app") { manager.open(item) })
        menu.addItem(Self.item("Show in Finder", symbol: "folder") { manager.reveal(item) })
        menu.addItem(.separator())
        menu.addItem(Self.item("Copy to…", symbol: "doc.on.doc") { manager.copy([item]) })
        menu.addItem(Self.item("Move to…", symbol: "arrow.right.doc.on.clipboard") { manager.move([item]) })
        menu.addItem(.separator())
        menu.addItem(Self.item("Remove", symbol: "xmark") { manager.remove(id: item.id) })
        return menu
    }

    static func allItemsMenu(manager: ShelfManager) -> NSMenu {
        let menu = NSMenu()
        menu.addItem(Self.item("Copy All to…", symbol: "doc.on.doc") { manager.copy(manager.items) })
        menu.addItem(Self.item("Move All to…", symbol: "arrow.right.doc.on.clipboard") { manager.move(manager.items) })
        menu.addItem(.separator())
        menu.addItem(Self.item("Clear", symbol: "trash") { manager.clear() })
        return menu
    }
}
