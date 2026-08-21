import AppKit
import Carbon
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var appState: AppState!
    private var currentIconStyle: MenuBarIconStyle?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Run purely as an accessory menu bar application (no Dock icon)
        NSApp.setActivationPolicy(.accessory)

        self.appState = AppState()

        setupStatusItem()
        setupPopover()
        setupGlobalHotkeys()

        if CommandLine.arguments.contains("--show-popover") {
            DispatchQueue.main.async { [weak self] in
                self?.togglePopover(nil)
            }
        }
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem.button {
            updateStatusItemIcon()
            button.imagePosition = .imageLeft
            button.action = #selector(togglePopover(_:))
            button.target = self
        }

        // Update menu bar title and icon asynchronously
        Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.updateStatusItemTitle()
                self?.updateStatusItemIcon()
            }
        }
    }

    private func updateStatusItemIcon() {
        guard let button = statusItem.button, let state = appState else { return }
        guard currentIconStyle != state.menuBarIconStyle else { return }
        let config = NSImage.SymbolConfiguration(pointSize: 13.5, weight: .medium)
        let image = NSImage(systemSymbolName: state.menuBarIconStyle.symbolName, accessibilityDescription: "MenuTools")?
            .withSymbolConfiguration(config)
        image?.isTemplate = true
        button.image = image
        currentIconStyle = state.menuBarIconStyle
    }

    private func setupPopover() {
        popover = NSPopover()
        popover.contentSize = NSSize(width: MacToolsTheme.popoverWidth, height: MacToolsTheme.popoverHeight)
        popover.behavior = .transient
        popover.animates = false
        popover.delegate = self
    }

    private func ensurePopoverContent() {
        if popover.contentViewController == nil {
            let contentView = PopoverContentView(appState: self.appState)
            popover.contentViewController = NSHostingController(rootView: contentView)
        }
    }

    private func setupGlobalHotkeys() {
        // Register ⌥⌘V (Option + Command + V) for Clipboard HUD
        let vKeyCode: UInt32 = 9
        let modifiers: UInt32 = UInt32(cmdKey | optionKey)

        CarbonHotKeyHelper.shared.register(keyCode: vKeyCode, modifiers: modifiers) {
            Task { @MainActor in
                ClipboardHUDWindowController.shared.toggle()
            }
        }
    }

    @objc func togglePopover(_ sender: AnyObject?) {
        guard let button = statusItem.button else { return }

        if popover.isShown {
            popover.performClose(sender)
        } else {
            ensurePopoverContent()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    func popoverWillShow(_ notification: Notification) {
        appState?.onPopoverWillShow()
    }

    func popoverDidClose(_ notification: Notification) {
        appState?.onPopoverDidClose()
    }

    private func updateStatusItemTitle() {
        guard let button = statusItem.button, let state = appState else { return }
        let title = state.menuBarTitle
        if button.title != title {
            button.title = title
        }
    }
}
