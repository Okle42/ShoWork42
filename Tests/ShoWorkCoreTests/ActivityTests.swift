import Foundation
import Testing
@testable import ShoWorkCore

// 10-20：對話紀錄多看出的四件事（動作、卡住原因、子 agent、token）。片段照 10-20 實際 jsonl 的欄位縮小
@Suite("Activity")
struct ActivityTests {
    let now = Date(timeIntervalSince1970: 1_791_440_000)

    func parse(_ lines: [String]) -> TranscriptInfo { TranscriptInfo.parse(Data(lines.joined(separator: "\n").utf8)) }
    func use(_ id: String, _ name: String, _ input: String = "{}") -> String {
        #"{"type":"assistant","message":{"id":"msg_\#(id)","role":"assistant","content":[{"type":"tool_use","id":"\#(id)","name":"\#(name)","input":\#(input)}]}}"#
    }
    func result(_ id: String, extra: String = "") -> String {
        #"{"type":"user"\#(extra),"message":{"role":"user","content":[{"tool_use_id":"\#(id)","type":"tool_result","content":"ok"}]}}"#
    }
    let prompt = #"{"type":"user","message":{"role":"user","content":"幫我改一下"}}"#
    let text = #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"好"}]}}"#

    @Test("動作：看最後一個還沒回結果的工具；沒有就是在想")
    func activity() {
        #expect(parse([prompt]).currentActivity == .thinking)
        #expect(parse([prompt, text]).currentActivity == .thinking)
        #expect(parse([use("a", "Read")]).currentActivity == .reading)
        #expect(parse([use("a", "Read"), result("a")]).currentActivity == .thinking)            // 讀完了
        #expect(parse([use("a", "Edit")]).currentActivity == .editing)
        #expect(parse([use("a", "Bash", #"{"command":"ls"}"#)]).currentActivity == .running)
        #expect(parse([use("a", "WebSearch")]).currentActivity == .searching)
        #expect(parse([use("a", "Agent", #"{"description":"找檔案","subagent_type":"Explore"}"#)]).currentActivity == .searching)
        #expect(parse([use("a", "Agent", #"{"description":"寫研究","subagent_type":"general-purpose"}"#)]).currentActivity == .delegating)
        #expect(parse([use("a", "mcp__screen42__click")]).currentActivity == .running)          // 不認得的工具＝執行
        // 平行呼叫：Read 回來了、Write 還沒 ⇒ editing
        #expect(parse([use("a", "Read"), use("b", "Write"), result("a")]).currentActivity == .editing)
        #expect(AIActivity.of(tool: "Grep") == .reading && AIActivity.of(tool: "WebFetch") == .reading)
        #expect(AIActivity.of(tool: "NotebookEdit") == .editing && AIActivity.of(tool: "Task") == .delegating)
    }

    @Test("看板：只有進行中才有動作，其餘 none")
    func activityOnlyWhenActive() {
        var t = parse([use("a", "Edit")]); t.lastActivity = now
        let busy = SessionRecord(pid: 1, sessionId: "s1", cwd: "/r", status: "busy")
        let idle = SessionRecord(pid: 2, sessionId: "s2", cwd: "/r", status: "idle")
        let cards = Board.build(sessions: [busy, idle], transcripts: ["s1": t, "s2": t], glows: [:], teams: [], inbox: [],
                                now: now, home: "/h", isRepo: { _ in false })
        #expect(cards.first { $0.id == "s1" }?.activity == .editing)
        #expect(cards.first { $0.id == "s2" }?.activity == AIActivity.none)
    }

