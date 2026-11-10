import Foundation
import Security

// 網頁版戰情中心（11-10：2017 Intel MacBook Pro 卡在 macOS 13，跑不動原生 App）。
// Mac mini 的看板常駐程式（ShoWorkAgent）開一個小 HTTP 伺服器，只綁在 Tailscale 介面（100.64.0.0/10），
// MacBook／iPad／iPhone 用瀏覽器開。這裡只有純邏輯（選位址、token、解析請求、JSON 形狀、路由），
// 真正的 socket 在 ShoWorkAgent/WebServer.swift。
//
// 安全：①預設關，`showork web enable` 才開 ②只綁 Tailscale IP（絕不 0.0.0.0、不綁區網 192.168.x）
// ③連線端不是 100.64.0.0/10 一律拒絕 ④每台安裝一組隨機 token（0600），所有請求都要帶，比對用固定時間
// ⑤Mac mini 自己連自己也拒 ⑥動作只收 POST＋JSON＋X-ShoWork-Token 標頭（跨站表單送不出自訂標頭；不回 CORS）
// ⑦POST 限頻、每筆寫 0600 稽核檔（web/audit.jsonl）⑧按選項只收卡片列出的選項；任意文字走「傳話」並加【使用者從網頁戰情中心】前綴
// ⑨能做的只有 WebAction 五種（回答、傳話、派工、取消派工、收件匣一張張 ack），沒有跑指令／看檔案／關 session／改設定。

// MARK: - 位址

public enum WebBind {
    /// 100.64.0.0/10（CGNAT，Tailscale 發的位址都在這段）
    public static func isTailscale(_ ip: String) -> Bool {
        guard let o = ipv4Octets(ip) else { return false }
        return o[0] == 100 && (o[1] & 0xC0) == 64
    }

    static func ipv4Octets(_ s: String) -> [UInt8]? {
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var out: [UInt8] = []
        for p in parts {
            guard !p.isEmpty, p.count <= 3, p.allSatisfy(\.isASCII), p.allSatisfy(\.isNumber), let v = UInt8(p) else { return nil }
            out.append(v)
        }
        return out
    }

    /// 從本機介面清單挑要綁的位址：只挑 Tailscale 段的 IPv4；utun（Tailscale 在 macOS 的介面）優先。
    /// 找不到就回 nil（伺服器不開，絕不退回 0.0.0.0）
    public static func pick(_ interfaces: [(name: String, ip: String)]) -> String? {
        let ts = interfaces.filter { isTailscale($0.ip) }
        return (ts.first { $0.name.hasPrefix("utun") } ?? ts.first)?.ip
    }

    /// 本機所有 IPv4 介面（getifaddrs）
    public static func interfaces() -> [(name: String, ip: String)] {
        var out: [(name: String, ip: String)] = []
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return out }
        defer { freeifaddrs(head) }
        var p: UnsafeMutablePointer<ifaddrs>? = first
        while let cur = p {
            defer { p = cur.pointee.ifa_next }
            guard let sa = cur.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET) else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let ip = String(decoding: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            out.append((String(cString: cur.pointee.ifa_name), ip))
        }
        return out
    }
}

// MARK: - 設定與 token

public struct WebConfig: Codable, Sendable, Equatable {
    public var enabled: Bool
    public var port: UInt16
    public init(enabled: Bool = false, port: UInt16 = WebConfig.defaultPort) { self.enabled = enabled; self.port = port }
    public static let defaultPort: UInt16 = 8742
}

/// 設定在 `<dir>/config.json`，token 在 `<dir>/token`（都 0600、資料夾 0700）。dir 預設 Application Support/ShoWork42/web，測試換暫存資料夾
public struct WebStore: Sendable {
    public let dir: URL
    public init(dir: URL = Paths.supportDir.appendingPathComponent("web", isDirectory: true)) { self.dir = dir }
    var configURL: URL { dir.appendingPathComponent("config.json") }
    var tokenURL: URL { dir.appendingPathComponent("token") }

