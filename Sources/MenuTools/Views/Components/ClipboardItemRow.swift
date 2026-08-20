import SwiftUI

struct ClipboardItemRow: View {
    let item: ClipboardItem
    let index: Int
    let isSelected: Bool
    let onSelect: () -> Void
    let onPinToggle: () -> Void
    let onDelete: () -> Void

    @State private var isHovered: Bool = false

    var body: some View {
        HStack(spacing: 8) {
            // Quick index badge 1-9
            if index < 9 {
                Text("\(index + 1)")
                    .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                    .foregroundStyle(isSelected ? Color.white : Color.secondary)
                    .frame(width: 16, height: 16)
                    .background(
                        isSelected
                            ? Color.accentColor.opacity(0.6)
                            : Color.white.opacity(0.06),
                        in: RoundedRectangle(cornerRadius: 4)
                    )
            } else {
                Spacer().frame(width: 16)
            }

            // Pinned indicator
            if item.isPinned {
                Image(systemName: "pin.fill")
                    .font(.system(size: 8.5))
                    .foregroundStyle(.yellow)
            }

            // Text snippet
            Text(item.snippet)
                .font(.system(size: 11.5))
                .foregroundStyle(isSelected ? Color.white : Color.primary)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 8)

            // Meta info or Action buttons
            if isHovered || isSelected {
                HStack(spacing: 6) {
                    Button(action: onPinToggle) {
                        Image(systemName: item.isPinned ? "pin.slash.fill" : "pin")
                            .font(.system(size: 10))
                            .foregroundStyle(item.isPinned ? Color.yellow : Color.secondary)
                            .frame(width: 20, height: 20)
                            .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 4))
                    }
                    .buttonStyle(.plain)
                    .help(item.isPinned ? "Unpin (⌥P)" : "Pin to top (⌥P)")

                    Button(action: onDelete) {
                        Image(systemName: "trash")
                            .font(.system(size: 10))
                            .foregroundStyle(.red.opacity(0.85))
                            .frame(width: 20, height: 20)
                            .background(Color.red.opacity(0.12), in: RoundedRectangle(cornerRadius: 4))
                    }
                    .buttonStyle(.plain)
                    .help("Delete clip (⌥⌫)")
                }
            } else {
                HStack(spacing: 6) {
                    Text("\(item.charCount) ch")
                        .font(.system(size: 8.5, design: .monospaced))
                        .foregroundStyle(.tertiary)

                    Text(item.timeAgoFormatted)
                        .font(.system(size: 8.5))
                        .foregroundStyle(.secondary.opacity(0.7))
                }
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(
                    isSelected
                        ? Color.accentColor.opacity(0.28)
                        : (isHovered ? Color.white.opacity(0.06) : Color.clear)
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7)
                .strokeBorder(
                    isSelected ? Color.accentColor.opacity(0.5) : Color.clear,
                    lineWidth: 1
                )
        )
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .onTapGesture {
            onSelect()
        }
    }
}
