import SwiftUI

/// A small macOS-style switch drawn in SwiftUI (26×15, like `NSSwitch` at `.small`). The native
/// `.switch` style bridges an `NSSwitch` per toggle, and Settings has a dozen of them, which made
/// the page slow to build; this one is a capsule and a circle in the theme accent.
struct SmallSwitchToggleStyle: ToggleStyle {
    @Environment(\.appTheme) private var theme
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            Capsule(style: .continuous)
                .fill(configuration.isOn ? theme.accent : Color.primary.opacity(0.18))
                .overlay(
                    Capsule(style: .continuous)
                        .strokeBorder(Color.primary.opacity(configuration.isOn ? 0 : 0.08), lineWidth: 0.5)
                )
                .overlay(alignment: configuration.isOn ? .trailing : .leading) {
                    Circle()
                        .fill(Color.white)
                        .shadow(color: .black.opacity(0.25), radius: 0.8, y: 0.5)
                        .padding(1.5)
                }
                .frame(width: 26, height: 15)
                .contentShape(Capsule())
                .animation(.easeOut(duration: 0.15), value: configuration.isOn)
        }
        .buttonStyle(.plain)
        .suppressesFocusRing()
        .opacity(isEnabled ? 1 : 0.45)
        .accessibilityValue(configuration.isOn ? "On" : "Off")
    }
}

extension ToggleStyle where Self == SmallSwitchToggleStyle {
    static var smallSwitch: SmallSwitchToggleStyle { SmallSwitchToggleStyle() }
}
