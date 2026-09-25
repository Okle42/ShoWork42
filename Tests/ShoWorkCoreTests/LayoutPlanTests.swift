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

    @Test("1–8 windows never overlap", arguments: 1...8)
    func noOverlap(n: Int) {
        for style in [LayoutPlan.FourStyle.columns, .grid] {
            let f = LayoutPlan.frames(count: n, in: area, four: style)
            for i in f.indices { for j in f.indices where i < j {
                #expect(f[i].intersection(f[j]).width < 1 || f[i].intersection(f[j]).height < 1, "n=\(n) \(i)×\(j)")
            } }
        }
    }

    @Test("1–8 windows fill the area (no wasted gaps)", arguments: 1...8)
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

    @Test("9–11: every title bar (top 28pt) stays visible above any later window", arguments: 9...11)
    func staggerTitles(n: Int) {
        let f = LayoutPlan.frames(count: n, in: area)
        for (i, r) in f.enumerated() {
            let title = CGRect(x: r.minX, y: r.minY, width: r.width, height: 28)
            // later windows in the list sit above earlier ones in z-order after arranging
            let covered = f[(i + 1)...].reduce(CGFloat(0)) { acc, o in acc + title.intersection(o).width * title.intersection(o).height }
            #expect(covered < title.width * title.height * 0.5, "n=\(n) window \(i) title mostly hidden")
        }
    }

    @Test("9–11: quarter width (≈60 columns) like Keng's current setup", arguments: 9...11)
    func staggerSize(n: Int) {
        #expect(LayoutPlan.frames(count: n, in: area).allSatisfy { $0.width == 480 })
    }
}
