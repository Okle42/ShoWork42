import Foundation

// 第 3 步：直接派工給隊長（10-22）。收件匣的「交給隊長」本來只能送，隊長的回答只在它的終端機裡，
// Kang 只好 attach 到隊長視窗跟它講話。這裡從隊長的對話紀錄（jsonl 尾端）整理出「隊長對話」：
//   • Kang：在隊長終端機打的（origin.kind == human）、從戰情中心送的（peer，from-name「AI工作戰情中心（使用者）」）
//   • 隊長：每一輪最後的那段話（stop_reason == end_turn 的文字）——就是它要講給 Kang 聽的
//   • 回報：其他 AI 的【工作回報】【派工回報】只留第一行，灰色小字；AI 之間的自由訊息只顯示「誰傳來一則訊息」
//   不顯示：工具呼叫的輸入與結果、thinking、每輪中途的話（10-22 隊長審查：工具往返裡有帳號、金鑰路徑、證件檔路徑）
// 10-25 點任何一個 AI 都能在右邊看它的對話（full 模式）：多了每輪中途的話、工具一行摘要（工具名＋AI 自己寫的說明或檔名），
//   工具的輸入原文與結果照樣不顯示。
// 純函式，畫面只負責顯示。

public struct CaptainLine: Sendable, Equatable, Identifiable {
    public enum Role: String, Sendable { case kang, captain, report, tool }
    public var id: String              // 那一行的 uuid（沒有就用時間）
    public var at: Date?
    public var role: Role
    public var text: String
    public var via: String?            // kang：「戰情中心」或「終端機」；report：誰送來的
    public init(id: String, at: Date?, role: Role, text: String, via: String? = nil) {
        self.id = id; self.at = at; self.role = role; self.text = text; self.via = via
    }
}

public enum CaptainThread {
    /// 看板送給隊長時包在外面的字（BoardActions.toCaptain）
    public static let boardPrefix = "【使用者從看板交辦】"
    public static let boardFromName = "AI工作戰情中心（使用者）"
    public static let keep = 40
    public static let keepFull = 120
    /// 戰情中心回答別的 AI 時包在外面的字（BoardActions.answer）
    public static let answerPrefix = "【使用者從戰情中心回答你的問題】"

