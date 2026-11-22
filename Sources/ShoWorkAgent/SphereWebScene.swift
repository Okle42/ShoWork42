import AppKit
import AVFoundation
import Combine
import SwiftUI
import WebKit
import ShoWorkCore

// 戰情中心第四個分頁「球體」（11-21 Kang：參考 IG 的 K.A.R.A 2.0 球體助理）。
// WKWebView 載 Web 資料夾的 sphere.html（three.js 用 vendor 那份，離線可用）；資料單向推：
//   原生端 → 網頁：window.karaUpdate({five_hour, seven_day, ctx, sessions, team, runs, heat, …})、window.karaVoice("start"|"word"|"end")、
//                 window.karaHeard(text, final)（按住球講話的辨識結果）、window.karaToast(一句話)
//   網頁 → 原生端：webkit.messageHandlers.sphere.postMessage({action: …})
//     ready／focus／speak／stopSpeaking（v2）
//     answer {sessionId, text}、permit {sessionId, permitId, decision, answers}（v3 #1：球旁邊的選項按鈕）
//     listen {on}、captain {text}（v3 #2：按住球講話 → 交給隊長）
//     mini {on}、openBoard（v3 #7：桌面常駐小球）
//     deskSize {id?}、deskChrome {noDrag}（11-22 球體桌面版：換尺寸、告訴原生端標題列哪些地方是按鈕不能拖）
// 球體的狀態與播報由網頁自己判（狀態一變就說一句）。
// 語音（v2，11-21）：macOS 內建台灣中文語音（AVSpeechSynthesizer），網頁上的喇叭按鈕開關，預設關。
// ⚠ 不准用使用者本人的聲音（11-21 使用者下令）。按住講話只做本機即時辨識成文字，不存音檔。

