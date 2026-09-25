import CoreGraphics

/// Pure window-layout geometry (top-left origin, like AX). No windows are touched here.
public enum LayoutPlan {
    public enum FourStyle: String, Sendable, Codable { case columns, grid }

    /// Keng 09-26: from 6 windows up, windows may overlap — but no window may ever become
    /// unclickable. Rule: every window keeps an EXCLUSIVE band (no other window's frame touches it)
    /// at least this tall, so whatever the stacking order, part of it is always on top.
    public static let minExclusive: CGFloat = 120

    /// Frames for `n` windows inside `area` (the screen's visible frame, top-left origin).
    public static func frames(count n: Int, in area: CGRect, four: FourStyle = .columns) -> [CGRect] {
        guard n > 0, area.width > 0, area.height > 0 else { return [] }
        switch n {
        case 1: return [area]
        case 2, 3: return columns(n, in: area)
        case 4: return four == .columns ? columns(4, in: area) : grid(rows: [2, 2], in: area)
        case 5: return grid(rows: [3, 2], in: area)
        case 6...8: return overlapRows([(n + 1) / 2, n / 2], in: area, halfShiftMiddle: false)
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

    /// Rows that overlap vertically. With R rows of height H stepping down by d:
    ///   top row exclusive    = d                (nobody starts above it)
    ///   bottom row exclusive = d                (nobody reaches below it)
    ///   middle rows exclusive = 2d − H          (between the row above's bottom and the row below's top)
    /// H = area − (R−1)·d; pick the smallest d that keeps every band ≥ minExclusive (tallest windows).
    static func overlapRows(_ rows: [Int], in a: CGRect, halfShiftMiddle: Bool, extra: Int = 0) -> [CGRect] {
        let R = CGFloat(rows.count), M = minExclusive
        let d = rows.count <= 2 ? M : max(M, ((a.height + M) / (R + 1)).rounded(.up))
        let h = a.height - (R - 1) * d
        var out: [CGRect] = []
        for (r, count) in rows.enumerated() {
            let w = halfShiftMiddle ? a.width / CGFloat(rows.max() ?? count) : a.width / CGFloat(count)
            let shift: CGFloat = (halfShiftMiddle && count < (rows.max() ?? count)) ? w / 2 : 0
            for c in 0..<count {
                out.append(CGRect(x: a.minX + shift + CGFloat(c) * w, y: a.minY + CGFloat(r) * d, width: w, height: h).integral)
            }
        }
        // 12+: extra windows cascade inside the middle band so their title bars stay visible
        if extra > 0, rows.count >= 3 {
            let mid = Array(out[rows[0]..<(rows[0] + rows[1])])
            for k in 0..<extra {
                let step = CGFloat(k / mid.count + 1) * 28
                out.append(mid[k % mid.count].offsetBy(dx: min(step, 120), dy: min(step, max(0, 2 * d - h - 28))).integral)
            }
        }
        return out
    }
}
