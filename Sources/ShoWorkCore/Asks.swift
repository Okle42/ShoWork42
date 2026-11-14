import Foundation

// 等你回答的問題排隊（11-11：使用者一直說「我根本就沒有按鈕」）。
// 原本每個 session 只留最後一張卡片（board/cards/<sid>.json），問題跟著卡片走，所以：
//   ① --status blocked 的 --ask 進「卡住」欄，不在「等你回答」；
//   ② 同一個 session 後來再發一張卡，前一題（例如 某組員的一題）就被蓋掉；
//   ③ AI 發完 --ask 又動一下工具，光暈變回工作中，問題從「等你回答」消失（Puppy 01:05:34→01:05:39）。
// 改成 --ask 另外排進 board/asks/<sid>.json：不管 status、後來的卡片、工作中事件，都留著，
// 只有「你在戰情中心回答」「你在那個終端機打字回答」「AI 自己撤回（showork asks withdraw）」「放超過 ttl」才拿掉。最早的先問。
// 11-14 使用者：在終端機那邊回答了，戰情中心的題目還掛著 ⇒ 使用者本人在那個 session 打字（UserPromptSubmit）就清掉它的待答題。

public struct PendingAsk: Codable, Sendable, Equatable, Identifiable {
    public var id: String              // Q＋4 碼，撤回用
    public var ask: String
    public var options: [String]?
    public var at: Date                // 第一次問的時間（排隊順序）
    public var doing: String?
    public init(id: String, ask: String, options: [String]? = nil, at: Date, doing: String? = nil) {
        self.id = id; self.ask = ask; self.options = options; self.at = at; self.doing = doing
    }
}

public enum AskQueue {
    /// 放多久沒人回答就不再列（使用者可能在終端機答了、AI 又忘了撤回）
    public static let ttl: TimeInterval = 48 * 3600

    public static var dir: URL {
        if let p = ProcessInfo.processInfo.environment["SHOWORK_ASKS_DIR"] { return URL(fileURLWithPath: p, isDirectory: true) }
        return Paths.supportDir.appendingPathComponent("board/asks", isDirectory: true)
    }

    // MARK: 純邏輯

    /// 新卡片 → 佇列：沒 --ask 就不動（新卡片不會刪掉還沒回答的題）；同一題再問一次只更新選項，不重排；新題排到最後
    public static func adding(_ r: SelfReport, to xs: [PendingAsk], id: () -> String = newID) -> [PendingAsk] {
        guard let q = r.ask?.trimmingCharacters(in: .whitespacesAndNewlines), !q.isEmpty else { return xs }
        var out = xs
        if let i = out.firstIndex(where: { Answered.same($0.ask, q) }) {
            if r.options != nil { out[i].options = r.options }
            return out
        }
        out.append(PendingAsk(id: id(), ask: q, options: r.options, at: r.at, doing: r.doing))
        return out
    }

    /// 還有效的（沒過期），最早的在前
    public static func live(_ xs: [PendingAsk], now: Date) -> [PendingAsk] {
        xs.filter { now.timeIntervalSince($0.at) < ttl }.sorted { $0.at < $1.at }
    }

    public static func newID() -> String {
        let a = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")
        return "Q" + String((0..<4).map { _ in a.randomElement()! })
    }

    // MARK: 檔案（board/asks/<sid>.json；空了就刪檔）

    public static func load(_ sid: String) -> [PendingAsk] {
        guard let d = FileManager.default.contents(atPath: dir.appendingPathComponent(sid + ".json").path) else { return [] }
        return (try? BoardJSON.decoder.decode([PendingAsk].self, from: d)) ?? []
    }

    public static func save(_ sid: String, _ xs: [PendingAsk]) {
        let url = dir.appendingPathComponent(sid + ".json")
        if xs.isEmpty { try? FileManager.default.removeItem(at: url); return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let d = try? BoardJSON.encoder.encode(xs) { try? d.write(to: url, options: .atomic) }
    }

    /// 全部 session（看板每次刷新讀；檔名＝sid）
    public static func all() -> [String: [PendingAsk]] {
        var out: [String: [PendingAsk]] = [:]
        for f in (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [] where f.hasSuffix(".json") {
            let sid = String(f.dropLast(5))
            let xs = load(sid)
            if !xs.isEmpty { out[sid] = xs }
        }
        return out
    }

    /// `showork card` 寫卡片時一起排（過期的順手清掉）
    @discardableResult
    public static func record(sid: String, report r: SelfReport, now: Date = Date()) -> [PendingAsk] {
        let old = load(sid)
        let xs = adding(r, to: live(old, now: now))
        if xs != old { save(sid, xs) }
        return xs
    }

    /// 你在戰情中心回答了這一題 ⇒ 拿掉；卡片檔上同一題的 --ask 也清掉（不然它會用舊卡片的問題再冒出來）
    @discardableResult
    public static func resolve(sid: String, id: String, cardsDir: URL = Paths.supportDir.appendingPathComponent("board/cards", isDirectory: true)) -> PendingAsk? {
        var xs = load(sid)
        guard let i = xs.firstIndex(where: { $0.id == id }) else { return nil }
        let q = xs.remove(at: i)
        save(sid, xs)
        Answered.clearCaptainCard(sid: sid, question: q.ask, dir: cardsDir)
        return q
    }

    /// 同一題（文字相同）拿掉：隊長卡片掛著組員已經被回答的題（Answered）
    @discardableResult
    public static func resolve(sid: String, question: String?) -> Bool {
        let xs = load(sid)
        let ys = xs.filter { !Answered.same($0.ask, question) }
        if ys.count != xs.count { save(sid, ys); return true }
        return false
    }

    /// AI 撤回：編號或 all；回傳撤掉幾題
    public static func withdraw(sid: String, id: String) -> Int {
        let xs = load(sid)
        let ys = id == "all" ? [] : xs.filter { $0.id.caseInsensitiveCompare(id) != .orderedSame }
        save(sid, ys)
        return xs.count - ys.count
    }

    /// 使用者本人在終端機打的字才算回答：其他 session／看板轉送／系統訊息（<…> 標籤，含戰情中心回答）不算；
    /// 「放行」是在回權限擋單，不是回答問題
    public static func isTerminalAnswer(_ prompt: String?) -> Bool {
        guard CaptainLink.needsStart(prompt: prompt) else { return false }
        return !(prompt ?? "").trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("放行")
    }

    /// 使用者在這個 session 的終端機打字回答 ⇒ 這個 session 的待答題全部拿掉、卡片上的 --ask 清掉；
    /// 隊長卡片／佇列掛著同一題的也清掉（不轉【使用者已答】：答案在組員那邊，隊長巡檢看得到，不為這個叫醒隊長）。回傳拿掉的題
    @discardableResult
    public static func answeredInTerminal(sid: String, prompt: String?, captain: String? = nil,
                                          cardsDir: URL = Paths.supportDir.appendingPathComponent("board/cards", isDirectory: true)) -> [PendingAsk] {
        guard isTerminalAnswer(prompt) else { return [] }
        let xs = load(sid)
        guard !xs.isEmpty else { return [] }
        save(sid, [])
        for q in xs {
            Answered.clearCaptainCard(sid: sid, question: q.ask, dir: cardsDir)
            if let cap = captain, cap != sid {
                Answered.clearCaptainCard(sid: cap, question: q.ask, dir: cardsDir)
                resolve(sid: cap, question: q.ask)
            }
        }
        return xs
    }
}
