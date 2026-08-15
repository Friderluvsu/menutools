import SwiftUI

struct FeatureCardRow<DetailContent: View>: View {
    let title: String
    let subtitle: String
    let icon: String
    var iconTint: Color = .blue
    var isSwitchOn: Bool? = nil
    var isSwitchTransitioning: Bool = false
    var isExpandable: Bool = false
    var onToggleSwitch: (() -> Void)? = nil
    var actionButtonTitle: String? = nil
    var onActionButton: (() -> Void)? = nil
    @ViewBuilder var detailContent: () -> DetailContent

    @State private var isExpanded: Bool = false
    @State private var isHovered: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            // Main Row Header
            HStack(spacing: 10) {
                // Icon with colored background
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(iconTint)
                    .frame(width: 26, height: 26)
                    .background(iconTint.opacity(0.16))
                    .clipShape(RoundedRectangle(cornerRadius: 7))

                // Title and Subtitle
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.primary)

                    Text(subtitle)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                // Trailing control
                if let on = isSwitchOn {
                    if isSwitchTransitioning {
                        ProgressView()
                            .controlSize(.small)
                            .frame(width: 32)
                    } else {
                        Toggle(
                            "",
                            isOn: Binding(
                                get: { on },
                                set: { _ in onToggleSwitch?() }
                            )
                        )
                        .toggleStyle(.switch)
                        .labelsHidden()
                        .controlSize(.mini)
                    }
                } else if let btnTitle = actionButtonTitle {
                    Button(btnTitle) {
                        onActionButton?()
                    }
                    .font(.system(size: 10, weight: .semibold))
                    .controlSize(.small)
                }

                if isExpandable {
                    Button(action: {
                        withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                            isExpanded.toggle()
                        }
                    }) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(.secondary)
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                            .frame(width: 16, height: 16)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
            .onTapGesture {
                if isExpandable {
                    withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                        isExpanded.toggle()
                    }
                } else if isSwitchOn != nil && !isSwitchTransitioning {
                    onToggleSwitch?()
                } else if onActionButton != nil {
                    onActionButton?()
                }
            }

            // Expandable Detail Content
            if isExpandable && isExpanded {
                VStack(spacing: 0) {
                    Divider()
                        .background(Color.white.opacity(0.06))
                        .padding(.horizontal, 10)

                    detailContent()
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(isHovered ? MacToolsTheme.hoverBackground : MacToolsTheme.cardBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(isHovered ? MacToolsTheme.borderHoverColor : MacToolsTheme.borderColor, lineWidth: 1)
        )
        .onHover { isHovered = $0 }
    }
}

extension FeatureCardRow where DetailContent == EmptyView {
    init(
        title: String,
        subtitle: String,
        icon: String,
        iconTint: Color = .blue,
        isSwitchOn: Bool? = nil,
        isSwitchTransitioning: Bool = false,
        onToggleSwitch: (() -> Void)? = nil,
        actionButtonTitle: String? = nil,
        onActionButton: (() -> Void)? = nil
    ) {
        self.title = title
        self.subtitle = subtitle
        self.icon = icon
        self.iconTint = iconTint
        self.isSwitchOn = isSwitchOn
        self.isSwitchTransitioning = isSwitchTransitioning
        self.isExpandable = false
        self.onToggleSwitch = onToggleSwitch
        self.actionButtonTitle = actionButtonTitle
        self.onActionButton = onActionButton
        self.detailContent = { EmptyView() }
    }
}
