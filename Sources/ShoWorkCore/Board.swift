import Foundation

// 戰情中心（Board）：把本機每個 Claude Code session 排進五欄看板。
// 這裡只有純邏輯（解析＋分欄），讀檔與畫面在 ShoWorkAgent。資料來源（10-08 實測，Claude Code 2.1.29x）：
//   ~/.claude/sessions/<pid>.json             每個開著的 session：status busy/idle/shell、啟動 cwd
//   ~/.claude/projects/<slug>/<sid>.jsonl     對話紀錄：ai-title、每筆 cwd/timestamp、queue-operation
//   ~/.claude/teams/<team>/config.json        agent team 成員（session 一關整個資料夾刪掉）
//   ~/.claude/teams/<team>/inboxes/<名>.json  隊員信箱（讀過就清空）

public enum BoardColumn: String, Codable, Sendable, CaseIterable {
    case todo, active, review, done, stuck

    public var title: String {
        switch self {
        case .todo: "待辦"
        case .active: "進行中"
        case .review: "待審"
        case .done: "完成"
        case .stuck: "卡住"
        }
    }
    public var symbol: String {
        switch self {
        case .todo: "tray"
        case .active: "circle.dotted.circle"
        case .review: "hand.raised.fill"
        case .done: "checkmark.circle.fill"
        case .stuck: "exclamationmark.triangle.fill"
        }
    }
}

/// `~/.claude/sessions/<pid>.json`
public struct SessionRecord: Codable, Sendable, Equatable {
    public var pid: Int32
    public var sessionId: String
    public var cwd: String
    public var name: String?
    public var status: String?
    public var kind: String?
    public var entrypoint: String?         // "sdk-cli"＝`claude -p` 這類無頭呼叫（審核員、秘書…），不上看板
    public var updatedAt: Double?          // ms
    public var statusUpdatedAt: Double?    // ms
    public var messagingSocketPath: String?  // 跨 session 訊息的收件 socket（Claude Code 內建 SendMessage 用的）

    public init(pid: Int32, sessionId: String, cwd: String, name: String? = nil, status: String? = nil,
                kind: String? = nil, updatedAt: Double? = nil, statusUpdatedAt: Double? = nil) {
        self.pid = pid; self.sessionId = sessionId; self.cwd = cwd; self.name = name; self.status = status
        self.kind = kind; self.updatedAt = updatedAt; self.statusUpdatedAt = statusUpdatedAt
    }

    public static func decode(_ d: Data) -> SessionRecord? { try? JSONDecoder().decode(SessionRecord.self, from: d) }

    /// `~/.claude/projects/` 底下的資料夾名：啟動 cwd 裡英數字以外的字元（`/`、`.`、中文⋯）全換成 `-`
    /// （10-08 實測：`accept/C-快做完` → `accept-C----`）
    public var projectSlug: String {
        String(cwd.unicodeScalars.map { ($0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "-")) ? Character($0) : "-" })
    }
}

/// 某個時間點 session 在哪個資料夾
public struct CwdMark: Sendable, Equatable {
    public var cwd: String
    public var at: Date?
    public init(cwd: String, at: Date?) { self.cwd = cwd; self.at = at }
}

/// 從對話紀錄尾端抽出看板要的東西
public struct TranscriptInfo: Sendable, Equatable {
    public var title: String?
    public var lastCwd: String?
    public var lastWorkCwd: String?         // 最後一個「做事的地方」：略過 ~/.claude、暫存資料夾（10-08：寫記憶時 cd 進 memory，專案名變成 memory）
    public var recentWorkCwds: [CwdMark] = []  // 最近幾筆做事的地方＋時間（10-13：cd 出去一下又回來，娃娃會跑到別座島再跑回來）
    public var lastPrompt: String?
    public var lastPromptAt: Date?          // 你最後一次送出訊息的時間（判斷自報是不是這一輪的）
    public var lastAssistantText: String?
    public var lastActivity: Date?
    public var queued: [String] = []        // 排隊中、AI 還沒拿去做的訊息
    public var pending: [PendingTool] = []  // 還沒拿到結果的工具呼叫（照呼叫順序；10-20）
    public var asyncAgents: [AsyncAgent] = []   // 背景跑的子 agent，還沒收到完成通知（10-20）
    public var lastSignal: BlockedReason?   // 最後一筆是 API 錯誤（額度／其他）或工具被拒（權限）；之後有新對話就清掉（10-20）
    public var awaitingReply = false        // 最後一筆是你的話或工具結果（AI 還沒接話）；AI 講完一段就變 false（10-20）
    public var tokens: TokenUsage?          // 整個檔案累計（BoardReader 增量算，不在 parse 裡；10-20）

