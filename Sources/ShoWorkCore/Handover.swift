import Foundation
import Darwin

// ctx 自動交接閉環（T1024155358，Kang 10-24：「超過 70% 以後就自動收尾…自己準備交接文件，處理好之後自己再接手」）
//   ① Stop hook（~/.claude/scripts/hook_ctx_wrapup.py）請它收尾
//   ② 收尾完 AI 發 `showork card --kind wrapup --handoff <檔>` ⇒ 這裡記一筆 board/handover/<sid>.json（pending）
//      看板看到它閒下來（最後一張卡就是 wrapup、不在工作、沒開對話框）⇒ 對它的終端機送 /clear
//   ③ /clear 後的 SessionStart（showork brief）認領這筆：名字沿用、派工單轉到新 sid、注入接手提示；看板再打一句「開始接手」叫它動起來
// 收尾後、/clear 前使用者又下新指令 ⇒ interrupted（不自動 /clear，看板轉隊長提醒）；之後 ctx 再多 15% Stop hook 會再收一次。

public struct HandoverRecord: Codable, Sendable, Equatable {
    public enum State: String, Codable, Sendable {
        case pending       // 收尾完，等它閒下來送 /clear
        case interrupted   // 收尾後使用者又派新工作：不自動 /clear
        case clearing      // /clear 已送，等新 sid 出現
        case taken         // 新 context 已認領（或壓縮後同一個 sid 接著做）
        case failed        // 送不出去／送了沒換 sid：要 Kang 手動
    }
    public var sid: String
    public var pid: Int32
    public var cwd: String
    public var name: String
    public var handoff: String            // 交接文件絕對路徑
    public var summary: String?           // 一句接手重點
    public var at: Date
    public var state: State
    public var newSid: String? = nil
    public var clearAt: Date? = nil
    public var via: String? = nil         // tmux／ghostty
    public var kicked = false             // 已打「開始接手」
    public var notified = false           // interrupted／failed 已通知
    public var note: String? = nil        // 失敗原因
    public var tasks: [String] = []       // 轉到新 sid 的派工單
    public init(sid: String, pid: Int32, cwd: String, name: String, handoff: String, summary: String?, at: Date, state: State = .pending) {
        self.sid = sid; self.pid = pid; self.cwd = cwd; self.name = name; self.handoff = handoff; self.summary = summary; self.at = at; self.state = state
    }
    /// 卡片／名冊上的標記
    public var label: String? {
        switch state {
        case .pending: "已收尾待 /clear"
        case .interrupted: "已收尾、又接新工作"
        case .clearing: "/clear 中"
        case .failed: "自動 /clear 失敗"
        case .taken: nil
        }
    }
}

public enum Handover {
    /// 認領期限：收尾後這麼久內的新 session 才算接手（Penny 規格 60 分鐘）
    public static let window: TimeInterval = 3600
    /// 鍵盤要靜這麼久才送 /clear（免得打進 Kang 正在那個分頁打的草稿；隊長 Penny 10-24 要求 60 秒）
    /// 10-26 Kang：收尾完就直接 /clear，不等鍵盤（原 60 秒：他一直在別的視窗打字就永遠送不出去）
    public static let keyIdle: TimeInterval = 0
    /// 送 /clear 後這麼久沒換 sid ⇒ 失敗
    public static let clearTimeout: TimeInterval = 20

