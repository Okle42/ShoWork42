import Foundation
import Testing
@testable import ShoWorkCore

@Suite("Islands")
struct IslandsTests {
    func card(_ id: String, _ project: String, _ col: BoardColumn, reason: String = "", title: String = "t", captain: Bool = false) -> BoardCard {
        var c = BoardCard(id: id, column: col, reason: reason, project: project, title: title, lastActivity: nil, pid: 1, sessionId: id)
        c.captain = captain
        return c
    }

    @Test("欄位對應角色：進行中＝打字、等你回答＝紅、做完沒看＝綠、卡住、閒置")
    func moods() {
        #expect(Mood.of(card("a", "P", .active)) == .working)
        #expect(Mood.of(card("a", "P", .review, reason: "等你回答")) == .waiting)
        #expect(Mood.of(card("a", "P", .review, reason: "要你決定：要不要 push")) == .waiting)
        #expect(Mood.of(card("a", "P", .review, reason: "做完了，你還沒看")) == .finished)
        #expect(Mood.of(card("a", "P", .review, reason: "AI 請你看過")) == .finished)
        #expect(Mood.of(card("a", "P", .stuck)) == .stuck)
        #expect(Mood.of(card("a", "P", .done)) == .idle)
        var fresh = card("a", "P", .done); fresh.unused = true
        #expect(Mood.of(fresh) == .asleep)                     // 從來沒用過＝睡覺；做完已讀＝休息
    }

    @Test("配件：隊長皇冠優先、秘書專案耳機、研究審核標題眼鏡")
    func accessories() {
        LocalFixture.use()
        let h = Islands.defaultHeadsetProjects
        #expect(Islands.accessory(card("a", "ProjectC", .active, captain: true), headsetProjects: h) == .crown)
        #expect(Islands.accessory(card("a", "projectc", .active), headsetProjects: h) == .headset)
        #expect(Islands.accessory(card("a", "ProjectA", .active, title: "給排水法規研究"), headsetProjects: h) == .glasses)
        #expect(Islands.accessory(card("a", "ProjectA", .active, title: "Code Review 第二輪"), headsetProjects: h) == .glasses)
        #expect(Islands.accessory(card("a", "ProjectA", .active, title: "接電路"), headsetProjects: h) == nil)
    }

    @Test("分組：排隊訊息只算數不畫人、要你處理的島和人排前面")
    func build() {
        let cards = [
            card("1", "Idle", .done),
            card("2", "Busy", .active),
            card("3", "Ask", .active),
            card("4", "Ask", .review, reason: "等你回答"),
            card("3#q0", "Ask", .todo),
            card("5", "Busy", .done),
        ]
        let isl = Islands.build(cards)
        #expect(isl.map(\.project) == ["Ask", "Busy", "Idle"])
        #expect(isl[0].people.map(\.id) == ["4", "3"])
        #expect(isl[0].queued == 1 && isl[0].needsYou == 1)
        #expect(isl[1].count(.working) == 1 && isl[1].count(.idle) == 1)
    }
}

@Suite("IslandGrid")
struct IslandGridTests {
    @Test("一樣大、塞滿：寬視窗排橫的、高視窗排直的、太小就可捲")
    func fit() {
        let one = IslandGrid.fit(count: 1, width: 1000, height: 600)
        #expect(one.cols == 1 && one.width == 1000 && one.height == 600)
        let wide = IslandGrid.fit(count: 4, width: 1600, height: 500)
        #expect(wide.cols >= 2)
        #expect(Double(wide.cols) * wide.width + Double(wide.cols - 1) * 12 == 1600)
        let tall = IslandGrid.fit(count: 4, width: 700, height: 1000)
        #expect(tall.cols == 1 && tall.rows == 4)
        let five = IslandGrid.fit(count: 5, width: 1200, height: 900)
        #expect(five.cols * five.rows >= 5 && (five.rows - 1) * five.cols < 5)
        let tiny = IslandGrid.fit(count: 9, width: 600, height: 400)
        #expect(tiny.height == 170)                                       // 不壓扁，改捲動
        let narrow = IslandGrid.fit(count: 8, width: 518, height: 900)
        #expect(narrow.cols == 1 && narrow.width == 518)                 // 兩欄只剩 253 寬 ⇒ 排一欄往下捲
    }
}

