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

    @Test("6–11 may overlap, but EVERY window keeps a ≥120pt exclusive square (clickable in any stacking order)", arguments: 1...11)
    func alwaysClickable(n: Int) {
        let f = LayoutPlan.frames(count: n, in: area)
        for i in f.indices {
            let s = Self.exclusiveSquare(i, f)
            #expect(s >= LayoutPlan.minExclusive - 8, "n=\(n) window \(i) exclusive only \(s)pt")
        }
    }

    @Test("overlap buys height: 6–8 windows are much taller than a non-overlapping 2-row grid", arguments: 6...8)
    func overlapTaller(n: Int) {
        #expect(LayoutPlan.frames(count: n, in: area).allSatisfy { $0.height >= 800 })
    }

    @Test("9–11: quarter width, 4-3-4 with the middle row shifted half a window", arguments: 9...11)
    func staggerShape(n: Int) {
        let f = LayoutPlan.frames(count: n, in: area)
        #expect(f.allSatisfy { $0.width == 480 })
        #expect(f[4].minX == 240 && f[4].minY > f[0].minY)
    }
}
