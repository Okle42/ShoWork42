import Foundation

// AI工作戰情中心 P3：隊長派工（Kang 10-09）。
// 你只跟一個「隊長」session 講話；隊長看名冊決定交給哪個 session，用 Claude Code 內建的 SendMessage 傳話
// （跨 session 訊息在對方下一次用工具時才進去，不會打進你正在打字的輸入框；tmux 打字只留給退回／收尾）。
// 看板這邊負責：名冊（每個 session 在做哪個專案）、同專案多開的重工警告、派工單從派出到回報的追蹤。
//   board/captain.json        誰是隊長
//   board/roster.json         名冊快照（agent 每次刷新寫；showork roster 讀）
//   board/tasks/<id>.json     派工單（showork task add 建；對方 showork card --task 回報時更新）

/// 一張派工單
public struct CaptainTask: Codable, Sendable, Equatable, Identifiable {
    public enum State: String, Codable, Sendable, CaseIterable {
        case sent, working, review, done, blocked, cancelled

        public var title: String {
            switch self {
            case .sent: "已派出"
            case .working: "做事中"
            case .review: "要你看"
            case .done: "完成"
            case .blocked: "卡住"
            case .cancelled: "已取消"
            }
        }
        /// 還沒結束（隊長要繼續追）
        public var open: Bool { self == .sent || self == .working || self == .blocked }
    }

    public var id: String
    public var from: String              // 隊長的 sessionId
    public var to: String                // 對方的 session 名（SendMessage 的地址）
    public var toSession: String?        // 派出當下對方的 sessionId
    public var project: String?
    public var text: String
    public var state: State
    public var summary: String?          // 對方最後一次回報的一句話
    public var ask: String?
    public var createdAt: Date
    public var updatedAt: Date
    public var thenTo: String? = nil       // 做完（done）後自動交給誰（接力）
    public var thenText: String? = nil     // 交給下一棒的任務
    public var followUp: String? = nil     // 已經開出的下一棒單號
    public var after: String? = nil        // 這張是哪張單的下一棒
    public var notified: State? = nil      // 已經通知隊長到哪個狀態（同一個狀態只通知一次）
    public var sendError: String? = nil    // 直送失敗的原因

    public init(id: String, from: String, to: String, toSession: String? = nil, project: String? = nil, text: String,
                state: State = .sent, summary: String? = nil, ask: String? = nil, createdAt: Date = Date(), updatedAt: Date? = nil,
                thenTo: String? = nil, thenText: String? = nil, after: String? = nil) {
        self.id = id; self.from = from; self.to = to; self.toSession = toSession; self.project = project; self.text = text
        self.state = state; self.summary = summary; self.ask = ask; self.createdAt = createdAt; self.updatedAt = updatedAt ?? createdAt
        self.thenTo = thenTo; self.thenText = thenText; self.after = after
    }

    /// 對方用 `showork card --task <id>` 回報 → 更新這張單
    public mutating func apply(_ r: SelfReport) {
        guard state != .cancelled else { return }
        switch r.status {
        case .working: state = .working
        case .review: state = .review
        case .done: state = r.ask == nil ? .done : .review
        case .blocked: state = .blocked
        }
        summary = r.summary ?? summary
        ask = r.ask
        updatedAt = r.at
    }
}

/// 名冊的一列
public struct RosterEntry: Codable, Sendable, Equatable {
    public var name: String              // SendMessage 用的地址
    public var sessionId: String
    public var pid: Int32
    public var kind: String?
    public var project: String
    public var root: String?             // 專案資料夾（git 根目錄）
    public var column: BoardColumn
    public var reason: String
    public var title: String
    public var summary: String?
    public var ctx: Int?
    public var lastActivity: Date?
    public var captain: Bool
    public var sameProject: [String]     // 同專案的其他 session 名（重工警告）
    public var handover: String? = nil   // 「已收尾待 /clear」⋯（Handover.swift；巡檢列出）
}

public struct Roster: Codable, Sendable, Equatable {
    public var at: Date
    public var captain: String?          // 隊長的 sessionId
    public var entries: [RosterEntry]
    public init(at: Date, captain: String?, entries: [RosterEntry]) { self.at = at; self.captain = captain; self.entries = entries }
}

public struct CaptainRecord: Codable, Sendable, Equatable {
    public var sessionId: String
    public var name: String?
    public var at: Date
    public init(sessionId: String, name: String?, at: Date = Date()) { self.sessionId = sessionId; self.name = name; self.at = at }
}

