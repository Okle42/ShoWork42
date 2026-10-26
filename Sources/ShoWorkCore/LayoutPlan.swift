import CoreGraphics

/// Pure window-layout geometry (top-left origin, like AX). No windows are touched here.
public enum LayoutPlan {
    public enum FourStyle: String, Sendable, Codable { case columns, grid }

    /// Kang 09-26 (decision boards): from 6 windows up windows overlap (6–7: his brick layout). All overlapping windows are the
    /// SAME height = area − rowReveal (the 2-row layout he approved: each row reveals 300pt). With 3 rows
    /// the rows spread evenly (step 150). No window gets lost because the arranger keeps the stacking
    /// canonical — top row < middle row < bottom row, the window you're using on top of all.
    public static let rowReveal: CGFloat = 300

    /// rowReveal / brickStep were tuned on Kang's 1080p screen (visible height 960–970). Taller screens
    /// (1440p, 5K…) scale them up so the layout keeps its proportions; 1080p-class and smaller screens keep
    /// the tuned values, which are what guarantee every window a band of its own.
    public static let referenceHeight: CGFloat = 1000
    static func scale(_ a: CGRect) -> CGFloat { max(1, a.height / referenceHeight) }

    /// Frames for `n` windows inside `area` (the screen's visible frame, top-left origin).
    public static func frames(count n: Int, in area: CGRect, four: FourStyle = .columns) -> [CGRect] {
        guard n > 0, area.width > 0, area.height > 0 else { return [] }
        switch n {
        case 1: return [area]
        case 2, 3: return columns(n, in: area)
        case 4: return four == .columns ? columns(4, in: area) : grid(rows: [2, 2], in: area)
        case 5: return grid(rows: [3, 2], in: area)
        case 6, 7: return brick(n, in: area)                                          // Kang's own hand-made layout, squared up
        case 8: return overlapRows([4, 4], in: area, halfShiftMiddle: false)
        default: return Array(overlapRows([4, 3, 4], in: area, halfShiftMiddle: true, extra: max(0, n - 11)).prefix(n))
        }
    }

    // MARK: 戰情中心旁邊（Kang 10-08：戰情中心放中間螢幕左側，終端機不管幾個都排在右側，像撲克牌）

    /// 螢幕可用區扣掉 `r`（戰情中心視窗）後剩下較大的那一側。`r` 沒有真的擋到（跟這個螢幕重疊不到一半高度）
    /// 或剩下的太窄（< 400pt）就不扣，照常用整個螢幕。
    public static func area(_ a: CGRect, avoiding r: CGRect?) -> CGRect {
        guard let r else { return a }
        let i = a.intersection(r)
        guard !i.isNull, i.height >= a.height * 0.5, i.width >= 100 else { return a }
        // 上下對齊戰情中心：10-08 電視回報的可用區從 y=0 開始，但系統實際把視窗推到 y=30（戰情中心也在 30），不對齊會被推歪
        let left = CGRect(x: a.minX, y: i.minY, width: i.minX - a.minX, height: i.height)
        let right = CGRect(x: i.maxX, y: i.minY, width: a.maxX - i.maxX, height: i.height)
        let best = left.width >= right.width ? left : right
        return best.width >= 400 ? best.integral : a
    }

    /// 視窗佔區域的比例（寬、高都是）
    public static let cardScale: CGFloat = 0.75
    /// 撲克牌每張至少錯開這麼多，標題列才露得出來
    public static let minCardStep: CGFloat = 30

    /// 撲克牌排法：1 個置中；2 個以上從左上到右下斜斜錯開，最後一個貼右下角，後面的疊在前面上面。
    /// 張數多到錯不開 30pt 時，視窗縮小讓出空間（最小到區域的 40%，20 張也錯得開）。
    public static func cascade(_ n: Int, in a: CGRect) -> [CGRect] {
        guard n > 0, a.width > 0, a.height > 0 else { return [] }
        var w = (a.width * cardScale).rounded(.down), h = (a.height * cardScale).rounded(.down)
        if n == 1 { return [CGRect(x: a.midX - w / 2, y: a.midY - h / 2, width: w, height: h).integral] }
        let k = CGFloat(n - 1)
        w = min(w, max(a.width * 0.4, a.width - minCardStep * k)).rounded(.down)
        h = min(h, max(a.height * 0.4, a.height - minCardStep * k)).rounded(.down)
        let dx = (a.width - w) / k, dy = (a.height - h) / k
        return (0..<n).map { CGRect(x: a.minX + CGFloat($0) * dx, y: a.minY + CGFloat($0) * dy, width: w, height: h).integral }
    }

