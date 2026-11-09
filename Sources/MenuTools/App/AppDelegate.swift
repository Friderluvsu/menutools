import AppKit
import Carbon
import Combine
import ObjectiveC
import SwiftUI

@objc(ZeroBlinkStatusBarButton)
private final class ZeroBlinkStatusBarButton: NSStatusBarButton {
    override func highlight(_ flag: Bool) {
        // Suppress programmatic highlight drawing
    }

    override var isHighlighted: Bool {
        get { false }
        set { }
    }

    override func draw(_ dirtyRect: NSRect) {
        cell?.isHighlighted = false
        super.draw(dirtyRect)
    }

    override func mouseDown(with event: NSEvent) {
        // DO NOT call super.mouseDown(with: event)!
        AppDelegate.sharedInstance?.statusButtonMouseDown()
    }

    override func mouseUp(with event: NSEvent) {
        // No-op (DO NOT dispatch togglePanel on mouseUp, avoiding the asynchronous time gap race condition).
        AppDelegate.sharedInstance?.statusButtonMouseUp()
    }

    override func rightMouseDown(with event: NSEvent) {
        AppDelegate.sharedInstance?.statusButtonMouseDown()
    }

    override func rightMouseUp(with event: NSEvent) {
        // Mirrors mouseUp: clears the press flag so outside clicks can close the panel again.
        AppDelegate.sharedInstance?.statusButtonMouseUp()
    }

    // Hover peek: enter / exit only, no mouse-moved events. No stored property here: the system
    // button is re-classed with object_setClass, so a subclass ivar would have no storage. The area
    // is found again by its userInfo tag.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas where area.userInfo?["menutools.hover"] != nil {
            removeTrackingArea(area)
        }
        addTrackingArea(
            NSTrackingArea(
                rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self,
                userInfo: ["menutools.hover": true]))
    }

    override func mouseEntered(with event: NSEvent) {
        AppDelegate.sharedInstance?.statusButtonHover(true)
    }

    override func mouseExited(with event: NSEvent) {
        AppDelegate.sharedInstance?.statusButtonHover(false)
    }

    /// Keeps the live status lights over the image slot (left of any title).
    override func layout() {
        super.layout()
        guard let lights = subviews.first(where: { $0 is StatusLightsView }) else { return }
        let slot = (cell as? NSButtonCell)?.imageRect(forBounds: bounds) ?? bounds
        let size = lights.frame.size
        lights.frame = NSRect(
            x: (slot.midX - size.width / 2).rounded(), y: (slot.midY - size.height / 2).rounded(),
            width: size.width, height: size.height)
    }

    // Spring-loaded: dragging files over the icon opens the panel; the drop itself happens inside the panel.
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        AppDelegate.sharedInstance?.statusButtonDragEntered()
        return []
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        []
    }
}

/// First click on the inactive panel (e.g. right after a Finder drop) acts immediately instead of only activating.
private final class PanelHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func layout() {
        super.layout()
        silenceFocusRings(in: self)
    }

    override func didAddSubview(_ subview: NSView) {
        super.didAddSubview(subview)
        silenceFocusRings(in: subview)
    }

    /// Clicks must not draw the accent ring. SwiftUI menus still become key and paint it otherwise.
    private func silenceFocusRings(in view: NSView) {
        if view.focusRingType != .none { view.focusRingType = .none }
        if let cell = (view as? NSControl)?.cell, cell.focusRingType != .none {
            cell.focusRingType = .none
        }
        for subview in view.subviews {
            silenceFocusRings(in: subview)
        }
    }
}

