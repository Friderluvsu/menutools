import AppKit
import Carbon

@MainActor
final class CarbonHotKeyHelper {
    static let shared = CarbonHotKeyHelper()

    private var hotKeyRefs: [UInt32: EventHotKeyRef] = [:]
    private var handlers: [UInt32: @MainActor () -> Void] = [:]
    private var handlerInstalled = false

    /// Registers (or replaces) the hotkey with this id.
    func register(id: UInt32 = 1, keyCode: UInt32, modifiers: UInt32, action: @escaping @MainActor () -> Void) {
        installHandlerIfNeeded()
        unregister(id: id)
        handlers[id] = action

        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: OSType(0x4D54_4F4C), id: id)  // "MTOL"
        let status = RegisterEventHotKey(
            keyCode,
            modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &ref
        )
        if status == noErr, let ref {
            hotKeyRefs[id] = ref
        } else {
            handlers[id] = nil
        }
    }

    func unregister(id: UInt32) {
        if let ref = hotKeyRefs.removeValue(forKey: id) {
            UnregisterEventHotKey(ref)
        }
        handlers[id] = nil
    }

    fileprivate func fire(id: UInt32) {
        handlers[id]?()
    }

    private func installHandlerIfNeeded() {
        guard !handlerInstalled else { return }
        handlerInstalled = true

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: OSType(kEventHotKeyPressed)
        )

        InstallEventHandler(
            GetApplicationEventTarget(),
            { (_, inEvent, _) -> OSStatus in
                var hotKeyID = EventHotKeyID()
                let status = GetEventParameter(
                    inEvent,
                    EventParamName(kEventParamDirectObject),
                    EventParamName(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )
                if status == noErr {
                    let id = hotKeyID.id
                    Task { @MainActor in
                        CarbonHotKeyHelper.shared.fire(id: id)
                    }
                }
                return noErr
            },
            1,
            &eventType,
            nil,
            nil
        )
    }
}
