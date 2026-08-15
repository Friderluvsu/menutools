import AppKit
import SwiftUI

@MainActor
enum PreviewRenderer {
    static func render(to outputURL: URL, showSettings: Bool) -> Bool {
        let appState = AppState(previewMode: true)
        let size = NSSize(width: MacToolsTheme.popoverWidth, height: MacToolsTheme.popoverHeight)
        let rootView = PopoverContentView(appState: appState, showSettings: showSettings)
        let hostingView = NSHostingView(rootView: rootView)
        hostingView.frame = NSRect(origin: .zero, size: size)

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = hostingView
        window.backgroundColor = .windowBackgroundColor
        window.layoutIfNeeded()
        hostingView.layoutSubtreeIfNeeded()
        hostingView.displayIfNeeded()

        guard let bitmap = hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds) else { return false }
        hostingView.cacheDisplay(in: hostingView.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { return false }

        do {
            try data.write(to: outputURL, options: .atomic)
            return true
        } catch {
            fputs("Preview render failed: \(error.localizedDescription)\n", stderr)
            return false
        }
    }
}
