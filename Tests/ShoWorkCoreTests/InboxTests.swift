import Foundation
import Testing
@testable import ShoWorkCore

@Suite("Inbox")
struct InboxTests {
    let t0 = Date(timeIntervalSince1970: 1_792_500_000)

    func card(_ id: String, _ col: BoardColumn, reason: String, report: SelfReport? = nil, at: Date? = nil) -> BoardCard {
        var c = BoardCard(id: id, column: col, reason: reason, project: "P", title: "t-\(id)", lastActivity: at, pid: 1, sessionId: id)
        c.report = report
        return c
    }

    @Test("--options：| 分隔、去空白去重、最多 4 個；沒有 --ask 就不收")
    func parseOptions() throws {
        let r = try SelfReport.parse(args: ["--status", "review", "--ask", "要 push 嗎", "--options", " 好，push | 先不要|好，push||a|b|c"]).get()
        #expect(r.options == ["好，push", "先不要", "a", "b"])
        let n = try SelfReport.parse(args: ["--status", "done", "--options", "a|b"]).get()
        #expect(n.options == nil)
        #expect(SelfReport.cleanOptions([" ", ""]) == nil)
        // 舊檔沒有 options 也讀得回來
        let old = #"{"status":"review","ask":"x","at":"2026-10-21T00:00:00.000Z"}"#
        #expect(try BoardJSON.decoder.decode(SelfReport.self, from: Data(old.utf8)).options == nil)
    }

    @Test("只列等你的；要你決定可回答、終端機選單只能跳過去")
    func items() {
        let ask = SelfReport(status: .review, ask: "要 push 嗎", options: ["好，push", "先不要"], at: t0)
        let cards = [
            card("a", .review, reason: "要你決定：要 push 嗎", report: ask, at: t0),
            card("b", .review, reason: "等你回答", at: t0.addingTimeInterval(-60)),
            card("c", .active, reason: "工作中"),
            card("d", .review, reason: "做完了，你還沒看"),
            card("e", .review, reason: "要你決定：門檻要調嗎", at: t0.addingTimeInterval(30)),
        ]
        let xs = Inbox.items(cards)
        #expect(xs.map(\.id) == ["b", "a", "e"])                       // 等最久的在前
        #expect(xs[0].kind == .menu && xs[0].options.isEmpty)
        #expect(xs[1].kind == .reply && xs[1].question == "要 push 嗎" && xs[1].options == ["好，push", "先不要"] && !xs[1].generic)
        #expect(xs[2].question == "門檻要調嗎" && xs[2].generic && xs[2].options == Inbox.genericOptions)
    }

    @Test("回答過、它還沒動 ⇒ 標已送出、排到後面；它又問了新問題就重新算")
    func answered() {
        let ask = SelfReport(status: .review, ask: "Q1", at: t0)
        let cards = [card("a", .review, reason: "要你決定：Q1", report: ask, at: t0),
                     card("b", .review, reason: "要你決定：Q2", at: t0.addingTimeInterval(60))]
        let xs = Inbox.items(cards, answered: ["a": t0.addingTimeInterval(5)])
        #expect(xs.map(\.id) == ["b", "a"] && xs[1].answered != nil)
        let ys = Inbox.items(cards, answered: ["a": t0.addingTimeInterval(-5)])   // 回答的是上一個問題
        #expect(ys.allSatisfy { $0.answered == nil })
        #expect(Inbox.message(" 好\n做 ") == "好 做")
    }

    @Test("背景隊長的第一句話帶登記、回報方式與交辦內容")
    func bootstrap() {
        let s = CaptainLaunch.bootstrap(showork: "/x/showork", task: "幫我看 ProjectA")
        #expect(s.contains("\"/x/showork\" captain") && s.contains("--options") && s.hasSuffix("幫我看 ProjectA"))
    }

