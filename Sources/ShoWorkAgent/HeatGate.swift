import Foundation
import ShoWorkCore

/// 熱就停動畫（10-20）：系統熱狀態走通知（免輪詢）；cool42 狀態檔約 5 秒改寫一次，不掛 FSEvents，掛在看板 15 秒保底上讀。
@MainActor
final class HeatGate {
    static let shared = HeatGate()
    static let changed = Notification.Name("ShoWork42.HeatGate.changed")
    static var cool42Path: String { ProcessInfo.processInfo.environment["SHOWORK_COOL42_STATE"] ?? "/var/run/cool42/state.json" }

    /// 機器熱、或停電（10-22 電廠＝AI 額度：額度用完 AI 定格）
    var paused: Bool { heatPaused || blackout }
    private var heatPaused = false
    private(set) var blackout = false
    private(set) var level: HeatPolicy.Level?
    private var coolSince: Date?
    private var wasHot = false

    private init() {
        NotificationCenter.default.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { HeatGate.shared.check() }
        }
    }

    /// 看板保底刷新時、系統熱狀態變時呼叫
    func check(now: Date = Date()) {
        if ProcessInfo.processInfo.environment["SHOWORK_HEAT"] == "off" { return set(false) }
        level = HeatPolicy.parseLevel(FileManager.default.contents(atPath: Self.cool42Path))
        let thermal = ProcessInfo.processInfo.environment["SHOWORK_HEAT"] == "hot" ? 3 : ProcessInfo.processInfo.thermalState.rawValue
        let hot = HeatPolicy.hot(level: level, thermal: thermal)
        if wasHot && !hot { coolSince = now }
        if hot { coolSince = nil }
        wasHot = hot
        set(HeatPolicy.paused(hotNow: hot, wasPaused: heatPaused, coolSince: coolSince, now: now))
        // 還在等恢復：一分鐘後再看一次（一次性，不是計時器）
        if heatPaused && !hot, let t = coolSince {
            DispatchQueue.main.asyncAfter(deadline: .now() + max(1, HeatPolicy.resumeAfter - now.timeIntervalSince(t)) + 0.5) {
                MainActor.assumeIsolated { HeatGate.shared.check() }
            }
        }
    }

    private func set(_ p: Bool) {
        guard p != heatPaused else { return }
        heatPaused = p
        Log.note("動畫\(p ? "暫停（機器熱：cool42 \(level?.rawValue ?? "—")）" : "恢復")")
        NotificationCenter.default.post(name: Self.changed, object: nil)
    }

    /// 停電：AI 定格（不管溫度）
    func setBlackout(_ b: Bool) {
        guard b != blackout else { return }
        blackout = b
        Log.note(b ? "停電：AI 額度用完，動畫定格" : "復電")
        NotificationCenter.default.post(name: Self.changed, object: nil)
    }
}