    public struct AsyncAgent: Sendable, Equatable {
        public var id: String; public var info: SubagentInfo
        public var launchedAt: Date? = nil      // 啟動時間（全檔追蹤用：太久沒收到完成通知就當作已經不在了）
    }

    public init() {}

    /// `tail` 是 jsonl 的尾端（可能從某行中間開始，第一行壞掉就略過）
    public static func parse(_ tail: Data) -> TranscriptInfo {
        var p = Parser()
        p.feed(tail)
        return p.info
    }

    /// 可以接著餵的解析器（10-21 CPU：AI 工作時對話紀錄幾秒就長一點，原本每次都重讀尾端 512KB 整段重新解析；
    /// 改成記住解析到哪、只餵新增的完整行）。結果跟把同一段資料一次 parse 完全一樣
    public struct Parser: Sendable {
        var t = TranscriptInfo()
        var queue: [String?] = []           // nil = 系統自動排的（task-notification），不算待辦
        public init() {}
        public var info: TranscriptInfo { var r = t; r.queued = queue.compactMap { $0 }; return r }
        public mutating func feed(_ data: Data) {
            TranscriptInfo.consume(data, &t, &queue)
        }
    }

    static func consume(_ tail: Data, _ t: inout TranscriptInfo, _ queue: inout [String?]) {
        for raw in tail.split(separator: 0x0A) {
            guard let o = try? JSONSerialization.jsonObject(with: Data(raw)) as? [String: Any] else { continue }
            if let c = o["cwd"] as? String {
                t.lastCwd = c
                if !Self.isToolDir(c) {
                    t.lastWorkCwd = c
                    t.recentWorkCwds.append(CwdMark(cwd: c, at: (o["timestamp"] as? String).flatMap(Self.iso)))
                    if t.recentWorkCwds.count > Self.cwdWindow { t.recentWorkCwds.removeFirst() }
                }
            }
            if let ts = o["timestamp"] as? String, let d = Self.iso(ts) { t.lastActivity = max(t.lastActivity ?? d, d) }
            switch o["type"] as? String {
            case "ai-title": if let s = o["aiTitle"] as? String, !s.isEmpty { t.title = s }
            case "custom-title": if let s = o["customTitle"] as? String, !s.isEmpty { t.title = s }
            case "last-prompt": if let s = o["lastPrompt"] as? String { t.lastPrompt = s }
            case "queue-operation":
                switch o["operation"] as? String {
                case "enqueue":
                    let c = o["content"] as? String
                    queue.append(c.flatMap { Self.isSystemMessage($0) ? nil : $0 })
                case "dequeue", "remove", "popAll": if !queue.isEmpty { queue.removeFirst() }
                default: break
                }
                if let c = o["content"] as? String, let id = Self.taskId(c) { t.asyncAgents.removeAll { $0.id == id } }   // 背景 agent 做完
            case "user":
                if o["isSidechain"] as? Bool == true { break }
                let content = (o["message"] as? [String: Any])?["content"]
                if let c = content as? String, let id = Self.taskId(c) { t.asyncAgents.removeAll { $0.id == id } }
                for p in (content as? [[String: Any]]) ?? [] where p["type"] as? String == "tool_result" {
                    guard let id = p["tool_use_id"] as? String, let k = t.pending.firstIndex(where: { $0.id == id }) else { continue }
                    let done = t.pending.remove(at: k)
                    // 背景 agent／workflow：結果馬上回 async_launched，之後 task-notification（task-id＝agentId 或 taskId）才算做完
                    if done.isAgent || done.name == "Workflow", let r = o["toolUseResult"] as? [String: Any],
                       r["status"] as? String == "async_launched" || r["isAsync"] as? Bool == true,
                       let aid = (r["agentId"] ?? r["taskId"]) as? String {
                        let desc = done.description ?? (r["workflowName"] ?? r["summary"] ?? r["description"]) as? String ?? ""
                        t.asyncAgents.append(AsyncAgent(id: aid, info: SubagentInfo(description: desc, subagentType: done.subagentType ?? r["taskType"] as? String, background: true)))
                    }
                }
                if content is [[String: Any]] || (content as? String).map({ !Self.isSystemMessage($0) }) == true { t.awaitingReply = true }
                // 被拒：user-rejected／permission-rule／automode-blocked＝權限；interrupted 是回應被中途停掉（實測是安全分類器），不是權限（10-20 審查）
                if o["isMeta"] as? Bool != true {
                    t.lastSignal = (o["toolDenialKind"] as? String).map { $0 == "interrupted" ? .apiError : .permission }
                }
                // 剛開的 session 還沒有 ai-title／last-prompt，用你最後打的那句當標題
                if let m = o["message"] as? [String: Any], let c = m["content"] as? String,
                   !isSystemMessage(c), !c.isEmpty {
                    t.lastPrompt = c
                    if let ts = o["timestamp"] as? String { t.lastPromptAt = Self.iso(ts) }
                }
            case "assistant":
                if o["isSidechain"] as? Bool == true { break }
                if let m = o["message"] as? [String: Any], let parts = m["content"] as? [[String: Any]] {
                    let text = parts.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
                        .joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                    t.lastSignal = o["isApiErrorMessage"] as? Bool == true ? BlockedReason.of(apiError: o, text: text) : nil
                    if !text.isEmpty { t.lastAssistantText = text }
                    t.awaitingReply = false
                    for p in parts where p["type"] as? String == "tool_use" {
                        guard let id = p["id"] as? String, let name = p["name"] as? String, !t.pending.contains(where: { $0.id == id }) else { continue }
                        let inp = p["input"] as? [String: Any]
                        t.pending.append(PendingTool(id: id, name: name, command: inp?["command"] as? String,
                                                     description: inp?["description"] as? String, subagentType: inp?["subagent_type"] as? String))
                    }
                }
            default: break
            }
        }
    }

