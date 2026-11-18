import AppKit
import Carbon
import Combine
import CryptoKit
import Foundation
import ImageIO

enum ClipboardItemKind: String, Codable {
    case text, image, files
}

struct ClipboardItem: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var kind: ClipboardItemKind = .text
    /// Search and dedupe key: the text, the file paths joined by "\n", or "" for an image.
    var text: String
    var snippet: String
    var timestamp: Date
    var isPinned: Bool = false
    var imageHash: String?
    var imageFile: String?
    var imageWidth: Int?
    var imageHeight: Int?
    var files: [String]?

    /// What identifies the content for dedupe.
    var contentKey: String {
        kind == .image ? (imageHash ?? "") : text
    }

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

    /// Right-hand detail for a row: "1200×800", "3 files" or the character count.
    var metaText: String {
        switch kind {
        case .text: return "\(charCount) ch"
        case .image: return "\(imageWidth ?? 0)×\(imageHeight ?? 0)"
        case .files:
            let n = files?.count ?? 0
            return "\(n) file\(n == 1 ? "" : "s")"
        }
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

    init(files paths: [String]) {
        self.id = UUID()
        self.kind = .files
        self.files = paths
        self.text = paths.joined(separator: "\n")
        let names = paths.map { ($0 as NSString).lastPathComponent }.joined(separator: ", ")
        self.snippet = names.count > 120 ? String(names.prefix(120)) + "..." : names
        self.timestamp = Date()
    }

    init(imageFile: String, hash: String, width: Int, height: Int) {
        self.id = UUID()
        self.kind = .image
        self.text = ""
        self.snippet = "Image \(width)×\(height)"
        self.imageFile = imageFile
        self.imageHash = hash
        self.imageWidth = width
        self.imageHeight = height
        self.timestamp = Date()
    }

    private enum CodingKeys: String, CodingKey {
        case id, kind, text, snippet, timestamp, isPinned, imageHash, imageFile, imageWidth, imageHeight, files
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        kind = try c.decodeIfPresent(ClipboardItemKind.self, forKey: .kind) ?? .text
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        snippet = try c.decodeIfPresent(String.self, forKey: .snippet) ?? ""
        timestamp = try c.decodeIfPresent(Date.self, forKey: .timestamp) ?? Date()
        isPinned = try c.decodeIfPresent(Bool.self, forKey: .isPinned) ?? false
        imageHash = try c.decodeIfPresent(String.self, forKey: .imageHash)
        imageFile = try c.decodeIfPresent(String.self, forKey: .imageFile)
        imageWidth = try c.decodeIfPresent(Int.self, forKey: .imageWidth)
        imageHeight = try c.decodeIfPresent(Int.self, forKey: .imageHeight)
        files = try c.decodeIfPresent([String].self, forKey: .files)
    }
}

@MainActor
final class ClipboardManager: ObservableObject {
    @Published var items: [ClipboardItem] = []
    @Published var searchQuery: String = ""
    @Published var isHUDVisible: Bool = false
    @Published var selectedIndex: Int = 0
    @Published var maxHistoryItems: Int = 100
    @Published var captureImages: Bool = true {
        didSet { UserDefaults.standard.set(captureImages, forKey: Self.captureImagesKey) }
    }
    @Published var captureFiles: Bool = true {
        didSet { UserDefaults.standard.set(captureFiles, forKey: Self.captureFilesKey) }
    }
    @Published var plainPasteHotkey: Bool = false {
        didSet {
            UserDefaults.standard.set(plainPasteHotkey, forKey: Self.plainPasteKey)
            updatePlainPasteHotkey()
        }
    }

    private static let captureImagesKey = "ClipboardCaptureImages"
    private static let captureFilesKey = "ClipboardCaptureFiles"
    private static let plainPasteKey = "ClipboardPlainPasteHotkey"
    private static let plainPasteHotkeyID: UInt32 = 2
    /// Images bigger than this (PNG bytes) are not kept.
    private static let maxImageBytes = 20_000_000
    /// Newest unpinned image items kept.
    private static let maxImageItems = 20

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
    private let imagesDir: URL
    private let thumbnailCache = NSCache<NSString, NSImage>()
    private let fileIconCache = NSCache<NSString, NSImage>()
    /// One serial queue so writes can never land out of order.
    private let saveQueue = DispatchQueue(label: "MenuTools.ClipboardSave", qos: .utility)
    /// Clips bigger than this are not kept (a single huge copy would sit in RAM and in the JSON file).
    private static let maxClipBytes = 2_000_000

