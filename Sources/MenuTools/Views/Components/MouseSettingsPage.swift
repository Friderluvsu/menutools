import AppKit
import SwiftUI

/// Settings → Mouse. Four short sub-pages so the Settings well stays compact.
struct MouseSettingsPage: View {
    @ObservedObject var mouse: MouseManager
    @AppStorage("MouseSettingsTab") private var tab: Tab = .scroll

    enum Tab: String, CaseIterable, Identifiable {
        case scroll = "Scroll"
        case buttons = "Buttons"
        case cursor = "Cursor"
        case apps = "Apps"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(spacing: MacToolsTheme.sectionSpacing) {
            Picker("", selection: $tab) {
                ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)

            switch tab {
            case .scroll: MouseScrollCard(mouse: mouse)
            case .buttons: MouseButtonsCard(mouse: mouse)
            case .cursor: MouseCursorCard(mouse: mouse)
            case .apps: MouseAppsCard(mouse: mouse)
            }
        }
    }
}

// MARK: - Scroll

private struct MouseScrollCard: View {
    @ObservedObject var mouse: MouseManager

    var body: some View {
        SettingsCard(title: "Mouse wheel", icon: "magicmouse", color: .teal) {
            SettingsRow(title: "Enabled") {
                MouseSwitch(isOn: $mouse.prefs.scrollEnabled)
            }
            MouseAccessRow(mouse: mouse, needed: mouse.prefs.scrollEnabled)
            Group {
                SettingsRow(title: "Smooth scroll") { MouseSwitch(isOn: $mouse.prefs.smoothScroll) }
                MouseSlider(title: "Speed", value: $mouse.prefs.scrollSpeed, range: 0.3...4, format: "%.1f×")
                MouseSlider(
                    title: "Acceleration", value: $mouse.prefs.scrollAcceleration, range: 0...1, format: "%.0f%%",
                    scale: 100)
                if mouse.prefs.smoothScroll {
                    MouseSlider(
                        title: "Glide", value: $mouse.prefs.scrollDuration, range: 0.1...0.7, format: "%.0f ms",
                        scale: 1000)
                }
                SettingsRow(title: "Reverse direction") { MouseSwitch(isOn: $mouse.prefs.reverseVertical) }
                    .help("Wheel only. Trackpad natural scrolling is unchanged.")
                Divider().opacity(0.35)
                MouseSlider(
                    title: "Sideways speed", value: $mouse.prefs.horizontalSpeed, range: 0.3...4, format: "%.1f×")
                SettingsRow(title: "Reverse sideways", isSecondary: true) {
                    MouseSwitch(isOn: $mouse.prefs.reverseHorizontal)
                }
                Divider().opacity(0.35)
                SettingsRow(title: "⇧ + wheel scrolls sideways") {
                    MouseSwitch(isOn: $mouse.prefs.shiftHorizontal)
                }
                SettingsRow(title: "⌘ + wheel scrolls fast") { MouseSwitch(isOn: $mouse.prefs.commandFast) }
                if mouse.prefs.commandFast {
                    MouseSlider(
                        title: "Fast gain", value: $mouse.prefs.fastGain, range: 1.5...8, format: "%.1f×"
                    )
                    .padding(.leading, 12)
                }
                SettingsRow(title: "⌃ + wheel zooms") { MouseSwitch(isOn: $mouse.prefs.controlZoom) }
                    .help("Sends ⌘+ / ⌘−. Off while macOS screen zoom uses ⌃ + scroll.")
            }
            .disabled(!mouse.prefs.scrollEnabled)
            .opacity(mouse.prefs.scrollEnabled ? 1 : 0.5)
        }
    }
}

// MARK: - Buttons

private struct MouseButtonsCard: View {
    @ObservedObject var mouse: MouseManager

    var body: some View {
        SettingsCard(title: "Buttons", icon: "circle.grid.cross", color: .orange) {
            SettingsRow(title: "Enabled") { MouseSwitch(isOn: $mouse.prefs.buttonsEnabled) }
            MouseAccessRow(mouse: mouse, needed: mouse.prefs.buttonsEnabled || mouse.isCapturing)
            VStack(spacing: 4) {
                ForEach(mouse.prefs.bindings) { binding in
                    MouseBindingRow(mouse: mouse, binding: binding)
                }
            }
            .disabled(!mouse.prefs.buttonsEnabled)
            .opacity(mouse.prefs.buttonsEnabled ? 1 : 0.5)
            HStack {
                if mouse.isCapturing {
                    Text("Press a mouse button…")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.orange)
                    Spacer()
                    Button("Cancel") { mouse.cancelCapture() }
                } else {
                    Text("Left and right clicks are never changed")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                    Spacer()
                    Button {
                        mouse.startCapture()
                    } label: {
                        Label("Add button", systemImage: "plus")
                    }
                    .disabled(!mouse.isAccessibilityGranted)
                }
            }
            .controlSize(.small)
            .padding(.top, 2)
        }
    }
}