    public func config() -> WebConfig {
        guard let d = FileManager.default.contents(atPath: configURL.path), let c = try? JSONDecoder().decode(WebConfig.self, from: d) else { return WebConfig() }
        return c
    }
    public func token() -> String? {
        guard let d = FileManager.default.contents(atPath: tokenURL.path), let s = String(data: d, encoding: .utf8) else { return nil }
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return WebToken.wellFormed(t) ? t : nil
    }

    public func save(_ c: WebConfig) throws {
        try ensureDir()
        try write(JSONEncoder().encode(c), to: configURL)
    }
    /// 產生新 token（舊的書籤就失效）並存起來
    @discardableResult
    public func rotateToken() throws -> String {
        try ensureDir()
        let t = WebToken.generate()
        try write(Data(t.utf8), to: tokenURL)
        return t
    }

    private func ensureDir() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
    }
    /// 先建 0600 的暫存檔再搬過去，中間不會有一刻是別人讀得到的
    private func write(_ d: Data, to url: URL) throws {
        let tmp = dir.appendingPathComponent(".tmp-\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: tmp.path, contents: d, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        if rename(tmp.path, url.path) != 0 { try? FileManager.default.removeItem(at: tmp); throw CocoaError(.fileWriteUnknown) }
    }
}

public enum WebToken {
    /// 32 個隨機位元組 → 64 個小寫十六進位字
    public static func generate() -> String {
        var b = [UInt8](repeating: 0, count: 32)
        if SecRandomCopyBytes(kSecRandomDefault, b.count, &b) != errSecSuccess {
            for i in b.indices { b[i] = UInt8.random(in: 0...255) }   // SystemRandomNumberGenerator 也是密碼學等級
        }
        return b.map { String(format: "%02x", $0) }.joined()
    }
    public static func wellFormed(_ t: String) -> Bool {
        t.utf8.count == 64 && t.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
    /// 固定時間比對（不因第幾個字不同而早退）
    public static func matches(_ given: String?, _ expected: String?) -> Bool {
        guard let g = given, let e = expected, wellFormed(e) else { return false }
        let a = Array(g.utf8), b = Array(e.utf8)
        var diff = UInt8(a.count == b.count ? 0 : 1)
        for i in 0..<b.count { diff |= (i < a.count ? a[i] : 0) ^ b[i] }
        return diff == 0
    }
}

// MARK: - HTTP 請求（只認 HTTP/1.1 最基本的形狀）

public struct WebRequest: Sendable, Equatable {
    public var method: String
    public var path: String
    public var query: [String: String]
    public var headers: [String: String]     // 小寫鍵
    public var body: Data

    public static let maxHeader = 16 * 1024
    public static let maxBody = 16 * 1024

    public enum Parse: Equatable { case need, bad, ok(WebRequest) }

