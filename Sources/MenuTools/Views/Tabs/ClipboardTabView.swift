import SwiftUI

struct ClipboardTabView: View {
    @ObservedObject var clipboard: ClipboardManager
    @State private var showCopiedAlert: Bool = false

    var body: some View {
        VStack(spacing: 8) {
            // Search Bar & Actions
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)

                TextField("Filter clipboard...", text: $clipboard.searchQuery)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))

                if !clipboard.searchQuery.isEmpty {
                    Button(action: { clipboard.searchQuery = "" }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }

                Spacer()

                Button(action: { ClipboardHUDWindowController.shared.show() }) {
                    HStack(spacing: 4) {
                        Image(systemName: "macwindow")
                            .font(.system(size: 10))
                        Text("HUD")
                            .font(.system(size: 10, weight: .bold))
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 4))
                }
                .buttonStyle(.plain)
                .help("Open floating HUD panel (⌥⌘V)")

                Button("Clear") {
                    clipboard.clearHistory()
                }
                .font(.system(size: 10))
                .foregroundStyle(.red)
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)

            Divider().opacity(0.35)

            // List of clips
            let items = clipboard.filteredItems
            if items.isEmpty {
                VStack(spacing: 6) {
                    Spacer()
                    Image(systemName: "doc.on.clipboard")
                        .font(.system(size: 24))
                        .foregroundStyle(.secondary.opacity(0.5))
                    Text(clipboard.searchQuery.isEmpty ? "No clipboard history" : "No results found")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 3) {
                        ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                            ClipboardItemRow(
                                item: item,
                                index: index,
                                isSelected: false,
                                onSelect: {
                                    clipboard.copyAndPaste(item: item, simulatePaste: false)
                                    showCopiedAlert = true
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                                        showCopiedAlert = false
                                    }
                                },
                                onPinToggle: {
                                    clipboard.togglePin(id: item.id)
                                },
                                onDelete: {
                                    clipboard.deleteItem(id: item.id)
                                }
                            )
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 6)
                }
            }

            Divider().opacity(0.35)

            // Footer
            HStack {
                Text(showCopiedAlert ? "✓ Copied to clipboard" : "\(clipboard.items.count) items stored")
                    .font(.system(size: 10, weight: showCopiedAlert ? .bold : .regular))
                    .foregroundStyle(showCopiedAlert ? Color.green : Color.secondary)
                Spacer()
                Text("HUD: ⌥⌘V")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color.white.opacity(0.02))
        }
    }
}
