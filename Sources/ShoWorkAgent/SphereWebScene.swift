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
// 球體的狀態與播報由網頁自己判（狀態一變就說一句）。
// 語音（v2，11-21）：macOS 內建台灣中文語音（AVSpeechSynthesizer），網頁上的喇叭按鈕開關，預設關。
// ⚠ 不准用 Keng 本人的聲音（11-21 Keng 下令；記憶 feedback_不准用Keng的聲音）。按住講話只做本機即時辨識成文字，不存音檔。

@MainActor
final class SphereWebHost: NSObject, WKNavigationDelegate, WKScriptMessageHandler, AVSpeechSynthesizerDelegate {
    let web: WKWebView
    let mini: Bool
    private var loaded = false
    private var sent: String?
    private var pending = false
    private var subs: [AnyCancellable] = []
    private var ticker: Timer?
    private var model: BoardModel { BoardModel.shared }
    private let synth = AVSpeechSynthesizer()
    private var listener: SphereListener?
    private let edge = SphereEdgeVoice()

    init?(dir: URL? = WorkWindow.webDir, mini: Bool = false) {
        guard let dir, FileManager.default.fileExists(atPath: dir.appendingPathComponent("sphere.html").path) else { return nil }
        self.mini = mini
        let cfg = WKWebViewConfiguration()
        cfg.setURLSchemeHandler(OfficeWebSchemeHandler(root: dir), forURLScheme: OfficeWebSchemeHandler.scheme)
        web = WKWebView(frame: .zero, configuration: cfg)
        super.init()
        cfg.userContentController.add(SphereWeakHandler(self), name: "sphere")
        synth.delegate = self
        web.setValue(false, forKey: "drawsBackground")
        // 測試視窗在螢幕外＝被當成看不見、rAF 停掉、WebGL 不畫（同 OfficeWebHost）：測試時關掉遮擋偵測
        let occ = NSSelectorFromString("_setWindowOcclusionDetectionEnabled:")
        if BoardWindow.testMode, web.responds(to: occ), let m = class_getInstanceMethod(WKWebView.self, occ) {
            typealias SetBool = @convention(c) (AnyObject, Selector, Bool) -> Void
            unsafeBitCast(method_getImplementation(m), to: SetBool.self)(web, occ, false)
        }
        web.navigationDelegate = self
        web.load(URLRequest(url: URL(string: "\(OfficeWebSchemeHandler.scheme)://web/sphere.html\(mini ? "?mini=1" : "")")!))
        model.start()
        model.objectWillChange.sink { [weak self] _ in self?.schedule() }.store(in: &subs)
        // 溫度、額度重置倒數不會觸發 objectWillChange：每 10 秒補一次（內容一樣就不推）
        ticker = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.push() } }
        NotificationCenter.default.publisher(for: HeatGate.changed).sink { [weak self] _ in self?.schedule() }.store(in: &subs)
    }

    func tearDown() {
        subs.removeAll()
        ticker?.invalidate(); ticker = nil
        listener?.stop(); listener = nil
        synth.stopSpeaking(at: .immediate); edge.stop()
        web.configuration.userContentController.removeScriptMessageHandler(forName: "sphere")
    }

    private var blocked: Bool { BoardWindow.testMode }

    // MARK: 網頁 → 原生端

    func userContentController(_ ucc: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let m = message.body as? [String: Any], let a = m["action"] as? String else { return }
        let str = { (k: String) in m[k] as? String }
        switch a {
        case "ready": loaded = true; sent = nil; push()
        case "focus":
            guard let c = card(str("sessionId")) else { return say("找不到這個 session 了。") }
            jump(c)
        case "speak": speak(str("text") ?? "")
        case "stopSpeaking": synth.stopSpeaking(at: .immediate); edge.stop()
        case "setVoice":       // 11-21 Keng：換聲音（選單選了就存起來、馬上試聽一句）
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
            SphereMini.shared.enabled = m["on"] as? Bool ?? !SphereMini.shared.enabled
            pushPrefs()
        case "openBoard": openBoard()
        default: break
        }
    }

    /// 打開戰情中心、切到球體分頁（小球點一下）
    func openBoard() {
        UserDefaults(suiteName: "ai.okle42.showork")?.set("sphere", forKey: "board.mode")
        if !blocked { NSApp.activate(ignoringOtherApps: true) }
        BoardWindow.shared.show()
    }

    private func card(_ sid: String?) -> BoardCard? {
        guard let sid else { return nil }
        return model.cards.first(where: { $0.sessionId == sid && !$0.id.contains("#") }) ?? model.cards.first(where: { $0.sessionId == sid })
    }

    /// 跳到那個 session：戰情中心自己開的（kind board）開工作視窗，其他的把終端機視窗叫到前面
    private func jump(_ c: BoardCard) {
        if blocked { return say("測試：不跳到 \(c.name ?? c.project)。") }
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
        synth.stopSpeaking(at: .immediate)
        let l = SphereListener { [weak self] text, final, err in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if let err { self.js("window.karaHeard", "", true); self.say(err); return }
                    self.js("window.karaHeard", text, final)
                }
            }
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
        synth.stopSpeaking(at: .immediate); edge.stop()
        let id = SphereVoices.selected
        if id.hasPrefix("edge:") {
            // 微軟神經語音：edge-tts 合成 mp3（要網路；文字會送到微軟），播放時用音量驅動球跳動
            edge.speak(String(t.prefix(300)), voice: String(id.dropFirst(5))) { [weak self] ev in
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.voice(ev) } }
            } failed: { [weak self] in
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.voice("end"); self?.say("微軟語音連不上，先改用系統語音。") } }
            }
            return
        }
        let u = AVSpeechUtterance(string: String(t.prefix(300)))
        u.voice = AVSpeechSynthesisVoice(identifier: String(id.dropFirst(6))) ?? AVSpeechSynthesisVoice(language: "zh-TW")
        u.rate = AVSpeechUtteranceDefaultSpeechRate * 1.05
        synth.speak(u)
    }

    private func voice(_ ev: String) { web.evaluateJavaScript("window.karaVoice && window.karaVoice('\(ev)')") }

    nonisolated func speechSynthesizer(_ s: AVSpeechSynthesizer, didStart u: AVSpeechUtterance) {
        DispatchQueue.main.async { MainActor.assumeIsolated { self.voice("start") } }
    }
    nonisolated func speechSynthesizer(_ s: AVSpeechSynthesizer, willSpeakRangeOfSpeechString r: NSRange, utterance u: AVSpeechUtterance) {
        DispatchQueue.main.async { MainActor.assumeIsolated { self.voice("word") } }
    }
    nonisolated func speechSynthesizer(_ s: AVSpeechSynthesizer, didFinish u: AVSpeechUtterance) {
        DispatchQueue.main.async { MainActor.assumeIsolated { self.voice("end") } }
    }
    nonisolated func speechSynthesizer(_ s: AVSpeechSynthesizer, didCancel u: AVSpeechUtterance) {
        DispatchQueue.main.async { MainActor.assumeIsolated { self.voice("end") } }
    }

    func webView(_ w: WKWebView, didFinish n: WKNavigation!) {
        loaded = true; sent = nil; push(); pushPrefs()
        // 測試：SHOWORK_TEST_SPHERE_SHOT=<png> 12 秒後（等卡片讀完）用 WebKit 自己截（BoardWindow.snapshot 的 cacheDisplay 拍不到 WebGL 的顏色）
        let env = ProcessInfo.processInfo.environment
        if BoardWindow.testMode, let out = env[mini ? "SHOWORK_TEST_SPHERE_MINI_SHOT" : "SHOWORK_TEST_SPHERE_SHOT"] {
            // SHOWORK_TEST_SPHERE_JS：截圖前先跑一段網頁程式（例如假一筆「需要你」看選項按鈕）
            if let code = env["SHOWORK_TEST_SPHERE_JS"], !mini {
                DispatchQueue.main.asyncAfter(deadline: .now() + 9) { [weak self] in self?.web.evaluateJavaScript(code) }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 12) { [weak self] in
                self?.web.takeSnapshot(with: nil) { img, _ in
                    guard let img, let t = img.tiffRepresentation, let r = NSBitmapImageRep(data: t),
                          let png = r.representation(using: .png, properties: [:]) else { print("sphere shot failed"); fflush(stdout); return }
                    try? png.write(to: URL(fileURLWithPath: out))
                    print("sphere shot saved \(out)"); fflush(stdout)
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
        js("window.karaPrefs", ["mini": SphereMini.shared.enabled, "voice": SphereVoices.selected,
                                "voices": SphereVoices.all().map { ["id": $0.id, "name": $0.name, "group": $0.group] }])
    }

    private func push() {
        guard loaded else { return }
        let heat = CityParse.cool42(FileManager.default.contents(atPath: HeatGate.cool42Path), now: Date())
        var o = Self.payload(model.cards, model.rateLimits, runs: model.runs, heat: heat)
        o["paused"] = HeatGate.shared.paused
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
            var t: [String: Any] = ["name": c.name ?? c.project, "status": needsYou(c) ? "需要你" : c.column.title, "sessionId": c.sessionId]
            if let p = c.report?.progress { t["progress"] = p }
            if let d = c.report?.doing { t["doing"] = d }
            if let s = c.report?.summary { t["summary"] = s }
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

// MARK: - 聲音選單（11-21 Keng：不喜歡預設那個聲音 ⇒ 讓他自己挑、可試聽）
// ⚠ 只列現成的合成聲音；不准用 Keng 本人的聲音（記憶 feedback_不准用Keng的聲音）

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

/// edge-tts 合成＋播放；放的時候每 60ms 看音量，聲音冒上來就回報一次 "word"（讓球跟著跳）
final class SphereEdgeVoice: NSObject, AVAudioPlayerDelegate, @unchecked Sendable {
    static var binary: String? {
        let cands = [ProcessInfo.processInfo.environment["SHOWORK_EDGE_TTS"], NSHomeDirectory() + "/github-repos/lipsync-lab/.venv/bin/edge-tts",
                     "/opt/homebrew/bin/edge-tts"].compactMap { $0 }
        return cands.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
    private static let cache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("ShoWork42/sphere-tts", isDirectory: true)
    private var player: AVAudioPlayer?
    private var meter: Timer?
    private var onEvent: ((String) -> Void)?
    private var gen = 0
    private var loud = false

    func speak(_ text: String, voice: String, onEvent: @escaping @Sendable (String) -> Void, failed: @escaping @Sendable () -> Void) {
        gen += 1; let g = gen
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
            DispatchQueue.main.async { self.play(out, gen: g, onEvent: onEvent, failed: failed) }
        }
    }

    private func play(_ url: URL, gen g: Int, onEvent: @escaping (String) -> Void, failed: () -> Void) {
        guard g == gen else { return }        // 中途又換了一句／停了
        guard let p = try? AVAudioPlayer(contentsOf: url) else { return failed() }
        p.delegate = self; p.isMeteringEnabled = true
        player = p; self.onEvent = onEvent
        p.play(); onEvent("start")
        meter = Timer.scheduledTimer(withTimeInterval: 0.06, repeats: true) { [weak self] _ in
            guard let self, let p = self.player else { return }
            p.updateMeters()
            let db = p.averagePower(forChannel: 0)
            if db > -24 && !self.loud { self.loud = true; self.onEvent?("word") }
            else if db < -32 { self.loud = false }
        }
    }

    func stop() {
        gen += 1
        if player != nil { finish() }
    }

    private func finish() {
        meter?.invalidate(); meter = nil
        player?.stop(); player = nil
        let e = onEvent; onEvent = nil
        e?("end")
    }

    func audioPlayerDidFinishPlaying(_ p: AVAudioPlayer, successfully: Bool) {
        DispatchQueue.main.async { if p === self.player { self.finish() } }
    }
}
