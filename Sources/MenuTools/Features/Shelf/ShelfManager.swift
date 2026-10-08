import AppKit
import Combine
import UniformTypeIdentifiers

/// A file held on the Shelf. Files are referenced in place (never copied on drop),
/// so dragging an item out with "move" semantics really moves the original file.
struct ShelfItem: Identifiable, Hashable {
    let id: UUID
    let url: URL
    let name: String
    let addedAt: Date

    init(id: UUID = UUID(), url: URL, addedAt: Date = Date()) {
        self.id = id
        self.url = url
        self.name = url.lastPathComponent
        self.addedAt = addedAt
    }
}

/// Temporary drop storage (NotchDrop / Dropover / Yoink style).
///
/// Global drag detection follows boring.notch's `DragDetector`: a global `.leftMouseDragged`
/// monitor compares `NSPasteboard(name: .drag).changeCount` (one integer compare) and only
/// inspects pasteboard types once per new drag. Global *mouse* monitors need no
/// Accessibility / Input Monitoring permission (only key-event monitors do).
@MainActor
final class ShelfManager: ObservableObject {
    static let shared = ShelfManager()

    @Published private(set) var items: [ShelfItem] = []
    /// True between the start of a global file drag and the next mouse up.
    @Published private(set) var isFileDragActive = false
    @Published private(set) var isPanelVisible = false

    @Published var isEnabled: Bool {
        didSet {
            guard isEnabled != oldValue else { return }
            UserDefaults.standard.set(isEnabled, forKey: Keys.isEnabled)
            if isEnabled { start() } else { stop() }
        }
    }

    @Published var showOnDrag: Bool {
        didSet {
            guard showOnDrag != oldValue else { return }
            UserDefaults.standard.set(showOnDrag, forKey: Keys.showOnDrag)
            updateDragMonitor()
        }
    }

    private enum Keys {
        static let isEnabled = "ShelfEnabled"
        static let showOnDrag = "ShelfShowOnDrag"
    }

    private struct StoredItem: Codable {
        let path: String
        let addedAt: Date
    }

    private let dragPasteboard = NSPasteboard(name: .drag)
    private var dragMonitor: Any?
    private var dragEndMonitor: Any?
    private var lastDragChangeCount = 0
    private var lastDragCheck: TimeInterval = 0
    private var panelShownByDrag = false
    private var droppedDuringDrag = false
    /// True from the drag's mouse up until the keep-or-hide decision: dropped URLs arrive asynchronously.
    private var dragDecisionPending = false
    private var isStarted = false
    private var savePending = false
    private var iconCache: [URL: NSImage] = [:]
    private lazy var panelController = ShelfPanelController(manager: self)

    /// Serial, so successive saves can never land out of order.
    private static let saveQueue = DispatchQueue(label: "MenuTools.ShelfSave", qos: .utility)

