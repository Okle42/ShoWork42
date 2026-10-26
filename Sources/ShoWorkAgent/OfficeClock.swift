import Foundation

/// 3D 辦公室燈光用的時鐘（10-21 日出日落）。
/// 測試視窗可設 SHOWORK_OFFICE_TIME=HH:MM（今天）或 YYYY-MM-DDTHH:MM 假裝時間（凍結，不往前走）；
/// 再加 SHOWORK_OFFICE_TIME_RUN=1 ⇒ 從那個時間開始照真實速度往前走（量晨昏每分鐘更新的 CPU）。正式版一律真實時間
@MainActor
enum OfficeClock {
    private static let start: Date? = {
        guard BoardWindow.testMode, let s = ProcessInfo.processInfo.environment["SHOWORK_OFFICE_TIME"] else { return nil }
        return parse(s)
    }()
    private static let running = start != nil && ProcessInfo.processInfo.environment["SHOWORK_OFFICE_TIME_RUN"] != nil
    private static let offset = start.map { $0.timeIntervalSinceNow } ?? 0
    /// 凍結的假時間（有值＝畫面不排下一次更新）
    static var fixed: Date? { running ? nil : start }

    static func now() -> Date { fixed ?? Date().addingTimeInterval(offset) }

    static func parse(_ s: String, today: Date = Date(), calendar: Calendar = .current) -> Date? {
        let parts = s.split(separator: "T")
        let hm = (parts.last ?? "").split(separator: ":").compactMap { Int($0) }
        guard hm.count == 2 else { return nil }
        var day = today
        if parts.count == 2 {
            let ymd = parts[0].split(separator: "-").compactMap { Int($0) }
            guard ymd.count == 3, let d = calendar.date(from: DateComponents(year: ymd[0], month: ymd[1], day: ymd[2])) else { return nil }
            day = d
        }
        return calendar.date(bySettingHour: hm[0], minute: hm[1], second: 0, of: day)
    }
}
