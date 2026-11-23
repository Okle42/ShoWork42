import AppKit
import AVFoundation
import Speech
import ShoWorkCore

// 球體桌面版（11-22 Keng 選定最終型態，T1122091602）：原本 200×210 的桌面小球放大成「完整的球體」——
// 跟戰情中心的球體分頁同一份 sphere.html（?desk=1），功能全部一樣（卡片、選項面板、事件卡、橫幅、時間軸、播報、按住講話、空白鍵）。
//   - 透明圓角浮動面板、不搶焦點（點它才變 key，不會把 App 叫到前面）、每個桌面都看得到
//   - 拖上方標題列移動；拖右下角縮放；工具列「尺寸」或選單列「桌面球體大小」切 小／中／大；位置和尺寸都記住
//   - 兩顆球同時開著時只有桌面版會「自動播報」出聲（分頁那顆只出字幕），免得同一句唸兩次
// 測試模式（--board-window）一律開在螢幕外，也不寫入位置／尺寸（記憶：測試視窗不可開到他螢幕）。
// 舊名 SphereMini 沿用（選單列、SphereWatch、偏好鍵 sphere.mini 都接著用，升級後上次開著就照樣開）。

@MainActor
final class SphereMini: NSObject, NSWindowDelegate {
    static let shared = SphereMini()
    static let changed = Notification.Name("SphereMini.changed")
    nonisolated(unsafe) private static let defaults = UserDefaults(suiteName: "ai.okle42.showork")
    private var panel: NSPanel?
    private var host: SphereWebHost?

    /// 預設尺寸（11-22：Keng 要比小球大；中＝直式，球在中間、卡片在下面）
    static let presets: [(id: String, name: String, size: NSSize)] = [
        ("s", "小", NSSize(width: 460, height: 620)),
        ("m", "中", NSSize(width: 540, height: 720)),
        ("l", "大", NSSize(width: 1000, height: 700)),
    ]
    static let minSize = NSSize(width: 360, height: 440)

    var enabled: Bool {
        get { Self.defaults?.bool(forKey: "sphere.mini") ?? false }
        set {
            Self.defaults?.set(newValue, forKey: "sphere.mini")
            newValue ? show() : hide()
            NotificationCenter.default.post(name: Self.changed, object: nil)
        }
    }

    /// App 啟動時：上次開著就照樣開
    func restore() { if enabled { show() } }

    var isShown: Bool { panel != nil }

    func show() {
        if let p = panel { p.orderFrontRegardless(); return }
        guard let h = SphereWebHost(desk: true) else { return }
        let size = savedSize()
        let p = DeskPanel(contentRect: NSRect(origin: origin(for: size), size: size),
                          styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.level = .floating
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.minSize = Self.minSize
        p.delegate = self
        let root = NSView(frame: NSRect(origin: .zero, size: size))
        root.wantsLayer = true
        root.layer?.cornerRadius = 14
        root.layer?.masksToBounds = true
        h.web.frame = root.bounds
        h.web.autoresizingMask = [.width, .height]
        root.addSubview(h.web)
        p.contentView = root
        p.orderFrontRegardless()
        panel = p; host = h
        if BoardWindow.testMode, ProcessInfo.processInfo.environment["SHOWORK_TEST_DESK_PROBE"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 9) { [weak self] in self?.probe() }
        }
    }