@Suite("StickyProject")
struct StickyProjectTests {
    let home = "/Users/k"
    func repo(_ p: String) -> Bool { ["/Users/k/repos/ProjectB", "/Users/k/repos/ShoWork42"].contains(p) }
    /// 依序在每個地方待幾秒（每 10 秒一筆）
    func marks(_ stays: [(String, Int)]) -> [CwdMark] {
        var t = Date(timeIntervalSince1970: 0), out: [CwdMark] = []
        for (c, secs) in stays { for _ in 0..<max(1, secs / 10) { out.append(CwdMark(cwd: c, at: t)); t += 10 } }
        return out
    }
    func w(_ stays: [(String, Int)]) -> (home: String, visiting: String?) {
        Board.whereabouts(marks(stays), fallback: nil, home: home, isRepo: repo)
    }
    let ride = "/Users/k/repos/ProjectB/app", show = "/Users/k/repos/ShoWork42"

    @Test("cd 出去一下不搬家、待滿 5 分鐘才搬、子資料夾算同一個專案")
    func sticky() {
        #expect(w([(ride, 1200), (home, 70)]) == ("ProjectB", "（家目錄）"))           // 回家目錄 70 秒
        #expect(w([(ride, 1200), (show, 200)]) == ("ProjectB", "ShoWork42"))           // 去別的 repo 逛 200 秒（很多筆也不算）
        #expect(w([(ride, 1200), (show, 200), (ride, 30)]) == ("ProjectB", nil))       // 回來了
        #expect(w([(ride, 1200), (show, 320)]) == ("ShoWork42", nil))                // 待滿 5 分鐘＝搬家
        #expect(w([(ride, 1200), (show, 900), (home, 60)]) == ("ShoWork42", "（家目錄）"))
        #expect(w([(home, 30)]) == ("（家目錄）", nil))                               // 只待過家目錄
        #expect(w([(home, 100), (ride, 20)]).home == "ProjectB")                       // 剛 cd 進專案：家目錄不搶
        #expect(Board.stickyProject([], fallback: "/Users/k/repos/ProjectB", home: home, isRepo: repo) == "ProjectB")
    }

    @Test("抽 cwd＋時間：只認最外層、字串裡跳脫的不算、略過 ~/.claude")
    func cwds() {
        let lines = [
            #"{"type":"user","cwd":"/Users/k/repos/ProjectB","timestamp":"2026-10-13T05:00:00.000Z","message":{"content":"{\"cwd\":\"/fake\"}"}}"#,
            #"{"type":"attachment","cwd":"/Users/k/.claude/projects/x/memory"}"#,
            #"{"type":"assistant","cwd":"/Users/k/中文 專案"}"#,
        ].joined(separator: "\n")
        let m = TranscriptInfo.workCwds(Data(lines.utf8))
        #expect(m.map(\.cwd) == ["/Users/k/repos/ProjectB", "/Users/k/中文 專案"])
        #expect(m[0].at != nil && m[1].at == nil)
    }

    @Test("影分身只出現在已經有的島上，本尊留在家")
    func ghosts() {
        var a = BoardCard(id: "a", column: .active, reason: "", project: "ProjectB", title: "t", lastActivity: nil, pid: 1, sessionId: "a")
        a.visiting = "ShoWork42"
        let b = BoardCard(id: "b", column: .active, reason: "", project: "ShoWork42", title: "t", lastActivity: nil, pid: 2, sessionId: "b")
        var c = a; c.id = "c"; c.sessionId = "c"; c.visiting = "Nowhere"
        let isl = Islands.build([a, b, c])
        #expect(isl.count == 2)
        #expect(isl.first { $0.project == "ShoWork42" }!.ghosts.map(\.id) == ["a"])
        #expect(isl.first { $0.project == "ProjectB" }!.people.map(\.id) == ["a", "c"])
    }
}
