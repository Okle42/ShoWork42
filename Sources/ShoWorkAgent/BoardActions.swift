import AppKit
import ShoWorkCore

// 戰情中心 P2 的動作：審核員（另一個 AI）、放行／丟待辦、退回補指示（打進 tmux）、新任務（claude --bg）。
// 會動到別的東西的只有「退回」（在那個 session 的 tmux pane 打字）和「新任務」（開背景 session），都是你按了才做。

/// readAll 的解碼快取：路徑 →（mtime|大小, 解碼結果）
final class DecodeCache: @unchecked Sendable {
    static let shared = DecodeCache()
    private let lock = NSLock()
    private var m: [String: (String, Any)] = [:]
    func get(_ p: String, _ stamp: String) -> Any? { lock.lock(); defer { lock.unlock() }; return m[p].flatMap { $0.0 == stamp ? $0.1 : nil } }
    func put(_ p: String, _ stamp: String, _ v: Any) { lock.lock(); m[p] = (stamp, v); lock.unlock() }
    /// 檔案刪掉了就丟掉
    func prune(prefix: String, keep: Set<String>) {
        lock.lock(); defer { lock.unlock() }
        for k in m.keys where k.hasPrefix(prefix + "/") && !keep.contains(k) { m[k] = nil }
    }
}

/// board/ 底下每個 session 一個 JSON：cards（AI 自報）、reviews（審核）、decisions（你的決定）
enum BoardStore {
    static func dir(_ kind: String) -> URL { BoardPaths.dir.appendingPathComponent(kind, isDirectory: true) }

    static func readAll<T: Decodable>(_ kind: String, as: T.Type) -> [String: T] {
        // 每 1.5 秒讀一次、約 150 個檔：只有 mtime／大小變了才重新解碼（10-20：閒置 CPU 的大宗就是這裡）
        let d = BoardJSON.decoder
        var out: [String: T] = [:]
        let fm = FileManager.default
        var seen = Set<String>()
        // 10-21：路徑用字串接（URL.appendingPathComponent 每次都 stat 一次看是不是資料夾）、戳記用 lstat（attributesOfItem 會讀延伸屬性）
        let base = dir(kind).path
        for f in (try? fm.contentsOfDirectory(atPath: base)) ?? [] where f.hasSuffix(".json") {
            let path = base + "/" + f
            guard let stamp = FileStat.lstat(path)?.stamp else { continue }
            seen.insert(path)
            if let hit = DecodeCache.shared.get(path, stamp) as? T { out[String(f.dropLast(5))] = hit; continue }
            if let data = fm.contents(atPath: path), let v = try? d.decode(T.self, from: data) {
                out[String(f.dropLast(5))] = v
                DecodeCache.shared.put(path, stamp, v)
            }
        }
        DecodeCache.shared.prune(prefix: dir(kind).path, keep: seen)
        return out
    }

    static func write<T: Encodable>(_ kind: String, _ sid: String, _ v: T) {
        let e = BoardJSON.encoder
        try? FileManager.default.createDirectory(at: dir(kind), withIntermediateDirectories: true)
        if let d = try? e.encode(v) { try? d.write(to: dir(kind).appendingPathComponent(sid + ".json"), options: .atomic) }
    }

    static func rateLimits() -> RateLimits? {
        let path = ProcessInfo.processInfo.environment["SHOWORK_RATE_LIMITS"] ?? BoardPaths.claude + "/cache/rate_limits.json"
        return FileManager.default.contents(atPath: path).flatMap(RateLimits.parse)
    }
}

