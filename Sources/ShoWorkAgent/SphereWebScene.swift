import AppKit
import Combine
import SwiftUI
import WebKit
import ShoWorkCore

// 戰情中心第四個分頁「球體」（11-21 Kang：參考 IG 的 K.A.R.A 2.0 球體助理）。
// WKWebView 載 Web 資料夾的 sphere.html（three.js 用 vendor 那份，離線可用）；資料單向推：
//   原生端 → 網頁：window.karaUpdate({five_hour, seven_day, ctx, sessions, team})
// 球體的狀態由網頁自己判：有人等你回答＝亮橘、有人進行中＝轉、都閒＝待命。沒有任何動作回傳原生端。

@MainActor
final class SphereWebHost: NSObject, WKNavigationDelegate {
    let web: WKWebView
    private var loaded = false
    private var sent: String?
    private var pending = false
    private var subs: [AnyCancellable] = []
    private var model: BoardModel { BoardModel.shared }

    init?(dir: URL? = WorkWindow.webDir) {
        guard let dir, FileManager.default.fileExists(atPath: dir.appendingPathComponent("sphere.html").path) else { return nil }
        let cfg = WKWebViewConfiguration()
        cfg.setURLSchemeHandler(OfficeWebSchemeHandler(root: dir), forURLScheme: OfficeWebSchemeHandler.scheme)
        web = WKWebView(frame: .zero, configuration: cfg)
        super.init()
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

    func tearDown() { subs.removeAll() }

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
            var t: [String: Any] = ["name": c.name ?? c.project, "status": needsYou(c) ? "需要你" : c.column.title]
            if let p = c.report?.progress { t["progress"] = p }
            if let d = c.report?.doing { t["doing"] = d }
            return t
        }
        return o
    }

    static func needsYou(_ c: BoardCard) -> Bool { !c.asks.isEmpty || c.permit != nil }
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