public enum Captain {
    public static var dir: URL { Paths.supportDir.appendingPathComponent("board", isDirectory: true) }
    public static var captainFile: URL { dir.appendingPathComponent("captain.json") }
    public static var rosterFile: URL { dir.appendingPathComponent("roster.json") }
    public static var tasksDir: URL { dir.appendingPathComponent("tasks", isDirectory: true) }

    /// 不算「專案」的歸屬（家目錄、看不出來的），不做重工比對
    public static func isRealProject(_ p: String) -> Bool { !p.hasPrefix("（") }

    /// 同專案多開：sessionId → 同專案的其他 session 名。隊長自己不算（它本來就會到處看）。
    public static func sameProject(_ cards: [BoardCard], captain: String?) -> [String: [String]] {
        let live = cards.filter { !$0.id.contains("#") && $0.sessionId != captain && isRealProject($0.project) }
        var out: [String: [String]] = [:]
        for c in live {
            let others = live.filter { $0.sessionId != c.sessionId && $0.project == c.project }.map { $0.name ?? String($0.sessionId.prefix(8)) }
            if !others.isEmpty { out[c.sessionId] = others.sorted() }
        }
        return out
    }

    /// 看板卡片＋派工單 → 標上隊長、重工、派工（純函式，畫面與 roster 共用）
    public static func annotate(_ cards: [BoardCard], captain: String?, tasks: [CaptainTask]) -> [BoardCard] {
        let dup = sameProject(cards, captain: captain)
        return cards.map { c in
            guard !c.id.contains("#") else { return c }
            var c = c
            c.captain = c.sessionId == captain
            c.sameProject = dup[c.sessionId] ?? []
            c.tasks = c.captain
                ? tasks.filter { $0.from == c.sessionId }.sorted { $0.createdAt > $1.createdAt }
                : tasks.filter { $0.state.open && ($0.toSession == c.sessionId || ($0.toSession == nil && $0.to == c.name)) }
            return c
        }
    }

    public static func roster(_ cards: [BoardCard], captain: String?, now: Date) -> Roster {
        let entries = cards.filter { !$0.id.contains("#") }.map { c in
            RosterEntry(name: c.name ?? String(c.sessionId.prefix(8)), sessionId: c.sessionId, pid: c.pid, kind: c.kind,
                        project: c.project, root: c.cwd, column: c.column, reason: c.reason, title: c.title,
                        summary: c.report?.summary ?? c.detail.map { String($0.prefix(120)) },
                        ctx: c.ctx.map { Int($0.percent) }, lastActivity: c.lastActivity,
                        captain: c.captain, sameProject: c.sameProject, handover: c.handover)
        }
        return Roster(at: now, captain: captain, entries: entries)
    }

    /// 派工單號：T 加上月日時分秒（同一秒派兩張就再加一碼）
    public static func newId(now: Date, existing: Set<String>) -> String {
        let f = DateFormatter(); f.dateFormat = "MMddHHmmss"; f.locale = Locale(identifier: "en_US_POSIX")
        let base = "T" + f.string(from: now)
        if !existing.contains(base) { return base }
        for i in 2... where !existing.contains("\(base)-\(i)") { return "\(base)-\(i)" }
        return base
    }

    /// 隊長要用 SendMessage 送給對方的全文（附上回報方式）
    public static func message(_ t: CaptainTask, showork: String) -> String {
        let lines = t.text.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n")
        let rest = lines.dropFirst().joined(separator: "\n")
        return """
        【隊長派工 \(t.id)】\(lines.first ?? "")
        \(rest.isEmpty ? "" : rest + "\n")
        回報方式：這件事每一輪的 showork card 都加上 --task \(t.id)（例如 "\(showork)" card --task \(t.id) --status done --progress 100 --confidence 80 --summary "…"）。要使用者決定的用 --ask；卡住用 --status blocked 並說原因。同一個 repo 的規則（不准 push、客戶案要審）照舊遵守。
        """
    }

