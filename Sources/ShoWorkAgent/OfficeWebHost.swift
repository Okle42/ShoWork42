import AppKit
import Combine
import SwiftUI
import WebKit
import ShoWorkCore

// 3D 辦公大樓的 Web 版宿主（11-08）：WKWebView 載 Windows 共用的 office.html（windows/ShoWork.Win/Board/Web），取代 SceneKit 的 OfficeView。
// 訊息格式見那裡的 PROTOCOL.md。Windows 端對照：Board/View/OfficeHost.cs（WebView2）＋BoardForm.HandleAction。
//   原生端 → 網頁：window.swRecv(obj)（office.js 開頭的 shim 轉成 host 的 "message" 事件）。
//   網頁 → 原生端：webkit.messageHandlers.sw.postMessage(obj)。
// office.js 是 ES module（import three），file:// 會被擋 ⇒ 用自訂 scheme showork://web/… 從 Web 資料夾回檔案（OfficeWebSchemeHandler）。
// 資料：BoardModel 發布就重推 office2（0.3 秒內的變動併成一次；內容一樣不推）；地下室圖譜只在換了的時候帶（網頁每收到一次就重建）。
// 拖檔：WKWebView 裡的 File 沒有路徑 ⇒ OfficeWebView（子類）在原生端先記下拖進來的路徑，網頁送 dropFiles{key} 時回 dropPaths{key, paths}。

@MainActor
final class OfficeWebHost: NSObject, WKScriptMessageHandler, WKNavigationDelegate, WKUIDelegate {
    /// 測試（--office-web-snap）：動作一律不送出，設定不寫回
    static var testMode = false

    // 外面（BoardView）給的：跟 OfficeView 同名同用途
    var onSendBack: (BoardCard) -> Void = { _ in }
    var onPark: (BoardCard) -> Void = { _ in }
    var onDispatch: (BoardCard) -> Void = { _ in }
    /// 動作的結果一句話；nil ⇒ 顯示在網頁自己的 toast
    var onToast: ((String) -> Void)?

    let web: OfficeWebView
    let demo: Bool
    private(set) var ready = false
    private(set) var pushes = 0                     // 推過幾次 office2（測試印出來）
    private(set) var lastCards = 0
    private var latest: String?, sent: String?
    private var graphSent: NeuralGraph?
    private var subs: [AnyCancellable] = []
    private var observers: [NSObjectProtocol] = []
    private var pending = false
    private var lastVisible: Bool?
    private static let demoGraph = NeuralGraph.demo()

    private var model: BoardModel { BoardModel.shared }
    private var blocked: Bool { Self.testMode || BoardWindow.testMode }

    /// demo＝載 office.html?demo=1（網頁自己讀 bench/mac-input.json，不接原生端、不送任何動作）
    init?(demo: Bool = false, extraQuery: String = "") {
        guard let dir = WorkWindow.webDir, FileManager.default.fileExists(atPath: dir.appendingPathComponent("office.html").path) else { return nil }
        self.demo = demo
        let cfg = WKWebViewConfiguration()
        cfg.setURLSchemeHandler(OfficeWebSchemeHandler(root: dir), forURLScheme: OfficeWebSchemeHandler.scheme)
        if Self.testMode { cfg.websiteDataStore = .nonPersistent() }        // 測試不碰正式的 localStorage（燈光、風格設定）
        web = OfficeWebView(frame: .zero, configuration: cfg)
        super.init()
        // 示範模式不掛 handler：office.js 找不到 host 才會走示範那條路（讀 bench 的資料）
        if !demo { cfg.userContentController.add(OfficeWeakHandler(self), name: "sw") }
        web.setValue(false, forKey: "drawsBackground")
        // 測試視窗在螢幕外＝被蓋住 ⇒ WebKit 把頁面當 hidden、requestAnimationFrame 停掉，WebGL 一張都不畫。測試時關掉遮擋偵測（WebKit SPI，沒有就算了）
        let occ = NSSelectorFromString("_setWindowOcclusionDetectionEnabled:")
        if Self.testMode, web.responds(to: occ), let m = class_getInstanceMethod(WKWebView.self, occ) {
            typealias SetBool = @convention(c) (AnyObject, Selector, Bool) -> Void
            unsafeBitCast(method_getImplementation(m), to: SetBool.self)(web, occ, false)
        }
        web.navigationDelegate = self
        web.uiDelegate = self
        web.onVisible = { [weak self] v in self?.visibleChanged(v) }
        var q = demo ? "demo=1" : ""
        if !extraQuery.isEmpty { q += (q.isEmpty ? "" : "&") + extraQuery }
        web.load(URLRequest(url: URL(string: "\(OfficeWebSchemeHandler.scheme)://web/office.html" + (q.isEmpty ? "" : "?" + q))!))
        if !demo { subscribe() }
    }

