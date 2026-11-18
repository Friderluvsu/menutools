import AppKit
import IOKit
import IOKit.hid

/// Pointer speed and acceleration for external mice, set live on each mouse's HID service
/// (`HIDPointerResolution`, and the key named by `HIDPointerAccelerationType`). Trackpads are left
/// alone. The device's own values are saved on first change and written back by `restore()`. They are
/// also kept in UserDefaults (`MousePointerOriginals`, per vendor / product / serial) until restored,
/// so a crash or SIGKILL while changed does not make the changed value the new "original" (speed
/// would compound on the next launch).
@MainActor
final class PointerController {
    private struct Original {
        let service: IOHIDServiceClient
        let accelerationKey: String
        let resolution: CFTypeRef?
        let acceleration: CFTypeRef?
        let deviceKey: String
    }

    private static let savedKey = "MousePointerOriginals"

    /// `com.apple.mouse.scaling` as IOFixed (macOS default 0.6875 when unset; -1 stays -1).
    private static func systemAcceleration() -> NSNumber {
        let value =
            CFPreferencesCopyValue(
                "com.apple.mouse.scaling" as CFString, kCFPreferencesAnyApplication, kCFPreferencesCurrentUser,
                kCFPreferencesAnyHost) as? Double ?? 0.6875
        return NSNumber(value: Int(value * 65_536))
    }

    private static func savedOriginals() -> [String: [String: NSNumber]] {
        UserDefaults.standard.dictionary(forKey: savedKey) as? [String: [String: NSNumber]] ?? [:]
    }

    /// Stable across reconnects and relaunches (registry ids are not).
    private static func deviceKey(_ service: IOHIDServiceClient) -> String {
        func value(_ key: String) -> String {
            (IOHIDServiceClientCopyProperty(service, key as CFString)).map { "\($0)" } ?? "-"
        }
        return [value(kIOHIDVendorIDKey), value(kIOHIDProductIDKey), value(kIOHIDSerialNumberKey)]
            .joined(separator: ":")
    }

    private let client = IOHIDEventSystemClientCreateSimpleClient(kCFAllocatorDefault)
    private var originals: [UInt64: Original] = [:]
    private var notifyPort: IONotificationPortRef?
    private var addedIterator: io_iterator_t = 0
    /// Re-applied when a mouse is plugged in or reconnects.
    var onDeviceAdded: (() -> Void)?

    /// Number of external mice found on the last apply (shown in Settings).
    private(set) var mouseCount = 0

    init() {
        watchDevices()
    }

    /// `speed`: multiplier on the device resolution (higher is faster). `acceleration`: macOS scale
    /// 0...3, or nil for linear (acceleration off).
    func apply(speed: Double, acceleration: Double?) {
        let mice = externalMice()
        mouseCount = mice.count
        for (id, service, key) in mice {
            if originals[id] == nil {
                let deviceKey = Self.deviceKey(service)
                var saved = Self.savedOriginals()
                let resolution: CFTypeRef?
                let acceleration: CFTypeRef?
                if let entry = saved[deviceKey] {
                    resolution = entry["resolution"] as NSNumber?
                    acceleration = entry["acceleration"] as NSNumber?
                } else {
                    resolution = IOHIDServiceClientCopyProperty(service, "HIDPointerResolution" as CFString)
                    // No value on the service: take the user's System Settings curve, so a restore puts
                    // back what they chose rather than leaving ours.
                    acceleration =
                        IOHIDServiceClientCopyProperty(service, key as CFString) ?? Self.systemAcceleration()
                    var entry: [String: NSNumber] = [:]
                    if let value = resolution as? NSNumber { entry["resolution"] = value }
                    if let value = acceleration as? NSNumber { entry["acceleration"] = value }
                    saved[deviceKey] = entry
                    UserDefaults.standard.set(saved, forKey: Self.savedKey)
                }
                originals[id] = Original(
                    service: service, accelerationKey: key, resolution: resolution, acceleration: acceleration,
                    deviceKey: deviceKey)
            }
            // Without a known resolution there is nothing to restore later, so speed is left alone.
            if let base = (originals[id]?.resolution as? NSNumber).map({ $0.doubleValue / 65_536 }) {
                let resolution = min(max(base / max(speed, 0.1), 10), 1995)
                set(service, "HIDPointerResolution", Int(resolution * 65_536))
            }
            let accel = acceleration.map { Int(min(max($0, 0), 3) * 65_536) } ?? -65_536
            set(service, key, accel)
        }
    }

