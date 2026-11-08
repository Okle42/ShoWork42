import Foundation

// 戰情中心 P2：AI 自報（showork card）、另一個 AI 的審核、你的決定（放行／丟待辦）。
// 三種東西都以 sessionId 為鍵存在 ~/Library/Application Support/ShoWork42/board/ 底下各一個資料夾。
// 「這一輪」的判準：記錄時間晚於該 session 最後一次你送出訊息的時間才算數，舊的一律不用。

/// AI 每輪結束時用 `showork card` 回報的東西
public struct SelfReport: Codable, Sendable, Equatable {
    public enum Status: String, Codable, Sendable, CaseIterable { case working, review, done, blocked }
    public var status: Status
    public var progress: Int?          // 0–100
    public var confidence: Int?        // 0–100
    public var summary: String?
    public var ask: String?            // 要你決定／回答的事
    public var report: String?         // 報告檔路徑
    public var task: String?           // 隊長派工單號（--task）
    public var doing: String?          // 正在做的任務（--doing，卡片標題「英文名-任務」用，見 Nickname.swift）
    public var options: [String]?      // --ask 的快速選項（--options "A|B|C"，戰情中心收件匣按一下就回答；10-21）
    public var how: String?            // 這一輪用的方法與工具（--how，轉送給隊長審；CardRelay.swift）
    // 開工卡（T1024033803 ①：使用者直接下指令後、動手前先發；轉給隊長時前綴【開工】）
    public var kind: String?           // --kind start（開工卡）／wrapup（ctx 收尾完，Handover.swift）
    public var handoff: String?        // --handoff 交接文件絕對路徑（wrapup 必帶）
    public var touch: String?          // --touch 會動到哪些檔／repo／系統設定
    public var outward: String?        // --outward 要不要 push、部署、對外傳訊息
    public var at: Date
    public var isStart: Bool { kind == "start" }
    public var isWrapup: Bool { kind == "wrapup" }

    public init(status: Status, progress: Int? = nil, confidence: Int? = nil, summary: String? = nil,
                ask: String? = nil, report: String? = nil, task: String? = nil, doing: String? = nil, options: [String]? = nil, how: String? = nil,
                kind: String? = nil, touch: String? = nil, outward: String? = nil, handoff: String? = nil, at: Date = Date()) {
        self.status = status; self.progress = progress.map(Self.clamp); self.confidence = confidence.map(Self.clamp)
        self.summary = summary; self.ask = ask; self.report = report; self.task = task; self.doing = doing
        self.options = options.flatMap(Self.cleanOptions); self.how = how; self.at = at
        self.kind = kind; self.touch = touch; self.outward = outward; self.handoff = handoff
    }
    static func clamp(_ v: Int) -> Int { min(100, max(0, v)) }

    /// 選項：去空白、去重複、最多 4 個、每個最多 40 字（按鈕放得下）；全空就 nil
    public static func cleanOptions(_ xs: [String]) -> [String]? {
        var out: [String] = []
        for x in xs.map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) }) where !x.isEmpty && !out.contains(x) && out.count < 4 {
            out.append(String(x.prefix(40)))
        }
        return out.isEmpty ? nil : out
    }

    /// `showork card` 的參數 → 回報；格式錯回傳錯誤訊息（給 AI 看得懂的中文）
    public static func parse(args: [String], now: Date = Date()) -> Result<SelfReport, CardError> {
        var a = args[...], status: Status?, p: Int?, c: Int?, s: String?, ask: String?, r: String?, task: String?, doing: String?, opts: [String]?, how: String?
        var kind: String?, touch: String?, outward: String?, handoff: String?
        func text(_ v: String) -> String? { let t = v.trimmingCharacters(in: .whitespacesAndNewlines); return t.isEmpty ? nil : t }
        while let k = a.popFirst() {
            guard let v = a.popFirst() else { return .failure(.init("\(k) 後面少了值")) }
            switch k {
            case "--status": guard let x = Status(rawValue: v) else { return .failure(.init("--status 只能是 working／review／done／blocked")) }; status = x
            case "--progress": guard let x = Int(v.trimmingCharacters(in: CharacterSet(charactersIn: "% "))) else { return .failure(.init("--progress 要是 0–100 的數字")) }; p = x
            case "--confidence": guard let x = Int(v.trimmingCharacters(in: CharacterSet(charactersIn: "% "))) else { return .failure(.init("--confidence 要是 0–100 的數字")) }; c = x
            case "--summary": s = v
            case "--ask": ask = v.isEmpty ? nil : v
            case "--report": r = v.isEmpty ? nil : v
            case "--task": task = v.isEmpty ? nil : v
            case "--doing": doing = Nicknames.cleanDoing(v)
            case "--options": opts = v.split(separator: "|").map(String.init)
            case "--how": how = v.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : v.trimmingCharacters(in: .whitespacesAndNewlines)
            case "--kind": guard v == "start" || v == "wrapup" else { return .failure(.init("--kind 只有 start（開工卡）／wrapup（收尾完）")) }; kind = v
            case "--handoff": handoff = text(v)
            case "--touch": touch = text(v)
            case "--outward": outward = text(v)
            default: return .failure(.init("不認得的參數 \(k)"))
            }
        }
        // 開工卡沒寫 --status 就當 working；收尾卡當 done，而且一定要給交接文件的絕對路徑
        if kind == "wrapup" {
            guard let h = handoff, h.hasPrefix("/") else { return .failure(.init("--kind wrapup 要帶 --handoff <交接文件絕對路徑>")) }
            guard FileManager.default.fileExists(atPath: h) else { return .failure(.init("找不到交接文件：\(h)")) }
        }
        guard let status = status ?? (kind == "start" ? .working : kind == "wrapup" ? .done : nil) else { return .failure(.init("缺 --status")) }
        return .success(SelfReport(status: status, progress: p, confidence: c, summary: s, ask: ask, report: r, task: task, doing: doing,
                                       options: ask == nil ? nil : opts, how: how, kind: kind, touch: touch, outward: outward, handoff: handoff, at: now))
    }
}