    /// `showork captain` 印給隊長 AI 的工作守則
    public static func manual(showork: String) -> String {
        let owner = LocalConfig.current.ownerName
        return """
        [AI工作戰情中心] 你現在是隊長。使用者把任務丟給你，你決定交給哪個 session 做，自己不下去做細節（保持 context 乾淨，才能一直當隊長）。
        1. 先看名冊："\(showork)" roster（每個 session 的名字、專案、在做什麼、閒置或忙、ctx、同專案重工警告）。
        2. 選人：同一個專案只交給一個 session（有人在做那個專案就交給它，不要再開）；ctx ≥ 85% 的不要再派；沒有合適的就請使用者開新的或用看板「新任務⋯」。
        3. 派工："\(showork)" task add --to <英文名，例如 Chris> --text "<任務：目標、判準、交什麼>" —— 會建單並直接送進對方收件匣。
           接力（A 做完自動交給 B）：再加 --then-to <B 的名字> --then "<B 要做的事>"，A 回報完成時看板會把 A 的回報附上、自動派給 B。
           直送失敗時它會印出全文，改用 SendMessage（to＝英文名，例如 Chris；名字固定，不會跟著對方在做的事變）送。
        4. 對方回報完成、要使用者決定、或卡住時，看板會自動傳一則「【派工回報】」給你；也可以隨時 "\(showork)" tasks 查。
        5. 收到回報後整理給使用者；要使用者決定的事轉問使用者，不要自己替他決定。
        6. 小事（問個問題、改一行）自己做比較快，不用派。派工會讓對方動手改東西；使用者沒授權的事、你自己權限會被擋的事，不要叫別人做。
        7. 流程優化：Agent交流互動板是大家休息時留的工作心得（方法、踩過的坑、流程哪裡可以改），新留言會以「【交流板】」轉給你；
           全部看 "\(showork)" b1 read。把重複出現的坑、好方法整理進派工（任務裡直接附上該注意的事），值得改成規則的提給使用者。
        8. 開工卡：組員收到使用者直接下的新任務時，動手前會發「【開工】」卡給你（打算怎麼做、會動到什麼、有沒有對外動作）；組員不等你，有問題就 SendMessage 修正，下一輪送達。
        9. 動作預告：組員要跑高風險指令前會送「【動作預告】」。rm／mv 到暫存區以外、firebase deploy、App 封裝上傳、line_send.py、gh 對外發言（issue／PR 留言或開單、PR review、release、gh api 寫入；Okle42 私有 repo 除外）會先擋下等放行；
           只有\(owner)已經明說同意的動作（例如他說「push」「部署」「傳給學弟」）你才能 "\(showork)" release <單號>，對外動作不能自己決定放行。每次放行都會記在 board/permits/releases.jsonl。
           其他（defaults write、寫 ~/.claude/scripts|data、ssh 遠端 Windows 寫入）只預告不擋，同一個組員一小段時間內的會合成一則。
           開工卡、預告、擋下都會留在收件匣；處理過的用 "\(showork)" captain ack <單號｜all> 標掉，鬧鐘的「未處理」只算沒 ack 的。
        10. 巡檢：看板每 30 分鐘送一則「【巡檢時間】」（人數、ctx、閒置太久的人；跟上次一樣就只寫「無變化」），趁這時候看看有沒有人卡住、ctx 快滿、閒太久。
        11. ctx 自動交接：組員 ctx 到門檻（board.ctxThreshold）會被 Stop hook 請去收尾，收尾完發 wrapup 卡、看板等它停下自動 /clear，新 context 沿用英文名、派工單自動轉給它，你不用重派。
            名冊／巡檢標「已收尾待 /clear」的人不要派新工作（派了就不會自動 /clear，看板會傳「【交接提醒】」給你）；「自動 /clear 失敗」的請\(owner)手動 /clear。
        12. 組員卡片已問使用者的事，隊長卡片不再問；隊長只審問題與選項。使用者在組員卡片答了，看板會傳「【使用者已答】名字：問題→答案」給你，你卡片上同一題會自動清掉。
        取消："\(showork)" task cancel <單號>。
        """
    }

    /// 隊長要知道的狀態：做完、要使用者決定、卡住（做事中不吵）
    public static func shouldNotify(_ t: CaptainTask) -> Bool {
        [.done, .review, .blocked].contains(t.state) && t.notified != t.state
    }

    /// 傳給隊長的回報
    public static func reportText(_ t: CaptainTask, followUp: CaptainTask? = nil) -> String {
        var s = "【派工回報 \(t.id)】\(t.to)：\(t.state.title)" + (t.summary.map { "——\($0)" } ?? "")
        if let a = t.ask { s += "\n要使用者決定：\(a)" }
        s += "\n原任務：\(t.text.replacingOccurrences(of: "\n", with: " ").prefix(120))"
        if let f = followUp { s += "\n已自動接力：\(f.id) 交給 \(f.to)" }
        return s
    }

