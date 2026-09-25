import AppKit
import Darwin
import ShoWorkCore

@_silgen_name("_AXUIElementGetWindow")
private func _AXUIElementGetWindow(_ el: AXUIElement, _ wid: UnsafeMutablePointer<CGWindowID>) -> AXError

enum TerminalApp: String, Sendable {
    case ghostty = "com.mitchellh.ghostty"
    case terminal = "com.apple.Terminal"
    case iterm = "com.googlecode.iterm2"
}

/// Where a tty is shown on screen. One tmux session can be attached in several windows.
struct Placement: Hashable, Sendable {
    let app: TerminalApp
    let pid: pid_t
    let wid: CGWindowID
    /// the terminal-side tty of the tab (for tmux this is the client tty, not the pane tty)
    let tabTTY: String
}

/// tty → on-screen placement(s). M0-verified methods:
///   Terminal / iTerm2 — AppleScript window id IS the CGWindowID
///   Ghostty           — OSC 7 nonce into the tty, matched against AX `AXDocument`; cwd restored
///   tmux              — pane tty → session → every client tty → one of the above
@MainActor
final class Resolver {
    private var cache: [String: [Placement]] = [:]

    func placements(for tty: String, refresh: Bool = false) -> [Placement] {
        if !refresh, let c = cache[tty], c.allSatisfy({ WindowList.exists($0.wid) }) { return c }
        let r = resolve(tty)
        cache[tty] = r.isEmpty ? nil : r
        return r
    }

    func forget(_ tty: String) { cache[tty] = nil }

    private func resolve(_ tty: String) -> [Placement] {
        switch ProcTree.host(of: tty) {
        case .app(let app, let pid): return resolveApp(app, pid: pid, tty: tty).map { [$0] } ?? []
        case .tmux(let socketPath):
            return Tmux.clientTTYs(ofPaneTTY: tty, socketPath: socketPath).flatMap { client -> [Placement] in
                guard case .app(let app, let pid) = ProcTree.host(of: client) else { return [] }
                return resolveApp(app, pid: pid, tty: client).map { [$0] } ?? []
            }
        case .unknown: return []
        }
    }

    private func resolveApp(_ app: TerminalApp, pid: pid_t, tty: String) -> Placement? {
        let wid: CGWindowID?
        switch app {
        case .terminal:
            wid = Script.int("""
                tell application id "com.apple.Terminal"
                  repeat with w in windows
                    repeat with t in tabs of w
                      if tty of t is "\(tty)" then return id of w
                    end repeat
                  end repeat
                end tell
                """).map(CGWindowID.init)
        case .iterm:
            wid = Script.int("""
                tell application id "com.googlecode.iterm2"
                  repeat with w in windows
                    repeat with t in tabs of w
                      repeat with s in sessions of t
                        if tty of s is "\(tty)" then return id of w
                      end repeat
                    end repeat
                  end repeat
                end tell
                """).map(CGWindowID.init)
        case .ghostty:
            wid = GhosttyProbe.wid(forTTY: tty, ghosttyPID: pid)
        }
        guard let wid else { return nil }
        return Placement(app: app, pid: pid, wid: wid, tabTTY: tty)
    }
}

// MARK: - Ghostty (no titles touched)

