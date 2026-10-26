import Foundation

// 戰情中心：從對話紀錄多看出四件事（10-20）——AI 現在在做哪一類動作、卡住／等你的原因、進行中的子 agent、累計 token。
// 欄位名以 10-20 實測（Claude Code 2.1.29x）為準：
//   assistant 行：message.content[] 裡 {"type":"tool_use","id","name","input"}；message.usage 有四種 token；
//                 同一則訊息每個 content 區塊各寫一行、usage 重複（message.id 相同）⇒ 要用 id 去重
//   user 行：message.content[] 裡 {"type":"tool_result","tool_use_id"}；被拒時最外層有 "toolDenialKind"
//            （user-rejected／permission-rule／interrupted）；背景 agent 的結果最外層 toolUseResult
//            {"isAsync":true,"status":"async_launched","agentId"}
//   API 錯誤：assistant 行最外層 "isApiErrorMessage":true、"error"（rate_limit／server_error／authentication_failed…）、
//            額度用完時另有 "apiErrorStatus":"429"、文字「You've hit your session limit」
//   背景 agent 做完：queue-operation／user 行的內容是 <task-notification><task-id>agentId</task-id>…

/// AI「現在」在做的工具動作（只有進行中的卡片有意義，其餘一律 none）
public enum AIActivity: String, Codable, Sendable, CaseIterable {
    case none, reading, editing, running, searching, thinking, delegating

    /// 工具名 → 動作分類；不認得的（Bash、MCP 工具、Monitor⋯）都算「執行」
    public static func of(tool: String, subagentType: String? = nil) -> AIActivity {
        switch tool {
        case "Read", "Grep", "Glob", "NotebookRead", "WebFetch", "LS", "ListMcpResourcesTool", "ReadMcpResourceTool":
            return .reading
        case "Edit", "Write", "MultiEdit", "NotebookEdit":
            return .editing
        case "WebSearch", "ToolSearch":
            return .searching
        case "Agent", "Task":
            return subagentType == "Explore" ? .searching : .delegating
        case "Workflow":
            return .delegating
        case "AskUserQuestion", "ExitPlanMode":
            return .thinking                                    // 在問你；正常會被光暈判成「等你回答」，不會落到進行中
        default:
            return tool.lowercased().contains("search") ? .searching : .running
        }
    }
}

/// 卡住／等你的原因（判不出就是 nil，不硬編；unknown 留給畫面相容，解析不會產生）
public enum BlockedReason: String, Codable, Sendable, CaseIterable {
    case permission, rateLimit, apiError, testRun, build, install, unknown

    /// 跑很久的 Bash 指令看關鍵字分類（測試 → 建置 → 安裝的順序；`swift build && swift test` 算測試）
    public static func of(command: String) -> BlockedReason? {
        let words = Set(command.lowercased().split { !($0.isLetter || $0.isNumber || $0 == "_") }.map(String.init))
        if !words.isDisjoint(with: ["test", "tests", "pytest", "jest", "vitest", "xctest", "unittest", "rspec"]) { return .testRun }
        if !words.isDisjoint(with: ["build", "xcodebuild", "make", "cmake", "ninja", "gradle", "gradlew", "bazel", "compile", "archive"]) { return .build }
        if !words.isDisjoint(with: ["install", "pip", "pip3", "brew", "npm", "pnpm", "yarn", "bun", "pod", "apt", "uv"])
            && (words.contains("install") || words.contains("add") || words.contains("i") || words.contains("ci") || words.contains("sync")) { return .install }
        return nil
    }

    /// API 錯誤那一行 → 額度（429／rate_limit／usage limit）或其他 API 錯誤
    static func of(apiError o: [String: Any], text: String?) -> BlockedReason {
        let err = (o["error"] as? String ?? "").lowercased()
        let status = (o["apiErrorStatus"] as? String) ?? (o["apiErrorStatus"] as? NSNumber)?.stringValue
        let t = (text ?? "").lowercased()
        if err.contains("rate_limit") || status == "429" || o["quotaLimits"] != nil
            || t.contains("rate limit") || t.contains("usage limit") || t.contains("session limit") || t.contains("429") {
            return .rateLimit
        }
        return .apiError
    }
}

/// 進行中的子 agent
public struct SubagentInfo: Codable, Sendable, Equatable, Hashable {
    public var description: String        // tool input 的 description（截 30 字）
    public var subagentType: String?      // general-purpose、Explore⋯
    public var background = false         // run_in_background：主 session 停了它還在跑

