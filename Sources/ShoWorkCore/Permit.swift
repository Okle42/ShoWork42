import Foundation

// 權限允許搬到戰情中心（10-21 第 2 步）：PermissionRequest hook（`showork permit`）把「要執行什麼」寫成一個檔，
// 戰情中心收件匣顯示「允許／一律允許／拒絕」，按下去寫回答檔，hook 讀到就回 decision 給 Claude Code。
// 10-21 實測（2.1.306，虛擬終端）：
//   • 終端機的允許對話框和 hook 同時出現；hook 等 15 秒才回 allow，Claude 照樣接受 ⇒ 兩邊都能按
//   • 終端機先按：hook 不會被砍，之後回的 decision 被忽略 ⇒ hook 自己看 transcript 出現這個 tool_use 的結果就收掉
// 檔案都在 board/permits/：<id>.json（請求）、<id>.answer.json（回答）。
// 10-25 選擇題與計畫確認也走這條（2.1.310 實測，scratchpad 假名 session）：AskUserQuestion／ExitPlanMode 都會跳 PermissionRequest，
//   回 allow＋updatedInput（原輸入＋answers）⇒ AI 收到的 tool_result 跟真人在終端機選的一模一樣；ExitPlanMode 回 allow＝核准計畫。
//   多選題的答案給陣列（每個都是選項 label）；不在選項裡的字（「其他」）AI 會收到「The user answered: …」，一樣照做。
//   從戰情中心替使用者回答的，每一筆記在 board/permits/answers.jsonl（欄位同 releases.jsonl）。

public struct PermitRequest: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var sessionId: String
    public var pid: Int32?            // AI 行程（死了就收掉）
    public var tool: String
    public var summary: String        // 要執行的東西：指令、檔案路徑、網址⋯
    public var detail: String?        // AI 自己寫的說明（Bash 的 description）
    public var cwd: String?
    public var alwaysRules: String?   // 「一律允許」要套的 permission_suggestions（addRules，JSON 陣列原文）
    public var at: Date
    public var questions: [AskQuestion]? = nil   // AskUserQuestion 的題目（10-25）
    public var input: String? = nil              // AskUserQuestion／ExitPlanMode 的 tool_input 原文：回答時改好當 updatedInput

    public var isAsk: Bool { tool == "AskUserQuestion" }
    public var isPlan: Bool { tool == "ExitPlanMode" }
    /// ExitPlanMode 的計畫內容
    public var plan: String? {
        guard isPlan, let s = input, let o = try? JSONSerialization.jsonObject(with: Data(s.utf8)) as? [String: Any] else { return nil }
        return (o["plan"] as? String).flatMap { $0.isEmpty ? nil : $0 }
    }

    public init(id: String, sessionId: String, pid: Int32?, tool: String, summary: String, detail: String? = nil,
                cwd: String? = nil, alwaysRules: String? = nil, at: Date) {
        self.id = id; self.sessionId = sessionId; self.pid = pid; self.tool = tool; self.summary = summary
        self.detail = detail; self.cwd = cwd; self.alwaysRules = alwaysRules; self.at = at
    }

    /// 「一律允許」會加的規則，給人看的樣子：Bash(mkdir:*)
    public var alwaysLabel: String? {
        guard let s = alwaysRules, let a = try? JSONSerialization.jsonObject(with: Data(s.utf8)) as? [[String: Any]] else { return nil }
        let xs = a.flatMap { ($0["rules"] as? [[String: Any]]) ?? [] }.compactMap { r -> String? in
            guard let t = r["toolName"] as? String else { return nil }
            return (r["ruleContent"] as? String).map { "\(t)(\($0))" } ?? t
        }
        return xs.isEmpty ? nil : xs.joined(separator: "、")
    }
}

/// AskUserQuestion 的一題
public struct AskQuestion: Codable, Sendable, Equatable, Hashable {
    public struct Option: Codable, Sendable, Equatable, Hashable {
        public var label: String
        public var description: String?
        public init(label: String, description: String? = nil) { self.label = label; self.description = description }
    }
    public var question: String
    public var header: String?
    public var multiSelect: Bool
    public var options: [Option]
    public init(question: String, header: String? = nil, multiSelect: Bool = false, options: [Option]) {
        self.question = question; self.header = header; self.multiSelect = multiSelect; self.options = options
    }

