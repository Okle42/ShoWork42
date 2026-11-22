import Accelerate
import AVFoundation
import Foundation

// 球體 v5（11-22 使用者：講話時要看得到聲波）：播報改走自己的 AVAudioEngine，才拿得到「真的」聲音。
//   - Mac 內建語音：AVSpeechSynthesizer.write(_:toBufferCallback:toMarkerCallback:) 先合成成 PCM 再自己播，
//     marker 帶每個詞在音訊裡的位置 ⇒ 字幕跟「唸到哪」逐詞同步（不是估的）
//   - 微軟神經語音（edge-tts mp3）：AVAudioFile 播，字幕照播放進度比例出字
//   - 主混音器掛 tap 做 FFT ⇒ 每 1/30 秒把 32 段頻譜＋音量推給網頁畫聲波
// ⚠ 不准用使用者本人的聲音；這裡只播合成語音。

/// 1024 點 FFT → 32 段對數頻帶（80 Hz–8 kHz）＋ RMS，數值都壓到 0…1
final class SphereSpectrum: @unchecked Sendable {
    static let bandCount = 32
    private let n = 1024
    private let fft = vDSP.FFT(log2n: 10, radix: .radix2, ofType: DSPSplitComplex.self)!
    private let window: [Float]
    private var buf: [Float]
    private var real: [Float]
    private var imag: [Float]
    private var mags: [Float]

    init() {
        window = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized, count: 1024, isHalfWindow: false)
        buf = .init(repeating: 0, count: 1024)
        real = .init(repeating: 0, count: 512); imag = .init(repeating: 0, count: 512); mags = .init(repeating: 0, count: 512)
    }

    func analyze(_ p: UnsafePointer<Float>, count: Int, sampleRate: Double) -> (bands: [Float], rms: Float) {
        let m = min(count, n)
        guard m > 0 else { return (.init(repeating: 0, count: Self.bandCount), 0) }
        var rms: Float = 0
        vDSP_rmsqv(p, 1, &rms, vDSP_Length(m))
        for i in 0..<n { buf[i] = i < m ? p[i] * window[i] : 0 }
        real.withUnsafeMutableBufferPointer { rp in
            imag.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                buf.withUnsafeBufferPointer { bp in
                    bp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: n / 2) { vDSP_ctoz($0, 2, &split, 1, vDSP_Length(n / 2)) }
                }
                fft.forward(input: split, output: &split)
                vDSP_zvmags(&split, 1, &mags, 1, vDSP_Length(n / 2))
            }
        }
        let binHz = sampleRate / Double(n)
        let lo = 80.0, hi = min(8000.0, sampleRate / 2 - binHz)
        var out = [Float](repeating: 0, count: Self.bandCount)
        for b in 0..<Self.bandCount {
            let f0 = lo * pow(hi / lo, Double(b) / Double(Self.bandCount))
            let f1 = lo * pow(hi / lo, Double(b + 1) / Double(Self.bandCount))
            let i0 = max(1, Int(f0 / binHz)), i1 = max(i0 + 1, Int(f1 / binHz))
            var s: Float = 0
            for i in i0..<min(i1, n / 2) { s += mags[i] }
            let pw = s / Float(max(1, i1 - i0))
            // 校正（11-22 用曉臻 mp3 實測）：說話時中位數約 0.3、p90 約 0.8，留一點頂到 1 的空間
            let db = 10 * log10(pw + 1e-9)
            out[b] = max(0, min(1, (db + 18) / 56))
        }
        return (out, min(1, rms * 4))
    }
}

@MainActor
final class SphereAudio {
    /// 頻譜（32 段）、音量、已播秒數、總秒數（未知 = nil）
    var onLevels: (([Float], Float, Double, Double?) -> Void)?
    /// 唸到第幾個字（UTF-16 位置、長度）
    var onWord: ((Int, Int) -> Void)?
    /// "start" / "end"
    var onEvent: ((String) -> Void)?

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let synth = AVSpeechSynthesizer()
    private let spectrum = SphereSpectrum()
    private let lock = NSLock()
    nonisolated(unsafe) private var latest: (bands: [Float], rms: Float) = (.init(repeating: 0, count: SphereSpectrum.bandCount), 0)
    private var ticker: Timer?
    private var gen = 0
    private var format: AVAudioFormat?
    private var scheduled: AVAudioFramePosition = 0
    private var synthDone = false
    private var markers: [(frame: AVAudioFramePosition, loc: Int, len: Int)] = []
    private var started = false
    private var duration: Double?