    /// 測試（--board-window＋SHOWORK_TEST_DESK_PROBE）：在螢幕外的桌面版上逐項按一遍，印出結果
    private func probe() {
        guard let p = panel as? DeskPanel, let h = host, let web = h.web as? SphereWebView else { return }
        func out(_ s: String) { print("desk probe:", s); fflush(stdout) }
        func js(_ code: String, _ done: @escaping (String) -> Void) {
            web.evaluateJavaScript(code) { r, e in MainActor.assumeIsolated { done(e.map { "JS錯誤 \($0)" } ?? "\(r ?? "nil")") } }
        }
        // 1. 拖移／縮放：標題列空白處、右下角的點擊會落到 SphereWebView（它的 mouseDown 才攔得到）
        let b = web.bounds
        let barPt = NSPoint(x: 40, y: web.isFlipped ? 12 : b.height - 12)
        out("標題列點擊落在 \(type(of: web.hitTest(web.convert(barPt, to: web.superview)) ?? web))；noDrag \(web.noDrag)")
        // 2. 尺寸：小 → 中 → 大，看視窗和網頁都跟著變
        var steps: [String] = []
        for id in ["s", "m", "l"] {
            setPreset(id)
            steps.append("\(id)=\(Int(p.frame.width))×\(Int(p.frame.height))")
        }
        out("尺寸 " + steps.joined(separator: " ") + "，目前預設 \(currentPreset ?? "nil")")
        setPreset("m")
        // 3. 網頁功能：按工具列、點衛星、時間軸、選項面板
        js("""
          void (async () => { const $ = id => document.getElementById(id); const w = ms => new Promise(f => setTimeout(f, ms));
            $('bBrief').click(); await w(800);
            $('bTl').click(); await w(800);
            const sid = (karaData().team || [])[0]?.sessionId;
            if (sid) webkit.messageHandlers.sphere.postMessage({ action: 'sessionInfo', sessionId: sid });
          })(); 'ok'
        """) { out("按鈕已按：\($0)") }
        // 3.5 秒後讀結果（callAsyncJavaScript 等得到 Promise）
        web.callAsyncJavaScript("""
          const r = []; const $ = id => document.getElementById(id); const w = ms => new Promise(f => setTimeout(f, ms));
          await w(3500);
          r.push('寬 ' + innerWidth + '×' + innerHeight);
          r.push('卡片 ' + ['cardUsage','cardTeam','cardSys'].map(i => i + ':' + $(i).classList.contains('on')).join(','));
          r.push('工具 ' + [...document.querySelectorAll('#tools button')].filter(b => b.offsetParent).map(b => b.textContent.trim()).join('/'));
          r.push('時間軸：' + $('tlCard').innerHTML.includes('今日時間軸'));
          r.push('衛星小卡：' + $('satCard').innerHTML.includes('SESSION'));
          r.push('選項面板：' + $('askCard').classList.contains('on') + '（asking=' + document.body.classList.contains('asking') + '）');
          r.push('早報字幕：' + $('capText').textContent.slice(0, 24));
          return r.join(' ｜ ');
        """, arguments: [:], in: nil, in: .page) { res in
            MainActor.assumeIsolated {
                if case .success(let v) = res { out("網頁 " + "\(v ?? "nil")") } else { out("網頁 失敗 \(res)") }
                self.probeKeys(p, web, out)
            }
        }
    }