private final class MenuToolsPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            AppDelegate.sharedInstance?.hidePanel()
        } else {
            super.keyDown(with: event)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static private(set) var sharedInstance: AppDelegate?

    private var statusItem: NSStatusItem!
    private var panel: MenuToolsPanel?
    private var resignObserver: NSObjectProtocol?
    private var outsideClickMonitor: Any?
    private var appState: AppState!
    private var currentIconStyle: MenuBarIconStyle?
    private var lastBatteryPercentage: Int = -1
    private var lastBatteryCharging: Bool = false
    private var lastBatteryPluggedIn: Bool = false
    private var lastBatteryLowPower: Bool = false
    private var lastDarkMode: Bool?
    private var lastSessionAlert = false
    /// Trial switch. The old battery and symbol drawing is `updateLegacyStatusItemIcon`.
    /// Settings → General → "Status lights". Off draws the static icon in `updateLegacyStatusItemIcon`.
    private var sessionRingEnabled: Bool { StatusLightSettings.shared.enabled }
    /// Draws and animates the three session lights (style picked in Settings → General).
    private var statusLights: StatusLightsAnimator?
    private let sessionPeek = SessionPeekController()
    private var lastTitleSegments: [MenuBarSegment]?
    private var lastMarkCounts: [Int]?
    private var bypassPoll: Timer?
    private var isMouseDownOnButton: Bool = false
    // Outside-press state machine: a press outside the panel only closes it on mouse up, and only if it was not a drag.
    private let dragPasteboard = NSPasteboard(name: .drag)
    private var outsidePressActive = false
    private var outsidePressLocation = NSPoint.zero
    private var outsidePressDragCount = 0
    private var outsidePressMoved = false
    private var outsidePressDragged = false
    private var panelShownAt: TimeInterval = 0
    /// True between showPanel and hidePanel, even if AppKit ordered the window out on its own.
    private var isPanelOpen = false
    private var panelClosedAt: TimeInterval = 0
    /// Natural content height reported by SwiftUI; the panel fits it exactly (no scrolling).
    private var panelContentHeight: CGFloat = MacToolsTheme.popoverHeight
    /// Screen Y of the panel's top edge, captured when the panel is shown. Height changes
    /// keep this value so the window never slides toward the menu bar.
    private var anchoredPanelTop: CGFloat?
    private var appearanceObservation: NSKeyValueObservation?
    private var cancellables = Set<AnyCancellable>()
    private var sigtermSource: DispatchSourceSignal?
    private var sessionMarksObserver: NSObjectProtocol?
    /// Holds off App Nap while no window is open, so a later input-needed scan still reaches the icon.
    private var sessionWatchActivity: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Self.sharedInstance = self

        // Run purely as an accessory menu bar application (no Dock icon)
        NSApp.setActivationPolicy(.accessory)
        // No window means App Nap, which defers the session timers until the panel opens.
        sessionWatchActivity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep],
            reason: "Menu bar session status")

        self.appState = AppState()

        setupStatusItem()
        // The panel (and its SwiftUI graph) is built on first open; idle memory stays low.
        setupGlobalHotkeys()
        setupTerminationSignal()
        ShelfManager.shared.start()

        // Automatically reset buggy Google Drive FinderSync extension on startup
        self.appState.systemUtils.autoResetGoogleDriveHelper()

        if CommandLine.arguments.contains("--panel-memory-diagnose") {
            PanelMemoryDiagnose.run(delegate: self)
        } else if CommandLine.arguments.contains("--show-popover") {
            DispatchQueue.main.async { [weak self] in
                self?.showPanel()
            }
        }
    }

    /// `killall` / logout send SIGTERM, which skips applicationWillTerminate: route it through
    /// NSApp.terminate so Anti-Sleep restores pmset and stops caffeinate.
    private func setupTerminationSignal() {
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler {
            MainActor.assumeIsolated { NSApp.terminate(nil) }
        }
        source.resume()
        sigtermSource = source
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem.button {
            object_setClass(button, ZeroBlinkStatusBarButton.self)
            (button.cell as? NSButtonCell)?.highlightsBy = []
            (button.cell as? NSButtonCell)?.showsStateBy = []
            button.highlight(false)
            statusLights = StatusLightsAnimator(
                button: button,
                isDark: { NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua })
            updateStatusItemIcon()
            button.imagePosition = .imageLeft
            button.action = #selector(togglePanel(_:))
            button.target = self
            button.registerForDraggedTypes([.fileURL])
        }

        // Event-driven: battery / anti-sleep / network changes arrive via AppState, theme changes via KVO.
        appearanceObservation = NSApp.observe(\.effectiveAppearance, options: [.new]) { [weak self] _, _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.statusLights?.refresh()
                    // Symbols are drawn for one appearance; rebuild the title for the new one.
                    self?.lastTitleSegments = nil
                    self?.updateStatusItemTitle()
                    self?.updateStatusItemIcon()
                }
            }
        }

        appState.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updateStatusItemTitle()
                self?.updateStatusItemIcon()
            }
            .store(in: &cancellables)
        // Awake / Closed-lid symbols and countdowns in the menu bar title.
        appState.antiSleep.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateStatusItemTitle() }
            .store(in: &cancellables)

        // Session refreshes post this after the new rows are stored. objectWillChange fires in willSet,
        // which can paint the previous marks and then skip the real change until the panel opens.
        MenuBarItemsStore.shared.$items
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.syncMenuBarItemSources() }
            .store(in: &cancellables)

        StatusLightSettings.shared.$enabled
            .dropFirst()
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] enabled in self?.statusLightsToggled(enabled) }
            .store(in: &cancellables)

        sessionMarksObserver = NotificationCenter.default.addObserver(
            forName: .sessionMenuMarksChanged, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.updateStatusItemIcon()
                if let self { self.sessionPeek.refresh(self.appState?.sessionPeek ?? []) }
            }
        }
    }

    private func setupPanel() {
        let panel = MenuToolsPanel(
            contentRect: NSRect(x: 0, y: 0, width: MacToolsTheme.popoverWidth, height: MacToolsTheme.popoverHeight),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .popUpMenu
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.animationBehavior = .none
        panel.isReleasedWhenClosed = false
        // NSPanel defaults to true: the panel would vanish on the first click into another app,
        // before the outside-press logic can tell a file drag from a plain click.
        panel.hidesOnDeactivate = false
        // `--show-popover --stat cpu` opens that detail page live (to measure a page's CPU use).
        var launchStat: StatTopic?
        if CommandLine.arguments.contains("--show-popover"),
            let flag = CommandLine.arguments.firstIndex(of: "--stat"),
            CommandLine.arguments.indices.contains(flag + 1)
        {
            launchStat = StatTopic(rawValue: CommandLine.arguments[flag + 1])
            if let launchStat { appState.systemMonitor.setStatFocus(launchStat) }
        }
        let hostingView = PanelHostingView(
            rootView: PopoverContentView(
                appState: self.appState,
                showStat: launchStat,
                onHeightChange: { [weak self] height in self?.panelContentHeightChanged(height) }
            )
        )
        // The panel frame is driven by panelContentHeightChanged, not by hosting-view constraints.
        hostingView.sizingOptions = []
        panel.contentView = hostingView
        // Catalog themes force the dark appearance so
        // AppKit controls match the theme; Classic follows the system.
        ThemeManager.shared.$theme
            .map(\.appearance)
            .removeDuplicates()
            .sink { [weak panel] name in panel?.appearance = name.flatMap(NSAppearance.init(named:)) }
            .store(in: &cancellables)

        if let existing = resignObserver {
            NotificationCenter.default.removeObserver(existing)
        }
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: panel,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self = self else { return }
                guard !self.shouldIgnoreOutsideEvent() else { return }
                // Button held (e.g. picking up a file in Finder): decide on mouse up, once we know if it is a drag.
                if NSEvent.pressedMouseButtons & 1 != 0 {
                    if !self.outsidePressActive { self.beginOutsidePress() }
                    return
                }
                self.hidePanel()
            }
        }

        self.panel = panel
    }

    private func updatePanelPosition() {
        guard let panel = panel,
              let button = statusItem?.button,
              let window = button.window else { return }

        let buttonFrame = window.convertToScreen(button.convert(button.bounds, to: nil))
        let screen = window.screen ?? NSScreen.main ?? NSScreen.screens.first
        let screenVisible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1920, height: 1080)
        let maxHeight = screenVisible.height - 8
        let panelSize = NSSize(width: MacToolsTheme.popoverWidth, height: min(panelContentHeight, maxHeight).rounded(.up))

        var x = buttonFrame.midX - (panelSize.width / 2)
        let minX = screenVisible.minX + 8
        let maxX = screenVisible.maxX - panelSize.width - 8
        x = max(minX, min(x, maxX))

        // Anchor the top once per open. Later height changes only move the bottom edge.
        // Animating setFrame is what made the whole panel jump toward the menu bar.
        let placing = anchoredPanelTop == nil || !panel.isVisible
        let top = anchoredPanelTop ?? (buttonFrame.minY - 4)
        anchoredPanelTop = top
        let originX = placing ? x : panel.frame.minX
        let frame = NSRect(x: originX, y: top - panelSize.height, width: panelSize.width, height: panelSize.height)
        guard panel.frame != frame else { return }
        NSAnimationContext.beginGrouping()
        NSAnimationContext.current.duration = 0
        NSAnimationContext.current.allowsImplicitAnimation = false
        panel.setFrame(frame, display: panel.isVisible, animate: false)
        NSAnimationContext.endGrouping()
    }

    /// Re-fit the panel when the content grows or shrinks (converter tasks, settings, pickers), keeping its top edge.
    private func panelContentHeightChanged(_ height: CGFloat) {
        guard height > 1, abs(height - panelContentHeight) >= 0.5 else { return }
        panelContentHeight = height
        guard panel?.isVisible == true else { return }
        // Same turn as the SwiftUI layout. Waiting a frame lets the new content draw
        // in the old window, which reads as the panel jumping.
        updatePanelPosition()
    }

    /// Hover peek: a session card under the icon while the pointer rests on it (lights on, panel closed).
    func statusButtonHover(_ inside: Bool) {
        guard let button = statusItem.button else { return }
        let wanted =
            inside && !isPanelOpen && StatusLightSettings.shared.enabled && StatusLightSettings.shared.hoverPeek
        sessionPeek.hover(wanted, button: button) { [weak self] in self?.appState?.sessionPeek ?? [] }
    }

    func statusButtonMouseDown() {
        sessionPeek.hide()
        isMouseDownOnButton = true
        togglePanel(nil)
    }

    func statusButtonMouseUp() {
        isMouseDownOnButton = false
    }

    func isClickOnStatusButton(mouseLocation: NSPoint) -> Bool {
        guard let button = statusItem?.button,
              let window = button.window else {
            return false
        }
        let buttonScreenRect = window.convertToScreen(button.convert(button.bounds, to: nil))
        let windowScreenRect = window.frame
        let targetRect = buttonScreenRect.union(windowScreenRect).insetBy(dx: -8, dy: -8)
        return targetRect.contains(mouseLocation)
    }

    /// `activate: false` shows the panel without taking focus, so an in-flight drag session is not disturbed.
    func showPanel(activate: Bool = true) {
        sessionPeek.hide()
        // Scan before the first layout so a live session is in the tree when the height is measured.
        appState?.onPopoverWillShow()
        if panel == nil {
            setupPanel()
        }
        anchoredPanelTop = nil
        panel?.contentView?.layoutSubtreeIfNeeded()
        updatePanelPosition()
        panelShownAt = ProcessInfo.processInfo.systemUptime
        isPanelOpen = true
        if sessionRingEnabled { statusLights?.playOpen() }
        if activate {
            panel?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        } else {
            panel?.orderFrontRegardless()
        }
        startOutsideClickMonitor()
    }

    /// After a drop from Finder the panel is visible but not key: take focus so Esc and clicks work.
    func focusPanelAfterDrop() {
        guard isPanelOpen, panel?.isKeyWindow == false else { return }
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.isPanelOpen, let panel = self.panel else { return }
                NSApp.activate(ignoringOtherApps: true)
                panel.makeKey()
            }
        }
    }

    /// Brings the panel back after a modal (e.g. the converter's file chooser) closed it via resign-key.
    func reopenPanelIfHidden() {
        guard panel?.isVisible != true else { return }
        showPanel()
    }

    func statusButtonDragEntered() {
        guard panel?.isVisible != true else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard now - panelClosedAt >= 0.15 else { return }
        showPanel(activate: false)
    }

    var appStateForDiagnose: AppState? { appState }

    func hidePanel() {
        guard let panel = panel, isPanelOpen || panel.isVisible else { return }
        // Teardown runs even if the window is already gone, so monitors and polling never outlive the panel.
        isPanelOpen = false
        panelClosedAt = ProcessInfo.processInfo.systemUptime
        outsidePressActive = false
        stopOutsideClickMonitor()
        if panel.isVisible { panel.orderOut(nil) }
        appState?.onPopoverDidClose()
    }

    @objc func togglePanel(_ sender: AnyObject?) {
        let now = ProcessInfo.processInfo.systemUptime
        if panel?.isVisible == true {
            hidePanel()
            return
        }
        if now - panelClosedAt < 0.15 {
            return
        }
        showPanel()
    }

    private func shouldIgnoreOutsideEvent() -> Bool {
        if isMouseDownOnButton { return true }
        let now = ProcessInfo.processInfo.systemUptime
        if now - panelShownAt < 0.15 { return true }
        return isClickOnStatusButton(mouseLocation: NSEvent.mouseLocation)
    }

    private func beginOutsidePress() {
        outsidePressActive = true
        outsidePressLocation = NSEvent.mouseLocation
        outsidePressDragCount = dragPasteboard.changeCount
        outsidePressMoved = false
        outsidePressDragged = false
    }

    private func startOutsideClickMonitor() {
        stopOutsideClickMonitor()
        // Only press/drag/release while the panel is visible; removed on hide.
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .leftMouseDragged, .leftMouseUp]
        ) { [weak self] event in
            let type = event.type
            MainActor.assumeIsolated {
                self?.handleOutsideMouse(type)
            }
        }
    }

    private func handleOutsideMouse(_ type: NSEvent.EventType) {
        switch type {
        case .leftMouseDown:
            outsidePressActive = false
            guard !shouldIgnoreOutsideEvent() else { return }
            beginOutsidePress()
        case .rightMouseDown:
            guard !shouldIgnoreOutsideEvent() else { return }
            hidePanel()
        case .leftMouseDragged:
            guard outsidePressActive, !outsidePressDragged else { return }
            if dragPasteboard.changeCount != outsidePressDragCount {
                outsidePressDragged = true
                return
            }
            if !outsidePressMoved {
                let p = NSEvent.mouseLocation
                outsidePressMoved = hypot(p.x - outsidePressLocation.x, p.y - outsidePressLocation.y) > 4
            }
        case .leftMouseUp:
            guard outsidePressActive else { return }
            outsidePressActive = false
            // A drag session wrote to the drag pasteboard: user is carrying something to the panel, keep it open.
            if outsidePressDragged || dragPasteboard.changeCount != outsidePressDragCount { return }
            // Plain drag (window move, selection) that ended over the panel: keep it as well.
            if outsidePressMoved, panel?.frame.contains(NSEvent.mouseLocation) == true { return }
            hidePanel()
        default:
            break
        }
    }

    private func stopOutsideClickMonitor() {
        if let monitor = outsideClickMonitor {
            NSEvent.removeMonitor(monitor)
            outsideClickMonitor = nil
        }
    }

    private func setupGlobalHotkeys() {
        // Register ⌥⌘V (Option + Command + V) for Clipboard HUD
        let vKeyCode: UInt32 = 9
        let modifiers: UInt32 = UInt32(cmdKey | optionKey)

        CarbonHotKeyHelper.shared.register(id: 1, keyCode: vKeyCode, modifiers: modifiers) {
            Task { @MainActor in
                ClipboardHUDWindowController.shared.toggle()
            }
        }

        // ⇧⌥⌘V: paste as plain text (registered only while the setting is on)
        appState.clipboard.updatePlainPasteHotkey()
    }

    private func updateStatusItemIcon() {
        guard let button = statusItem.button, let state = appState else { return }
        if sessionRingEnabled {
            updateSessionRingIcon(button: button, state: state)
            return
        }
        updateLegacyStatusItemIcon()
    }

    /// Switching between the colour lights and the static icon. Both paths cache what they drew last,
    /// so the caches are cleared to force a repaint.
    private func statusLightsToggled(_ enabled: Bool) {
        currentIconStyle = nil
        lastMarkCounts = nil
        lastSessionAlert = false
        lastDarkMode = nil
        lastBatteryPercentage = -1
        statusItem.button?.toolTip = nil
        statusLights?.setActive(enabled)
        updateStatusItemIcon()
        if enabled { statusLights?.playOpen() }
    }

    /// Three lights. Input, running and an unseen end; `StatusLightsAnimator` animates changes.
    private func updateSessionRingIcon(button: NSStatusBarButton, state: AppState) {
        let marks = state.sessionMarks
        let tip = marks.tooltip.isEmpty ? nil : marks.tooltip
        // The hover peek replaces the plain tooltip.
        let shownTip = StatusLightSettings.shared.hoverPeek ? nil : tip
        if button.toolTip != shownTip { button.toolTip = shownTip }
        // Every manager posts on every refresh; most of those carry the same counts.
        let counts = [marks.inputCount, marks.runningCount, marks.endedCount]
        guard counts != lastMarkCounts else { return }
        lastMarkCounts = counts
        statusLights?.update(counts: counts)
    }

    /// Battery bars and symbol styles. Used while `sessionRingEnabled` is false.
    private func updateLegacyStatusItemIcon() {
        guard let button = statusItem.button, let state = appState else { return }
        let style = state.menuBarIconStyle

        if style.isBatteryStyle {
            let pct = state.battery.percentage
            let charging = state.battery.isCharging
            let pluggedIn = state.battery.isPluggedIn
            let lowPower = state.battery.isLowPowerMode
            let hasBattery = state.battery.hasBattery
            // The menu bar follows the system appearance; the status button itself can report .aqua over a dark bar.
        let isDarkMode = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let alert = state.hasSessionAlert

        if currentIconStyle != style
            || lastBatteryPercentage != pct
            || lastBatteryCharging != charging
            || lastBatteryPluggedIn != pluggedIn
            || lastBatteryLowPower != lowPower
            || lastDarkMode != isDarkMode
            || lastSessionAlert != alert
        {
                let image: NSImage
                switch style {
                case .batteryBarGoldenGate:
                    // macOS 27 shows the bolt whenever AC is attached, even when charging is on hold.
                    image = BatteryIconRenderer.renderGoldenGateBar(
                        percentage: pct,
                        isCharging: charging || pluggedIn,
                        isLowPowerMode: lowPower,
                        showPercentInside: false,
                        isDarkMode: isDarkMode
                    )
                case .batteryBarGoldenGatePercent:
                    // macOS 27 shows the bolt whenever AC is attached, even when charging is on hold.
                    image = BatteryIconRenderer.renderGoldenGateBar(
                        percentage: pct,
                        isCharging: charging || pluggedIn,
                        isLowPowerMode: lowPower,
                        showPercentInside: true,
                        isDarkMode: isDarkMode
                    )
                case .batteryBar:
                    image = BatteryIconRenderer.renderBar(
                        percentage: pct,
                        isCharging: charging,
                        isLowPowerMode: lowPower,
                        showPercentage: false,
                        isDarkMode: isDarkMode
                    )
                case .batteryBarPercentage:
                    image = BatteryIconRenderer.renderBar(
                        percentage: pct,
                        isCharging: charging,
                        isLowPowerMode: lowPower,
                        showPercentage: true,
                        showPercentSymbol: true,
                        isDarkMode: isDarkMode
                    )
                case .batteryBarCharge:
                    image = BatteryIconRenderer.renderBar(
                        percentage: pct,
                        isCharging: charging,
                        isLowPowerMode: lowPower,
                        showPercentage: true,
                        showPercentSymbol: false,
                        isDarkMode: isDarkMode
                    )
                case .batteryCharge:
                    image = BatteryIconRenderer.renderChargeOnly(
                        percentage: pct,
                        isCharging: charging,
                        isLowPowerMode: lowPower,
                        hasBattery: hasBattery,
                        isDarkMode: isDarkMode
                    )
                case .batteryRingNumber:
                    image = BatteryIconRenderer.renderRing(
                        percentage: pct,
                        isCharging: charging,
                        isLowPowerMode: lowPower,
                        hasBattery: hasBattery,
                        showPercentageNumber: true,
                        isDarkMode: isDarkMode
                    )
                case .batteryRing:
                    image = BatteryIconRenderer.renderRing(
                        percentage: pct,
                        isCharging: charging,
                        isLowPowerMode: lowPower,
                        hasBattery: hasBattery,
                        showPercentageNumber: false,
                        isDarkMode: isDarkMode
                    )
                default:
                    image = BatteryIconRenderer.renderRing(
                        percentage: pct,
                        isCharging: charging,
                        isLowPowerMode: lowPower,
                        hasBattery: hasBattery,
                        showPercentageNumber: false,
                        isDarkMode: isDarkMode
                    )
                }
                button.image = alert ? Self.withAlertDot(image, isDark: isDarkMode) : image
                currentIconStyle = style
                lastBatteryPercentage = pct
                lastBatteryCharging = charging
                lastBatteryPluggedIn = pluggedIn
                lastBatteryLowPower = lowPower
                lastDarkMode = isDarkMode
                lastSessionAlert = alert
            }
        } else {
            let alert = state.hasSessionAlert
            let isDarkMode = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            guard currentIconStyle != style || lastSessionAlert != alert || lastDarkMode != isDarkMode else { return }
            let config = NSImage.SymbolConfiguration(pointSize: 13.5, weight: .semibold)
            let image = NSImage(systemSymbolName: style.symbolName, accessibilityDescription: "MenuTools")?
                .withSymbolConfiguration(config)
            image?.isTemplate = true
            button.image = alert ? image.flatMap { Self.withAlertDot($0, isDark: isDarkMode) } : image
            currentIconStyle = style
            lastSessionAlert = alert
            lastDarkMode = isDarkMode
        }
    }

    /// Orange dot on the menu bar icon while a Cursor chat has finished and has not been opened yet.
    private static func withAlertDot(_ image: NSImage, isDark: Bool) -> NSImage {
        let size = image.size
        let canvas = NSImage(size: NSSize(width: size.width + 2, height: size.height))
        canvas.lockFocus()
        let draw = NSRect(x: 0, y: 0, width: size.width, height: size.height)
        if image.isTemplate {
            let tinted = NSImage(size: size)
            tinted.lockFocus()
            image.draw(in: NSRect(origin: .zero, size: size))
            (isDark ? NSColor.white : NSColor.black).setFill()
            NSRect(origin: .zero, size: size).fill(using: .sourceAtop)
            tinted.unlockFocus()
            tinted.isTemplate = false
            tinted.draw(in: draw)
        } else {
            image.draw(in: draw)
        }
        let dot = NSRect(x: size.width - 3.5, y: size.height - 5, width: 5, height: 5)
        NSColor.systemOrange.setFill()
        NSBezierPath(ovalIn: dot).fill()
        canvas.unlockFocus()
        canvas.isTemplate = false
        return canvas
    }

    /// Menu bar items beside the icon (Settings → General → Menu bar). Rebuilt only when the pieces change.
    private func updateStatusItemTitle() {
        guard let button = statusItem.button, let state = appState else { return }
        let segments = state.menuBarSegments(MenuBarItemsStore.shared.ordered)
        guard segments != lastTitleSegments else { return }
        lastTitleSegments = segments
        if segments.isEmpty {
            button.title = ""
        } else {
            button.attributedTitle = MenuBarTitleRenderer.title(
                segments, font: button.font ?? NSFont.menuBarFont(ofSize: 0))
        }
    }

    /// Stat items follow the 2 s sampler; VPN / SpoofDPI items poll their status every 15 s while the
    /// panel is closed (the panel polls every 5 s itself).
    private func syncMenuBarItemSources() {
        let store = MenuBarItemsStore.shared
        appState?.systemMonitor.onSample =
            store.needsStats
            ? { [weak self] in MainActor.assumeIsolated { self?.updateStatusItemTitle() } } : nil
        bypassPoll?.invalidate()
        bypassPoll = nil
        if store.needsNetworkBypass {
            appState?.network.refreshStatus()
            let timer = Timer(timeInterval: 15, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, !self.isPanelOpen else { return }
                    self.appState?.network.refreshStatus()
                }
            }
            timer.tolerance = 3
            RunLoop.main.add(timer, forMode: .common)
            bypassPoll = timer
        }
        updateStatusItemTitle()
    }

    func applicationWillTerminate(_ notification: Notification) {
        ShelfManager.shared.stop()
        if let sessionWatchActivity {
            ProcessInfo.processInfo.endActivity(sessionWatchActivity)
        }
        // Synchronous: the process exits right after this returns, so no Task would ever run.
        appState?.antiSleep.prepareForTermination()
        appState?.mouse.prepareForTermination()
    }
}