    public static var dir: URL {
        if let d = ProcessInfo.processInfo.environment["SHOWORK_HANDOVER_DIR"] { return URL(fileURLWithPath: d, isDirectory: true) }
        return Paths.supportDir.appendingPathComponent("board/handover", isDirectory: true)
    }
    public static func load(_ sid: String) -> HandoverRecord? {
        FileManager.default.contents(atPath: dir.appendingPathComponent(sid + ".json").path).flatMap { try? BoardJSON.decoder.decode(HandoverRecord.self, from: $0) }
    }
    public static func all() -> [HandoverRecord] {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).filter { $0.hasSuffix(".json") }
            .compactMap { load(String($0.dropLast(5))) }.sorted { $0.at < $1.at }
    }
    @discardableResult
    public static func save(_ r: HandoverRecord) -> Bool {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        guard let d = try? BoardJSON.encoder.encode(r) else { return false }
        return (try? d.write(to: dir.appendingPathComponent(r.sid + ".json"), options: .atomic)) != nil
    }

    /// 這個 hook／CLI 是哪個 claude 行程叫的：往上找第一個有 ~/.claude/sessions/<pid>.json 的祖先
    /// （/clear 換 sid 但不換行程；行程名不可靠——實測 p_comm 是版本號那個執行檔名，不是 claude）
    public static func claudePID(startingAt pid: Int32 = getppid()) -> Int32? {
        let dir = FileManager.default.homeDirectoryForCurrentUser.path + "/.claude/sessions/"
        var p = pid
        for _ in 0..<12 {
            guard p > 1 else { return nil }
            if FileManager.default.fileExists(atPath: dir + "\(p).json") { return p }
            guard let info = TTYFinder.kinfo(p) else { return nil }
            p = info.kp_eproc.e_ppid
        }
        return nil
    }

    /// 新 context 要認領哪一筆（SessionStart）：
    ///   compact＝同一個 sid；其他（clear／startup／resume）先找同一個 claude 行程，再找同資料夾而且原 session 已經不在的
    /// live＝現在活著的 sessionId（不含自己）
    public static func match(_ rs: [HandoverRecord], sid: String, pid: Int32?, cwd: String?, source: String?, live: Set<String>, now: Date) -> HandoverRecord? {
        let fresh = rs.filter { $0.state != .taken && now.timeIntervalSince($0.at) < window && $0.sid != "" }
        if source == "compact" { return fresh.last { $0.sid == sid } }
        if let pid, let r = fresh.last(where: { $0.pid == pid && $0.sid != sid }) { return r }
        guard let cwd = cwd.map(normal) else { return nil }
        return fresh.last { normal($0.cwd) == cwd && $0.sid != sid && !live.contains($0.sid) }
    }
    static func normal(_ p: String) -> String { URL(fileURLWithPath: p).standardizedFileURL.path }

    /// 注入給新 context 的接手提示（SessionStart additionalContext）
    public static func resumeContext(_ r: HandoverRecord, tasks: [String]) -> String {
        var t = "【自動接手】你是 \(r.name) 的接手（上一段 context 在 \(clock(r.at)) 收尾）。先完整讀交接文件 \(r.handoff)（和它指定要讀的文件），"
            + "照裡面的「下一步」直接接著做，不用等使用者重新交代；遇到交接裡寫明要等使用者決定的事就跳過、做下一件。"
            + "名字沿用 \(r.name)（自報 showork card 照常）"
        t += tasks.isEmpty ? "。" : "，派工單沿用：\(tasks.joined(separator: "、"))（回報照樣帶 --task）。"
        if let s = r.summary, !s.isEmpty { t += "上一段留的接手重點：\(s)" }
        return t
    }
    /// /clear 後看板打進去的那一句（真的讓它動起來；SessionStart 的提示萬一沒進去，這句也帶著交接路徑）
    public static func kickoff(_ r: HandoverRecord) -> String {
        "【自動接手】請接手 \(r.name) 的工作：先讀 \(r.handoff)，照裡面的下一步繼續。"
    }
    static func clock(_ d: Date) -> String { let f = DateFormatter(); f.dateFormat = "HH:mm"; return f.string(from: d) }

    /// 看板能不能送 /clear 了：還在 pending（使用者沒打斷）、不在工作、沒開對話框、最後一張不是開工卡、停了 5 秒、鍵盤 60 秒沒動
    public static func readyToClear(state: HandoverRecord.State, lastKind: String?, working: Bool, dialog: Bool,
                                    lastActivity: Date?, keyIdle: TimeInterval, now: Date) -> Bool {
        // T1026230337：收尾後被訊息叫醒、回完又發一般卡片，不再讓收尾作廢；使用者本人打斷由 noteNewPrompt 改成 interrupted 處理
        guard state == .pending, lastKind != "start", !working, !dialog, keyIdle >= Self.keyIdle else { return false }
        return lastActivity.map { now.timeIntervalSince($0) >= 5 } ?? true
    }

    /// 終端機標題要對得上英文名（Ghostty 標題＝「✳ Ruby-任務」；閉環驗證，驗不過不送）
    public static func titleMatches(_ title: String, name: String) -> Bool {
        let t = title.drop { !$0.isLetter }
        return t == Substring(name) || t.hasPrefix(name + "-")
    }
}

// MARK: - 認領：名字沿用、派工單轉手

extension Handover {
    /// SessionStart 用：認領、沿用名字、轉派工單，回傳要注入的提示；沒得認領＝nil
    public static func claim(sid: String, pid: Int32?, cwd: String?, source: String?, now: Date = Date()) -> String? {
        let live = Set(NicknameStore.liveSessions().map(\.sessionId)).subtracting([sid])
        guard var r = match(all(), sid: sid, pid: pid, cwd: cwd, source: source, live: live, now: now) else { return nil }
        var moved: [String] = []
        if r.sid != sid {
            var n = Nickname(name: r.name, doing: NicknameStore.get(r.sid)?.doing, at: now)
            n.handoverFrom = r.sid
            NicknameStore.save(sid, n)
            for var t in CaptainStore.tasks() where t.state.open && (t.toSession == r.sid || (t.toSession == nil && t.to == r.name)) {
                t.toSession = sid; t.to = r.name
                if CaptainStore.save(t) { moved.append(t.id) }
            }
        } else {
            moved = CaptainStore.tasks().filter { $0.state.open && $0.toSession == sid }.map(\.id)
        }
        r.state = .taken; r.newSid = sid; r.tasks = moved
        save(r)
        return resumeWithHeld(r, tasks: moved)
    }

