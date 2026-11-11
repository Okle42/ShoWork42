import Foundation
import Testing
@testable import ShoWorkCore

// 11-10 BZW2R：使用者在看板問「開pr能幹嘛」，動作預告的自動放行把它當成同意 gh pr create。問句永遠不算同意
@Suite("自動放行：問句不算同意")
struct QuestionConsentTests {
    let gh = "GitHub 公開發言（gh）", dep = "firebase 部署", line = "LINE 對外傳訊（line_send.py）"

    @Test("問句（？／? 或問句詞）一律不放行")
    func questions() {
        for a in ["開pr能幹嘛", "開pr？", "開pr?", "開 PR 嗎", "開PR要幹嘛", "PR 是什麼", "為什麼要開 PR", "怎麼開 PR", "開 PR 什麼意思",
                  "開 PR 可以嗎", "開 PR 好嗎", "開pr，能幹嘛", "開 PR 幹嘛", "要不要開 PR", "部署呢", "部署可以嗎", "部署是什麼意思"] {
            #expect(CaptainInbox.isQuestion(a), "應判為問句：\(a)")
            #expect(!CaptainInbox.authorizes(a, rule: gh) && !CaptainInbox.authorizes(a, rule: dep), "問句不該放行：\(a)")
        }
    }

    @Test("同意句照樣放行")
    func consents() {
        for a in ["開pr merge", "部署", "發"] { #expect(!CaptainInbox.isQuestion(a), "不是問句：\(a)") }
        #expect(CaptainInbox.authorizes("開pr merge", rule: gh))
        #expect(CaptainInbox.authorizes("部署", rule: dep))
        #expect(CaptainInbox.authorizes("好，開 PR", rule: gh))
        #expect(CaptainInbox.authorizes("傳 LINE 給同事", rule: line))
        // 「發」沒點名任何擋規則：不是問句，但也不放行擋單（要動作詞＋對象，11-02 規則不變）
        #expect(!CaptainInbox.authorizes("發", rule: gh) && !CaptainInbox.authorizes("發", rule: line))
    }

    @Test("事先放行：記下的問句答案不會放行之後被擋的 gh pr create")
    func preapprovalReplay() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("qc-\(UUID().uuidString)")
        setenv("SHOWORK_PREAPPROVAL_LOG", dir.appendingPathComponent("pre.json").path, 1)
        defer { unsetenv("SHOWORK_PREAPPROVAL_LOG"); try? FileManager.default.removeItem(at: dir) }
        let t0 = Date(timeIntervalSince1970: 1_793_000_000)
        CaptainInbox.recordAnswer(sid: "w", answer: "開pr能幹嘛", question: "要開 PR 嗎？", now: t0)
        #expect(CaptainInbox.usePreapproval(sid: "w", rules: [gh], now: t0 + 5) == nil)
        CaptainInbox.recordAnswer(sid: "w", answer: "開pr merge", question: "要開 PR 嗎？", now: t0 + 10)
        #expect(CaptainInbox.usePreapproval(sid: "w", rules: [gh], now: t0 + 15)?.answer == "開pr merge")
    }
}
