import Foundation
import ShoWorkCore

// Agent交流互動板（10-24 Kang：B1 交流不一定要面對面，改成留言板；內容都進隊長的優化指揮）
//   showork b1 read [--n 20] [--all]      看最近的留言（隊長整理流程優化、AI 留言前先看）
//   showork b1 post --text "…" [--re 編號]  留一則；同時轉給現任隊長
//   showork b1 hint                       印收尾提示要加的那段（hook_ctx_wrapup.py 用；10-27 改成收尾時順便留）
enum B1CLI {
    static func run(_ args: [String]) -> Int32 {
        var a = Array(args.dropFirst())
        let sub = a.isEmpty ? "read" : a.removeFirst()
        func value(_ flag: String) -> String? { a.firstIndex(of: flag).flatMap { $0 + 1 < a.count ? a[$0 + 1] : nil } }
        switch sub {
        case "read":
            let posts = B1Board.all()
            guard !posts.isEmpty else { print("Agent交流互動板還是空的。"); return 0 }
            let n = a.contains("--all") ? posts.count : Int(value("--n") ?? "") ?? 20
            print("Agent交流互動板（共 \(posts.count) 則，最近 \(min(n, posts.count)) 則）：")
            for p in posts.suffix(n) { print(p.line()) }
            return 0
        case "post":
            guard let text = value("--text") else { CaptainCLI.err("用法：showork b1 post --text \"<150 字以內>\" [--re <編號>]"); return 1 }
            guard let sid = CaptainCLI.mySession else { CaptainCLI.err("showork b1 post：要在 Claude Code 裡跑（找不到 CLAUDE_CODE_SESSION_ID）"); return 1 }
            let name = NicknameStore.ensure(sid).name
            let project = CaptainStore.roster()?.entries.first { $0.sessionId == sid }?.project ?? ""
            guard let p = B1Board.post(sid: sid, name: name, project: project, text: text, re: value("--re").flatMap { Int($0.trimmingCharacters(in: CharacterSet(charactersIn: "#"))) }) else {
                CaptainCLI.err("沒有留成（內容是空的，或寫檔失敗）"); return 1
            }
            print("已留言 #\(p.id)" + (B1Board.clean(text).count > B1Talk.maxChars ? "（超過 \(B1Talk.maxChars) 字，下次精簡一點）" : ""))
            // 轉給現任隊長（自己就是隊長、或隊長不在線就不送；留言本身已經在板上）
            if let cap = CaptainStore.captain(), cap.sessionId != sid, let r = Peer.find(cap.sessionId) {
                switch Peer.send(to: r, text: p.captainText, fromName: "AI工作戰情中心（Agent交流互動板）") {
                case .success: print("已轉給隊長 \(cap.name ?? r.name ?? "")")
                case .failure(let e): print("轉給隊長失敗（\(e)）；留言在板上，隊長用 showork b1 read 看得到")
                }
            }
            return 0
        case "hint":
            print(B1Talk.wrapupNote(showork: Paths.supportDir.appendingPathComponent("bin/showork").path, recent: B1Board.all()))
            return 0
        default:
            CaptainCLI.err("用法：showork b1 read [--n 20｜--all]｜showork b1 post --text \"…\" [--re <編號>]｜showork b1 hint"); return 1
        }
    }
}
