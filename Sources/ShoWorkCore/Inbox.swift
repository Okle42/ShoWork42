import Foundation

// 收件匣（10-21 Kang：「我一直在操作終端機，戰情中心是不是失去使用意義？」）：
// 所有在等你的 AI 排成一列，問題、快速選項、直接打字都在戰情中心裡做完，不用切回終端機。
//   reply：AI 講完一輪、在一般輸入框等你（要你決定）⇒ 可以按選項或打字，送進它的 session
//   permit：權限允許對話框（PermissionRequest hook 有寫請求檔）⇒ 允許／一律允許／拒絕，直接回給 Claude Code（第 2 步，Permit.swift）
//   ask  ：AI 用 AskUserQuestion 出選擇題（hook 有寫請求檔）⇒ 按選項／勾多選／打「其他」，回給 Claude Code（10-25）
//   plan ：AI 用 ExitPlanMode 交計畫（hook 有寫請求檔）⇒ 核准／退回並說要改什麼（10-25）
//   menu ：終端機裡開了選單但沒接到 hook（session 開在安裝前）⇒ 打字進去會被當選項鍵，只能跳到視窗

public struct InboxItem: Sendable, Equatable, Identifiable {
    public enum Kind: Sendable, Equatable { case reply, permit, ask, plan, menu }
    public var id: String
    public var card: BoardCard
    public var kind: Kind
    public var question: String
    public var context: String?        // AI 最後講的話（問題沒寫清楚時看這個）
    public var options: [String]
    public var generic: Bool           // AI 沒給選項：用通用的「好／先不要」
    public var since: Date?
    public var answered: Date?         // 你從戰情中心回答過、它還沒動：顯示「已送出」
}

public enum Inbox {
    public static let genericOptions = ["好，照你的建議做", "先不要，等我想一下"]

    /// - Parameter answered: sessionId → 你從戰情中心回答的時間
    public static func items(_ cards: [BoardCard], answered: [String: Date] = [:]) -> [InboxItem] {
        let out: [InboxItem] = cards.compactMap { c in
            if let p = c.permit {   // 對話框開著就列，不管看板顏色（Notification 比 hook 晚到）
                let a = answered[c.sessionId].flatMap { t in t > p.at ? t : nil }
                let kind: InboxItem.Kind = p.isAsk ? .ask : p.isPlan ? .plan : .permit
                let q = p.isAsk ? "它問你" : p.isPlan ? "計畫寫好了，要照這個做嗎？" : "要\(Inbox.toolVerb(p.tool))，可以嗎？"
                return InboxItem(id: c.id, card: c, kind: kind, question: q, context: p.isAsk || p.isPlan ? nil : p.detail,
                                 options: [], generic: false, since: p.at, answered: a)
            }
            guard Mood.of(c) == .waiting else { return nil }
            let reply = c.reason.hasPrefix("要你決定")
            let ask = c.report?.ask?.trimmingCharacters(in: .whitespacesAndNewlines)
            let q: String
            if let ask, !ask.isEmpty { q = ask }
            else if reply { q = String(c.reason.dropFirst("要你決定：".count)) }
            else { q = c.blockedReason == .permission ? "它在等你按允許" : "它在終端機開了選單等你選" }
            let opts = reply ? (c.report?.options ?? []) : []
            let since = c.report?.at ?? c.lastActivity
            let a = answered[c.sessionId].flatMap { t in t > (since ?? .distantPast) ? t : nil }
            let ctx = c.detail.flatMap { d in d.isEmpty || d == q ? nil : d }
            return InboxItem(id: c.id, card: c, kind: reply ? .reply : .menu, question: q, context: ctx,
                             options: reply ? (opts.isEmpty ? genericOptions : opts) : [], generic: reply && opts.isEmpty,
                             since: since, answered: a)
        }
        // 還沒回答的在前；同一組裡等最久的在前
        return out.sorted { a, b in
            if (a.answered == nil) != (b.answered == nil) { return a.answered == nil }
            return (a.since ?? .distantFuture) < (b.since ?? .distantFuture)
        }
    }

    /// 權限對話框標題用的動詞
    public static func toolVerb(_ tool: String) -> String {
        switch tool {
        case "Bash": return "執行指令"
        case "Edit", "MultiEdit": return "修改檔案"
        case "Write": return "寫入檔案"
        case "Read": return "讀取檔案"
        case "NotebookEdit": return "修改筆記本"
        case "WebFetch": return "開網頁"
        case "WebSearch": return "上網搜尋"
        default: return tool.hasPrefix("mcp__") ? "用工具 \(tool.split(separator: "__").dropFirst().joined(separator: "・"))" : "用 \(tool)"
        }
    }

    /// 送給 AI 的那句話（選項按鈕和打字同一條路）
    public static func message(_ text: String) -> String {
        text.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 拖檔案進輸入框（10-25）：把路徑接在已經打的字後面，跟拖進終端機一樣，AI 會自己去讀。
    /// 路徑有空白或 shell 特殊字元就用單引號包起來（單引號本身寫成 '\''）；中文不用包
    public static func withPaths(_ text: String, _ paths: [String]) -> String {
        let ps = paths.filter { !$0.isEmpty }.map(quote).joined(separator: " ")
        guard !ps.isEmpty else { return text }
        if text.isEmpty { return ps + " " }
        return text + (text.hasSuffix(" ") || text.hasSuffix("\n") ? "" : " ") + ps + " "
    }

    static func quote(_ p: String) -> String {
        let special = Set(" \t\n'\"\\$`!&*()[]{};<>?|#~")
        guard p.contains(where: { special.contains($0) }) else { return p }
        return "'" + p.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

/// 隊長（10-21 Kang：隊長的大腦用當下最高的模型）：戰情中心「交給隊長」找不到隊長時，自己開一個背景隊長
public enum CaptainLaunch {
    public static let defaultModel = "claude-fable-5-1"
    public static let modelKey = "captain.model"

    /// 背景隊長的第一句話：登記、守則，以及它看不到終端機 ⇒ 所有要跟使用者講的都走 showork card
    public static func bootstrap(showork: String, task: String) -> String {
        """
        你是 AI 工作戰情中心的隊長（背景 session，使用者看不到你的終端機）。
        1. 先跑：\"\(showork)\" captain（登記成隊長並印出守則），照守則做事：先看 \"\(showork)\" roster，選人後用 \"\(showork)\" task add 派工；同專案只派一個；小事自己做。
        2. 你要跟使用者講的話，一律用 \"\(showork)\" card 回報（--summary 寫結果；要他決定就 --status review --ask "<問題>" --options "<選項1>|<選項2>"）。他在戰情中心看卡片、按選項回答你。
        3. 之後使用者從戰情中心交辦的事，會以【使用者從看板交辦】的訊息送進來，一樣照守則處理。
        使用者交辦的第一件事：\(task)
        """
    }
}
