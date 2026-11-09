import Foundation

@MainActor
public final class SMCHelperManager: ObservableObject {
    public static let shared = SMCHelperManager()

    nonisolated public static let installedHelperPath = "/Library/Application Support/MenuTools/menutools-smc-helper"

    @Published public private(set) var isHelperInstalled: Bool = false
    @Published public private(set) var isInstalling: Bool = false
    @Published public private(set) var lastError: String?

    private init() {
        checkHelperInstalled()
    }

    public func checkHelperInstalled() {
        isHelperInstalled = Self.isHelperInstalledSync
    }

    /// Root-owned and setuid (or executable): pmset can be changed without an admin prompt.
    nonisolated public static var isHelperInstalledSync: Bool {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: installedHelperPath) else {
            return false
        }
        let posixPerms = (attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0
        let ownerID = (attrs[.ownerAccountID] as? NSNumber)?.intValue ?? -1
        return ownerID == 0 && ((posixPerms & 0o4000) != 0 || (posixPerms & 0o111) != 0)
    }

    public var bundledHelperPath: String? {
        if let path = Bundle.main.path(forResource: "menutools-smc-helper", ofType: nil, inDirectory: "bin"),
           FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        // Fallback for debug/development builds
        let devPath = Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("menutools-smc-helper").path
        if FileManager.default.isExecutableFile(atPath: devPath) {
            return devPath
        }
        return nil
    }

    public func installHelper() async -> Bool {
        guard let sourcePath = bundledHelperPath else {
            self.lastError = "Helper binary not found in app bundle"
            return false
        }

        self.isInstalling = true
        defer { self.isInstalling = false }

        let targetPath = Self.installedHelperPath
        let script = """
        do shell script "mkdir -p '/Library/Application Support/MenuTools' && cp '\(sourcePath)' '\(targetPath)' && chown root:wheel '\(targetPath)' && chmod 4755 '\(targetPath)'" with administrator privileges
        """

        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                var errorDict: NSDictionary?
                if let appleScript = NSAppleScript(source: script) {
                    _ = appleScript.executeAndReturnError(&errorDict)
                }

                Task { @MainActor in
                    self.checkHelperInstalled()
                    if let err = errorDict {
                        self.lastError = err[NSAppleScript.errorMessage] as? String ?? "Authorization failed"
                        continuation.resume(returning: false)
                    } else {
                        self.lastError = nil
                        continuation.resume(returning: self.isHelperInstalled)
                    }
                }
            }
        }
    }

    public func setFanSpeed(rpm: Int) async -> Bool {
        if !isHelperInstalled {
            let installed = await installHelper()
            guard installed else { return false }
        }

        let helperPath = Self.installedHelperPath
        return await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: helperPath)
            process.arguments = ["set", "0", "\(rpm)"]

            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe

            do {
                try process.run()
                process.waitUntilExit()
                return process.terminationStatus == 0
            } catch {
                return false
            }
        }.value
    }

    public func setAuto() async -> Bool {
        if !isHelperInstalled {
            return true
        }

        let helperPath = Self.installedHelperPath
        return await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: helperPath)
            process.arguments = ["auto", "0"]

            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe

            do {
                try process.run()
                process.waitUntilExit()
                return process.terminationStatus == 0
            } catch {
                return false
            }
        }.value
    }

    public func setLidSleep(disabled: Bool) async -> Bool {
        let useHelper = isHelperInstalled
        let val = disabled ? "1" : "0"
        // Off the main actor: the helper, sudo and the admin prompt fallback may all block.
        return await Task.detached(priority: .userInitiated) {
            Self.runPmset(setting: "disablesleep", value: val, useHelper: useHelper)
        }.value
    }

    public func setLowPowerMode(enabled: Bool) async -> Bool {
        let useHelper = isHelperInstalled
        let val = enabled ? "1" : "0"
        return await Task.detached(priority: .userInitiated) {
            Self.runPmset(setting: "lowpowermode", value: val, useHelper: useHelper)
        }.value
    }

    /// Blocking restore of system sleep for app termination, where no Task would get to run.
    nonisolated public static func restoreSleepSync() {
        let helperPath = installedHelperPath
        let useHelper = FileManager.default.isExecutableFile(atPath: helperPath)
        // Never an admin prompt here: it would hang quit and logout (the next launch restores instead).
        _ = runPmset(setting: "disablesleep", value: "0", useHelper: useHelper, allowPrompt: false)
    }

    /// Helper first, then non-interactive sudo, then the admin prompt. Blocks the calling thread.
    nonisolated private static func runPmset(
        setting: String, value: String, useHelper: Bool, allowPrompt: Bool = true
    ) -> Bool {
        if useHelper, runProcess(installedHelperPath, [setting, value]) { return true }
        if runProcess("/usr/bin/sudo", ["-n", "/usr/bin/pmset", "-a", setting, value]) { return true }
        guard allowPrompt else { return false }
        let script = "do shell script \"/usr/bin/pmset -a \(setting) \(value)\" with administrator privileges"
        var errorDict: NSDictionary?
        _ = NSAppleScript(source: script)?.executeAndReturnError(&errorDict)
        return errorDict == nil
    }

    nonisolated private static func runProcess(_ path: String, _ args: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }
}