    /// 收到的位元組夠不夠組成一個請求；太大或格式壞掉回 .bad
    public static func parse(_ data: Data) -> Parse {
        let sep = Data("\r\n\r\n".utf8)
        guard let r = data.range(of: sep) else { return data.count > maxHeader ? .bad : .need }
        guard r.lowerBound <= maxHeader, let head = String(data: data[data.startIndex..<r.lowerBound], encoding: .utf8) else { return .bad }
        var lines = head.components(separatedBy: "\r\n")
        let start = lines.removeFirst().split(separator: " ", omittingEmptySubsequences: true)
        guard start.count == 3, start[2].hasPrefix("HTTP/1.") else { return .bad }
        var headers: [String: String] = [:]
        for l in lines {
            guard let c = l.firstIndex(of: ":") else { return .bad }
            headers[l[..<c].trimmingCharacters(in: .whitespaces).lowercased()] = l[l.index(after: c)...].trimmingCharacters(in: .whitespaces)
        }
        if headers["transfer-encoding"] != nil { return .bad }   // 不支援 chunked
        let len: Int
        if let v = headers["content-length"] { guard let n = Int(v), n >= 0, n <= maxBody else { return .bad }; len = n } else { len = 0 }
        let bodyStart = r.upperBound
        guard data.count - (bodyStart - data.startIndex) >= len else { return .need }
        let body = data[bodyStart..<(bodyStart + len)]
        let target = String(start[1])
        guard target.hasPrefix("/") else { return .bad }
        let comps = URLComponents(string: "http://x" + target)
        var q: [String: String] = [:]
        for i in comps?.queryItems ?? [] { q[i.name] = i.value ?? "" }
        return .ok(WebRequest(method: String(start[0]), path: comps?.path ?? target, query: q, headers: headers, body: Data(body)))
    }
}

public struct WebResponse: Sendable, Equatable {
    public var status: Int
    public var contentType: String
    public var body: Data
    public init(_ status: Int, _ contentType: String = "application/json; charset=utf-8", _ body: Data) {
        self.status = status; self.contentType = contentType; self.body = body
    }
    public static func json(_ status: Int, _ obj: [String: String]) -> WebResponse {
        WebResponse(status, "application/json; charset=utf-8", (try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])) ?? Data("{}".utf8))
    }
    static func reason(_ s: Int) -> String {
        switch s {
        case 200: "OK"; case 400: "Bad Request"; case 403: "Forbidden"; case 404: "Not Found"
        case 405: "Method Not Allowed"; case 409: "Conflict"; case 413: "Payload Too Large"; case 415: "Unsupported Media Type"; case 429: "Too Many Requests"
        default: "Error"
        }
    }
    public func serialized() -> Data {
        var h = "HTTP/1.1 \(status) \(Self.reason(status))\r\n"
        h += "Content-Type: \(contentType)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n"
        h += "Cache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\nReferrer-Policy: no-referrer\r\nX-Frame-Options: DENY\r\n"
        h += "Content-Security-Policy: default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; connect-src 'self'; img-src data:; base-uri 'none'; form-action 'none'; frame-ancestors 'none'\r\n\r\n"
        return Data(h.utf8) + body
    }
}

// MARK: - 給網頁的 JSON

public struct WebSnapshot: Codable, Sendable, Equatable {
    public struct Session: Codable, Sendable, Equatable {
        public var id: String
        public var name: String
        public var project: String
        public var column: String          // todo／active／review／done／stuck
        public var columnTitle: String     // 待辦／工作中／待審／完成／卡住
        public var reason: String
        public var doing: String?
        public var summary: String?
        public var idleSeconds: Int?
        public var captain: Bool
        public var question: String?
        public var options: [String]
        public var canAnswer: Bool         // 只有「要你決定」（一般輸入框等你）能從網頁按選項；權限／選擇題／選單要回終端機或原生 App
        public var answeredAt: Date?
    }
    public struct Task: Codable, Sendable, Equatable {
        public var id: String
        public var to: String
        public var project: String?
        public var text: String
        public var state: String
        public var stateTitle: String
        public var summary: String?
        public var updatedAt: Date
    }
    /// 隊長收件匣還沒 ack 的（開工卡／動作預告／擋下等放行）
    public struct InboxEntry: Codable, Sendable, Equatable {
        public var id: String
        public var kind: String
        public var name: String
        public var project: String?
        public var text: String
        public var at: Date
    }
    public var generatedAt: Date
    public var sessions: [Session]
    public var tasks: [Task]
    public var inbox: [InboxEntry]

    public static func columnTitle(_ c: BoardColumn) -> String { c == .active ? "工作中" : c.title }

    /// 網頁「傳話」「派工」的文字一律加這個前綴，收到的 AI 看得出是使用者本人從（有 token 的）網頁送的。
    /// 對照原生收件匣 Peer 直送時 BoardActions.answer 加的「【使用者從戰情中心回答你的問題】」
    public static let sendPrefix = "【使用者從網頁戰情中心】"

