import Foundation
import Testing
@testable import ShoWorkCore

/// 11-10 隊長省額度：只推要隊長動手的事（工作回報、巡檢、開工卡、換哨提醒）
@Suite("CaptainQuiet")
struct CaptainQuietTests {
    let t0 = Date(timeIntervalSince1970: 1_792_500_000)
    let txt: (String, SelfReport) -> String = { sid, r in "\(sid):\(r.summary ?? "")" }
    func card(_ s: SelfReport.Status, _ summary: String, at: Date, ask: String? = nil) -> SelfReport {
        var r = SelfReport(status: s, progress: 50, confidence: 70, summary: summary, doing: "做事", at: at)
        r.ask = ask
        return r
    }

    @Test("工作回報：預設只推 review／blocked／帶 --ask；done、working 只記不推（之後也不補送）")
    func actionableOnly() {
        var st = CardRelay.State(); st.seeded = true
        let quiet = CardRelay.plan(reports: ["w": card(.working, "做事中", at: t0), "d": card(.done, "做完", at: t0),
                                             "r": card(.review, "要審", at: t0), "b": card(.blocked, "卡住", at: t0),
                                             "q": card(.working, "問一下", at: t0, ask: "要 push 嗎")],
                                   captain: "cap", captainLive: true, state: &st, now: t0, text: txt)
        #expect(Set(quiet.map(\.sessionId)) == ["r", "b", "q"])
        // done／working 已記成看過：同一張卡之後不會補送
        #expect(CardRelay.plan(reports: ["w": card(.working, "做事中", at: t0), "d": card(.done, "做完", at: t0)],
                               captain: "cap", captainLive: true, state: &st, now: t0 + 120, text: txt).isEmpty)
        // 同一個人改成卡住 ⇒ 推
        #expect(CardRelay.plan(reports: ["w": card(.blocked, "卡住了", at: t0 + 130)],
                               captain: "cap", captainLive: true, state: &st, now: t0 + 130, text: txt).map(\.sessionId) == ["w"])
    }

    @Test("開關改回舊行為：done／working 照推")
    func legacy() {
        var st = CardRelay.State(); st.seeded = true
        let out = CardRelay.plan(reports: ["w": card(.working, "x", at: t0), "d": card(.done, "y", at: t0)],
                                 captain: "cap", captainLive: true, state: &st, now: t0, policy: .legacy, text: txt)
        #expect(out.count == 2)
    }

    @Test("開工卡：預設只進收件匣不推；captain.relayStartCards 打開才推")
    func startCards() {
        let start = SelfReport(status: .working, summary: "改按鈕", doing: "改按鈕", kind: "start", at: t0)
        var st = CardRelay.State(); st.seeded = true
        #expect(CardRelay.plan(reports: ["a": start], captain: "c", captainLive: true, state: &st, now: t0, text: txt).isEmpty)
        var st2 = CardRelay.State(); st2.seeded = true
        let p = CardRelay.Policy(actionableOnly: true, pushStart: true)
        #expect(CardRelay.plan(reports: ["a": start], captain: "c", captainLive: true, state: &st2, now: t0, policy: p, text: txt).count == 1)
    }

    @Test("設定讀取：沒設過＝新行為；設了照設定")
    func policyFromDefaults() throws {
        let name = "showork.test.quiet.\(UUID().uuidString)"
        let d = try #require(UserDefaults(suiteName: name))
        defer { d.removePersistentDomain(forName: name) }
        #expect(CardRelay.Policy.from(d) == .quiet)
        d.set(false, forKey: CardRelay.Policy.actionableKey); d.set(true, forKey: CardRelay.Policy.startKey)
        #expect(CardRelay.Policy.from(d) == .legacy)
        #expect(CaptainLink.captainCtxLimit(d) == 750_000)
        d.set(400_000, forKey: CaptainLink.captainCtxKey)
        #expect(CaptainLink.captainCtxLimit(d) == 400_000)
        d.set(-1, forKey: CaptainLink.captainCtxKey)
        #expect(CaptainLink.captainCtxLimit(d) == nil)
    }

    func entry(_ n: String, column: BoardColumn = .done, tokens: Int? = nil, idle: Double = 60, cap: Bool = false, handover: String? = nil) -> RosterEntry {
        RosterEntry(name: n, sessionId: n, pid: 1, kind: nil, project: "專案A", root: nil, column: column, reason: "", title: "", summary: nil,
                    ctx: nil, ctxTokens: tokens, lastActivity: t0 - idle, captain: cap, sameProject: [], handover: handover)
    }

    @Test("巡檢：沒事＝空（不推）；閒置但沒派工單不算；開工卡不算")
    func alarmNothing() {
        let r = Roster(at: t0, captain: "隊長", entries: [entry("小明"), entry("阿華", idle: 7200), entry("隊長", tokens: 900_000, cap: true)])
        let start = CaptainInboxItem(id: "SAAAA", kind: .start, at: t0 - 60, sid: "小明", name: "小明", project: nil, text: "開工")
        let a = CaptainLink.alarmActions(r, openTaskSessions: [], inbox: [start], ctxLimit: 250_000, now: t0)
        #expect(a.reasons.isEmpty)
        #expect(a.sig == "")
    }

    @Test("巡檢：卡住、待審、ctx 到門檻、有派工單閒太久、擋下、預告都算；同一批指紋不變")
    func alarmActionable() {
        let r = Roster(at: t0, captain: "隊長", entries: [
            entry("卡卡", column: .stuck), entry("審審", column: .review), entry("滿滿", tokens: 300_000),
            entry("收好", tokens: 300_000, handover: "已收尾待 /clear"), entry("閒閒", idle: 7200), entry("隊長", cap: true)])
        let block = CaptainInboxItem(id: "BAAAA", kind: .block, at: t0 - 60, sid: "x", name: "x", project: nil, kinds: ["rm"], text: "rm -rf")
        let notice = CaptainInboxItem(id: "NAAAA", kind: .notice, at: t0 - 60, sid: "x", name: "x", project: nil, kinds: ["mv"], text: "mv")
        var acked = notice; acked.id = "NBBBB"; acked.acked = t0
        let a = CaptainLink.alarmActions(r, openTaskSessions: ["閒閒"], inbox: [block, notice, acked], ctxLimit: 250_000, now: t0)
        let all = a.reasons.joined(separator: "；")
        for k in ["卡住：卡卡", "待審／等回答：審審", "ctx 到門檻 250k：滿滿 300k", "閒置超過 30 分鐘：閒閒", "擋下等放行 1 則：BAAAA", "動作預告沒 ack 1 則"] {
            #expect(all.contains(k))
        }
        #expect(!all.contains("收好"))          // 已收尾的交給自動 /clear，不算
        #expect(CaptainLink.alarmActions(r, openTaskSessions: ["閒閒"], inbox: [block, notice], ctxLimit: 250_000, now: t0 + 30).sig == a.sig)
        // 放行了 ⇒ 指紋變
        var rel = block; rel.released = t0
        #expect(CaptainLink.alarmActions(r, openTaskSessions: ["閒閒"], inbox: [rel, notice], ctxLimit: 250_000, now: t0).sig != a.sig)
        let text = CaptainLink.alarmQuietText(reasons: a.reasons, full: "【巡檢時間】在線 5 人")
        #expect(text.hasPrefix("【巡檢時間】要處理：卡住：卡卡"))
        #expect(text.hasSuffix("\n在線 5 人"))
    }

    @Test("換哨提醒：隊長 ctx 過門檻送一次；降下來重新計；組員不算")
    func shift() {
        func roster(_ t: Int) -> Roster { Roster(at: t0, captain: "隊長", entries: [entry("隊長", tokens: t, cap: true), entry("小明", tokens: 999_000)]) }
        let a = CaptainLink.shiftReminder(roster(700_000), limit: 750_000, sent: [], owner: "Boss", handoff: "交接.md")
        #expect(a.text == nil && a.sent.isEmpty)
        let b = CaptainLink.shiftReminder(roster(760_000), limit: 750_000, sent: a.sent, owner: "Boss", handoff: "交接.md")
        let t = b.text ?? ""
        #expect(t.hasPrefix("【換哨提醒】隊長 context 已用 760k（門檻 750k）"))
        #expect(t.contains("交接.md") && t.contains("請Boss在這個視窗打 /clear，再說「換哨」"))
        #expect(b.sent == ["隊長"])
        #expect(CaptainLink.shiftReminder(roster(800_000), limit: 750_000, sent: b.sent, owner: "Boss", handoff: "x").text == nil)
        let c = CaptainLink.shiftReminder(roster(10_000), limit: 750_000, sent: b.sent, owner: "Boss", handoff: "x")
        #expect(c.sent.isEmpty)
        #expect(CaptainLink.shiftReminder(roster(900_000), limit: nil, sent: [], owner: "Boss", handoff: "x").text == nil)
    }

    @Test("隊長守則文字跟著改：開工卡不推、巡檢沒事不送、換哨提醒")
    func manual() {
        let m = Captain.manual(showork: "/x/showork")
        #expect(m.contains("只進你的收件匣、不推給你"))
        #expect(m.contains("沒事不送"))
        #expect(m.contains("【換哨提醒】"))
        #expect(m.contains("做完、做事中的卡只記在看板"))
        #expect(!m.contains("無變化"))
    }

    @Test("本機設定的隊長交接文件：沒設用通用說法")
    func handoffName() {
        #expect(LocalConfig().captainHandoffName == "隊長交接文件")
        var c = LocalConfig(); c.captainHandoff = "~/交接.md"
        #expect(c.captainHandoffName == "~/交接.md")
    }
}
