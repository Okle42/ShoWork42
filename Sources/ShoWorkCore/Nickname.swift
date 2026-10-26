import Foundation

/// 戰情中心上每個 AI 的英文名＋正在做的任務（10-19 Kang：you-88、session 標題這些他分不出誰是誰，
/// 標題又停在開場那件事；改成卡片標題＝「英文名-正在做的任務」，任務每輪自報都更新）
/// 存在 board/names/<sid>.json；名字跟著 session 走，session 結束後名字可以給新的 session 用。
public struct Nickname: Codable, Sendable, Equatable {
    public var name: String
    public var doing: String?
    public var at: Date?
    public var handoverFrom: String? = nil   // 自動交接（Handover.swift）：接手的是哪個舊 sessionId
    public init(name: String, doing: String? = nil, at: Date? = nil) { self.name = name; self.doing = doing; self.at = at }
}

public enum Nicknames {
    /// 好念、字首不重複；避開使用者身邊真人的名字（可自行調整），免得跟同事搞混
    public static let pool = ["Alex", "Bella", "Chris", "Dora", "Ethan", "Fiona", "Gavin", "Hana", "Ivan", "Jade", "Kyle", "Luna", "Milo",
                              "Nina", "Oscar", "Penny", "Quinn", "Ruby", "Sam", "Tina", "Umar", "Vera", "Wade", "Xena", "Yuki", "Zack"]

    /// 挑一個還沒被活著的 session 用掉的名字；26 個都用完就加數字（Alex2⋯）
    /// transcript 開頭的 custom-title／agent-name（舊版標題是「Bella-在做的事」⇒ 取「-」前面）；要是英文名的樣子（字母開頭、英數、≤12 字）
    public static func inherited(_ head: Data?) -> String? {
        guard let head else { return nil }
        for raw in head.split(separator: 0x0A).prefix(20) {
            guard let o = try? JSONSerialization.jsonObject(with: Data(raw)) as? [String: Any] else { continue }
            let v = (o["type"] as? String == "custom-title" ? o["customTitle"] : o["type"] as? String == "agent-name" ? o["agentName"] : nil) as? String
            guard let t = v?.split(separator: "-", maxSplits: 1).first.map(String.init) else { continue }
            if let f = t.first, f.isLetter, f.isASCII, t.count <= 12, t.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) { return t }
        }
        return nil
    }

    public static func pick(taken: Set<String>) -> String {
        for round in 1... {
            for n in pool {
                let c = round == 1 ? n : "\(n)\(round)"
                if !taken.contains(c) { return c }
            }
        }
        return pool[0]
    }

    /// 名字不急著回收：session 結束後，Remote Control 那邊還會留一筆同名的離線紀錄，
    /// SendMessage 遇到兩個同名就退回要 ref（10-22 實測：新的 Gavin 撞上 9 小時前的 Gavin）。所以最近用過的也算佔用。
    public static let reuseAfter: TimeInterval = 3 * 86400

    /// 不能挑的名字：活著的 session 的名字＋reuseAfter 內用過的
    public static func taken(_ all: [String: Nickname], live: Set<String>, me: String, now: Date) -> Set<String> {
        Set(all.compactMap { sid, n in
            if sid == me { return nil }
            if live.contains(sid) { return n.name }
            return n.at.map { now.timeIntervalSince($0) < reuseAfter } == true ? n.name : nil
        })
    }

    /// 任務字串整理：去掉換行、頭尾空白，太長截斷（卡片一行放得下）
    public static func cleanDoing(_ s: String) -> String? {
        let t = s.split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        if t.isEmpty { return nil }
        return t.count > 24 ? String(t.prefix(24)) + "⋯" : t
    }

    /// 卡片標題：有英文名就「名字-任務」，還沒自報過任務就接原本的標題
    public static func title(_ n: Nickname?, fallback: String) -> String {
        guard let n else { return fallback }
        return "\(n.name)-\(n.doing ?? fallback)"
    }
}

/// 固定英文名當收訊地址（10-22 派工 T1022020414）：session 名只設英文名（Chris），doing 只進卡片標題與名冊顯示。
/// 名字回收重用（昨天另一個 session 也叫 Chris）時只看「現在活著的」；兩個活的同名就全回，讓呼叫端報錯。
public enum ShortName {
    /// sessions＝活著的 (sessionId, session 名)；nick＝sessionId → 英文名。回傳符合的 sessionId（依序：全名／sessionId ⇒ 英文名 ⇒ sessionId 開頭）
    public static func match(_ who: String, among sessions: [(String, String?)], nick: [String: String]) -> [String] {
        let w = who.trimmingCharacters(in: .whitespaces)
        guard !w.isEmpty else { return [] }
        let exact = sessions.filter { $0.1 == w || $0.0 == w }.map(\.0)
        if !exact.isEmpty { return exact }
        // 英文名：看板記的名字，或舊 session 還沒改名時的「Chris-在做的事」開頭
        let short = sessions.filter { sid, name in
            nick[sid]?.caseInsensitiveCompare(w) == .orderedSame
                || (name.map { $0.lowercased().hasPrefix(w.lowercased() + "-") } ?? false)
        }.map(\.0)
        if !short.isEmpty { return short }
        return w.count >= 6 ? sessions.filter { $0.0.hasPrefix(w) }.map(\.0) : []
    }
}

/// board/names/<sid>.json 的讀寫（CLI 寫、agent 讀）
public enum NicknameStore {
    public static var dir: URL { Paths.supportDir.appendingPathComponent("board/names", isDirectory: true) }
    static var sessionsDir: String { FileManager.default.homeDirectoryForCurrentUser.path + "/.claude/sessions" }