    /// 按住空白鍵 3 秒（90 次自動重複）：數嗶聲（noResponder）＋看有沒有開始聽／放開送出
    private func probeKeys(_ p: DeskPanel, _ web: SphereWebView, _ out: @escaping @MainActor (String) -> Void) {
        DeskPanel.testKey = true
        p.makeFirstResponder(web)
        func key(_ down: Bool, _ rep: Bool) {
            let e = NSEvent.keyEvent(with: down ? .keyDown : .keyUp, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                     windowNumber: p.windowNumber, context: nil, characters: " ", charactersIgnoringModifiers: " ", isARepeat: rep, keyCode: 49)!
            p.sendEvent(e)
        }
        web.evaluateJavaScript("document.activeElement && document.activeElement.blur()")
        key(true, false)
        func step(_ n: Int) {
            key(true, true)
            if n == 45 { web.evaluateJavaScript("document.getElementById('stZh').dataset.v") { r, _ in MainActor.assumeIsolated { out("按住中狀態：\(r ?? "nil")") } } }
            guard n >= 90 else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 / 30) { MainActor.assumeIsolated { step(n + 1) } }
                return
            }
            key(false, false)
            for d in [0.3, 1.0, 1.8] {
                DispatchQueue.main.asyncAfter(deadline: .now() + d) {
                    web.evaluateJavaScript("document.getElementById('stZh').dataset.v + '｜' + document.getElementById('capText').textContent") { r, _ in MainActor.assumeIsolated { out("放開後 \(d) 秒：\(r ?? "nil")") } }
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                web.evaluateJavaScript("document.getElementById('capText').textContent") { r, _ in
                    MainActor.assumeIsolated { out("空白鍵 90 次重複 → 嗶聲 \(DeskPanel.beeps) 次；放開後字幕「\(r ?? "")」") }
                    exit(0)
                }
            }
        }
        step(1)
    }

    func bounce() { host?.bounce() }

    func hide() {
        host?.tearDown(); host = nil
        panel?.orderOut(nil); panel = nil
    }

    // MARK: 尺寸

    /// 目前尺寸對到哪個預設（拖過邊角＝nil）
    var currentPreset: String? {
        guard let s = panel?.frame.size ?? Optional(savedSize()) else { return nil }
        return Self.presets.first { abs($0.size.width - s.width) < 2 && abs($0.size.height - s.height) < 2 }?.id
    }

    /// 換尺寸：上緣和中線不動（往下長、左右各長一半），再塞回螢幕內
    func setPreset(_ id: String) {
        guard let pr = Self.presets.first(where: { $0.id == id }) else { return }
        resize(to: pr.size)
    }

    /// 工具列「尺寸」：小 → 中 → 大 → 小
    func cyclePreset() {
        let ids = Self.presets.map(\.id)
        let i = currentPreset.flatMap { ids.firstIndex(of: $0) } ?? 0
        setPreset(ids[(i + 1) % ids.count])
    }

    private func resize(to size: NSSize) {
        guard let p = panel else { return }
        let f = p.frame
        var r = NSRect(x: f.midX - size.width / 2, y: f.maxY - size.height, width: size.width, height: size.height)
        if !BoardWindow.testMode, let v = (p.screen ?? NSScreen.main)?.visibleFrame {
            r.size.width = min(r.width, v.width); r.size.height = min(r.height, v.height)
            r.origin.x = min(max(r.minX, v.minX), v.maxX - r.width)
            r.origin.y = min(max(r.minY, v.minY), v.maxY - r.height)
        }
        p.setFrame(r, display: true, animate: !BoardWindow.testMode)
        save()
    }

    private func savedSize() -> NSSize {
        if let env = ProcessInfo.processInfo.environment["SHOWORK_TEST_DESK_SIZE"] {      // 測試：各尺寸截圖
            let s = NSSizeFromString(env); if s.width > 0 { return s }
        }
        if let s = Self.defaults?.string(forKey: "sphere.desk.size") {
            let z = NSSizeFromString(s)
            if z.width >= Self.minSize.width, z.height >= Self.minSize.height { return z }
        }
        return Self.presets[1].size
    }

    private func origin(for size: NSSize) -> NSPoint {
        if BoardWindow.testMode { return NSPoint(x: -4000, y: -4000) }
        if let s = Self.defaults?.string(forKey: "sphere.mini.origin") {
            let p = NSPointFromString(s)
            // 存的位置還在某個螢幕上才用（外接螢幕拔掉了就回預設）；放大後超出螢幕就往內收
            if let scr = NSScreen.screens.first(where: { $0.visibleFrame.insetBy(dx: -40, dy: -40).contains(p) }) {
                let v = scr.visibleFrame
                return NSPoint(x: min(max(p.x, v.minX), v.maxX - size.width), y: min(max(p.y, v.minY), v.maxY - size.height))
            }
        }
        let v = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        return NSPoint(x: v.maxX - size.width - 24, y: v.minY + 24)
    }

    private func save() {
        guard !BoardWindow.testMode, let p = panel else { return }
        Self.defaults?.set(NSStringFromPoint(p.frame.origin), forKey: "sphere.mini.origin")
        Self.defaults?.set(NSStringFromSize(p.frame.size), forKey: "sphere.desk.size")
        NotificationCenter.default.post(name: Self.changed, object: nil)
    }

    func windowDidMove(_ n: Notification) { save() }
    func windowDidEndLiveResize(_ n: Notification) { save() }
}

