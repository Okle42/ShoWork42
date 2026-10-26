import Foundation
import Testing
@testable import ShoWorkCore

@Suite struct NicknameTests {
    @Test("挑名字：跳過用掉的，26 個都用完加數字")
    func pick() {
        #expect(Nicknames.pick(taken: []) == "Alex")
        #expect(Nicknames.pick(taken: ["Alex", "Bella"]) == "Chris")
        #expect(Nicknames.pick(taken: Set(Nicknames.pool)) == "Alex2")
    }

    @Test("--doing：去換行、空字串不算、太長截斷")
    func doing() throws {
        #expect(try SelfReport.parse(args: ["--status", "working", "--doing", " 公會留言板\n第二階段 "]).get().doing == "公會留言板 第二階段")
        #expect(try SelfReport.parse(args: ["--status", "working", "--doing", "  "]).get().doing == nil)
        #expect(Nicknames.cleanDoing(String(repeating: "字", count: 30))?.count == 25)
    }

    @Test("卡片標題＝英文名-任務；沒報任務接原標題；沒名字照舊")
    func title() {
        #expect(Nicknames.title(Nickname(name: "Bella", doing: "訊息分頁"), fallback: "Handoff 88") == "Bella-訊息分頁")
        #expect(Nicknames.title(Nickname(name: "Bella"), fallback: "Handoff 88") == "Bella-Handoff 88")
        #expect(Nicknames.title(nil, fallback: "Handoff 88") == "Handoff 88")
    }

    @Test("看板用 nicknames 組標題")
    func board() {
        let s = SessionRecord(pid: 1, sessionId: "A", cwd: "/h/x")
        var t = TranscriptInfo(); t.title = "舊標題"
        let cards = Board.build(sessions: [s], transcripts: ["A": t], glows: [:], teams: [], inbox: [],
                                nicknames: ["A": Nickname(name: "Chris", doing: "硬碟清理")],
                                now: Date(), home: "/h", isRepo: { _ in false })
        #expect(cards.first?.title == "Chris-硬碟清理")
    }
}
