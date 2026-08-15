import AppKit
import SwiftUI

final class ClipboardHUDPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
final class ClipboardHUDWindowController {
    static let shared = ClipboardHUDWindowController()

    private var window: ClipboardHUDPanel?
    private var clipboardManager: ClipboardManager?

    func setup(clipboardManager: ClipboardManager) {
        self.clipboardManager = clipboardManager
    }

    func toggle() {
        if let win = window, win.isVisible {
            hide()
        } else {
            show()
        }
    }

    func show() {
        guard let manager = clipboardManager else { return }

        if window == nil {
            let panel = ClipboardHUDPanel(
                contentRect: NSRect(x: 0, y: 0, width: 440, height: 340),
                styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )

            panel.isFloatingPanel = true
            panel.level = .floating
            panel.titleVisibility = .hidden
            panel.titlebarAppearsTransparent = true
            panel.isMovableByWindowBackground = true
            panel.backgroundColor = .clear
            panel.isOpaque = false
            panel.hasShadow = true
            panel.animationBehavior = .utilityWindow

            let hostingView = NSHostingView(rootView: ClipboardHUDView(clipboardManager: manager))
            panel.contentView = hostingView

            self.window = panel
        }

        // Position window near top right / mouse position
        if let win = window {
            if let screen = NSScreen.main {
                let screenRect = screen.visibleFrame
                let x = screenRect.maxX - 460
                let y = screenRect.maxY - 360
                win.setFrameOrigin(NSPoint(x: x, y: y))
            }

            win.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    func hide() {
        window?.orderOut(nil)
    }
}
