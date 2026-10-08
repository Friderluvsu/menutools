import Foundation

enum Shell {
    @discardableResult
    static func run(_ command: String, environment: [String: String]? = nil) -> (output: String, exitCode: Int32) {
        let process = Process()
        let pipe = Pipe()

        process.standardOutput = pipe
        process.standardError = pipe
        process.arguments = ["-c", command]
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")

        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:" + (env["PATH"] ?? "")
        if let customEnv = environment {
            for (key, value) in customEnv {
                env[key] = value
            }
        }
        process.environment = env

        do {
            try process.run()
            process.waitUntilExit()

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""
            return (output.trimmingCharacters(in: .whitespacesAndNewlines), process.terminationStatus)
        } catch {
            return (error.localizedDescription, -1)
        }
    }

    /// Runs a binary directly with an argument vector (no shell, so arguments are never interpreted).
    /// Output is discarded: chatty tools like ffmpeg could otherwise fill an unread pipe and hang.
    @discardableResult
    static func run(executable: String, arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        } catch {
            return -1
        }
    }

    @discardableResult
    static func runPrivileged(_ command: String) -> (output: String, exitCode: Int32) {
        // Try non-interactive sudo first
        let direct = run("sudo -n \(command)")
        if direct.exitCode == 0 {
            return direct
        }

        // Fallback to AppleScript with administrator privileges
        let escaped = command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let script = "do shell script \"\(escaped)\" with administrator privileges"
        var errorDict: NSDictionary?
        if let appleScript = NSAppleScript(source: script) {
            let result = appleScript.executeAndReturnError(&errorDict)
            if let err = errorDict {
                let msg = err[NSAppleScript.errorMessage] as? String ?? "Authorization failed"
                return (msg, 1)
            }
            return (result.stringValue ?? "", 0)
        }
        return ("Failed to execute privileged command", 1)
    }

    @discardableResult
    static func runAsync(_ command: String, completion: @Sendable @escaping (String, Int32) -> Void) -> Process? {
        let process = Process()
        let pipe = Pipe()

        process.standardOutput = pipe
        process.standardError = pipe
        process.arguments = ["-c", command]
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")

        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:" + (env["PATH"] ?? "")
        process.environment = env

        process.terminationHandler = { proc in
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""
            DispatchQueue.main.async {
                completion(output.trimmingCharacters(in: .whitespacesAndNewlines), proc.terminationStatus)
            }
        }

        do {
            try process.run()
            return process
        } catch {
            DispatchQueue.main.async {
                completion(error.localizedDescription, -1)
            }
            return nil
        }
    }

    static func which(_ tool: String) -> String? {
        let commonPaths = [
            "/opt/homebrew/bin/\(tool)",
            "/usr/local/bin/\(tool)",
            "/usr/bin/\(tool)",
            "/bin/\(tool)",
        ]
        for path in commonPaths {
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }
        let result = run("which \(tool)")
        if result.exitCode == 0, !result.output.isEmpty, FileManager.default.isExecutableFile(atPath: result.output) {
            return result.output
        }
        return nil
    }

    @discardableResult
    static func runDetached(executable: String, arguments: [String], logPath: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        FileManager.default.createFile(atPath: logPath, contents: nil)
        guard let logHandle = FileHandle(forWritingAtPath: logPath) else { return false }
        process.standardOutput = logHandle
        process.standardError = logHandle

        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:" + (env["PATH"] ?? "")
        process.environment = env

        do {
            try process.run()
            return true
        } catch {
            try? logHandle.write(contentsOf: Data(error.localizedDescription.utf8))
            try? logHandle.close()
            return false
        }
    }
}
