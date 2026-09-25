// showork — the tiny command every adapter calls.
//   showork emit <working|done|input|clear> [--agent claude] [--tty /dev/ttysNNN]
//
// Contract with the AI tools that call us (hooks): this must NEVER slow them down or fail them.
//   • always exits 0, prints nothing on success
//   • gives up after 200 ms if the agent isn't there
//   • never reads stdin (hook JSON may be large; we don't need it)
import Foundation
import Darwin
import ShoWorkCore

func usage() -> Never {
    FileHandle.standardError.write(Data("usage: showork emit <working|done|input|clear> [--agent NAME] [--tty PATH]\n".utf8))
    exit(0)
}

var args = Array(CommandLine.arguments.dropFirst())
guard args.first == "emit", args.count >= 2, let event = WorkEvent(rawValue: args[1]) else { usage() }
args.removeFirst(2)

var agent = "generic"
var ttyOverride: String?
while let a = args.first {
    args.removeFirst()
    switch a {
    case "--agent": agent = args.first ?? agent; if !args.isEmpty { args.removeFirst() }
    case "--tty": ttyOverride = args.first; if !args.isEmpty { args.removeFirst() }
    default: break
    }
}

let found = ttyOverride.map { TTYFinder.Found(tty: $0, pid: getppid()) } ?? TTYFinder.find()
guard let found else { exit(0) }                       // not in a terminal: nothing to light up
guard let line = try? WireMessage(event: event, tty: found.tty, agent: agent, pid: found.pid).encodedLine() else { exit(0) }

// Unix socket, non-blocking connect with a hard deadline.
let fd = socket(AF_UNIX, SOCK_STREAM, 0)
guard fd >= 0 else { exit(0) }
var on: Int32 = 1
setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
_ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)

var addr = sockaddr_un()
addr.sun_family = sa_family_t(AF_UNIX)
let path = Paths.socket.path
guard path.utf8.count < MemoryLayout.size(ofValue: addr.sun_path) else { exit(0) }
withUnsafeMutableBytes(of: &addr.sun_path) { buf in
    path.utf8.enumerated().forEach { buf[$0.offset] = $0.element }
}
let rc = withUnsafePointer(to: &addr) {
    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
}
if rc != 0 {
    guard errno == EINPROGRESS else { close(fd); exit(0) }    // no agent running: fine
    var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
    guard poll(&pfd, 1, 200) == 1 else { close(fd); exit(0) }
}
line.withUnsafeBytes { _ = write(fd, $0.baseAddress, line.count) }
close(fd)
exit(0)