    /// 系統自動排進來的（task-notification、跨 session 的閒置／送達通知），不是你交代的事
    public static func isSystemMessage(_ s: String) -> Bool {
        s.hasPrefix("<") || s.hasPrefix("[Cross-session")
    }

    public static let cwdWindow = 400

    /// 從對話紀錄抽出每一筆的 cwd＋時間（不解析整行 JSON：讀圖的那幾行一行幾百 KB）。
    /// 只認最外層的 `"cwd":"`——字串裡面的引號是跳脫過的，不會誤認。略過 ~/.claude、暫存資料夾。
    public static func workCwds(_ d: Data) -> [CwdMark] {
        var out: [CwdMark] = []
        d.withUnsafeBytes { (b: UnsafeRawBufferPointer) in
            /// 從 from 開始找 `"key":"值"`，回傳值（找不到 nil）
            func value(_ key: [UInt8], _ from: Int, _ to: Int) -> String? {
                var i = from
                while i + key.count < to {
                    var hit = true
                    for k in 0..<key.count where b[i + k] != key[k] { hit = false; break }
                    if hit {
                        var j = i + key.count
                        while j < to, b[j] != 0x22 { if b[j] == 0x5C { j += 1 }; j += 1 }
                        guard j < to else { return nil }
                        return try? JSONDecoder().decode(String.self, from: Data(b[(i + key.count - 1)...j]))
                    }
                    i += 1
                }
                return nil
            }
            let cwdKey = Array(#""cwd":""#.utf8), tsKey = Array(#""timestamp":""#.utf8)
            var start = 0
            while start < b.count {
                var end = start
                while end < b.count, b[end] != 0x0A { end += 1 }
                if let c = value(cwdKey, start, end), !isToolDir(c) {
                    out.append(CwdMark(cwd: c, at: value(tsKey, start, end).flatMap(iso)))
                }
                start = end + 1
            }
        }
        return out
    }

    /// 不代表「在做哪個案子」的資料夾
    public static func isToolDir(_ p: String) -> Bool {
        p.contains("/.claude/") || p.hasSuffix("/.claude") || p.hasPrefix("/private/tmp/") || p.hasPrefix("/tmp/") || p.hasPrefix("/var/folders/")
    }

    /// 10-20：每次呼叫都 new 一個 formatter 很貴（取樣時佔讀檔 CPU 大半），改共用兩個（ISO8601DateFormatter 執行緒安全）
    static func iso(_ s: String) -> Date? { isoFrac.date(from: s) ?? isoPlain.date(from: s) }
    nonisolated(unsafe) private static let isoFrac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }()
    nonisolated(unsafe) private static let isoPlain = ISO8601DateFormatter()
}