private struct MouseBindingRow: View {
    @ObservedObject var mouse: MouseManager
    let binding: MouseButtonBinding
    @Environment(\.appTheme) private var theme

    var body: some View {
        HStack(spacing: 6) {
            Text(binding.buttonTitle)
                .font(.system(size: 11.5, weight: .medium))
                .lineLimit(1)
            Spacer(minLength: 4)
            if binding.action == .shortcut {
                ShortcutRecorder(combo: binding.shortcut) { mouse.setShortcut($0, for: binding.button) }
            }
            Picker(
                "",
                selection: Binding(
                    get: { binding.action },
                    set: { mouse.setAction($0, for: binding.button) })
            ) {
                ForEach(MouseAction.allCases) { action in
                    if action == .shortcut { Divider() }
                    Text(action.title).tag(action)
                    if action == .none { Divider() }
                }
            }
            .labelsHidden()
            .controlSize(.small)
            .frame(width: 128)
            if binding.button >= 5 {
                Button {
                    mouse.removeBinding(binding.button)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Remove")
            }
        }
        .padding(.horizontal, 7)
        .frame(minHeight: 26)
        .background(theme.tileFill, in: RoundedRectangle(cornerRadius: theme.radius(6), style: .continuous))
    }
}

/// Click, then press a key combination. Esc cancels.
private struct ShortcutRecorder: View {
    let combo: KeyCombo?
    let onRecord: (KeyCombo) -> Void
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        Button {
            recording ? stop() : start()
        } label: {
            Text(recording ? "Type keys…" : (combo?.display ?? "Record"))
                .font(.system(size: 10.5, weight: .medium, design: .rounded))
                .frame(minWidth: 52)
        }
        .controlSize(.small)
        .tint(recording ? .orange : nil)
        .onDisappear { stop() }
    }

    private func start() {
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53, event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty {
                stop()
                return nil
            }
            onRecord(Self.combo(from: event))
            stop()
            return nil
        }
    }

    private func stop() {
        recording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    static func combo(from event: NSEvent) -> KeyCombo {
        let mods = event.modifierFlags
        var flags: CGEventFlags = []
        var text = ""
        if mods.contains(.control) {
            flags.insert(.maskControl)
            text += "⌃"
        }
        if mods.contains(.option) {
            flags.insert(.maskAlternate)
            text += "⌥"
        }
        if mods.contains(.shift) {
            flags.insert(.maskShift)
            text += "⇧"
        }
        if mods.contains(.command) {
            flags.insert(.maskCommand)
            text += "⌘"
        }
        text += keyName(event)
        return KeyCombo(keyCode: event.keyCode, flags: flags.rawValue, display: text)
    }

    private static func keyName(_ event: NSEvent) -> String {
        let named: [UInt16: String] = [
            36: "↩", 48: "⇥", 49: "Space", 51: "⌫", 53: "⎋", 117: "⌦",
            123: "←", 124: "→", 125: "↓", 126: "↑", 115: "↖", 119: "↘", 116: "⇞", 121: "⇟",
            122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8",
            101: "F9", 109: "F10", 103: "F11", 111: "F12",
        ]
        if let name = named[event.keyCode] { return name }
        return (event.charactersIgnoringModifiers ?? "?").uppercased()
    }
}

// MARK: - Cursor

private struct MouseCursorCard: View {
    @ObservedObject var mouse: MouseManager

    var body: some View {
        SettingsCard(title: "Pointer", icon: "cursorarrow.motionlines", color: .blue) {
            SettingsRow(title: "Enabled") { MouseSwitch(isOn: $mouse.prefs.cursorEnabled) }
            Group {
                MouseSlider(title: "Speed", value: $mouse.prefs.cursorSpeed, range: 0.3...4, format: "%.1f×")
                SettingsRow(title: "Acceleration off") { MouseSwitch(isOn: $mouse.prefs.cursorLinear) }
                    .help("Same hand movement, same distance, at any speed")
                if !mouse.prefs.cursorLinear {
                    MouseSlider(
                        title: "Acceleration", value: $mouse.prefs.cursorAcceleration, range: 0...3,
                        format: "%.2f")
                }
            }
            .disabled(!mouse.prefs.cursorEnabled)
            .opacity(mouse.prefs.cursorEnabled ? 1 : 0.5)
            Divider().opacity(0.35)
            DiagnosticRow(
                label: "Mouse",
                value: mouse.mouseCount == 0
                    ? "None connected" : (mouse.mouseCount == 1 ? "1 connected" : "\(mouse.mouseCount) connected"),
                isHealthy: mouse.mouseCount > 0)
            Text("External mice only. The trackpad keeps its own settings.")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
    }
}

// MARK: - Apps

private struct MouseAppsCard: View {
    @ObservedObject var mouse: MouseManager
    @Environment(\.appTheme) private var theme

