import Foundation

/// `--terax-link-diagnose`: runs the link on a temporary socket with preview state and checks the
/// replies a client gets. Validation only; no action is performed, so power settings never change.
@MainActor
enum TeraxLinkDiagnose {
    static func run() -> Bool {
        let path = NSTemporaryDirectory() + "menutools-link-\(getpid()).sock"
        let app = AppState(previewMode: true)
        let service = TeraxLinkService(app: app)
        let server = TeraxLinkServer(path: path) { line in await service.handle(line) }
        do {
            try server.start()
        } catch {
            print("start: FAIL \(error)")
            return false
        }

        let idle = RestModeManager.secondsSinceLocalInput()
        let idleReadable = idle.isFinite && idle >= 0
        print("local input idle time readable: \(idleReadable ? "ok" : "FAIL") (\(Int(idle)) s)")
        var info = stat()
        let privateMode = stat(path, &info) == 0 && info.st_mode & 0o777 == 0o600
        print("socket mode 0600: \(privateMode ? "ok" : "FAIL")")
        var passed = true
        var finished = false
        Task.detached {
            let checks: [(String, Data, (String) -> Bool)] = [
                (
                    "status", Data(#"{"method":"status"}"#.utf8),
                    { $0.contains(#""ok":true"#) && $0.contains(#""version":1"#) && $0.contains(#""power""#) }
                ),
                (
                    "refresh", Data(#"{"method":"status","params":{"refresh":true}}"#.utf8),
                    { $0.contains(#""refreshed":true"#) && $0.contains(#""updatedAt""#) }
                ),
                ("malformed", Data("not json".utf8), { $0.contains("invalid request") }),
                ("unknown method", Data(#"{"method":"shell"}"#.utf8), { $0.contains("unknown method") }),
                (
                    "unknown action", Data(#"{"method":"action","params":{"name":"reboot","on":true}}"#.utf8),
                    { $0.contains("unknown action") }
                ),
                (
                    "bad duration", Data(#"{"method":"action","params":{"name":"awake","on":true,"minutes":7}}"#.utf8),
                    { $0.contains("unsupported duration") }
                ),
                (
                    "missing on", Data(#"{"method":"action","params":{"name":"rest"}}"#.utf8),
                    { $0.contains("missing on") }
                ),
                (
                    "alarm start refused", Data(#"{"method":"action","params":{"name":"alarm","on":true}}"#.utf8),
                    { $0.contains("alarm can only be stopped") }
                ),
                (
                    "sleep when done", Data(#"{"method":"action","params":{"name":"sleepWhenDone","on":true}}"#.utf8),
                    { $0.contains(#""afterDone":{"#) && $0.contains(#""sleep":true"#) }
                ),
                (
                    "sleep when done off",
                    Data(#"{"method":"action","params":{"name":"sleepWhenDone","on":false}}"#.utf8),
                    { $0.contains(#""sleep":false"#) }
                ),
                (
                    "pane focused", Data(#"{"method":"action","params":{"name":"paneFocused","pid":999999}}"#.utf8),
                    { $0.contains(#""ok":true"#) }
                ),
                (
                    "pane focused without pid", Data(#"{"method":"action","params":{"name":"paneFocused"}}"#.utf8),
                    { $0.contains("missing pid") }
                ),
                (
                    "too large", Data(repeating: 0x20, count: TeraxLinkProtocol.maxRequestBytes + 10),
                    { $0.contains("request too large") }
                ),
            ]
            var allPassed = true
            for (name, body, expect) in checks {
                let reply = Self.request(path, body)
                let ok = reply.map(expect) ?? false
                allPassed = allPassed && ok
                print("\(name): \(ok ? "ok" : "FAIL") \(reply.map { String($0.prefix(120)) } ?? "no reply")")
            }
            let busy = TeraxLinkServer.isServing(path)
            print("second instance refused: \(busy ? "ok" : "FAIL")")
            let result = allPassed && busy
            await MainActor.run {
                passed = result
                finished = true
            }
        }
        while !finished { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        server.stop()
        let removed = !FileManager.default.fileExists(atPath: path)
        print("socket removed on stop: \(removed ? "ok" : "FAIL")")
        return passed && removed && privateMode && idleReadable
    }

    nonisolated private static func request(_ path: String, _ body: Data) -> String? {
        var address = sockaddr_un()
        let bytes = Array(path.utf8)
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else { return nil }
        var payload = body
        payload.append(0x0A)
        TeraxLinkServer.writeAll(fd, payload)
        var reply = Data()
        var buffer = [UInt8](repeating: 0, count: 65536)
        while true {
            let count = read(fd, &buffer, buffer.count)
            guard count > 0 else { break }
            reply.append(contentsOf: buffer[0..<count])
        }
        return String(data: reply, encoding: .utf8)
    }
}