    @Test("卡住原因：權限、額度、API 錯誤、長指令（測試／建置／安裝），判不出 nil")
    func blocked() {
        // 等你回答時還有工具沒結果 ⇒ 卡在權限提示
        #expect(parse([use("a", "Bash", #"{"command":"rm x"}"#)]).blockedReason(waiting: true, stuck: false) == .permission)
        // 等你回答但是在問問題 ⇒ 不是權限
        #expect(parse([use("a", "AskUserQuestion")]).blockedReason(waiting: true, stuck: false) == nil)
        // 權限被拒（實際格式：最外層 toolDenialKind）
        let denied = parse([use("a", "Bash"), result("a", extra: #","toolDenialKind":"user-rejected""#)])
        #expect(denied.blockedReason(waiting: true, stuck: false) == .permission)
        #expect(denied.blockedReason(waiting: false, stuck: false) == nil)              // 不在卡住／等你就不填
        // 額度（10-20 實際：error rate_limit、apiErrorStatus 429）
        let rl = #"{"type":"assistant","error":"rate_limit","isApiErrorMessage":true,"apiErrorStatus":"429","message":{"id":"x","model":"<synthetic>","role":"assistant","content":[{"type":"text","text":"You've hit your session limit · resets 4:50am"}]}}"#
        #expect(parse([prompt, rl]).blockedReason(waiting: false, stuck: true) == .rateLimit)
        let se = #"{"type":"assistant","error":"server_error","isApiErrorMessage":true,"message":{"role":"assistant","content":[{"type":"text","text":"API Error: Connection lost mid-response."}]}}"#
        #expect(parse([prompt, se]).blockedReason(waiting: false, stuck: true) == .apiError)
        #expect(parse([prompt, se, prompt]).blockedReason(waiting: false, stuck: true) == nil)   // 之後又有新對話 ⇒ 清掉
        // 長時間 Bash
        #expect(parse([use("a", "Bash", #"{"command":"swift test 2>&1 | tail"}"#)]).blockedReason(waiting: false, stuck: true) == .testRun)
        #expect(parse([use("a", "Bash", #"{"command":"swift build -c release"}"#)]).blockedReason(waiting: false, stuck: true) == .build)
        #expect(parse([use("a", "Bash", #"{"command":"brew install ffmpeg"}"#)]).blockedReason(waiting: false, stuck: true) == .install)
        #expect(parse([use("a", "Bash", #"{"command":"sleep 900"}"#)]).blockedReason(waiting: false, stuck: true) == nil)
        #expect(BlockedReason.of(command: "xcodebuild test -scheme X") == .testRun)
        #expect(BlockedReason.of(command: "npm run build") == .build)
        #expect(BlockedReason.of(command: "pip install -r req.txt") == .install)
        #expect(BlockedReason.of(command: "cat latest.log") == nil)                       // latest 不是 test
    }

    @Test("子 agent：同步的看有沒有結果、背景的看完成通知")
    func subagents() {
        let long = String(repeating: "研", count: 40)
        let a = use("a", "Agent", #"{"description":"\#(long)","subagent_type":"general-purpose","prompt":"..."}"#)
        let t = parse([a])
        #expect(t.subagents(includeSync: true) == [SubagentInfo(description: long, subagentType: "general-purpose")])
        #expect(t.subagents(includeSync: true)[0].description.count == 30)              // 截 30 字
        #expect(t.subagents(includeSync: false).isEmpty)                                // 主 session 停了＝殘留
        #expect(parse([a, result("a")]).subagents(includeSync: true).isEmpty)           // 同步的做完了
        // 背景：結果馬上回 async_launched，之後 task-notification 才算做完
        let bg = use("b", "Agent", #"{"description":"背景研究","subagent_type":"general-purpose","run_in_background":true}"#)
        let launched = result("b", extra: #","toolUseResult":{"isAsync":true,"status":"async_launched","agentId":"afdd48"}"#)
        let t2 = parse([bg, launched])
        #expect(t2.subagents(includeSync: false) == [SubagentInfo(description: "背景研究", subagentType: "general-purpose", background: true)])
        #expect(t2.currentActivity == .thinking)                                        // 主 session 自己沒在等工具
        let note = #"{"type":"queue-operation","operation":"enqueue","content":"<task-notification>\n<task-id>afdd48</task-id>\n<status>completed</status>"}"#
        #expect(parse([bg, launched, note]).subagents(includeSync: false).isEmpty)
        // 10-20 實際：Workflow 也是 async_launched，用 taskId／workflowName；AI 講完一段、背景還在跑 ⇒ 交辦中
        let wf = use("w", "Workflow", #"{"script":"..."}"#)
        let wfDone = result("w", extra: #","toolUseResult":{"status":"async_launched","taskId":"wgw9","taskType":"local_workflow","workflowName":"office3d-upgrade"}"#)
        let t3 = parse([prompt, wf, wfDone, text])
        #expect(t3.subagents(includeSync: false) == [SubagentInfo(description: "office3d-upgrade", subagentType: "local_workflow", background: true)])
        #expect(t3.currentActivity == .delegating)
        #expect(parse([prompt, wf, wfDone, text, prompt]).currentActivity == .thinking)   // 你又交代新的事：AI 自己在想
        let noteUser = #"{"type":"user","origin":{"kind":"task-notification"},"message":{"role":"user","content":"<task-notification>\n<task-id>afdd48</task-id>"}}"#
        #expect(parse([bg, launched, noteUser]).subagents(includeSync: false).isEmpty)
    }

    @Test("token：四種加總、同一則訊息多行只算一次、最後一輪 output、可分段餵")
    func tokens() {
        func asst(_ id: String, _ i: Int, _ o: Int, _ cc: Int, _ cr: Int) -> String {
            #"{"type":"assistant","message":{"id":"\#(id)","role":"assistant","content":[{"type":"text","text":"x"}],"usage":{"input_tokens":\#(i),"output_tokens":\#(o),"cache_creation_input_tokens":\#(cc),"cache_read_input_tokens":\#(cr),"iterations":[{"input_tokens":99}]}}}"#
        }
        let lines = [
            prompt,
            asst("m1", 2, 100, 1000, 5000),
            asst("m1", 2, 100, 1000, 5000),                  // 同一則訊息的第二個區塊，usage 重複
            result("t1"),                                    // 工具結果不算新一輪
            asst("m2", 1, 50, 0, 6000),
            #"{"type":"user","message":{"role":"user","content":"<task-notification>x</task-notification>"}}"#,   // 系統通知不算新一輪
            #"{"type":"user","isMeta":true,"message":{"role":"user","content":"skill 內容"}}"#,
            #"{"type":"user","isCompactSummary":true,"message":{"role":"user","content":"This session is being continued"}}"#,
            prompt,                                          // 新的一輪
            asst("m3", 3, 7, 10, 20),
        ]
        var t = TokenTally()
        t.consume(Data((lines.joined(separator: "\n") + "\n").utf8))
        #expect(t.usage == TokenUsage(input: 6, output: 157, cacheCreation: 1010, cacheRead: 11020, lastTurnOutput: 7))
        #expect(t.usage.total == 6 + 157 + 1010 + 11020)
        // 分兩段餵結果一樣（BoardReader 只餵新增的行）
        var u = TokenTally()
        u.consume(Data((lines.prefix(4).joined(separator: "\n") + "\n").utf8))
        #expect(u.usage.output == 100 && u.usage.lastTurnOutput == 100)
        u.consume(Data((lines.dropFirst(4).joined(separator: "\n") + "\n").utf8))
        #expect(u.usage == t.usage)
        // 圖片陣列的訊息也算你送出的（含 text）
        var v = TokenTally()
        v.consume(Data([asst("a", 0, 9, 0, 0),
                        #"{"type":"user","message":{"role":"user","content":[{"type":"image"},{"type":"text","text":"看這張"}]}}"#,
                        asst("b", 0, 4, 0, 0)].joined(separator: "\n").utf8))
        #expect(v.usage.output == 13 && v.usage.lastTurnOutput == 4)
    }

    @Test("BoardCard：舊 JSON 沒有新欄位也讀得回來，新欄位來回不變")
    func codable() throws {
        let old = #"{"id":"s","column":"active","reason":"工作中","project":"P","title":"T","pid":1,"sessionId":"s","teammates":[],"messages":[]}"#
        let c = try JSONDecoder().decode(BoardCard.self, from: Data(old.utf8))
        #expect(c.activity == AIActivity.none && c.blockedReason == nil && c.subagents.isEmpty && c.tokens == nil && !c.captain)
        var n = c
        n.activity = .editing; n.blockedReason = .rateLimit
        n.subagents = [SubagentInfo(description: "研究", subagentType: "Explore", background: true)]
        n.tokens = TokenUsage(input: 1, output: 2, cacheCreation: 3, cacheRead: 4, lastTurnOutput: 2)
        let back = try JSONDecoder().decode(BoardCard.self, from: JSONEncoder().encode(n))
        #expect(back == n)
    }

    @Test("審查補：背景 agent 全檔追蹤（啟動那行在尾端外也看得到）；中斷不是權限")
    func reviewFixes() {
        let launch = #"{"type":"user","timestamp":"2026-10-20T06:00:00.000Z","message":{"role":"user","content":[{"tool_use_id":"w1","type":"tool_result","content":"started"}]},"toolUseResult":{"status":"async_launched","taskId":"wgw9","taskType":"local_workflow","workflowName":"office3d-upgrade"}}"#
        let agent = #"{"type":"user","message":{"role":"user","content":[{"tool_use_id":"a1","type":"tool_result","content":"started"}]},"toolUseResult":{"isAsync":true,"status":"async_launched","agentId":"ag1","description":"寫測試"}}"#
        let done = #"{"type":"queue-operation","operation":"enqueue","content":"<task-notification>\n<task-id>ag1</task-id>\n<status>completed</status>"}"#
        var t = TokenTally()
        t.consume(Data(([launch, agent] + Array(repeating: prompt, count: 3)).joined(separator: "\n").utf8 + [0x0A]))
        #expect(t.asyncAgents.map(\.id) == ["wgw9", "ag1"])
        #expect(t.asyncAgents[0].info == SubagentInfo(description: "office3d-upgrade", subagentType: "local_workflow", background: true))
        #expect(t.asyncAgents[0].launchedAt != nil)
        t.consume(Data((done + "\n").utf8))
        #expect(t.asyncAgents.map(\.id) == ["wgw9"])
        // 被安全分類器中斷（toolDenialKind interrupted）⇒ API 錯誤，不是「等你按允許」
        let cut = parse([use("a", "Bash"), result("a", extra: #","toolDenialKind":"interrupted""#)])
        #expect(cut.blockedReason(waiting: false, stuck: true) == .apiError)
        let rule = parse([use("a", "Bash"), result("a", extra: #","toolDenialKind":"permission-rule""#)])
        #expect(rule.blockedReason(waiting: false, stuck: true) == .permission)
    }

    @Test("審查補：等子 agent 回來超過 10 分鐘不算卡住，算交辦中")
    func delegatingNotStuck() {
        let busy = SessionRecord(pid: 1, sessionId: "s1", cwd: "/r", status: "busy")
        var t = parse([use("a", "Agent", #"{"description":"寫研究","subagent_type":"general-purpose"}"#)])
        t.lastActivity = now.addingTimeInterval(-30 * 60)
        var plain = parse([use("a", "Bash", #"{"command":"swift test"}"#)]); plain.lastActivity = t.lastActivity
        let cards = Board.build(sessions: [busy], transcripts: ["s1": t], glows: [:], teams: [], inbox: [], now: now, home: "/h", isRepo: { _ in false })
        #expect(cards[0].column == .active && cards[0].activity == .delegating && cards[0].subagents.count == 1)
        let stuck = Board.build(sessions: [busy], transcripts: ["s1": plain], glows: [:], teams: [], inbox: [], now: now, home: "/h", isRepo: { _ in false })
        #expect(stuck[0].column == .stuck && stuck[0].blockedReason == .testRun)
    }
}