    func tearDown() {
        subs.removeAll()
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
        web.configuration.userContentController.removeScriptMessageHandler(forName: "sw")
    }

    // MARK: 訂閱資料

    private func subscribe() {
        model.start()
        model.objectWillChange.sink { [weak self] _ in self?.schedule() }.store(in: &subs)
        OfficeWeather.shared.objectWillChange.sink { [weak self] _ in self?.schedule() }.store(in: &subs)
        GraphSource.shared.$graph.removeDuplicates().sink { [weak self] _ in self?.schedule() }.store(in: &subs)
        // 地名搜尋結果（回應 weatherSearch）
        OfficeWeather.shared.$results.combineLatest(OfficeWeather.shared.$searchNote).dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] r, note in
                MainActor.assumeIsolated {
                    var o: [String: Any] = ["type": "weatherResults", "results": r.map(Self.site)]
                    if let note { o["note"] = note }
                    self?.post(o)
                }
            }.store(in: &subs)
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: GlowSettings.changed, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.schedule() }
        })
        observers.append(nc.addObserver(forName: HeatGate.changed, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.post(["type": "heat", "paused": HeatGate.shared.paused]) }
        })
    }

    /// 0.3 秒內的發布併成一次（objectWillChange 是改之前發的：下一輪 run loop 才讀得到新值）
    private func schedule() {
        guard !pending else { return }
        pending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            MainActor.assumeIsolated { self?.pending = false; self?.pushData() }
        }
    }

    private func pushData() {
        guard ready, !demo else { return }
        var o = office2()
        // 圖譜：只在換了的時候帶（網頁收到就重建）；還是示範圖譜就給空的（網頁留著自己的示範）
        let g = GraphSource.shared.graph
        if graphSent != g {
            graphSent = g
            o["graph"] = g == Self.demoGraph ? ["nodes": [], "edges": []] : SceneDump.json(g)
        }
        guard let d = try? JSONSerialization.data(withJSONObject: o) else { return }
        let s = String(decoding: d, as: UTF8.self)
        latest = s
        // now 每次都不同：比對時拿掉 now 再比，不然每次都會推
        let key = s.replacingOccurrences(of: #""now":[0-9.]+"#, with: "", options: .regularExpression)
        guard key != sent else { return }
        sent = key
        pushes += 1
        web.evaluateJavaScript("window.swRecv(\(s))")
    }

    // MARK: office2（PROTOCOL.md；形狀同 SceneDump.input，但不洗掉路徑：工作視窗要用 cwd）

    func office2() -> [String: Any] {
        let m = model
        let cards = m.cards
        lastCards = cards.count
        let w = OfficeWeather.shared
        let p = OfficePrefs()
        let j = { (v: Any) in SceneDump.json(v) }
        var o: [String: Any] = [
            "type": "office2", "source": "mac", "now": Date().timeIntervalSince1970,
            "tower": j(m.tower), "decor": j(m.decor), "wander": j(m.wander), "islands": j(Islands.build(cards)),
            "guardStatus": j(m.guardStatus), "scanning": m.guardScanning,
            "city": CityMonitor.off ? NSNull() : j(m.city),
            "cards": j(cards),
            "captainThread": j(m.captainThread), "captainTasks": j(m.captainTasks), "sessionThread": j(m.sessionThread),
            "runs": j(m.runs), "reviewing": Array(m.reviewing).sorted(),
            "captainModelTitle": BoardActions.modelTitle(BoardActions.captainModel),
            "site": Self.site(w.main),
            "weatherSites": w.sites.map { s -> [String: Any] in
                ["site": Self.site(s), "report": w.report(s).map { ["now": j($0.now), "at": $0.at.timeIntervalSince1970] as [String: Any] } ?? NSNull(),
                 "failed": w.failed.contains(s)]
            },
            "weatherMenuStatus": w.menuStatus,
            "lighting": p.lighting.rawValue,
            "colors": ["working": GlowSettings.shared.look(.working).hex, "input": GlowSettings.shared.look(.input).hex,
                       "done": GlowSettings.shared.look(.done).hex],
            "reduceMotion": NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
        ]
        if let now = w.current { o["weather"] = ["now": j(now), "at": (w.reports[w.main]?.at ?? Date()).timeIntervalSince1970] }
        else { o["weather"] = NSNull() }
        return o
    }

    static func site(_ s: WeatherSite) -> [String: Any] {
        var o: [String: Any] = ["title": s.title, "lat": s.lat, "lon": s.lon]
        if let d = s.detail { o["detail"] = d }
        return o
    }

    // MARK: 網頁 → Swift

    func userContentController(_ ucc: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let m = message.body as? [String: Any], let type = m["type"] as? String else { return }
        switch type {
        case "ready":
            ready = true; sent = nil; graphSent = nil
            pushData()
            post(["type": "heat", "paused": HeatGate.shared.paused])
            if let v = lastVisible { post(["type": "visible", "visible": v]) }
            post(["type": "b1Posts", "posts": Self.b1Posts()])
        case "action": action(m)
        case "dropFiles":
            post(["type": "dropPaths", "key": m["key"] as? String ?? "", "paths": web.takeDropped()])
        default: break
        }
    }

    private func card(_ m: [String: Any]) -> BoardCard? {
        let cards = model.cards
        if let id = m["id"] as? String, let c = cards.first(where: { $0.id == id }) { return c }
        if let sid = m["sessionId"] as? String { return cards.first { $0.sessionId == sid && !$0.id.contains("#") } ?? cards.first { $0.sessionId == sid } }
        return nil
    }

    /// 動作（PROTOCOL.md「網頁 → C#」那張表；Mac 對應照 OfficeView 的按鈕）
    func action(_ m: [String: Any]) {
        let a = m["action"] as? String ?? ""
        let str = { (k: String) in m[k] as? String }
        switch a {
        case "answer":
            guard let c = card(m) else { return toast("這張卡已經不在了") }
            let text = str("text") ?? ""
            if blocked { return toast("測試：不送出「\(text)」") }
            toast(BoardActions.answer(c, text: text))
        case "permit":
            guard let c = card(m) else { return toast("這張卡已經不在了") }
            let d = PermitAnswer.Decision(rawValue: str("decision") ?? "") ?? .deny
            if blocked { return toast("測試：不回答權限（\(d.rawValue)）") }
            if let pid = str("permitId"), let cur = c.permit?.id, pid != cur { return toast("這個對話框已經關了") }
            toast(BoardActions.permit(c, PermitAnswer(d, message: str("message"), answers: m["answers"] as? [String: [String]])))
        case "askCaptain":
            let text = str("text") ?? ""
            if blocked { return toast("測試：不交給隊長「\(text)」", captainDone: true) }
            DispatchQueue.global().async {
                let msg = BoardActions.askCaptain(text)
                DispatchQueue.main.async { MainActor.assumeIsolated { self.toast(msg, captainDone: true) } }
            }
        case "focus":
            guard let c = card(m) else { return toast("找不到這個 session 的視窗") }
            jump(c)
        case "approve":
            guard let c = card(m) else { return }
            if blocked { return toast("測試：不放行") }
            BoardActions.approve(c)
        case "dispatch": if let c = card(m) { onDispatch(c) }
        case "sendBack": if let c = card(m) { onSendBack(c) }
        case "park": if let c = card(m) { onPark(c) }
        case "review":
            guard let c = card(m) else { return }
            if blocked { return toast("測試：不重新審核") }
            Reviewer.shared.start(c, force: true)
        case "redecorate":
            if blocked { return toast("測試：不重新裝潢") }
            toast(model.redecorate(str("project") ?? ""))
        case "guardScan": guardScan()
        case "pushAllow":
            guard let dir = str("dir"), let head = str("head"), !head.isEmpty else { return }
            if blocked { return toast("測試：不放行 push") }
            var e = PushEvent(at: Date(), repo: str("repo") ?? "", dir: dir, refs: [], commits: 0, verdict: .block, reasons: [])
            e.head = head
            PushGuard.allow(e)
        case "watch":
            let sid = str("sessionId")
            if !blocked { model.watch(sid) }
            // 點角色才帶 id：戰情中心自己持有的 session（kind == board）同時打開工作視窗（OfficeView.click）
            if str("id") != nil, let c = card(m), c.kind == "board" { openWork(c) }
        case "openGraph": openGraph(str("project") ?? "")
        case "b1Refresh": post(["type": "b1Posts", "posts": Self.b1Posts()])
        case "weatherSearch": OfficeWeather.shared.search(str("query") ?? "")
        case "setPref": setPref(str("key") ?? "", m["value"])
        case "wanderVisible":
            if !blocked { model.wanderVisible = (m["visible"] as? Bool ?? true) && !HeatGate.shared.paused }
        default: break
        }
    }

    private func jump(_ c: BoardCard) {
        if c.kind == "board" { openWork(c); return }
        if blocked { return toast("測試：不跳到視窗") }
        if !BoardActions.focus(pid: c.pid) {
            toast(c.kind == "bg" ? "這是背景 session，沒有視窗；用 claude attach 打開" : "找不到這個 session 的視窗")
        }
    }

    /// 工作視窗（11-08 H3）：卡片上是 Claude 那邊的 id（/clear 之後會換），工作視窗用戰情中心的把手
    private func openWork(_ c: BoardCard) {
        if blocked { return toast("測試：不開工作視窗（\(c.title)）") }
        WorkWindow.show(SessionHost.shared.handle(for: c.sessionId) ?? c.sessionId, cwd: c.cwd)
    }

    private func guardScan() {
        let msg: String
        if blocked && ProcessInfo.processInfo.environment["SHOWORK_WIFIWATCH_SCRIPT"] == nil { msg = "測試視窗不掃描真的網路" }
        else { msg = model.guardScan() ? "開始掃描 Wi-Fi（約數十秒）" : "已經在掃描了" }
        if blocked { print("office-web guardScan →", msg); fflush(stdout) }
        toast(msg)
    }

    private func openGraph(_ project: String) {
        if blocked { return toast("測試：開啟整棟大樓知識星雲") }
        GraphSource.shared.openBuilding(clicked: project) { [weak self] r in
            if let r {
                NSWorkspace.shared.open(r.url)
                self?.toast(r.count > 0 ? "開啟整棟大樓知識星雲（\(r.count) 個專案）" : "開啟整棟大樓知識星雲")
            } else if let (name, url) = GraphSource.shared.htmlFor(project: project) {
                NSWorkspace.shared.open(url)
                self?.toast("整棟版做不出來，先開 \(name) 知識圖譜")
            } else {
                self?.toast("知識圖譜產生失敗（找不到 graphify 或專案資料夾）")
            }
        }
    }

    /// 設定：跟 OfficeView 的 @AppStorage／OfficeWeather 同一份（UserDefaults ai.okle42.showork）
    private func setPref(_ key: String, _ value: Any?) {
        if blocked { print("office-web setPref", key, value ?? "nil"); fflush(stdout); return }
        let p = OfficePrefs()
        switch key {
        case "lighting": if let s = value as? String, let l = OfficeLighting(rawValue: s) { p.lighting = l }
        case "style": if let s = value as? String, OfficeStyle(rawValue: s) != nil { p.store.set(s, forKey: OfficePrefs.styleKey) }
        case "weather": if let b = value as? Bool { OfficeWeather.shared.enabled = b }
        case "guardPatrol": if let b = value as? Bool { p.guardPatrol = b }
        case "weatherPlaces":
            guard let xs = value as? [[String: Any]] else { return }
            let sites = xs.compactMap { o -> WeatherSite? in
                guard let t = o["title"] as? String, let la = (o["lat"] as? NSNumber)?.doubleValue, let lo = (o["lon"] as? NSNumber)?.doubleValue else { return nil }
                return WeatherSite(title: t, lat: la, lon: lo, detail: o["detail"] as? String)
            }
            if !sites.isEmpty { OfficeWeather.shared.sites = sites }
        default: break
        }
    }

    static func b1Posts() -> [[String: Any]] {
        B1Board.all().map { p in
            var o: [String: Any] = ["id": p.id, "at": p.at.timeIntervalSince1970, "name": p.name, "project": p.project, "text": p.text]
            if let r = p.re { o["re"] = r }
            return o
        }
    }

    // MARK: Swift → 網頁

    func toast(_ text: String, captainDone: Bool = false) {
        if blocked { print("office-web toast:", text); fflush(stdout) }
        if let t = onToast {
            t(text)
            if captainDone { post(["type": "captainBusy", "busy": false]) }      // 清掉網頁上的「隊長開啟中」
            return
        }
        var o: [String: Any] = ["type": "toast", "text": text]
        if captainDone { o["captainDone"] = true }
        post(o)
    }

    /// 小訊息（toast、heat、visible、b1Posts⋯）；頁面還沒好就丟掉
    func post(_ o: [String: Any]) {
        guard ready, let d = try? JSONSerialization.data(withJSONObject: o) else { return }
        web.evaluateJavaScript("window.swRecv(\(String(decoding: d, as: UTF8.self)))")
    }

    /// 視窗被蓋住／縮小（OfficeWebView 看 occlusionState）
    private func visibleChanged(_ v: Bool) {
        guard v != lastVisible else { return }
        lastVisible = v
        post(["type": "visible", "visible": v])
    }

    // MARK: 導覽：只准看自己的頁面

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        let s = navigationAction.request.url?.scheme
        decisionHandler(s == OfficeWebSchemeHandler.scheme || s == "about" ? .allow : .cancel)
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? { nil }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        ready = false
        webView.reload()          // 網頁程序掛掉：重載（ready 回來會重推整份）
    }
}

