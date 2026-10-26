import AppKit
import ShoWorkCore

/// Fallback for AI sessions that send no hook events (09-26: a Claude started before ShoWork42 was
/// installed never loaded the hooks, so its window stayed dark while it worked). Every 2 s it reads all
/// Ghostty tab titles in ONE Apple event and turns Claude's spinner/sparkle into working/done.
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

    /// 退避（10-24 Kang 選 B）：上一輪看到的 AI 分頁全都有 hook 回報 ⇒ 之後每 5 輪（10 秒）才讀一次標題；
    /// 有沒 hook 的分頁就照舊每 2 秒。有新 session 開出來（~/.claude/sessions 多了檔）立刻恢復讀一次
    private var skip = 0
    private var sessionFiles = Set<String>()
    static let backoffTicks = 4
    private var backingOff: Bool?

    /// 這個分頁前景是 Claude Code（有 ~/.claude/sessions/<pid>.json）⇒ 全域 hook 會回報，不用靠標題。閒著的分頁重啟後還沒發過事件，
    /// 不在 hookTTYs 裡，原本會被當成沒裝 hook、退避永遠開不起來（10-24 實測：6 個分頁 hook 只認得 1 個）。結果記 60 秒
    private var claudeCache: [String: (yes: Bool, at: Date)] = [:]
    private func claudeTTY(_ tty: String) -> Bool {
        if let c = claudeCache[tty], Date().timeIntervalSince(c.at) < 60 { return c.yes }
        let yes = ProcTree.foregroundLeader(on: tty).map { FileManager.default.fileExists(atPath: "\(BoardPaths.claude)/sessions/\($0).json") } ?? false
        claudeCache[tty] = (yes, Date())
        return yes
    }

    private func tick() {
        // 用檔名集合，不用資料夾 mtime：Claude 會一直原子改寫自己的 session 檔（改名也會動到資料夾 mtime）
        let files = Set(((try? FileManager.default.contentsOfDirectory(atPath: BoardPaths.claude + "/sessions")) ?? []).filter { $0.hasSuffix(".json") })
        if files != sessionFiles { sessionFiles = files; skip = 0 }
        if skip > 0 { skip -= 1; return }
        guard let engine, let ghostty = NSRunningApplication.runningApplications(withBundleIdentifier: TerminalApp.ghostty.rawValue).first
        else { return }
        // ONE Apple event for every id and every title (09-26: looping per terminal and concatenating in
        // AppleScript was ~80% of the agent's CPU — 0.30 s vs 0.10 s per tick with 7 tabs, same output)
        guard let out = Script.string("""
            tell application id "com.mitchellh.ghostty" to set {ids, names} to {id, name} of terminals
            set AppleScript's text item delimiters to (character id 10)
            return (ids as text) & (character id 30) & (names as text)
            """) else { return }
        let halves = out.split(separator: "\u{1E}", omittingEmptySubsequences: false)
        guard halves.count == 2 else { return }
        let ids = halves[0].split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let names = halves[1].split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard ids.count == names.count else { return }              // a title with a newline: skip this tick
        var seen = Set<String>()
        var needProbe = false
        var unhooked = false            // 有 AI 標題、卻不是 hook 回報的分頁（沒裝 hook 的舊 session）
        for (tid, title) in zip(ids, names) where !tid.isEmpty {
            seen.insert(tid)
            let sig = TitleSignal.classify(title)
            // don't remember a signal for a tab we can't place yet — otherwise its first busy edge is
            // consumed before the probe maps it, and it never lights purple (09-26 test)
            guard sig == .unknown || ttyOf[tid] != nil else { needProbe = true; unhooked = true; continue }
            if sig != .unknown, let tty = ttyOf[tid], !engine.hookTTYs.contains(tty), !claudeTTY(tty) { unhooked = true }
            let old = last[tid] ?? .unknown
            last[tid] = sig
            guard sig != .unknown, let tty = ttyOf[tid] else { continue }
            if engine.hookTTYs.contains(tty) { continue }          // hooks are authoritative for this tab
            guard let ev = TitleSignal.event(from: old, to: sig) else { continue }
            let pid = ProcTree.foregroundLeader(on: tty) ?? 0
            engine.handle(WireMessage(event: ev, tty: tty, agent: "claude-title", pid: pid))
        }
        for k in last.keys where !seen.contains(k) { last[k] = nil; ttyOf[k] = nil }
        let back = !(unhooked || needProbe)
        if back != backingOff { backingOff = back; Log.note("TITLE 退避 \(back ? "開（分頁都有 hook）" : "關")：unhooked=\(unhooked) needProbe=\(needProbe) 分頁 \(ids.count) 已對應 \(ttyOf.count) hook \(engine.hookTTYs.count)") }
        skip = back ? Self.backoffTicks : 0
        // map terminal ids → ttys (probe writes OSC 7 to every tab for ~0.2 s) — at most once a minute
        if needProbe, Date().timeIntervalSince(lastProbe) > 60 {
            lastProbe = Date()
            for (tty, tid) in GhosttyProbe.terminalIDs(ghosttyPID: ghostty.processIdentifier) { ttyOf[tid] = tty }
            Log.note("TITLE map \(ttyOf.count) Ghostty tabs")
        }
    }
}
