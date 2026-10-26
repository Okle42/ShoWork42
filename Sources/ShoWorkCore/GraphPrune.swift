import Foundation

// 圖譜輸出的大小上限（10-22 隊長 Chris：內建碟剩 21G，Graphify 自動跑的輸出別變成下一個肥的）。
// 每個專案本來就只留一份（重跑會覆蓋），會長大的只有「專案資料夾越積越多」：
//   ① 不在大樓上超過 maxAge 的專案 ⇒ 丟垃圾桶
//   ② 加總還超過 cap ⇒ 從最久沒更新、不在大樓上的開始丟；全部都在大樓上還是超過 ⇒ 不動（寫 log，不刪正在用的）
public enum GraphPrune {
    public static let cap: Int64 = 300 * 1024 * 1024
    public static let maxAge: TimeInterval = 14 * 86400

    public struct Dir: Equatable, Sendable {
        public var name: String
        public var bytes: Int64
        public var modified: Date
        public var active: Bool          // 現在大樓上有這個專案
        public init(name: String, bytes: Int64, modified: Date, active: Bool) {
            self.name = name; self.bytes = bytes; self.modified = modified; self.active = active
        }
    }

    /// 要丟掉的資料夾名（先丟過期的，再照最舊的丟到不超過 cap）
    public static func pick(_ dirs: [Dir], now: Date, cap: Int64 = cap, maxAge: TimeInterval = maxAge) -> [String] {
        var out: [String] = []
        var total = dirs.reduce(Int64(0)) { $0 + $1.bytes }
        for d in dirs where !d.active && now.timeIntervalSince(d.modified) > maxAge {
            out.append(d.name); total -= d.bytes
        }
        for d in dirs.filter({ !$0.active && !out.contains($0.name) }).sorted(by: { $0.modified < $1.modified }) where total > cap {
            out.append(d.name); total -= d.bytes
        }
        return out
    }
}
