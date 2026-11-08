import Foundation
import Testing
@testable import ShoWorkCore

@Suite("CaptainThread")
struct CaptainThreadTests {
    @Test("隊長對話：終端機與戰情中心的話、隊長每輪最後一段、回報只留第一行；工具結果與中途的話不算")
    func parse() {
        let lines = [
            #"{"type":"user","uuid":"u1","timestamp":"2026-10-21T18:24:39.372Z","origin":{"kind":"human"},"message":{"role":"user","content":"把 ProjectD 上架做完"}}"#,
            #"{"type":"assistant","uuid":"a1","message":{"stop_reason":"tool_use","content":[{"type":"text","text":"我先看名冊"}]}}"#,
            #"{"type":"user","uuid":"t1","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"x","content":"ok"}]}}"#,
            #"{"type":"assistant","uuid":"a2","timestamp":"2026-10-21T18:26:28.054Z","message":{"stop_reason":"end_turn","content":[{"type":"text","text":"🧢 miniKang：提醒\n\n收到，**Dora** 接手"}]}}"#,
            #"{"type":"user","uuid":"p1","origin":{"kind":"peer","name":"AI工作戰情中心","body":"【工作回報】Dora：重建商品\n狀態 working"},"message":{"role":"user","content":"x"}}"#,
            #"{"type":"user","uuid":"p2","origin":{"kind":"peer","name":"AI工作戰情中心（使用者）","body":"【使用者從看板交辦】預設值照你建議的\n請照隊長守則處理：先看名冊"},"message":{"role":"user","content":"x"}}"#,
            #"{"type":"user","uuid":"m1","isMeta":true,"origin":{"kind":"human"},"message":{"role":"user","content":"meta"}}"#,
            #"{"type":"user","uuid":"c1","origin":{"kind":"human"},"message":{"role":"user","content":"<command-name>/clear</command-name>"}}"#,
            "{壞掉的行",
        ].joined(separator: "\n")
        let t = CaptainThread.parse(Data(lines.utf8))
        #expect(t.map(\.role) == [.kang, .captain, .report, .kang])
        #expect(t[0].text == "把 ProjectD 上架做完" && t[0].via == "終端機" && t[0].at != nil)
        #expect(t[1].text == "收到，**Dora** 接手")
        #expect(t[2].text == "【工作回報】Dora：重建商品")
        #expect(t[3].text == "預設值照你建議的" && t[3].via == "戰情中心")
    }

    @Test("不上面板：工具輸入／結果、thinking、AI 之間的自由訊息內文")
    func privacy() {
        let lines = [
            #"{"type":"assistant","uuid":"a1","message":{"stop_reason":"end_turn","content":[{"type":"thinking","thinking":"秘密思考"},{"type":"tool_use","id":"x","name":"Bash","input":{"command":"cat 帳號.txt"}},{"type":"text","text":"處理好了"}]}}"#,
            #"{"type":"user","uuid":"t1","origin":{"kind":"human"},"message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"x","content":"帳號 1234"}]}}"#,
            #"{"type":"user","uuid":"p1","origin":{"kind":"peer","name":"Dora","body":"銀行帳號 1234-5678\n證件在 /x/id.png"},"message":{"role":"user","content":"x"}}"#,
        ].joined(separator: "\n")
        let t = CaptainThread.parse(Data(lines.utf8))
        #expect(t.map(\.text) == ["處理好了", "Dora 傳來一則訊息（內容不顯示）"])
        #expect(!t.map(\.text).joined().contains("1234") && !t.map(\.text).joined().contains("秘密"))
    }

    @Test("舊的「巡檢無變化」與隊長的空回覆不上面板；有變化的巡檢照留")
    func noopPatrol() {
        let lines = [
            #"{"type":"user","uuid":"p1","origin":{"kind":"peer","name":"AI工作戰情中心（巡檢）","body":"【巡檢時間】無變化（在線 6 人，跟上次一樣）"},"message":{"role":"user","content":"x"}}"#,
            #"{"type":"assistant","uuid":"a1","message":{"stop_reason":"end_turn","content":[{"type":"text","text":"巡檢無變化,沒有動作。"}]}}"#,
            #"{"type":"user","uuid":"p2","origin":{"kind":"peer","name":"AI工作戰情中心（巡檢）","body":"【巡檢時間】在線 6 人（不含隊長）"},"message":{"role":"user","content":"x"}}"#,
            #"{"type":"assistant","uuid":"a2","message":{"stop_reason":"end_turn","content":[{"type":"text","text":"Chris 閒置太久，先不動"}]}}"#,
            #"{"type":"user","uuid":"p3","origin":{"kind":"peer","name":"AI工作戰情中心（巡檢）","body":"【巡檢時間】無變化（在線 6 人，跟上次一樣）"},"message":{"role":"user","content":"x"}}"#,
            #"{"type":"user","uuid":"u1","origin":{"kind":"human"},"message":{"role":"user","content":"進度？"}}"#,
            #"{"type":"assistant","uuid":"a3","message":{"stop_reason":"end_turn","content":[{"type":"text","text":"無變化"}]}}"#,
        ].joined(separator: "\n")
        let t = CaptainThread.parse(Data(lines.utf8))
        #expect(t.map(\.text) == ["【巡檢時間】在線 6 人（不含隊長）", "Chris 閒置太久，先不動", "進度？", "無變化"])
    }

    @Test("peer 沒有 body 欄位時從 cross-session-message 拿內文")
    func peerBody() {
        let s = "Another Claude session sent a message:\n<cross-session-message from=\"uds:\" from-name=\"X\">\n【派工回報 T1】完成\n第二行\n</cross-session-message>"
        #expect(CaptainThread.peerBody(s) == "【派工回報 T1】完成\n第二行")
    }
}