    /// 排好的視窗有互相重疊時，每個視窗屬於第幾排（依 y 由上往下）；沒有重疊回傳 nil（不需要疊放管理）
    public static func overlapRows(of frames: [CGRect]) -> [Int]? {
        let overlapping = frames.indices.contains { i in frames.indices.contains { j in
            j > i && frames[i].insetBy(dx: 2, dy: 2).intersects(frames[j].insetBy(dx: 2, dy: 2)) } }
        guard overlapping else { return nil }
        let ys = Array(Set(frames.map { $0.minY.rounded() })).sorted()
        return frames.map { f in ys.firstIndex(of: f.minY.rounded()) ?? 0 }
    }

    static func columns(_ n: Int, in a: CGRect) -> [CGRect] {
        let w = a.width / CGFloat(n)
        return (0..<n).map { CGRect(x: a.minX + CGFloat($0) * w, y: a.minY, width: w, height: a.height).integral }
    }

    static func grid(rows: [Int], in a: CGRect) -> [CGRect] {
        let h = a.height / CGFloat(rows.count)
        return rows.enumerated().flatMap { r, count -> [CGRect] in
            let w = a.width / CGFloat(count)
            return (0..<count).map { CGRect(x: a.minX + CGFloat($0) * w, y: a.minY + CGFloat(r) * h, width: w, height: h).integral }
        }
    }

    /// Rows that overlap vertically; every window has the same height H = area − rowReveal, rows step
    /// down evenly: d = rowReveal / (R − 1). In canonical stacking (later rows on top) each row keeps a
    /// visible band of d at its top; the bottom row is fully visible.
    static func overlapRows(_ rows: [Int], in a: CGRect, halfShiftMiddle: Bool, extra: Int = 0) -> [CGRect] {
        let R = rows.count
        let reveal = (rowReveal * scale(a)).rounded()
        let h = a.height - reveal
        let d = R > 1 ? reveal / CGFloat(R - 1) : 0
        let mx = rows.max() ?? 1
        var out: [CGRect] = []
        for (r, count) in rows.enumerated() {
            let w = halfShiftMiddle ? a.width / CGFloat(mx) : a.width / CGFloat(count)
            let shift: CGFloat = (halfShiftMiddle && count < mx) ? w / 2 : 0
            for c in 0..<count {
                out.append(CGRect(x: a.minX + shift + CGFloat(c) * w, y: a.minY + CGFloat(r) * d, width: w, height: h).integral)
            }
        }
        // 12+: extra windows cascade along the middle row so their title bars stay visible
        if extra > 0, R >= 3 {
            let mid = Array(out[rows[0]..<(rows[0] + rows[1])])
            for k in 0..<extra {
                let step = CGFloat(k / mid.count + 1) * 28
                out.append(mid[k % mid.count].offsetBy(dx: min(step, 120), dy: min(step, d - 28)).integral)
            }
        }
        return out
    }

    /// Kang 09-26 arranged 7 windows by hand like bricks: quarter-width windows, top row in columns
    /// 1 & 3, middle row half-shifted (3), bottom row in columns 2 & 4, rows stepping down. Besides its
    /// top edge every window keeps a vertical strip no neighbour covers. 6 = drop the middle-centre one.
    public static let brickStep: CGFloat = 120

    static func brick(_ n: Int, in a: CGRect) -> [CGRect] {
        let step = (brickStep * scale(a)).rounded()
        let w = a.width / 4, h = a.height - 2 * step
        let xs: [[CGFloat]] = n == 7 ? [[0, 2 * w], [w / 2, 1.5 * w, 2.5 * w], [w, 3 * w]]
                                     : [[0, 2 * w], [w / 2, 2.5 * w], [w, 3 * w]]
        return xs.enumerated().flatMap { r, row in
            row.map { CGRect(x: a.minX + $0, y: a.minY + CGFloat(r) * step, width: w, height: h).integral }
        }
    }

    /// Row of each frame for the canonical stacking (0 = top row, lowest in z-order).
    public static func rows(count n: Int) -> [Int] {
        switch n {
        case 6: return [0, 0, 1, 1, 2, 2]
        case 7: return [0, 0, 1, 1, 1, 2, 2]
        case 8: return [0, 0, 0, 0, 1, 1, 1, 1]
        case 9...: return Array(([0,0,0,0, 1,1,1, 2,2,2,2] + Array(repeating: 1, count: max(0, n - 11))).prefix(n))
        default: return Array(repeating: 0, count: n)
        }
    }
}