/// `~/.claude/teams/<team>/config.json` 裡的一個成員
public struct TeamMember: Codable, Sendable, Equatable, Hashable {
    public var agentId: String
    public var name: String
    public var agentType: String?
    public var color: String?
    public var model: String?
    public var joinedAt: Double?
}

public struct TeamConfig: Codable, Sendable, Equatable {
    public var name: String
    public var leadSessionId: String?
    public var members: [TeamMember]

    public static func decode(_ d: Data) -> TeamConfig? { try? JSONDecoder().decode(TeamConfig.self, from: d) }
    /// 隊長以外的人
    public var teammates: [TeamMember] { members.filter { $0.agentType != "team-lead" } }
}

/// 信箱裡的一則訊息（`inboxes/<to>.json` 是這種東西的陣列）
public struct TeamMessage: Codable, Sendable, Equatable, Hashable {
    public var from: String
    public var text: String
    public var summary: String?
    public var timestamp: String?
    public var msg_id: String?
    public var to: String?                  // 不在檔案裡，讀檔時補上信箱主人

    public init(from: String, text: String, summary: String? = nil, timestamp: String? = nil, msg_id: String? = nil, to: String? = nil) {
        self.from = from; self.text = text; self.summary = summary; self.timestamp = timestamp; self.msg_id = msg_id; self.to = to
    }

    public static func decodeInbox(_ d: Data, owner: String) -> [TeamMessage] {
        ((try? JSONDecoder().decode([TeamMessage].self, from: d)) ?? []).map { var m = $0; m.to = owner; return m }
    }
    public var key: String { msg_id ?? "\(from)>\(to ?? "")@\(timestamp ?? "")" }
}

/// 看板上的一張卡
public struct BoardCard: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var column: BoardColumn
    public var reason: String              // 為什麼在這欄（一行白話）
    public var project: String
    public var title: String
    public var detail: String?             // 最後一句 AI 說的話、或排隊中的訊息
    public var lastActivity: Date?
    public var pid: Int32
    public var sessionId: String
    public var teammates: [String] = []
    public var messages: [TeamMessage] = []
    public var cwd: String?                // 專案資料夾（審核、新任務用）
    public var kind: String?               // interactive／bg
    public var report: SelfReport?         // 這一輪的自報（舊的不放）
    public var review: Review?             // 這一輪的審核
    public var ctx: ContextUse?            // context 用量（狀態列存的）
    public var name: String? = nil         // session 名（SendMessage 的地址，例如 you-9e）
    public var captain = false             // 是不是隊長
    public var sameProject: [String] = []  // 同專案的其他 session（重工警告）
    public var tasks: [CaptainTask] = []   // 隊長：派出去的單；其他人：交給它、還沒結束的單
    public var visiting: String? = nil     // 人還住在 project，但最近 cd 去逛的另一個專案（島上畫影分身）
    public var unused = false              // 開了 claude 但從來沒交代過事（連對話紀錄都沒有）：島上畫睡覺
    public var activity: AIActivity = .none        // 現在在做哪一類動作（只有進行中有值，其餘 none；10-20）
    public var blockedReason: BlockedReason? = nil // 卡住／等你回答的原因（判不出就 nil；10-20）
    public var subagents: [SubagentInfo] = []      // 進行中的子 agent（10-20）
    public var tokens: TokenUsage? = nil           // 這個 session 累計 token（10-20）
    public var permit: PermitRequest? = nil        // 終端機開著的權限對話框（PermissionRequest hook；10-21）
    public var handover: String? = nil             // 自動交接狀態（「已收尾待 /clear」⋯；Handover.swift）
}

