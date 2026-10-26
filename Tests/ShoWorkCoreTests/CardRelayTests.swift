import Foundation
import Testing
@testable import ShoWorkCore

@Suite("CardRelay")
struct CardRelayTests {
    let t0 = Date(timeIntervalSince1970: 1_792_500_000)
    func r(_ s: String, at: Date, how: String? = nil) -> SelfReport { SelfReport(status: .working, progress: 50, confidence: 70, summary: s, doing: "做事", how: how, at: at) }
    func txt(_ sid: String, _ r: SelfReport) -> String { "\(sid):\(r.summary ?? "")" }

    @Test("--how 解析；舊卡沒有 how 也讀得回來")
    func parseHow() throws {
        let x = try SelfReport.parse(args: ["--status", "done", "--how", " 讀檔＋swift test "]).get()
        #expect(x.how == "讀檔＋swift test")
        let old = #"{"status":"done","at":"2026-10-21T00:00:00.000Z"}"#
        #expect(try BoardJSON.decoder.decode(SelfReport.self, from: Data(old.utf8)).how == nil)
    }

    @Test("啟動時現有的卡不送；新卡轉給隊長；隊長自己的卡不轉")
    func relay() {
        var st = CardRelay.State()
        #expect(CardRelay.plan(reports: ["a": r("舊", at: t0)], captain: "cap", captainLive: true, state: &st, now: t0, text: txt).isEmpty)
        let out = CardRelay.plan(reports: ["a": r("新", at: t0), "cap": r("隊長的", at: t0)], captain: "cap", captainLive: true, state: &st, now: t0, text: txt)
        #expect(out == [CardRelay.Outgoing(sessionId: "a", text: "a:新")])
    }

    @Test("節流：60 秒內只送一次，到時送最後一張；內容沒變不重送")
    func throttle() {
        var st = CardRelay.State(); st.seeded = true
        #expect(CardRelay.plan(reports: ["a": r("1", at: t0)], captain: "c", captainLive: true, state: &st, now: t0, text: txt).count == 1)
        #expect(CardRelay.plan(reports: ["a": r("2", at: t0 + 10)], captain: "c", captainLive: true, state: &st, now: t0 + 10, text: txt).isEmpty)
        #expect(CardRelay.plan(reports: ["a": r("3", at: t0 + 20)], captain: "c", captainLive: true, state: &st, now: t0 + 30, text: txt).isEmpty)
        let late = CardRelay.plan(reports: ["a": r("3", at: t0 + 20)], captain: "c", captainLive: true, state: &st, now: t0 + 61, text: txt)
        #expect(late.map(\.text) == ["a:3"])
        #expect(CardRelay.plan(reports: ["a": r("3", at: t0 + 20)], captain: "c", captainLive: true, state: &st, now: t0 + 200, text: txt).isEmpty)
    }

    @Test("隊長不在：不送也不堆積（回來後不補送那段期間的卡）")
    func noCaptain() {
        var st = CardRelay.State(); st.seeded = true
        #expect(CardRelay.plan(reports: ["a": r("x", at: t0)], captain: nil, captainLive: false, state: &st, now: t0, text: txt).isEmpty)
        #expect(CardRelay.plan(reports: ["a": r("x", at: t0)], captain: "c", captainLive: true, state: &st, now: t0 + 5, text: txt).isEmpty)
        #expect(CardRelay.plan(reports: ["b": r("old", at: t0 - 3600)], captain: "c", captainLive: true, state: &st, now: t0, text: txt).isEmpty)
    }

    @Test("工作回報全文帶名字、專案、狀態、方法、問題與選項")
    func text() {
        var x = r("改完收件匣", at: t0, how: "讀 3 檔＋swift test")
        x.ask = "要 push 嗎"; x.options = ["好", "不要"]; x.report = "/r.html"
        let s = CardRelay.text(name: "Ethan", project: "ShoWork42", report: x)
        for k in ["【工作回報】Ethan（ShoWork42）：做事", "完成度 50%", "信心 70%", "摘要：改完收件匣", "方法與工具：讀 3 檔＋swift test", "選項：好／不要", "報告：/r.html"] {
            #expect(s.contains(k))
        }
        #expect(CardRelay.text(name: "A", project: nil, report: r("y", at: t0)).contains("（沒寫 --how）"))
    }

    @Test("派工單的 done／review／blocked 已有派工回報，不重複轉；working 照轉")
    func noDuplicateTaskReport() {
        var st = CardRelay.State(); st.seeded = true
        var done = r("做完", at: t0); done.task = "T1"; done.status = .done
        #expect(CardRelay.plan(reports: ["a": done], captain: "c", captainLive: true, state: &st, now: t0, text: txt).isEmpty)
        var w = r("進行中", at: t0); w.task = "T1"
        #expect(CardRelay.plan(reports: ["b": w], captain: "c", captainLive: true, state: &st, now: t0, text: txt).count == 1)
    }
}
