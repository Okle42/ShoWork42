import Foundation
import Testing
@testable import ShoWorkCore

@Suite("右側對話窗格（CaptainThread full 模式）")
struct SessionThreadTests {
    func line(_ o: [String: Any]) -> String {
        String(data: try! JSONSerialization.data(withJSONObject: o), encoding: .utf8)!
    }

    var tail: Data {
        let rows: [[String: Any]] = [
            ["type": "user", "uuid": "u1", "timestamp": "2026-10-25T02:00:00.000Z", "origin": ["kind": "human"],
             "message": ["role": "user", "content": "幫我改登入頁"]],
            ["type": "assistant", "uuid": "a1", "timestamp": "2026-10-25T02:00:05.000Z",
             "message": ["stop_reason": "tool_use", "content": [
                ["type": "text", "text": "好，我先找檔案。"],
                ["type": "tool_use", "name": "Bash", "input": ["command": "cat ~/.secret/key.txt", "description": "列出專案檔案"]],
             ]]],
            ["type": "user", "uuid": "r1", "message": ["role": "user", "content": [["type": "tool_result", "content": "SECRET-123"]]]],
            ["type": "assistant", "uuid": "a2", "message": ["stop_reason": "tool_use", "content": [
                ["type": "tool_use", "name": "Edit", "input": ["file_path": "/Users/x/專案A/LoginView.swift", "old_string": "a", "new_string": "b"]],
                ["type": "tool_use", "name": "WebFetch", "input": ["url": "https://example.com/a?token=abc"]],
                ["type": "tool_use", "name": "mcp__screen42__click", "input": [:]],
             ]]],
            ["type": "user", "uuid": "p1", "origin": ["kind": "peer", "name": "AI工作戰情中心（使用者）"],
             "message": ["role": "user", "content": "<cross-session-message from=\"uds:\">【使用者從戰情中心回答你的問題】好</cross-session-message>"]],
            ["type": "assistant", "uuid": "a3", "message": ["stop_reason": "end_turn", "content": [["type": "text", "text": "改好了。"]]]],
        ]
        return Data((rows.map(line).joined(separator: "\n") + "\n").utf8)
    }

    @Test("full：中途的話、工具一行摘要都收；指令原文、工具結果、網址參數不收")
    func full() {
        let xs = CaptainThread.parse(tail, full: true)
        #expect(xs.map(\.role) == [.kang, .captain, .tool, .tool, .tool, .tool, .kang, .captain])
        #expect(xs.map(\.text) == ["幫我改登入頁", "好，我先找檔案。", "執行指令：列出專案檔案", "修改：LoginView.swift",
                                   "開網頁：example.com", "用工具 screen42・click", "好", "改好了。"])
        #expect(xs[6].via == "戰情中心")
        let all = xs.map(\.text).joined()
        #expect(!all.contains("SECRET") && !all.contains("key.txt") && !all.contains("token"))
        #expect(Set(xs.map(\.id)).count == xs.count)      // 同一則訊息裡的多個區塊 id 不重複
    }

    @Test("隊長模式照舊：只收每輪最後的話")
    func captainMode() {
        let xs = CaptainThread.parse(tail)
        #expect(xs.map(\.role) == [.kang, .kang, .captain])
        #expect(xs.last?.text == "改好了。")
    }
}
