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
        text.components(separatedBy: .newlines).count
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

    private var lastChangeCount: Int = 0
    private var timerCancellable: AnyCancellable?
    private let storageURL: URL

    var filteredItems: [ClipboardItem] {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if query.isEmpty {
            return sortedItems(items)
        }
        let matching = items.filter { $0.text.lowercased().contains(query) }
        return sortedItems(matching)
    }

    init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("MenuTools", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.storageURL = dir.appendingPathComponent("clipboard_history.json")

        loadHistory()
        self.lastChangeCount = NSPasteboard.general.changeCount
        startMonitoring()
    }

    func startMonitoring() {
        timerCancellable?.cancel()
        timerCancellable = Timer.publish(every: 0.75, tolerance: 0.25, on: .main, in: .common)
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

        guard let text = copiedString,
            !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return
        }

        addClip(text)
    }

    func addClip(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        // If exact text already exists as pinned, update timestamp only
        if let pinnedIndex = items.firstIndex(where: { $0.isPinned && $0.text == text }) {
            items[pinnedIndex].timestamp = Date()
            reorderAndSave()
            return
        }

        // Remove duplicate unpinned item if exists
        items.removeAll { !$0.isPinned && $0.text == text }

        let newItem = ClipboardItem(text: text)
        items.insert(newItem, at: 0)

        // Trim unpinned history
        let pinned = items.filter { $0.isPinned }
        let unpinned = items.filter { !$0.isPinned }
        let allowedUnpinned = max(0, maxHistoryItems - pinned.count)
        items = pinned + Array(unpinned.prefix(allowedUnpinned))

        reorderAndSave()
    }

    func copyAndPaste(item: ClipboardItem, simulatePaste: Bool = true) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(item.text, forType: .string)
        lastChangeCount = NSPasteboard.general.changeCount

        // Update timestamp and reposition
        if let idx = items.firstIndex(where: { $0.id == item.id }) {
            items[idx].timestamp = Date()
            reorderAndSave()
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
            items[idx].isPinned.toggle()
            items[idx].timestamp = Date()
            reorderAndSave()
        }
    }

    func deleteItem(id: UUID) {
        items.removeAll { $0.id == id }
        reorderAndSave()
        clampSelectedIndex()
    }

    func clearHistory() {
        // Keep pinned items
        items.removeAll { !$0.isPinned }
        NSPasteboard.general.clearContents()
        lastChangeCount = NSPasteboard.general.changeCount
        reorderAndSave()
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
        let pinned = list.filter { $0.isPinned }.sorted { $0.timestamp > $1.timestamp }
        let unpinned = list.filter { !$0.isPinned }.sorted { $0.timestamp > $1.timestamp }
        return pinned + unpinned
    }

    private func reorderAndSave() {
        items = sortedItems(items)
        saveHistory()
    }

    private func saveHistory() {
        let itemsToSave = items
        let url = storageURL
        Task.detached {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            if let data = try? encoder.encode(itemsToSave) {
                try? data.write(to: url, options: .atomic)
            }
        }
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