enum GhosttyProbe {
    /// Writes a nonce cwd (OSC 7) into the tty, finds the AX window whose AXDocument shows it,
    /// then writes the real cwd back. Only the SELECTED tab of a window reports its cwd, so a
    /// background tab resolves through the AppleScript tab tree instead.
    @MainActor
    static func wid(forTTY tty: String, ghosttyPID: pid_t) -> CGWindowID? {
        let realCWD = ProcTree.cwd(ofForegroundOn: tty) ?? FileManager.default.homeDirectoryForCurrentUser.path
        let nonce = "SW42-" + String(UInt32.random(in: .min ... .max), radix: 16)
        // must be the exact system hostname: Ghostty compares case-sensitively and ignores OSC 7 from
        // "other hosts" (ProcessInfo.hostName lower-cases it — M1-2 bug)
        var hb = [CChar](repeating: 0, count: 256); gethostname(&hb, hb.count)
        let host = String(cString: hb)
        defer { TTYWrite.osc7(tty, host: host, path: realCWD) }
        guard TTYWrite.osc7(tty, host: host, path: "/tmp/\(nonce)") else { return nil }

        for _ in 0..<10 {                                     // Ghostty applies OSC 7 asynchronously
            usleep(30_000)
            if let w = AXQuery.window(ofPID: ghosttyPID, whereDocumentContains: nonce) { return w }
        }
        // background tab: find its AppleScript window, then that window's selected-tab cwd on AX
        guard let sel = Script.string("""
            tell application id "com.mitchellh.ghostty"
              repeat with w in windows
                repeat with t in terminals of w
                  if (working directory of t) contains "\(nonce)" then
                    return (working directory of focused terminal of selected tab of w) & "\\n" & (name of w)
                  end if
                end repeat
              end repeat
            end tell
            """) else { return nil }
        let parts = sel.split(separator: "\n", maxSplits: 1).map(String.init)
        if parts.count == 2, !parts[0].isEmpty,
           let w = AXQuery.window(ofPID: ghosttyPID, document: parts[0], title: parts[1]) { return w }
        // The selected tab never reported a cwd (no shell integration) or the cwd+title pair is
        // ambiguous: probe EVERY Ghostty tab at once and read the full map (M0 ⑤ method).
        return fullProbe(ghosttyPID: ghosttyPID)[tty]
    }

    /// tty → wid for every Ghostty tab: a distinct OSC 7 nonce per tty, then
    ///   AX:  window.AXDocument          → nonce of that window's selected tab → wid
    ///   AS:  window → all its terminals → every tab of the window gets that wid
    /// Every tty's real cwd is written back afterwards.
    @MainActor
    static func fullProbe(ghosttyPID: pid_t) -> [String: CGWindowID] {
        var hb = [CChar](repeating: 0, count: 256); gethostname(&hb, hb.count)
        let host = String(cString: hb)
        let ttys = ProcTree.ttys(under: ghosttyPID)
        var nonceOf: [String: String] = [:], ttyOf: [String: String] = [:]
        for t in ttys {
            let n = "SW42-" + String(UInt32.random(in: .min ... .max), radix: 16)
            if TTYWrite.osc7(t, host: host, path: "/tmp/\(n)") { nonceOf[t] = n; ttyOf[n] = t }
        }
        usleep(200_000)
        let dbg = ProcessInfo.processInfo.environment["SHOWORK_DEBUG"] != nil
        if dbg { FileHandle.standardError.write(Data("fullProbe ttys=\(ttys) nonces=\(nonceOf)\n".utf8)) }
        // selected-tab nonce → wid
        var widOfNonce: [String: CGWindowID] = [:]
        for w in AXQuery.windows(ofPID: ghosttyPID) {
            guard let d = AXQuery.string(w, "AXDocument"), let r = d.range(of: "SW42-") else { continue }
            widOfNonce[String(d[r.lowerBound...]).trimmingCharacters(in: CharacterSet(charactersIn: "/"))] = AXQuery.wid(w)
        }
        // AppleScript: one line per window, "selectedNonce<TAB>nonce nonce nonce"
        let lines = Script.string("""
            tell application id "com.mitchellh.ghostty"
              set out to ""
              repeat with w in windows
                set sel to working directory of focused terminal of selected tab of w
                set all to ""
                repeat with t in terminals of w
                  set all to all & (working directory of t) & " "
                end repeat
                set out to out & sel & (character id 9) & all & (character id 10)   -- `tab` is a Ghostty class here
              end repeat
              return out
            end tell
            """) ?? ""
        if dbg { FileHandle.standardError.write(Data("widOfNonce=\(widOfNonce)\nAS=\(lines)\n".utf8)) }
        var result: [String: CGWindowID] = [:]
        func nonce(_ path: Substring) -> String? {
            guard let r = path.range(of: "SW42-") else { return nil }
            return String(path[r.lowerBound...]).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        }
        for line in lines.split(separator: "\n") {
            let cols = line.split(separator: "\t", maxSplits: 1)
            guard cols.count == 2, let sel = nonce(cols[0]), let wid = widOfNonce[sel] else { continue }
            for p in cols[1].split(separator: " ") { if let n = nonce(p), let t = ttyOf[n] { result[t] = wid } }
        }
        // restore: OSC 7 never changes a process's real cwd, so re-read it and write it back
        for (t, _) in nonceOf { TTYWrite.osc7(t, host: host, path: ProcTree.cwd(ofForegroundOn: t) ?? FileManager.default.homeDirectoryForCurrentUser.path) }
        return result
    }
}