    private static let storeURL: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("MenuTools/shelf.json")
    }()

    private init() {
        let defaults = UserDefaults.standard
        isEnabled = defaults.object(forKey: Keys.isEnabled) as? Bool ?? true
        showOnDrag = defaults.object(forKey: Keys.showOnDrag) as? Bool ?? true
        load()
    }

    // MARK: - Lifecycle

    /// Call once at launch. Installs the global drag monitor when enabled.
    func start() {
        guard isEnabled else { return }
        isStarted = true
        updateDragMonitor()
    }

    func stop() {
        isStarted = false
        removeDragMonitors()
        hidePanel()
        // Also runs on quit: write anything still pending and wait for in-flight writes.
        flushPendingSave()
    }

    // MARK: - Items

    @discardableResult
    func add(urls: [URL]) -> Int {
        var known = Set(items.map { $0.url.path })
        var added = 0
        for raw in urls {
            guard let url = Self.normalized(raw), !known.contains(url.path),
                FileManager.default.fileExists(atPath: url.path)
            else { continue }
            known.insert(url.path)
            items.append(ShelfItem(url: url))
            added += 1
        }
        guard added > 0 else { return 0 }
        if isFileDragActive || dragDecisionPending { droppedDuringDrag = true }
        scheduleSave()
        panelController.contentDidChange()
        return added
    }

    func remove(id: ShelfItem.ID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        iconCache[items[index].url] = nil
        items.remove(at: index)
        scheduleSave()
        panelController.contentDidChange()
    }

    func clear() {
        guard !items.isEmpty else { return }
        items.removeAll()
        iconCache.removeAll()
        scheduleSave()
        panelController.contentDidChange()
    }

    /// Drops items whose files were moved or deleted elsewhere.
    func removeMissing() {
        let fm = FileManager.default
        let kept = items.filter { fm.fileExists(atPath: $0.url.path) }
        guard kept.count != items.count else { return }
        let keptURLs = Set(kept.map(\.url))
        iconCache = iconCache.filter { keptURLs.contains($0.key) }
        items = kept
        scheduleSave()
        panelController.contentDidChange()
    }

    func icon(for item: ShelfItem) -> NSImage {
        if let cached = iconCache[item.url] { return cached }
        let image = NSWorkspace.shared.icon(forFile: item.url.path)
        iconCache[item.url] = image
        return image
    }

    /// Accepts SwiftUI `onDrop(of: [.fileURL])` providers. Returns false if none carry files.
    func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        let fileProviders = providers.filter {
            $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
        }
        guard !fileProviders.isEmpty else { return false }
        for provider in fileProviders {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in ShelfManager.shared.add(urls: [url]) }
            }
        }
        return true
    }

    /// Called by drag sources when a drag-out ends. Moved / trashed files leave the shelf.
    func dragOutEnded(operation: NSDragOperation) {
        // Global monitors never see our own drags: mark this pasteboard content as seen, or the next
        // unrelated drag elsewhere (e.g. a window move) would be mistaken for a file drag.
        lastDragChangeCount = dragPasteboard.changeCount
        removeMissing()
        // Finder may finish a cross-volume move slightly later.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.removeMissing()
        }
    }

    // MARK: - File actions

    func open(_ item: ShelfItem) {
        NSWorkspace.shared.open(item.url)
    }

    func reveal(_ item: ShelfItem) {
        NSWorkspace.shared.activateFileViewerSelecting([item.url])
    }

    func copy(_ items: [ShelfItem]) {
        transfer(items, move: false)
    }

    func move(_ items: [ShelfItem]) {
        transfer(items, move: true)
    }

    private func transfer(_ selection: [ShelfItem], move: Bool) {
        guard !selection.isEmpty else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = move ? "Move" : "Copy"
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let folder = panel.url else { return }

        let sources = selection.map(\.url)
        let ids = selection.map(\.id)
        // Cross-volume copies can be large: keep them off the main thread.
        Task.detached(priority: .userInitiated) {
            var failure: Error?
            var movedIDs: [ShelfItem.ID] = []
            let fm = FileManager.default
            for (source, id) in zip(sources, ids) {
                let target = Self.uniqueDestination(for: source, in: folder)
                do {
                    if move {
                        try fm.moveItem(at: source, to: target)
                        movedIDs.append(id)
                    } else {
                        try fm.copyItem(at: source, to: target)
                    }
                } catch {
                    failure = error
                }
            }
            let reportedError = failure
            let moved = movedIDs
            await MainActor.run {
                let manager = ShelfManager.shared
                if move {
                    // Only files that really moved leave the shelf; failed ones stay where they are.
                    for id in moved { manager.remove(id: id) }
                    manager.removeMissing()
                }
                if let reportedError {
                    NSAlert(error: reportedError).runModal()
                }
            }
        }
    }

    nonisolated private static func uniqueDestination(for source: URL, in folder: URL) -> URL {
        let fm = FileManager.default
        var target = folder.appendingPathComponent(source.lastPathComponent)
        guard fm.fileExists(atPath: target.path) else { return target }
        let base = source.deletingPathExtension().lastPathComponent
        let ext = source.pathExtension
        var index = 2
        repeat {
            let name = ext.isEmpty ? "\(base) \(index)" : "\(base) \(index).\(ext)"
            target = folder.appendingPathComponent(name)
            index += 1
        } while fm.fileExists(atPath: target.path)
        return target
    }

    // MARK: - Panel

    func showPanel() {
        guard isEnabled else { return }
        removeMissing()
        panelShownByDrag = false
        panelController.show()
    }

    func hidePanel() {
        panelController.hide()
    }

    func togglePanel() {
        if isPanelVisible { hidePanel() } else { showPanel() }
    }

    func panelVisibilityChanged(_ visible: Bool) {
        if isPanelVisible != visible { isPanelVisible = visible }
        if !visible { panelShownByDrag = false }
    }

    // MARK: - Global drag detection

    private func updateDragMonitor() {
        if isStarted && isEnabled && showOnDrag {
            guard dragMonitor == nil else { return }
            lastDragChangeCount = dragPasteboard.changeCount
            dragMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDragged) { event in
                let timestamp = event.timestamp
                MainActor.assumeIsolated {
                    ShelfManager.shared.handleGlobalDrag(timestamp: timestamp)
                }
            }
        } else {
            removeDragMonitors()
        }
    }

    private func removeDragMonitors() {
        if let dragMonitor { NSEvent.removeMonitor(dragMonitor) }
        dragMonitor = nil
        removeDragEndMonitor()
        if isFileDragActive { isFileDragActive = false }
    }

    /// Hot path: runs for every global left-mouse drag event. Throttled integer compare only.
    private func handleGlobalDrag(timestamp: TimeInterval) {
        guard !isFileDragActive, timestamp - lastDragCheck > 0.05 else { return }
        lastDragCheck = timestamp
        let changeCount = dragPasteboard.changeCount
        guard changeCount != lastDragChangeCount else { return }
        lastDragChangeCount = changeCount
        guard dragPasteboard.types?.contains(.fileURL) == true else { return }
        beginFileDrag()
    }

    private func beginFileDrag() {
        isFileDragActive = true
        droppedDuringDrag = false
        if !panelController.isVisible {
            removeMissing()
            panelShownByDrag = true
            panelController.show()
        }
        // Mouse-down is a fallback reset in case the drag's mouse-up is swallowed by a drop target.
        dragEndMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseUp, .leftMouseDown]) { _ in
            MainActor.assumeIsolated {
                ShelfManager.shared.endFileDrag()
            }
        }
    }

    private func endFileDrag() {
        removeDragEndMonitor()
        guard isFileDragActive else { return }
        isFileDragActive = false
        dragDecisionPending = true
        // Give async drop item providers a moment to deliver URLs before deciding.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self else { return }
            self.dragDecisionPending = false
            guard !self.isFileDragActive else { return }
            if self.panelShownByDrag && !self.droppedDuringDrag {
                self.hidePanel()
            } else {
                // A drop pins the panel until it is closed or goes idle.
                self.panelShownByDrag = false
                self.panelController.contentDidChange()
            }
        }
    }

    private func removeDragEndMonitor() {
        if let dragEndMonitor { NSEvent.removeMonitor(dragEndMonitor) }
        dragEndMonitor = nil
    }

    // MARK: - Persistence

    private func load() {
        guard let data = try? Data(contentsOf: Self.storeURL),
            let stored = try? JSONDecoder().decode([StoredItem].self, from: data)
        else { return }
        let fm = FileManager.default
        items = stored.compactMap { entry in
            guard fm.fileExists(atPath: entry.path) else { return nil }
            return ShelfItem(url: URL(fileURLWithPath: entry.path), addedAt: entry.addedAt)
        }
        if items.count != stored.count { scheduleSave() }
    }

    /// Coalesces several mutations in one run loop turn into a single background write.
    private func scheduleSave() {
        guard !savePending else { return }
        savePending = true
        DispatchQueue.main.async { [weak self] in
            guard let self, self.savePending else { return }
            self.writeSnapshot(waitUntilDone: false)
        }
    }

    private func flushPendingSave() {
        if savePending {
            writeSnapshot(waitUntilDone: true)
        } else {
            Self.saveQueue.sync {}
        }
    }

    private func writeSnapshot(waitUntilDone: Bool) {
        savePending = false
        let stored = items.map { StoredItem(path: $0.url.path, addedAt: $0.addedAt) }
        let url = Self.storeURL
        let work = {
            guard let data = try? JSONEncoder().encode(stored) else { return }
            try? FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
        }
        if waitUntilDone {
            Self.saveQueue.sync(execute: work)
        } else {
            Self.saveQueue.async(execute: work)
        }
    }

    private static func normalized(_ url: URL) -> URL? {
        guard url.isFileURL else { return nil }
        var resolved = url
        // Finder may hand out file reference URLs (file:///.file/id=...).
        if url.path.hasPrefix("/.file/id="), let path = (url as NSURL).filePathURL {
            resolved = path
        }
        return resolved.standardizedFileURL
    }
}
