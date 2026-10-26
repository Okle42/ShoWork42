import Foundation
import Testing
@testable import ShoWorkCore

@Suite("Board")
struct BoardTests {
    let now = Date(timeIntervalSince1970: 1_791_440_000)

    @Test("分欄：紅＝待審、忙＝進行中、忙太久＝卡住、綠＝待審、閒＝完成")
    func columns() {
        #expect(Board.column(status: "busy", glow: .input, lastActivity: now, now: now).0 == .review)
        #expect(Board.column(status: "busy", glow: nil, lastActivity: now.addingTimeInterval(-60), now: now).0 == .active)
        #expect(Board.column(status: "busy", glow: nil, lastActivity: now.addingTimeInterval(-11 * 60), now: now).0 == .stuck)
        #expect(Board.column(status: "idle", glow: .working, lastActivity: now, now: now).0 == .active)   // hook 比 status 檔快
        #expect(Board.column(status: "idle", glow: .done, lastActivity: now, now: now).0 == .review)
        #expect(Board.column(status: "idle", glow: nil, lastActivity: now, now: now).0 == .done)
        #expect(Board.column(status: "shell", glow: nil, lastActivity: now.addingTimeInterval(-3600), now: now).0 == .done)   // 只是背景指令還在
        #expect(Board.column(status: "busy", glow: nil, lastActivity: nil, now: now).0 == .active)        // 沒紀錄不判卡住
    }

    @Test("session 檔（10-08 實際格式，多的欄位略過）")
    func sessionRecord() throws {
        let j = #"{"pid":7369,"sessionId":"264343ad-21db","cwd":"/Users/k","startedAt":1,"kind":"interactive","name":"k-b3","status":"busy","updatedAt":1791448526068,"peerFeatures":["notify_idle"]}"#
        let s = try #require(SessionRecord.decode(Data(j.utf8)))
        #expect(s.pid == 7369 && s.status == "busy" && s.projectSlug == "-Users-k")
        #expect(SessionRecord(pid: 1, sessionId: "x", cwd: "/private/tmp/a.b").projectSlug == "-private-tmp-a-b")
        #expect(SessionRecord(pid: 1, sessionId: "x", cwd: "/t/accept/C-快做完").projectSlug == "-t-accept-C----")
        #expect(SessionRecord(pid: 1, sessionId: "x", cwd: "/t/claude-501/a_b").projectSlug == "-t-claude-501-a-b")
    }

