import AppKit
import Carbon

@MainActor
final class CarbonHotKeyHelper {
    static let shared = CarbonHotKeyHelper()

    private var hotKeyRef: EventHotKeyRef?
    var handler: (@MainActor () -> Void)?

    func register(keyCode: UInt32, modifiers: UInt32, action: @escaping @MainActor () -> Void) {
        self.handler = action

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
                if status == noErr && hotKeyID.id == 1 {
                    Task { @MainActor in
                        CarbonHotKeyHelper.shared.handler?()
                    }
                }
                return noErr
            },
            1,
            &eventType,
            nil,
            nil
        )

        let hotKeyID = EventHotKeyID(signature: OSType(0x4D54_4F4C), id: 1)  // "MTOL", 1
        RegisterEventHotKey(
            keyCode,
            modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
    }
}