    /// 接手提示＋收尾期間暫存的訊息（取出後清掉）
    public static func resumeWithHeld(_ r: HandoverRecord, tasks: [String]) -> String {
        let held = takeHeld(r.sid)
        guard !held.isEmpty else { return resumeContext(r, tasks: tasks) }
        return resumeContext(r, tasks: tasks) + "\n【收尾期間暫存、現在補交給你的 \(held.count) 則訊息】（讀完交接後照常處理；隊長另跑 showork captain 看未 ack 收件匣）\n"
            + held.map { "— 來自 \($0.from)：\($0.text)" }.joined(separator: "\n")
    }

    /// UserPromptSubmit 用：收尾後、/clear 前「使用者本人」又下指令 ⇒ interrupted（看板轉隊長提醒）。
    /// T1026230337：其他 session 的訊息、巡檢、工作回報／派工回報轉送都不算打斷（10-26 Penny、Tina 被巡檢一叫醒收尾就作廢）；
    /// 沒打斷但還在等 /clear ⇒ 回一段提醒，請它簡短回完就停、有新進度補進交接，不用再發收尾卡
    @discardableResult
    public static func noteNewPrompt(sid: String, prompt: String?, now: Date = Date()) -> String? {
        guard var r = load(sid), r.state == .pending else { return nil }
        if isUserPrompt(prompt) {
            r.state = .interrupted; r.note = "使用者又下指令"
            save(r)
            log("interrupted \(r.name) \(r.sid.prefix(8))：使用者又下指令", now: now)
            return nil
        }
        log("keep \(r.name) \(r.sid.prefix(8))：\(sender(prompt)) 的訊息不算打斷，收尾照舊", now: now)
        return "【交接中】你已收尾、在等戰情中心自動 /clear。這則是其他 session／看板的訊息，不算打斷：簡短處理或回覆後就停下；"
            + "有新進度就補進交接文件 \(r.handoff)，不用再發收尾卡（發一般卡片也不影響自動 /clear）。"
    }

    /// 使用者本人：在那個視窗直接打的字，或戰情中心轉來的「使用者回答／使用者交辦」
    public static func isUserPrompt(_ prompt: String?) -> Bool {
        guard let p = prompt?.trimmingCharacters(in: .whitespacesAndNewlines), !p.isEmpty else { return false }
        if p.hasPrefix("<cross-session-message") {
            let head = p.prefix { $0 != ">" }
            return head.contains("from-name=\"AI工作戰情中心（使用者")
        }
        return CaptainLink.needsStart(prompt: p)
    }
    static func sender(_ prompt: String?) -> String {
        guard let p = prompt, let r = p.range(of: "from-name=\"") else { return "非使用者" }
        return String(p[r.upperBound...].prefix { $0 != "\"" })
    }

    // MARK: 收尾期間暫存（T1026230337 ②）：看板／隊長流程要送給「已收尾等 /clear」的 session 的訊息先存著，新 context 接手時一起交給它

    /// 收尾中（pending／clearing）而且不是使用者本人的訊息 ⇒ 暫存不送
    public static func shouldHold(sid: String, fromName: String) -> Bool {
        guard let r = load(sid), r.state == .pending || r.state == .clearing else { return false }
        return !fromName.contains("（使用者") && !fromName.contains("（交接）")
    }
    static func heldURL(_ sid: String) -> URL { dir.appendingPathComponent("held/\(sid).jsonl") }
    public static func hold(sid: String, text: String, fromName: String, now: Date = Date()) {
        try? FileManager.default.createDirectory(at: heldURL(sid).deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let d = try? JSONSerialization.data(withJSONObject: ["at": ISO8601DateFormatter().string(from: now), "from": fromName, "text": text]) else { return }
        if let h = try? FileHandle(forWritingTo: heldURL(sid)) { h.seekToEndOfFile(); h.write(d + Data("\n".utf8)); try? h.close() }
        else { try? (d + Data("\n".utf8)).write(to: heldURL(sid)) }
        log("hold → \(load(sid)?.name ?? sid.prefix(8).description)（\(fromName)）：\(text.prefix(40))", now: now)
    }
    /// 取出並清掉暫存（接手時用）
    public static func takeHeld(_ sid: String) -> [(from: String, text: String)] {
        guard let d = FileManager.default.contents(atPath: heldURL(sid).path) else { return [] }
        try? FileManager.default.removeItem(at: heldURL(sid))
        return d.split(separator: 0x0A).compactMap { l in
            (try? JSONSerialization.jsonObject(with: Data(l)) as? [String: String]).flatMap { o in o["text"].map { (o["from"] ?? "", $0) } }
        }
    }

    /// 寫 board/handover.log（看板 HandoverClear 也寫同一份）
    public static func log(_ msg: String, now: Date = Date()) {
        let url = dir.deletingLastPathComponent().appendingPathComponent("handover.log")
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let line = Data("\(f.string(from: now)) \(msg)\n".utf8)
        if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(line); try? h.close() } else { try? line.write(to: url) }
    }
}