    var filteredItems: [ClipboardItem] { visibleItems }

    /// `previewItems`: render with these clips only. The saved history is not read, nothing is
    /// saved, and the pasteboard is not watched (`--render-clipboard-hud`).
    init(previewItems: [ClipboardItem]? = nil) {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("MenuTools", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.storageURL = dir.appendingPathComponent("clipboard_history.json")
        self.imagesDir = dir.appendingPathComponent("clipboard-images", isDirectory: true)

        let defaults = UserDefaults.standard
        func flag(_ key: String, default value: Bool) -> Bool {
            defaults.object(forKey: key) == nil ? value : defaults.bool(forKey: key)
        }
        captureImages = flag(Self.captureImagesKey, default: true)
        captureFiles = flag(Self.captureFilesKey, default: true)
        // Off by default: ⇧⌥⌘V is "Paste and Match Style" in many apps, and a global hotkey hides it.
        plainPasteHotkey = flag(Self.plainPasteKey, default: false)
        thumbnailCache.countLimit = 60
        fileIconCache.countLimit = 100

        if let previewItems {
            items = sortedItems(previewItems)
            startFiltering()
            return
        }
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
        let debouncedQuery =
            $searchQuery
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
        let pb = NSPasteboard.general
        let currentCount = pb.changeCount
        guard currentCount != lastChangeCount else { return }
        lastChangeCount = currentCount

        // (a) file URLs
        if captureFiles,
            let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
            !urls.isEmpty
        {
            addItem(ClipboardItem(files: urls.map(\.path)))
            return
        }

        // (b) text
        var copiedString: String? = pb.string(forType: .string)
        if copiedString == nil || copiedString?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true {
            if let str = pb.readObjects(forClasses: [NSString.self], options: nil)?.first as? String {
                copiedString = str
            }
        }
        let hasImage = captureImages && (pb.data(forType: .png) != nil || pb.data(forType: .tiff) != nil)
        if let text = copiedString, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // "Copy Image" in a browser puts the image's URL beside the bitmap: that is an image copy.
            // Spreadsheet cells also come with a bitmap, so any other text still wins.
            if hasImage, Self.isBareURL(text) {
                captureImage(from: pb)
                return
            }
            if text.utf8.count <= Self.maxClipBytes { addClip(text) }
            return
        }

        // (c) image
        if hasImage { captureImage(from: pb) }
    }

    private static func isBareURL(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count <= 2048, !trimmed.contains(where: \.isWhitespace),
            let url = URL(string: trimmed), let scheme = url.scheme?.lowercased()
        else { return false }
        return ["http", "https", "file", "data"].contains(scheme)
    }