@MainActor
final class SphereWebHost: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    let web: WKWebView
    let desk: Bool          // 11-22：球體桌面版（SphereMini 的浮動面板，?desk=1）
    private var loaded = false
    private var sent: String?
    private var pending = false
    private var subs: [AnyCancellable] = []
    private var ticker: Timer?
    private var model: BoardModel { BoardModel.shared }
    private let audio = SphereAudio()      // v5：自己播＋FFT，聲波和逐詞字幕都靠它
    private var listener: SphereListener?
    private let edge = SphereEdgeVoice()

    init?(dir: URL? = WorkWindow.webDir, desk: Bool = false) {
        guard let dir, FileManager.default.fileExists(atPath: dir.appendingPathComponent("sphere.html").path) else { return nil }
        self.desk = desk
        let cfg = WKWebViewConfiguration()
        cfg.setURLSchemeHandler(OfficeWebSchemeHandler(root: dir), forURLScheme: OfficeWebSchemeHandler.scheme)
        let wv = SphereWebView(frame: .zero, configuration: cfg)
        wv.desk = desk
        web = wv
        super.init()
        cfg.userContentController.add(SphereWeakHandler(self), name: "sphere")
        audio.onEvent = { [weak self] ev in self?.voice(ev) }
        audio.onWord = { [weak self] loc, len in self?.web.evaluateJavaScript("window.karaVoice && window.karaVoice('word', \(loc), \(len))") }
        audio.onLevels = { [weak self] bands, rms, pos, dur in self?.levels(bands, rms, pos: pos, dur: dur, mic: false) }
        web.setValue(false, forKey: "drawsBackground")
        // 測試視窗在螢幕外＝被當成看不見、rAF 停掉、WebGL 不畫（同 OfficeWebHost）：測試時關掉遮擋偵測
        let occ = NSSelectorFromString("_setWindowOcclusionDetectionEnabled:")
        if BoardWindow.testMode, web.responds(to: occ), let m = class_getInstanceMethod(WKWebView.self, occ) {
            typealias SetBool = @convention(c) (AnyObject, Selector, Bool) -> Void
            unsafeBitCast(method_getImplementation(m), to: SetBool.self)(web, occ, false)
        }
        web.navigationDelegate = self
        web.load(URLRequest(url: URL(string: "\(OfficeWebSchemeHandler.scheme)://web/sphere.html\(desk ? "?desk=1" : "")")!))
        model.start()
        model.objectWillChange.sink { [weak self] _ in self?.schedule() }.store(in: &subs)
        // 溫度、額度重置倒數不會觸發 objectWillChange：每 10 秒補一次（內容一樣就不推）
        ticker = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.push(); if self?.desk == false { GhosttyTheme.recheck() } } }
        NotificationCenter.default.publisher(for: HeatGate.changed).sink { [weak self] _ in self?.schedule() }.store(in: &subs)
        // 桌面版開關／尺寸變了：兩顆球都要知道（分頁那顆要不要出聲、桌面版的「尺寸」按鈕字）
        NotificationCenter.default.publisher(for: SphereMini.changed).sink { [weak self] _ in self?.pushPrefs() }.store(in: &subs)
    }

    func tearDown() {
        subs.removeAll()
        ticker?.invalidate(); ticker = nil
        listener?.stop(); listener = nil
        audio.stop(); edge.stop()
        web.configuration.userContentController.removeScriptMessageHandler(forName: "sphere")
    }

    private var blocked: Bool { BoardWindow.testMode }

    // MARK: 網頁 → 原生端

    func userContentController(_ ucc: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let m = message.body as? [String: Any], let a = m["action"] as? String else { return }
        let str = { (k: String) in m[k] as? String }
        switch a {
        case "ready": loaded = true; sent = nil; push(); pushPrefs()
        case "focus":
            guard let c = card(str("sessionId")) else { return say("找不到這個 session 了。") }
            jump(c)
        case "speak": speak(str("text") ?? "")
        case "stopSpeaking": audio.stop(); edge.stop()
        case "setVoice":       // 11-21 使用者：換聲音（選單選了就存起來、馬上試聽一句）
            guard let id = str("id"), SphereVoices.all().contains(where: { $0.id == id }) else { return }
            SphereVoices.selected = id
            pushPrefs()
            speak(str("sample") ?? "你好，我是球體助理，之後就用這個聲音播報。")
        case "answer":
            guard let c = card(str("sessionId")) else { return say("這個 session 已經不在了。") }
            let text = (str("text") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return }
            if blocked { return say("測試：不送出「\(text)」。") }
            say(BoardActions.answer(c, text: text) + "。")
        case "permit":
            guard let c = card(str("sessionId")) else { return say("這個 session 已經不在了。") }
            let d = PermitAnswer.Decision(rawValue: str("decision") ?? "") ?? .deny
            if let pid = str("permitId"), let cur = c.permit?.id, pid != cur { return say("這個對話框已經關了。") }
            if blocked { return say("測試：不回答權限（\(d.rawValue)）。") }
            say(BoardActions.permit(c, PermitAnswer(d, message: str("message"), answers: m["answers"] as? [String: [String]])) + "。")
        case "listen": (m["on"] as? Bool ?? false) ? startListening() : listener?.finish()
        case "captain":
            let text = (str("text") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return }
            if blocked { return say("測試：不交給隊長「\(text)」。") }
            DispatchQueue.global().async {
                let msg = BoardActions.askCaptain(text)
                DispatchQueue.main.async { MainActor.assumeIsolated { self.say(msg + "。") } }
            }
        case "mini":
            let on = m["on"] as? Bool ?? !SphereMini.shared.enabled
            // 桌面版自己按「收起」：不能在它自己的訊息回呼裡拆掉自己 ⇒ 下一輪再關
            DispatchQueue.main.async { MainActor.assumeIsolated { SphereMini.shared.enabled = on } }
        case "deskSize":
            if let id = str("id") { SphereMini.shared.setPreset(id) } else { SphereMini.shared.cyclePreset() }
        case "deskChrome":
            (web as? SphereWebView)?.noDrag = (m["noDrag"] as? [[Double]] ?? []).filter { $0.count == 4 }.map { NSRect(x: $0[0], y: $0[1], width: $0[2], height: $0[3]) }
        case "openBoard": openBoard()
        case "theme":           // 11-22 Keng：終端機（Ghostty）配色跟球體連動
            GhosttyTheme.apply(mode: str("mode") ?? "auto", now: str("name") ?? "dark", blocked: blocked)
        case "sessionInfo":     // v4 C：點衛星展開小卡
            guard let c = card(str("sessionId")) else { return say("這個 session 已經不在了。") }
            js("window.karaSessionInfo", Self.info(c))
        case "timeline":        // v4 E：今日時間軸
            js("window.karaTimeline", SphereWatch.todayTimeline())
        case "audit":           // 11-22 Keng：自檢原子環——開工（早報）／收工各跑一次，自檢卡也能手動重跑／送出
            let send = m["send"] as? Bool ?? false
            if send && blocked { return say("測試模式不送出。") }
            if !SphereAudit.run(send: send, done: { [weak self] ok in
                self?.sent = nil; self?.push()
                if send { self?.say(ok ? "自檢已送到 Discord #自檢回報。" : "自檢送出失敗（看 ~/.claude/flow-audit/sphere/last.log）。") }
            }) { say("自檢正在跑，等它跑完。") }
            sent = nil; push()
        case "auditFix":        // 11-22 Keng 選「加，直接處理」：關掉停放空殼、停掉 Claude 預備程序（都不會丟對話），做完重跑自檢
            if blocked { return say("測試模式不動手。") }
            say("處理中⋯")
            DispatchQueue.global(qos: .utility).async {
                let r = SphereAudit.fix()
                Task { @MainActor [weak self] in
                    self?.say(r)
                    SphereAudit.run(send: false) { _ in self?.sent = nil; self?.push() }
                    self?.sent = nil; self?.push()
                }
            }
        default: break
        }
    }

    /// 打開戰情中心、切到球體分頁（小球點一下）
    func openBoard() {
        UserDefaults(suiteName: "ai.okle42.showork")?.set("sphere", forKey: "board.mode")
        if !blocked { NSApp.activate(ignoringOtherApps: true) }
        BoardWindow.shared.show()
    }

    /// 小球彈一下（SphereWatch 發現新的「需要你」）
    func bounce() { web.evaluateJavaScript("window.karaBounce && window.karaBounce()") }

    static func info(_ c: BoardCard, now: Date = Date()) -> [String: Any] {
        var o: [String: Any] = ["sessionId": c.sessionId, "name": c.display, "address": c.name ?? "", "project": c.project,
                                "status": needsYou(c) ? "需要你" : c.column.title, "reason": c.reason]
        if let d = c.report?.doing, c.label != nil { o["doing"] = d }      // 沒職稱／專案時名字就是任務，不重複
        if let s = c.report?.summary { o["summary"] = String(s.prefix(240)) }
        if let p = c.report?.progress { o["progress"] = p }
        if let x = c.ctx { o["ctx"] = x.percent.rounded() }
        if let t = c.lastActivity { o["ago"] = max(0, Int(now.timeIntervalSince(t) / 60)) }
        if let d = c.detail { o["detail"] = String(d.trimmingCharacters(in: .whitespacesAndNewlines).prefix(240)) }
        if !c.subagents.isEmpty { o["subagents"] = c.subagents.count }
        if let k = c.kind { o["kind"] = k }
        return o
    }

    private func card(_ sid: String?) -> BoardCard? {
        guard let sid else { return nil }
        return model.cards.first(where: { $0.sessionId == sid && !$0.id.contains("#") }) ?? model.cards.first(where: { $0.sessionId == sid })
    }

    /// 跳到那個 session：戰情中心自己開的（kind board）開工作視窗，其他的把終端機視窗叫到前面
    private func jump(_ c: BoardCard) {
        if blocked { return say("測試：不跳到 \(c.display)。") }
        if c.kind == "board" {
            WorkWindow.show(SessionHost.shared.handle(for: c.sessionId) ?? c.sessionId, cwd: c.cwd)
        } else if !BoardActions.focus(pid: c.pid) {
            say(c.kind == "bg" ? "這是背景 session，沒有視窗。" : "找不到這個 session 的視窗。")
        }
    }

    /// 結果回網頁當一句播報
    private func say(_ s: String) { js("window.karaToast", s) }

    private func js(_ fn: String, _ args: Any...) {
        guard let d = try? JSONSerialization.data(withJSONObject: args) else { return }
        web.evaluateJavaScript("\(fn) && \(fn)(...\(String(decoding: d, as: UTF8.self)))")
    }

    // MARK: 按住球講話（v3 #2）：本機即時辨識成文字，網頁顯示、放開後交給隊長

    private func startListening() {
        listener?.stop()
        if blocked {
            // 測試不碰麥克風：假裝聽到一句
            let words = ["幫我", "幫我看一下", "幫我看一下 Alex", "幫我看一下 Alex 的進度"]
            for (i, w) in words.enumerated() {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4 * Double(i + 1)) { [weak self] in self?.js("window.karaHeard", w, i == words.count - 1) }
            }
            return
        }
        audio.stop(); edge.stop()
        let l = SphereListener { [weak self] text, final, err in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if let err { self.js("window.karaHeard", "", true); self.say(err); return }
                    self.js("window.karaHeard", text, final)
                }
            }
        }
        l.onLevel = { [weak self] bands, rms in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.levels(bands, rms, pos: 0, dur: nil, mic: true) } }
        }
        listener = l
        l.start()
    }

    // MARK: 語音

    private func speak(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return voice("end") }
        // 測試不出聲：照字數估時間，假裝唸完
        if blocked {
            voice("start")
            DispatchQueue.main.asyncAfter(deadline: .now() + min(8, 0.18 * Double(t.count))) { [weak self] in self?.voice("end") }
            return
        }
        audio.stop(); edge.stop()
        let id = SphereVoices.selected
        if id.hasPrefix("edge:") {
            // 微軟神經語音：edge-tts 合成 mp3（要網路；文字會送到微軟），播放時用音量驅動球跳動
            edge.speak(String(t.prefix(300)), voice: String(id.dropFirst(5))) { [weak self] url in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        if !self.audio.play(file: url) { self.voice("end"); self.say("微軟語音的音檔打不開，先改用系統語音。") }
                    }
                }
            } failed: { [weak self] in
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.voice("end"); self?.say("微軟語音連不上，先改用系統語音。") } }
            }
            return
        }
        let u = AVSpeechUtterance(string: String(t.prefix(300)))
        u.voice = AVSpeechSynthesisVoice(identifier: String(id.dropFirst(6))) ?? AVSpeechSynthesisVoice(language: "zh-TW")
        u.rate = AVSpeechUtteranceDefaultSpeechRate * 1.05
        audio.speak(u)
    }

    private func voice(_ ev: String) { web.evaluateJavaScript("window.karaVoice && window.karaVoice('\(ev)')") }

    /// v5 聲波：頻譜 32 段＋音量（＋播放進度）推給網頁；mic＝按住講話時的麥克風
    private func levels(_ bands: [Float], _ rms: Float, pos: Double, dur: Double?, mic: Bool) {
        let b = bands.map { String(format: "%.2f", $0) }.joined(separator: ",")
        let d = dur.map { String(format: "%.2f", $0) } ?? "null"
        web.evaluateJavaScript("window.karaLevels && window.karaLevels({b:[\(b)],r:\(String(format: "%.3f", rms)),p:\(String(format: "%.2f", pos)),d:\(d),mic:\(mic)})")
    }

    func webView(_ w: WKWebView, didFinish n: WKNavigation!) {
        loaded = true; sent = nil; push(); pushPrefs()
        // 測試：SHOWORK_TEST_SPHERE_SHOT=<png> 12 秒後（等卡片讀完）用 WebKit 自己截（BoardWindow.snapshot 的 cacheDisplay 拍不到 WebGL 的顏色）
        let env = ProcessInfo.processInfo.environment
        if BoardWindow.testMode, let out = env[desk ? "SHOWORK_TEST_SPHERE_MINI_SHOT" : "SHOWORK_TEST_SPHERE_SHOT"] {
            // SHOWORK_TEST_SPHERE_JS：截圖前先跑一段網頁程式（例如假一筆「需要你」看選項按鈕）
            if let code = env[desk ? "SHOWORK_TEST_SPHERE_DESK_JS" : "SHOWORK_TEST_SPHERE_JS"] {
                DispatchQueue.main.asyncAfter(deadline: .now() + 9) { [weak self] in self?.web.evaluateJavaScript(code) }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 12) { [weak self] in
                self?.web.takeSnapshot(with: nil) { img, _ in
                    guard let img, let t = img.tiffRepresentation, let r = NSBitmapImageRep(data: t),
                          let png = r.representation(using: .png, properties: [:]) else { print("sphere shot failed"); fflush(stdout); return }
                    try? png.write(to: URL(fileURLWithPath: out))
                    print("sphere shot saved \(out)", self?.web.title ?? ""); fflush(stdout)
                }
            }
        }
    }

    /// 0.3 秒內的變動併成一次（objectWillChange 在改之前發）
    private func schedule() {
        guard !pending else { return }
        pending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            MainActor.assumeIsolated { self?.pending = false; self?.push() }
        }
    }

    private func pushPrefs() {
        let size = SphereMini.shared.currentPreset.flatMap { id in SphereMini.presets.first { $0.id == id }?.name } ?? "自訂"
        js("window.karaPrefs", ["mini": SphereMini.shared.enabled, "deskSize": size, "voice": SphereVoices.selected,
                                "voices": SphereVoices.all().map { ["id": $0.id, "name": $0.name, "group": $0.group] }])
    }

    private func push() {
        guard loaded else { return }
        let heat = CityParse.cool42(FileManager.default.contents(atPath: HeatGate.cool42Path), now: Date())
        var o = Self.payload(model.cards, model.rateLimits, runs: model.runs, heat: heat)
        o["paused"] = HeatGate.shared.paused
        o["disks"] = SphereDisks.read()          // 11-22 Keng：球右半邊的硬碟空間刻度環
        if let a = SphereAudit.latest() { o["audit"] = a }       // 11-22 Keng：自檢原子環（流量架構自檢的優化建議，不是用量）
        o["auditBusy"] = SphereAudit.busy
        // v4 A：隊長最後一句（網頁判斷是不是回覆剛交辦的事）
        if let l = model.captainThread.last(where: { $0.role == .captain }) {
            o["captain"] = ["id": l.id, "text": String(l.text.prefix(400)), "at": l.at.map { ISO8601DateFormatter().string(from: $0) } ?? ""]
        }
        guard let d = try? JSONSerialization.data(withJSONObject: o, options: .sortedKeys) else { return }
        let s = String(decoding: d, as: UTF8.self)
        guard s != sent else { return }
        sent = s
        if ProcessInfo.processInfo.environment["SHOWORK_TEST_SPHERE_LOG"] != nil { print("sphere push", s.prefix(160)); fflush(stdout) }
        web.evaluateJavaScript("window.karaUpdate && window.karaUpdate(\(s))")
    }

    /// 網頁要的資料（純函式，方便測）
    static func payload(_ cards: [BoardCard], _ limits: RateLimits?, runs: [RunProgress] = [], heat: CityPower? = nil, now: Date = Date()) -> [String: Any] {
        let people = cards.filter { !$0.id.contains("#") }
        let l = limits?.current(now: now)
        var o: [String: Any] = ["sessions": people.count]
        o["five_hour"] = l?.fiveHour.map { $0.used.rounded() } ?? NSNull()
        o["seven_day"] = l?.sevenDay.map { $0.used.rounded() } ?? NSNull()
        // 重置倒數（分鐘；額度預警、早報用）
        func mins(_ d: Date?) -> Any { d.map { max(0, Int(($0.timeIntervalSince(now) / 60).rounded())) } ?? NSNull() }
        o["five_reset"] = mins(l?.fiveHour?.resetsAt)
        o["seven_reset"] = mins(l?.sevenDay?.resetsAt)
        // 記憶量：最近有動靜的那個 session
        let recent = people.filter { $0.ctx != nil }.max { ($0.lastActivity ?? .distantPast) < ($1.lastActivity ?? .distantPast) }
        o["ctx"] = recent?.ctx.map { $0.percent.rounded() } ?? NSNull()
        // 今天做完（待審＋完成、最後動靜在今天）的件數：收工總結用
        o["doneToday"] = people.filter { ($0.column == .review || $0.column == .done) && $0.lastActivity.map { Calendar.current.isDate($0, inSameDayAs: now) } == true }.count
        // 需要你的排最前，再來進行中
        func rank(_ c: BoardCard) -> Int { needsYou(c) ? 0 : c.column == .active ? 1 : 2 }
        o["team"] = people.sorted { rank($0) < rank($1) }.map { c -> [String: Any] in
            var t: [String: Any] = ["name": c.display, "status": needsYou(c) ? "需要你" : c.column.title, "sessionId": c.sessionId]
            if let p = c.report?.progress { t["progress"] = p }
            if let d = c.report?.doing, c.label != nil { t["doing"] = d }   // 沒職稱／專案時名字就是任務，不重複
            if let a = c.name { t["address"] = a }                            // 英文名：只給語音「Hana 在幹嘛」這種問法對得上
            if let s = c.report?.summary { t["summary"] = s }
            if let x = c.ctx { t["ctx"] = x.percent.rounded() }          // v5：戰情卡每列的記憶量
            if let t0 = c.lastActivity { t["ago"] = max(0, Int(now.timeIntervalSince(t0) / 60)) }
            if let a = c.asks.first {
                t["ask"] = a.ask
                if let opts = a.options, !opts.isEmpty { t["options"] = opts }
            } else if let p = c.permit {
                t["ask"] = p.isAsk ? (p.questions?.first?.question ?? "有選擇題要你回答")
                    : p.isPlan ? "計畫要你核准" : "要不要讓它執行 \(p.tool)：\(p.summary)"
                var pm: [String: Any] = ["id": p.id, "kind": p.isAsk ? "ask" : p.isPlan ? "plan" : "tool", "tool": p.tool, "summary": String(p.summary.prefix(200))]
                if let d = p.detail { pm["detail"] = String(d.prefix(200)) }
                if let qs = p.questions {
                    pm["questions"] = qs.map { ["question": $0.question, "multi": $0.multiSelect, "options": $0.options.map(\.label)] as [String: Any] }
                }
                t["permit"] = pm
            }
            return t
        }
        // 外環（v3 #6）：背景長工作進度、cool42 溫度
        o["runs"] = runs.filter { $0.fresh(now) }.prefix(3).map { r -> [String: Any] in
            var x: [String: Any] = ["label": r.label, "fraction": (r.fraction * 100).rounded() / 100]
            if let n = r.name { x["name"] = n }
            if let e = r.eta { x["eta"] = e }
            return x
        }
        if let h = heat, h.known, let t = h.temp {
            o["heat"] = ["temp": t.rounded(), "level": h.level ?? "ok"] as [String: Any]
        } else { o["heat"] = NSNull() }
        return o
    }

    static func needsYou(_ c: BoardCard) -> Bool { !c.asks.isEmpty || c.permit != nil }
}

