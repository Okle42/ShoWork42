import AppKit
import AVFoundation
import Combine
import SwiftUI
import WebKit
import ShoWorkCore

// 戰情中心第四個分頁「球體」（11-21 Kang：參考 IG 的 K.A.R.A 2.0 球體助理）。
// WKWebView 載 Web 資料夾的 sphere.html（three.js 用 vendor 那份，離線可用）；資料單向推：
//   原生端 → 網頁：window.karaUpdate({five_hour, seven_day, ctx, sessions, team})、window.karaVoice("start"|"word"|"end")
//   網頁 → 原生端：webkit.messageHandlers.sphere.postMessage({action: "ready"|"focus"|"speak"|"stopSpeaking", …})
// 球體的狀態與播報由網頁自己判（狀態一變就說一句）。
// 語音（v2，11-21）：macOS 內建台灣中文語音（AVSpeechSynthesizer），網頁上的喇叭按鈕開關，預設關。
// ⚠ 不准用 Keng 本人的聲音（11-21 Keng 下令；記憶 feedback_不准用Keng的聲音）。

@MainActor
final class SphereWebHost: NSObject, WKNavigationDelegate, WKScriptMessageHandler, AVSpeechSynthesizerDelegate {
    let web: WKWebView
    private var loaded = false
    private var sent: String?
    private var pending = false
    private var subs: [AnyCancellable] = []
    private var model: BoardModel { BoardModel.shared }
    private let synth = AVSpeechSynthesizer()
    private static let voice: AVSpeechSynthesisVoice? =
        AVSpeechSynthesisVoice.speechVoices().filter { $0.language == "zh-TW" }.max { $0.quality.rawValue < $1.quality.rawValue }
        ?? AVSpeechSynthesisVoice(language: "zh-TW")

    init?(dir: URL? = WorkWindow.webDir) {
        guard let dir, FileManager.default.fileExists(atPath: dir.appendingPathComponent("sphere.html").path) else { return nil }
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
        web.load(URLRequest(url: URL(string: "\(OfficeWebSchemeHandler.scheme)://web/sphere.html")!))
        model.start()
        model.objectWillChange.sink { [weak self] _ in self?.schedule() }.store(in: &subs)
    }

    func tearDown() {
        subs.removeAll()
        synth.stopSpeaking(at: .immediate)
        web.configuration.userContentController.removeScriptMessageHandler(forName: "sphere")
    }

    // MARK: 網頁 → 原生端

    func userContentController(_ ucc: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let m = message.body as? [String: Any], let a = m["action"] as? String else { return }
        switch a {
        case "ready": loaded = true; sent = nil; push()
        case "focus":
            guard let sid = m["sessionId"] as? String,
                  let c = model.cards.first(where: { $0.sessionId == sid && !$0.id.contains("#") }) ?? model.cards.first(where: { $0.sessionId == sid })
            else { return say("找不到這個 session 了。") }
            jump(c)
        case "speak": speak(m["text"] as? String ?? "")
        case "stopSpeaking": synth.stopSpeaking(at: .immediate)
        default: break
        }
    }

    /// 跳到那個 session：戰情中心自己開的（kind board）開工作視窗，其他的把終端機視窗叫到前面
    private func jump(_ c: BoardCard) {
        if BoardWindow.testMode { return say("測試：不跳到 \(c.name ?? c.project)。") }
        if c.kind == "board" {
            WorkWindow.show(SessionHost.shared.handle(for: c.sessionId) ?? c.sessionId, cwd: c.cwd)
        } else if !BoardActions.focus(pid: c.pid) {
            say(c.kind == "bg" ? "這是背景 session，沒有視窗。" : "找不到這個 session 的視窗。")
        }
    }

    /// 結果回網頁當一句播報
    private func say(_ s: String) {
        guard let d = try? JSONSerialization.data(withJSONObject: [s]) else { return }
        web.evaluateJavaScript("window.karaToast && window.karaToast(\(String(decoding: d, as: UTF8.self))[0])")
    }

    // MARK: 語音

    private func speak(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return voice("end") }
        // 測試不出聲：照字數估時間，假裝唸完
        if BoardWindow.testMode {
            voice("start")
            DispatchQueue.main.asyncAfter(deadline: .now() + min(8, 0.18 * Double(t.count))) { [weak self] in self?.voice("end") }
            return
        }
        synth.stopSpeaking(at: .immediate)
        let u = AVSpeechUtterance(string: String(t.prefix(300)))
        u.voice = Self.voice
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
        loaded = true; sent = nil; push()
        // 測試：SHOWORK_TEST_SPHERE_SHOT=<png> 12 秒後（等卡片讀完）用 WebKit 自己截（BoardWindow.snapshot 的 cacheDisplay 拍不到 WebGL 的顏色）
        if BoardWindow.testMode, let out = ProcessInfo.processInfo.environment["SHOWORK_TEST_SPHERE_SHOT"] {
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

    private func push() {
        guard loaded, let d = try? JSONSerialization.data(withJSONObject: Self.payload(model.cards, model.rateLimits), options: .sortedKeys) else { return }
        let s = String(decoding: d, as: UTF8.self)
        guard s != sent else { return }
        sent = s
        if ProcessInfo.processInfo.environment["SHOWORK_TEST_SPHERE_LOG"] != nil { print("sphere push", s.prefix(120)); fflush(stdout) }
        web.evaluateJavaScript("window.karaUpdate && window.karaUpdate(\(s))")
    }

    /// 網頁要的資料（純函式，方便測）
    static func payload(_ cards: [BoardCard], _ limits: RateLimits?, now: Date = Date()) -> [String: Any] {
        let people = cards.filter { !$0.id.contains("#") }
        let l = limits?.current(now: now)
        var o: [String: Any] = ["sessions": people.count]
        o["five_hour"] = l?.fiveHour.map { $0.used.rounded() } ?? NSNull()
        o["seven_day"] = l?.sevenDay.map { $0.used.rounded() } ?? NSNull()
        // 記憶量：最近有動靜的那個 session
        let recent = people.filter { $0.ctx != nil }.max { ($0.lastActivity ?? .distantPast) < ($1.lastActivity ?? .distantPast) }
        o["ctx"] = recent?.ctx.map { $0.percent.rounded() } ?? NSNull()
        // 需要你的排最前，再來進行中
        func rank(_ c: BoardCard) -> Int { needsYou(c) ? 0 : c.column == .active ? 1 : 2 }
        o["team"] = people.sorted { rank($0) < rank($1) }.map { c -> [String: Any] in
            var t: [String: Any] = ["name": c.name ?? c.project, "status": needsYou(c) ? "需要你" : c.column.title, "sessionId": c.sessionId]
            if let p = c.report?.progress { t["progress"] = p }
            if let d = c.report?.doing { t["doing"] = d }
            if let s = c.report?.summary { t["summary"] = s }
            if let a = c.asks.first?.ask { t["ask"] = a }
            else if let p = c.permit { t["ask"] = "要不要讓它執行 \(p.tool)：\(p.summary)" }
            return t
        }
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
