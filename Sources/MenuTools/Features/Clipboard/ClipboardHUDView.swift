import AppKit
import SwiftUI

struct ClipboardHUDView: View {
    @ObservedObject var clipboardManager: ClipboardManager
    @State private var showClearConfirm: Bool = false
    @FocusState private var isSearchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            // Header with search bar
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)

                TextField("Search clipboard history...", text: $clipboardManager.searchQuery)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5))
                    .focused($isSearchFocused)
                    .onChange(of: clipboardManager.searchQuery) {
                        clipboardManager.selectedIndex = 0
                    }

                if !clipboardManager.searchQuery.isEmpty {
                    Button(action: { clipboardManager.searchQuery = "" }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }

                Spacer()

                // Clear button
                if showClearConfirm {
                    Button("Confirm Clear?") {
                        clipboardManager.clearHistory()
                        showClearConfirm = false
                    }
                    .font(.system(size: 10.5, weight: .bold))
                    .foregroundStyle(.red)
                    .buttonStyle(.plain)
                } else {
                    Button("Clear") {
                        showClearConfirm = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                            showClearConfirm = false
                        }
                    }
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .buttonStyle(.plain)
                    .help("Clear unpinned clips (⌥C)")
                }

                Text("ESC")
                    .font(.system(size: 8.5, weight: .bold, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 4))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(Color.white.opacity(0.04))

            Divider().opacity(0.35)

            // List of clips
            let items = clipboardManager.filteredItems
            if items.isEmpty {
                VStack(spacing: 8) {
                    Spacer()
                    Image(systemName: "doc.on.clipboard")
                        .font(.system(size: 30))
                        .foregroundStyle(.secondary.opacity(0.45))
                    Text(
                        clipboardManager.searchQuery.isEmpty ? "Clipboard history is empty" : "No matching clips found"
                    )
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(spacing: 3) {
                            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                                ClipboardItemRow(
                                    item: item,
                                    index: index,
                                    isSelected: index == clipboardManager.selectedIndex,
                                    onSelect: {
                                        clipboardManager.copyAndPaste(item: item)
                                    },
                                    onPinToggle: {
                                        clipboardManager.togglePin(id: item.id)
                                    },
                                    onDelete: {
                                        clipboardManager.deleteItem(id: item.id)
                                    }
                                )
                                .id(item.id)
                            }
                        }
                        .padding(.vertical, 6)
                        .padding(.horizontal, 8)
                    }
                    .onChange(of: clipboardManager.selectedIndex) { _, newIndex in
                        if newIndex >= 0 && newIndex < items.count {
                            withAnimation(.easeInOut(duration: 0.1)) {
                                proxy.scrollTo(items[newIndex].id, anchor: .center)
                            }
                        }
                    }
                }
            }

            Divider().opacity(0.35)

            // Footer shortcuts tip
            HStack(spacing: 12) {
                HStack(spacing: 8) {
                    FooterKeyTip(key: "↵", label: "Paste")
                    FooterKeyTip(key: "⌘1–9", label: "Quick")
                    FooterKeyTip(key: "⌥P", label: "Pin")
                    FooterKeyTip(key: "⌥⌫", label: "Delete")
                    FooterKeyTip(key: "⌥C", label: "Clear")
                }
                Spacer()
                Text("\(items.count) item\(items.count == 1 ? "" : "s")")
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(Color.white.opacity(0.025))
        }
        .frame(width: 480, height: 380)
        .background(
            Color(nsColor: .windowBackgroundColor).opacity(0.85)
        )
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.white.opacity(0.10), lineWidth: 1)
        )
        .onAppear {
            isSearchFocused = true
            clipboardManager.clampSelectedIndex()
        }
        .onKeyPress(.upArrow) {
            let items = clipboardManager.filteredItems
            if !items.isEmpty {
                clipboardManager.selectedIndex = (clipboardManager.selectedIndex - 1 + items.count) % items.count
            }
            return .handled
        }
        .onKeyPress(.downArrow) {
            let items = clipboardManager.filteredItems
            if !items.isEmpty {
                clipboardManager.selectedIndex = (clipboardManager.selectedIndex + 1) % items.count
            }
            return .handled
        }
        .onKeyPress(.return) {
            let items = clipboardManager.filteredItems
            if clipboardManager.selectedIndex >= 0 && clipboardManager.selectedIndex < items.count {
                clipboardManager.copyAndPaste(item: items[clipboardManager.selectedIndex])
            }
            return .handled
        }
        .onKeyPress(.escape) {
            if !clipboardManager.searchQuery.isEmpty {
                clipboardManager.searchQuery = ""
            } else {
                ClipboardHUDWindowController.shared.hide()
            }
            return .handled
        }
        .onKeyPress { press in
            let items = clipboardManager.filteredItems

            // ⌘1..9 or ⌥1..9 quick paste
            if press.modifiers == .command || press.modifiers == .option,
                let char = press.characters.first,
                let digit = Int(String(char)),
                digit >= 1 && digit <= 9
            {
                let targetIndex = digit - 1
                if targetIndex < items.count {
                    clipboardManager.copyAndPaste(item: items[targetIndex])
                    return .handled
                }
            }

            // ⌥P / ⌘P - Toggle Pin
            if (press.modifiers == .option || press.modifiers == .command) && press.characters.lowercased() == "p" {
                if clipboardManager.selectedIndex >= 0 && clipboardManager.selectedIndex < items.count {
                    clipboardManager.togglePin(id: items[clipboardManager.selectedIndex].id)
                    return .handled
                }
            }

            // ⌥C - Clear History
            if press.modifiers == .option && (press.characters.lowercased() == "c" || press.characters == "ç") {
                clipboardManager.clearHistory()
                return .handled
            }

            // ⌥⌫ / ⌘⌫ - Delete clip
            if (press.modifiers == .option || press.modifiers == .command) && press.key == .delete {
                if clipboardManager.selectedIndex >= 0 && clipboardManager.selectedIndex < items.count {
                    clipboardManager.deleteItem(id: items[clipboardManager.selectedIndex].id)
                    return .handled
                }
            }

            return .ignored
        }
    }
}

private struct FooterKeyTip: View {
    let key: String
    let label: String

    var body: some View {
        HStack(spacing: 3) {
            Text(key)
                .font(.system(size: 8.5, weight: .bold, design: .monospaced))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 3.5)
                .padding(.vertical, 1.5)
                .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 3))
            Text(label)
                .font(.system(size: 9))
                .foregroundStyle(.secondary.opacity(0.8))
        }
    }
}
