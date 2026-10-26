import Foundation
import Testing
@testable import ShoWorkCore

@Suite("使用者已答：轉隊長、清掉隊長卡片的同一題")
struct AnsweredTests {
    @Test func relay() {
        #expect(Answered.relay(name: "小明", question: "要 push 嗎？", answer: "好，push").hasPrefix("【使用者已答】小明：要 push 嗎？→好，push"))
        #expect(Answered.relay(name: "小明", question: nil, answer: "好").contains("（卡片上沒有問題文字）"))
    }

    @Test func same() {
        #expect(Answered.same("要 push 嗎？", "要push嗎?"))
        #expect(Answered.same("Push now?", "push now"))
        #expect(!Answered.same("要 push 嗎？", "要部署嗎？"))
        #expect(!Answered.same(nil, "要 push 嗎？"))
        #expect(!Answered.same("？", "?"))                     // 只剩標點不算同一題
    }

    @Test func clearing() throws {
        var r = SelfReport(status: .review, summary: "等 Kang 決定")
        r.ask = "要 push 嗎？"; r.options = ["好，push", "先不要"]
        let x = try #require(Answered.clearing(r, question: "要push嗎?"))
        #expect(x.ask == nil && x.options == nil && x.summary == "等 Kang 決定" && x.status == .review)
        #expect(Answered.clearing(r, question: "要部署嗎？") == nil)

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("answered-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try BoardJSON.encoder.encode(r).write(to: dir.appendingPathComponent("cap.json"))
        #expect(!Answered.clearCaptainCard(sid: "cap", question: "別的事？", dir: dir))
        #expect(Answered.clearCaptainCard(sid: "cap", question: "要 push 嗎", dir: dir))
        let back = try BoardJSON.decoder.decode(SelfReport.self, from: Data(contentsOf: dir.appendingPathComponent("cap.json")))
        #expect(back.ask == nil && back.options == nil)
        #expect(!Answered.clearCaptainCard(sid: "沒有這張", question: "要 push 嗎", dir: dir))
    }
}
