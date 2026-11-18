import AppKit
import SwiftUI

/// One clip in the HUD list. The row is a fixed height and its trailing slot is a fixed size, so
/// hovering swaps the meta text for the buttons without moving anything.
struct ClipboardItemRow: View {
    @Environment(\.appTheme) private var theme

    let item: ClipboardItem
    let index: Int
    let isSelected: Bool
    let onSelect: () -> Void
    let onPinToggle: () -> Void
    let onDelete: () -> Void
    var icon: NSImage?

    @State private var isHovered: Bool = false

    private static let height: CGFloat = 30
    private static let trailingWidth: CGFloat = 112

    var body: some View {
        HStack(spacing: 8) {
            Text(index < 9 ? "\(index + 1)" : "")
                .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                .foregroundStyle(isSelected ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                .frame(width: 16, height: 16)
                .background(
                    isSelected ? theme.accent.opacity(0.45) : theme.controlFill,
                    in: RoundedRectangle(cornerRadius: theme.radius(4), style: .continuous)
                )
                .opacity(index < 9 ? 1 : 0)

            if let icon {
                Image(nsImage: icon)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 18, height: 18)
                    .clipShape(RoundedRectangle(cornerRadius: theme.radius(3.5), style: .continuous))
            }

            if item.isPinned {
                Image(systemName: "pin.fill")
                    .font(.system(size: 8.5))
                    .foregroundStyle(.yellow)
            }

            Text(item.snippet)
                .font(.system(size: 11.5))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 8)

            ZStack(alignment: .trailing) {
                HStack(spacing: 6) {
                    Text(item.metaText)
                        .font(.system(size: 8.5, design: .monospaced))
                        .foregroundStyle(.tertiary)
                    Text(item.timeAgoFormatted)
                        .font(.system(size: 8.5))
                        .foregroundStyle(.secondary)
                }
                .lineLimit(1)
                .opacity(showsActions ? 0 : 1)

                HStack(spacing: 5) {
                    actionButton(
                        item.isPinned ? "pin.slash.fill" : "pin",
                        tint: item.isPinned ? .yellow : nil,
                        help: item.isPinned ? "Unpin (⌥P)" : "Pin to top (⌥P)",
                        action: onPinToggle)
                    actionButton("trash", tint: .red, help: "Delete clip (⌥⌫)", action: onDelete)
                }
                .opacity(showsActions ? 1 : 0)
                .allowsHitTesting(showsActions)
            }
            .frame(width: Self.trailingWidth, alignment: .trailing)
        }
        .padding(.horizontal, 9)
        .frame(height: Self.height)
        .background(rowFill, in: RoundedRectangle(cornerRadius: theme.radius(7), style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: theme.radius(7), style: .continuous)
                .strokeBorder(isSelected ? theme.accent.opacity(0.45) : Color.clear, lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .onTapGesture(perform: onSelect)
    }

    private var showsActions: Bool { isHovered || isSelected }

    private var rowFill: Color {
        if isSelected { return theme.accent.opacity(0.22) }
        return isHovered ? theme.hoverFill : theme.tileFill
    }

    private func actionButton(
        _ symbol: String, tint: Color?, help: String, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(tint.map { AnyShapeStyle($0.opacity(0.9)) } ?? AnyShapeStyle(.secondary))
                .frame(width: 20, height: 20)
                .background(
                    tint == .red ? Color.red.opacity(0.12) : theme.controlFill,
                    in: RoundedRectangle(cornerRadius: theme.radius(4), style: .continuous)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .suppressesFocusRing()
        .help(help)
    }
}