    /// Only the raw bytes are taken on the main thread. A screenshot is a multi-megabyte TIFF, so the
    /// PNG encode, hash, thumbnail and writes run on the save queue; the item is added when they are done.
    private func captureImage(from pb: NSPasteboard) {
        let png = pb.data(forType: .png)
        let tiff = png == nil ? pb.data(forType: .tiff) : nil
        let maxBytes = Self.maxImageBytes
        // The cap is on the PNG; a TIFF several times larger cannot encode under it.
        guard (png != nil && png!.count <= maxBytes) || (tiff != nil && tiff!.count <= maxBytes * 4) else { return }
        let dir = imagesDir
        saveQueue.async {
            var pngData = png
            if pngData == nil, let tiff, let rep = NSBitmapImageRep(data: tiff) {
                pngData = rep.representation(using: .png, properties: [:])
            }
            guard let data = pngData, data.count <= maxBytes,
                let source = CGImageSourceCreateWithData(data as CFData, nil),
                let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                let width = props[kCGImagePropertyPixelWidth] as? Int,
                let height = props[kCGImagePropertyPixelHeight] as? Int
            else { return }
            let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            let fileName = UUID().uuidString + ".png"
            let thumbData = Self.thumbnailPNG(source)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                // Same image already in history: just bring it to the top.
                if let idx = self.items.firstIndex(where: { $0.kind == .image && $0.imageHash == hash }) {
                    var list = self.items
                    list[idx].timestamp = Date()
                    self.commit(list)
                    return
                }
                self.saveQueue.async {
                    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                    try? data.write(to: dir.appendingPathComponent(fileName), options: .atomic)
                    if let thumbData {
                        try? thumbData.write(to: dir.appendingPathComponent(Self.thumbName(fileName)), options: .atomic)
                    }
                }
                self.addItem(ClipboardItem(imageFile: fileName, hash: hash, width: width, height: height))
            }
        }
    }

    nonisolated private static let thumbnailPixels = 48

    /// `<uuid>.thumb.png` beside `<uuid>.png`.
    nonisolated private static func thumbName(_ imageFile: String) -> String {
        (imageFile as NSString).deletingPathExtension + ".thumb.png"
    }

    /// A 48 px PNG of the image, made once at capture so rows never decode the full picture.
    nonisolated private static func thumbnailPNG(_ source: CGImageSource) -> Data? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: thumbnailPixels,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])
    }

    func addClip(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        addItem(ClipboardItem(text: text))
    }

    /// Inserts a new item at the top, merging with an existing one that has the same content.
    private func addItem(_ item: ClipboardItem) {
        var list = items
        let key = item.contentKey

        // If the same content already exists as pinned, update timestamp only
        if let pinnedIndex = list.firstIndex(where: { $0.isPinned && $0.kind == item.kind && $0.contentKey == key }) {
            list[pinnedIndex].timestamp = Date()
            commit(list)
            return
        }

        // Remove duplicate unpinned item if exists
        list.removeAll { !$0.isPinned && $0.kind == item.kind && $0.contentKey == key }
        list.insert(item, at: 0)

        // Trim unpinned history
        let pinned = list.filter { $0.isPinned }
        var unpinned = list.filter { !$0.isPinned }
        // Only the newest few images stay.
        var imageCount = 0
        unpinned = unpinned.sorted { $0.timestamp > $1.timestamp }.filter { entry in
            guard entry.kind == .image else { return true }
            imageCount += 1
            return imageCount <= Self.maxImageItems
        }
        let allowedUnpinned = max(0, maxHistoryItems - pinned.count)
        commit(pinned + Array(unpinned.prefix(allowedUnpinned)))
    }

    func copyAndPaste(item: ClipboardItem, simulatePaste: Bool = true) {
        guard writeToPasteboard(item) else {
            deleteItem(id: item.id)
            return
        }

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

    /// Puts the item on the pasteboard. False when its files or image are gone.
    private func writeToPasteboard(_ item: ClipboardItem) -> Bool {
        let pb = NSPasteboard.general
        switch item.kind {
        case .text:
            pb.clearContents()
            pb.setString(item.text, forType: .string)
        case .files:
            let urls = (item.files ?? []).filter { FileManager.default.fileExists(atPath: $0) }
                .map { URL(fileURLWithPath: $0) as NSURL }
            guard !urls.isEmpty else { return false }
            pb.clearContents()
            pb.writeObjects(urls)
        case .image:
            guard let name = item.imageFile,
                let data = try? Data(contentsOf: imagesDir.appendingPathComponent(name)),
                let image = NSImage(data: data)
            else { return false }
            pb.clearContents()
            pb.writeObjects([image])
            pb.setData(data, forType: .png)
        }
        lastChangeCount = pb.changeCount
        return true
    }

    /// Small cached preview for an image item: the 48 px thumb file written at capture. An image
    /// without one (not expected) is decoded at thumbnail size from the full file.
    func thumbnail(for item: ClipboardItem) -> NSImage? {
        guard item.kind == .image, let name = item.imageFile else { return nil }
        let key = item.id.uuidString as NSString
        if let cached = thumbnailCache.object(forKey: key) { return cached }
        let image: NSImage?
        if let thumb = NSImage(contentsOf: imagesDir.appendingPathComponent(Self.thumbName(name))) {
            image = thumb
        } else if let source = CGImageSourceCreateWithURL(imagesDir.appendingPathComponent(name) as CFURL, nil),
            let data = Self.thumbnailPNG(source)
        {
            image = NSImage(data: data)
        } else {
            image = nil
        }
        if let image { thumbnailCache.setObject(image, forKey: key) }
        return image
    }

    /// Row icon: the thumbnail for images, the first file's Finder icon for file lists, nil for text.
    func icon(for item: ClipboardItem) -> NSImage? {
        switch item.kind {
        case .text: return nil
        case .image: return thumbnail(for: item)
        case .files:
            guard let first = item.files?.first else { return nil }
            let key = first as NSString
            if let cached = fileIconCache.object(forKey: key) { return cached }
            let icon = NSWorkspace.shared.icon(forFile: first)
            fileIconCache.setObject(icon, forKey: key)
            return icon
        }
    }

    // MARK: - Plain paste

    func updatePlainPasteHotkey() {
        if plainPasteHotkey {
            let modifiers = UInt32(cmdKey | optionKey | shiftKey)
            CarbonHotKeyHelper.shared.register(id: Self.plainPasteHotkeyID, keyCode: 9, modifiers: modifiers) {
                [weak self] in
                self?.pastePlainText()
            }
        } else {
            CarbonHotKeyHelper.shared.unregister(id: Self.plainPasteHotkeyID)
        }
    }

    /// Pastes the pasteboard's text without formatting, into whatever app is frontmost.
    /// Pastes the pasteboard's text without formatting, into whatever app is frontmost. The original
    /// pasteboard (rich text, image, file URLs) is put back afterwards, so a later ⌘V still pastes it.
    func pastePlainText() {
        let pb = NSPasteboard.general
        guard let text = pb.string(forType: .string), !text.isEmpty else { return }
        let original = Self.snapshot(pb)
        pb.clearContents()
        pb.setString(text, forType: .string)
        lastChangeCount = pb.changeCount
        // ⌘V must not go out while ⇧⌥ from the hotkey are still down, or the app sees ⇧⌥⌘V again.
        Self.afterModifiersReleased { [weak self] in
            ClipboardManager.simulatePasteCommand()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                guard let self, pb.changeCount == self.lastChangeCount else { return }
                Self.restore(original, to: pb)
                self.lastChangeCount = pb.changeCount
            }
        }
    }

    /// Every item's data by type, so the pasteboard can be put back exactly.
    private static func snapshot(_ pb: NSPasteboard) -> [[NSPasteboard.PasteboardType: Data]] {
        (pb.pasteboardItems ?? []).map { item in
            var types: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) { types[type] = data }
            }
            return types
        }
    }

    private static func restore(_ items: [[NSPasteboard.PasteboardType: Data]], to pb: NSPasteboard) {
        pb.clearContents()
        let restored = items.map { types in
            let item = NSPasteboardItem()
            for (type, data) in types { item.setData(data, forType: type) }
            return item
        }
        pb.writeObjects(restored)
    }

    /// Runs `action` once no modifier key is held (polled every 20 ms, at most 1 s).
    private static func afterModifiersReleased(_ action: @escaping @MainActor () -> Void, tries: Int = 50) {
        let held = CGEventSource.flagsState(.combinedSessionState)
            .intersection([.maskShift, .maskAlternate, .maskCommand, .maskControl])
        if held.isEmpty || tries == 0 {
            action()
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) {
            afterModifiersReleased(action, tries: tries - 1)
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
        let kept = Set(list.compactMap(\.imageFile))
        let dropped = items.filter { item in item.imageFile.map { !kept.contains($0) } ?? false }
        if !dropped.isEmpty {
            for item in dropped { thumbnailCache.removeObject(forKey: item.id.uuidString as NSString) }
            removeImageFiles(dropped.compactMap(\.imageFile))
        }
        items = sortedItems(list)
        scheduleSave()
    }

    private func removeImageFiles(_ names: [String]) {
        let dir = imagesDir
        saveQueue.async {
            for name in names {
                try? FileManager.default.removeItem(at: dir.appendingPathComponent(name))
                try? FileManager.default.removeItem(at: dir.appendingPathComponent(Self.thumbName(name)))
            }
        }
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
            let dir = imagesDir
            let valid = saved.filter { item in
                guard item.kind == .image else { return true }
                guard let name = item.imageFile else { return false }
                return FileManager.default.fileExists(atPath: dir.appendingPathComponent(name).path)
            }
            self.items = sortedItems(valid)
        }
        sweepOrphanImages()
    }

    /// Deletes PNGs in the images folder that no item references (a PNG is written before the
    /// coalesced JSON save, so a crash in between leaves one behind).
    private func sweepOrphanImages() {
        let dir = imagesDir
        var referenced = Set<String>()
        for name in items.compactMap(\.imageFile) {
            referenced.insert(name)
            referenced.insert(Self.thumbName(name))
        }
        saveQueue.async {
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return }
            for name in names where !referenced.contains(name) {
                try? FileManager.default.removeItem(at: dir.appendingPathComponent(name))
            }
        }
    }
}