/// 11-22 Keng：Ghostty 終端機跟球體的配色連動。只改設定檔裡 `theme =` 那一行（色票在 ~/.config/ghostty/themes/Okle42-Dark／Light），
/// 改了才叫 Ghostty 重新載入設定（輔助使用點選單，不切前景）。自動＝跟系統外觀（Ghostty 自己切）；深／淺＝固定；日出日落＝照球體當下算的深淺
@MainActor
enum GhosttyTheme {
    static let config = NSHomeDirectory() + "/Library/Application Support/com.mitchellh.ghostty/config.ghostty"
    private static var last: String?
    /// 第一次看到 Claude Code 主題是淺色／auto 的時間（之前開的 session 都是深色介面）
    private static func sinceAuto(_ on: Bool) -> Double {
        let d = UserDefaults(suiteName: "ai.okle42.showork"), k = "ghostty.lightSince"
        if !on { d?.removeObject(forKey: k); return .infinity }
        if let v = d?.object(forKey: k) as? Double { return v }
        let v = Date().timeIntervalSince1970; d?.set(v, forKey: k); return v
    }
    /// 每分鐘重看一次（舊 session 關光了就自動換成跟球體）
    static func recheck() { if let m = lastMode { apply(mode: m.0, now: m.1, blocked: false, force: true) } }
    private static var lastMode: (String, String)?
    static func apply(mode: String, now: String, blocked: Bool, force: Bool = false) {
        lastMode = (mode, now)
        // 11-22 Keng 截圖：終端機切淺色後 Claude Code 的介面（框、表格、灰字）還是深色版 ⇒ 淺底上看不清楚。
        // 所以只有 Claude Code 自己也設成淺色主題（~/.claude.json theme 以 light 開頭）時才讓終端機跟著變淺；否則一律深色
        // 主題設定以 ~/.claude/settings.json 為準（11-22 實查：那裡寫著 "dark"，~/.claude.json 的不算數）
        let ccLight = ((try? JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: NSHomeDirectory() + "/.claude/settings.json")))) as? [String: Any])?["theme"]
            .flatMap { $0 as? String }.map { $0.hasPrefix("light") || $0 == "auto" } == true      // auto＝Claude Code 跟著終端機深淺
        // 已經開著的 Claude Code 是用舊主題（深色）畫的，要重開才會吃到 auto ⇒ 還有「主題改成 auto 之前開的」session 活著就先維持深色
        let since = sinceAuto(ccLight)
        let oldAlive = NicknameStore.liveSessions().contains { ($0.startedAt ?? 0) / 1000 < since && $0.kind != "bg" }
        let line = !ccLight || oldAlive ? "theme = Okle42-Dark"
            : mode == "auto" ? "theme = light:Okle42-Light,dark:Okle42-Dark" : "theme = Okle42-\(now == "light" ? "Light" : "Dark")"
        guard line != last || force, !blocked else { return }
        if line == last { return }
        last = line
        guard FileManager.default.fileExists(atPath: NSHomeDirectory() + "/.config/ghostty/themes/Okle42-Dark"),
              let text = try? String(contentsOfFile: config, encoding: .utf8), text.contains("theme =") else { return }   // 沒裝 Okle42 主題就不動
        let lines = text.components(separatedBy: "\n").map { $0.hasPrefix("theme =") ? line : $0 }
        let out = lines.joined(separator: "\n")
        guard out != text else { return }
        try? out.write(toFile: config, atomically: true, encoding: .utf8)
        DispatchQueue.global().async {
            let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            p.arguments = ["-e", "tell application \"System Events\" to if exists process \"Ghostty\" then tell process \"Ghostty\" to click menu item \"Reload Configuration\" of menu 1 of menu bar item 2 of menu bar 1"]
            p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
            try? p.run(); p.waitUntilExit()
        }
    }
}

