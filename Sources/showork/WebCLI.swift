import Foundation
import ShoWorkCore

// `showork web enable [--port N] | disable | status | rotate`：網頁版戰情中心的開關（伺服器在 ShoWorkAgent/WebServer.swift）。
// 網頁上按選項＝使用者本人的決定，所以開關與 token 只給人在自己的終端機操作：在 Claude Code 裡（有 CLAUDE_CODE_SESSION_ID）一律拒絕，
// 免得 AI 自己打開、拿到 token 替使用者按按鈕。
enum WebCLI {
    static func err(_ s: String) { FileHandle.standardError.write(Data((s + "\n").utf8)) }

    static func run(_ args: [String]) -> Int32 {
        let store = WebStore()
        let sub = args.dropFirst().first ?? "status"
        if sub != "status", let sid = ProcessInfo.processInfo.environment["CLAUDE_CODE_SESSION_ID"], !sid.isEmpty {
            err("showork web \(sub)：這個要你本人在自己的終端機（不是 Claude Code 裡）跑，因為網頁上按按鈕等於你本人同意。")
            return 1
        }
        let ip = WebBind.pick(WebBind.interfaces())
        func url(_ port: UInt16, _ t: String) -> String { "http://\(ip ?? "<Tailscale IP>"):\(port)/?t=\(t)" }
        do {
            switch sub {
            case "enable":
                var cfg = store.config()
                var a = args.dropFirst(2)
                while let k = a.popFirst() {
                    guard k == "--port", let v = a.popFirst(), let p = UInt16(v), p >= 1024 else { err("用法：showork web enable [--port 1024–65535]"); return 1 }
                    cfg.port = p
                }
                let fresh = store.token() == nil
                let t = try store.token() ?? store.rotateToken()
                cfg.enabled = true
                try store.save(cfg)
                notify()
                print("網頁版戰情中心：已開（只綁 Tailscale，連線端也只收 100.64.0.0/10；Mac mini 自己連自己會被拒）")
                if ip == nil { print("⚠️ 找不到 Tailscale 位址：Tailscale 連上後常駐程式會自己綁上（30 秒內）") }
                if fresh {
                    print("用這個網址開（加成書籤；網址裡就是密碼，別貼給別人）：")
                    print(url(cfg.port, t))
                } else {
                    print("沿用之前的 token（網址不重印）；忘了就跑 showork web rotate 換一組新的，舊書籤會失效")
                }
                return 0
            case "rotate":
                let t = try store.rotateToken()
                notify()
                print("已換新 token，舊網址失效。新網址：")
                print(url(store.config().port, t))
                return 0
            case "disable":
                var cfg = store.config(); cfg.enabled = false
                try store.save(cfg)
                notify()
                print("網頁版戰情中心：已關")
                return 0
            case "status":
                let cfg = store.config()
                print("網頁版戰情中心：\(cfg.enabled ? "開" : "關")　port \(cfg.port)　Tailscale 位址 \(ip ?? "（找不到）")　token \(store.token() == nil ? "沒有" : "有")")
                return 0
            default:
                err("用法：showork web enable [--port N] | disable | status | rotate")
                return 1
            }
        } catch {
            err("showork web：寫不進 \(store.dir.path)：\(error)")
            return 1
        }
    }

    static func notify() {
        DistributedNotificationCenter.default().postNotificationName(Notification.Name("ai.okle42.showork.web"), object: nil, userInfo: nil, deliverImmediately: true)
    }
}