    public init(description: String, subagentType: String? = nil, background: Bool = false) {
        self.description = String(description.prefix(30)); self.subagentType = subagentType; self.background = background
    }
}

/// 還沒拿到 tool_result 的工具呼叫
public struct PendingTool: Sendable, Equatable {
    public var id: String
    public var name: String
    public var command: String?           // Bash 的 command
    public var description: String?
    public var subagentType: String?
    public var isAgent: Bool { name == "Agent" || name == "Task" }
}

/// 這個 session 累計的 token（不算錢：訂閱制）
public struct TokenUsage: Codable, Sendable, Equatable {
    public var input = 0
    public var output = 0
    public var cacheCreation = 0
    public var cacheRead = 0
    public var lastTurnOutput = 0         // 你最後一次送出訊息之後，AI 產出的 output token
    public var total: Int { input + output + cacheCreation + cacheRead }

    public init(input: Int = 0, output: Int = 0, cacheCreation: Int = 0, cacheRead: Int = 0, lastTurnOutput: Int = 0) {
        self.input = input; self.output = output; self.cacheCreation = cacheCreation; self.cacheRead = cacheRead
        self.lastTurnOutput = lastTurnOutput
    }
}

/// token 增量累加：整個檔案從頭掃一次，之後只餵新增的完整行。
/// 不解析整行 JSON：先用位元組找 `"role":"assistant"`（assistant 行都很小，10-20 實測 176MB 的檔 assistant 行合計 1MB），
/// 讀圖的 user 行一行幾百 KB，直接跳過。
public struct TokenTally: Sendable, Equatable {
    public private(set) var usage = TokenUsage()
    private var seen = Set<String>()
    /// 背景 agent／workflow：整個檔案一起追（10-20 審查：只看尾端 512KB 會漏掉——主 session 開完 workflow 又聊了 1.8MB，啟動那行就看不到了）
    public private(set) var asyncAgents: [TranscriptInfo.AsyncAgent] = []
    public init() {}

