import AppKit
import SwiftUI

struct ClipboardHUDView: View {
    @ObservedObject var clipboardManager: ClipboardManager
    @State private var selectedIndex: Int = 0
    @State private var showClearConfirm: Bool = false
    @FocusState private var isSearchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            // Header with search bar
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.secondary)

                TextField("Search clipboard history...", text: $clipboardManager.searchQuery)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .focused($isSearchFocused)
                    .onChange(of: clipboardManager.searchQuery) {
                        selectedIndex = 0
                    }

                if !clipboardManager.searchQuery.isEmpty {
                    Button(action: { clipboardManager.searchQuery = "" }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
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
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(.red)
                    .buttonStyle(.plain)
                } else {
                    Button("Clear History") {
                        showClearConfirm = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                            showClearConfirm = false
                        }
                    }
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .buttonStyle(.plain)
                }

                Text("ESC")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .background(Color.white.opacity(0.1))
                    .cornerRadius(4)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Color.white.opacity(0.04))

            Divider()
                .background(Color.white.opacity(0.1))

            // List of clips
            let items = clipboardManager.filteredItems
            if items.isEmpty {
                VStack(spacing: 8) {
                    Spacer()
                    Image(systemName: "doc.on.clipboard")
                        .font(.system(size: 28))
                        .foregroundColor(.secondary.opacity(0.6))
                    Text(clipboardManager.searchQuery.isEmpty ? "Clipboard history is empty" : "No matching clips")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                                ClipboardItemRow(
                                    item: item,
                                    index: index,
                                    isSelected: index == selectedIndex,
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
                                .id(index)
                            }
                        }
                        .padding(.vertical, 6)
                        .padding(.horizontal, 8)
                    }
                    .onChange(of: selectedIndex) { _, newIndex in
                        withAnimation(.easeInOut(duration: 0.1)) {
                            proxy.scrollTo(newIndex, anchor: .center)
                        }
                    }
                }
            }

            // Footer shortcuts tip
            HStack {
                Text("↵ to paste • 1-9 quick paste • ⌥C clear • Esc to dismiss")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary.opacity(0.7))
                Spacer()
                Text("\(items.count) items")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary.opacity(0.7))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(Color.white.opacity(0.02))
        }
        .frame(width: 440, height: 340)
        .background(.ultraThinMaterial)
        .onAppear {
            isSearchFocused = true
            selectedIndex = 0
        }
        .onKeyPress(.upArrow) {
            let items = clipboardManager.filteredItems
            if !items.isEmpty {
                selectedIndex = (selectedIndex - 1 + items.count) % items.count
            }
            return .handled
        }
        .onKeyPress(.downArrow) {
            let items = clipboardManager.filteredItems
            if !items.isEmpty {
                selectedIndex = (selectedIndex + 1) % items.count
            }
            return .handled
        }
        .onKeyPress(.return) {
            let items = clipboardManager.filteredItems
            if selectedIndex >= 0 && selectedIndex < items.count {
                clipboardManager.copyAndPaste(item: items[selectedIndex])
            }
            return .handled
        }
        .onKeyPress(.escape) {
            ClipboardHUDWindowController.shared.hide()
            return .handled
        }
    }
}