/// WKUserContentController 會強引用 handler；中間隔一層，畫面拆掉才放得掉
private final class OfficeWeakHandler: NSObject, WKScriptMessageHandler {
    weak var target: (any WKScriptMessageHandler)?
    init(_ t: any WKScriptMessageHandler) { target = t }
    func userContentController(_ ucc: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(ucc, didReceive: message)
    }
}

/// 拖檔：原生端先記下路徑（網頁的 File 沒有路徑），網頁接著送 dropFiles{key} 來拿；視窗可見度變化也從這裡報
final class OfficeWebView: WKWebView {
    var onVisible: ((Bool) -> Void)?
    private var dropped: [String] = []
    private var droppedAt = Date.distantPast
    private var obs: [NSObjectProtocol] = []

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        dropped = urls.map(\.path); droppedAt = Date()
        return super.performDragOperation(sender)
    }

    /// 最近一次拖進來的路徑（10 秒內有效，拿一次就清掉）
    func takeDropped() -> [String] {
        defer { dropped = [] }
        return Date().timeIntervalSince(droppedAt) < 10 ? dropped : []
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        obs.forEach { NotificationCenter.default.removeObserver($0) }
        obs = []
        guard let w = window else { onVisible?(false); return }
        let nc = NotificationCenter.default
        for n in [NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification] {
            obs.append(nc.addObserver(forName: n, object: w, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.report() } })
        }
        report()
    }

    private func report() {
        guard let w = window else { return }
        onVisible?(w.isVisible && !w.isMiniaturized && w.occlusionState.contains(.visible))
    }
}

