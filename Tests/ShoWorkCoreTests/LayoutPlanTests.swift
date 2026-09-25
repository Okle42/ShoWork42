import Testing
import CoreGraphics
@testable import ShoWorkCore

@Suite("LayoutPlan")
struct LayoutPlanTests {
    // Keng's screen: 1920×1080, menu bar 30, Dock ≈ 80 → visible 1920×970 at y=30
    let area = CGRect(x: 0, y: 30, width: 1920, height: 970)

    @Test("every frame stays inside the visible area", arguments: 1...14)
    func inside(n: Int) {
        let f = LayoutPlan.frames(count: n, in: area)
        #expect(f.count == n)
        for r in f { #expect(area.insetBy(dx: -1, dy: -1).contains(r), "n=\(n) \(r)") }
    }

    @Test("1–5 windows never overlap", arguments: 1...5)
    func noOverlap(n: Int) {
        for style in [LayoutPlan.FourStyle.columns, .grid] {
            let f = LayoutPlan.frames(count: n, in: area, four: style)
            for i in f.indices { for j in f.indices where i < j {
                #expect(f[i].intersection(f[j]).width < 1 || f[i].intersection(f[j]).height < 1, "n=\(n) \(i)×\(j)")
            } }
        }
    }

    @Test("1–5 windows fill the area (no wasted gaps)", arguments: 1...5)
    func fills(n: Int) {
        let f = LayoutPlan.frames(count: n, in: area)
        let total = f.reduce(0) { $0 + $1.width * $1.height }
        #expect(abs(total - area.width * area.height) / (area.width * area.height) < 0.01, "n=\(n)")
    }

    @Test("4 windows: columns vs 2×2")
    func four() {
        let c = LayoutPlan.frames(count: 4, in: area, four: .columns)
        #expect(Set(c.map(\.width)) == [480] && Set(c.map(\.height)) == [970])
        let g = LayoutPlan.frames(count: 4, in: area, four: .grid)
        #expect(Set(g.map(\.width)) == [960] && Set(g.map(\.height)) == [485])
    }

    @Test("3 windows: equal thirds, full height")
    func three() {
        let f = LayoutPlan.frames(count: 3, in: area)
        #expect(f.map(\.width) == [640, 640, 640])
        #expect(f.allSatisfy { $0.height == 970 && $0.minY == 30 })
    }

    /// Largest square (side, pt) inside `r` that no OTHER frame touches — sampled on an 8pt grid.
    static func exclusiveSquare(_ i: Int, _ f: [CGRect]) -> CGFloat {
        let r = f[i], step: CGFloat = 8
        let cols = Int(r.width / step), rows = Int(r.height / step)
        guard cols > 0, rows > 0 else { return 0 }
        var best = [[Int]](repeating: [Int](repeating: 0, count: cols + 1), count: rows + 1)
        var side = 0
        for y in 0..<rows { for x in 0..<cols {
            let p = CGPoint(x: r.minX + (CGFloat(x) + 0.5) * step, y: r.minY + (CGFloat(y) + 0.5) * step)
            let free = !f.indices.contains { $0 != i && f[$0].contains(p) }
            best[y + 1][x + 1] = free ? min(best[y][x], best[y + 1][x], best[y][x + 1]) + 1 : 0
            side = max(side, best[y + 1][x + 1])
        } }
        return CGFloat(side) * step
    }

    @Test("1–5, 7, 8: every window keeps a ≥120pt exclusive square in ANY stacking order", arguments: [1, 2, 3, 4, 5, 7, 8])
    func alwaysClickable(n: Int) {
        let f = LayoutPlan.frames(count: n, in: area)
        for i in f.indices { #expect(Self.exclusiveSquare(i, f) >= 112, "n=\(n) window \(i)") }
    }

    /// Visible band height of window i when windows are stacked by row (later rows on top).
    static func visibleBand(_ i: Int, _ f: [CGRect], rows: [Int]) -> CGFloat {
        let above = f.indices.filter { $0 != i && rows[$0] > rows[i] }
        let r = f[i]
        let covering = above.map { f[$0] }.filter { $0.intersects(r) }.map(\.minY).min() ?? r.maxY
        return covering - r.minY
    }

    @Test("6, 9–11: in canonical stacking (top < middle < bottom) every window shows ≥140pt", arguments: [6, 9, 10, 11])
    func canonicalVisible(n: Int) {
        let f = LayoutPlan.frames(count: n, in: area), rows = LayoutPlan.rows(count: n)
        for i in f.indices { #expect(Self.visibleBand(i, f, rows: rows) >= 140, "n=\(n) window \(i) shows \(Self.visibleBand(i, f, rows: rows))") }
    }

    @Test("6–11: every overlapping window has the same height (Keng: 一樣高)", arguments: 6...11)
    func sameHeight(n: Int) {
        let f = LayoutPlan.frames(count: n, in: area)
        #expect(Set(f.map(\.height)).count == 1)
        #expect(f[0].height == area.height - LayoutPlan.rowReveal)
    }

    @Test("6: two half-width card piles, 3 per side, fanned downward")
    func sixCards() {
        let f = LayoutPlan.frames(count: 6, in: area)
        #expect(f.allSatisfy { $0.width == 960 })
        #expect(f.filter { $0.minX == 0 }.count == 3 && f.filter { $0.minX == 960 }.count == 3)
        #expect(Set(f.map(\.minY)).count == 3)
    }

    @Test("9–11: quarter width, 4-3-4 with the middle row shifted half a window", arguments: 9...11)
    func staggerShape(n: Int) {
        let f = LayoutPlan.frames(count: n, in: area)
        #expect(f.allSatisfy { $0.width == 480 })
        #expect(f[4].minX == 240 && f[4].minY > f[0].minY)
    }
}