    static let roleKey = Array(#""role":"assistant""#.utf8)
    static let usageKey = Array(#""usage""#.utf8)
    static let userKey = Array(#""type":"user""#.utf8)
    static let resultKey = Array(#""tool_use_id""#.utf8)
    static let launchKey = Array(#""status":"async_launched""#.utf8)
    static let notifyKey = Array("<task-id>".utf8)

    /// `d` 必須是完整的行（最後一行沒寫完的不要傳進來）
    public mutating func consume(_ d: Data) {
        d.withUnsafeBytes { (b: UnsafeRawBufferPointer) in
            guard let base = b.baseAddress else { return }
            var start = 0
            while start < b.count {
                let rest = b.count - start
                let nl = memchr(base + start, 0x0A, rest).map { $0 - UnsafeMutableRawPointer(mutating: base) } ?? b.count
                let len = nl - start
                if len > 0 { line(base + start, len) }
                start = nl + 1
            }
        }
    }

    private static func has(_ p: UnsafeRawPointer, _ n: Int, _ k: [UInt8]) -> Bool {
        k.withUnsafeBytes { memmem(p, n, $0.baseAddress, k.count) != nil }
    }

    private mutating func line(_ p: UnsafeRawPointer, _ n: Int) {
        if Self.has(p, n, Self.launchKey) { launched(p, n); return }
        if Self.has(p, n, Self.notifyKey), !Self.has(p, n, Self.roleKey) { notified(p, n) }
        if Self.has(p, n, Self.roleKey) && Self.has(p, n, Self.usageKey) {
            guard let o = try? JSONSerialization.jsonObject(with: Data(bytes: p, count: n)) as? [String: Any],
                  o["isSidechain"] as? Bool != true,
                  let m = o["message"] as? [String: Any], let u = m["usage"] as? [String: Any] else { return }
            if let id = m["id"] as? String { guard seen.insert(id).inserted else { return } }
            func i(_ k: String) -> Int { (u[k] as? NSNumber)?.intValue ?? 0 }
            usage.input += i("input_tokens"); usage.output += i("output_tokens")
            usage.cacheCreation += i("cache_creation_input_tokens"); usage.cacheRead += i("cache_read_input_tokens")
            usage.lastTurnOutput += i("output_tokens")
        } else if n < 256 * 1024, Self.has(p, n, Self.userKey), !Self.has(p, n, Self.resultKey) {
            guard let o = try? JSONSerialization.jsonObject(with: Data(bytes: p, count: n)) as? [String: Any],
                  o["type"] as? String == "user", o["isMeta"] as? Bool != true, o["isSidechain"] as? Bool != true,
                  o["isCompactSummary"] as? Bool != true,                  // context 壓縮後的摘要不是你送的
                  let m = o["message"] as? [String: Any] else { return }
            if TranscriptInfo.isPrompt(m["content"]) { usage.lastTurnOutput = 0 }
        }
    }
}

extension TokenTally {
    /// tool_result 的 toolUseResult.status＝async_launched：記住 agentId／taskId（description／workflowName 都在這一行）
    private mutating func launched(_ p: UnsafeRawPointer, _ n: Int) {
        guard let o = try? JSONSerialization.jsonObject(with: Data(bytes: p, count: n)) as? [String: Any],
              o["type"] as? String == "user", o["isSidechain"] as? Bool != true,
              let r = o["toolUseResult"] as? [String: Any], r["status"] as? String == "async_launched",
              let id = (r["agentId"] ?? r["taskId"]) as? String, !asyncAgents.contains(where: { $0.id == id }) else { return }
        let desc = (r["description"] ?? r["workflowName"] ?? r["summary"]) as? String ?? ""
        let at = (o["timestamp"] as? String).flatMap(TranscriptInfo.iso)
        asyncAgents.append(.init(id: id, info: SubagentInfo(description: desc, subagentType: r["taskType"] as? String, background: true), launchedAt: at))
    }
    /// queue-operation 或 user 行的 <task-notification><task-id>X</task-id>：X 做完了
    private mutating func notified(_ p: UnsafeRawPointer, _ n: Int) {
        guard !asyncAgents.isEmpty,
              let o = try? JSONSerialization.jsonObject(with: Data(bytes: p, count: n)) as? [String: Any],
              o["isSidechain"] as? Bool != true else { return }
        let c = (o["content"] as? String) ?? ((o["message"] as? [String: Any])?["content"] as? String) ?? ""
        if let id = TranscriptInfo.taskId(c) { asyncAgents.removeAll { $0.id == id } }
    }
}

extension TranscriptInfo {
    /// 你親手送出的訊息（不是工具結果、不是系統通知）
    static func isPrompt(_ content: Any?) -> Bool {
        if let s = content as? String { return !s.isEmpty && !isSystemMessage(s) }
        guard let parts = content as? [[String: Any]] else { return false }
        if parts.contains(where: { $0["type"] as? String == "tool_result" }) { return false }
        return parts.contains { p in p["type"] as? String == "text" && !((p["text"] as? String).map(isSystemMessage) ?? true) }
    }

    /// 最後一個還沒拿到結果的工具 → 現在在做什麼；沒有的話：AI 講完了但背景 agent／workflow 還在跑 ⇒ 交辦中，
    /// 其餘就是在想（剛收到你的話、或剛講完一段還在忙）
    public var currentActivity: AIActivity {
        guard let p = pending.last else { return !awaitingReply && !asyncAgents.isEmpty ? .delegating : .thinking }
        return AIActivity.of(tool: p.name, subagentType: p.subagentType)
    }

    /// 正在等子 agent：同步的 Agent／Workflow 還沒回結果，或還有背景的沒收到完成通知
    public var isDelegating: Bool {
        !asyncAgents.isEmpty || pending.contains { $0.isAgent || $0.name == "Workflow" }
    }

    /// 進行中的子 agent：同步的（Agent 還沒回結果，`includeSync`＝主 session 還在忙才算）＋背景的（還沒收到完成通知）
    public func subagents(includeSync: Bool) -> [SubagentInfo] {
        let sync = includeSync ? pending.filter(\.isAgent).map { SubagentInfo(description: $0.description ?? "", subagentType: $0.subagentType) } : []
        return sync + asyncAgents.map(\.info)
    }

    /// 卡住／等你的原因。`waiting`＝光暈紅（等你回答）；`stuck`＝卡住欄
    public func blockedReason(waiting: Bool, stuck: Bool) -> BlockedReason? {
        if waiting {
            if let p = pending.last, p.name != "AskUserQuestion", p.name != "ExitPlanMode" { return .permission }   // 工具在等你按允許
            return lastSignal
        }
        if stuck {
            if let p = pending.last, p.name == "Bash", let c = p.command, let r = BlockedReason.of(command: c) { return r }
            return lastSignal
        }
        return nil
    }

    /// `<task-notification><task-id>X</task-id>` 裡的 X
    static func taskId(_ s: String) -> String? {
        guard s.hasPrefix("<task-notification>"), let a = s.range(of: "<task-id>"),
              let b = s.range(of: "</task-id>", range: a.upperBound..<s.endIndex) else { return nil }
        return String(s[a.upperBound..<b.lowerBound])
    }
}