enum TTYWrite {
    @discardableResult
    static func osc7(_ tty: String, host: String, path: String) -> Bool {
        guard tty.hasPrefix("/dev/tty") else { return false }
        let fd = open(tty, O_WRONLY | O_NOCTTY | O_NONBLOCK)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        let enc = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
        let s = "\u{1B}]7;file://\(host)\(enc)\u{07}"
        return s.withCString { write(fd, $0, strlen($0)) } > 0
    }
}

// MARK: - AX / window list

enum AXQuery {
    static func windows(ofPID pid: pid_t) -> [AXUIElement] {
        var v: CFTypeRef?
        AXUIElementCopyAttributeValue(AXUIElementCreateApplication(pid), kAXWindowsAttribute as CFString, &v)
        return v as? [AXUIElement] ?? []
    }
    static func wid(_ w: AXUIElement) -> CGWindowID { var id: CGWindowID = 0; _ = _AXUIElementGetWindow(w, &id); return id }
    static func string(_ w: AXUIElement, _ attr: String) -> String? {
        var v: CFTypeRef?; AXUIElementCopyAttributeValue(w, attr as CFString, &v); return v as? String
    }
    static func window(ofPID pid: pid_t, whereDocumentContains needle: String) -> CGWindowID? {
        windows(ofPID: pid).first { string($0, "AXDocument")?.contains(needle) == true }.map(wid)
    }
    /// Background-tab fallback. Ambiguous (two windows, same cwd AND title) ⇒ nil, never a guess.
    static func window(ofPID pid: pid_t, document: String, title: String) -> CGWindowID? {
        let want = URL(fileURLWithPath: document).standardizedFileURL.path
        let hits = windows(ofPID: pid).filter {
            guard let d = string($0, "AXDocument"), let u = URL(string: d) else { return false }
            return u.standardizedFileURL.path == want && string($0, kAXTitleAttribute) == title
        }
        return hits.count == 1 ? wid(hits[0]) : nil
    }
    static func element(pid: pid_t, wid target: CGWindowID) -> AXUIElement? {
        windows(ofPID: pid).first { wid($0) == target }
    }
}

enum WindowList {
    static func exists(_ wid: CGWindowID) -> Bool {
        (CGWindowListCopyWindowInfo([.optionIncludingWindow], wid) as? [[String: Any]])?.isEmpty == false
    }
}

// MARK: - AppleScript

enum Script {
    @MainActor static func run(_ src: String) -> NSAppleEventDescriptor? {
        var err: NSDictionary?
        return NSAppleScript(source: src)?.executeAndReturnError(&err)
    }
    @MainActor static func int(_ src: String) -> Int? {
        guard let d = run(src) else { return nil }
        let v = Int(d.int32Value)
        return v > 0 ? v : Int(d.stringValue ?? "")
    }
    @MainActor static func string(_ src: String) -> String? { run(src)?.stringValue }
}
