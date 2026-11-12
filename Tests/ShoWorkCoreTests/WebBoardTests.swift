import Foundation
import Testing
@testable import ShoWorkCore

@Suite("WebBoard")
struct WebBoardTests {
    let t0 = Date(timeIntervalSince1970: 1_792_500_000)
    let tok = String(repeating: "ab", count: 32)
    let peer = "100.77.57.35", mini = "100.69.17.79"

    func card(_ id: String, _ col: BoardColumn, reason: String, report: SelfReport? = nil, at: Date? = nil) -> BoardCard {
        var c = BoardCard(id: id, column: col, reason: reason, project: "P", title: "t-\(id)", lastActivity: at, pid: 1, sessionId: id)
        c.report = report
        c.name = "N\(id)"
        return c
    }

    func req(_ method: String, _ path: String, token: String? = nil, body: String? = nil, contentType: String? = "application/json") -> WebRequest {
        var h: [String: String] = [:]
        if let token { h[WebRouter.tokenHeader] = token }
        if body != nil, let contentType { h["content-type"] = contentType }
        let comps = URLComponents(string: "http://x" + path)
        var q: [String: String] = [:]
        for i in comps?.queryItems ?? [] { q[i.name] = i.value ?? "" }
        return WebRequest(method: method, path: comps?.path ?? path, query: q, headers: h, body: Data((body ?? "").utf8))
    }

    /// 跑路由，記下有沒有呼叫 perform、記了哪些稽核
    func route(_ r: WebRequest, peer p: String? = "100.77.57.35", token: String?? = .none, limiter: inout WebRateLimiter,
               result: Result<String, CardError> = .success("ok")) -> (WebResponse, [WebAction], [WebAuditEntry]) {
        var acts: [WebAction] = [], audits: [WebAuditEntry] = []
        let resp = WebRouter.handle(r, peer: p, localIP: mini, token: token ?? tok, page: Data("<html>".utf8), now: t0, limiter: &limiter,
                                    snapshot: { Data("{}".utf8) },
                                    perform: { acts.append($0); return result },
                                    audit: { audits.append($0) })
        return (resp, acts, audits)
    }

    // MARK: 綁定位址