/// showork://web/<路徑> ⇒ Web 資料夾裡的檔案（ES module 要正確的 MIME；不准跳出資料夾）
final class OfficeWebSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "showork"
    let root: URL
    init(root: URL) { self.root = root.standardizedFileURL }

    static let mime: [String: String] = [
        "html": "text/html", "htm": "text/html", "js": "text/javascript", "mjs": "text/javascript", "css": "text/css",
        "json": "application/json", "png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg", "gif": "image/gif",
        "webp": "image/webp", "svg": "image/svg+xml", "glb": "model/gltf-binary", "gltf": "model/gltf+json",
        "bin": "application/octet-stream", "wasm": "application/wasm", "woff": "font/woff", "woff2": "font/woff2",
        "ttf": "font/ttf", "otf": "font/otf", "mp3": "audio/mpeg", "wav": "audio/wav", "ogg": "audio/ogg", "txt": "text/plain",
        "ktx2": "image/ktx2", "hdr": "application/octet-stream",
    ]

    /// 路徑 → 檔案（nil＝不准或不存在）
    func file(for url: URL) -> URL? {
        let rel = url.path.removingPercentEncoding ?? url.path
        guard !rel.split(separator: "/").contains("..") else { return nil }
        let f = root.appendingPathComponent(String(rel.drop { $0 == "/" })).standardizedFileURL
        guard f.path.hasPrefix(root.path + "/") else { return nil }
        var dir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: f.path, isDirectory: &dir), !dir.boolValue else { return nil }
        return f
    }

    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        guard let url = task.request.url else { return }
        guard let f = file(for: url), let data = try? Data(contentsOf: f) else {
            let r = HTTPURLResponse(url: url, statusCode: 404, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "text/plain"])!
            task.didReceive(r); task.didReceive(Data("not found".utf8)); task.didFinish()
            return
        }
        var type = Self.mime[f.pathExtension.lowercased()] ?? "application/octet-stream"
        if type.hasPrefix("text/") || type.hasSuffix("json") || type.hasSuffix("javascript") { type += "; charset=utf-8" }
        let r = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                headerFields: ["Content-Type": type, "Content-Length": "\(data.count)", "Cache-Control": "no-cache"])!
        task.didReceive(r)
        task.didReceive(data)
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {}
}

