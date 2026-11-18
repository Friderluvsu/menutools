import AppKit
import Foundation

/// Shows the Terax pane a session runs in. Each running Terax publishes a control descriptor
/// (`~/Library/Caches/terax*/control.json`, readable only by this user: loopback address, token and
/// its own pid). The Terax among the session's parents is found by that pid, brought forward, and
/// asked over its control socket (`pane.reveal`) to switch to the pane and highlight it.
enum TeraxReveal {
    struct Descriptor: Decodable, Equatable {
        let version: Int
        let address: String
        let token: String
        let pid: Int32

        enum CodingKeys: String, CodingKey {
            case version = "protocol"
            case address, token, pid
        }

        /// Only a loopback IPv4 port, as Terax binds it.
        var port: UInt16? {
            guard address.hasPrefix("127.0.0.1:") else { return nil }
            return UInt16(address.dropFirst("127.0.0.1:".count))
        }

        var isUsable: Bool {
            version == 1 && port != nil && token.count == 64 && token.allSatisfy(\.isHexDigit)
        }
    }

    private static let maxDepth = 16
    private static let maxDescriptorBytes = 16 * 1024
    private static let maxReplyBytes = 64 * 1024

    /// MenuTools' session states, as Terax's highlight tells them apart.
    enum State: String {
        case input, running, done, idle
    }

    /// True when the session runs in a Terax: that Terax was activated and asked for the pane.
    /// Anything else leaves the caller to bring the owning app forward its usual way.
    @discardableResult
    static func reveal(pid: pid_t, state: State?) -> Bool {
        let descriptors = loadDescriptors()
        guard let descriptor = owner(of: pid, among: descriptors) else {
            trace("pid \(pid): no Terax among parents (descriptors: \(descriptors.map(\.pid)))")
            return false
        }
        guard let request = requestLine(pid: pid, state: state, token: descriptor.token),
            let port = descriptor.port
        else {
            trace("pid \(pid): could not build request")
            return false
        }
        NSRunningApplication(processIdentifier: descriptor.pid)?.activate(from: .current)
        let label = "pid \(pid) state \(state?.rawValue ?? "-") -> Terax \(descriptor.pid)"
        DispatchQueue.global(qos: .userInitiated).async {
            trace("\(label): \(send(request, port: port) ?? "no reply")")
        }
        return true
    }

    private static let traceLock = NSLock()

    /// `~/Library/Logs/MenuTools/terax-reveal.log`, kept under 64 KiB. Replies carry no token.
    static func trace(_ line: String) {
        traceLock.lock()
        defer { traceLock.unlock() }
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/MenuTools")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("terax-reveal.log")
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        if size > 64 * 1024 { try? FileManager.default.removeItem(at: url) }
        let entry = Data("\(ISO8601DateFormatter().string(from: Date())) \(line)\n".utf8)
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(entry)
            try? handle.close()
        } else {
            try? entry.write(to: url)
        }
    }

    /// The descriptor of the Terax whose process is one of this pid's parents.
    static func owner(
        of pid: pid_t, among descriptors: [Descriptor], parent: (pid_t) -> pid_t? = ProcessLookup.parentPid
    ) -> Descriptor? {
        var current = pid
        for _ in 0..<maxDepth {
            guard let next = parent(current), next != current else { return nil }
            if let match = descriptors.first(where: { $0.pid == next }) { return match }
            current = next
        }
        return nil
    }

    static func loadDescriptors() -> [Descriptor] {
        guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            return []
        }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: caches.path)) ?? []
        return names.filter { $0 == "terax" || $0.hasPrefix("terax-") }.compactMap { name in
            let url = caches.appendingPathComponent(name, isDirectory: true).appendingPathComponent("control.json")
            guard let data = try? Data(contentsOf: url), data.count <= maxDescriptorBytes,
                let descriptor = try? JSONDecoder().decode(Descriptor.self, from: data), descriptor.isUsable
            else { return nil }
            return descriptor
        }
    }

    static func requestLine(pid: pid_t, state: State?, token: String) -> Data? {
        var params: [String: Any] = ["pid": Int(pid)]
        if let state { params["state"] = state.rawValue }
        let request: [String: Any] = [
            "protocol": 1,
            "id": "menutools-\(UUID().uuidString)",
            "token": token,
            "method": "pane.reveal",
            "params": params,
        ]
        guard var line = try? JSONSerialization.data(withJSONObject: request) else { return nil }
        line.append(0x0A)
        return line
    }

    /// One request line to Terax's loopback control port; returns its reply line.
    static func send(_ line: Data, port: UInt16) -> String? {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var timeout = timeval(tv_sec: 7, tv_usec: 0)
        let timeoutSize = socklen_t(MemoryLayout<timeval>.size)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, timeoutSize)
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, timeoutSize)
        var noSigpipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigpipe, socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connected == 0 else { return nil }

        let written = line.withUnsafeBytes { buffer -> Bool in
            var offset = 0
            while offset < buffer.count {
                let n = write(fd, buffer.baseAddress! + offset, buffer.count - offset)
                if n <= 0 { return false }
                offset += n
            }
            return true
        }
        guard written else { return nil }

        var reply = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while reply.count < maxReplyBytes {
            let n = read(fd, &chunk, chunk.count)
            if n <= 0 { break }
            reply.append(contentsOf: chunk[0..<n])
            if chunk[0..<n].contains(0x0A) { break }
        }
        return String(data: reply, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `--terax-reveal-diagnose <pid> [state]`: which Terax owns the pid, and Terax's reply.
    static func diagnose(arguments: [String]) -> [String] {
        guard let index = arguments.firstIndex(of: "--terax-reveal-diagnose"),
            index + 1 < arguments.count, let pid = pid_t(arguments[index + 1])
        else { return ["usage: --terax-reveal-diagnose <pid> [input|running|done|idle]"] }
        let state = index + 2 < arguments.count ? State(rawValue: arguments[index + 2]) : nil
        let descriptors = loadDescriptors()
        var lines = ["descriptors: \(descriptors.map { "pid \($0.pid) \($0.address)" })"]
        guard let descriptor = owner(of: pid, among: descriptors) else {
            lines.append("owner: none (pid \(pid) does not run under a Terax)")
            return lines
        }
        lines.append("owner: Terax pid \(descriptor.pid)")
        guard let request = requestLine(pid: pid, state: state, token: descriptor.token),
            let port = descriptor.port
        else { return lines + ["request: FAIL"] }
        NSRunningApplication(processIdentifier: descriptor.pid)?.activate(from: .current)
        lines.append("reply: \(send(request, port: port) ?? "none")")
        return lines
    }
}
