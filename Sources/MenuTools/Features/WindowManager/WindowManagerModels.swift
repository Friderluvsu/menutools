import Foundation

public enum QuitOnCloseMode: String, CaseIterable, Identifiable, Codable, Sendable {
    case lastWindow = "Last window only"
    case always = "Always quit"

    public var id: String { rawValue }
}

public struct WindowExceptionApp: Identifiable, Hashable, Codable, Sendable {
    public var id: String  // bundle identifier
    public var name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }

    public init(bundleId: String, name: String) {
        self.id = bundleId
        self.name = name
    }

    public var bundleIdentifier: String {
        id
    }
}