public struct CardError: Error, Equatable, Sendable { public let message: String; public init(_ m: String) { message = m } }

/// 審核員（另一個 AI）的意見
public struct Review: Codable, Sendable, Equatable {
    public var progress: Int?
    public var confidence: Int?
    public var verdict: String         // pass／concern／fail
    public var issues: [String]
    public var turn: Date              // 審的是哪一輪（那輪最後活動時間）
    public var at: Date
    public var model: String
    public var costUSD: Double?
    public var error: String?          // 審核失敗時的原因（卡片上顯示，不重試）

    public init(progress: Int?, confidence: Int?, verdict: String, issues: [String], turn: Date, at: Date = Date(),
                model: String, costUSD: Double? = nil, error: String? = nil) {
        self.progress = progress; self.confidence = confidence; self.verdict = verdict; self.issues = issues
        self.turn = turn; self.at = at; self.model = model; self.costUSD = costUSD; self.error = error
    }
}

/// 你在看板上的決定（session 一有新動靜就失效）
public struct Decision: Codable, Sendable, Equatable {
    public enum Action: String, Codable, Sendable { case approve, park }
    public var action: Action
    public var note: String?
    public var at: Date
    public init(action: Action, note: String? = nil, at: Date = Date()) { self.action = action; self.note = note; self.at = at }
}

/// 看板存檔的 JSON：時間一律帶毫秒（10-08：只存到秒時，審核記的「這一輪」永遠比實際早一點，於是每 20 秒重審一次）
public enum BoardJSON {
    public static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .custom { d, enc in var c = enc.singleValueContainer(); try c.encode(iso.string(from: d)) }
        return e
    }
    public static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { dec in
            let s = try dec.singleValueContainer().decode(String.self)
            guard let v = iso.date(from: s) ?? ISO8601DateFormatter().date(from: s) else {
                throw DecodingError.dataCorrupted(.init(codingPath: dec.codingPath, debugDescription: "bad date \(s)"))
            }
            return v
        }
        return d
    }
    nonisolated(unsafe) static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }()
}

public enum CardRules {
    /// 注入每個新 session 的說明（SessionStart hook 的輸出會進 AI 的 context），越短越省
    public static func brief(showork: String, name: String? = nil) -> String {
        let who = name.map { "你在戰情中心的名字是 \($0)，卡片標題會顯示「\($0)-正在做的任務」。" } ?? "第一次自報後會分到一個英文名，卡片標題顯示「英文名-正在做的任務」。"
        return """
        [ShoWork42 AI工作戰情中心] 每一輪做完事、回覆使用者之前，用 Bash 跑一次（不用跟使用者提）：
        "\(showork)" card --doing "<正在做的任務，10 個字內>" --status <working|review|done|blocked> --progress <0-100> --confidence <0-100> --summary "<一句話：做了什麼、結果>" [--ask "<需要使用者決定或回答的事>" --options "<選項1>|<選項2>"] [--how "<這一輪用的方法與工具，一句話>"] [--report "<報告檔絕對路徑>"]
        \(who)--doing 每次都要帶、寫「現在」手上這件事（換任務就換），使用者靠它做戰情管控。
        status：review＝需要使用者看過或決定；done＝完成、不需要看；blocked＝卡住做不下去，等外部的事（等回信、等背景工作）也用 blocked，終端機會亮橘；working＝還沒做完、會繼續。confidence 是你對「做對了」的把握，要誠實，沒驗證過就不要給高分。有 --ask 時附 2–4 個 --options（| 分隔、每個是完整的一句回答，例如 "好，push|先不要"），使用者會在戰情中心按一下就把那句話送給你。--how 寫這一輪用了什麼方法和工具（例如「讀 3 個檔＋改 Inbox.swift＋swift test」），戰情中心會把卡片轉給隊長審。只是聊天、沒動手做事的回合可省略。
        跟使用者提到其他 AI session 時，一律用英文名（不要說 \(NSUserName())-xx 或 session id）；對照表："\(showork)" names。
        """
    }

