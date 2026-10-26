import CoreGraphics
import Testing
@testable import ShoWorkCore

@Suite("戰情中心旁的撲克牌排版")
struct NarrowLayoutTests {
    // 10-08 實際配置：中間螢幕（電視）可用區 x -1920…0、y 0…1080；戰情中心在左半邊
    let tv = CGRect(x: -1920, y: 0, width: 1920, height: 1080)
    let board = CGRect(x: -1920, y: 30, width: 961, height: 1050)

    @Test("扣掉戰情中心：留右側；沒擋到、太窄、沒開都用整個螢幕")
    func reserve() {
        #expect(LayoutPlan.area(tv, avoiding: board) == CGRect(x: -959, y: 30, width: 959, height: 1050))   // 上下對齊戰情中心
        #expect(LayoutPlan.area(tv, avoiding: CGRect(x: -400, y: 0, width: 400, height: 1080)) == CGRect(x: -1920, y: 0, width: 1520, height: 1080))   // 放右邊就留左邊
        #expect(LayoutPlan.area(tv, avoiding: nil) == tv)
        #expect(LayoutPlan.area(tv, avoiding: CGRect(x: 0, y: 0, width: 800, height: 900)) == tv)            // 在別的螢幕
        #expect(LayoutPlan.area(tv, avoiding: CGRect(x: -1900, y: 0, width: 600, height: 300)) == tv)        // 只擋一小塊
        #expect(LayoutPlan.area(tv, avoiding: CGRect(x: -1800, y: 0, width: 1600, height: 1080)) == tv)      // 剩下不到 400
    }

    @Test("撲克牌 1–20 張：都在區內、左上到右下、後面的不蓋住前面的標題列", arguments: 1...20)
    func cascade(n: Int) {
        let a = LayoutPlan.area(tv, avoiding: board)
        let f = LayoutPlan.cascade(n, in: a)
        #expect(f.count == n)
        for r in f { #expect(a.insetBy(dx: -1, dy: -1).contains(r)) }
        if n == 1 { #expect(abs(f[0].midX - a.midX) <= 1 && abs(f[0].midY - a.midY) <= 1) }
        if n >= 2 {
            #expect(abs(f[0].minX - a.minX) <= 1 && abs(f[0].minY - a.minY) <= 1)        // 第一張貼左上
            #expect(abs(f[n - 1].maxX - a.maxX) <= 1 && abs(f[n - 1].maxY - a.maxY) <= 1) // 最後一張貼右下
            for i in 1..<n { #expect(f[i].minY - f[i - 1].minY >= 28 && f[i].minX > f[i - 1].minX) }
            #expect(f.allSatisfy { $0.height >= a.height * 0.4 - 1 && $0.width >= a.width * 0.4 - 1 })
        }
    }

    @Test("6 張的實際尺寸（10-08 電視右半邊）")
    func six() {
        let f = LayoutPlan.cascade(6, in: LayoutPlan.area(tv, avoiding: board))
        #expect(f[0] == CGRect(x: -959, y: 30, width: 719, height: 787))
        #expect(f[5].maxX == 0 && f[5].maxY == 1080)
        #expect(f[1].minX - f[0].minX == 48 && f[1].minY - f[0].minY >= 52)
    }

    @Test("疊放排序：有重疊才給排號")
    func rows() {
        let a = LayoutPlan.area(tv, avoiding: board)
        #expect(LayoutPlan.overlapRows(of: LayoutPlan.cascade(4, in: a)) == [0, 1, 2, 3])
        #expect(LayoutPlan.overlapRows(of: LayoutPlan.cascade(1, in: a)) == nil)
        #expect(LayoutPlan.overlapRows(of: LayoutPlan.frames(count: 3, in: tv)) == nil)        // 全螢幕 3 欄不重疊
    }

    @Test("寬螢幕照舊（沒開戰情中心時）")
    func wideUnchanged() {
        #expect(LayoutPlan.frames(count: 6, in: tv) == LayoutPlan.brick(6, in: tv))
    }
}
