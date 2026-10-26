import Foundation

// 使用者已答（隊長 Penny 10-25：Kang 指出隊長重複問組員卡片已經問過的題）。
// 使用者在任一組員卡片的 --ask 按了選項或打字回答（BoardActions.answer）⇒ 除了送給那個組員，也轉隊長一則「【使用者已答】」，
// 隊長卡片上如果掛著同一個問題，就把那個 --ask 清掉（不再出現在收件匣等 Kang 再答一次）。

public enum Answered {
    public static let prefix = "【使用者已答】"

    /// 「【使用者已答】Ruby：要 push 嗎？→好，push」
    public static func relay(name: String, question: String?, answer: String) -> String {
        let q = question.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty ? nil : $0 } ?? "（卡片上沒有問題文字）"
        return "\(prefix)\(name)：\(q)→\(answer)。這題不用再問使用者；隊長卡片上同一題已自動清掉。"
    }

    /// 比對用：去空白、全形半形問號與句尾標點、不分大小寫
    static func normal(_ s: String) -> String {
        s.lowercased().filter { !$0.isWhitespace && !"？?。.！!：:「」\"'".contains($0) }
    }

    public static func same(_ a: String?, _ b: String?) -> Bool {
        guard let a, let b else { return false }
        let x = normal(a), y = normal(b)
        return !x.isEmpty && x == y
    }

    /// 隊長卡片掛著同一題 ⇒ 回傳清掉 --ask／--options 的卡片；不是同一題 ⇒ nil（不動）
    public static func clearing(_ r: SelfReport, question: String?) -> SelfReport? {
        guard same(r.ask, question) else { return nil }
        var x = r
        x.ask = nil; x.options = nil
        return x
    }

    /// 改寫隊長的卡片檔（board/cards/<sid>.json）；有清掉回 true
    @discardableResult
    public static func clearCaptainCard(sid: String, question: String?, dir: URL = Paths.supportDir.appendingPathComponent("board/cards", isDirectory: true)) -> Bool {
        let url = dir.appendingPathComponent(sid + ".json")
        guard let d = try? Data(contentsOf: url), let r = try? BoardJSON.decoder.decode(SelfReport.self, from: d),
              let x = clearing(r, question: question), let out = try? BoardJSON.encoder.encode(x) else { return false }
        return (try? out.write(to: url, options: .atomic)) != nil
    }
}