    nonisolated(unsafe) static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }()

    /// jsonl 尾端（第一行可能不完整，壞的略過）→ 最後 keep 行
    /// - Parameter full: 也收每輪中途的話與工具摘要（右側對話窗格看一般 AI 用）
    public static func parse(_ tail: Data, full: Bool = false) -> [CaptainLine] {
        var out: [CaptainLine] = []
        for raw in tail.split(separator: 0x0A) {
            guard raw.count < 2 << 20, let o = try? JSONSerialization.jsonObject(with: Data(raw)) as? [String: Any] else { continue }
            let type = o["type"] as? String
            let id = o["uuid"] as? String ?? UUID().uuidString
            let at = (o["timestamp"] as? String).flatMap { iso.date(from: $0) }
            let msg = o["message"] as? [String: Any]
            if type == "user", o["isMeta"] as? Bool != true, let origin = o["origin"] as? [String: Any] {
                switch origin["kind"] as? String {
                case "human":
                    guard let t = userText(msg?["content"]), !t.hasPrefix("<") else { continue }
                    out.append(CaptainLine(id: id, at: at, role: .kang, text: t, via: "終端機"))
                case "peer":
                    let name = origin["name"] as? String ?? ""
                    let body = (origin["body"] as? String) ?? peerBody(userText(msg?["content"]) ?? "")
                    if name == boardFromName || body.hasPrefix(boardPrefix) {
                        out.append(CaptainLine(id: id, at: at, role: .kang, text: boardText(body), via: "戰情中心"))
                    } else {
                        // 只留看板格式的摘要行（【工作回報】【派工回報】⋯）；AI 之間的自由訊息可能夾帳號、路徑，只說「誰傳來一則訊息」
                        let first = body.split(whereSeparator: \.isNewline).first.map(String.init) ?? body
                        let text = first.hasPrefix("【") ? String(first.prefix(160)) : "\(name.isEmpty ? "其他 AI" : name) 傳來一則訊息（內容不顯示）"
                        out.append(CaptainLine(id: id, at: at, role: .report, text: text, via: name.isEmpty ? nil : name))
                    }
                default: continue
                }
            } else if full, type == "assistant", let cs = msg?["content"] as? [[String: Any]] {
                for (i, c) in cs.enumerated() {
                    let lid = i == 0 ? id : "\(id)#\(i)"
                    if c["type"] as? String == "text", let t = (c["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty {
                        out.append(CaptainLine(id: lid, at: at, role: .captain, text: stripNag(t)))
                    } else if c["type"] as? String == "tool_use", let name = c["name"] as? String {
                        out.append(CaptainLine(id: lid, at: at, role: .tool, text: toolLine(name, c["input"] as? [String: Any] ?? [:])))
                    }
                }
            } else if type == "assistant", msg?["stop_reason"] as? String == "end_turn",
                      let cs = msg?["content"] as? [[String: Any]] {
                let t = cs.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
                    .joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                if !t.isEmpty { out.append(CaptainLine(id: id, at: at, role: .captain, text: stripNag(t))) }
            }
        }
        return Array(out.suffix(full ? keepFull : keep))
    }

    /// 工具一行：工具名＋AI 自己寫的說明或檔名（不放指令原文、網址參數、檔案內容）
    static func toolLine(_ name: String, _ input: [String: Any]) -> String {
        func str(_ k: String) -> String? { (input[k] as? String).flatMap { $0.isEmpty ? nil : $0 } }
        func file(_ k: String) -> String? { str(k).map { ($0 as NSString).lastPathComponent } }
        let s: String
        switch name {
        case "Bash": s = "執行指令" + (str("description").map { "：\($0)" } ?? "")
        case "Read": s = "讀檔" + (file("file_path").map { "：\($0)" } ?? "")
        case "Edit", "MultiEdit": s = "修改" + (file("file_path").map { "：\($0)" } ?? "")
        case "Write": s = "寫檔" + (file("file_path").map { "：\($0)" } ?? "")
        case "Grep", "Glob": s = "搜尋檔案"
        case "WebSearch": s = "上網搜尋"
        case "WebFetch": s = "開網頁" + (str("url").flatMap { URL(string: $0)?.host }.map { "：\($0)" } ?? "")
        case "Agent", "Task": s = "派子代理" + (str("description").map { "：\($0)" } ?? "")
        case "SendMessage": s = "傳訊息給 " + (str("to") ?? "其他 AI")
        case "AskUserQuestion": s = "問你選擇題"
        case "ExitPlanMode": s = "交計畫給你確認"
        case "TodoWrite", "TaskCreate", "TaskUpdate": s = "更新待辦"
        default: s = name.hasPrefix("mcp__") ? "用工具 " + name.split(separator: "__").dropFirst().joined(separator: "・") : name
        }
        return s.count > 120 ? String(s.prefix(120)) + "⋯" : s
    }

    static func userText(_ c: Any?) -> String? {
        if let s = c as? String { return s.trimmingCharacters(in: .whitespacesAndNewlines) }
        let t = (c as? [[String: Any]] ?? []).compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined(separator: "\n")
        return t.isEmpty ? nil : t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// <cross-session-message …>內文</cross-session-message> 的內文
    static func peerBody(_ s: String) -> String {
        guard let a = s.range(of: "<cross-session-message"), let gt = s[a.upperBound...].firstIndex(of: ">") else { return s }
        let rest = s[s.index(after: gt)...]
        let end = rest.range(of: "</cross-session-message>")?.lowerBound ?? rest.endIndex
        return rest[..<end].trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 看板交辦的原話：去掉前綴與後面的守則提醒
    static func boardText(_ body: String) -> String {
        var t = body.hasPrefix(boardPrefix) ? String(body.dropFirst(boardPrefix.count))
            : body.hasPrefix(answerPrefix) ? String(body.dropFirst(answerPrefix.count)) : body
        if let r = t.range(of: "\n請照隊長守則") { t = String(t[..<r.lowerBound]) }
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 隊長回答開頭的 miniKang 提醒（hook 要它加的，給 Kang 看沒意義）：第一段是「🧢 miniKang：」就拿掉
    static func stripNag(_ t: String) -> String {
        guard t.hasPrefix("🧢") else { return t }
        let parts = t.components(separatedBy: "\n\n")
        return parts.count > 1 ? parts.dropFirst().joined(separator: "\n\n") : t
    }
}
