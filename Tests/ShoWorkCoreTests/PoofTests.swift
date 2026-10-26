import Foundation
import Testing
@testable import ShoWorkCore

// 10-21 忍術消失／出現的煙霧曲線（定格截圖、動畫每幀用同一套）

@Suite("Poof")
struct PoofTests {
    let n = PoofCurve.puffs

    @Test("煙：0.05 秒冒到最濃、之後往外往上擴散放大、0.8 秒完全散掉")
    func smoke() {
        for i in 0..<n {
            let a = PoofCurve.puff(i, at: 0.05), b = PoofCurve.puff(i, at: 0.4), c = PoofCurve.puff(i, at: 0.7)
            #expect(a.opacity == 1)
            #expect(b.opacity < 1 && b.opacity > c.opacity && c.opacity > 0)
            #expect(PoofCurve.puff(i, at: PoofCurve.duration).opacity == 0)
            #expect(b.scale > a.scale && c.scale > b.scale)                       // 越散越大
            let r = { (p: PoofCurve.Puff) in (p.offset.x * p.offset.x + p.offset.z * p.offset.z).squareRoot() }
            #expect(r(b) > r(a) && r(c) > r(b))                                   // 往外
            #expect(c.offset.y > a.offset.y)                                      // 往上
        }
        #expect(PoofCurve.puff(0, at: 0).opacity == 0)                            // 第 0 幀還沒冒出來
    }

    @Test("煙往四面八方：8 顆的水平方向加起來接近抵消")
    func spread() {
        var s = SIMD3<Double>(0, 0, 0)
        for i in 0..<n { s += PoofCurve.puff(i, at: 0.4).offset }
        #expect(abs(s.x) < 0.3 && abs(s.z) < 0.3)
    }

    @Test("離開：煙最濃時（0.05–0.14 秒）縮到 0，之後一直是 0")
    func vanish() {
        #expect(PoofCurve.person(at: 0, appear: false).scale == 1)
        #expect(PoofCurve.person(at: 0.1, appear: false).scale < 1)
        #expect(PoofCurve.person(at: 0.14, appear: false).scale == 0)
        #expect(PoofCurve.person(at: 0.7, appear: false).scale == 0)
    }

    @Test("出現：先只有煙，再彈出來（超過原尺寸一點）、最後回到 1")
    func appear() {
        #expect(PoofCurve.person(at: 0.05, appear: true).scale == 0)
        let peak = stride(from: 0.12, through: 0.45, by: 0.01).map { PoofCurve.person(at: $0, appear: true).scale }.max() ?? 0
        #expect(peak > 1.1 && peak <= 1.15 + 1e-9)
        #expect(PoofCurve.person(at: 0.45, appear: true).scale == 1)
        #expect(PoofCurve.person(at: PoofCurve.duration, appear: true).scale == 1)
    }
}
