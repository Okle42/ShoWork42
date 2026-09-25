import Foundation
import Darwin

/// Who draws a tty on screen: a terminal app directly, or a tmux server (then look at its clients).
enum TTYHost: Equatable {
    case app(TerminalApp, pid_t)
    case tmux(socketPath: String)
    case unknown
}

enum ProcTree {
    static func host(of tty: String) -> TTYHost {
        guard let dev = ttyDev(tty) else { return .unknown }
        let procs = processes(onTTY: dev)
        // walk up from the session leader until we reach a terminal app or a tmux server.
        // (Not via the TMUX env var: macOS 27 hides other processes' environments — M1-2 finding.)
        guard var p = procs.map(\.pid).min() else { return .unknown }
        for _ in 0..<16 {
            if let path = exePath(p) {
                if (path as NSString).lastPathComponent == "tmux" {
                    return Tmux.socket(owningPane: tty).map { .tmux(socketPath: $0) } ?? .unknown
                }
                if path.contains("/Ghostty.app/") { return .app(.ghostty, p) }
                if path.contains("/Terminal.app/") { return .app(.terminal, p) }
                if path.contains("/iTerm.app/") { return .app(.iterm, p) }
            }
            guard let parent = kinfo(p)?.kp_eproc.e_ppid, parent > 1 else { break }
            p = parent
        }
        return .unknown
    }

    /// cwd of the foreground process group on the tty (what the shell/AI is "in").
    static func cwd(ofForegroundOn tty: String) -> String? {
        guard let dev = ttyDev(tty) else { return nil }
        let procs = processes(onTTY: dev)
        let fg = procs.first { $0.pgid == $0.tpgid } ?? procs.min { $0.pid < $1.pid }
        guard let pid = fg?.pid else { return nil }
        var vpi = proc_vnodepathinfo()
        let n = proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &vpi, Int32(MemoryLayout<proc_vnodepathinfo>.size))
        guard n > 0 else { return nil }
        return withUnsafeBytes(of: vpi.pvi_cdir.vip_path) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
    }

    /// Every tty whose processes descend from `root` (e.g. all of Ghostty's tabs).
    static func ttys(under root: pid_t) -> [String] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]   // ALL: the chain passes through root-owned `login`
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0 else { return [] }
        var buf = [kinfo_proc](repeating: kinfo_proc(), count: size / MemoryLayout<kinfo_proc>.stride + 16)
        size = buf.count * MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0 else { return [] }
        let all = buf.prefix(size / MemoryLayout<kinfo_proc>.stride)
        let parent = Dictionary(all.map { ($0.kp_proc.p_pid, $0.kp_eproc.e_ppid) }, uniquingKeysWith: { a, _ in a })
        var out = Set<String>()
        for k in all {
            let dev = k.kp_eproc.e_tdev
            guard dev != UInt32(bitPattern: -1), dev != 0, let name = devname(dev_t(dev), S_IFCHR) else { continue }
            var p = k.kp_eproc.e_ppid
            for _ in 0..<4 { if p == root { out.insert("/dev/" + String(cString: name)); break }; guard let q = parent[p] else { break }; p = q }
        }
        return out.sorted()
    }

    static func alive(_ pid: pid_t) -> Bool { kill(pid, 0) == 0 || errno == EPERM }

    // MARK: primitives

    struct Proc { let pid: pid_t; let pgid: pid_t; let tpgid: pid_t }

    static func ttyDev(_ tty: String) -> dev_t? {
        var st = stat()
        guard stat(tty, &st) == 0, (st.st_mode & S_IFMT) == S_IFCHR else { return nil }
        return st.st_rdev
    }

    static func processes(onTTY dev: dev_t) -> [Proc] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_TTY, Int32(bitPattern: UInt32(dev))]
        var size = 0
        guard sysctl(&mib, 4, nil, &size, nil, 0) == 0, size > 0 else { return [] }
        let count = size / MemoryLayout<kinfo_proc>.stride
        var buf = [kinfo_proc](repeating: kinfo_proc(), count: count + 8)
        size = buf.count * MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, 4, &buf, &size, nil, 0) == 0 else { return [] }
        return buf.prefix(size / MemoryLayout<kinfo_proc>.stride).map {
            Proc(pid: $0.kp_proc.p_pid, pgid: $0.kp_eproc.e_pgid, tpgid: $0.kp_eproc.e_tpgid)
        }
    }

    static func kinfo(_ pid: pid_t) -> kinfo_proc? {
        var info = kinfo_proc(); var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        return info
    }

    static func exePath(_ pid: pid_t) -> String? {
        var buf = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        return proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 ? String(cString: buf) : nil
    }
}

enum Tmux {
    /// Which tmux server owns this pane tty? Ask each socket in the user's tmux dir(s).
    static func socket(owningPane pane: String) -> String? {
        var dirs = ["/private/tmp/tmux-\(getuid())"]
        if let t = ProcessInfo.processInfo.environment["TMUX_TMPDIR"] { dirs.insert("\(t)/tmux-\(getuid())", at: 0) }
        for d in dirs {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: d)) ?? []
            for n in names {
                let sock = "\(d)/\(n)"
                if run(sock, ["list-panes", "-a", "-F", "#{pane_tty}"]).split(separator: "\n").contains(Substring(pane)) { return sock }
            }
        }
        return nil
    }

    /// Every client tty attached to the session that owns this pane. Detached ⇒ [] ⇒ no glow.
    static func clientTTYs(ofPaneTTY pane: String, socketPath: String) -> [String] {
        let panes = run(socketPath, ["list-panes", "-a", "-F", "#{pane_tty} #{session_name}"])
        guard let session = panes.split(separator: "\n").first(where: { $0.hasPrefix(pane + " ") })?
            .split(separator: " ", maxSplits: 1).last.map(String.init) else { return [] }
        return run(socketPath, ["list-clients", "-t", session, "-F", "#{client_tty}"])
            .split(separator: "\n").map(String.init).filter { $0.hasPrefix("/dev/tty") }
    }

    static func binary() -> String {
        for p in ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/usr/bin/tmux"] where FileManager.default.isExecutableFile(atPath: p) { return p }
        return "tmux"
    }

    private static func run(_ socket: String, _ args: [String]) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: binary())
        p.arguments = ["-S", socket] + args
        let out = Pipe(); p.standardOutput = out; p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return "" }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}