    /// 排序：等你回答的在前、再來卡住、待審、工作中、完成、待辦；同組照專案名
    public static func make(cards: [BoardCard], tasks: [CaptainTask], inbox: [CaptainInboxItem] = [], answered: [String: Date], now: Date) -> WebSnapshot {
        let items = Dictionary(Inbox.items(cards, answered: answered).map { ($0.card.sessionId, $0) }, uniquingKeysWith: { a, _ in a })
        let rank: [BoardColumn: Int] = [.stuck: 1, .review: 2, .active: 3, .done: 4, .todo: 5]
        let ss: [Session] = cards.filter { !$0.unused && !$0.id.contains("#") }.map { c in
            let it = items[c.sessionId]
            let summary = c.report?.summary ?? c.detail
            return Session(id: c.sessionId, name: c.name ?? c.title, project: c.project, column: c.column.rawValue,
                           columnTitle: columnTitle(c.column), reason: c.reason, doing: c.report?.doing,
                           summary: summary.map { String($0.prefix(400)) },
                           idleSeconds: c.lastActivity.map { max(0, Int(now.timeIntervalSince($0))) }, captain: c.captain,
                           question: it?.question, options: it?.kind == .reply ? it!.options : [],
                           canAnswer: it?.kind == .reply, answeredAt: it?.answered)
        }.sorted { a, b in
            let ra = a.question != nil ? 0 : rank[BoardColumn(rawValue: a.column) ?? .todo] ?? 9
            let rb = b.question != nil ? 0 : rank[BoardColumn(rawValue: b.column) ?? .todo] ?? 9
            return ra != rb ? ra < rb : (a.project, a.name) < (b.project, b.name)
        }
        let ts = tasks.filter { $0.state.open }.sorted { $0.updatedAt > $1.updatedAt }.map {
            Task(id: $0.id, to: $0.to, project: $0.project, text: String($0.text.prefix(300)), state: $0.state.rawValue,
                 stateTitle: $0.state.title, summary: $0.summary, updatedAt: $0.updatedAt)
        }
        let ib = inbox.filter { $0.acked == nil }.sorted { $0.at > $1.at }.prefix(30).map {
            InboxEntry(id: $0.id, kind: $0.kind.rawValue, name: $0.name, project: $0.project, text: String($0.text.prefix(300)), at: $0.at)
        }
        return WebSnapshot(generatedAt: now, sessions: ss, tasks: ts, inbox: Array(ib))
    }

    /// 按選項：只收這張卡片列出的選項之一（任意文字走「傳話」，會加前綴）
    public static func validate(answer text: String, for id: String, cards: [BoardCard]) -> Result<BoardCard, CardError> {
        guard let c = cards.first(where: { $0.sessionId == id }) else { return .failure(.init("找不到這個 session，可能已經關了")) }
        guard let it = Inbox.items([c]).first, it.kind == .reply else { return .failure(.init("它現在沒有在等你回答")) }
        guard it.options.contains(text) else { return .failure(.init("只能按卡片上的選項")) }
        return .success(c)
    }

    /// 傳話／派工的對象：看板上活著的 session（子 agent 那種「#」卡不算）
    public static func target(_ id: String, cards: [BoardCard]) -> Result<BoardCard, CardError> {
        guard let c = cards.first(where: { $0.sessionId == id && !$0.id.contains("#") }) else { return .failure(.init("找不到這個 session，可能已經關了")) }
        return .success(c)
    }
}

// MARK: - 動作

/// 網頁能做的事只有這五種：沒有跑指令、看檔案、關／重開 session、改名字或設定
public enum WebAction: Equatable, Sendable {
    case answer(session: String, text: String)     // 按卡片選項（跟原生收件匣同一條 BoardActions.answer）
    case send(session: String, text: String)       // 傳話給某個 session（BoardActions.answer 同一條送法，前面加 sendPrefix）
    case dispatch(session: String, text: String)   // 開派工單（BoardActions.dispatch，跟看板「派工」同一條；內文加 sendPrefix）
    case cancel(task: String)                      // 取消派工單（Captain.cancel，跟 showork task cancel 同一條）
    case ack(inbox: String)                        // 隊長收件匣標已處理，一次一張（CaptainInbox.ack；不收 all）

    public var name: String {
        switch self { case .answer: "answer"; case .send: "send"; case .dispatch: "dispatch"; case .cancel: "cancel"; case .ack: "ack" }
    }
    public var target: String {
        switch self { case .answer(let s, _), .send(let s, _), .dispatch(let s, _): s; case .cancel(let t): t; case .ack(let i): i }
    }
    public var text: String? {
        switch self { case .answer(_, let t), .send(_, let t), .dispatch(_, let t): t; default: nil }
    }