    init() {
        engine.attach(player)
        let mixer = engine.mainMixerNode
        let fmt = mixer.outputFormat(forBus: 0)
        mixer.installTap(onBus: 0, bufferSize: 1024, format: fmt) { [weak self] buf, _ in
            guard let self, let ch = buf.floatChannelData?[0] else { return }
            let r = self.spectrum.analyze(ch, count: Int(buf.frameLength), sampleRate: fmt.sampleRate)
            self.lock.lock(); self.latest = r; self.lock.unlock()
        }
    }

    var isPlaying: Bool { started }

    /// Mac 內建語音：合成成 PCM，邊合成邊排進播放器；marker 記下每個詞的取樣位置
    func speak(_ u: AVSpeechUtterance) {
        stop()
        gen += 1; let g = gen
        synth.write(u, toBufferCallback: { [weak self] b in
            MainActor.assumeIsolated {
                guard let self, g == self.gen, let pcm = b as? AVAudioPCMBuffer else { return }
                if pcm.frameLength == 0 { self.synthDone = true; return }
                if self.format == nil { self.begin(format: pcm.format) }
                self.player.scheduleBuffer(pcm)
                self.scheduled += AVAudioFramePosition(pcm.frameLength)
                if !self.started { self.play() }
            }
        }, toMarkerCallback: { [weak self] ms in
            MainActor.assumeIsolated {
                guard let self, g == self.gen else { return }
                for m in ms where m.mark == .word {
                    // byteSampleOffset 是位元組：系統語音給 Float32 單聲道 ⇒ 除以每格位元組數
                    let bpf = AVAudioFramePosition(self.format?.streamDescription.pointee.mBytesPerFrame ?? 4)
                    self.markers.append((AVAudioFramePosition(m.byteSampleOffset) / max(1, bpf), m.textRange.location, m.textRange.length))
                }
            }
        })
    }

    /// 微軟神經語音的 mp3
    func play(file url: URL) -> Bool {
        stop()
        gen += 1
        guard let f = try? AVAudioFile(forReading: url) else { return false }
        begin(format: f.processingFormat)
        player.scheduleFile(f, at: nil)
        scheduled = f.length
        synthDone = true
        duration = Double(f.length) / f.processingFormat.sampleRate
        play()
        return true
    }

    func stop() {
        gen += 1
        let was = started
        ticker?.invalidate(); ticker = nil
        synth.stopSpeaking(at: .immediate)
        player.stop()
        engine.stop()            // 效能（11-22）：沒在唸就關掉音訊引擎（不然 tap 一直對靜音做 FFT、音訊硬體也不休息）
        started = false; format = nil; scheduled = 0; synthDone = false; markers = []; duration = nil
        if was { onEvent?("end") }
    }

    private func begin(format f: AVAudioFormat) {
        format = f
        engine.stop()
        engine.disconnectNodeOutput(player)
        engine.connect(player, to: engine.mainMixerNode, format: f)
        engine.prepare()
        try? engine.start()
    }

    private func play() {
        started = true
        player.play()
        onEvent?("start")
        ticker = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    private func tick() {
        guard started, let f = format else { return }
        var pos: AVAudioFramePosition = 0
        if let nt = player.lastRenderTime, let pt = player.playerTime(forNodeTime: nt) { pos = max(0, pt.sampleTime) }
        while let m = markers.first, m.frame <= pos { markers.removeFirst(); onWord?(m.loc, m.len) }
        lock.lock(); let l = latest; lock.unlock()
        // Mac 語音邊合成邊播、一開始不知道總長；合成比播放快很多，合成完就知道了 ⇒ 網頁可以照播放進度出字（逐詞 marker 再補準）
        let total = duration ?? (synthDone ? Double(scheduled) / f.sampleRate : nil)
        onLevels?(l.bands, l.rms, Double(pos) / f.sampleRate, total)
        if synthDone && pos >= scheduled {
            // 唸完：剩下的 marker 一次補完，讓字幕停在整句
            for m in markers { onWord?(m.loc, m.len) }
            markers = []
            ticker?.invalidate(); ticker = nil
            player.stop()
            engine.stop()
            started = false; format = nil
            onLevels?(.init(repeating: 0, count: SphereSpectrum.bandCount), 0, Double(pos) / f.sampleRate, duration)
            onEvent?("end")
        }
    }
}
