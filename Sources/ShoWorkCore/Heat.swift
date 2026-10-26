import Foundation

// 動畫跟機器溫度連動（10-20 Kang：「CPU 用在對的地方」）。Mac 忙或熱 ⇒ 3D 辦公室所有動畫定格，只在狀態變時重畫一次；
// 來源：cool42 的 /var/run/cool42/state.json（level：ok／warm／hot／critical）＋ macOS ProcessInfo.thermalState。
// 純邏輯放這裡可測；讀檔與通知在 ShoWorkAgent/HeatGate.swift。

public enum HeatPolicy {
    /// cool42 的等級（讀不到＝nil）
    public enum Level: String, Sendable { case ok, warm, hot, critical }
    /// 回到正常後要穩定多久才恢復動畫（防止在臨界點一直切換）
    public static let resumeAfter: TimeInterval = 60

    /// 現在算不算「熱」：cool42 warm 以上，或系統熱狀態 serious 以上（thermal：0 nominal、1 fair、2 serious、3 critical）
    public static func hot(level: Level?, thermal: Int) -> Bool {
        if thermal >= 2 { return true }
        if let level, level != .ok { return true }
        return false
    }

    /// 要不要暫停動畫。`coolSince`＝最近一次從熱變不熱的時間（還在熱就傳 nil）
    public static func paused(hotNow: Bool, wasPaused: Bool, coolSince: Date?, now: Date) -> Bool {
        if hotNow { return true }
        guard wasPaused else { return false }
        guard let t = coolSince else { return true }
        return now.timeIntervalSince(t) < resumeAfter
    }

    /// 解析 cool42 state.json 的 level（格式不對或檔案不存在＝nil）
    public static func parseLevel(_ data: Data?) -> Level? {
        guard let data, let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let s = o["level"] as? String else { return nil }
        return Level(rawValue: s)
    }
}
