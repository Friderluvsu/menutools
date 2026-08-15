import AppKit
import SwiftUI

enum MacToolsTheme {
    static let popoverWidth: CGFloat = 368
    static let popoverHeight: CGFloat = 540
    static let cornerRadius: CGFloat = 10
    static let outerPadding: CGFloat = 10
    static let sectionSpacing: CGFloat = 8
    static let controlHeight: CGFloat = 32

    static var panelBackground: Color {
        Color(nsColor: .windowBackgroundColor).opacity(0.85)
    }

    static var cardBackground: Color {
        Color(nsColor: .controlBackgroundColor).opacity(0.42)
    }

    static var controlBackground: Color {
        Color.white.opacity(0.05)
    }

    static var hoverBackground: Color {
        Color.white.opacity(0.09)
    }

    static var borderColor: Color {
        Color.white.opacity(0.06)
    }

    static var borderHoverColor: Color {
        Color.white.opacity(0.14)
    }
}

struct MacToolsCard<Content: View>: View {
    let content: Content
    var padding: CGFloat = 10
    var cornerRadius: CGFloat = MacToolsTheme.cornerRadius

    init(padding: CGFloat = 10, cornerRadius: CGFloat = MacToolsTheme.cornerRadius, @ViewBuilder content: () -> Content)
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