/// SwiftUI 包裝：BoardView 裡取代 OfficeView（OfficeWebHost 自己訂閱 BoardModel，不必從外面傳資料）
struct OfficeWebScene: NSViewRepresentable {
    var onSendBack: (BoardCard) -> Void
    var onPark: (BoardCard) -> Void
    var onDispatch: (BoardCard) -> Void
    var onToast: ((String) -> Void)? = nil

    final class Coordinator { var host: OfficeWebHost? }
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        guard let h = OfficeWebHost() else {
            let t = NSTextField(labelWithString: "找不到 office.html（Web 資料夾）")
            t.alignment = .center
            return t
        }
        context.coordinator.host = h
        apply(h)
        return h.web
    }

    func updateNSView(_ v: NSView, context: Context) { if let h = context.coordinator.host { apply(h) } }

    static func dismantleNSView(_ v: NSView, coordinator: Coordinator) { coordinator.host?.tearDown(); coordinator.host = nil }

    private func apply(_ h: OfficeWebHost) {
        h.onSendBack = onSendBack; h.onPark = onPark; h.onDispatch = onDispatch; h.onToast = onToast
    }
}

/// 測試（--office-web-snap，main.swift）：螢幕外視窗載 office.html，ready 後等幾秒截圖、印幾個數字就結束
@MainActor
enum OfficeWebSnap {
    private static var host: OfficeWebHost?
    private static var window: NSWindow?
    private static var started: Date?
    private static let size = NSSize(width: 1600, height: 1000)

