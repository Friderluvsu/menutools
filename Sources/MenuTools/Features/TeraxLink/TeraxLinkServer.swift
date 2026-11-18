import Darwin
import Foundation

/// Unix socket for the Terax link. Only this user can connect: the socket is 0600 inside the user's
/// own Application Support folder and every peer's uid is checked. One request line and one reply
/// line per connection. Idle cost is one listening descriptor watched by a dispatch source.
final class TeraxLinkServer: @unchecked Sendable {
    enum StartError: Error, Equatable {
        case pathTooLong
        case inUse
        case system(String, Int32)
    }

    static let maxConnections = 8
    static let ioTimeoutSeconds = 3

    static var defaultPath: String {
        let base =
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("MenuTools/terax.sock").path
    }

    private let path: String
    private let handler: @Sendable (Data) async -> Data
    private let queue = DispatchQueue(label: "com.frider.MenuTools.terax-link")
    private let lock = NSLock()
    private var active = 0
    private var source: DispatchSourceRead?
    private var boundInode: ino_t?

    init(path: String = TeraxLinkServer.defaultPath, handler: @escaping @Sendable (Data) async -> Data) {
        self.path = path
        self.handler = handler
    }

    func start() throws {
        guard source == nil else { return }
        let directory = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(
            atPath: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        // A second MenuTools (a dev build beside the installed one) must not take the socket away.
        if Self.isServing(path) { throw StartError.inUse }
        unlink(path)

        var address = sockaddr_un()
        let pathBytes = Array(path.utf8)
        guard pathBytes.count < MemoryLayout.size(ofValue: address.sun_path) else { throw StartError.pathTooLong }
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: pathBytes)
            raw[pathBytes.count] = 0
        }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw StartError.system("socket", errno) }
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0 else {
            let code = errno
            close(fd)
            throw StartError.system("bind", code)
        }
        chmod(path, 0o600)
        guard listen(fd, 8) == 0 else {
            let code = errno
            close(fd)
            unlink(path)
            throw StartError.system("listen", code)
        }
        var info = stat()
        if stat(path, &info) == 0 { boundInode = info.st_ino }

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptPending(fd) }
        source.setCancelHandler { close(fd) }
        source.resume()
        self.source = source
    }

    func stop() {
        guard let source else { return }
        source.cancel()
        self.source = nil
        // Remove the socket only if it is still ours, not one a newer instance created.
        var info = stat()
        if let boundInode, stat(path, &info) == 0, info.st_ino == boundInode { unlink(path) }
        boundInode = nil
    }

    static func isServing(_ path: String) -> Bool {
        var address = sockaddr_un()
        let pathBytes = Array(path.utf8)
        guard pathBytes.count < MemoryLayout.size(ofValue: address.sun_path) else { return false }
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: pathBytes)
            raw[pathBytes.count] = 0
        }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        return connected == 0
    }

    private func acceptPending(_ listener: Int32) {
        while true {
            let client = accept(listener, nil, nil)
            guard client >= 0 else { return }
            guard Self.peerIsThisUser(client), claimSlot() else {
                close(client)
                continue
            }
            Self.configure(client)
            DispatchQueue.global(qos: .userInitiated).async { [self] in serve(client) }
        }
    }

    private func serve(_ client: Int32) {
        switch Self.readLine(client) {
        case .closed:
            finish(client)
        case .tooLarge:
            Self.writeAll(client, TeraxLinkProtocol.failure(.invalid("request too large")))
            finish(client)
        case .line(let line):
            let handler = self.handler
            Task {
                let reply = await handler(line)
                // The blocking write stays off the cooperative pool.
                DispatchQueue.global(qos: .userInitiated).async { [self] in
                    Self.writeAll(client, reply)
                    finish(client)
                }
            }
        }
    }

    private func finish(_ client: Int32) {
        close(client)
        lock.lock()
        active -= 1
        lock.unlock()
    }

    private func claimSlot() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard active < Self.maxConnections else { return false }
        active += 1
        return true
    }

    private static func peerIsThisUser(_ fd: Int32) -> Bool {
        var uid: uid_t = 0
        var gid: gid_t = 0
        return getpeereid(fd, &uid, &gid) == 0 && uid == getuid()
    }

    private static func configure(_ fd: Int32) {
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) & ~O_NONBLOCK)
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        var timeout = timeval(tv_sec: ioTimeoutSeconds, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    }

    enum ReadResult: Equatable {
        case line(Data)
        case tooLarge
        case closed
    }

    /// A request must arrive whole within this long; the per-read timeout alone would let a client
    /// trickling bytes hold a connection slot for hours.
    nonisolated static let requestDeadline: TimeInterval = 5

    /// Reads up to the first newline, at most `maxRequestBytes`. A timeout, the deadline, or a closed
    /// peer without a newline yields `.closed`.
    static func readLine(_ fd: Int32) -> ReadResult {
        var collected = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        let deadline = Date().addingTimeInterval(requestDeadline)
        while collected.count <= TeraxLinkProtocol.maxRequestBytes {
            let count = read(fd, &buffer, buffer.count)
            guard count > 0, Date() < deadline else { return .closed }
            if let newline = buffer[0..<count].firstIndex(of: 0x0A) {
                collected.append(contentsOf: buffer[0..<newline])
                return collected.count <= TeraxLinkProtocol.maxRequestBytes ? .line(collected) : .tooLarge
            }
            collected.append(contentsOf: buffer[0..<count])
        }
        return .tooLarge
    }

    static func writeAll(_ fd: Int32, _ data: Data) {
        data.withUnsafeBytes { raw in
            guard var pointer = raw.baseAddress else { return }
            var left = raw.count
            while left > 0 {
                let written = write(fd, pointer, left)
                guard written > 0 else { return }
                pointer += written
                left -= written
            }
        }
    }
}
