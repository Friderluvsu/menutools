import AppKit
import Combine

struct ClipboardItem: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var text: String
    var snippet: String
    var timestamp: Date
    var isPinned: Bool = false

    init(text: String, isPinned: Bool = false) {
        self.id = UUID()
        self.text = text
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let singleLine = trimmed.replacingOccurrences(of: "\n", with: " ")
        self.snippet = singleLine.count > 100 ? String(singleLine.prefix(100)) + "..." : singleLine
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
            return items
        }
        return items.filter { $0.text.lowercased().contains(query) }
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
        timerCancellable = Timer.publish(every: 0.5, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                self?.checkPasteboard()
            }
    }

    private func checkPasteboard() {
        let currentCount = NSPasteboard.general.changeCount
        guard currentCount != lastChangeCount else { return }
        lastChangeCount = currentCount

        guard let copiedString = NSPasteboard.general.string(forType: .string),
            !copiedString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return
        }

        addClip(copiedString)
    }

    func addClip(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        // Remove duplicate non-pinned item if exists
        items.removeAll { !$0.isPinned && $0.text == text }

        let newItem = ClipboardItem(text: text)
        items.insert(newItem, at: 0)

        // Trim history
        if items.count > maxHistoryItems {
            let pinned = items.filter { $0.isPinned }
            let unpinned = items.filter { !$0.isPinned }
            let allowedUnpinned = max(0, maxHistoryItems - pinned.count)
            items = pinned + Array(unpinned.prefix(allowedUnpinned))
        }

        saveHistory()
    }

    func copyAndPaste(item: ClipboardItem, simulatePaste: Bool = true) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(item.text, forType: .string)
        lastChangeCount = NSPasteboard.general.changeCount

        // Move to top of history
        if let idx = items.firstIndex(where: { $0.id == item.id }) {
            var updated = items.remove(at: idx)
            updated.timestamp = Date()
            items.insert(updated, at: 0)
            saveHistory()
        }

        if simulatePaste {
            // Dismiss HUD first
            ClipboardHUDWindowController.shared.hide()

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                Self.simulatePasteCommand()
            }
        }
    }

    static func simulatePasteCommand() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let vKeyCode: CGKeyCode = 9  // Key 'V'

        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: true)
        keyDown?.flags = .maskCommand
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: false)
        keyUp?.flags = .maskCommand

        keyDown?.post(tap: .cghidEventTap)
        keyUp?.post(tap: .cghidEventTap)
    }

    func togglePin(id: UUID) {
        if let idx = items.firstIndex(where: { $0.id == id }) {
            items[idx].isPinned.toggle()
            saveHistory()
        }
    }

    func deleteItem(id: UUID) {
        items.removeAll { $0.id == id }
        saveHistory()
    }

    func clearHistory() {
        // Keep pinned items
        items.removeAll { !$0.isPinned }
        NSPasteboard.general.clearContents()
        lastChangeCount = NSPasteboard.general.changeCount
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
            self.items = saved
        }
    }
}