    static let probe = """
    JSON.stringify((() => { const d = window.__office?.S?.data; return {ready: !!window.__ready, hasData: !!d,
      cards: (d?.cards ?? (d?.islands ?? []).flatMap(i => i.people)).length, islands: (d?.islands ?? []).length,
      floors: (d?.tower?.floors ?? []).length, toast: window.__office?.S?.toast ?? null,
      empty: document.getElementById('empty')?.hidden === false ? document.getElementById('empty').textContent : null,
      canvas: !!document.querySelector('#stage canvas'), frames: window.__office?.view?.renderer?.info?.render?.frame ?? null,
      lost: window.__office?.view?.renderer?.getContext?.()?.isContextLost?.() ?? null, visibility: document.visibilityState,
      errors: window.__errs ?? []}; })())
    """

    static func run(out: String, demo: Bool) {
        NSApplication.shared.setActivationPolicy(.prohibited)
        BoardWindow.testMode = true
        OfficeWebHost.testMode = true
        let w = OffscreenWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        guard let h = OfficeWebHost(demo: demo, extraQuery: "test=1") else { print("找不到 office.html"); exit(2) }
        h.web.configuration.userContentController.addUserScript(WKUserScript(source: """
            window.__errs=[];addEventListener('error',e=>window.__errs.push(String(e.message)+' @'+(e.filename||'').split('/').pop()+':'+e.lineno));
            addEventListener('unhandledrejection',e=>window.__errs.push('reject '+String(e.reason)));
            """, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        h.web.reload()          // user script 要在載入前掛好
        host = h; window = w
        w.contentView = h.web
        w.setFrameOrigin(NSPoint(x: -6000, y: -6000))
        w.orderBack(nil)
        w.setFrameOrigin(NSPoint(x: -6000, y: -6000))
        let wait = Double(ProcessInfo.processInfo.environment["SHOWORK_SNAP_WAIT"] ?? "") ?? 6
        let t0 = Date()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in MainActor.assumeIsolated { tick(out, t0: t0, wait: wait) } }
    }

    private static var timer: Timer?
    private static func tick(_ out: String, t0: Date, wait: Double) {
        guard let h = host else { return }
        if Date().timeIntervalSince(t0) > 60 { print("office-web-snap: 60 秒內網頁沒好"); timer?.invalidate(); finish(out); return }
        if let s = started { if Date().timeIntervalSince(s) >= wait { timer?.invalidate(); finish(out) }; return }
        if !h.demo && !(BoardModel.shared.loaded && h.pushes > 0 && h.lastCards == BoardModel.shared.cards.count) { return }   // 真資料：等看板讀完第一輪、推過去
        h.web.evaluateJavaScript("!!window.__ready && !!window.__office?.S?.data") { r, _ in
            MainActor.assumeIsolated {
                guard (r as? Bool) == true, started == nil else { return }
                started = Date()
                // SHOWORK_SNAP_JS：網頁好了就在裡面跑（模擬按鈕：送 action，看原生端印出的 toast）
                if let js = ProcessInfo.processInfo.environment["SHOWORK_SNAP_JS"] { h.web.evaluateJavaScript(js) }
            }
        }
    }

    private static func finish(_ out: String) {
        guard let h = host else { exit(1) }
        h.web.evaluateJavaScript(probe) { r, _ in
            MainActor.assumeIsolated {
                print("office-web-snap: native ready=\(h.ready) pushes=\(h.pushes) cards(native)=\(h.lastCards) page=\(r as? String ?? "?")"); fflush(stdout)
                let js = "(() => { const c = document.querySelector('#stage canvas'); if (!c) return null; const r = c.getBoundingClientRect(); return JSON.stringify({x: r.x, y: r.y, w: r.width, h: r.height, url: c.toDataURL('image/png')}); })()"
                h.web.evaluateJavaScript(js) { cr, _ in
                    MainActor.assumeIsolated {
                        let canvas = cr as? String
                        h.web.takeSnapshot(with: nil) { img, _ in MainActor.assumeIsolated { compose(out, canvas: canvas, page: img) } }
                    }
                }
            }
        }
    }

    /// 底：canvas 的 toDataURL（WebGL；takeSnapshot 可能拍不到）；上：網頁截圖（DOM 疊層）
    private static func compose(_ out: String, canvas: String?, page: NSImage?) {
        guard let page else { print("截圖失敗"); exit(1) }
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height), bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor(white: 0.1, alpha: 1).setFill(); NSRect(origin: .zero, size: size).fill()
        if let s = canvas, let o = (try? JSONSerialization.jsonObject(with: Data(s.utf8))) as? [String: Any],
           let u = o["url"] as? String, let b64 = u.split(separator: ",").last, let pd = Data(base64Encoded: String(b64)), let ci = NSImage(data: pd) {
            let x = o["x"] as? Double ?? 0, y = o["y"] as? Double ?? 0, cw = o["w"] as? Double ?? 0, ch = o["h"] as? Double ?? 0
            ci.draw(in: NSRect(x: x, y: size.height - y - ch, width: cw, height: ch))
            try? pd.write(to: URL(fileURLWithPath: (out as NSString).deletingPathExtension + "-canvas.png"))
        } else { print("office-web-snap: 拿不到 canvas") }
        page.draw(in: NSRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()
        guard let png = rep.representation(using: .png, properties: [:]) else { print("截圖失敗"); exit(1) }
        try? png.write(to: URL(fileURLWithPath: out))
        print("office-web-snap: 存到", out); fflush(stdout)
        exit(0)
    }
}
