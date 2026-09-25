import Foundation
import Darwin
import ShoWorkCore

/// Unix-socket listener. One JSON line per connection (showork connects, writes, closes).
final class Server: @unchecked Sendable {
    private var listenFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private let queue = DispatchQueue(label: "showork.server")
    private let onMessage: @Sendable (WireMessage) -> Void

    init(onMessage: @escaping @Sendable (WireMessage) -> Void) { self.onMessage = onMessage }

    func start() throws {
        let url = Paths.socket
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        unlink(url.path)                                            // stale socket from a crash
        listenFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listenFD >= 0 else { throw POSIXError(.EIO) }
        var addr = sockaddr_un(); addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &addr.sun_path) { b in url.path.utf8.enumerated().forEach { b[$0.offset] = $0.element } }
        let rc = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listenFD, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        guard rc == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        chmod(url.path, 0o600)                                      // only this user may talk to us
        listen(listenFD, 64)
        _ = fcntl(listenFD, F_SETFL, fcntl(listenFD, F_GETFL) | O_NONBLOCK)
        let src = DispatchSource.makeReadSource(fileDescriptor: listenFD, queue: queue)
        src.setEventHandler { [weak self] in self?.acceptAll() }
        src.resume()
        acceptSource = src
    }

    private func acceptAll() {
        while true {
            let fd = accept(listenFD, nil, nil)
            guard fd >= 0 else { return }
            // same-user check (belt and braces on top of the 0600 socket)
            var uid: uid_t = 0, gid: gid_t = 0
            guard getpeereid(fd, &uid, &gid) == 0, uid == getuid() else { close(fd); continue }
            var tv = timeval(tv_sec: 0, tv_usec: 300_000)
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
            var data = Data(); var buf = [UInt8](repeating: 0, count: 4096)
            while data.count < 64 * 1024 {
                let n = read(fd, &buf, buf.count)
                if n <= 0 { break }
                data.append(buf, count: n)
                if buf[n - 1] == 0x0A { break }
            }
            close(fd)
            for line in data.split(separator: 0x0A) {
                if let m = WireMessage.decode(line: Data(line)) { onMessage(m) }
            }
        }
    }
}
