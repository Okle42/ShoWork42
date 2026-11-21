import AppKit
import AVFoundation
import Speech
import ShoWorkCore

// 球體 v3 #7：桌面常駐小球（11-21）。透明、不搶焦點、永遠在最上層、每個桌面都看得到的小面板，
// 裡面是 sphere.html?mini=1（只有球＋一行字幕，不唸出聲；播報交給戰情中心那顆）。
// 拖曳移動、點一下打開戰情中心的球體分頁。開關：球體分頁的「小球」按鈕、選單列「桌面小球」。
// 測試模式（--board-window）一律開在螢幕外（記憶：測試視窗不可開到他螢幕）。

@MainActor
final class SphereMini: NSObject, NSWindowDelegate {
    static let shared = SphereMini()
    nonisolated(unsafe) private static let defaults = UserDefaults(suiteName: "ai.okle42.showork")
    private var panel: NSPanel?
    private var host: SphereWebHost?
    static let size = NSSize(width: 200, height: 210)

    var enabled: Bool {
        get { Self.defaults?.bool(forKey: "sphere.mini") ?? false }
        set {
            Self.defaults?.set(newValue, forKey: "sphere.mini")
            newValue ? show() : hide()
        }
    }

    /// App 啟動時：上次開著就照樣開
    func restore() { if enabled { show() } }

    func show() {
        if let p = panel { p.orderFrontRegardless(); return }
        guard let h = SphereWebHost(mini: true) else { return }
        let p = NSPanel(contentRect: NSRect(origin: origin(), size: Self.size),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.level = .floating
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.delegate = self
        let root = NSView(frame: NSRect(origin: .zero, size: Self.size))
        h.web.frame = root.bounds
        h.web.autoresizingMask = [.width, .height]
        root.addSubview(h.web)
        // 蓋一層透明的拖曳面：拖＝移動、點一下＝打開戰情中心（網頁本身不收滑鼠）
        let grip = MiniGrip(frame: root.bounds)
        grip.autoresizingMask = [.width, .height]
        grip.onClick = { [weak h] in h?.openBoard() }
        root.addSubview(grip)
        p.contentView = root
        p.orderFrontRegardless()
        panel = p; host = h
    }

    func bounce() { host?.bounce() }

    func hide() {
        host?.tearDown(); host = nil
        panel?.orderOut(nil); panel = nil
    }

    private func origin() -> NSPoint {
        if BoardWindow.testMode { return NSPoint(x: -4000, y: -4000) }
        if let s = Self.defaults?.string(forKey: "sphere.mini.origin") {
            let p = NSPointFromString(s)
            // 存的位置還在某個螢幕上才用（外接螢幕拔掉了就回預設）
            if NSScreen.screens.contains(where: { $0.visibleFrame.insetBy(dx: -40, dy: -40).contains(p) }) { return p }
        }
        let v = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        return NSPoint(x: v.maxX - Self.size.width - 24, y: v.minY + 24)
    }

    func windowDidMove(_ n: Notification) {
        guard !BoardWindow.testMode, let p = panel else { return }
        Self.defaults?.set(NSStringFromPoint(p.frame.origin), forKey: "sphere.mini.origin")
    }
}

/// 拖曳面：按下後有移動＝拖視窗；沒移動就放開＝點擊
final class MiniGrip: NSView {
    var onClick: (() -> Void)?
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with e: NSEvent) {
        guard let w = window else { return }
        let before = w.frame.origin
        w.performDrag(with: e)          // 跑到放開為止
        if w.frame.origin == before { onClick?() }
    }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
}

// MARK: - 按住球講話（v3 #2）

/// 本機語音辨識（台灣中文）：麥克風 → SFSpeechRecognizer，中間結果一直回報；finish() 收尾拿最後一句。
/// 不存音檔、能本機辨識就強制本機（requiresOnDeviceRecognition）；音訊不離開這台 Mac。
final class SphereListener: @unchecked Sendable {
    typealias Report = @Sendable (_ text: String, _ final: Bool, _ error: String?) -> Void
    private let report: Report
    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var last = ""
    private var done = false
    private let lock = NSLock()

    init(_ report: @escaping Report) { self.report = report }

    func start() {
        SFSpeechRecognizer.requestAuthorization { st in
            guard st == .authorized else {
                self.report("", true, st == .denied || st == .restricted
                    ? "沒有語音辨識權限：到「系統設定 › 隱私權與安全性 › 語音辨識」打開 ShoWork42 戰情中心。"
                    : "語音辨識還沒授權。")
                return
            }
            DispatchQueue.main.async { self.begin() }
        }
    }

    private func begin() {
        guard let rec = SFSpeechRecognizer(locale: Locale(identifier: "zh-TW")), rec.isAvailable else {
            return report("", true, "這台 Mac 現在不能辨識中文語音。")
        }
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        if rec.supportsOnDeviceRecognition { req.requiresOnDeviceRecognition = true }
        request = req
        let input = engine.inputNode
        let fmt = input.outputFormat(forBus: 0)
        guard fmt.sampleRate > 0 else { return report("", true, "找不到麥克風。") }
        nonisolated(unsafe) let r = req
        input.installTap(onBus: 0, bufferSize: 1024, format: fmt) { buf, _ in r.append(buf) }
        engine.prepare()
        do { try engine.start() } catch { return report("", true, "麥克風開不起來：\(error.localizedDescription)") }
        task = rec.recognitionTask(with: req) { [weak self] res, err in
            guard let self else { return }
            self.lock.lock()
            if self.done { self.lock.unlock(); return }
            if let res { self.last = res.bestTranscription.formattedString }
            let final = res?.isFinal == true || err != nil
            if final { self.done = true }
            let text = self.last
            self.lock.unlock()
            if final { self.teardown() }
            self.report(text, final, nil)
        }
    }

    /// 放開球：停止收音，等辨識器給最後結果（最多 2 秒）
    func finish() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        request?.endAudio()
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            if self.done { self.lock.unlock(); return }
            self.done = true
            let text = self.last
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