/// 無邊框面板預設不能變 key ⇒ 選項面板打不了字、空白鍵收不到。改成可以（.nonactivatingPanel：變 key 也不會把 App 叫到前面）
final class DeskPanel: NSPanel {
    nonisolated(unsafe) static var testKey = false, beeps = 0      // 測試：螢幕外也當成 key、數嗶聲
    override var canBecomeKey: Bool { true }
    override var isKeyWindow: Bool { Self.testKey || super.isKeyWindow }
    override func noResponder(for s: Selector) { if Self.testKey { Self.beeps += 1 } else { super.noResponder(for: s) } }
    override func constrainFrameRect(_ r: NSRect, to screen: NSScreen?) -> NSRect { BoardWindow.testMode ? r : super.constrainFrameRect(r, to: screen) }
}

/// 桌面版的視窗操作（SphereWebView 呼叫）：上方標題列＝拖移、右下角＝縮放
@MainActor
enum DeskChrome {
    static let barHeight: CGFloat = 34
    static let corner: CGFloat = 18

    /// 處理了就回 true（不交給網頁）
    static func mouseDown(_ e: NSEvent, in v: NSView, noDrag: [NSRect]) -> Bool {
        guard let w = v.window else { return false }
        let p = v.convert(e.locationInWindow, from: nil)
        let top = v.isFlipped ? p.y : v.bounds.height - p.y          // 從上緣量
        let fromRight = v.bounds.width - p.x, fromBottom = v.bounds.height - top
        if fromRight < corner && fromBottom < corner { liveResize(w, e); return true }
        if top < barHeight, !noDrag.contains(where: { $0.contains(NSPoint(x: p.x, y: top)) }) {
            w.performDrag(with: e)
            return true
        }
        return false
    }

    /// 右下角拖曳縮放（左上角固定）
    private static func liveResize(_ w: NSWindow, _ down: NSEvent) {
        let start = NSEvent.mouseLocation, f0 = w.frame
        while let e = w.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            let m = NSEvent.mouseLocation
            let width = max(w.minSize.width, f0.width + (m.x - start.x))
            let height = max(w.minSize.height, f0.height - (m.y - start.y))
            w.setFrame(NSRect(x: f0.minX, y: f0.maxY - height, width: width, height: height), display: true)
            if e.type == .leftMouseUp { break }
        }
        (w.delegate as? SphereMini)?.windowDidEndLiveResize(Notification(name: NSWindow.didEndLiveResizeNotification, object: w))
    }
}

// MARK: - 按住球講話（v3 #2）

