import Foundation

// B1 小量精緻交流（10-22 Kang：「地下 1 樓的 AI 不是要讓他們完全沒事，但也不能一直用大量流量 ⇒ 小量的精緻交流」）。
// 10-24 Kang 改成留言板：「交流內容都攸關工作過程的升級 ⇒ 不一定要面對面，也可以是留言板；這些內容都要進入隊長的優化指揮」。
// 10-27 Kang（T1027193007）改成「收尾時順便留、不叫醒人」：
//   • 不再叫醒在 B1 閒置的 session（原本一天 3 次）⇒ 閒置 session 零花費
//   • 只在收尾那一輪（Stop hook hook_ctx_wrapup.py 的收尾提示，用 `showork b1 hint` 取這段）順便留，不多開一輪
//   • 頂多一則、可以零則：這段工作沒有失敗、被糾正、重工就不留
//   • 只留「需要修正」的事：哪裡出錯或繞遠路、根因、建議改成什麼規則或做法，附證據（檔名、log、SHA）；通用技巧不留
//   • 提示裡直接附板上最近幾則（不多一次工具呼叫），同一個坑已經有人寫過就 --re 回覆或不留
//   • 每則留言同時轉給現任隊長（【交流板】），隊長用 showork b1 read 整理成流程優化

public enum B1Talk {
    public static let maxChars = 150
    /// 硬上限（超過就截斷；建議字數是 maxChars）
    public static let hardChars = 300
    /// 收尾提示裡直接附上板上最近幾則（不用另外跑 b1 read，也不會漏讀；10-27 實測叫它先讀，它會跳過）
    public static let recentN = 5
    /// 附上的每則截到幾個字
    public static let recentChars = 60

    /// 收尾提示裡加的那段（hook_ctx_wrapup.py 跑 `showork b1 hint` 取得，接在發收尾卡之前，收尾卡順延成 ⑤）
    public static func wrapupNote(showork: String, recent: [B1Post]) -> String {
        var t = "④交流板檢討（頂多一則、可以零則）：這段工作有失敗、被使用者／隊長糾正、或重工繞遠路才留，一切順利就不留；"
            + "要留就 `\"\(showork)\" b1 post --text \"<\(maxChars) 字以內>\"`（**硬上限 \(maxChars) 字，寫好先數字數再送**）：哪裡錯或繞遠路、根因、建議改成什麼規則或做法，附證據（檔名、log、SHA）；"
            + "通用好用技巧不留；不寫帳號、金鑰、客戶名、真實人名"
        let last = recent.suffix(recentN)
        guard !last.isEmpty else { return t + "。" }
        t += "。板上最近 \(last.count) 則（同一個坑已經有人寫過：沒有新證據就不留；有新證據——不同 SHA、不同根因——才加 `--re <編號>` 回覆，只寫新的部分）："
        t += last.map { p in
            let x = p.text.count > recentChars ? String(p.text.prefix(recentChars)) + "…" : p.text
            return "#\(p.id) \(p.name)" + (p.re.map { "↪#\($0)" } ?? "") + "：\(x)"
        }.joined(separator: "｜")
        return t
    }
}

/// Agent交流互動板：board/b1-board.jsonl，一行一則（只增不改）
public struct B1Post: Codable, Sendable, Equatable {
    public var id: Int
    public var at: Date
    public var sid: String
    public var name: String
    public var project: String
    public var text: String
    public var re: Int?
    public init(id: Int, at: Date, sid: String, name: String, project: String, text: String, re: Int? = nil) {
        self.id = id; self.at = at; self.sid = sid; self.name = name; self.project = project; self.text = text; self.re = re
    }

    /// 一行顯示：#12 10-24 03:10 Ruby（ShoWork42）↪#9：內容
    public func line(_ cal: Calendar = .current) -> String {
        let f = DateFormatter(); f.calendar = cal; f.timeZone = cal.timeZone; f.dateFormat = "MM-dd HH:mm"
        return "#\(id) \(f.string(from: at)) \(name)" + (project.isEmpty ? "" : "（\(project)）") + (re.map { " ↪#\($0)" } ?? "") + "：\(text)"
    }

    /// 轉給隊長的那則
    public var captainText: String {
        "【交流板 #\(id)】\(name)" + (project.isEmpty ? "" : "（\(project)）") + (re.map { " 回應 #\($0)" } ?? "") + "：\(text)\n"
            + "（工作心得，請收進流程優化的參考；不用回。全部留言：showork b1 read）"
    }
}

public enum B1Board {
    public static var file: URL {
        if let p = ProcessInfo.processInfo.environment["SHOWORK_B1_BOARD"] { return URL(fileURLWithPath: p) }
        return Captain.dir.appendingPathComponent("b1-board.jsonl")
    }

    public static func all() -> [B1Post] {
        guard let d = FileManager.default.contents(atPath: file.path) else { return [] }
        return d.split(separator: 0x0A).compactMap { try? BoardJSON.decoder.decode(B1Post.self, from: Data($0)) }
    }

    /// 整理文字：去頭尾空白、換行改空白、超過硬上限截斷
    public static func clean(_ s: String) -> String {
        let t = s.replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        return t.count > B1Talk.hardChars ? String(t.prefix(B1Talk.hardChars)) + "…" : t
    }

    /// 加一則（編號＝目前最大 +1）；空字串不收
    @discardableResult
    public static func post(sid: String, name: String, project: String, text: String, re: Int? = nil, now: Date = Date()) -> B1Post? {
        let t = clean(text)
        guard !t.isEmpty else { return nil }
        let p = B1Post(id: (all().map(\.id).max() ?? 0) + 1, at: now, sid: sid, name: name, project: project, text: t, re: re)
        guard var d = try? BoardJSON.encoder.encode(p) else { return nil }      // 預設不排版＝一行
        d.append(0x0A)
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let h = try? FileHandle(forWritingTo: file) {
            defer { try? h.close() }
            _ = try? h.seekToEnd(); try? h.write(contentsOf: d)
        } else {
            guard (try? d.write(to: file, options: .atomic)) != nil else { return nil }
        }
        return p
    }
}