    /// tool_input.questions → 題目（格式不對的題目略過）
    public static func parse(_ input: [String: Any]) -> [AskQuestion] {
        ((input["questions"] as? [[String: Any]]) ?? []).compactMap { q in
            guard let text = q["question"] as? String, !text.isEmpty else { return nil }
            let opts = ((q["options"] as? [[String: Any]]) ?? []).compactMap { o in
                (o["label"] as? String).map { Option(label: $0, description: (o["description"] as? String).flatMap { $0.isEmpty ? nil : $0 }) }
            }
            return AskQuestion(question: text, header: (q["header"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                               multiSelect: q["multiSelect"] as? Bool ?? false, options: opts)
        }
    }
}

public struct PermitAnswer: Codable, Sendable, Equatable {
    public enum Decision: String, Codable, Sendable { case allow, always, deny }
    public var decision: Decision
    public var message: String?
    public var answers: [String: [String]]? = nil   // 選擇題：題目 → 選的（單選一個、多選多個、「其他」是自己打的字）
    public init(_ decision: Decision, message: String? = nil, answers: [String: [String]]? = nil) {
        self.decision = decision; self.message = message; self.answers = answers
    }
}

public enum Permit {
    /// hook 最久等多久（之後終端機對話框還在，只是戰情中心不能按了）
    public static let maxWait: TimeInterval = 3600
    /// 超過這麼久的請求檔當成殘留（hook 當掉沒收）
    public static let staleAfter: TimeInterval = maxWait + 60

    public static var dir: URL { Paths.supportDir.appendingPathComponent("board/permits", isDirectory: true) }
    public static func requestURL(_ id: String, dir: URL = dir) -> URL { dir.appendingPathComponent(id + ".json") }
    public static func answerURL(_ id: String, dir: URL = dir) -> URL { dir.appendingPathComponent(id + ".answer.json") }

    /// hook 的 stdin JSON → 請求（不是 PermissionRequest 或缺 session 就 nil）
    public static func request(hook o: [String: Any], pid: Int32?, now: Date = Date()) -> PermitRequest? {
        guard let sid = o["session_id"] as? String, !sid.isEmpty, let tool = o["tool_name"] as? String else { return nil }
        let input = o["tool_input"] as? [String: Any] ?? [:]
        let rules = (o["permission_suggestions"] as? [[String: Any]] ?? []).filter { ($0["type"] as? String) == "addRules" }
        let rulesText = rules.isEmpty ? nil : (try? JSONSerialization.data(withJSONObject: rules)).flatMap { String(data: $0, encoding: .utf8) }
        let ms = Int(now.timeIntervalSince1970 * 1000)
        var r = PermitRequest(id: "\(sid.prefix(8))-\(ms)", sessionId: sid, pid: pid, tool: tool,
                              summary: summary(tool: tool, input: input), detail: (input["description"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                              cwd: o["cwd"] as? String, alwaysRules: rulesText, at: now)
        if tool == "AskUserQuestion" || tool == "ExitPlanMode" {
            r.input = (try? JSONSerialization.data(withJSONObject: input)).flatMap { String(data: $0, encoding: .utf8) }
            r.alwaysRules = nil
            if tool == "AskUserQuestion" {
                let qs = AskQuestion.parse(input)
                guard !qs.isEmpty else { return nil }
                r.questions = qs
                r.summary = qs.map(\.question).joined(separator: "／")
            } else {
                r.summary = "計畫寫好了，要照這個做嗎？"
            }
        }
        return r
    }

    /// 要執行的東西，一行（太長截斷）
    public static func summary(tool: String, input: [String: Any]) -> String {
        let keys = ["command", "file_path", "notebook_path", "url", "query", "pattern", "path", "prompt"]
        let s = keys.lazy.compactMap { input[$0] as? String }.first { !$0.isEmpty }
            ?? (try? JSONSerialization.data(withJSONObject: input, options: [.sortedKeys])).flatMap { String(data: $0, encoding: .utf8) }
            ?? ""
        return s.count > 600 ? String(s.prefix(600)) + "⋯" : s
    }

    /// 回給 Claude Code 的 hook 輸出
    public static func hookOutput(_ a: PermitAnswer, request r: PermitRequest) -> String {
        var d: [String: Any]
        switch a.decision {
        case .allow where r.isAsk || r.isPlan:
            // 選擇題：把答案填進原輸入（多選給陣列、單選給字串）；計畫確認：原輸入照樣放行＝核准
            var input = r.input.flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] } ?? [:]
            if r.isAsk {
                let multi = Dictionary((r.questions ?? []).map { ($0.question, $0.multiSelect) }, uniquingKeysWith: { a, _ in a })
                var ans: [String: Any] = [:]
                for (q, v) in a.answers ?? [:] where !v.isEmpty { ans[q] = multi[q] == true ? v : v.joined(separator: ", ") }
                input["answers"] = ans
            }
            d = ["behavior": "allow", "updatedInput": input]
        case .allow: d = ["behavior": "allow"]
        case .always:
            d = ["behavior": "allow"]
            if let s = r.alwaysRules, let rules = try? JSONSerialization.jsonObject(with: Data(s.utf8)) { d["updatedPermissions"] = rules }
        case .deny:
            let m = a.message.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty ? nil : $0 }
            if r.isPlan {
                d = ["behavior": "deny", "message": m.map { "使用者在戰情中心退回這份計畫，要你照這句修改後再提：\($0)" } ?? "使用者在戰情中心退回這份計畫，先不要動手。"]
            } else if r.isAsk {
                d = ["behavior": "deny", "message": m.map { "使用者沒有選選項，在戰情中心回你：\($0)" } ?? "使用者在戰情中心選擇不回答這題。"]
            } else {
                d = ["behavior": "deny", "message": m.map { "使用者在戰情中心按了拒絕，並說：\($0)" } ?? "使用者在戰情中心按了拒絕。"]
            }
        }
        let o: [String: Any] = ["hookSpecificOutput": ["hookEventName": "PermissionRequest", "decision": d]]
        return (try? JSONSerialization.data(withJSONObject: o)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }

    // MARK: 終端機先答了沒（看 transcript）

    /// transcript 尾端裡，這次要求權限的 tool_use id（從後往前找同名、同輸入的那一個）
    public static func toolUseId(transcript tail: Data, tool: String, input: [String: Any]) -> String? {
        for line in tail.split(separator: UInt8(ascii: "\n")).reversed() {
            guard line.count < 4 << 20, let o = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  o["type"] as? String == "assistant",
                  let content = (o["message"] as? [String: Any])?["content"] as? [[String: Any]] else { continue }
            for c in content.reversed() where c["type"] as? String == "tool_use" && c["name"] as? String == tool {
                if let i = c["input"] as? [String: Any], NSDictionary(dictionary: i).isEqual(to: input), let id = c["id"] as? String { return id }
            }
        }
        return nil
    }

    /// 新增的 transcript 內容裡有沒有這個 tool_use 的結果（允許後跑完、被拒絕、被中斷都會寫 tool_result）
    /// 找不到 id 時退而求其次：出現任何 tool_result 就算
    public static func resolved(appended: Data, toolUseId: String?) -> Bool {
        let s = String(decoding: appended, as: UTF8.self)
        if let id = toolUseId { return s.contains("\"tool_use_id\":\"\(id)\"") }
        return s.contains("\"type\":\"tool_result\"")
    }

    // MARK: 讀寫（hook 和戰情中心共用）

    /// 還在等的請求（每個 session 最新的一個）
    public static func pending(dir: URL = dir, now: Date = Date()) -> [String: PermitRequest] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { return [:] }
        var out: [String: PermitRequest] = [:]
        for n in names where n.hasSuffix(".json") && !n.hasSuffix(".answer.json") {
            guard let d = try? Data(contentsOf: dir.appendingPathComponent(n)),
                  let r = try? BoardJSON.decoder.decode(PermitRequest.self, from: d),
                  now.timeIntervalSince(r.at) < staleAfter,
                  !fm.fileExists(atPath: answerURL(r.id, dir: dir).path) else { continue }
            if let o = out[r.sessionId], o.at > r.at { continue }
            out[r.sessionId] = r
        }
        return out
    }

    public static func write(_ r: PermitRequest, dir: URL = dir) -> Bool {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        guard let d = try? BoardJSON.encoder.encode(r) else { return false }
        return (try? d.write(to: requestURL(r.id, dir: dir), options: .atomic)) != nil
    }

    /// 戰情中心按下去：寫回答檔（請求已經收掉就不寫，回 false）
    @discardableResult
    public static func answer(_ id: String, _ a: PermitAnswer, dir: URL = dir) -> Bool {
        guard FileManager.default.fileExists(atPath: requestURL(id, dir: dir).path), let d = try? JSONEncoder().encode(a) else { return false }
        return (try? d.write(to: answerURL(id, dir: dir), options: .atomic)) != nil
    }

    /// 選擇題／計畫確認從戰情中心回答的紀錄（board/permits/answers.jsonl，欄位同 releases.jsonl）
    public static func logAnswer(_ r: PermitRequest, _ a: PermitAnswer, now: Date = Date(), dir: URL = dir) {
        guard r.isAsk || r.isPlan else { return }
        let rec = ReleaseRecord(at: now, id: r.id, by: "board", byName: "使用者（戰情中心）", target: r.sessionId,
                                summary: answerText(r, a), source: r.isAsk ? "戰情中心選擇題" : "戰情中心計畫確認")
        guard var d = try? BoardJSON.encoder.encode(rec) else { return }
        d.append(0x0A)
        let url = dir.appendingPathComponent("answers.jsonl")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let h = try? FileHandle(forWritingTo: url) { _ = try? h.seekToEnd(); try? h.write(contentsOf: d); try? h.close() }
        else { try? d.write(to: url, options: .atomic) }
    }

    /// 一行：哪題、答什麼
    public static func answerText(_ r: PermitRequest, _ a: PermitAnswer) -> String {
        if r.isPlan { return a.decision == .deny ? "退回計畫" + (a.message.map { "：\($0)" } ?? "") : "核准計畫" }
        if a.decision == .deny { return "不選選項" + (a.message.map { "，回：\($0)" } ?? "") }
        return (r.questions ?? []).map { q in "\(q.question) → \((a.answers?[q.question] ?? []).joined(separator: "、"))" }.joined(separator: "；")
    }

    public static func readAnswer(_ id: String, dir: URL = dir) -> PermitAnswer? {
        (try? Data(contentsOf: answerURL(id, dir: dir))).flatMap { try? JSONDecoder().decode(PermitAnswer.self, from: $0) }
    }

    public static func remove(_ id: String, dir: URL = dir) {
        try? FileManager.default.removeItem(at: requestURL(id, dir: dir))
        try? FileManager.default.removeItem(at: answerURL(id, dir: dir))
    }
}