extension BoardCard {
    /// 有預設值的欄位缺了也讀得回來（舊版存的 JSON 沒有 10-20 之後的新欄位）
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        column = try c.decode(BoardColumn.self, forKey: .column)
        reason = try c.decode(String.self, forKey: .reason)
        project = try c.decode(String.self, forKey: .project)
        title = try c.decode(String.self, forKey: .title)
        detail = try c.decodeIfPresent(String.self, forKey: .detail)
        lastActivity = try c.decodeIfPresent(Date.self, forKey: .lastActivity)
        pid = try c.decode(Int32.self, forKey: .pid)
        sessionId = try c.decode(String.self, forKey: .sessionId)
        teammates = try c.decodeIfPresent([String].self, forKey: .teammates) ?? []
        messages = try c.decodeIfPresent([TeamMessage].self, forKey: .messages) ?? []
        cwd = try c.decodeIfPresent(String.self, forKey: .cwd)
        kind = try c.decodeIfPresent(String.self, forKey: .kind)
        report = try c.decodeIfPresent(SelfReport.self, forKey: .report)
        review = try c.decodeIfPresent(Review.self, forKey: .review)
        ctx = try c.decodeIfPresent(ContextUse.self, forKey: .ctx)
        name = try c.decodeIfPresent(String.self, forKey: .name)
        captain = try c.decodeIfPresent(Bool.self, forKey: .captain) ?? false
        sameProject = try c.decodeIfPresent([String].self, forKey: .sameProject) ?? []
        tasks = try c.decodeIfPresent([CaptainTask].self, forKey: .tasks) ?? []
        visiting = try c.decodeIfPresent(String.self, forKey: .visiting)
        unused = try c.decodeIfPresent(Bool.self, forKey: .unused) ?? false
        activity = try c.decodeIfPresent(AIActivity.self, forKey: .activity) ?? .none
        blockedReason = try c.decodeIfPresent(BlockedReason.self, forKey: .blockedReason)
        subagents = try c.decodeIfPresent([SubagentInfo].self, forKey: .subagents) ?? []
        tokens = try c.decodeIfPresent(TokenUsage.self, forKey: .tokens)
        permit = try c.decodeIfPresent(PermitRequest.self, forKey: .permit)
        handover = try c.decodeIfPresent(String.self, forKey: .handover)
    }
}

public enum Board {
    /// 進行中卻這麼久沒新紀錄 ⇒ 卡住
    public static let stuckAfter: TimeInterval = 10 * 60

    /// 一個 session 放哪一欄。`glow` 是 ShoWork 自己的發光狀態（hook 事件，比 status 檔即時）。
    public static func column(status: String?, glow: WorkState?, lastActivity: Date?, now: Date) -> (BoardColumn, String) {
        if glow == .input { return (.review, "等你回答") }
        // status "shell"＝這一輪做完了、但還有背景指令在跑（10-08 實測：ProjectA 那條掛了 3 個背景 zsh 一天多），不算忙
        if status == "busy" || glow == .working {
            if let t = lastActivity, now.timeIntervalSince(t) > stuckAfter {
                return (.stuck, "\(Int(now.timeIntervalSince(t) / 60)) 分鐘沒有新動靜")
            }
            return (.active, "工作中")
        }
        if glow == .waiting { return (.stuck, "在等外部的事") }   // 橘：AI 自報 blocked
        if glow == .done { return (.review, "做完了，你還沒看") }
        return (.done, status == "shell" ? "閒置（背景指令還在跑）" : "閒置")
    }

