import Foundation
import Network
import ShoWorkCore

// 網頁版戰情中心的 HTTP 伺服器（11-10，規則在 ShoWorkCore/WebBoard.swift，頁面在 WebPage.swift）。
// 放在看板常駐程式裡（不是另開 `showork web serve`），因為：①看板資料（BoardModel.shared.cards、captainTasks）本來就在這裡算好，
// 不用再讀一次 ②回答要走跟收件匣按鈕同一條 BoardActions.answer（tmux 打字 → Peer 直送 → 拷貝，並轉隊長【使用者已答】），
// 那條路是 @MainActor、要 BoardModel，只有這個行程有。
// 開關：`showork web enable|disable` 寫 web/config.json 後發 ai.okle42.showork.web 通知，這裡重讀，不用重開 agent。
// Unix socket（Server.swift）完全不動；這是另一個 listener，只綁 Tailscale IP。

@MainActor
final class WebServer {
    static let shared = WebServer()
    static let reloadNote = Notification.Name("ai.okle42.showork.web")

    private var listener: NWListener?
    private var boundIP: String?
    private var port: UInt16 = 0
    private var retry: Timer?
    private var open = 0
    /// 從網頁回答過的時間（sessionId → 時間），讓網頁顯示「已送出」；原生收件匣的 answered 是畫面 @State，網頁另記
    private var answered: [String: Date] = [:]
    private var limiter = WebRateLimiter()
    private let store = WebStore()
    private let page = Data(WebPage.html.utf8)

    func start() {
        DistributedNotificationCenter.default().addObserver(forName: Self.reloadNote, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { WebServer.shared.reload() }
        }
        reload()
    }

