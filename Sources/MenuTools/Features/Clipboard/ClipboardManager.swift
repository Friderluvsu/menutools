import AppKit
import Combine
import Foundation

struct ClipboardItem: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var text: String
    var snippet: String
    var timestamp: Date
    var isPinned: Bool = false

    var charCount: Int {
        text.count
    }

    var lineCount: Int {
        // Same result as components(separatedBy: .newlines).count without allocating the pieces.
        var breaks = 0
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x0A...0x0D, 0x85, 0x2028, 0x2029: breaks += 1
            default: break
            }
        }
        return breaks + 1
    }

    var timeAgoFormatted: String {
        let seconds = Int(-timestamp.timeIntervalSinceNow)
        if seconds < 10 { return "Just now" }
        if seconds < 60 { return "\(seconds)s ago" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m ago" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)h ago" }
        let days = hours / 24
        return "\(days)d ago"
    }

    init(text: String, isPinned: Bool = false) {
        self.id = UUID()
        self.text = text
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let singleLine =
            trimmed
            .replacingOccurrences(of: "\t", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: "")
        self.snippet = singleLine.count > 120 ? String(singleLine.prefix(120)) + "..." : singleLine
        self.timestamp = Date()
        self.isPinned = isPinned
    }
}

@MainActor
final class ClipboardManager: ObservableObject {
    @Published var items: [ClipboardItem] = []
    @Published var searchQuery: String = ""
    @Published var isHUDVisible: Bool = false
    @Published var selectedIndex: Int = 0
    @Published var maxHistoryItems: Int = 100

    /// Filtered list, recomputed only when items or the (debounced) query change — not on every view update.
    @Published private(set) var visibleItems: [ClipboardItem] = []

    private var lastChangeCount: Int = 0
    private var timerCancellable: AnyCancellable?
    private var visibleItemsCancellable: AnyCancellable?
    /// The query `visibleItems` was last filtered with.
    private var filteredQuery: String = ""
    private var terminateObserver: NSObjectProtocol?
    private var pendingSave: DispatchWorkItem?
    private let storageURL: URL
    /// One serial queue so writes can never land out of order.
    private let saveQueue = DispatchQueue(label: "MenuTools.ClipboardSave", qos: .utility)
    /// Clips bigger than this are not kept (a single huge copy would sit in RAM and in the JSON file).
    private static let maxClipBytes = 2_000_000

    var filteredItems: [ClipboardItem] { visibleItems }