    @Test("對話紀錄：標題、最後 cwd、最後一句、排隊（系統通知不算）、第一行壞掉")
    func transcript() {
        let lines = [
            #"cut-off garbage {"#,
            #"{"type":"user","cwd":"/r/A","timestamp":"2026-10-08T05:29:00.000Z"}"#,
            #"{"type":"ai-title","aiTitle":"語音備忘錄整理"}"#,
            #"{"type":"assistant","cwd":"/r/B","timestamp":"2026-10-08T05:30:00.500Z","message":{"content":[{"type":"text","text":"做完了"},{"type":"tool_use"}]}}"#,
            #"{"type":"assistant","timestamp":"2026-10-08T05:30:01.000Z","message":{"content":[{"type":"tool_use"}]}}"#,
            #"{"type":"queue-operation","operation":"enqueue","content":"先做 A"}"#,
            #"{"type":"queue-operation","operation":"dequeue"}"#,
            #"{"type":"queue-operation","operation":"enqueue","content":"<task-notification>x"}"#,
            #"{"type":"queue-operation","operation":"enqueue","content":"再做 B"}"#,
            #"{"type":"last-prompt","lastPrompt":"好"}"#,
        ]
        let t = TranscriptInfo.parse(Data(lines.joined(separator: "\n").utf8))
        #expect(t.title == "語音備忘錄整理")
        #expect(t.lastCwd == "/r/B")
        let mem = TranscriptInfo.parse(Data([#"{"cwd":"/h/github-repos/ProjectB"}"#, #"{"cwd":"/h/.claude/projects/-h/memory"}"#].joined(separator: "\n").utf8))
        #expect(mem.lastCwd == "/h/.claude/projects/-h/memory" && mem.lastWorkCwd == "/h/github-repos/ProjectB")
        #expect(t.lastAssistantText == "做完了")
        #expect(t.lastPrompt == "好")
        let fresh = TranscriptInfo.parse(Data(#"{"type":"user","message":{"role":"user","content":"回答 1+1"}}"#.utf8))
        #expect(fresh.lastPrompt == "回答 1+1")
        let tool = TranscriptInfo.parse(Data(#"{"type":"user","message":{"content":[{"type":"tool_result"}]}}"#.utf8))
        #expect(tool.lastPrompt == nil)
        #expect(t.queued == ["再做 B"])
        #expect(t.lastActivity == TranscriptInfo.iso("2026-10-08T05:30:01.000Z"))
    }

    @Test("agent team 設定與信箱（10-08 實測格式）")
    func team() throws {
        let c = #"{"name":"session-16b861fc","createdAt":1,"leadAgentId":"team-lead@s","leadSessionId":"16b861fc-16dc","members":[{"agentId":"team-lead@s","name":"team-lead","agentType":"team-lead","joinedAt":1,"tmuxPaneId":"leader","subscriptions":[],"backendType":"in-process"},{"agentId":"coder@s","name":"coder","color":"blue","joinedAt":2,"agentType":"general-purpose","model":"sonnet","prompt":"…"}]}"#
        let cfg = try #require(TeamConfig.decode(Data(c.utf8)))
        #expect(cfg.teammates.map(\.name) == ["coder"])
        let ib = #"[{"from":"tester","text":"5 個測試全過","summary":"回報","timestamp":"2026-10-08T05:31:13.333Z","color":"green","msgV":1,"msg_id":"5266","type":"message","read":false}]"#
        let m = TeamMessage.decodeInbox(Data(ib.utf8), owner: "team-lead")
        #expect(m.count == 1 && m[0].to == "team-lead" && m[0].key == "5266")
        #expect(TeamMessage.decodeInbox(Data("[]".utf8), owner: "x").isEmpty)
    }

    @Test("摘要去掉 Markdown、空行併成一行")
    func plain() {
        #expect(Board.plain("# ProjectC 檢查報告\n\n**commit 有**，`push` 還沒有。\n- 第一點\n|a|b|\n|---|---|") == "ProjectC 檢查報告 commit 有，push 還沒有。 第一點 a b")
    }

    @Test("組看板：無頭 session 不上板、自報與審核掛上、舊審核不放")
    func buildP2() {
        let s1 = SessionRecord(pid: 1, sessionId: "A", cwd: "/h", status: "idle", updatedAt: 2)
        var head = SessionRecord(pid: 2, sessionId: "H", cwd: "/h", status: "busy", updatedAt: 1); head.entrypoint = "sdk-cli"
        var t = TranscriptInfo(); t.lastPromptAt = now.addingTimeInterval(-100); t.lastActivity = now.addingTimeInterval(-10)
        let rep = SelfReport(status: .review, progress: 90, confidence: 60, ask: "要 push 嗎", at: now.addingTimeInterval(-20))
        let old = Review(progress: 1, confidence: 1, verdict: "fail", issues: [], turn: now.addingTimeInterval(-500), model: "sonnet")
        let cards = Board.build(sessions: [s1, head], transcripts: ["A": t], glows: [1: .done], teams: [], inbox: [],
                                reports: ["A": rep], reviews: ["A": old], now: now, home: "/h", isRepo: { _ in false })
        #expect(cards.map(\.id) == ["A"])
        #expect(cards[0].column == .review && cards[0].reason == "要你決定：要 push 嗎" && cards[0].report == rep && cards[0].review == nil)
    }

    @Test("專案名：git 根目錄、家目錄、非 repo")
    func project() {
        let repos: Set = ["/h/github-repos/ProjectA"]
        let f = { (p: String) in repos.contains(p) }
        #expect(Board.projectName(cwd: "/h/github-repos/ProjectA/docs/x", home: "/h", isRepo: f) == "ProjectA")
        #expect(Board.projectName(cwd: "/h", home: "/h", isRepo: f) == "（家目錄）")
        #expect(Board.projectName(cwd: "/h/Desktop/tmp", home: "/h", isRepo: f) == "tmp")
        #expect(Board.projectName(cwd: nil, home: "/h", isRepo: f) == "（不明）")
    }

    @Test("組看板：每個 session 一張卡＋排隊訊息成待辦，隊員與訊息掛在隊長卡上")
    func build() {
        let s1 = SessionRecord(pid: 1, sessionId: "A", cwd: "/h", status: "busy", updatedAt: 2)
        let s2 = SessionRecord(pid: 2, sessionId: "B", cwd: "/h", status: "idle", updatedAt: 1)
        var t1 = TranscriptInfo(); t1.title = "做 ProjectA"; t1.lastCwd = "/h/r/ProjectA"; t1.lastActivity = now; t1.queued = ["下一件"]
        let team = TeamConfig(name: "session-A", leadSessionId: "A", members: [
            TeamMember(agentId: "team-lead@A", name: "team-lead", agentType: "team-lead"),
            TeamMember(agentId: "coder@A", name: "coder", agentType: "general-purpose")])
        let msg = TeamMessage(from: "coder", text: "好了", to: "team-lead")
        let cards = Board.build(sessions: [s2, s1], transcripts: ["A": t1], glows: [2: .done], teams: [team], inbox: [msg],
                                now: now, home: "/h", isRepo: { $0 == "/h/r/ProjectA" })
        #expect(cards.map(\.id) == ["A", "A#q0", "B"])
        #expect(cards[0].column == .active && cards[0].project == "ProjectA" && cards[0].teammates == ["coder"] && cards[0].messages == [msg])
        #expect(cards[1].column == .todo && cards[1].title == "下一件")
        #expect(cards[2].column == .review && cards[2].project == "（家目錄）")
    }
}