    /// 卡片上的摘要：拿掉 Markdown 記號（標題 #、粗體 **、程式碼 `、清單 -、表格 |），換行併成一行
    public static func plain(_ s: String) -> String {
        var lines: [String] = []
        for var l in s.split(whereSeparator: \.isNewline).map(String.init) {
            l = l.trimmingCharacters(in: .whitespaces)
            while l.hasPrefix("#") || l.hasPrefix(">") { l.removeFirst() }
            if l.hasPrefix("- ") || l.hasPrefix("* ") { l.removeFirst(2) }
            if l.allSatisfy({ "|-: ".contains($0) }) { continue }       // 表格分隔線
            l = l.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "")
                .replacingOccurrences(of: "|", with: " ").trimmingCharacters(in: .whitespaces)
            if !l.isEmpty { lines.append(l) }
        }
        return lines.joined(separator: " ")
    }

    /// 專案名：往上找 .git 的資料夾名；家目錄本身不算專案
    public static func projectName(cwd: String?, home: String, isRepo: (String) -> Bool) -> String {
        guard var p = cwd, !p.isEmpty else { return "（不明）" }
        let start = p
        while p.count > 1 {
            if p == home { break }
            if isRepo(p) { return (p as NSString).lastPathComponent }
            p = (p as NSString).deletingLastPathComponent
        }
        if start == home { return "（家目錄）" }
        return (start as NSString).lastPathComponent
    }

    /// 這個 session「住」哪個專案：在一個地方連續待滿 `settle` 秒才算搬家；cd 出去一下（回家目錄、看別的 repo）
    /// 不算——那是「逛」（visiting，島上畫影分身）。往回找最近一段待夠久的就是住的地方；都沒有就取待最多筆的，家目錄最後才算。
    public static func stickyProject(_ marks: [CwdMark], fallback: String?, home: String, settle: TimeInterval = 300,
                                     isRepo: (String) -> Bool) -> String {
        whereabouts(marks, fallback: fallback, home: home, settle: settle, isRepo: isRepo).home
    }

    public static func whereabouts(_ marks: [CwdMark], fallback: String?, home: String, settle: TimeInterval = 300,
                                   isRepo: (String) -> Bool) -> (home: String, visiting: String?) {
        guard !marks.isEmpty else { return (projectName(cwd: fallback, home: home, isRepo: isRepo), nil) }
        var cache: [String: String] = [:]
        let names = marks.map { m in cache[m.cwd] ?? { let n = projectName(cwd: m.cwd, home: home, isRepo: isRepo); cache[m.cwd] = n; return n }() }
        // 切成一段一段（同一個專案連在一起），每段待多久＝到下一段開始（最後一段到最後一筆）
        var runs: [(name: String, from: Int, to: Int)] = []
        for (i, n) in names.enumerated() {
            if let l = runs.last, l.name == n { runs[runs.count - 1].to = i } else { runs.append((n, i, i)) }
        }
        func lasted(_ k: Int) -> TimeInterval {
            let r = runs[k]
            guard let a = marks[r.from].at, let b = (k + 1 < runs.count ? marks[runs[k + 1].from].at : marks[r.to].at) else {
                return Double(r.to - r.from + 1) * 15                  // 沒時間戳：一筆當 15 秒
            }
            return b.timeIntervalSince(a)
        }
        let last = runs[runs.count - 1].name
        if runs.count == 1 { return (last, nil) }
        if let k = runs.indices.reversed().first(where: { lasted($0) >= settle }) {
            let stay = runs[k].name
            return (stay, last == stay ? nil : last)
        }
        var count: [String: Int] = [:]
        for n in names { count[n, default: 0] += 1 }
        let others = count.filter { $0.key != "（家目錄）" }
        let pool = others.isEmpty ? count : others
        let lastIndex = Dictionary(names.enumerated().map { ($1, $0) }, uniquingKeysWith: max)
        let stay = pool.max { ($0.value, lastIndex[$0.key] ?? 0) < ($1.value, lastIndex[$1.key] ?? 0) }!.key
        return (stay, last == stay ? nil : last)
    }

    /// 組出整個看板：每個 session 一張卡，再加上排隊中的訊息各一張待辦卡
    public static func build(sessions: [SessionRecord], transcripts: [String: TranscriptInfo],
                             glows: [Int32: WorkState], teams: [TeamConfig], inbox: [TeamMessage],
                             reports: [String: SelfReport] = [:], reviews: [String: Review] = [:], decisions: [String: Decision] = [:],
                             contexts: [String: ContextUse] = [:], nicknames: [String: Nickname] = [:],
                             now: Date, home: String, isRepo: (String) -> Bool) -> [BoardCard] {
        var out: [BoardCard] = []
        for s in sessions.sorted(by: { ($0.updatedAt ?? 0) > ($1.updatedAt ?? 0) }) where s.entrypoint != "sdk-cli" {
            let t = transcripts[s.sessionId] ?? TranscriptInfo()
            var base = column(status: s.status, glow: glows[s.pid], lastActivity: t.lastActivity, now: now)
            // 10-20 審查：在等子 agent／workflow 回來時主 session 本來就不寫東西，不算卡住（實測主控 session 開完 workflow 被誤判卡住）
            if base.0 == .stuck && t.isDelegating { base = (.active, "交辦中，等子 agent 回來") }
            let report = CardRules.fresh(reports[s.sessionId], t.lastPromptAt)
            let (col, why) = CardRules.column(base: base, glow: glows[s.pid], report: report, decision: decisions[s.sessionId],
                                              lastPrompt: t.lastPromptAt, lastActivity: t.lastActivity)
            let review = reviews[s.sessionId].flatMap { r in (t.lastPromptAt.map { r.turn >= $0 } ?? true) ? r : nil }
            let (project, visiting) = whereabouts(t.recentWorkCwds, fallback: t.lastCwd ?? s.cwd, home: home, isRepo: isRepo)
            let team = teams.first { $0.leadSessionId == s.sessionId }
            let names = team?.teammates.map(\.name) ?? []
            let msgs = team == nil ? [] : inbox.filter { m in names.contains(m.from) || names.contains(m.to ?? "") }
            out.append(BoardCard(id: s.sessionId, column: col, reason: why, project: project,
                                 title: Nicknames.title(nicknames[s.sessionId], fallback: t.title ?? t.lastPrompt.map { String($0.prefix(40)) } ?? (s.name ?? "未命名")),
                                 detail: t.lastAssistantText.map { String(plain($0).prefix(240)) },
                                 lastActivity: t.lastActivity, pid: s.pid, sessionId: s.sessionId,
                                 teammates: names, messages: Array(msgs.suffix(5)),
                                 cwd: t.lastWorkCwd ?? t.lastCwd ?? s.cwd, kind: s.kind, report: report, review: review,
                                 ctx: contexts[s.sessionId], name: s.name))
            if col == .active { out[out.count - 1].visiting = visiting }
            out[out.count - 1].unused = t.lastActivity == nil && t.lastPrompt == nil   // 只有正在做事才有影分身，閒著不留幽靈
            // 10-20：動作／卡住原因／子 agent／token。同步子 agent 只在主 session 還沒停時算（停了還掛著＝被中斷的殘留）
            let waiting = col == .review && glows[s.pid] == .input
            out[out.count - 1].activity = col == .active ? t.currentActivity : .none
            out[out.count - 1].blockedReason = t.blockedReason(waiting: waiting, stuck: col == .stuck)
            out[out.count - 1].subagents = t.subagents(includeSync: col == .active || col == .stuck || waiting)
            out[out.count - 1].tokens = t.tokens
            for (i, q) in t.queued.enumerated() {
                out.append(BoardCard(id: "\(s.sessionId)#q\(i)", column: .todo, reason: "排隊中，等這個 AI 有空", project: project,
                                     title: String(q.prefix(60)), detail: q.count > 60 ? q : nil, lastActivity: nil,
                                     pid: s.pid, sessionId: s.sessionId, cwd: t.lastCwd ?? s.cwd, kind: s.kind))
            }
        }
        return out
    }
}
