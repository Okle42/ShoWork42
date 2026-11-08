import AppKit
import WebKit
import ShoWorkCore

// 工作視窗（11-08 H3，docs/OWN-SESSIONS.md）：戰情中心自己持有的 session 的對話，在這裡交代事、看過程、回權限，不必切到終端機。
// 網頁 work.html 跟 Windows 共用（windows/ShoWork.Win/Board/Web）；訊息格式見那裡的 PROTOCOL.md「工作視窗」。
// 對話來源是 SessionHost 的事件 log（board/sessions/<sid>.jsonl）：打開時整份重播，之後照 offset 讀新增的行。
// 不掛 OwnedSession.onEvent：送話時 ensure 可能換成新的程序物件，讀 log 不管程序換幾次都接得上，也不會跟別人搶那個回呼。
// work.js 是一般 script（不是 ES module），file:// 載入就能跑，不用自訂 scheme。

@MainActor
final class WorkWindow: NSObject, NSWindowDelegate, WKScriptMessageHandler {
    private static var windows: [String: WorkWindow] = [:]
    /// 測試（--work-snap）：開在螢幕外、不搶焦點
    static var testMode = false

    /// 打開（已經開著就拿到前面）
    @discardableResult
    static func show(_ sid: String, cwd: String? = nil) -> WorkWindow? {
        if let w = windows[sid] { w.front(); return w }
        guard let dir = webDir else { BoardModel.shared.append(["ev": "work-window-missing", "id": sid]); return nil }
        let w = WorkWindow(sid: sid, cwd: cwd, webDir: dir)
        windows[sid] = w
        w.front()
        return w
    }

    private func front() {
        if Self.testMode { window.setFrameOrigin(NSPoint(x: -6000, y: -6000)); window.orderBack(nil); return }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// 測試用：在網頁裡跑一段 JS（模擬使用者按按鈕、打字送出）
    func runJS(_ js: String) { web.evaluateJavaScript(js) }

    /// 測試用：網頁目前的樣子（截圖）＋幾個數字（訊息數、狀態字）
    func snapshot(_ done: @escaping @MainActor (NSImage?, String) -> Void) {
        web.evaluateJavaScript("JSON.stringify({msgs: document.querySelectorAll('#flow > *').length, tools: document.querySelectorAll('.tool').length, state: document.querySelector('#state').textContent, project: document.querySelector('#project').textContent, ctx: document.querySelector('#ctx').textContent})") { r, _ in
            let info = r as? String ?? "?"
            self.web.takeSnapshot(with: nil) { img, _ in MainActor.assumeIsolated { done(img, info) } }
        }
    }

    /// 網頁資料夾：環境變數（開發用）→ app 裡的 Resources/Web → 原始碼旁邊（swift run）
    static var webDir: URL? {
        var cands: [URL] = []
        if let e = ProcessInfo.processInfo.environment["SHOWORK_WEB_DIR"] { cands.append(URL(fileURLWithPath: e)) }
        if let r = Bundle.main.resourceURL { cands.append(r.appendingPathComponent("Web")) }
        cands.append(URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("windows/ShoWork.Win/Board/Web"))
        return cands.first { FileManager.default.fileExists(atPath: $0.appendingPathComponent("work.html").path) }
    }

    let sid: String
    private var cwd: String?
    let window: NSWindow
    private let web: WorkWebView
    private var offset: UInt64 = 0
    private var partial = Data()
    private var timer: Timer?
    private var ticks = 0
    private var lastState = ""
    private var lastPermit: String? = "—"     // 還沒推過
    private var ready = false

    private var host: SessionHost { SessionHost.shared }

    private init(sid: String, cwd: String?, webDir: URL) {
        self.sid = sid
        self.cwd = cwd ?? SessionHost.shared.owners()[sid]?.cwd
        let cfg = WKWebViewConfiguration()
        web = WorkWebView(frame: .zero, configuration: cfg)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 760),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        super.init()
        cfg.userContentController.add(WeakHandler(self), name: "sw")
        web.setValue(false, forKey: "drawsBackground")
        web.onDropPaths = { [weak self] paths in self?.push(["type": "dropPaths", "paths": paths]) }
        window.title = "工作視窗・" + (self.cwd.map { ($0 as NSString).lastPathComponent } ?? sid)
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = NSColor(white: 0.196, alpha: 1)
        window.contentView = web
        window.minSize = NSSize(width: 560, height: 420)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.setFrameAutosaveName("ShoWorkWorkWindow")
        if window.frame.origin == .zero { window.center() }
        web.loadFileURL(webDir.appendingPathComponent("work.html"), allowingReadAccessTo: webDir)
    }