    /// 自報＋決定＋光暈 → 欄位。P1 的規則（`Board.column`）是底，這裡疊上這一輪的新資訊。
    /// - Parameters:
    ///   - lastPrompt: 你最後一次送出訊息的時間（之前的自報都算舊的）
    public static func column(base: (BoardColumn, String), glow: WorkState?, report: SelfReport?, decision: Decision?,
                              lastPrompt: Date?, lastActivity: Date?) -> (BoardColumn, String) {
        if glow == .input { return base }                                       // 等你回答永遠最優先
        if base.0 == .active || base.0 == .stuck {
            if let r = fresh(report, lastPrompt), r.status == .blocked { return (.stuck, "AI 自報卡住：\(r.summary ?? "")") }
            return base
        }
        if let d = decision, d.at >= (lastActivity ?? .distantPast) {
            switch d.action {
            case .approve: return (.done, "你已放行")
            case .park: return (.todo, "你丟回待辦" + (d.note.map { "：\($0)" } ?? ""))
            }
        }
        guard let r = fresh(report, lastPrompt) else { return base }
        switch r.status {
        case .review: return (.review, r.ask.map { "要你決定：\($0)" } ?? "AI 請你看過")
        case .blocked: return (.stuck, "AI 自報卡住：\(r.summary ?? "")")
        case .done: return r.ask != nil ? (.review, "要你決定：\(r.ask!)") : (.done, "AI 自報完成")
        case .working: return base
        }
    }

    static func fresh(_ r: SelfReport?, _ lastPrompt: Date?) -> SelfReport? {
        guard let r else { return nil }
        if let p = lastPrompt, r.at < p { return nil }
        return r
    }

    /// 需不需要（再）審：在待審、還沒審過這一輪
    public static func needsReview(column: BoardColumn, review: Review?, turn: Date?) -> Bool {
        guard column == .review, let turn else { return false }
        guard let r = review else { return true }
        return r.turn.addingTimeInterval(1) < turn          // 舊檔只存到秒：差不到 1 秒算同一輪
    }

    /// 給審核員的指示（對話摘錄另外附上）
    public static func reviewPrompt(project: String, title: String, report: SelfReport?, excerpt: String) -> String {
        let self_ = report.map { r in
            "AI 自報：status=\(r.status.rawValue) 完成度=\(r.progress.map(String.init) ?? "?") 信心=\(r.confidence.map(String.init) ?? "?")\n摘要：\(r.summary ?? "")\n" +
            (r.ask.map { "要使用者決定：\($0)\n" } ?? "") + (r.report.map { "報告檔：\($0)\n" } ?? "")
        } ?? "AI 沒有自報。\n"
        return """
        你是審核員。另一個 AI 在專案「\(project)」做「\(title)」，剛結束一輪，請獨立判斷它做得怎樣。
        可以用 Read／Grep／Glob 和 git status／diff／log 查證它說做到的事；不要修改任何檔案。
        \(self_)
        ===== 最近的對話摘錄 =====
        \(excerpt)
        ===== 摘錄結束 =====
        最後只輸出一個 JSON（不要 markdown 圍欄、不要其他字）：
        {"progress": 0-100, "confidence": 0-100, "verdict": "pass|concern|fail", "issues": ["最多 3 條、每條一句繁體中文；沒問題就空陣列"]}
        progress＝你認為真正完成多少；confidence＝你多相信它做對了；只看到宣稱、沒有證據就壓低。
        """
    }

