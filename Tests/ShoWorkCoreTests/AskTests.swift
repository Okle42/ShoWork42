import Foundation
import Testing
@testable import ShoWorkCore

@Suite("選擇題與計畫確認（AskUserQuestion／ExitPlanMode 走 PermissionRequest）")
struct AskTests {
    let t0 = Date(timeIntervalSince1970: 1_792_500_000)

    let askInput: [String: Any] = ["questions": [
        ["question": "午餐吃什麼？", "header": "午餐", "multiSelect": false,
         "options": [["label": "拉麵", "description": "日式拉麵"], ["label": "咖哩", "description": ""]]],
        ["question": "要加什麼配料？", "multiSelect": true, "options": [["label": "蛋"], ["label": "海苔"], ["label": "叉燒"]]],
    ]]

    func hook(_ tool: String, _ input: [String: Any]) -> [String: Any] {
        ["session_id": "abcdef1234", "tool_name": tool, "tool_input": input, "cwd": "/tmp/專案A",
         "permission_suggestions": [["type": "addRules", "rules": [["toolName": tool]]]]]
    }

    func output(_ s: String) -> [String: Any] {
        let o = try? JSONSerialization.jsonObject(with: Data(s.utf8)) as? [String: Any]
        return ((o?["hookSpecificOutput"] as? [String: Any])?["decision"] as? [String: Any]) ?? [:]
    }

    @Test("請求檔帶題目和原輸入；不給「一律允許」")
    func request() throws {
        let r = try #require(Permit.request(hook: hook("AskUserQuestion", askInput), pid: nil, now: t0))
        #expect(r.isAsk && !r.isPlan)
        #expect(r.questions?.count == 2)
        #expect(r.questions?[0] == AskQuestion(question: "午餐吃什麼？", header: "午餐", options: [.init(label: "拉麵", description: "日式拉麵"), .init(label: "咖哩")]))
        #expect(r.questions?[1].multiSelect == true && r.questions?[1].header == nil)
        #expect(r.summary == "午餐吃什麼？／要加什麼配料？")
        #expect(r.alwaysRules == nil && r.input != nil)
        // 寫檔讀回（舊版請求檔沒有新欄位也讀得回來）
        let back = try BoardJSON.decoder.decode(PermitRequest.self, from: BoardJSON.encoder.encode(r))
        #expect(back == r)
        let old = #"{"id":"x","sessionId":"s","tool":"Bash","summary":"ls","at":"2026-10-21T00:00:00.000Z"}"#
        #expect(try BoardJSON.decoder.decode(PermitRequest.self, from: Data(old.utf8)).questions == nil)
        // 沒有題目的 AskUserQuestion 不接（交給終端機）
        #expect(Permit.request(hook: hook("AskUserQuestion", ["questions": []]), pid: nil, now: t0) == nil)
    }

    @Test("回答：updatedInput＝原輸入＋answers；單選給字串、多選給陣列")
    func answerOutput() throws {
        let r = try #require(Permit.request(hook: hook("AskUserQuestion", askInput), pid: nil, now: t0))
        let a = PermitAnswer(.allow, answers: ["午餐吃什麼？": ["牛肉麵"], "要加什麼配料？": ["蛋", "叉燒"]])
        let d = output(Permit.hookOutput(a, request: r))
        #expect(d["behavior"] as? String == "allow")
        let u = try #require(d["updatedInput"] as? [String: Any])
        #expect((u["questions"] as? [Any])?.count == 2)
        let ans = try #require(u["answers"] as? [String: Any])
        #expect(ans["午餐吃什麼？"] as? String == "牛肉麵")
        #expect(ans["要加什麼配料？"] as? [String] == ["蛋", "叉燒"])
        #expect(Permit.answerText(r, a) == "午餐吃什麼？ → 牛肉麵；要加什麼配料？ → 蛋、叉燒")
        let no = output(Permit.hookOutput(PermitAnswer(.deny, message: "都不要"), request: r))
        #expect(no["behavior"] as? String == "deny" && (no["message"] as? String)?.contains("都不要") == true)
    }

    @Test("計畫確認：核准＝原輸入放行；退回帶要改的話")
    func plan() throws {
        let r = try #require(Permit.request(hook: hook("ExitPlanMode", ["plan": "# 計畫\n建 hello.txt"]), pid: nil, now: t0))
        #expect(r.isPlan && r.plan == "# 計畫\n建 hello.txt" && r.alwaysRules == nil)
        let ok = output(Permit.hookOutput(PermitAnswer(.allow), request: r))
        #expect((ok["updatedInput"] as? [String: Any])?["plan"] as? String == "# 計畫\n建 hello.txt")
        let back = output(Permit.hookOutput(PermitAnswer(.deny, message: "檔名改成 bye.txt"), request: r))
        #expect((back["message"] as? String)?.contains("檔名改成 bye.txt") == true)
        #expect(Permit.answerText(r, PermitAnswer(.deny, message: "x")) == "退回計畫：x")
        #expect(Permit.answerText(r, PermitAnswer(.allow)) == "核准計畫")
    }

    @Test("一般權限照舊：allow 不帶 updatedInput")
    func plainPermit() throws {
        let r = try #require(Permit.request(hook: hook("Bash", ["command": "ls"]), pid: nil, now: t0))
        #expect(!r.isAsk && !r.isPlan && r.input == nil && r.alwaysRules != nil)
        #expect(output(Permit.hookOutput(PermitAnswer(.allow), request: r))["updatedInput"] == nil)
    }

    @Test("收件匣：選擇題列成 ask、計畫列成 plan")
    func inboxKinds() throws {
        func card(_ id: String, _ p: PermitRequest) -> BoardCard {
            var c = BoardCard(id: id, column: .review, reason: "等你回答", project: "P", title: "t-\(id)", lastActivity: t0, pid: 1, sessionId: id)
            c.permit = p
            return c
        }
        let ask = try #require(Permit.request(hook: hook("AskUserQuestion", askInput), pid: nil, now: t0))
        let plan = try #require(Permit.request(hook: hook("ExitPlanMode", ["plan": "x"]), pid: nil, now: t0.addingTimeInterval(1)))
        let bash = try #require(Permit.request(hook: hook("Bash", ["command": "ls"]), pid: nil, now: t0.addingTimeInterval(2)))
        let xs = Inbox.items([card("a", ask), card("b", plan), card("c", bash)])
        #expect(xs.map(\.kind) == [.ask, .plan, .permit])
        #expect(xs[0].context == nil && xs[2].question == "要執行指令，可以嗎？")
    }

    @Test("回答紀錄寫進 answers.jsonl（欄位同放行紀錄）；一般權限不寫")
    func log() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ask-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let r = try #require(Permit.request(hook: hook("AskUserQuestion", askInput), pid: nil, now: t0))
        Permit.logAnswer(r, PermitAnswer(.allow, answers: ["午餐吃什麼？": ["咖哩"], "要加什麼配料？": ["蛋"]]), now: t0, dir: dir)
        Permit.logAnswer(try #require(Permit.request(hook: hook("Bash", ["command": "ls"]), pid: nil, now: t0)), PermitAnswer(.allow), now: t0, dir: dir)
        let lines = try String(contentsOf: dir.appendingPathComponent("answers.jsonl"), encoding: .utf8).split(separator: "\n")
        #expect(lines.count == 1)
        let rec = try BoardJSON.decoder.decode(ReleaseRecord.self, from: Data(lines[0].utf8))
        #expect(rec.target == "abcdef1234" && rec.source == "戰情中心選擇題" && rec.summary.contains("咖哩"))
    }
}