    public static let paths = ["/api/answer", "/api/send", "/api/task", "/api/task/cancel", "/api/inbox/ack"]
    public static let maxAnswer = 200, maxText = 2000

    static func matches(_ s: String, _ pattern: String) -> Bool { s.range(of: pattern, options: .regularExpression) != nil }
    /// session id（UUID）只收英數與 -
    static func sessionOK(_ s: String) -> Bool { matches(s, "^[A-Za-z0-9-]{1,64}$") }
    /// 派工單號：T＋月日時分秒（Captain.newId），重複時加 -2、-3。只收這個形狀（單號會拿去拼檔名）
    static func taskOK(_ s: String) -> Bool { matches(s, "^T[0-9]{10}(-[0-9]{1,3})?$") }
    /// 收件匣單號：B／N／S＋4 碼（CaptainInbox.newID）；「all」不收
    static func inboxOK(_ s: String) -> Bool { matches(s, "^[BNS][A-HJ-NP-Z2-9]{4}$") }

    public static func parse(path: String, body: Data) -> Result<WebAction, CardError> {
        guard let o = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { return .failure(.init("要 JSON 物件")) }
        func str(_ k: String) -> String? { (o[k] as? String).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty ? nil : $0 } }
        switch path {
        case "/api/answer", "/api/send", "/api/task":
            guard let id = str("id"), sessionOK(id) else { return .failure(.init("缺 id 或格式不對")) }
            guard let text = str("text") else { return .failure(.init("缺 text")) }
            let limit = path == "/api/answer" ? maxAnswer : maxText
            guard text.count <= limit else { return .failure(.init("太長了（最多 \(limit) 字）")) }
            switch path {
            case "/api/answer": return .success(.answer(session: id, text: text))
            case "/api/send": return .success(.send(session: id, text: text))
            default: return .success(.dispatch(session: id, text: text))
            }
        case "/api/task/cancel":
            guard let id = str("id"), taskOK(id) else { return .failure(.init("派工單號格式不對")) }
            return .success(.cancel(task: id))
        case "/api/inbox/ack":
            guard let id = str("id")?.uppercased(), inboxOK(id) else { return .failure(.init("收件匣單號格式不對（一次一張，不收 all）")) }
            return .success(.ack(inbox: id))
        default:
            return .failure(.init("沒有這個動作"))
        }
    }
}

// MARK: - 頻率限制與稽核

/// 每個來源 IP：兩次 POST 至少隔 minGap、每分鐘最多 perMinute 次
public struct WebRateLimiter: Sendable {
    public var perMinute: Int
    public var minGap: TimeInterval
    private var hits: [String: [Date]] = [:]
    public init(perMinute: Int = 20, minGap: TimeInterval = 0.5) { self.perMinute = perMinute; self.minGap = minGap }

    public mutating func allow(_ peer: String, now: Date) -> Bool {
        var xs = (hits[peer] ?? []).filter { now.timeIntervalSince($0) < 60 }
        defer { hits[peer] = xs }
        if let last = xs.last, now.timeIntervalSince(last) < minGap { return false }
        guard xs.count < perMinute else { return false }
        xs.append(now)
        return true
    }
}

public struct WebAuditEntry: Codable, Sendable, Equatable {
    public var at: Date
    public var peer: String
    public var action: String
    public var target: String?
    public var text: String?
    public var status: Int
    public var result: String
    public init(at: Date, peer: String, action: String, target: String? = nil, text: String? = nil, status: Int, result: String) {
        self.at = at; self.peer = peer; self.action = action; self.target = target
        self.text = text.map { String($0.prefix(300)) }; self.status = status; self.result = String(result.prefix(300))
    }
}