    public static func get(_ sid: String) -> Nickname? {
        FileManager.default.contents(atPath: dir.appendingPathComponent(sid + ".json").path).flatMap { try? BoardJSON.decoder.decode(Nickname.self, from: $0) }
    }

    public static func all() -> [String: Nickname] {
        var out: [String: Nickname] = [:]
        for f in (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [] where f.hasSuffix(".json") {
            let sid = String(f.dropLast(5))
            if let n = get(sid) { out[sid] = n }
        }
        return out
    }

    static func save(_ sid: String, _ n: Nickname) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let d = try? BoardJSON.encoder.encode(n) { try? d.write(to: dir.appendingPathComponent(sid + ".json"), options: .atomic) }
    }

    /// 現在活著的 session（~/.claude/sessions/<pid>.json 而且 pid 還在）
    public static func liveSessions() -> [SessionRecord] {
        let fm = FileManager.default
        return ((try? fm.contentsOfDirectory(atPath: sessionsDir)) ?? []).compactMap { f -> SessionRecord? in
            guard f.hasSuffix(".json"), let d = fm.contents(atPath: sessionsDir + "/" + f), let r = SessionRecord.decode(d),
                  kill(r.pid, 0) == 0 || errno == EPERM else { return nil }
            return r
        }
    }

    /// 這個 session 的名字；還沒有就從活著的 session 沒用到的名字裡挑一個存起來
    @discardableResult
    public static func ensure(_ sid: String) -> Nickname {
        if let n = get(sid) { return n }
        let all = all()
        let live = Set(liveSessions().map(\.sessionId))
        // 10-22 Bella→Kyle：同一個程序換了 sessionId（transcript 換一個檔，開頭抄著舊的 custom-title「Bella」）⇒ 沿用那個名字，
        // 只要現在沒有別的活著的 session 用它
        if let old = Nicknames.inherited(headOfTranscript(sid)),
           !all.contains(where: { $0.key != sid && live.contains($0.key) && $0.value.name == old }) {
            let n = Nickname(name: old, at: Date())
            save(sid, n)
            return n
        }
        let n = Nickname(name: Nicknames.pick(taken: Nicknames.taken(all, live: live, me: sid, now: Date())), at: Date())
        save(sid, n)
        return n
    }

    /// 這個 session 的 transcript 開頭（~/.claude/projects/*/<sid>.jsonl 前 16 KB）；找不到＝nil
    static func headOfTranscript(_ sid: String) -> Data? {
        let root = FileManager.default.homeDirectoryForCurrentUser.path + "/.claude/projects"
        for d in (try? FileManager.default.contentsOfDirectory(atPath: root)) ?? [] {
            let f = root + "/" + d + "/" + sid + ".jsonl"
            guard let h = FileHandle(forReadingAtPath: f) else { continue }
            defer { try? h.close() }
            return try? h.read(upToCount: 16 << 10)
        }
        return nil
    }

    /// 還活著：at 當「最後出現」用（名字冷卻從這裡算）；一小時最多寫一次
    public static func touch(_ sid: String, now: Date = Date()) {
        guard var n = get(sid), (n.at ?? .distantPast) < now.addingTimeInterval(-3600) else { return }
        n.at = now; save(sid, n)
    }

    /// 自報帶了 --doing 就更新任務
    @discardableResult
    public static func update(_ sid: String, doing: String?) -> Nickname {
        var n = ensure(sid)
        if let doing, doing != n.doing { n.doing = doing; n.at = Date(); save(sid, n) }
        return n
    }
}

extension Nicknames {
    /// 終端機視窗標題（10-19 Kang：Ghostty 標題也要跟著變）。由 hook 回傳 `terminalSequence`（OSC 0），Claude Code 代為寫出。
    /// 開頭沿用 Claude 的狀態符號（◐ 工作中、✳ 這輪做完），TitleWatcher 的備援判斷照樣認得。
    public static func terminalTitle(_ n: Nickname, done: Bool) -> String {
        let text = (n.doing.map { "\(n.name)-\($0)" } ?? n.name).unicodeScalars.filter { $0.value >= 0x20 && $0.value != 0x7F }
        return (done ? "✳ " : "◐ ") + String(String.UnicodeScalarView(text))
    }

    /// hook 的輸出 JSON：{"terminalSequence":"ESC]0;標題BEL"}；UserPromptSubmit 另外帶 sessionTitle（等同 /rename），
    /// 讓 Claude Code 自己維持的標題至少是英文名——工作中它每轉一格 spinner 都會重寫標題，光靠 terminalSequence 會被蓋掉。
    /// 10-22 起 sessionTitle 只放英文名（它也是 SendMessage 的地址，不能跟著 doing 變）；任務照樣靠 terminalSequence 與做完時補寫的 OSC 0
    /// n＝nil（還沒取名）時只輸出 context；context＝UserPromptSubmit 要注入給 AI 的提醒（開工卡，CaptainLink）
    public static func hookOutput(_ n: Nickname?, done: Bool, event: String? = nil, context: String? = nil) -> String {
        var o: [String: Any] = [:]
        if let n { o["terminalSequence"] = "\u{1B}]0;" + terminalTitle(n, done: done) + "\u{07}" }
        if event == "UserPromptSubmit" {
            // session 名＝收訊地址，只放英文名（10-22 T1022020414：帶 doing 的話每次自報地址就變，隊長插話一直被退回）
            var h: [String: Any] = ["hookEventName": "UserPromptSubmit"]
            if let n { h["sessionTitle"] = n.name }
            if let context { h["additionalContext"] = context }
            if h.count > 1 { o["hookSpecificOutput"] = h }
        }
        guard !o.isEmpty else { return "" }
        let d = (try? JSONSerialization.data(withJSONObject: o)) ?? Data()
        return String(decoding: d, as: UTF8.self)
    }
}
