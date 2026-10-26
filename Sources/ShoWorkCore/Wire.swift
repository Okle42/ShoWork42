import Foundation
import Darwin

/// One line of JSON over the agent's Unix socket.
public struct WireMessage: Codable, Sendable, Equatable {
    public var v: Int = 1
    public var event: WorkEvent
    public var tty: String          // "/dev/ttys009" — the tab the AI runs in
    public var agent: String        // "claude", "codex", "gemini", "generic"
    public var pid: Int32           // the AI process (for liveness checks)

    public init(event: WorkEvent, tty: String, agent: String, pid: Int32) {
        self.event = event; self.tty = tty; self.agent = agent; self.pid = pid
    }

    public func encodedLine() throws -> Data {
        var d = try JSONEncoder().encode(self)
        d.append(0x0A)
        return d
    }

    public static func decode(line: Data) -> WireMessage? {
        guard let m = try? JSONDecoder().decode(WireMessage.self, from: line), m.v == 1 else { return nil }
        guard m.tty.hasPrefix("/dev/tty") else { return nil }      // never trust a path that isn't a tty
        return m
    }
}

public enum Paths {
    public static var supportDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/ShoWork42", isDirectory: true)
    }
    public static var socket: URL {
        if let s = ProcessInfo.processInfo.environment["SHOWORK_SOCKET"] { return URL(fileURLWithPath: s) }
        return supportDir.appendingPathComponent("agent.sock")
    }
}

/// Finds the controlling terminal of the AI that spawned us. Hooks run with stdin/stdout
/// redirected, so we walk up the parent chain until a process owns a tty.
public enum TTYFinder {
    public struct Found: Equatable, Sendable {
        public let tty: String; public let pid: Int32
        public init(tty: String, pid: Int32) { self.tty = tty; self.pid = pid }
    }

    public static func find(startingAt pid: Int32 = getppid(), maxHops: Int = 12) -> Found? {
        var p = pid
        for _ in 0..<maxHops {
            guard p > 1, let info = kinfo(p) else { return nil }
            let dev = info.kp_eproc.e_tdev
            if dev != UInt32(bitPattern: -1), dev != 0, let name = devname(dev_t(dev), S_IFCHR) {
                return Found(tty: "/dev/" + String(cString: name), pid: p)
            }
            p = info.kp_eproc.e_ppid
        }
        return nil
    }

    static func kinfo(_ pid: Int32) -> kinfo_proc? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        return info
    }
}