    /// 照設定開／關。開著但 Tailscale 還沒連上 ⇒ 每 30 秒再找一次位址；位址換了就重綁
    func reload() {
        let cfg = store.config()
        guard cfg.enabled, store.token() != nil else { stop(); retry?.invalidate(); retry = nil; return }
        if retry == nil {
            retry = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in MainActor.assumeIsolated { WebServer.shared.reload() } }
        }
        guard let ip = WebBind.pick(WebBind.interfaces()) else {
            if listener != nil { NSLog("ShoWork web: Tailscale 位址不見了，先關掉"); stop() }
            return
        }
        if listener != nil, ip == boundIP, cfg.port == port { return }
        stop()
        bind(ip: ip, port: cfg.port)
    }

    private func stop() {
        listener?.cancel(); listener = nil; boundIP = nil
    }

    private func bind(ip: String, port p: UInt16) {
        guard WebBind.isTailscale(ip), let nwPort = NWEndpoint.Port(rawValue: p), let v4 = IPv4Address(ip) else { return }
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: .ipv4(v4), port: nwPort)   // 只綁這個位址，不是 0.0.0.0
        params.allowLocalEndpointReuse = true
        do {
            let l = try NWListener(using: params)
            l.newConnectionHandler = { c in MainActor.assumeIsolated { WebServer.shared.accept(c) } }
            l.stateUpdateHandler = { st in
                MainActor.assumeIsolated {
                    switch st {
                    case .ready: NSLog("ShoWork web: listening on http://\(ip):\(p)/")
                    case .failed(let e): NSLog("ShoWork web: listener failed \(e)"); WebServer.shared.stop()
                    default: break
                    }
                }
            }
            l.start(queue: .main)
            listener = l; boundIP = ip; port = p
        } catch {
            NSLog("ShoWork web: cannot listen on \(ip):\(p): \(error)")
        }
    }

    private func accept(_ c: NWConnection) {
        guard open < 16 else { c.cancel(); return }
        open += 1
        c.stateUpdateHandler = { st in
            MainActor.assumeIsolated {
                switch st {
                case .cancelled, .failed: WebServer.shared.open -= 1
                default: break
                }
            }
        }
        c.start(queue: .main)
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { c.cancel() }   // 慢慢送的連線不留
        let peer = Self.peerIP(c.endpoint)
        guard let peer, WebBind.isTailscale(peer), peer != boundIP else { c.cancel(); return }  // 不是 Tailscale 來的、或自己連自己：連回應都不給
        receive(c, peer: peer, buf: Data())
    }

    private func receive(_ c: NWConnection, peer: String, buf: Data) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { data, _, done, err in
            MainActor.assumeIsolated {
                var b = buf
                if let data { b.append(data) }
                switch WebRequest.parse(b) {
                case .ok(let r): WebServer.shared.respond(c, WebServer.shared.handle(r, peer: peer))
                case .bad: WebServer.shared.respond(c, .json(400, ["error": "請求格式不對"]))
                case .need:
                    if done || err != nil { c.cancel() } else { WebServer.shared.receive(c, peer: peer, buf: b) }
                }
            }
        }
    }

    private func respond(_ c: NWConnection, _ r: WebResponse) {
        c.send(content: r.serialized(), completion: .contentProcessed { _ in c.cancel() })
    }

    func handle(_ r: WebRequest, peer: String) -> WebResponse {
        WebRouter.handle(r, peer: peer, localIP: boundIP, token: store.token(), page: page, limiter: &limiter,
                         snapshot: { [self] in
                             let s = WebSnapshot.make(cards: BoardModel.shared.cards, tasks: BoardModel.shared.captainTasks,
                                                      inbox: CaptainInbox.pending(now: Date()), answered: answered, now: Date())
                             return (try? BoardJSON.encoder.encode(s)) ?? Data("{}".utf8)
                         },
                         perform: { [self] a in perform(a, peer: peer) },
                         audit: { [store] e in
                             store.audit(e)
                             NSLog("ShoWork web: \(e.action) \(e.target ?? "-") from \(e.peer) → \(e.status)")
                         })
    }

    /// 每個動作都接到原生看板／CLI 已經有的那條路，不另做一套
    private func perform(_ a: WebAction, peer: String) -> Result<String, CardError> {
        let cards = BoardModel.shared.cards
        // 測試視窗／示範資料絕不真的送（跟原生收件匣同一條規矩）
        if OfficeDemo.mode != nil || BoardWindow.testMode { return .success("測試：不執行 \(a.name)") }
        BoardModel.shared.append(["ev": "web-\(a.name)", "id": a.target, "peer": peer])
        defer { BoardModel.shared.refresh() }
        switch a {
        case .answer(let id, let text):
            // 跟原生收件匣按選項同一條：BoardActions.answer（tmux 打字 → Peer 直送 → 拷貝；轉隊長【使用者已答】；「放行」直接放行）
            return WebSnapshot.validate(answer: text, for: id, cards: cards).map { c in
                answered[c.sessionId] = Date()
                return BoardActions.answer(c, text: Inbox.message(text))
            }
        case .send(let id, let text):
            // 跟 3D 辦公室「跟他說」同一條（OfficeView onPersonSend → BoardActions.answer），前面加網頁前綴
            return WebSnapshot.target(id, cards: cards).map { c in
                answered[c.sessionId] = Date()
                return BoardActions.answer(c, text: WebSnapshot.sendPrefix + Inbox.message(text), resolvesAsk: false)
            }
        case .dispatch(let id, let text):
            // 跟看板「派工」（DispatchSheet）同一條：BoardActions.dispatch → Captain.dispatch（建單＋直送）
            return WebSnapshot.target(id, cards: cards).flatMap { c in
                BoardActions.dispatch(to: c, text: WebSnapshot.sendPrefix + text, thenTo: nil, thenText: nil,
                                      captain: CaptainStore.captain()?.sessionId)
                    .map { "已派工 \($0) 給 \(c.name ?? c.title)" }
            }
        case .cancel(let id):
            // 跟 showork task cancel 同一條（Captain.cancel）
            guard let t = CaptainStore.task(id), t.state.open else { return .failure(CardError("找不到還沒結的派工單 \(id)")) }
            guard let (t2, notified) = Captain.cancel(t.id) else { return .failure(CardError("找不到派工單 \(id)")) }
            return .success(notified ? "已取消 \(id)，也通知 \(t2.to) 不用做了" : "已取消 \(id)；通知 \(t2.to) 失敗")
        case .ack(let id):
            // 跟 showork captain ack <單號> 同一條（CaptainInbox.ack），只收單號（parse 已擋 all）
            return CaptainInbox.ack(id, now: Date()) == 1 ? .success("已標 \(id) 為已處理") : .failure(CardError("找不到未處理的 \(id)"))
        }
    }


    nonisolated static func peerIP(_ e: NWEndpoint) -> String? {
        guard case .hostPort(let host, _) = e else { return nil }
        switch host {
        case .ipv4(let a): return "\(a)".split(separator: "%").first.map(String.init)
        case .ipv6(let a):    // IPv4 對應的 IPv6（::ffff:100.x）也認
            let s = "\(a)".split(separator: "%").first.map(String.init) ?? ""
            return s.lowercased().hasPrefix("::ffff:") ? String(s.dropFirst(7)) : s
        default: return nil
        }
    }
}
