import Foundation

/// 背景長工作的即時進度（10-26）：AI 在背景跑測試、稽核時，卡片每輪才更新一次，看起來像停了。
/// AI 自己每隔幾秒寫 `~/.claude/run/progress/<任意檔名>.json`，一個工作一個檔：
/// `{"name":"小明","label":"稽核（畫面）","done":12,"total":37,"updatedAt":1792955900,"pct":32,"eta":"4 分","updated":1792955900}`
/// name＝showork names 的英文名（舊檔沒有就用 label 開頭的名字比對）；pct／eta／updated 是給終端機狀態列讀的舊欄位。
/// 超過 10 分鐘沒更新就不算（跟狀態列一致）。
public struct RunProgress: Sendable, Equatable {
    public var name: String?
    public var label: String
    public var done: Int?
    public var total: Int?
    public var eta: String?
    public var updatedAt: Date
    /// 0–1
    public var fraction: Double

    public static let staleAfter: TimeInterval = 600

    public init(name: String?, label: String, done: Int?, total: Int?, eta: String?, updatedAt: Date, fraction: Double) {
        self.name = name; self.label = label; self.done = done; self.total = total; self.eta = eta
        self.updatedAt = updatedAt; self.fraction = min(max(fraction, 0), 1)
    }

    public static func parse(_ d: Data) -> RunProgress? {
        guard let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return nil }
        func num(_ k: String) -> Double? { (o[k] as? NSNumber)?.doubleValue }
        guard let t = num("updatedAt") ?? num("updated") else { return nil }
        let done = num("done").map { Int($0) }, total = num("total").map { Int($0) }
        let f: Double
        if let done, let total, total > 0 { f = Double(done) / Double(total) }
        else if let p = num("pct") { f = p / 100 }
        else { return nil }
        let name = (o["name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let eta = (o["eta"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return RunProgress(name: name, label: o["label"] as? String ?? "", done: done, total: total, eta: eta,
                           updatedAt: Date(timeIntervalSince1970: t), fraction: f)
    }

    public func fresh(_ now: Date = Date()) -> Bool { now.timeIntervalSince(updatedAt) <= Self.staleAfter }

    /// 這個工作是不是 name 的：有 name 欄位就只看它；沒有就看 label 是不是以名字開頭
    public func belongs(to who: String) -> Bool {
        guard !who.isEmpty else { return false }
        if let name { return name.caseInsensitiveCompare(who) == .orderedSame }
        return label.hasPrefix(who + " ") || label.hasPrefix(who + "：") || label.hasPrefix(who + "-")
    }

    /// 某個 AI 現在的進度：沒過期的裡面 updatedAt 最新的一個
    public static func pick(_ all: [RunProgress], for who: String, now: Date = Date()) -> RunProgress? {
        all.filter { $0.belongs(to: who) && $0.fresh(now) }.max { $0.updatedAt < $1.updatedAt }
    }

    /// 進度條旁的字：label 拿掉開頭的名字，接 12/37 或 32%，有 eta 再接「還要 4 分」
    public func caption(for who: String) -> String {
        var l = label
        if name == nil, l.hasPrefix(who) { l = String(l.dropFirst(who.count)).trimmingCharacters(in: CharacterSet(charactersIn: " ：-")) }
        let n = done.flatMap { d in total.map { "\(d)/\($0)" } } ?? "\(Int((fraction * 100).rounded()))%"
        // 舊格式的 label 自己帶了「10/37」就不重複
        let parts = [l, l.contains(n) ? nil : n, eta.map { "還要 \($0)" }].compactMap { $0 }.filter { !$0.isEmpty }
        return parts.joined(separator: " ")
    }

    public static func load(dir: String) -> [RunProgress] {
        let fm = FileManager.default
        return ((try? fm.contentsOfDirectory(atPath: dir)) ?? []).filter { $0.hasSuffix(".json") }
            .compactMap { fm.contents(atPath: dir + "/" + $0).flatMap(parse) }
    }
}