extension WebStore {
    var auditURL: URL { dir.appendingPathComponent("audit.jsonl") }
    /// 每個 POST（成功、失敗、token 不對、限頻）都記一行；檔案建立時就是 0600
    public func audit(_ e: WebAuditEntry) {
        guard var d = try? BoardJSON.encoder.encode(e) else { return }
        d.append(0x0A)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let fd = Darwin.open(auditURL.path, O_WRONLY | O_APPEND | O_CREAT, 0o600)
        guard fd >= 0 else { return }
        defer { Darwin.close(fd) }
        _ = d.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
    }
    public func auditLines() -> [WebAuditEntry] {
        guard let d = FileManager.default.contents(atPath: auditURL.path) else { return [] }
        return d.split(separator: 0x0A).compactMap { try? BoardJSON.decoder.decode(WebAuditEntry.self, from: Data($0)) }
    }
}

// MARK: - 路由

public enum WebRouter {
    public static let tokenHeader = "x-showork-token"

    /// - Parameters:
    ///   - peer: 連線端 IP（不是 Tailscale 段就 403）
    ///   - localIP: 綁的位址；連線端就是自己（Mac mini 上的程式繞 Tailscale 連自己）也 403，免得本機的 AI 替你按按鈕
    ///   - limiter: POST 頻率限制（通過 token 檢查後才算次數）
    ///   - snapshot: 產生看板 JSON
    ///   - perform: 執行動作 → 成功訊息或錯誤
    ///   - audit: 每個 POST 的結果
    public static func handle(_ r: WebRequest, peer: String?, localIP: String?, token: String?, page: Data, now: Date = Date(),
                              limiter: inout WebRateLimiter,
                              snapshot: () -> Data,
                              perform: (WebAction) -> Result<String, CardError>,
                              audit: (WebAuditEntry) -> Void = { _ in }) -> WebResponse {
        guard let peer, WebBind.isTailscale(peer) else { return .json(403, ["error": "只接受 Tailscale 連線"]) }
        guard peer != localIP else { return .json(403, ["error": "不接受 Mac mini 自己連自己"]) }
        guard token != nil else { return .json(403, ["error": "還沒設定 token（showork web enable）"]) }
        let isAction = WebAction.paths.contains(r.path)
        switch (r.method, r.path) {
        case ("GET", "/"), ("GET", "/index.html"):
            guard WebToken.matches(r.query["t"], token) else { return .json(403, ["error": "token 不對"]) }
            return WebResponse(200, "text/html; charset=utf-8", page)
        case ("GET", "/api/board"):
            guard WebToken.matches(r.headers[tokenHeader], token) else { return .json(403, ["error": "token 不對"]) }
            return WebResponse(200, "application/json; charset=utf-8", snapshot())
        case ("POST", _) where isAction:
            func done(_ resp: WebResponse, _ a: WebAction?, _ msg: String) -> WebResponse {
                audit(WebAuditEntry(at: now, peer: peer, action: a?.name ?? r.path, target: a?.target, text: a?.text, status: resp.status, result: msg))
                return resp
            }
            guard WebToken.matches(r.headers[tokenHeader], token) else { return done(.json(403, ["error": "token 不對"]), nil, "token 不對") }
            guard (r.headers["content-type"] ?? "").lowercased().hasPrefix("application/json") else { return done(.json(415, ["error": "要 JSON"]), nil, "不是 JSON") }
            guard limiter.allow(peer, now: now) else { return done(.json(429, ["error": "按太快了，等一下再試"]), nil, "頻率限制") }
            let a: WebAction
            switch WebAction.parse(path: r.path, body: r.body) {
            case .failure(let e): return done(.json(400, ["error": e.message]), nil, e.message)
            case .success(let x): a = x
            }
            switch perform(a) {
            case .success(let m): return done(.json(200, ["ok": "1", "message": m]), a, m)
            case .failure(let e): return done(.json(409, ["error": e.message]), a, e.message)
            }
        case (_, "/"), (_, "/index.html"), (_, "/api/board"):
            return .json(405, ["error": "方法不對"])
        case (_, _) where isAction:
            return .json(405, ["error": "方法不對"])
        default:
            return .json(404, ["error": "沒有這頁"])
        }
    }
}
