import CoreGraphics

/// Pure window-layout geometry (top-left origin, like AX). No windows are touched here.
public enum LayoutPlan {
    public enum FourStyle: String, Sendable, Codable { case columns, grid }

    /// Vertical step between the staggered rows in the 9–11 layout: enough to keep each
    /// window's title bar (≈28pt) plus a bit of its first line visible.
    public static let staggerStep: CGFloat = 110

    /// Frames for `n` windows inside `area` (the screen's visible frame, top-left origin).
    public static func frames(count n: Int, in area: CGRect, four: FourStyle = .columns) -> [CGRect] {
        guard n > 0, area.width > 0, area.height > 0 else { return [] }
        switch n {
        case 1: return [area]
        case 2, 3: return columns(n, in: area)
        case 4: return four == .columns ? columns(4, in: area) : grid(rows: [2, 2], in: area)
        case 5...8: return grid(rows: [(n + 1) / 2, n / 2], in: area)
        default: return stagger(n, in: area)
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

    /// Keng's 4-3-4 arrangement: quarter-width windows, top row 4, middle row 3 shifted half a
    /// window, bottom row 4; rows step down so every title bar stays visible. Extras (12+) cascade
    /// along the middle row.
    static func stagger(_ n: Int, in a: CGRect) -> [CGRect] {
        let w = a.width / 4
        let h = a.height - 2 * staggerStep
        var out: [CGRect] = []
        let top = (0..<4).map { CGRect(x: a.minX + CGFloat($0) * w, y: a.minY, width: w, height: h) }
        let mid = (0..<3).map { CGRect(x: a.minX + w / 2 + CGFloat($0) * w, y: a.minY + staggerStep, width: w, height: h) }
        let bot = (0..<4).map { CGRect(x: a.minX + CGFloat($0) * w, y: a.minY + 2 * staggerStep, width: w, height: h) }
        out = top + mid + bot
        var k = 0
        while out.count < n {                                   // 12+: cascade along the middle row
            let base = mid[k % 3]
            let step = CGFloat(k / 3 + 1) * 28
            out.append(base.offsetBy(dx: min(step, w / 2), dy: min(step, staggerStep - 28)))
            k += 1
        }
        return Array(out.prefix(n)).map(\.integral)
    }
}
