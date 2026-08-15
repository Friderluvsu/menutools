import AppKit
import SwiftUI

enum MacToolsTheme {
    static let popoverWidth: CGFloat = 392
    static let popoverHeight: CGFloat = 580
    static let cornerRadius: CGFloat = 12
    static let outerPadding: CGFloat = 12
    static let sectionSpacing: CGFloat = 10
    static let controlHeight: CGFloat = 36

    static var panelBackground: Color {
        Color(nsColor: .windowBackgroundColor).opacity(0.85)
    }

    static var cardBackground: Color {
        Color(nsColor: .controlBackgroundColor).opacity(0.55)
    }

    static var controlBackground: Color {
        Color.white.opacity(0.06)
    }

    static var hoverBackground: Color {
        Color.white.opacity(0.09)
    }

    static var borderColor: Color {
        Color.white.opacity(0.08)
    }

    static var borderHoverColor: Color {
        Color.white.opacity(0.14)
    }
}

struct MacToolsCard<Content: View>: View {
    let content: Content
    var padding: CGFloat = 12
    var cornerRadius: CGFloat = MacToolsTheme.cornerRadius

    init(padding: CGFloat = 12, cornerRadius: CGFloat = MacToolsTheme.cornerRadius, @ViewBuilder content: () -> Content)
    {
        self.padding = padding
        self.cornerRadius = cornerRadius
        self.content = content()
    }

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(MacToolsTheme.cardBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .strokeBorder(MacToolsTheme.borderColor, lineWidth: 1)
            )
    }
}
