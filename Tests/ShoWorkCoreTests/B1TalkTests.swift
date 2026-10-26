import Foundation
import Testing
@testable import ShoWorkCore

@Suite("B1Talk")
struct B1TalkTests {
    // 假名（10-22 規矩）
    let p = ["a", "b", "c"].map { B1Talk.Person(sid: $0, name: "小明\($0)", project: "專案A", address: "uds:/tmp/x-\($0).sock") }
    let t0 = Date(timeIntervalSince1970: 1_792_650_000)
    var cal: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "Asia/Taipei")!; return c }

    @Test("一個人就辦（留言板不用面對面）；額度超過 60% 不辦")
    func basics() {
        #expect(B1Talk.pick(people: [], history: [], fiveUsed: 10, now: t0, calendar: cal) == nil)
        #expect(B1Talk.pick(people: [p[0]], history: [], fiveUsed: 10, now: t0, calendar: cal)?.sid == "a")
        #expect(B1Talk.pick(people: p, history: [], fiveUsed: 61, now: t0, calendar: cal) == nil)
    }

    @Test("一天最多 3 次、間隔 60 分鐘、今天留過的人不再叫")
    func limits() {
        #expect(B1Talk.pick(people: p, history: [B1Talk.Record(at: t0 - 1800, a: "a")], fiveUsed: 0, now: t0, calendar: cal) == nil)   // 才 30 分鐘
        #expect(B1Talk.pick(people: p, history: [B1Talk.Record(at: t0 - 4000, a: "a")], fiveUsed: 0, now: t0, calendar: cal)?.sid == "b")
        #expect(B1Talk.pick(people: [p[0]], history: [B1Talk.Record(at: t0 - 4000, a: "a")], fiveUsed: 0, now: t0, calendar: cal) == nil)
        // 舊版兩人紀錄（a、b 都算今天交流過）
        #expect(B1Talk.pick(people: p, history: [B1Talk.Record(at: t0 - 4000, a: "a", b: "b")], fiveUsed: 0, now: t0, calendar: cal)?.sid == "c")
        let three = (1...3).map { B1Talk.Record(at: t0 - Double($0) * 4000, a: "x\($0)") }
        #expect(B1Talk.pick(people: p, history: three, fiveUsed: 0, now: t0, calendar: cal) == nil)
        let msg = B1Talk.prompt(me: p[0], showork: "/x/showork")
        #expect(msg.hasPrefix("【Agent交流互動板】") && msg.contains("\"/x/showork\" b1 read") && msg.contains("b1 post") && msg.contains("150 字以內"))
    }

    @Test("留言板：編號遞增、一行一則、轉隊長的文字")
    func board() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("b1board-\(UUID().uuidString)")
        let f = dir.appendingPathComponent("b1-board.jsonl")
        setenv("SHOWORK_B1_BOARD", f.path, 1); defer { unsetenv("SHOWORK_B1_BOARD"); try? FileManager.default.removeItem(at: dir) }
        #expect(B1Board.all().isEmpty)
        #expect(B1Board.post(sid: "a", name: "小明", project: "專案A", text: "  \n ", now: t0) == nil)
        let one = try #require(B1Board.post(sid: "a", name: "小明", project: "專案A", text: "改共用工具前\n先備份每個檔", now: t0))
        let two = try #require(B1Board.post(sid: "b", name: "ACME", project: "", text: String(repeating: "字", count: 400), re: 1, now: t0 + 60))
        #expect(one.id == 1 && two.id == 2 && one.text == "改共用工具前 先備份每個檔")
        #expect(two.text.count == B1Talk.hardChars + 1 && two.re == 1)
        #expect(B1Board.all().map(\.id) == [1, 2])
        #expect(try String(contentsOf: f, encoding: .utf8).split(separator: "\n").count == 2)
        #expect(one.line(cal).hasPrefix("#1 ") && one.line(cal).contains("小明（專案A）：改共用工具前"))
        #expect(two.captainText.hasPrefix("【交流板 #2】ACME 回應 #1：") && two.captainText.contains("showork b1 read"))
    }
}
