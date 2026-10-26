import Foundation
import Testing
import simd
@testable import ShoWorkCore

// 地下室 B1 點神經網路（10-22）：射線與球、離射線最近的節點、節點找回專案
@Suite struct NeuralPickTests {
    @Test func raySphereHitsMissesAndBehind() {
        // 從 z=+10 往 −z 射，半徑 2 的球在原點 ⇒ t＝8（方向沒正規化也對）
        let t = NeuralPick.raySphere(origin: SIMD3(0, 0, 10), dir: SIMD3(0, 0, -2), center: .zero, radius: 2)
        #expect(t != nil && abs(t! - 4) < 1e-9)      // dir 長度 2 ⇒ t 4 ＝ 走 8 公尺
        // 偏 3 公尺：擦不到
        #expect(NeuralPick.raySphere(origin: SIMD3(3, 0, 10), dir: SIMD3(0, 0, -1), center: .zero, radius: 2) == nil)
        // 球在背後
        #expect(NeuralPick.raySphere(origin: SIMD3(0, 0, 10), dir: SIMD3(0, 0, 1), center: .zero, radius: 2) == nil)
        // 從球裡面射
        #expect(NeuralPick.raySphere(origin: SIMD3(0, 0.5, 0), dir: SIMD3(1, 0, 0), center: .zero, radius: 2) == 0)
        // 零向量不算
        #expect(NeuralPick.raySphere(origin: SIMD3(0, 0, 10), dir: .zero, center: .zero, radius: 2) == nil)
    }

    @Test func distanceToHalfRay() {
        let o = SIMD3<Double>(0, 0, 0), d = SIMD3<Double>(1, 0, 0)
        #expect(abs(NeuralPick.distance(SIMD3(5, 3, 0), origin: o, dir: d) - 3) < 1e-9)
        // 在射線起點後面：距離量到起點
        #expect(abs(NeuralPick.distance(SIMD3(-4, 3, 0), origin: o, dir: d) - 5) < 1e-9)
    }

    @Test func nearestPrefersClosestToRayThenCamera() {
        let o = SIMD3<Double>(0, 0, 10), d = SIMD3<Double>(0, 0, -1)
        let pts: [SIMD3<Double>] = [SIMD3(0.5, 0, 0), SIMD3(0.1, 0, -1), SIMD3(0.1, 0, 1), SIMD3(2, 2, 0)]
        // 1、2 離射線一樣近 ⇒ 取靠鏡頭的 2（z=1）
        #expect(NeuralPick.nearest(pts, origin: o, dir: d) == 2)
        #expect(NeuralPick.nearest(pts, origin: o, dir: d, maxDistance: 0.05) == nil)
        #expect(NeuralPick.nearest([], origin: o, dir: d) == nil)
    }

    @Test func pickNeedsSphereHit() {
        let pts: [SIMD3<Double>] = [SIMD3(1, 0, 0), SIMD3(-1, 0, 0)]
        let d = SIMD3<Double>(0, 0, -1)
        #expect(NeuralPick.pick(pts, origin: SIMD3(0.9, 0, 10), dir: d, radius: 1.5) == 0)
        #expect(NeuralPick.pick(pts, origin: SIMD3(-0.9, 0, 10), dir: d, radius: 1.5) == 1)
        // 射線沒穿過球（偏 3 公尺）⇒ 沒點到，就算有節點也不認
        #expect(NeuralPick.pick(pts, origin: SIMD3(3, 0, 10), dir: d, radius: 1.5) == nil)
        #expect(NeuralPick.pick([], origin: SIMD3(0, 0, 10), dir: d, radius: 1.5) == nil)
    }

    @Test func dotsRememberProjectBeyondPalette() {
        // 專案比調色盤多 ⇒ 顏色會循環，但 project 索引不循環（點擊才找得回是哪個專案）
        let names = ["A", "B", "C"]
        let g = NeuralGraph(nodes: names.enumerated().map { .init(id: $1, label: $1, project: $1, degree: 1, x: Double($0)) }, edges: [])
        let p = g.placement(palette: 2)
        #expect(p.dots.map(\.color) == [0, 1, 0])
        #expect(p.dots.map(\.project) == [0, 1, 2])
        #expect(p.dots.map { p.projects[$0.project] } == names)
    }
}