enum Tools {
    /// launchd 給的 PATH 很短，claude 要自己找
    static func claude() -> String? {
        let h = BoardPaths.home
        return [h + "/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude", h + "/.claude/local/claude"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// 跑一個指令，等它結束（呼叫端自己放在背景佇列）
    @discardableResult
    static func run(_ exe: String, _ args: [String], cwd: String? = nil, env: [String: String] = [:], stdin: String? = nil,
                    timeout: TimeInterval = 60, qos: QualityOfService? = nil) -> (code: Int32, out: String, err: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        if let qos { p.qualityOfService = qos }                         // 地下室圖譜用 .utility（10-22）
        if let cwd { p.currentDirectoryURL = URL(fileURLWithPath: cwd) }
        var e = ProcessInfo.processInfo.environment
        e["PATH"] = "\(BoardPaths.home)/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        env.forEach { e[$0.key] = $0.value }
        p.environment = e
        let o = Pipe(), er = Pipe(), i = Pipe()
        p.standardOutput = o; p.standardError = er; p.standardInput = stdin == nil ? FileHandle.nullDevice : i
        do { try p.run() } catch { return (-1, "", "\(error)") }
        if let stdin { i.fileHandleForWriting.write(Data(stdin.utf8)); try? i.fileHandleForWriting.close() }
        let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
        // stderr 另開執行緒同時讀（10-22：graphify 的 WARNING 灌滿 stderr 管道 64KB ⇒ 子行程卡住、這邊卡在讀 stdout ⇒ 互等到逾時）
        final class Buf: @unchecked Sendable { var d = Data() }      // 只有背景那條寫、等 semaphore 之後才讀
        let eb = Buf(), errDone = DispatchSemaphore(value: 0)
        let eh = er.fileHandleForReading
        DispatchQueue.global(qos: .utility).async { eb.d = eh.readDataToEndOfFile(); errDone.signal() }
        let od = o.fileHandleForReading.readDataToEndOfFile()
        errDone.wait()
        let ed = eb.d
        p.waitUntilExit(); killer.cancel()
        return (p.terminationStatus, String(decoding: od, as: UTF8.self), String(decoding: ed, as: UTF8.self))
    }
}

// MARK: - 審核員

@MainActor
final class Reviewer {
    static let shared = Reviewer()
    nonisolated static let model = "sonnet"
    private var running = Set<String>()                 // sessionId
    private let queue = DispatchQueue(label: "showork.reviewer", attributes: .concurrent)
    private let limit = 2                               // 同時最多審幾個
    private var started: [String: [Date]] = [:]         // 保險絲：同一個 session 一小時最多自動審 3 次（10-08 曾因時間精度連審 14 次）

    var enabled: Bool {
        get { UserDefaults(suiteName: "ai.okle42.showork")?.object(forKey: "board.review") as? Bool ?? true }
        set { UserDefaults(suiteName: "ai.okle42.showork")?.set(newValue, forKey: "board.review") }
    }
    func isRunning(_ sid: String) -> Bool { running.contains(sid) }

    /// 看板每次刷新都會叫；只有「在待審、這一輪還沒審」的才真的開審
    func consider(_ cards: [BoardCard], reviews: [String: Review]) {
        guard enabled else { return }
        for c in cards where !c.id.contains("#") && !running.contains(c.sessionId) && running.count < limit {
            guard CardRules.needsReview(column: c.column, review: reviews[c.sessionId], turn: c.lastActivity),
                  c.reason != "等你回答" else { continue }      // 正在問你問題的不用審
            let recent = (started[c.sessionId] ?? []).filter { $0.timeIntervalSinceNow > -3600 }
            started[c.sessionId] = recent
            if recent.count >= 3 { continue }
            start(c, force: false)
        }
    }

    func start(_ c: BoardCard, force: Bool) {
        guard let turn = c.lastActivity, !running.contains(c.sessionId), let claude = Tools.claude() else { return }
        running.insert(c.sessionId)
        started[c.sessionId, default: []].append(Date())
        Log.note("REVIEW start \(c.sessionId) force=\(force)")
        BoardModel.shared.refresh()
        let path = "\(BoardPaths.claude)/projects/\(SessionRecord(pid: c.pid, sessionId: c.sessionId, cwd: c.kindCwd).projectSlug)/\(c.sessionId).jsonl"
        let tail = (FileHandle(forReadingAtPath: path)).map { h -> Data in
            defer { try? h.close() }
            let size = (try? h.seekToEnd()) ?? 0
            try? h.seek(toOffset: size > 200_000 ? size - 200_000 : 0)
            return h.readDataToEndOfFile()
        } ?? Data()
        // 待命輪（沒動手）不開無頭審核員：一週約省幾百次 sonnet 呼叫；手動「重新審核」照審
        if !force, !CardRules.lastTurnDidWork(tail) {
            BoardStore.write("reviews", c.sessionId, Review(progress: nil, confidence: nil, verdict: "skip", issues: [], turn: turn, model: "-", costUSD: 0))
            Log.note("REVIEW skip \(c.sessionId) 這輪沒動手")
            running.remove(c.sessionId); started[c.sessionId]?.removeLast()   // 略過不算保險絲次數
            BoardModel.shared.refresh()
            return
        }
        let prompt = CardRules.reviewPrompt(project: c.project, title: c.title, report: c.report, excerpt: CardRules.excerpt(tail))
        let cwd = c.cwd.flatMap { FileManager.default.fileExists(atPath: $0) ? $0 : nil } ?? BoardPaths.home
        let sid = c.sessionId
        queue.async {
            let r = Tools.run(claude, ["-p", "--model", Reviewer.model, "--output-format", "json", "--max-turns", "12",
                                       "--allowedTools", "Read,Grep,Glob,Bash(git status:*),Bash(git diff:*),Bash(git log:*),Bash(git show:*)",
                                       "--permission-mode", "default"],
                              cwd: cwd, env: ["SHOWORK_REVIEWER": "1"], stdin: prompt, timeout: 300)
            let o = (try? JSONSerialization.jsonObject(with: Data(r.out.utf8))) as? [String: Any]
            let text = o?["result"] as? String ?? r.out
            let cost = (o?["total_cost_usd"] as? NSNumber)?.doubleValue
            let review = CardRules.parseReview(text, turn: turn, model: Reviewer.model, cost: cost)
                ?? Review(progress: nil, confidence: nil, verdict: "error", issues: [], turn: turn, model: Reviewer.model, costUSD: cost,
                          error: r.code == 0 ? "審核員沒有給出看得懂的結果" : "審核員執行失敗（\(r.code)）：\(r.err.prefix(120))")
            BoardStore.write("reviews", sid, review)
            Log.note("REVIEW done \(sid) code=\(r.code) verdict=\(review.verdict)")
            DispatchQueue.main.async { MainActor.assumeIsolated {
                Reviewer.shared.running.remove(sid)
                BoardModel.shared.append(["ev": "review", "id": sid, "verdict": review.verdict,
                                          "progress": review.progress.map(String.init) ?? "", "confidence": review.confidence.map(String.init) ?? "",
                                          "cost": cost.map { String(format: "%.4f", $0) } ?? ""])
                BoardModel.shared.refresh()
            } }
        }
    }
}

private extension BoardCard {
    /// 對話紀錄的資料夾是依「啟動時」的 cwd 命名；看板只留最後 cwd，所以從 sessions 檔再查一次
    var kindCwd: String {
        let f = "\(BoardPaths.claude)/sessions/\(pid).json"
        return FileManager.default.contents(atPath: f).flatMap(SessionRecord.decode)?.cwd ?? (cwd ?? BoardPaths.home)
    }
}

// MARK: - 你的動作

@MainActor
enum BoardActions {
    static func approve(_ c: BoardCard) {
        BoardStore.write("decisions", c.sessionId, Decision(action: .approve))
        BoardModel.shared.append(["ev": "approve", "id": c.sessionId, "project": c.project, "title": c.title])
        BoardModel.shared.refresh()
    }

    static func park(_ c: BoardCard, note: String?) {
        BoardStore.write("decisions", c.sessionId, Decision(action: .park, note: note?.isEmpty == true ? nil : note))
        BoardModel.shared.append(["ev": "park", "id": c.sessionId, "project": c.project, "note": note ?? ""])
        BoardModel.shared.refresh()
    }

    enum SendResult { case typed, copied(String) }

    /// 退回＋補一句指示：在 tmux 裡就打進那個 pane 按 Enter；不在 tmux 就拷貝到剪貼簿並跳到那個視窗
    static func sendBack(_ c: BoardCard, text: String) -> SendResult {
        let line = text.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        BoardModel.shared.append(["ev": "sendback", "id": c.sessionId, "project": c.project, "text": line])
        if let (sock, pane) = tmuxPane(of: c.pid) {
            let t = Tmux.binary()
            Tools.run(t, ["-S", sock, "send-keys", "-t", pane, "-l", line], timeout: 5)
            Thread.sleep(forTimeInterval: 0.15)
            Tools.run(t, ["-S", sock, "send-keys", "-t", pane, "Enter"], timeout: 5)
            return .typed
        }
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(line, forType: .string)
        return .copied(focus(pid: c.pid) ? "已拷貝，並跳到那個視窗；貼上後按 Return。" : "已拷貝到剪貼簿；找不到那個視窗，請自己切過去貼上。")
    }

    /// 3D 辦公室直接回答（10-20）：有 tmux 就打字送進輸入框；沒有（Kang 的 session 都直接開在 Ghostty）就走看板直送（Peer，跟派工同一條），
    /// 兩條都不通才退回拷貝。不先動剪貼簿（10-18：蓋掉他的剪貼簿）
    static func answer(_ c: BoardCard, text: String) -> String {
        let line = text.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        defer { tellCaptain(c, answer: line) }
        if tmuxPane(of: c.pid) != nil {
            if case .typed = sendBack(c, text: line) { return "已送進「\(c.title)」" }
        }
        if let r = Peer.find(c.sessionId) {
            BoardModel.shared.append(["ev": "answer", "id": c.sessionId, "project": c.project, "text": line])
            switch Peer.send(to: r, text: "【使用者從戰情中心回答你的問題】\(line)", fromName: "AI工作戰情中心（使用者）") {
            case .success: return "已送給「\(c.title)」"
            case .failure(let e): NSLog("answer peer failed: \(e.message)")
            }
        }
        if case .copied(let m) = sendBack(c, text: line) { return m }
        return "已送進「\(c.title)」"
    }

    /// 使用者答了組員卡片的問題 ⇒ 轉隊長一則「【使用者已答】」、清掉隊長卡片上同一題（隊長 Penny 10-25：別再重複問 Kang）。
    /// 答的是隊長自己的卡片就不用轉
    private static func tellCaptain(_ c: BoardCard, answer: String) {
        guard let cap = CaptainStore.captain()?.sessionId, cap != c.sessionId else { return }
        let q = c.report?.ask
        Answered.clearCaptainCard(sid: cap, question: q)
        let name = NicknameStore.get(c.sessionId)?.name ?? c.title
        let text = Answered.relay(name: name, question: q, answer: answer)
        DispatchQueue.global().async {
            guard let to = Peer.find(cap) else { return }
            _ = Peer.send(to: to, text: text, fromName: "AI工作戰情中心（使用者已答）")
        }
    }

    /// 權限對話框：在收件匣按了允許／一律允許／拒絕 ⇒ 寫回答檔，等著的 hook（showork permit）讀到就回給 Claude Code
    static func permit(_ c: BoardCard, _ a: PermitAnswer) -> String {
        guard let p = c.permit else { return "「\(c.title)」的對話框已經關了" }
        guard Permit.answer(p.id, a) else { return "「\(c.title)」已經在終端機答過了" }
        BoardModel.shared.append(["ev": "permit", "id": c.sessionId, "project": c.project, "tool": p.tool, "decision": a.decision.rawValue])
        Permit.logAnswer(p, a)
        if p.isAsk || p.isPlan { return "已回答「\(c.title)」：\(Permit.answerText(p, a))" }
        switch a.decision {
        case .allow: return "已允許「\(c.title)」"
        case .always: return "已允許「\(c.title)」，以後同類不再問"
        case .deny: return "已拒絕「\(c.title)」"
        }
    }

    /// claude 行程的 tty → 哪個 tmux server 的哪個 pane
    static func tmuxPane(of pid: Int32) -> (String, String)? {
        guard let info = ProcTree.kinfo(pid) else { return nil }
        let dev = info.kp_eproc.e_tdev
        guard dev != UInt32(bitPattern: -1), dev != 0, let n = devname(dev_t(dev), S_IFCHR) else { return nil }
        let tty = "/dev/" + String(cString: n)
        guard let sock = Tmux.socket(owningPane: tty) else { return nil }
        let out = Tools.run(Tmux.binary(), ["-S", sock, "list-panes", "-a", "-F", "#{pane_tty} #{pane_id}"], timeout: 5).out
        guard let pane = out.split(separator: "\n").first(where: { $0.hasPrefix(tty + " ") })?.split(separator: " ").last else { return nil }
        return (sock, String(pane))
    }

    /// 跳到那個 AI 的終端機視窗（光暈引擎知道它在哪）
    @discardableResult
    static func focus(pid: Int32) -> Bool {
        guard let p = Engine.current?.tabs.values.first(where: { $0.agentPID == pid })?.placements.first,
              let el = AXQuery.element(pid: p.pid, wid: p.wid) else { return false }
        NSRunningApplication(processIdentifier: p.pid)?.activate()
        AXUIElementPerformAction(el, kAXRaiseAction as CFString)
        AXUIElementSetAttributeValue(el, kAXMainAttribute as CFString, kCFBooleanTrue)
        return true
    }

    /// 前台・保全的「立即掃描」（10-20）：跑 wifiwatch.sh 不帶參數＝掃一次（ping 整個網段、讀 ARP，約數十秒）。
    /// 用 zsh 跑（腳本本身是 zsh）；最多等 10 分鐘。測試用 SHOWORK_WIFIWATCH_SCRIPT 換成假腳本，不准真的掃網路。
    nonisolated static let guardScanner = GuardScanner(script: BoardPaths.wifiwatchScript) { script in
        Tools.run("/bin/zsh", [script], timeout: 600).code
    }

    /// 新任務：在指定資料夾開官方背景 session（`claude --bg`）；回傳背景 id 或錯誤訊息
    nonisolated static func newTask(folder: String, prompt: String, fullAuto: Bool) -> Result<String, CardError> {
        guard let claude = Tools.claude() else { return .failure(CardError("找不到 claude 指令")) }
        var args = ["--bg"]
        if fullAuto { args += ["--permission-mode", "bypassPermissions"] }
        args.append(prompt)
        let r = Tools.run(claude, args, cwd: folder, timeout: 60)
        let all = r.out + r.err
        if let line = all.split(separator: "\n").first(where: { $0.contains("backgrounded") }),
           let id = line.split(separator: "·").last?.trimmingCharacters(in: .whitespaces) { return .success(id) }
        return .failure(CardError(all.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "claude --bg 失敗（\(r.code)）" : String(all.prefix(300))))
    }
}


// MARK: - ctx 快滿：提醒＋自動收尾（Kang 10-09）

@MainActor
final class CtxGuard {
    static let shared = CtxGuard()
    private var file: URL { BoardPaths.dir.appendingPathComponent("ctxguard.json") }
    private struct State: Codable { var notified: [String: Date] = [:]; var sent: [String: Date] = [:] }
    private lazy var state: State = (try? BoardJSON.decoder.decode(State.self, from: Data(contentsOf: file))) ?? State()

    var autoWrapUp: Bool {
        get { UserDefaults(suiteName: "ai.okle42.showork")?.object(forKey: "board.autoWrapUp") as? Bool ?? true }
        set { UserDefaults(suiteName: "ai.okle42.showork")?.set(newValue, forKey: "board.autoWrapUp") }
    }
    func wasSent(_ sid: String) -> Bool { state.sent[sid] != nil || hookHandled(sid) }

    /// Stop hook（~/.claude/scripts/hook_ctx_wrapup.py）請它收尾過就會留這個檔。收尾主力是 hook：
    /// 不靠 tmux 打字，Ghostty 直接開的 session 也收得到（10-18：不在 tmux 裡的都送不到，還蓋掉剪貼簿）
    private func hookHandled(_ sid: String) -> Bool {
        FileManager.default.fileExists(atPath: BoardPaths.claude + "/cache/ctx_wrapup/" + sid)
    }

    func check(_ cards: [BoardCard]) {
        guard Engine.current != nil else { return }             // 只有正式 agent 會提醒、會打字；測試視窗不動手
        var changed = false
        for c in cards where !c.id.contains("#") {
            guard let x = c.ctx, ContextGuard.over(x) else { continue }
            if state.notified[c.sessionId] == nil {
                state.notified[c.sessionId] = Date(); changed = true
                notify("\(c.project)：context \(Int(x.percent))%",
                       autoWrapUp ? "停下來後會自動請它 commit 並收尾" : "該收尾了：在AI工作戰情中心按「收尾」")
                BoardModel.shared.append(["ev": "ctx85", "id": c.sessionId, "project": c.project, "ctx": String(Int(x.percent))])
            }
            // 後備：hook 沒接手（例如 session 開在 hook 裝好之前）、停了 60 秒以上、又在 tmux 裡才打字；
            // 打不進去就不記已送、不動剪貼簿，等下次停下來由 hook 收
            if autoWrapUp, ContextGuard.shouldWrapUp(card: c, ctx: x, alreadySent: wasSent(c.sessionId)),
               let t = c.lastActivity, Date().timeIntervalSince(t) >= 60,
               BoardActions.tmuxPane(of: c.pid) != nil {
                BoardActions.wrapUp(c)
                state.sent[c.sessionId] = Date(); changed = true
            }
        }
        if changed, let d = try? BoardJSON.encoder.encode(state) {
            try? FileManager.default.createDirectory(at: BoardPaths.dir, withIntermediateDirectories: true)
            try? d.write(to: file, options: .atomic)
        }
    }

    func markSent(_ sid: String) { state.sent[sid] = Date(); if let d = try? BoardJSON.encoder.encode(state) { try? d.write(to: file, options: .atomic) } }

    /// agent 不是 .app，用 osascript 發系統通知
    private func notify(_ title: String, _ body: String) {
        func q(_ s: String) -> String { s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") }
        DispatchQueue.global().async {
            Tools.run("/usr/bin/osascript", ["-e", "display notification \"\(q(body))\" with title \"AI工作戰情中心\" subtitle \"\(q(title))\""], timeout: 10)
        }
    }
}

extension BoardActions {
    /// 請那個 session 收尾（commit、規則允許才 push、更新交接）；回傳 "typed" 或說明
    @discardableResult
    static func wrapUp(_ c: BoardCard) -> String {
        let text = ContextGuard.wrapUpPrompt(percent: c.ctx?.percent ?? ContextGuard.threshold)
        BoardModel.shared.append(["ev": "wrapup", "id": c.sessionId, "project": c.project, "ctx": c.ctx.map { String(Int($0.percent)) } ?? ""])
        CtxGuard.shared.markSent(c.sessionId)
        switch sendBack(c, text: text) {
        case .typed: return "typed"
        case .copied(let m): return m
        }
    }
}

// MARK: - P3 派工：自動回報隊長、自動接力（Kang 10-09）

/// 每次刷新看一遍派工單：做完／要你決定／卡住 ⇒ 傳一則【派工回報】給隊長；做完又有下一棒 ⇒ 自動派給下一棒。
/// 只有正式 agent 會送（測試視窗不動手）；送訊息會等一下，所以放背景，同一張單同時只處理一次。
@MainActor
final class TaskRouter {
    static let shared = TaskRouter()
    private var inflight = Set<String>()
    private let queue = DispatchQueue(label: "showork.router")

    func check(_ tasks: [CaptainTask]) {
        guard Engine.current != nil else { return }
        for t in tasks where !inflight.contains(t.id) && (Captain.shouldNotify(t) || (t.state == .done && t.thenTo != nil && t.followUp == nil)) {
            inflight.insert(t.id)
            let id = t.id
            queue.async {
                TaskRouter.route(id)
                DispatchQueue.main.async { MainActor.assumeIsolated { TaskRouter.shared.inflight.remove(id); BoardModel.shared.refresh() } }
            }
        }
    }

    nonisolated static var showork: String { Paths.supportDir.appendingPathComponent("bin/showork").path }

    nonisolated static func route(_ id: String) {
        guard let t = CaptainStore.task(id) else { return }
        var follow: CaptainTask?
        if let next = Captain.nextLeg(of: t, id: Captain.newId(now: Date(), existing: Set(CaptainStore.tasks().map(\.id))), now: Date()) {
            let (saved, r) = Captain.dispatch(next, showork: showork)
            follow = saved
            Log.note("ROUTER followup \(id) → \(saved.id) \(saved.to) \(r)")
        }
        var notified: CaptainTask.State?
        if Captain.shouldNotify(t) {
            let text = Captain.reportText(t, followUp: follow)
            if let cap = Peer.find(t.from), cap.sessionId != t.toSession {
                let r = Peer.send(to: cap, text: text, fromName: "AI工作戰情中心")
                Log.note("ROUTER notify \(id) \(t.state.rawValue) → \(cap.name ?? cap.sessionId) \(r)")
                if case .failure = r { systemNotice(t) }
            } else {
                systemNotice(t)                // 隊長不在（或從看板直接派的），改發系統通知給你
            }
            notified = t.state
        }
        // 寫回前再讀一次：對方可能剛好又回報了，只動我們自己的欄位
        guard var fresh = CaptainStore.task(id) else { return }
        if let f = follow { fresh.followUp = f.id }
        if let n = notified { fresh.notified = n }
        CaptainStore.save(fresh)
        DispatchQueue.main.async { MainActor.assumeIsolated {
            BoardModel.shared.append(["ev": "task", "id": id, "state": t.state.rawValue, "followUp": follow?.id ?? ""])
        } }
    }

    nonisolated static func systemNotice(_ t: CaptainTask) {
        func q(_ s: String) -> String { s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") }
        let body = q(t.summary ?? t.text)
        Tools.run("/usr/bin/osascript", ["-e", "display notification \"\(body)\" with title \"AI工作戰情中心\" subtitle \"\(q("派工 \(t.id)：\(t.to) \(t.state.title)"))\""], timeout: 10)
    }
}

extension BoardActions {
    /// 看板上直接派工給某個 session（你按的）；有隊長就由隊長收回報，沒有就發系統通知給你
    nonisolated static func dispatch(to c: BoardCard, text: String, thenTo: String?, thenText: String?, captain: String?) -> Result<String, CardError> {
        let id = Captain.newId(now: Date(), existing: Set(CaptainStore.tasks().map(\.id)))
        let t = CaptainTask(id: id, from: captain ?? "board", to: c.name ?? c.sessionId, toSession: c.sessionId, project: c.project, text: text,
                            thenTo: thenTo, thenText: thenTo == nil ? nil : thenText)
        let (_, r) = Captain.dispatch(t, showork: TaskRouter.showork, fromName: "AI工作戰情中心（你從看板派的）")
        return r.map { _ in id }
    }

    /// 把一件事交給隊長，由它決定給誰
    nonisolated static func toCaptain(_ sid: String, text: String) -> Result<String, CardError> {
        guard let cap = Peer.find(sid) else { return .failure(CardError("隊長的 session 沒開著")) }
        let body = "【使用者從看板交辦】\(text)\n請照隊長守則處理：先看名冊（showork roster），選人後用 showork task add 派工；小事自己做。"
        return Peer.send(to: cap, text: body, fromName: "AI工作戰情中心（使用者）")
    }
}

// MARK: - 收件匣：交給隊長（10-26 Kang：預設 Opus，需要判斷時再升 Fable）

extension BoardActions {
    nonisolated static var captainModel: String {
        UserDefaults(suiteName: "ai.okle42.showork")?.string(forKey: CaptainLaunch.modelKey).flatMap { $0.isEmpty ? nil : $0 } ?? CaptainLaunch.defaultModel
    }
    /// 剛開的背景隊長（短 id、開的時間）：還沒登記好之前不要再開第二個
    nonisolated(unsafe) private static var launching: (id: String, at: Date)?
    nonisolated private static let launchLock = NSLock()

    /// 現在的隊長還開著嗎（行程在、有收件匣）
    nonisolated static func liveCaptain() -> SessionRecord? {
        CaptainStore.captain().flatMap { Peer.find($0.sessionId) }
    }

    /// 交給隊長：隊長在就直送；不在就開一個背景隊長（claude --bg --model <captainModel>），把這件事當它的第一句話。
    /// 會等（開 session 最多 30 秒），呼叫端放背景佇列。
    nonisolated static func askCaptain(_ text: String) -> String {
        let line = Inbox.message(text)
        guard !line.isEmpty else { return "沒有內容" }
        if let cap = liveCaptain() {
            switch toCaptain(cap.sessionId, text: line) {
            case .success: return "已交給隊長「\(cap.name ?? "隊長")」"
            case .failure(let e): return "送不到隊長：\(e.message)"
            }
        }
        launchLock.lock()
        if let l = launching, Date().timeIntervalSince(l.at) < 120 {
            launchLock.unlock()
            if let r = Peer.find(l.id) {
                CaptainStore.setCaptain(CaptainRecord(sessionId: r.sessionId, name: r.name))
                return toCaptain(r.sessionId, text: line).map { _ in "已交給隊長「\(r.name ?? "隊長")」" }.get(or: "送不到隊長")
            }
            return "隊長剛開，還在暖機；過半分鐘再送一次"
        }
        launching = (id: "", at: Date())
        launchLock.unlock()
        guard let claude = Tools.claude() else { launching = nil; return "找不到 claude 指令，開不了隊長" }
        let prompt = CaptainLaunch.bootstrap(showork: TaskRouter.showork, task: line)
        let r = Tools.run(claude, ["--bg", "--model", captainModel, "-n", "隊長", "--permission-mode", "bypassPermissions", prompt],
                          cwd: BoardPaths.home, timeout: 60)
        let all = r.out + r.err
        guard let l = all.split(separator: "\n").first(where: { $0.contains("backgrounded") }),
              let id = l.split(separator: "·").dropFirst().first?.trimmingCharacters(in: .whitespaces), id.count >= 6 else {
            launching = nil
            return "開隊長失敗：" + String(all.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200))
        }
        launching = (id: id, at: Date())
        Log.note("CAPTAIN launched \(id) model=\(captainModel)")
        // 登記成隊長（它自己跑 showork captain 也會登記；先登記，下一句交辦才找得到它）
        for _ in 0..<30 {
            if let rec = Peer.find(id) {
                CaptainStore.setCaptain(CaptainRecord(sessionId: rec.sessionId, name: rec.name))
                return "已開新隊長（\(modelTitle(captainModel))），這件事是它的第一個任務"
            }
            Thread.sleep(forTimeInterval: 1)
        }
        return "已開新隊長（\(modelTitle(captainModel))），正在暖機"
    }

    nonisolated static func modelTitle(_ m: String) -> String {
        switch m {
        case "claude-fable-5-1": "Fable 5.1"
        case "claude-opus-5-5": "Opus 5.5"
        case "claude-sonnet-5-5": "Sonnet 5.5"
        default: m
        }
    }
}

private extension Result {
    func get(or fallback: String) -> String where Success == String { (try? get()) ?? fallback }
}
