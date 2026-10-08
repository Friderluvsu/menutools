import SwiftUI

/// Compact dashboard card for the Shelf: ~32pt empty, ~60pt with items. No scrolling.
struct ShelfCard: View {
    @ObservedObject var manager: ShelfManager
    @State private var isTargeted = false

    private let maxChips = 4

    init(manager: ShelfManager) {
        self.manager = manager
    }

    var body: some View {
        MacToolsCard(padding: 7) {
            VStack(alignment: .leading, spacing: 5) {
                header
                if !manager.items.isEmpty {
                    chips
                }
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: MacToolsTheme.cornerRadius, style: .continuous)
                .strokeBorder(Color.accentColor.opacity(isTargeted ? 0.8 : 0), lineWidth: 1.5)
                .allowsHitTesting(false)
        )
        .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
            AppDelegate.sharedInstance?.focusPanelAfterDrop()
            return manager.handleDrop(providers)
        }
        .onAppear { manager.removeMissing() }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Label("Shelf", systemImage: "tray.full")
                .font(.system(size: 11, weight: .semibold))
            if manager.items.isEmpty {
                Text(isTargeted ? "Release to add" : "Drop files to hold them")
                    .font(.system(size: 10))
                    .foregroundStyle(isTargeted ? Color.accentColor : .secondary)
                    .lineLimit(1)
            } else {
                Text("\(manager.items.count)")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            if manager.items.count > 1 {
                ShelfDragAllHandle(manager: manager)
            }
            iconButton(manager.isPanelVisible ? "macwindow.badge.plus" : "macwindow", help: "Float") {
                manager.togglePanel()
            }
            if !manager.items.isEmpty {
                iconButton("trash", help: "Clear") { manager.clear() }
            }
        }
        .frame(height: 18)
    }

    private var chips: some View {
        let overflow = manager.items.count > maxChips
        let shown = overflow ? Array(manager.items.prefix(maxChips - 1)) : manager.items
        return HStack(spacing: 4) {
            ForEach(shown) { item in
                ShelfChip(item: item, manager: manager)
            }
            if overflow {
                Button {
                    manager.showPanel()
                } label: {
                    Text("+\(manager.items.count - shown.count)")
                        .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(width: 40, height: 26)
                        .background(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(MacToolsTheme.controlBackground)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Show all")
            }
        }
    }

    private func iconButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(help)
    }
}

private struct ShelfChip: View {
    let item: ShelfItem
    @ObservedObject var manager: ShelfManager
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 4) {
            Image(nsImage: manager.icon(for: item))
                .resizable()
                .interpolation(.high)
                .frame(width: 16, height: 16)
            Text(item.name)
                .font(.system(size: 10))
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, 6)
        .frame(maxWidth: .infinity, minHeight: 26, maxHeight: 26, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(isHovered ? MacToolsTheme.hoverBackground : MacToolsTheme.controlBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(isHovered ? MacToolsTheme.borderHoverColor : MacToolsTheme.borderColor, lineWidth: 1)
        )
        .overlay(
            ShelfDragSource(
                urls: { [item.url] },
                menu: { ShelfMenu.menu(for: item, manager: manager) },
                onDoubleClick: { manager.open(item) },
                onHover: { isHovered = $0 }
            )
        )
        .help(item.name)
    }
}
