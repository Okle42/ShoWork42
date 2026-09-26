import CoreGraphics

/// Pure window-layout geometry (top-left origin, like AX). No windows are touched here.
public enum LayoutPlan {
    public enum FourStyle: String, Sendable, Codable { case columns, grid }

    /// Keng 09-26 (decision boards): from 6 windows up windows overlap (6–7: his brick layout). All overlapping windows are the
    /// SAME height = area − rowReveal (the 2-row layout he approved: each row reveals 300pt). With 3 rows
    /// the rows spread evenly (step 150). No window gets lost because the arranger keeps the stacking
    /// canonical — top row < middle row < bottom row, the window you're using on top of all.
    public static let rowReveal: CGFloat = 300

    /// rowReveal / brickStep were tuned on Keng's 1080p screen (visible height 960–970). Taller screens
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
        case 6, 7: return brick(n, in: area)                                          // Keng's own hand-made layout, squared up
        case 8: return overlapRows([4, 4], in: area, halfShiftMiddle: false)
        default: return Array(overlapRows([4, 3, 4], in: area, halfShiftMiddle: true, extra: max(0, n - 11)).prefix(n))
        }
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

    /// Keng 09-26 arranged 7 windows by hand like bricks: quarter-width windows, top row in columns
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
