import CoreGraphics

/// Pure window-layout geometry (top-left origin, like AX). No windows are touched here.
public enum LayoutPlan {
    public enum FourStyle: String, Sendable, Codable { case columns, grid }

    /// Keng 09-26 (decision boards): from 6 windows up windows overlap. All overlapping windows are the
    /// SAME height = area − rowReveal (the 2-row layout he approved: each row reveals 300pt). With 3 rows
    /// the rows spread evenly (step 150). No window gets lost because the arranger keeps the stacking
    /// canonical — top row < middle row < bottom row, the window you're using on top of all.
    public static let rowReveal: CGFloat = 300

    /// Frames for `n` windows inside `area` (the screen's visible frame, top-left origin).
    public static func frames(count n: Int, in area: CGRect, four: FourStyle = .columns) -> [CGRect] {
        guard n > 0, area.width > 0, area.height > 0 else { return [] }
        switch n {
        case 1: return [area]
        case 2, 3: return columns(n, in: area)
        case 4: return four == .columns ? columns(4, in: area) : grid(rows: [2, 2], in: area)
        case 5: return grid(rows: [3, 2], in: area)
        case 6: return overlapRows([2, 2, 2], in: area, halfShiftMiddle: false)   // Keng: 左右各三，像攤開的撲克牌
        case 7...8: return overlapRows([(n + 1) / 2, n / 2], in: area, halfShiftMiddle: false)
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
        let h = a.height - rowReveal
        let d = R > 1 ? rowReveal / CGFloat(R - 1) : 0
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

    /// Row of each frame for the canonical stacking (0 = top row, lowest in z-order).
    public static func rows(count n: Int) -> [Int] {
        switch n {
        case 6: return [0, 0, 1, 1, 2, 2]
        case 7...8: return Array(repeating: 0, count: (n + 1) / 2) + Array(repeating: 1, count: n / 2)
        case 9...: return Array(([0,0,0,0, 1,1,1, 2,2,2,2] + Array(repeating: 1, count: max(0, n - 11))).prefix(n))
        default: return Array(repeating: 0, count: n)
        }
    }
}
