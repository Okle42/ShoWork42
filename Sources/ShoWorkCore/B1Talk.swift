import Foundation

// B1 小量精緻交流（10-22 Kang：「地下 1 樓的 AI 不是要讓他們完全沒事，但也不能一直用大量流量 ⇒ 小量的精緻交流」）。
// 10-24 Kang 改成留言板：「交流內容都攸關工作過程的升級 ⇒ 不一定要面對面，也可以是留言板；這些內容都要進入隊長的優化指揮」。
// 規則（純函式，看板每次刷新問一次）：
//   • 有人在 B1 休息（站定、沒在路上）、session 開著、今天還沒被叫來留言過（一個人就可以，不用等另一個人）
//   • 一天最多 3 次、兩次之間至少隔 60 分鐘；5 小時額度用超過 60% 不辦（停電、過熱看板本來就不叫人）
//   • 一次叫醒一人：先讀板上最近的留言，再用 showork b1 post 留一則 ≤150 字的心得（可以回應板上某則），留完就停
//   • 每則留言同時轉給現任隊長（【交流板】），隊長用 showork b1 read 整理成流程優化

public enum B1Talk {
    public static let perDay = 3
    public static let gap: TimeInterval = 3600
    public static let maxFiveUsed = 60.0
    public static let maxChars = 150
    /// 硬上限（超過就截斷；建議字數是 maxChars）
    public static let hardChars = 300

    public struct Record: Codable, Sendable, Equatable {
        public var at: Date
        public var a: String                // sessionId
        public var b: String                // 舊版兩人交流的另一人；留言板版本＝空字串
        public init(at: Date, a: String, b: String = "") { self.at = at; self.a = a; self.b = b }
    }

    public struct Person: Sendable, Equatable {
        public var sid: String
        public var name: String             // 英文名
        public var project: String
        public var address: String          // SendMessage 的收件地址（uds:/tmp/cc-socks/<pid>.sock）
        public init(sid: String, name: String, project: String, address: String) {
            self.sid = sid; self.name = name; self.project = project; self.address = address
        }
    }

    /// 現在要不要叫一個人來留言、叫誰。people＝現在在 B1 站定休息、收得到訊息的人（呼叫端依 sid 排好）
    public static func pick(people: [Person], history: [Record], fiveUsed: Double?, now: Date, calendar: Calendar = .current) -> Person? {
        guard !people.isEmpty, (fiveUsed ?? 0) <= maxFiveUsed else { return nil }
        let today = history.filter { calendar.isDate($0.at, inSameDayAs: now) }
        guard today.count < perDay else { return nil }
        if let last = history.map(\.at).max(), now.timeIntervalSince(last) < gap { return nil }
        let usedToday = Set(today.flatMap { [$0.a, $0.b] })
        return people.first { !usedToday.contains($0.sid) }
    }

    /// 送給 me 的那則（叫他讀板、留一則）
    public static func prompt(me: Person, showork: String) -> String {
        """
        【Agent交流互動板】你現在在 B1 機房休息，請只做這一件事：
        1. 先跑 "\(showork)" b1 read 看板上最近的留言。
        2. 再跑 "\(showork)" b1 post --text "<\(maxChars) 字以內>" 留一則：你最近工作裡學到、別人用得上的一件事（方法、踩過的坑、好用的工具、流程哪裡可以改）；想回應板上某則就加 --re <編號>。不寫帳號、金鑰、客戶名、真實人名。
        留完就停，不要做別的事、不要回覆這則。留言會轉給隊長當流程優化的參考。
        """
    }

    /// 只留最近 30 天
    public static func prune(_ h: [Record], now: Date) -> [Record] { h.filter { now.timeIntervalSince($0.at) < 30 * 86400 } }
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
