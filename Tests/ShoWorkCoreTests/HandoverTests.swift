import Foundation
import Testing
@testable import ShoWorkCore

// ctx 自動交接（T1024155358）：假名、假路徑
@Suite("Handover")
struct HandoverTests {
    let t0 = Date(timeIntervalSince1970: 1_792_650_000)
    func rec(_ sid: String, pid: Int32 = 100, cwd: String = "/x/專案A", state: HandoverRecord.State = .pending, ago: TimeInterval = 60) -> HandoverRecord {
        HandoverRecord(sid: sid, pid: pid, cwd: cwd, name: "小明", handoff: "/x/專案A/docs/HANDOFF.md", summary: "下一步做按鈕", at: t0 - ago, state: state)
    }

    @Test("③ 認領：compact 同 sid；clear 同行程；新開同資料夾且原 session 已不在")
    func match() {
        let a = rec("舊A")
        #expect(Handover.match([a], sid: "舊A", pid: 100, cwd: nil, source: "compact", live: [], now: t0)?.sid == "舊A")
        #expect(Handover.match([a], sid: "新B", pid: 100, cwd: nil, source: "clear", live: [], now: t0)?.sid == "舊A")
        #expect(Handover.match([a], sid: "新B", pid: 999, cwd: "/x/專案A/", source: "startup", live: [], now: t0)?.sid == "舊A")
        // 原 session 還活著（同資料夾另一個人）⇒ 不搶
        #expect(Handover.match([a], sid: "新B", pid: 999, cwd: "/x/專案A", source: "startup", live: ["舊A"], now: t0) == nil)
        // 別的資料夾、超過 60 分鐘、已認領過 ⇒ 不認
        #expect(Handover.match([a], sid: "新B", pid: 999, cwd: "/x/專案B", source: "startup", live: [], now: t0) == nil)
        #expect(Handover.match([rec("舊A", ago: 3700)], sid: "新B", pid: 100, cwd: nil, source: "clear", live: [], now: t0) == nil)
        #expect(Handover.match([rec("舊A", state: .taken)], sid: "新B", pid: 100, cwd: nil, source: "clear", live: [], now: t0) == nil)
        // compact 不會去認別人的
        #expect(Handover.match([a], sid: "新B", pid: 100, cwd: nil, source: "compact", live: [], now: t0) == nil)
    }

    @Test("② 送 /clear 的條件：最後一張卡是 wrapup、閒著、鍵盤 60 秒沒動")
    func ready() {
        func ok(_ s: HandoverRecord.State = .pending, kind: String? = "wrapup", working: Bool = false, dialog: Bool = false,
                last: TimeInterval = 30, key: TimeInterval = 60) -> Bool {
            Handover.readyToClear(state: s, lastKind: kind, working: working, dialog: dialog, lastActivity: t0 - last, keyIdle: key, now: t0)
        }
        #expect(ok())
        #expect(!ok(.interrupted))
        #expect(!ok(.clearing))
        #expect(!ok(kind: nil))           // 收尾後又發了一般卡（在問問題／還在做）
        #expect(!ok(working: true))
        #expect(!ok(dialog: true))
        #expect(!ok(last: 2))
        #expect(!ok(key: 3))              // Kang 正在打字
        #expect(!ok(key: 59))
    }

    @Test("閉環驗證：終端機標題開頭要是英文名")
    func title() {
        #expect(Handover.titleMatches("✳ Quinn-整理名片", name: "Quinn"))
        #expect(Handover.titleMatches("◐ Quinn", name: "Quinn"))
        #expect(!Handover.titleMatches("✳ Quinn2-整理名片", name: "Quinn"))
        #expect(!Handover.titleMatches("✳ Handoff 88", name: "Quinn"))
        #expect(!Handover.titleMatches("", name: "Quinn"))
    }

    @Test("接手提示：名字、交接路徑、派工單")
    func context() {
        let c = Handover.resumeContext(rec("舊A"), tasks: ["T1"])
        #expect(c.hasPrefix("【自動接手】你是 小明 的接手") && c.contains("/x/專案A/docs/HANDOFF.md") && c.contains("T1") && c.contains("下一步做按鈕"))
        #expect(Handover.kickoff(rec("舊A")).contains("/x/專案A/docs/HANDOFF.md"))
        #expect(rec("舊A").label == "已收尾待 /clear")
        #expect(rec("舊A", state: .taken).label == nil)
    }

    @Test("收尾卡：一定要帶存在的交接檔，預設 done")
    func card() throws {
        let f = FileManager.default.temporaryDirectory.appendingPathComponent("handover-test-\(UUID().uuidString).md")
        try Data("x".utf8).write(to: f)
        defer { try? FileManager.default.removeItem(at: f) }
        let r = try SelfReport.parse(args: ["--kind", "wrapup", "--handoff", f.path, "--summary", "接手重點"]).get()
        #expect(r.isWrapup && r.status == .done && r.handoff == f.path)
        if case .success = SelfReport.parse(args: ["--kind", "wrapup", "--summary", "x"]) { Issue.record("沒帶 --handoff 要失敗") }
        if case .success = SelfReport.parse(args: ["--kind", "wrapup", "--handoff", "/不存在/HANDOFF.md"]) { Issue.record("檔不存在要失敗") }
        if case .success = SelfReport.parse(args: ["--kind", "wrapup", "--handoff", "docs/HANDOFF.md"]) { Issue.record("相對路徑要失敗") }
    }

    @Test("巡檢列出已收尾、還沒 /clear 的人")
    func alarm() {
        var e = RosterEntry(name: "小明", sessionId: "a", pid: 1, kind: nil, project: "專案A", root: nil, column: .done, reason: "", title: "", summary: nil,
                            ctx: 72, lastActivity: t0, captain: false, sameProject: [])
        let plain = CaptainLink.alarm(Roster(at: t0, captain: nil, entries: [e]), pending: 0, now: t0)
        e.handover = "已收尾待 /clear"
        let a = CaptainLink.alarm(Roster(at: t0, captain: nil, entries: [e]), pending: 0, now: t0)
        #expect(a.text.contains("已收尾、還沒 /clear：小明（已收尾待 /clear）"))
        #expect(a.sig != plain.sig)
    }
}
