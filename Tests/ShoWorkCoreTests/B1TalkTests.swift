import Foundation
import Testing
@testable import ShoWorkCore

@Suite("B1Talk")
struct B1TalkTests {
    // 假名（10-22 規矩）
    let t0 = Date(timeIntervalSince1970: 1_792_650_000)
    var cal: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "Asia/Taipei")!; return c }

    @Test("收尾提示（10-27 T1027193007）：不叫醒人、頂多一則可零則、只留需要修正的事、附板上最近幾則避免重複")
    func wrapupNote() {
        let empty = B1Talk.wrapupNote(showork: "/x/showork", recent: [])
        #expect(empty.hasPrefix("④交流板檢討") && empty.hasSuffix("。") && !empty.contains("板上最近"))
        #expect(empty.contains("頂多一則") && empty.contains("可以零則") && empty.contains("一切順利就不留"))
        #expect(empty.contains("失敗") && empty.contains("糾正") && empty.contains("重工"))
        #expect(empty.contains("根因") && empty.contains("證據") && empty.contains("SHA") && empty.contains("通用好用技巧不留"))
        #expect(empty.contains("\"/x/showork\" b1 post --text") && empty.contains("\(B1Talk.maxChars) 字以內"))
        #expect(empty.contains("不寫帳號、金鑰、客戶名、真實人名") && !empty.contains("b1 read"))   // 不多一次工具呼叫
        let posts = (1...7).map { B1Post(id: $0, at: t0, sid: "s", name: "小明", project: "", text: $0 == 7 ? String(repeating: "坑", count: 80) : "坑\($0)", re: $0 == 6 ? 2 : nil) }
        let n = B1Talk.wrapupNote(showork: "/x/showork", recent: posts)
        #expect(n.contains("板上最近 5 則") && n.contains("--re <編號>"))
        #expect(n.contains("沒有新證據就不留") && n.contains("不同 SHA、不同根因") && empty.contains("硬上限 \(B1Talk.maxChars) 字"))
        #expect(!n.contains("#2 小明：") && n.contains("#3 小明：坑3｜") && n.contains("#6 小明↪#2：坑6"))
        #expect(n.contains("#7 小明：" + String(repeating: "坑", count: B1Talk.recentChars) + "…") && !n.contains(String(repeating: "坑", count: B1Talk.recentChars + 1)))
        #expect(!n.contains("\n"))          // hook 把它接進同一段收尾提示
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
