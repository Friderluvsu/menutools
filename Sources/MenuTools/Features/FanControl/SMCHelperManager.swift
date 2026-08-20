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
        let fm = FileManager.default
        guard fm.fileExists(atPath: Self.installedHelperPath) else {
            self.isHelperInstalled = false
            return
        }
        
        do {
            let attrs = try fm.attributesOfItem(atPath: Self.installedHelperPath)
            let posixPerms = (attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0
            let ownerID = (attrs[.ownerAccountID] as? NSNumber)?.intValue ?? -1
            
            // Needs to be owned by root (UID 0) and have setuid (04000) or executable permissions
            let isSetuidRoot = (ownerID == 0) && ((posixPerms & 0o4000) != 0)
            self.isHelperInstalled = isSetuidRoot || (ownerID == 0 && (posixPerms & 0o111) != 0)
        } catch {
            self.isHelperInstalled = false
        }
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
}