    /// Puts back every value we changed.
    func restore() {
        var saved = Self.savedOriginals()
        for original in originals.values {
            saved[original.deviceKey] = nil
            if let resolution = original.resolution {
                IOHIDServiceClientSetProperty(original.service, "HIDPointerResolution" as CFString, resolution)
            }
            if let acceleration = original.acceleration {
                IOHIDServiceClientSetProperty(
                    original.service, original.accelerationKey as CFString, acceleration)
            }
        }
        originals.removeAll()
        if saved.isEmpty {
            UserDefaults.standard.removeObject(forKey: Self.savedKey)
        } else {
            UserDefaults.standard.set(saved, forKey: Self.savedKey)
        }
    }

    /// Launch with Cursor off after a crash while it was on: put the saved device values back.
    func restoreLeftovers() {
        var saved = Self.savedOriginals()
        guard !saved.isEmpty else { return }
        for (_, service, key) in externalMice() {
            let deviceKey = Self.deviceKey(service)
            guard let entry = saved[deviceKey] else { continue }
            if let resolution = entry["resolution"] {
                IOHIDServiceClientSetProperty(service, "HIDPointerResolution" as CFString, resolution)
            }
            if let acceleration = entry["acceleration"] {
                IOHIDServiceClientSetProperty(service, key as CFString, acceleration)
            }
            saved[deviceKey] = nil
        }
        if saved.isEmpty {
            UserDefaults.standard.removeObject(forKey: Self.savedKey)
        } else {
            UserDefaults.standard.set(saved, forKey: Self.savedKey)
        }
    }

    func countMice() -> Int {
        mouseCount = externalMice().count
        return mouseCount
    }

    private func set(_ service: IOHIDServiceClient, _ key: String, _ value: Int) {
        IOHIDServiceClientSetProperty(service, key as CFString, NSNumber(value: value))
    }

    /// Mouse services whose acceleration type is a mouse curve (trackpads report a trackpad curve).
    private func externalMice() -> [(UInt64, IOHIDServiceClient, String)] {
        let services = IOHIDEventSystemClientCopyServices(client) as? [IOHIDServiceClient] ?? []
        return services.compactMap { service in
            guard
                IOHIDServiceClientConformsTo(service, UInt32(kHIDPage_GenericDesktop), UInt32(kHIDUsage_GD_Mouse))
                    != 0
            else { return nil }
            let product = IOHIDServiceClientCopyProperty(service, kIOHIDProductKey as CFString) as? String ?? ""
            let type =
                IOHIDServiceClientCopyProperty(service, "HIDPointerAccelerationType" as CFString) as? String
            if product.localizedCaseInsensitiveContains("trackpad") { return nil }
            if let type, type.localizedCaseInsensitiveContains("trackpad") { return nil }
            guard let id = (IOHIDServiceClientGetRegistryID(service) as? NSNumber)?.uint64Value else { return nil }
            return (id, service, type ?? "HIDMouseAcceleration")
        }
    }

    // MARK: Hot plug

    private func watchDevices() {
        guard let port = IONotificationPortCreate(kIOMainPortDefault) else { return }
        notifyPort = port
        IONotificationPortSetDispatchQueue(port, .main)
        let matching = IOServiceMatching(kIOHIDDeviceKey) as NSMutableDictionary
        matching[kIOHIDDeviceUsagePageKey] = kHIDPage_GenericDesktop
        matching[kIOHIDDeviceUsageKey] = kHIDUsage_GD_Mouse
        let context = Unmanaged.passUnretained(self).toOpaque()
        let result = IOServiceAddMatchingNotification(
            port, kIOFirstMatchNotification, matching,
            { context, iterator in
                PointerController.drain(iterator)
                guard let context else { return }
                let controller = Unmanaged<PointerController>.fromOpaque(context).takeUnretainedValue()
                MainActor.assumeIsolated {
                    // The HID service appears a moment after the device.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                        MainActor.assumeIsolated { controller.onDeviceAdded?() }
                    }
                }
            }, context, &addedIterator)
        if result == KERN_SUCCESS { Self.drain(addedIterator) }
    }

    nonisolated private static func drain(_ iterator: io_iterator_t) {
        while case let object = IOIteratorNext(iterator), object != 0 { IOObjectRelease(object) }
    }
}