/// 11-22 Keng：自檢原子環的資料＝scripts/flow_audit.py（流量架構自檢）的最新報告。
/// 跑：python3 flow_audit.py --names --out ~/.claude/flow-audit/sphere（本機那份保留專案名，只給自己看；--send 送出的一律去隱私）。
/// 腳本找法：App 包 Resources/flow_audit.py（安裝時複製）→ 原始碼旁的 scripts/。讀檔有快取（看修改時間）。
@MainActor
enum SphereAudit {
    nonisolated static let dir = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude/flow-audit/sphere")
    private(set) static var busy = false
    private static var cache: (path: String, mtime: Date, value: [String: Any])?

    nonisolated static var script: URL? {
        var c: [URL] = []
        if let r = Bundle.main.resourceURL { c.append(r.appendingPathComponent("flow_audit.py")) }
        c.append(URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("scripts/flow_audit.py"))
        return c.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    static func latest() -> [String: Any]? {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { return nil }
        guard let newest = names.filter({ $0.hasPrefix("flow-audit-") && $0.hasSuffix(".json") }).sorted().last else { return nil }
        let path = dir.appendingPathComponent(newest).path
        let mtime = (try? fm.attributesOfItem(atPath: path)[.modificationDate] as? Date) ?? Date.distantPast
        if let c = cache, c.path == path, c.mtime == mtime { return c.value }
        guard let d = fm.contents(atPath: path), let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return nil }
        let cl = j["claude"] as? [String: Any] ?? [:]
        // 只送球體用得到的（不送 by_project 明細）
        let v: [String: Any] = ["at": j["at"] ?? "", "today": cl["today"] ?? [:], "standing": cl["standing"] ?? [:],
                                "sessions": cl["sessions"] ?? [], "net": (j["network"] as? [String: Any])?["top"] ?? [], "advice": j["advice"] ?? []]
        cache = (path, mtime, v)
        return v
    }