/// 本機語音辨識（台灣中文）：麥克風 → SFSpeechRecognizer，中間結果一直回報；finish() 收尾拿最後一句。
/// 不存音檔、能本機辨識就強制本機（requiresOnDeviceRecognition）；音訊不離開這台 Mac。
///
/// 11-23 T1123114256 Keng「按住講話一停頓，前面的字就被刪掉，最後只送出最後一句」：
/// 本機辨識在停頓後會開新的一段，bestTranscription 只剩「這一段」，之前直接拿它蓋掉 ⇒ 前面全丟。
/// 現在：①偵測到新的一段（時間戳往後跳、或字變短且開頭不同）就把上一段收進 committed；
/// ②辨識器在停頓時直接給 isFinal／沒聽到聲音的錯誤 ⇒ 收進 committed、馬上接一個新的辨識繼續聽；
/// ③放開（finish）才整段送出；中間每次回報的都是「按住以來的全部文字」，畫面上看得到完整內容。
/// 測試：環境變數 SHOWORK_TEST_LISTEN_FILE＝音檔路徑 ⇒ 不開麥克風，照真實速度把音檔餵給辨識器，播完自動 finish。
final class SphereListener: @unchecked Sendable {
    typealias Report = @Sendable (_ text: String, _ final: Bool, _ error: String?) -> Void
    private let report: Report
    private let engine = AVAudioEngine()
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var committed = ""          // 已經講完的段落（按住期間累加）
    private var current = ""            // 目前這一段的辨識結果
    private var currentStart: TimeInterval = -1
    private var finishing = false
    private var done = false
    private var generation = 0          // 每接一次新辨識 +1，舊辨識的回呼不再算數
    private let lock = NSLock()

    /// v5：麥克風的頻譜＋音量（聽的時候球也有聲波），約 30 次／秒
    var onLevel: (@Sendable ([Float], Float) -> Void)?
    private let spectrum = SphereSpectrum()
    private var lastLevel = Date.distantPast

    init(_ report: @escaping Report) { self.report = report }

    static var testFile: String? { ProcessInfo.processInfo.environment["SHOWORK_TEST_LISTEN_FILE"] }

    func start() {
        SFSpeechRecognizer.requestAuthorization { st in
            if Self.testFile != nil { print("listen auth \(st.rawValue)"); fflush(stdout) }
            guard st == .authorized else {
                self.report("", true, st == .denied || st == .restricted
                    ? "沒有語音辨識權限：到「系統設定 › 隱私權與安全性 › 語音辨識」打開 ShoWork42 戰情中心。"
                    : "語音辨識還沒授權。")
                return
            }
            DispatchQueue.main.async { self.begin() }
        }
    }

    /// 兩段文字接起來
    static func join(_ a: String, _ b: String) -> String {
        let a = a.trimmingCharacters(in: .whitespaces), b = b.trimmingCharacters(in: .whitespaces)
        if a.isEmpty { return b }; if b.isEmpty { return a }
        // 段落之間是你停頓的地方 ⇒ 補一個「，」（上一段已經有標點就不補），隊長讀得出斷句
        let l = a.unicodeScalars.last!
        return a + (CharacterSet.punctuationCharacters.contains(l) ? "" : "，") + b
    }

    /// 新結果是不是「下一段」（辨識器在停頓後重新開始）而不是同一段的修正
    static func isNewSegment(prev: String, prevStart: TimeInterval, new: String, newStart: TimeInterval) -> Bool {
        if prev.isEmpty || new.isEmpty { return false }
        if prevStart > 0, newStart > prevStart + 0.6 { return true }
        let common = zip(prev, new).prefix { $0 == $1 }.count
        // 實測（11-23，macOS 本機辨識）：停頓後同一個辨識的文字會從頭來（「第一段…多少」→「第」），時間戳全是 0
        return (new.count < prev.count && common < 2) || Double(new.count) < Double(prev.count) * 0.6
    }

    private var full: String { Self.join(committed, current) }

    private func begin() {
        guard let rec = SFSpeechRecognizer(locale: Locale(identifier: "zh-TW")), rec.isAvailable else {
            return report("", true, "這台 Mac 現在不能辨識中文語音。")
        }
        recognizer = rec
        newTask()
        if let path = Self.testFile { return feed(path) }
        let input = engine.inputNode
        let fmt = input.outputFormat(forBus: 0)
        guard fmt.sampleRate > 0 else { return report("", true, "找不到麥克風。") }
        input.installTap(onBus: 0, bufferSize: 1024, format: fmt) { [weak self] buf, _ in
            guard let self else { return }
            self.lock.lock(); let r = self.request; self.lock.unlock()
            r?.append(buf)
            guard let cb = self.onLevel, let ch = buf.floatChannelData?[0], Date().timeIntervalSince(self.lastLevel) > 0.03 else { return }
            self.lastLevel = Date()
            let l = self.spectrum.analyze(ch, count: Int(buf.frameLength), sampleRate: fmt.sampleRate)
            cb(l.bands, l.rms)
        }
        engine.prepare()
        do { try engine.start() } catch { return report("", true, "麥克風開不起來：\(error.localizedDescription)") }
    }

