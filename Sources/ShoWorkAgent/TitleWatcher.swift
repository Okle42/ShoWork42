import AppKit
import ShoWorkCore

/// Fallback for AI sessions that send no hook events (09-26: a Claude started before ShoWork42 was
/// installed never loaded the hooks, so its window stayed dark while it worked). Every 2 s it reads all
/// Ghostty tab titles in ONE AppleScript call and turns Claude's spinner/sparkle into working/done.
/// Tabs that ever sent a real hook event are left to the hooks.
@MainActor
final class TitleWatcher {
    private weak var engine: Engine?
    private var timer: Timer?
    private var last: [String: TitleSignal] = [:]          // Ghostty terminal id → last signal
    private var ttyOf: [String: String] = [:]               // Ghostty terminal id → tty (from a full probe)
    private var lastProbe = Date.distantPast

    init(engine: Engine) { self.engine = engine }

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    private func tick() {
        guard let engine, let ghostty = NSRunningApplication.runningApplications(withBundleIdentifier: TerminalApp.ghostty.rawValue).first
        else { return }
        guard let out = Script.string("""
            tell application id "com.mitchellh.ghostty"
              set o to ""
              repeat with t in terminals
                set o to o & (id of t) & (character id 9) & (name of t) & (character id 10)
              end repeat
              return o
            end tell
            """) else { return }
        var seen = Set<String>()
        var needProbe = false
        for line in out.split(separator: "\n") {
            let cols = line.split(separator: "\t", maxSplits: 1).map(String.init)
            guard cols.count == 2 else { continue }
            let (tid, title) = (cols[0], cols[1])
            seen.insert(tid)
            let sig = TitleSignal.classify(title)
            // don't remember a signal for a tab we can't place yet — otherwise its first busy edge is
            // consumed before the probe maps it, and it never lights purple (09-26 test)
            guard sig == .unknown || ttyOf[tid] != nil else { needProbe = true; continue }
            let old = last[tid] ?? .unknown
            last[tid] = sig
            guard sig != .unknown, let tty = ttyOf[tid] else { continue }
            if engine.hookTTYs.contains(tty) { continue }          // hooks are authoritative for this tab
            guard let ev = TitleSignal.event(from: old, to: sig) else { continue }
            let pid = ProcTree.foregroundLeader(on: tty) ?? 0
            engine.handle(WireMessage(event: ev, tty: tty, agent: "claude-title", pid: pid))
        }
        for k in last.keys where !seen.contains(k) { last[k] = nil; ttyOf[k] = nil }
        // map terminal ids → ttys (probe writes OSC 7 to every tab for ~0.2 s) — at most once a minute
        if needProbe, Date().timeIntervalSince(lastProbe) > 60 {
            lastProbe = Date()
            for (tty, tid) in GhosttyProbe.terminalIDs(ghosttyPID: ghostty.processIdentifier) { ttyOf[tid] = tty }
            Log.note("TITLE map \(ttyOf.count) Ghostty tabs")
        }
    }
}