    /// 審核員的輸出 → Review（容許前後夾雜文字或 ```json 圍欄）
    public static func parseReview(_ text: String, turn: Date, model: String, cost: Double?, now: Date = Date()) -> Review? {
        guard let s = text.firstIndex(of: "{"), let e = text.lastIndex(of: "}"), s < e,
              let o = try? JSONSerialization.jsonObject(with: Data(text[s...e].utf8)) as? [String: Any] else { return nil }
        func int(_ k: String) -> Int? { (o[k] as? NSNumber).map { SelfReport.clamp($0.intValue) } }
        let v = (o["verdict"] as? String).flatMap { ["pass", "concern", "fail"].contains($0) ? $0 : nil } ?? "concern"
        return Review(progress: int("progress"), confidence: int("confidence"), verdict: v,
                      issues: Array(((o["issues"] as? [String]) ?? []).prefix(3)), turn: turn, at: now, model: model, costUSD: cost)
    }

    /// 最後一輪（最後一句使用者的話之後）有沒有真的動手：只回話、只發卡片／查名冊／讀通知的「待命」輪不用開審核員。
    /// 尾端找不到使用者那句話（輪太長被截掉）時當作有動手。
    public static func lastTurnDidWork(_ tail: Data) -> Bool {
        var worked = true
        for raw in tail.split(separator: 0x0A) {
            guard let o = try? JSONSerialization.jsonObject(with: Data(raw)) as? [String: Any],
                  let m = o["message"] as? [String: Any] else { continue }
            switch o["type"] as? String {
            case "user":
                if m["content"] is String { worked = false }
                else if let ps = m["content"] as? [[String: Any]], !ps.contains(where: { $0["type"] as? String == "tool_result" }) { worked = false }
            case "assistant":
                for p in (m["content"] as? [[String: Any]]) ?? [] where p["type"] as? String == "tool_use" {
                    let n = p["name"] as? String ?? ""
                    let cmd = ((p["input"] as? [String: Any])?["command"] as? String) ?? ""
                    if ["ListAgents", "ReadNotifications", "ToolSearch"].contains(n) { continue }
                    if n == "Bash", cmd.contains("/showork\""), cmd.contains(" card ") || cmd.contains(" names") { continue }
                    worked = true
                }
            default: break
            }
        }
        return worked
    }

    /// 對話紀錄尾端 → 給審核員看的摘錄（你說的話、AI 說的話、用了哪些工具），最多 `limit` 字
    public static func excerpt(_ tail: Data, limit: Int = 12_000) -> String {
        var out: [String] = []
        for raw in tail.split(separator: 0x0A) {
            guard let o = try? JSONSerialization.jsonObject(with: Data(raw)) as? [String: Any],
                  let m = o["message"] as? [String: Any] else { continue }
            switch o["type"] as? String {
            case "user":
                if let c = m["content"] as? String, !c.hasPrefix("<") { out.append("【使用者】\(c)") }
            case "assistant":
                for p in (m["content"] as? [[String: Any]]) ?? [] {
                    if p["type"] as? String == "text", let t = p["text"] as? String { out.append("【AI】\(t)") }
                    if p["type"] as? String == "tool_use", let n = p["name"] as? String {
                        let inp = (p["input"] as? [String: Any]).flatMap { i in
                            (i["command"] ?? i["file_path"] ?? i["pattern"] ?? i["description"]) as? String } ?? ""
                        out.append("【工具 \(n)】\(inp.prefix(200))")
                    }
                }
            default: break
            }
        }
        var s = out.joined(separator: "\n")
        if s.count > limit { s = "⋯（前面省略）\n" + String(s.suffix(limit)) }
        return s
    }
}

/// 帳號流量（訂閱額度）。Claude Code 只把它交給 statusLine，所以要由 statusLine 腳本存成快照檔：
/// `{"rate_limits":{"five_hour":{"used_percentage":27,"resets_at":1791457200},"seven_day":{…}},"at":"2026-10-08 18:12:08"}`
public struct RateLimits: Sendable, Equatable {
    public struct Window: Sendable, Equatable {
        public var used: Double; public var resetsAt: Date?
        public init(used: Double, resetsAt: Date?) { self.used = used; self.resetsAt = resetsAt }
    }
    public var fiveHour: Window?
    public var sevenDay: Window?
    public var snapshotAt: Date?
    public init(fiveHour: Window? = nil, sevenDay: Window? = nil, snapshotAt: Date? = nil) {
        self.fiveHour = fiveHour; self.sevenDay = sevenDay; self.snapshotAt = snapshotAt
    }