    @Test("權限：hook JSON → 請求；一律允許只帶 addRules；決定的輸出格式")
    func permitRequest() throws {
        let o: [String: Any] = ["session_id": "bb5d3e57-89b3", "tool_name": "Bash", "cwd": "/w",
                                "tool_input": ["command": "mkdir -p x", "description": "建資料夾"],
                                "permission_suggestions": [["type": "setMode", "mode": "acceptEdits", "destination": "session"],
                                                           ["type": "addRules", "rules": [["toolName": "Bash", "ruleContent": "mkdir:*"]], "behavior": "allow", "destination": "localSettings"]]]
        let r = try #require(Permit.request(hook: o, pid: 42, now: t0))
        #expect(r.summary == "mkdir -p x" && r.detail == "建資料夾" && r.alwaysLabel == "Bash(mkdir:*)" && r.id.hasPrefix("bb5d3e57-"))
        let allow = Permit.hookOutput(PermitAnswer(.allow), request: r)
        #expect(allow.contains(#""behavior":"allow""#) && !allow.contains("updatedPermissions") && allow.contains(#""hookEventName":"PermissionRequest""#))
        let always = Permit.hookOutput(PermitAnswer(.always), request: r)
        #expect(always.contains("updatedPermissions") && always.contains("mkdir:*") && !always.contains("setMode"))
        let deny = Permit.hookOutput(PermitAnswer(.deny, message: "改用 trash"), request: r)
        #expect(deny.contains(#""behavior":"deny""#) && deny.contains("改用 trash"))
        #expect(Permit.request(hook: ["tool_name": "Bash"], pid: nil) == nil)
        #expect(Permit.summary(tool: "Edit", input: ["file_path": "/a.swift", "old_string": "x"]) == "/a.swift")
    }

    @Test("權限：從 transcript 找 tool_use id、看它的結果出現了沒")
    func permitTranscript() {
        let tail = """
        {"type":"assistant","message":{"content":[{"type":"tool_use","id":"toolu_old","name":"Bash","input":{"command":"ls"}}]}}
        {"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"toolu_old"}]}}
        {"type":"assistant","message":{"content":[{"type":"text","text":"x"},{"type":"tool_use","id":"toolu_new","name":"Bash","input":{"command":"mkdir -p x","description":"d"}}]}}
        """
        let id = Permit.toolUseId(transcript: Data(tail.utf8), tool: "Bash", input: ["command": "mkdir -p x", "description": "d"])
        #expect(id == "toolu_new")
        #expect(Permit.toolUseId(transcript: Data(tail.utf8), tool: "Bash", input: ["command": "rm"]) == nil)
        #expect(!Permit.resolved(appended: Data(#"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"toolu_old"}]}}"#.utf8), toolUseId: "toolu_new"))
        #expect(Permit.resolved(appended: Data(#"{"type":"tool_result","tool_use_id":"toolu_new"}"#.utf8), toolUseId: "toolu_new"))
        #expect(Permit.resolved(appended: Data(#"{"type":"tool_result","tool_use_id":"x"}"#.utf8), toolUseId: nil))
    }

    @Test("權限：檔案讀寫；答過的、過期的不列；收件匣有對話框就列成 permit")
    func permitStore() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("permit-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = PermitRequest(id: "a1", sessionId: "s1", pid: nil, tool: "Bash", summary: "ls", at: t0)
        let b = PermitRequest(id: "b1", sessionId: "s2", pid: nil, tool: "Write", summary: "/x", at: t0.addingTimeInterval(-Permit.staleAfter - 1))
        #expect(Permit.write(a, dir: dir) && Permit.write(b, dir: dir))
        #expect(Permit.pending(dir: dir, now: t0).keys.sorted() == ["s1"])
        #expect(Permit.answer("a1", PermitAnswer(.deny, message: "不要"), dir: dir))
        #expect(Permit.readAnswer("a1", dir: dir)?.message == "不要")
        #expect(Permit.pending(dir: dir, now: t0).isEmpty)
        Permit.remove("a1", dir: dir)
        #expect(!Permit.answer("a1", PermitAnswer(.allow), dir: dir))     // 請求已收：不寫
        var c = card("p", .active, reason: "工作中")
        c.permit = a
        let xs = Inbox.items([c])
        #expect(xs.count == 1 && xs[0].kind == .permit && xs[0].question == "要執行指令，可以嗎？")
    }
}