    /// 開一個新的辨識（第一次，或上一個在停頓時自己結束了）
    private func newTask() {
        guard let rec = recognizer else { return }
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        if rec.supportsOnDeviceRecognition { req.requiresOnDeviceRecognition = true }
        lock.lock(); generation += 1; let gen = generation; request = req; current = ""; currentStart = -1; lock.unlock()
        task = rec.recognitionTask(with: req) { [weak self] res, err in self?.handle(res, err, gen) }
    }

    private func handle(_ res: SFSpeechRecognitionResult?, _ err: Error?, _ gen: Int) {
        lock.lock()
        if done || gen != generation { lock.unlock(); return }
        if let res {
            let t = res.bestTranscription.formattedString
            let st = res.bestTranscription.segments.first?.timestamp ?? 0
            if Self.testFile != nil { print("raw gen=\(gen) st=\(String(format: "%.1f", st)) final=\(res.isFinal) n=\(t.count) new=\(Self.isNewSegment(prev: current, prevStart: currentStart, new: t, newStart: st)) \(String(t.prefix(14)))"); fflush(stdout) }
            if Self.isNewSegment(prev: current, prevStart: currentStart, new: t, newStart: st) {
                committed = Self.join(committed, current)
            }
            current = t; currentStart = st
        }
        let ended = res?.isFinal == true || err != nil
        if Self.testFile != nil, let err { print("raw err \(err)"); fflush(stdout) }
        if ended && !finishing {
            // 按住中、辨識器自己在停頓處收尾（或「沒聽到聲音」）：這段收進去，接一個新的繼續聽
            committed = full; current = ""
            let text = committed
            lock.unlock()
            report(text, false, nil)
            DispatchQueue.main.async { self.newTask() }
            return
        }
        if ended { done = true }
        let text = full
        lock.unlock()
        if ended { teardown() }
        report(text, ended, nil)
    }

    /// 測試：照真實速度把音檔餵給目前的辨識，播完放開
    private func feed(_ path: String) {
        DispatchQueue.global().async { [weak self] in
            guard let self, let f = try? AVAudioFile(forReading: URL(fileURLWithPath: path)) else { return }
            let fmt = f.processingFormat, chunk: AVAudioFrameCount = 1024
            while true {
                guard let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: chunk), (try? f.read(into: buf, frameCount: chunk)) != nil, buf.frameLength > 0 else { break }
                self.lock.lock(); let r = self.request; self.lock.unlock()
                r?.append(buf)
                Thread.sleep(forTimeInterval: Double(buf.frameLength) / fmt.sampleRate)
            }
            self.finish()
        }
    }

    /// 放開球：停止收音，等辨識器給最後結果（最多 2 秒）
    func finish() {
        lock.lock(); finishing = true; lock.unlock()
        if engine.isRunning { engine.inputNode.removeTap(onBus: 0); engine.stop() }
        request?.endAudio()
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            if self.done { self.lock.unlock(); return }
            self.done = true
            let text = self.full
            self.lock.unlock()
            self.task?.cancel()
            self.report(text, true, nil)
        }
    }

    func stop() {
        lock.lock(); done = true; lock.unlock()
        teardown()
    }

    private func teardown() {
        if engine.isRunning { engine.inputNode.removeTap(onBus: 0); engine.stop() }
        request?.endAudio()
        task?.cancel()
    }
}
