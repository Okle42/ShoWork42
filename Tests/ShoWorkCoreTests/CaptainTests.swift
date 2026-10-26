import Foundation
import Testing
@testable import ShoWorkCore

@Suite("隊長派工")
struct CaptainTests {
    func card(_ sid: String, _ project: String, name: String? = nil) -> BoardCard {
        BoardCard(id: sid, column: .done, reason: "閒置", project: project, title: "t", pid: 1, sessionId: sid, name: name ?? "s-\(sid)")
    }

    @Test("同專案多開才警告；隊長、家目錄、排隊卡不算")
    func sameProject() {
        let cards = [card("A", "ProjectA"), card("B", "ProjectA"), card("C", "專案A"), card("D", "（家目錄）"), card("E", "（家目錄）"),
                     card("K", "ProjectA"), BoardCard(id: "A#q0", column: .todo, reason: "", project: "ProjectA", title: "q", pid: 1, sessionId: "A")]
        let d = Captain.sameProject(cards, captain: "K")
        #expect(d["A"] == ["s-B"])
        #expect(d["B"] == ["s-A"])
        #expect(d["C"] == nil && d["D"] == nil && d["K"] == nil)
    }

    @Test("隊長卡列出派出去的單；對方卡只列還沒結束、交給它的")
    func annotate() {
        let t1 = CaptainTask(id: "T1", from: "K", to: "s-A", toSession: "A", text: "做 X")
        var t2 = CaptainTask(id: "T2", from: "K", to: "s-A", toSession: "A", text: "做 Y"); t2.state = .done
        let t3 = CaptainTask(id: "T3", from: "K", to: "s-B", text: "做 Z")          // 只有名字（派出時名冊沒更新）
        let out = Captain.annotate([card("K", "x"), card("A", "a"), card("B", "b")], captain: "K", tasks: [t1, t2, t3])
        #expect(out[0].captain && out[0].tasks.count == 3)
        #expect(out[1].tasks.map(\.id) == ["T1"])
        #expect(out[2].tasks.map(\.id) == ["T3"])
    }

    @Test("回報更新單子；取消後不再變")
    func apply() {
        var t = CaptainTask(id: "T", from: "K", to: "a", text: "x")
        t.apply(SelfReport(status: .working, summary: "開工"))
        #expect(t.state == .working && t.summary == "開工")
        t.apply(SelfReport(status: .done, summary: "好了", ask: "要不要 push"))
        #expect(t.state == .review && t.ask == "要不要 push")
        t.apply(SelfReport(status: .done, summary: "推了"))
        #expect(t.state == .done && t.ask == nil)
        t.state = .cancelled
        t.apply(SelfReport(status: .working))
        #expect(t.state == .cancelled)
    }

    @Test("單號同一秒不撞；card 吃 --task")
    func ids() throws {
        let now = Date(timeIntervalSince1970: 1_791_500_000)
        let a = Captain.newId(now: now, existing: [])
        #expect(Captain.newId(now: now, existing: [a]) == a + "-2")
        #expect(try SelfReport.parse(args: ["--status", "done", "--task", "T1"]).get().task == "T1")
    }

    @Test("派工全文：第一行就看得出是什麼事，附回報方式")
    func message() {
        let m = Captain.message(CaptainTask(id: "T9", from: "K", to: "a", text: "修登入\n判準：測試全過"), showork: "/x/showork")
        #expect(m.hasPrefix("【隊長派工 T9】修登入\n判準：測試全過"))
        #expect(m.contains("--task T9"))
    }
}

@Suite("跨 session 通知不算待辦")
struct CrossSessionQueueTests {
    @Test func idleNoticeIsNotTodo() {
        let lines = [
            #"{"type":"queue-operation","operation":"enqueue","content":"[Cross-session idle notice] \"x\" is idle now"}"#,
            #"{"type":"queue-operation","operation":"enqueue","content":"幫我看一下"}"#,
        ].joined(separator: "\n")
        #expect(TranscriptInfo.parse(Data(lines.utf8)).queued == ["幫我看一下"])
    }
}

@Suite("派工直送與接力")
struct RelayTests {
    @Test("直送格式：先 auth 再一則 user 訊息，包在 cross-session-message 裡")
    func lines() throws {
        let l = Peer.lines(token: "tok", text: "做 X\n第二行", fromName: "隊\"長", replyTo: "/tmp/cc-socks/1.sock", id: "m1")
        #expect(l.count == 2)
        let a = try #require(try JSONSerialization.jsonObject(with: Data(l[0].utf8)) as? [String: Any])
        #expect(a["type"] as? String == "auth" && a["token"] as? String == "tok")
        let m = try #require(try JSONSerialization.jsonObject(with: Data(l[1].utf8)) as? [String: Any])
        #expect(m["type"] as? String == "user" && m["msg_id"] as? String == "m1" && m["from"] as? String == "uds:/tmp/cc-socks/1.sock")
        let content = ((m["message"] as? [String: Any])?["content"] as? String) ?? ""
        #expect(content.hasPrefix("<cross-session-message from=\"uds:/tmp/cc-socks/1.sock\" from-name=\"隊&quot;長\">\n做 X\n第二行\n"))
    }

    @Test("做完才接力、只接一次；附上前一棒回報")
    func nextLeg() {
        var t = CaptainTask(id: "T1", from: "K", to: "a", text: "查 log", thenTo: "b", thenText: "修 bug")
        #expect(Captain.nextLeg(of: t, id: "T2", now: Date()) == nil)
        t.apply(SelfReport(status: .done, summary: "找到是 timeout"))
        let n = Captain.nextLeg(of: t, id: "T2", now: Date())
        #expect(n?.to == "b" && n?.after == "T1" && n?.from == "K")
        #expect(n?.text.contains("修 bug") == true && n?.text.contains("找到是 timeout") == true)
        t.followUp = "T2"
        #expect(Captain.nextLeg(of: t, id: "T3", now: Date()) == nil)
        t.apply(SelfReport(status: .done, summary: "x", ask: "要 push 嗎"))
        #expect(t.state == .review && Captain.nextLeg(of: { var x = t; x.followUp = nil; return x }(), id: "T3", now: Date()) == nil)
    }

    @Test("同一個狀態只通知隊長一次；做事中不通知")
    func notify() {
        var t = CaptainTask(id: "T1", from: "K", to: "a", text: "x")
        #expect(!Captain.shouldNotify(t))
        t.apply(SelfReport(status: .working)); #expect(!Captain.shouldNotify(t))
        t.apply(SelfReport(status: .blocked, summary: "沒權限")); #expect(Captain.shouldNotify(t))
        t.notified = .blocked; #expect(!Captain.shouldNotify(t))
        t.apply(SelfReport(status: .done, summary: "好了")); #expect(Captain.shouldNotify(t))
        #expect(Captain.reportText(t).hasPrefix("【派工回報 T1】a：完成——好了"))
    }
}