    /// 「處理」：重新讀 ~/.claude/sessions（不靠舊報告），只動兩種保證不丟對話的：
    ///   停放空殼＝終端機把對話停放到背景後留下的殼（parkedJobId 指向活著的背景 job）⇒ 對殼的程序送 SIGTERM（對話在背景繼續）
    ///   預備程序＝Claude 背景常駐程式先開好的空 session（bg、沒名字、沒講過話）⇒ `claude stop`（跟 BgJanitor 同一招）
    /// 大記憶量閒置、開場太重、常駐設定這些要人判斷的，不動。記錄在 ~/.claude/flow-audit/sphere/fix.log
    nonisolated static func fix() -> String {
        let fm = FileManager.default, dir = BoardPaths.claude + "/sessions"
        let recs = ((try? fm.contentsOfDirectory(atPath: dir)) ?? []).filter { $0.hasSuffix(".json") }.compactMap { f -> SessionRecord? in
            guard let d = fm.contents(atPath: dir + "/" + f), let r = SessionRecord.decode(d), kill(r.pid, 0) == 0 else { return nil }
            return r
        }
        let jobs = Set(recs.compactMap(\.jobId)), me = getpid()
        var lines: [String] = [], shells = 0, spares = 0
        for r in recs where r.pid != me {
            if let pj = r.parkedJobId, jobs.contains(pj) {
                let ok = kill(r.pid, SIGTERM) == 0
                if ok { shells += 1 }
                lines.append("\(ok ? "關空殼" : "關空殼失敗") \(r.name ?? String(r.sessionId.prefix(8)))（pid \(r.pid)，對話在背景 \(pj)）")
            } else if r.kind == "bg", r.entrypoint != "sdk-cli", r.name == nil || r.name == String(r.sessionId.prefix(8)), !BgJanitorRunner.hasWork(r) {
                let id = r.jobId ?? String(r.sessionId.prefix(8))
                let (ok, out) = BgJanitorRunner.claudeStop(id)
                if ok { spares += 1 }
                lines.append("\(ok ? "停預備程序" : "停預備程序失敗") \(id)\(ok ? "" : "｜\(out)")")
            }
        }
        try? fm.createDirectory(at: dir_, withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter().string(from: Date())
        let text = (lines.isEmpty ? ["\(stamp) 沒有可以自動處理的"] : lines.map { "\(stamp) \($0)" }).joined(separator: "\n") + "\n"
        let log = dir_.appendingPathComponent("fix.log")
        if let h = try? FileHandle(forWritingTo: log) { h.seekToEndOfFile(); h.write(Data(text.utf8)); try? h.close() }
        else { try? Data(text.utf8).write(to: log) }
        if shells + spares == 0 { return lines.isEmpty ? "沒有可以自動處理的（閒置、常駐設定這些要你自己決定）。" : "處理失敗，看 ~/.claude/flow-audit/sphere/fix.log。" }
        return "已處理：關掉 \(shells) 個停放空殼、停掉 \(spares) 個預備程序（對話都還在）。正在重跑自檢。"
    }
    nonisolated private static var dir_: URL { dir }

    /// 背景跑一次；已經在跑就回 false。done 在主執行緒呼叫（ok＝結束代碼 0）
    @discardableResult
    static func run(send: Bool, done: @escaping @MainActor @Sendable (Bool) -> Void) -> Bool {
        guard !busy, let script else { return false }
        busy = true
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        p.arguments = ["-I", script.path, "--label", "Keng", "--names", "--out", dir.path] + (send ? ["--send"] : [])
        let log = dir.appendingPathComponent("last.log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        if let h = try? FileHandle(forWritingTo: log) { p.standardOutput = h; p.standardError = h }
        p.terminationHandler = { pr in
            let ok = pr.terminationStatus == 0
            Task { @MainActor in busy = false; done(ok) }
        }
        do { try p.run() } catch { busy = false; return false }
        return true
    }
}

/// 11-22 Keng：球右半邊的硬碟空間（每顆一圈）。只列看得到的實體硬碟：內建（/）＋ /Volumes 底下可瀏覽、不是 Recovery 的
enum SphereDisks {
    static func read() -> [[String: Any]] {
        let keys: [URLResourceKey] = [.volumeNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey, .volumeIsBrowsableKey]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        var out: [[String: Any]] = []
        for u in urls {
            guard let v = try? u.resourceValues(forKeys: Set(keys)), v.volumeIsBrowsable != false, let total = v.volumeTotalCapacity, total > 1_000_000_000 else { continue }
            let path = u.path
            guard path == "/" || (path.hasPrefix("/Volumes/") && v.volumeName != "Recovery") else { continue }
            // 可用空間：內建碟用「重要用途可用」（含可清除的，跟 Finder 一致）；外接碟用一般可用
            let free = (path == "/" ? v.volumeAvailableCapacityForImportantUsage.map(Int.init) : nil) ?? v.volumeAvailableCapacity ?? 0
            let used = max(0, min(100, Double(total - free) / Double(total) * 100))
            out.append(["name": path == "/" ? "內建" : (v.volumeName ?? u.lastPathComponent), "used": used.rounded(),
                        "freeGB": (Double(free) / 1e9).rounded(), "totalGB": (Double(total) / 1e9).rounded()])
        }
        return Array(out.prefix(4))
    }
}

/// 11-22 使用者：按住空白鍵講話時聽到一堆嗶聲＝自動重複的空白鍵沒人收，macOS 每下嗶一聲（約 30 聲／秒，麥克風也錄進去）。
/// 網頁已經吞掉重複鍵；這裡原生再擋一層：按住期間的空白鍵重複事件直接丟掉，不進網頁、不走到 noResponder。
/// 第一下和放開照常交給網頁（開始聽／送出）。實測：按住 3 秒、90 次重複 → 0 聲。
final class SphereWebView: WKWebView {
    override func keyDown(with e: NSEvent) {
        if e.keyCode == 49 && e.isARepeat { return }
        super.keyDown(with: e)
    }

    // 11-22 球體桌面版：上方標題列拖移、右下角縮放（DeskChrome）；noDrag＝網頁回報的按鈕位置（從上緣量的 CSS px）
    var desk = false
    var noDrag: [NSRect] = []
    override func mouseDown(with e: NSEvent) {
        if desk, DeskChrome.mouseDown(e, in: self, noDrag: noDrag) { return }
        super.mouseDown(with: e)
    }
    // 浮動面板沒在前面時，第一下點擊也要算數（點球、按選項）
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { desk || super.acceptsFirstMouse(for: event) }
}

/// WKUserContentController 會強引用 handler：中間隔一層 weak，宿主才放得掉
private final class SphereWeakHandler: NSObject, WKScriptMessageHandler {
    weak var target: SphereWebHost?
    init(_ t: SphereWebHost) { target = t }
    func userContentController(_ ucc: WKUserContentController, didReceive message: WKScriptMessage) {
        MainActor.assumeIsolated { target?.userContentController(ucc, didReceive: message) }
    }
}

struct SphereWebScene: NSViewRepresentable {
    final class Coordinator { var host: SphereWebHost? }
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        guard let h = SphereWebHost() else {
            let t = NSTextField(labelWithString: "找不到 sphere.html（Web 資料夾）")
            t.alignment = .center
            return t
        }
        context.coordinator.host = h
        return h.web
    }

    func updateNSView(_ v: NSView, context: Context) {}

    static func dismantleNSView(_ v: NSView, coordinator: Coordinator) { coordinator.host?.tearDown(); coordinator.host = nil }
}

// MARK: - 聲音選單（11-21 使用者：不喜歡預設那個聲音 ⇒ 讓他自己挑、可試聽）
// ⚠ 只列現成的合成聲音；不准用使用者本人的聲音

enum SphereVoices {
    struct Voice { let id: String; let name: String; let group: String }
    nonisolated(unsafe) private static let defaults = UserDefaults(suiteName: "ai.okle42.showork")
    /// 微軟神經語音（edge-tts；要網路，播報文字會送到微軟）
    static let edgeVoices: [(String, String)] = [
        ("zh-TW-HsiaoChenNeural", "曉臻（台灣女聲）"), ("zh-TW-HsiaoYuNeural", "曉雨（台灣女聲）"),   // 雲哲 YunJhe 免費接口一直失敗（11-21 再試仍失敗），不列
        ("zh-CN-XiaoxiaoNeural", "曉曉（溫暖女聲）"), ("zh-CN-XiaoyiNeural", "曉伊（活潑女聲）"),
        ("zh-CN-YunxiNeural", "雲希（陽光男聲）"), ("zh-CN-YunyangNeural", "雲揚（新聞男聲）"), ("zh-CN-YunjianNeural", "雲健（熱血男聲）"),
    ]
    static func all() -> [Voice] {
        let apple = AVSpeechSynthesisVoice.speechVoices().filter { $0.language == "zh-TW" }
        var seen = Set<String>(), out: [Voice] = []
        // 同名留品質最好的那個
        for v in apple.sorted(by: { $0.quality.rawValue > $1.quality.rawValue }) where !seen.contains(v.name) {
            seen.insert(v.name)
            let name = v.identifier.contains("Shufen") ? "淑芬（系統高品質女聲）" : v.name == "Meijia" ? "美佳（系統女聲）" : v.name
            out.append(Voice(id: "apple:" + v.identifier, name: name, group: "Mac 內建（離線）"))
        }
        if SphereEdgeVoice.binary != nil {
            out += edgeVoices.map { Voice(id: "edge:" + $0.0, name: $0.1, group: "微軟神經語音（要網路，文字會送到微軟）") }
        }
        return out
    }
    static var selected: String {
        get {
            if let s = defaults?.string(forKey: "sphere.voiceId"), all().contains(where: { $0.id == s }) { return s }
            return all().first?.id ?? "apple:"
        }
        set { defaults?.set(newValue, forKey: "sphere.voiceId") }
    }
}

/// edge-tts 合成 mp3（v5：播放交給 SphereAudio，才能做 FFT 畫聲波）
final class SphereEdgeVoice: @unchecked Sendable {
    static var binary: String? {
        let cands = [ProcessInfo.processInfo.environment["SHOWORK_EDGE_TTS"], NSHomeDirectory() + "/github-repos/lipsync-lab/.venv/bin/edge-tts",
                     "/opt/homebrew/bin/edge-tts"].compactMap { $0 }
        return cands.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
    private static let cache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("ShoWork42/sphere-tts", isDirectory: true)
    private let lock = NSLock()
    private var gen = 0

    func speak(_ text: String, voice: String, ready: @escaping @Sendable (URL) -> Void, failed: @escaping @Sendable () -> Void) {
        lock.lock(); gen += 1; let g = gen; lock.unlock()
        guard let bin = Self.binary else { return failed() }
        try? FileManager.default.createDirectory(at: Self.cache, withIntermediateDirectories: true)
        let key = String(UInt64(bitPattern: Int64("\(voice)|\(text)".hashValue)), radix: 36)
        // hashValue 每次啟動會變：快取只在這次執行有效（夠用：同一句常重播的是試聽）
        let out = Self.cache.appendingPathComponent("\(voice)-\(key).mp3")
        DispatchQueue.global().async {
            if !FileManager.default.fileExists(atPath: out.path) {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: bin)
                p.arguments = ["-v", voice, "--text=\(text)", "--write-media=\(out.path)"]
                p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
                do { try p.run() } catch { return failed() }
                let deadline = Date().addingTimeInterval(20)
                while p.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
                if p.isRunning { p.terminate(); return failed() }
                guard p.terminationStatus == 0 else { try? FileManager.default.removeItem(at: out); return failed() }
            }
            self.lock.lock(); let live = g == self.gen; self.lock.unlock()
            if live { ready(out) }        // 中途又換了一句／停了就不播
        }
    }

    func stop() { lock.lock(); gen += 1; lock.unlock() }
}