    public static func parse(_ d: Data) -> RateLimits? {
        guard let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let rl = o["rate_limits"] as? [String: Any] else { return nil }
        func w(_ k: String) -> Window? {
            guard let x = rl[k] as? [String: Any], let u = (x["used_percentage"] as? NSNumber)?.doubleValue else { return nil }
            return Window(used: u, resetsAt: (x["resets_at"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) })
        }
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm:ss"; f.locale = Locale(identifier: "en_US_POSIX")
        let r = RateLimits(fiveHour: w("five_hour"), sevenDay: w("seven_day"), snapshotAt: (o["at"] as? String).flatMap(f.date(from:)))
        return r.fiveHour == nil && r.sevenDay == nil ? nil : r
    }

    /// 重置時間已過的視窗，數字已不準，當成 0%（下一次 statusLine 更新就會補正）
    public func current(now: Date) -> RateLimits {
        var r = self
        if let t = r.fiveHour?.resetsAt, t <= now { r.fiveHour = Window(used: 0, resetsAt: nil) }
        if let t = r.sevenDay?.resetsAt, t <= now { r.sevenDay = Window(used: 0, resetsAt: nil) }
        return r
    }
}


/// 每個 session 的 context 用量。Claude Code 只交給 statusLine，由狀態列腳本存成
/// `~/.claude/cache/ctx/<sessionId>.json`：`{"used_percentage": 44, "total_input_tokens": 439517, "at": 1791475515.98}`
public struct ContextUse: Codable, Sendable, Equatable {
    public var percent: Double
    public var tokens: Int?
    public var at: Date?

    public init(percent: Double, tokens: Int? = nil, at: Date? = nil) { self.percent = percent; self.tokens = tokens; self.at = at }

    public static func parse(_ d: Data) -> ContextUse? {
        guard let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let p = (o["used_percentage"] as? NSNumber)?.doubleValue else { return nil }
        return ContextUse(percent: p, tokens: (o["total_input_tokens"] as? NSNumber)?.intValue,
                          at: (o["at"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) })
    }
}

/// ctx 快滿時的收尾（Kang 10-09：超過 85% 提醒我，或幫我 commit、能 push 就 push）
public enum ContextGuard {
    /// 門檻只有一條：context 用到幾 token 就交接（10-26 Kang 加 token 線；10-29 Kang：拿掉 % 保險、只留這一個條件，250k–1000k 自由調）。
    /// 戰情中心工具列調；agent、showork CLI、Stop hook（hook_ctx_wrapup.py）讀同一份設定 board.ctxTokens
    public static let defaultTokenLimit = 250_000
    public static let tokenRange = 250_000...1_000_000
    public static let tokenStep = 10_000
    public static var tokenLimit: Int {
        get { clamp(UserDefaults(suiteName: "ai.okle42.showork")?.integer(forKey: "board.ctxTokens") ?? 0) }
        set { UserDefaults(suiteName: "ai.okle42.showork")?.set(clamp(newValue), forKey: "board.ctxTokens") }
    }
    /// 沒設過（0）用預設；超出範圍的舊值（例如以前的 150k、200k）拉回 250k–1000k，對齊 10k
    public static func clamp(_ v: Int) -> Int {
        guard v > 0 else { return defaultTokenLimit }
        let r = (v + tokenStep / 2) / tokenStep * tokenStep
        return min(max(r, tokenRange.lowerBound), tokenRange.upperBound)
    }
    public static func over(_ c: ContextUse, tokenLimit: Int = tokenLimit) -> Bool {
        (c.tokens ?? 0) >= tokenLimit
    }

    /// 打進那個 session 的收尾指令。push 與否交給那個 session 的 AI 依該 repo 的規則判斷
    /// （ghosts、客戶案等有「不准 push／要先審」的規則，看板不知道，AI 看得到）。
    public static func wrapUpPrompt(tokens: Int) -> String {
        "【AI工作戰情中心】context 已用 \(tokens / 1000)k，請收尾：①把目前該存的進度 commit；②這個 repo 的規則允許才 push（規定不准 push、要先審或有客戶資料的就不要推，回報原因）；③更新交接文件（寫清楚未完成工作與下一步）與記憶；④最後發收尾卡 `showork card --kind wrapup --handoff <交接文件絕對路徑> --doing <任務> --summary \"<一句接手重點>\"`，發完就停下。看板會自動 /clear，新 context 自動讀交接接手（名字、派工單沿用）。"
    }

    /// 現在要不要對這張卡送收尾：超過門檻、還沒送過、它停下來了（不在工作中、也不是在問你問題）
    public static func shouldWrapUp(card: BoardCard, ctx: ContextUse?, alreadySent: Bool, tokenLimit: Int = tokenLimit) -> Bool {
        guard let c = ctx, over(c, tokenLimit: tokenLimit), !alreadySent, !card.id.contains("#") else { return false }
        return card.column != .active && card.reason != "等你回答"
    }
}