    var body: some View {
        SettingsCard(title: "App exceptions", icon: "app.badge", color: .purple) {
            HStack {
                Text("Lit icons are on in that app")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                Spacer()
                RunningAppsMenu(title: "Add app", taken: Set(mouse.prefs.appRules.map(\.id))) { id, name in
                    mouse.addRule(bundleId: id, name: name)
                }
            }
            if mouse.prefs.appRules.isEmpty {
                Text("None. Add a game or an app that has its own mouse handling.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(spacing: 4) {
                    ForEach($mouse.prefs.appRules) { $rule in
                        HStack(spacing: 6) {
                            Image(nsImage: Self.icon(rule.id))
                                .resizable()
                                .frame(width: 18, height: 18)
                            Text(rule.name)
                                .font(.system(size: 11.5, weight: .medium))
                                .lineLimit(1)
                            Spacer(minLength: 4)
                            featureToggle("scroll", help: "Wheel", off: $rule.scrollOff)
                            featureToggle("circle.grid.cross", help: "Buttons", off: $rule.buttonsOff)
                            featureToggle("cursorarrow", help: "Pointer", off: $rule.cursorOff)
                            Button {
                                mouse.removeRule(rule.id)
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .help("Remove")
                        }
                        .padding(.horizontal, 7)
                        .frame(minHeight: 28)
                        .background(
                            theme.tileFill, in: RoundedRectangle(cornerRadius: theme.radius(6), style: .continuous))
                    }
                }
            }
        }
    }

    private func featureToggle(_ symbol: String, help: String, off: Binding<Bool>) -> some View {
        Button {
            off.wrappedValue.toggle()
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(off.wrappedValue ? AnyShapeStyle(.tertiary) : AnyShapeStyle(theme.accent))
                .frame(width: 22, height: 20)
                .background(
                    off.wrappedValue ? Color.clear : theme.accent.opacity(0.15),
                    in: RoundedRectangle(cornerRadius: 5)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("\(help): \(off.wrappedValue ? "off" : "on") in this app")
    }

    /// Looked up once per app; the page re-renders while Settings is open.
    private static var iconCache: [String: NSImage] = [:]

    private static func icon(_ bundleId: String) -> NSImage {
        if let cached = iconCache[bundleId] { return cached }
        let image =
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId).map {
                NSWorkspace.shared.icon(forFile: $0.path)
            } ?? NSImage(systemSymbolName: "app", accessibilityDescription: nil) ?? NSImage()
        iconCache[bundleId] = image
        return image
    }
}

// MARK: - Building blocks

private struct MouseSwitch: View {
    @Binding var isOn: Bool

    var body: some View {
        Toggle("", isOn: $isOn)
            .labelsHidden()
            .toggleStyle(.smallSwitch)
            .controlSize(.small)
    }
}

private struct MouseSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let format: String
    var scale: Double = 1

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 6)
            Slider(value: $value, in: range)
                .controlSize(.mini)
                .frame(width: 140)
            Text(String(format: format, value * scale))
                .font(.system(size: 10.5, weight: .medium).monospacedDigit())
                .frame(width: 44, alignment: .trailing)
        }
        .frame(minHeight: 22)
    }
}

/// Shown only when a feature that needs the event tap is on and Accessibility is missing.
private struct MouseAccessRow: View {
    @ObservedObject var mouse: MouseManager
    let needed: Bool

    var body: some View {
        if needed, !mouse.isAccessibilityGranted {
            HStack {
                Text("Needs Accessibility")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                Spacer()
                Button("Grant") { mouse.requestAccessibility() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
        }
    }
}

/// "Add" menu of running apps. The list is built when the page appears and when apps launch or
/// quit, not on every render (Settings pages stay mounted and re-render often).
struct RunningAppsMenu: View {
    let title: String
    let taken: Set<String>
    var custom: (() -> Void)?
    let onPick: (_ bundleId: String, _ name: String) -> Void
    @State private var apps: [(bundleId: String, name: String)] = []

    var body: some View {
        Menu {
            let available = apps.filter { !taken.contains($0.bundleId) }
            if available.isEmpty { Text("No other running apps") }
            ForEach(available, id: \.bundleId) { app in
                Button(app.name) { onPick(app.bundleId, app.name) }
            }
            if let custom {
                Divider()
                Button("Custom identifier…", action: custom)
            }
        } label: {
            Label(title, systemImage: "plus")
        }
        .menuStyle(.button)
        .buttonStyle(.bordered)
        .controlSize(.small)
        .fixedSize()
        .onAppear(perform: reload)
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didLaunchApplicationNotification)) {
            _ in reload()
        }
        .onReceive(
            NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didTerminateApplicationNotification)
        ) { _ in reload() }
    }

    private func reload() {
        let own = Bundle.main.bundleIdentifier
        var seen = Set<String>()
        apps = NSWorkspace.shared.runningApplications.compactMap { app in
            guard app.activationPolicy == .regular, let id = app.bundleIdentifier, id != own, seen.insert(id).inserted
            else { return nil }
            return (id, app.localizedName ?? id)
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}