    /// 接力：A 做完 ⇒ 開給 B 的單（附上 A 的回報）
    public static func nextLeg(of t: CaptainTask, id: String, now: Date) -> CaptainTask? {
        guard t.state == .done, t.followUp == nil, let to = t.thenTo, let text = t.thenText else { return nil }
        let full = text + "\n（前一棒 \(t.to) 已完成「\(t.text.replacingOccurrences(of: "\n", with: " ").prefix(80))」，回報：\(t.summary ?? "沒有摘要")）"
        return CaptainTask(id: id, from: t.from, to: to, project: nil, text: full, createdAt: now, after: t.id)
    }

    /// 建單＋直送；送不出去時單子照樣留著（sendError），讓呼叫端改走 SendMessage
    public static func dispatch(_ t: CaptainTask, showork: String, fromName: String = "AI工作戰情中心") -> (CaptainTask, Result<String, CardError>) {
        var t = t
        let target = Peer.find(t.toSession ?? t.to) ?? Peer.find(t.to)
        if let r = target { t.toSession = r.sessionId; t.to = r.name ?? t.to }
        let replyTo = Peer.find(t.from)?.messagingSocketPath
        let result: Result<String, CardError> = target.map { Peer.send(to: $0, text: message(t, showork: showork), fromName: fromName, replyTo: replyTo) }
            ?? .failure(CardError("找不到開著的 session「\(t.to)」"))
        if case .failure(let e) = result { t.sendError = e.message } else { t.sendError = nil }
        CaptainStore.save(t)
        return (t, result)
    }
}

// MARK: - 讀寫（CLI 與 agent 共用）

public enum CaptainStore {
    /// 10-21 CPU：看板每輪都讀；只有 mtime／大小變了的檔才重新解碼（取樣裡 JSON 解碼是讀檔路徑的大宗之一）
    nonisolated(unsafe) private static var taskCache: [String: (stamp: String, task: CaptainTask)] = [:]
    private static let taskLock = NSLock()
    public static func tasks() -> [CaptainTask] {
        let fm = FileManager.default, dec = BoardJSON.decoder
        let base = Captain.tasksDir.path
        taskLock.lock(); defer { taskLock.unlock() }
        var out: [CaptainTask] = [], seen = Set<String>()
        for f in (try? fm.contentsOfDirectory(atPath: base)) ?? [] where f.hasSuffix(".json") {
            let path = base + "/" + f
            guard let st = FileStat.lstat(path)?.stamp else { continue }
            seen.insert(path)
            if let c = taskCache[path], c.stamp == st { out.append(c.task); continue }
            guard let t = fm.contents(atPath: path).flatMap({ try? dec.decode(CaptainTask.self, from: $0) }) else { continue }
            taskCache[path] = (st, t); out.append(t)
        }
        taskCache = taskCache.filter { seen.contains($0.key) }
        return out.sorted { $0.createdAt < $1.createdAt }
    }

    public static func task(_ id: String) -> CaptainTask? {
        (try? Data(contentsOf: Captain.tasksDir.appendingPathComponent(id + ".json"))).flatMap { try? BoardJSON.decoder.decode(CaptainTask.self, from: $0) }
    }

    @discardableResult
    public static func save(_ t: CaptainTask) -> Bool {
        try? FileManager.default.createDirectory(at: Captain.tasksDir, withIntermediateDirectories: true)
        guard let d = try? BoardJSON.encoder.encode(t) else { return false }
        return (try? d.write(to: Captain.tasksDir.appendingPathComponent(t.id + ".json"), options: .atomic)) != nil
    }

    public static func captain() -> CaptainRecord? {
        (try? Data(contentsOf: Captain.captainFile)).flatMap { try? BoardJSON.decoder.decode(CaptainRecord.self, from: $0) }
    }

    @discardableResult
    public static func setCaptain(_ r: CaptainRecord) -> Bool {
        try? FileManager.default.createDirectory(at: Captain.dir, withIntermediateDirectories: true)
        guard let d = try? BoardJSON.encoder.encode(r) else { return false }
        return (try? d.write(to: Captain.captainFile, options: .atomic)) != nil
    }

    public static func roster() -> Roster? {
        (try? Data(contentsOf: Captain.rosterFile)).flatMap { try? BoardJSON.decoder.decode(Roster.self, from: $0) }
    }

    public static func saveRoster(_ r: Roster) {
        try? FileManager.default.createDirectory(at: Captain.dir, withIntermediateDirectories: true)
        if let d = try? BoardJSON.encoder.encode(r) { try? d.write(to: Captain.rosterFile, options: .atomic) }
    }
}
