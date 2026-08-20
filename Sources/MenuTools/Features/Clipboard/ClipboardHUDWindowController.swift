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
    private var previousApp: NSRunningApplication?
    private var resignObserver: NSObjectProtocol?

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

        // Immediately check pasteboard to capture any recent copy
        manager.checkPasteboard()

        // Remember the application that was active before HUD opened
        if let active = NSWorkspace.shared.frontmostApplication,
            active.bundleIdentifier != Bundle.main.bundleIdentifier
        {
            previousApp = active
        }

        manager.searchQuery = ""
        manager.selectedIndex = 0
        manager.isHUDVisible = true

        if window == nil {
            let panel = ClipboardHUDPanel(
                contentRect: NSRect(x: 0, y: 0, width: 480, height: 380),
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

            // Auto-hide when user clicks outside the HUD panel
            resignObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didResignKeyNotification,
                object: panel,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.hide()
                }
            }

            self.window = panel
        } else if let panel = window, let hostingView = panel.contentView as? NSHostingView<ClipboardHUDView> {
            // Force re-evaluate SwiftUI hierarchy with latest state
            hostingView.rootView = ClipboardHUDView(clipboardManager: manager)
        }

        if let win = window {
            // Center the window on the active screen containing the mouse cursor
            let mouseLoc = NSEvent.mouseLocation
            let targetScreen =
                NSScreen.screens.first(where: { NSMouseInRect(mouseLoc, $0.frame, false) }) ?? NSScreen.main
            if let screen = targetScreen {
                let screenRect = screen.visibleFrame
                let x = screenRect.midX - 240
                let y = screenRect.midY - 140
                win.setFrameOrigin(NSPoint(x: x, y: y))
            }

            win.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    func hide() {
        clipboardManager?.isHUDVisible = false
        window?.orderOut(nil)
    }

    func hideAndPaste() {
        hide()

        let target = previousApp
        if let target {
            if #available(macOS 14.0, *) {
                target.activate(options: [.activateAllWindows])
            } else {
                target.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            ClipboardManager.simulatePasteCommand()
        }
    }
}