@Suite("ShortName")
struct ShortNameTests {
    @Test("換 sessionId 沿用 transcript 開頭的名字（10-22 Bella→Kyle）")
    func inherit() {
        func d(_ lines: [String]) -> Data { Data(lines.joined(separator: "\n").utf8) }
        #expect(Nicknames.inherited(d([#"{"type":"custom-title","customTitle":"Bella","sessionId":"x"}"#])) == "Bella")
        #expect(Nicknames.inherited(d([#"{"type":"mode"}"#, #"{"type":"custom-title","customTitle":"Bella-清模擬器"}"#])) == "Bella")
        #expect(Nicknames.inherited(d([#"{"type":"agent-name","agentName":"Alex2"}"#])) == "Alex2")
        #expect(Nicknames.inherited(d([#"{"type":"custom-title","customTitle":"隊長"}"#])) == nil)
        #expect(Nicknames.inherited(d([#"{"type":"user","message":"hi"}"#])) == nil && Nicknames.inherited(nil) == nil)
    }

    @Test("短名、全名、sessionId 都找得到；舊 session 的「Chris-在做的事」也認得")
    func match() {
        let ss: [(String, String?)] = [("aaaa1111-x", "Chris"), ("bbbb2222-y", "Dora-改收費方案"), ("cccc3333-z", nil)]
        let nick = ["aaaa1111-x": "Chris", "bbbb2222-y": "Dora", "dead0000-q": "Ethan"]
        #expect(ShortName.match("Chris", among: ss, nick: nick) == ["aaaa1111-x"])
        #expect(ShortName.match("chris", among: ss, nick: nick) == ["aaaa1111-x"])
        #expect(ShortName.match("Dora", among: ss, nick: [:]) == ["bbbb2222-y"])              // 舊 session 還沒改名
        #expect(ShortName.match("Dora-改收費方案", among: ss, nick: nick) == ["bbbb2222-y"])   // 全名照樣可以
        #expect(ShortName.match("cccc3333", among: ss, nick: nick) == ["cccc3333-z"])
        #expect(ShortName.match("Ethan", among: ss, nick: nick).isEmpty)                      // 名字主人已經不在
        #expect(ShortName.match("Do", among: ss, nick: nick).isEmpty)
    }

    @Test("名字回收重用：只看活著的；兩個活的同名就全回（呼叫端報錯）")
    func reuse() {
        let ss: [(String, String?)] = [("new00000-1", "Chris"), ("old00000-2", "Chris-審 Dora")]
        #expect(ShortName.match("Chris", among: ss, nick: ["new00000-1": "Chris", "old00000-2": "Chris"]).count == 1)   // 全名 Chris 先中
        let two: [(String, String?)] = [("a0000000-1", "Chris-甲"), ("b0000000-2", "Chris-乙")]
        #expect(ShortName.match("Chris", among: two, nick: [:]).sorted() == ["a0000000-1", "b0000000-2"])
    }

    @Test("sessionTitle（收訊地址）只放英文名，終端機標題照樣帶任務")
    func hookTitle() {
        let n = Nickname(name: "Ethan", doing: "修收件匣")
        let o = Nicknames.hookOutput(n, done: false, event: "UserPromptSubmit")
        #expect(o.contains(#""sessionTitle":"Ethan""#) && o.contains("Ethan-修收件匣"))
    }

    @Test("名字冷卻：活著的、3 天內用過的都不挑（Remote Control 留著同名離線紀錄）")
    func cooldown() {
        let now = Date(timeIntervalSince1970: 1_792_600_000)
        let all = ["live": Nickname(name: "Alex", at: now.addingTimeInterval(-9 * 86400)),
                   "dead1": Nickname(name: "Bella", at: now.addingTimeInterval(-9 * 3600)),
                   "dead2": Nickname(name: "Chris", at: now.addingTimeInterval(-4 * 86400))]
        let t = Nicknames.taken(all, live: ["live"], me: "x", now: now)
        #expect(t == ["Alex", "Bella"])
        #expect(Nicknames.pick(taken: t) == "Chris")
    }
}