    func windowWillClose(_ notification: Notification) {
        timer?.invalidate(); timer = nil
        web.configuration.userContentController.removeScriptMessageHandler(forName: "sw")
        WorkWindow.windows[sid] = nil
    }

    // MARK: 網頁 → Swift

    func userContentController(_ ucc: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let m = message.body as? [String: Any], let type = m["type"] as? String else { return }
        switch type {
        case "ready": start()
        case "send": send(text: m["text"] as? String ?? "", images: m["images"] as? [[String: Any]] ?? [])
        case "interrupt": toast(OwnedActions.interrupt(sid))
        case "openInTerminal": toast(OwnedActions.openInTerminal(sid))
        case "close": toast(OwnedActions.close(sid))
        case "setModel": control("set_model", ["model": m["model"] as? String ?? ""], done: "已換模型")
        case "setPermissionMode": control("set_permission_mode", ["mode": m["mode"] as? String ?? "default"], done: "已換權限模式")
        case "permit": permit(m)
        default: break
        }
    }

    private func start() {
        ready = true
        var s: [String: Any] = ["type": "session", "sid": sid, "cwd": cwd ?? ""]
        if let r = host.owners()[sid] {
            if let n = r.name { s["name"] = n }
            if let mo = r.model { s["model"] = mo }
            if let pm = r.permissionMode { s["permissionMode"] = pm }
        }
        push(s)
        readLog(replay: true)
        tick()
        timer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.tick() } }
    }

    private func send(text: String, images: [[String: Any]]) {
        let content: Any
        if images.isEmpty { content = text } else {
            var blocks: [[String: Any]] = images.compactMap { im in
                guard let mt = im["mediaType"] as? String, let d = im["data"] as? String else { return nil }
                return ["type": "image", "source": ["type": "base64", "media_type": mt, "data": d]]
            }
            if !text.isEmpty { blocks.append(["type": "text", "text": text]) }
            content = blocks
        }
        if let err = OwnedActions.send(sid, content: content, cwd: cwd) { toast(err) }
        tick()
    }

    private func control(_ subtype: String, _ extra: [String: Any], done: String) {
        guard let s = host.session(sid), s.state != .exited else { toast("程序沒在跑；先送一句話接回來再換"); return }
        toast(s.control(subtype, extra) ? done : "沒送出去：程序已經結束")
    }

    private func permit(_ m: [String: Any]) {
        guard let id = m["permitId"] as? String, let req = Permit.pending()[sid], req.id == id else { toast("這個對話框已經關了"); return }
        let decision = PermitAnswer.Decision(rawValue: m["decision"] as? String ?? "") ?? .deny
        let answers = (m["answers"] as? [String: [String]])
        let a = PermitAnswer(decision, message: m["message"] as? String, answers: answers)
        guard Permit.answer(id, a) else { toast("已經在別處答過了"); return }
        Permit.logAnswer(req, a)
        BoardModel.shared.append(["ev": "permit", "id": sid, "tool": req.tool, "decision": decision.rawValue, "via": "work"])
        lastPermit = nil
        push(["type": "permit", "req": NSNull()])
    }

    // MARK: Swift → 網頁

    private func tick() {
        guard ready else { return }
        readLog(replay: false)
        let st = state()
        if st != lastState { lastState = st; push(["type": "state", "state": st]) }
        ticks += 1
        if ticks % 3 == 1 {                                   // 權限請求約每秒看一次（要掃資料夾）
            let p = Permit.pending()[sid]
            if p?.id != lastPermit { lastPermit = p?.id; push(["type": "permit", "req": p.map(permitJSON) ?? NSNull()]) }
        }
    }

    private func state() -> String {
        if let s = host.session(sid), s.state != .exited { return s.state.rawValue }
        return host.owners()[sid]?.owner == .terminal ? "terminal" : "exited"
    }

    private func permitJSON(_ p: PermitRequest) -> [String: Any] {
        var o: [String: Any] = ["id": p.id, "tool": p.tool, "summary": p.summary]
        if let d = p.detail { o["detail"] = d }
        if let a = p.alwaysLabel { o["alwaysLabel"] = a }
        if let plan = p.plan { o["plan"] = plan }
        if let qs = p.questions {
            o["questions"] = qs.map { q in
                ["question": q.question, "multiSelect": q.multiSelect,
                 "options": q.options.map { ["label": $0.label, "description": $0.description ?? ""] }] as [String: Any]
            }
        }
        return o
    }

    /// 讀 log 新增的完整行，一批推給網頁（行本身就是 JSON，直接拼，不重新編碼）
    private func readLog(replay: Bool) {
        let url = host.logFile(sid)
        guard let h = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        if size < offset { offset = 0; partial.removeAll() }   // 檔案被換掉了
        guard size > offset else { return }
        try? h.seek(toOffset: offset)
        let d = h.readDataToEndOfFile()
        offset += UInt64(d.count)
        partial.append(d)
        guard let last = partial.lastIndex(of: 0x0A) else { return }
        let chunk = partial[partial.startIndex...last]
        partial = Data(partial[partial.index(after: last)...])
        let lines = chunk.split(separator: 0x0A).filter { (try? JSONSerialization.jsonObject(with: Data($0))) is [String: Any] }
        guard !lines.isEmpty else { return }
        var js = Data(#"{"type":"lines","replay":\#(replay),"lines":["#.utf8)
        for (i, l) in lines.enumerated() { if i > 0 { js.append(0x2C) }; js.append(contentsOf: l) }
        js.append(contentsOf: Data("]}".utf8))
        eval(js)
    }

    private func toast(_ text: String) { push(["type": "toast", "text": text]) }

    private func push(_ o: [String: Any]) {
        guard let d = try? JSONSerialization.data(withJSONObject: o) else { return }
        eval(d)
    }

    private func eval(_ json: Data) {
        web.evaluateJavaScript("window.swRecv(\(String(decoding: json, as: UTF8.self)))")
    }
}

/// WKUserContentController 會強引用 handler；中間隔一層，視窗關掉才放得掉
private final class WeakHandler: NSObject, WKScriptMessageHandler {
    weak var target: (any WKScriptMessageHandler)?
    init(_ t: any WKScriptMessageHandler) { target = t }
    func userContentController(_ ucc: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(ucc, didReceive: message)
    }
}

/// 網頁裡拖檔拿不到完整路徑：圖片以外的檔在這裡接，路徑推給網頁插進輸入框；圖片照常交給網頁（讀成附件）
final class WorkWebView: WKWebView {
    var onDropPaths: (([String]) -> Void)?
    private static let imageExt: Set<String> = ["png", "jpg", "jpeg", "gif", "webp"]

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        let files = urls.filter { !Self.imageExt.contains($0.pathExtension.lowercased()) }
        if !files.isEmpty { onDropPaths?(files.map(\.path)) }
        if files.count == urls.count && !urls.isEmpty { return true }
        return super.performDragOperation(sender)
    }
}