    @Test("100.64.0.0/10 才算 Tailscale")
    func cgnat() {
        for ip in ["100.64.0.1", "100.69.17.79", "100.77.57.35", "100.127.255.255"] { #expect(WebBind.isTailscale(ip), "\(ip)") }
        for ip in ["100.63.255.255", "100.128.0.1", "192.168.0.5", "10.0.0.1", "127.0.0.1", "0.0.0.0", "100.64.0", "100.64.0.1.2", "100.64.0.256", "abc", "", "::1", "fd7a:115c:a1e0::1"] {
            #expect(!WebBind.isTailscale(ip), "\(ip)")
        }
    }

    @Test("挑位址：只挑 Tailscale，utun 優先；沒有就 nil，絕不退回 0.0.0.0 或區網")
    func pick() {
        #expect(WebBind.pick([("lo0", "127.0.0.1"), ("en0", "192.168.0.12"), ("utun4", "100.69.17.79")]) == "100.69.17.79")
        #expect(WebBind.pick([("en5", "100.70.0.1"), ("utun3", "100.69.17.79")]) == "100.69.17.79")
        #expect(WebBind.pick([("en5", "100.70.0.1")]) == "100.70.0.1")
        #expect(WebBind.pick([("lo0", "127.0.0.1"), ("en0", "192.168.0.12"), ("bridge0", "0.0.0.0")]) == nil)
        #expect(WebBind.pick([]) == nil)
    }

    // MARK: token

    @Test("token：64 個十六進位字、每次不同；比對要完全一樣")
    func token() {
        let a = WebToken.generate(), b = WebToken.generate()
        #expect(WebToken.wellFormed(a) && WebToken.wellFormed(b) && a != b)
        #expect(WebToken.matches(a, a))
        #expect(!WebToken.matches(b, a))
        #expect(!WebToken.matches(String(a.dropLast()), a))
        #expect(!WebToken.matches(a + "0", a))
        #expect(!WebToken.matches(nil, a))
        #expect(!WebToken.matches("", a))
        #expect(!WebToken.matches(a, nil))
        #expect(!WebToken.matches("x", "x"))      // 存的 token 格式壞掉也不放行
    }

    @Test("設定與 token 檔：預設關、檔案 0600、資料夾 0700；稽核檔也是 0600")
    func store() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("webstore-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let s = WebStore(dir: dir)
        #expect(s.config() == WebConfig(enabled: false, port: WebConfig.defaultPort))
        #expect(s.token() == nil)
        let t = try s.rotateToken()
        #expect(s.token() == t)
        try s.save(WebConfig(enabled: true, port: 9000))
        #expect(s.config() == WebConfig(enabled: true, port: 9000))
        func perm(_ u: URL) throws -> Int { (try FileManager.default.attributesOfItem(atPath: u.path)[.posixPermissions] as? NSNumber)?.intValue ?? -1 }
        #expect(try perm(s.tokenURL) == 0o600)
        #expect(try perm(s.configURL) == 0o600)
        #expect(try perm(dir) == 0o700)
        s.audit(WebAuditEntry(at: t0, peer: peer, action: "send", target: "a", text: "hi", status: 200, result: "ok"))
        s.audit(WebAuditEntry(at: t0, peer: peer, action: "ack", target: "SABCD", status: 409, result: "no"))
        #expect(try perm(s.auditURL) == 0o600)
        let lines = s.auditLines()
        #expect(lines.count == 2 && lines[0].peer == peer && lines[0].at == t0 && lines[1].status == 409)
    }

    // MARK: HTTP 解析

    @Test("請求解析：分段收到、query、標頭小寫；太大、chunked、壞的起始列都拒")
    func parse() {
        #expect(WebRequest.parse(Data("GET / HTTP/1.1\r\nHost: x".utf8)) == .need)
        guard case .ok(let g) = WebRequest.parse(Data("GET /?t=abc HTTP/1.1\r\nX-ShoWork-Token: q\r\n\r\n".utf8)) else { Issue.record("GET"); return }
        #expect(g.method == "GET" && g.path == "/" && g.query["t"] == "abc" && g.headers["x-showork-token"] == "q")
        let head = "POST /api/send HTTP/1.1\r\nContent-Type: application/json\r\nContent-Length: 9\r\n\r\n"
        #expect(WebRequest.parse(Data((head + "{\"a\":").utf8)) == .need)
        guard case .ok(let p) = WebRequest.parse(Data((head + "{\"a\":\"b\"}").utf8)) else { Issue.record("POST"); return }
        #expect(String(data: p.body, encoding: .utf8) == "{\"a\":\"b\"}")
        #expect(WebRequest.parse(Data("POST / HTTP/1.1\r\nContent-Length: 999999\r\n\r\n".utf8)) == .bad)
        #expect(WebRequest.parse(Data("POST / HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n".utf8)) == .bad)
        #expect(WebRequest.parse(Data("GARBAGE\r\n\r\n".utf8)) == .bad)
        #expect(WebRequest.parse(Data("GET http://evil/ HTTP/1.1\r\n\r\n".utf8)) == .bad)
        #expect(WebRequest.parse(Data(repeating: 0x41, count: WebRequest.maxHeader + 1)) == .bad)
    }

    // MARK: 路由：連線端、token

    @Test("不是 Tailscale 來的、或 Mac mini 自己連自己：GET、POST 都 403，也不執行")
    func peers() {
        var l = WebRateLimiter()
        for p in ["192.168.0.20", "127.0.0.1", "10.1.2.3", "8.8.8.8", mini] {
            #expect(route(req("GET", "/?t=\(tok)"), peer: p, limiter: &l).0.status == 403, "\(p)")
            let (r, acts, _) = route(req("POST", "/api/send", token: tok, body: #"{"id":"a","text":"hi"}"#), peer: p, limiter: &l)
            #expect(r.status == 403 && acts.isEmpty, "\(p)")
        }
        #expect(route(req("GET", "/?t=\(tok)"), peer: nil, limiter: &l).0.status == 403)
    }

    @Test("頁面與 JSON：要對的 token（頁面用 ?t=，API 用標頭）；沒設定 token 一律 403")
    func readToken() {
        var l = WebRateLimiter()
        #expect(route(req("GET", "/?t=\(tok)"), limiter: &l).0.status == 200)
        #expect(route(req("GET", "/?t=\(tok)"), limiter: &l).0.contentType.hasPrefix("text/html"))
        #expect(route(req("GET", "/"), limiter: &l).0.status == 403)
        #expect(route(req("GET", "/?t=" + String(repeating: "cd", count: 32)), limiter: &l).0.status == 403)
        #expect(route(req("GET", "/api/board", token: tok), limiter: &l).0.status == 200)
        #expect(route(req("GET", "/api/board"), limiter: &l).0.status == 403)
        #expect(route(req("GET", "/api/board?t=\(tok)"), limiter: &l).0.status == 403)     // API 只認標頭
        #expect(route(req("GET", "/api/board", token: tok), token: .some(nil), limiter: &l).0.status == 403)
        #expect(route(req("GET", "/nope", token: tok), limiter: &l).0.status == 404)
    }

    @Test("每個動作：沒 token、錯 token 都 403、不執行但有稽核；GET 動作網址 405；不是 JSON 415")
    func actionAuth() {
        let bodies = [("/api/answer", #"{"id":"a","text":"好"}"#), ("/api/send", #"{"id":"a","text":"hi"}"#),
                      ("/api/task", #"{"id":"a","text":"做 X"}"#), ("/api/task/cancel", #"{"id":"T1110123456"}"#),
                      ("/api/inbox/ack", #"{"id":"SABCD"}"#)]
        for (path, body) in bodies {
            var l = WebRateLimiter(perMinute: 100, minGap: 0)
            var (r, acts, audits) = route(req("POST", path, body: body), limiter: &l)
            #expect(r.status == 403 && acts.isEmpty && audits.count == 1 && audits[0].status == 403 && audits[0].peer == peer, "\(path) 沒 token")
            (r, acts, audits) = route(req("POST", path, token: String(repeating: "0", count: 64), body: body), limiter: &l)
            #expect(r.status == 403 && acts.isEmpty && audits.count == 1, "\(path) 錯 token")
            (r, acts, _) = route(req("POST", path, token: tok, body: body, contentType: "text/plain"), limiter: &l)
            #expect(r.status == 415 && acts.isEmpty, "\(path) 不是 JSON")
            (r, acts, _) = route(req("GET", path, token: tok), limiter: &l)
            #expect(r.status == 405 && acts.isEmpty, "\(path) GET")
            (r, acts, audits) = route(req("POST", path, token: tok, body: body), limiter: &l)
            #expect(r.status == 200 && acts.count == 1 && audits.count == 1 && audits[0].status == 200 && audits[0].at == t0, "\(path) 正常")
        }
    }

    @Test("動作解析：五種動作各自的形狀；單號格式、ack 不收 all、路徑字元、太長都擋")
    func actions() throws {
        func p(_ path: String, _ body: String) -> Result<WebAction, CardError> { WebAction.parse(path: path, body: Data(body.utf8)) }
        #expect(try p("/api/answer", #"{"id":"a-1","text":" 好 "}"#).get() == .answer(session: "a-1", text: "好"))
        #expect(try p("/api/send", #"{"id":"a","text":"hi"}"#).get() == .send(session: "a", text: "hi"))
        #expect(try p("/api/task", #"{"id":"a","text":"做 X"}"#).get() == .dispatch(session: "a", text: "做 X"))
        #expect(try p("/api/task/cancel", #"{"id":"T1110123456-2"}"#).get() == .cancel(task: "T1110123456-2"))
        #expect(try p("/api/inbox/ack", #"{"id":"babcd"}"#).get() == .ack(inbox: "BABCD"))
        for (path, body) in [("/api/inbox/ack", #"{"id":"all"}"#), ("/api/inbox/ack", #"{"id":"ALL"}"#), ("/api/inbox/ack", #"{"id":"../x"}"#),
                             ("/api/task/cancel", #"{"id":"../../etc/passwd"}"#), ("/api/task/cancel", #"{"id":"T1"}"#),
                             ("/api/send", #"{"id":"../a","text":"x"}"#), ("/api/send", #"{"id":"a","text":"   "}"#), ("/api/send", #"{"id":"a"}"#),
                             ("/api/answer", "{\"id\":\"a\",\"text\":\"" + String(repeating: "字", count: 201) + "\"}"),
                             ("/api/send", "{\"id\":\"a\",\"text\":\"" + String(repeating: "字", count: 2001) + "\"}"),
                             ("/api/send", "[1]"), ("/api/send", "not json"), ("/api/shell", #"{"cmd":"rm"}"#)] {
            if case .success = p(path, body) { Issue.record("應該擋：\(path) \(body.prefix(40))") }
        }
        #expect((try? p("/api/send", "{\"id\":\"a\",\"text\":\"" + String(repeating: "字", count: 2000) + "\"}").get()) != nil)
    }

    @Test("路由：ack all 回 400 不執行；沒有的動作 404")
    func routerRejects() {
        var l = WebRateLimiter(perMinute: 100, minGap: 0)
        let (r, acts, audits) = route(req("POST", "/api/inbox/ack", token: tok, body: #"{"id":"all"}"#), limiter: &l)
        #expect(r.status == 400 && acts.isEmpty && audits.count == 1)
        #expect(route(req("POST", "/api/shell", token: tok, body: #"{"cmd":"ls"}"#), limiter: &l).0.status == 404)
        let (f, _, fa) = route(req("POST", "/api/send", token: tok, body: #"{"id":"a","text":"x"}"#), limiter: &l, result: .failure(CardError("關了")))
        #expect(f.status == 409 && fa.first?.result == "關了" && fa.first?.target == "a" && fa.first?.text == "x")
    }

    @Test("限頻：同一個來源太快或一分鐘超過上限回 429；別的來源不受影響；過一分鐘恢復")
    func rateLimit() {
        var l = WebRateLimiter(perMinute: 3, minGap: 0.5)
        var got: [Bool] = []
        for (p, dt) in [(peer, 0.0), (peer, 0.1), (peer, 1), (peer, 2), (peer, 3), ("100.70.0.9", 3), (peer, 61)] {
            got.append(l.allow(p, now: t0.addingTimeInterval(dt)))
        }
        #expect(got == [true, false, true, true, false, true, true])
        var r = WebRateLimiter(perMinute: 1, minGap: 0)
        let body = #"{"id":"a","text":"x"}"#
        #expect(route(req("POST", "/api/send", token: tok, body: body), limiter: &r).0.status == 200)
        let (x, acts, audits) = route(req("POST", "/api/send", token: tok, body: body), limiter: &r)
        #expect(x.status == 429 && acts.isEmpty && audits.first?.status == 429)
        // 錯 token 不吃額度（限頻在 token 檢查之後）
        var z = WebRateLimiter(perMinute: 1, minGap: 0)
        _ = route(req("POST", "/api/send", token: String(repeating: "0", count: 64), body: body), limiter: &z)
        #expect(route(req("POST", "/api/send", token: tok, body: body), limiter: &z).0.status == 200)
    }

    // MARK: JSON 形狀

    @Test("看板 JSON：欄位、排序、選項只給要你決定的；沒用過的與子 agent 卡不列；只列沒結的單與沒 ack 的收件匣")
    func snapshot() throws {
        let ask = SelfReport(status: .review, summary: "做好了", ask: "要 push 嗎", doing: "修 bug", options: ["好，push", "先不要"], at: t0)
        var unused = card("z", .todo, reason: "閒置"); unused.unused = true
        var sub = card("s#1", .active, reason: "工作中")
        sub.sessionId = "s"
        let cards = [card("w", .active, reason: "工作中", at: t0.addingTimeInterval(-120)),
                     card("a", .review, reason: "要你決定：要 push 嗎", report: ask, at: t0),
                     card("m", .review, reason: "等你回答", at: t0),
                     card("d", .done, reason: "完成"), unused, sub]
        let tasks = [CaptainTask(id: "T1110000001", from: "cap", to: "Nw", text: "做 A", createdAt: t0),
                     CaptainTask(id: "T1110000002", from: "cap", to: "Nd", text: "做 B", state: .done, createdAt: t0)]
        var acked = CaptainInboxItem(id: "SAAAA", kind: .start, at: t0, sid: "w", name: "Nw", project: "P", text: "開工")
        acked.acked = t0
        let inbox = [acked, CaptainInboxItem(id: "BBBBB", kind: .block, at: t0, sid: "a", name: "Na", project: "P", text: "git push")]
        let s = WebSnapshot.make(cards: cards, tasks: tasks, inbox: inbox, answered: ["a": t0.addingTimeInterval(5)], now: t0)
        #expect(s.sessions.map(\.id) == ["a", "m", "w", "d"])
        let a = s.sessions[0]
        #expect(a.name == "Na" && a.column == "review" && a.columnTitle == "待審" && a.doing == "修 bug" && a.summary == "做好了")
        #expect(a.question == "要 push 嗎" && a.options == ["好，push", "先不要"] && a.canAnswer && a.answeredAt == t0.addingTimeInterval(5))
        #expect(s.sessions[1].question != nil && !s.sessions[1].canAnswer && s.sessions[1].options.isEmpty)   // 終端機選單：只能看
        #expect(s.sessions[2].columnTitle == "工作中" && s.sessions[2].idleSeconds == 120 && s.sessions[2].question == nil)
        #expect(s.tasks.map(\.id) == ["T1110000001"] && s.tasks[0].stateTitle == "已派出")
        #expect(s.inbox.map(\.id) == ["BBBBB"] && s.inbox[0].kind == "block")

        let o = try #require(try JSONSerialization.jsonObject(with: BoardJSON.encoder.encode(s)) as? [String: Any])
        #expect(Set(o.keys) == ["generatedAt", "sessions", "tasks", "inbox"])
        let s0 = try #require((o["sessions"] as? [[String: Any]])?.first)
        for k in ["id", "name", "project", "column", "columnTitle", "reason", "doing", "summary", "idleSeconds", "captain", "question", "options", "canAnswer", "answeredAt"] {
            #expect(s0[k] != nil, "sessions[].\(k)")
        }
        #expect(s0["answeredAt"] is String)           // ISO 字串，網頁 new Date() 讀得懂
        let t = try #require((o["tasks"] as? [[String: Any]])?.first)
        for k in ["id", "to", "text", "state", "stateTitle", "updatedAt"] { #expect(t[k] != nil, "tasks[].\(k)") }
        let i = try #require((o["inbox"] as? [[String: Any]])?.first)
        for k in ["id", "kind", "name", "text", "at"] { #expect(i[k] != nil, "inbox[].\(k)") }
    }

    @Test("按選項只收卡片上的選項；傳話對象要是活著的 session（不收子 agent 卡）")
    func validate() {
        let ask = SelfReport(status: .review, ask: "要 push 嗎", options: ["好，push", "先不要"], at: t0)
        var sub = card("s#1", .active, reason: "工作中"); sub.sessionId = "s"
        let cards = [card("a", .review, reason: "要你決定：要 push 嗎", report: ask, at: t0), card("w", .active, reason: "工作中"), sub]
        #expect((try? WebSnapshot.validate(answer: "好，push", for: "a", cards: cards).get())?.sessionId == "a")
        #expect((try? WebSnapshot.validate(answer: "rm -rf /", for: "a", cards: cards).get()) == nil)
        #expect((try? WebSnapshot.validate(answer: "好，push", for: "w", cards: cards).get()) == nil)
        #expect((try? WebSnapshot.validate(answer: "好，push", for: "x", cards: cards).get()) == nil)
        #expect((try? WebSnapshot.target("w", cards: cards).get())?.sessionId == "w")
        #expect((try? WebSnapshot.target("s", cards: cards).get()) == nil)
        #expect(WebSnapshot.sendPrefix == "【使用者從網頁戰情中心】")
    }

    @Test("頁面：不連外部資源、文字不拼 HTML")
    func page() {
        let h = WebPage.html
        #expect(!h.contains("http://") && !h.contains("https://"))
        #expect(!h.contains("innerHTML"))
        #expect(h.contains("X-ShoWork-Token"))
        for p in WebAction.paths { #expect(h.contains("\"\(p)\""), "頁面有用到 \(p)") }
    }
}