    init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("MenuTools", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.storageURL = dir.appendingPathComponent("clipboard_history.json")

        loadHistory()
        self.lastChangeCount = NSPasteboard.general.changeCount
        startMonitoring()
        startFiltering()

        // The save is debounced, so make sure the last change reaches disk on quit.
        terminateObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.flushPendingSave(wait: true) }
        }
    }

    private func startFiltering() {
        let debouncedQuery = $searchQuery
            .removeDuplicates()
            .debounce(for: .milliseconds(120), scheduler: RunLoop.main)

        visibleItemsCancellable = Publishers.CombineLatest($items, debouncedQuery)
            .sink { [weak self] items, query in
                guard let self else { return }
                self.filteredQuery = query
                self.visibleItems = self.filter(items, query: query)
            }
        visibleItems = sortedItems(items)
    }

    /// Catches `visibleItems` up with the query right away, so a key pressed within the debounce
    /// window acts on the list the user is about to see, not the stale one.
    func flushFilter() {
        guard searchQuery != filteredQuery else { return }
        filteredQuery = searchQuery
        visibleItems = filter(items, query: searchQuery)
    }

    /// Case-insensitive substring search without copying each clip's text.
    private func filter(_ list: [ClipboardItem], query raw: String) -> [ClipboardItem] {
        let query = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return sortedItems(list) }
        let matching = list.filter { $0.text.range(of: query, options: .caseInsensitive) != nil }
        return sortedItems(matching)
    }

    func startMonitoring() {
        timerCancellable?.cancel()
        // changeCount is an O(1) read; the HUD forces an extra check when it opens.
        timerCancellable = Timer.publish(every: 1.0, tolerance: 0.5, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                self?.checkPasteboard()
            }
    }

    func checkPasteboard() {
        let currentCount = NSPasteboard.general.changeCount
        guard currentCount != lastChangeCount else { return }

        var copiedString: String? = NSPasteboard.general.string(forType: .string)
        if copiedString == nil || copiedString?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true {
            if let str = NSPasteboard.general.readObjects(forClasses: [NSString.self], options: nil)?.first as? String {
                copiedString = str
            }
        }

        lastChangeCount = currentCount

        guard let text = copiedString, text.utf8.count <= Self.maxClipBytes,
            !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return
        }

        addClip(text)
    }

    func addClip(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        var list = items

        // If exact text already exists as pinned, update timestamp only
        if let pinnedIndex = list.firstIndex(where: { $0.isPinned && $0.text == text }) {
            list[pinnedIndex].timestamp = Date()
            commit(list)
            return
        }

        // Remove duplicate unpinned item if exists
        list.removeAll { !$0.isPinned && $0.text == text }
        list.insert(ClipboardItem(text: text), at: 0)

        // Trim unpinned history
        let pinned = list.filter { $0.isPinned }
        let unpinned = list.filter { !$0.isPinned }
        let allowedUnpinned = max(0, maxHistoryItems - pinned.count)
        commit(pinned + Array(unpinned.prefix(allowedUnpinned)))
    }

    func copyAndPaste(item: ClipboardItem, simulatePaste: Bool = true) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(item.text, forType: .string)
        lastChangeCount = NSPasteboard.general.changeCount

        // Update timestamp and reposition
        if let idx = items.firstIndex(where: { $0.id == item.id }) {
            var list = items
            list[idx].timestamp = Date()
            commit(list)
        }

        if simulatePaste {
            ClipboardHUDWindowController.shared.hideAndPaste()
        }
    }

    static func simulatePasteCommand() {
        guard let source = CGEventSource(stateID: .combinedSessionState) else { return }
        let vKeyCode: CGKeyCode = 9  // Key 'V'

        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: true)
        keyDown?.flags = .maskCommand
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: false)
        keyUp?.flags = .maskCommand

        keyDown?.post(tap: .cgSessionEventTap)
        usleep(15_000)
        keyUp?.post(tap: .cgSessionEventTap)
    }

    func togglePin(id: UUID) {
        if let idx = items.firstIndex(where: { $0.id == id }) {
            var list = items
            list[idx].isPinned.toggle()
            list[idx].timestamp = Date()
            commit(list)
        }
    }

    func deleteItem(id: UUID) {
        commit(items.filter { $0.id != id })
        clampSelectedIndex()
    }

    func clearHistory() {
        // Keep pinned items
        NSPasteboard.general.clearContents()
        lastChangeCount = NSPasteboard.general.changeCount
        commit(items.filter { $0.isPinned })
        selectedIndex = 0
    }

    func clampSelectedIndex() {
        let count = filteredItems.count
        if count == 0 {
            selectedIndex = 0
        } else if selectedIndex >= count {
            selectedIndex = count - 1
        } else if selectedIndex < 0 {
            selectedIndex = 0
        }
    }

    private func sortedItems(_ list: [ClipboardItem]) -> [ClipboardItem] {
        let byNewest: (ClipboardItem, ClipboardItem) -> Bool = { $0.timestamp > $1.timestamp }
        let pinned = list.filter { $0.isPinned }.sorted(by: byNewest)
        let unpinned = list.filter { !$0.isPinned }.sorted(by: byNewest)
        return pinned + unpinned
    }

    /// Sorts, publishes `items` exactly once (one filter pass, one view update) and schedules a save.
    private func commit(_ list: [ClipboardItem]) {
        items = sortedItems(list)
        scheduleSave()
    }

    /// Coalesces bursts of changes into a single background write.
    private func scheduleSave() {
        pendingSave?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.flushPendingSave() }
        }
        pendingSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: work)
    }

    private func flushPendingSave(wait: Bool = false) {
        if let pending = pendingSave {
            pending.cancel()
            pendingSave = nil

            let itemsToSave = items
            let url = storageURL
            saveQueue.async {
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .iso8601
                if let data = try? encoder.encode(itemsToSave) {
                    try? data.write(to: url, options: .atomic)
                }
            }
        }
        // On quit, block until the write has finished.
        if wait { saveQueue.sync {} }
    }

    private func loadHistory() {
        guard let data = try? Data(contentsOf: storageURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let saved = try? decoder.decode([ClipboardItem].self, from: data) {
            self.items = sortedItems(saved)
        }
    }
}
