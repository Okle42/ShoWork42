import Foundation
import simd

// 地下室 B1 神經網路的點擊判定（10-22 Kang：「點中間那一坨神經網路，應該要可以用它原本應用的功能」）。
// 純數字、可測：畫面把滑鼠那一點轉成一條射線（已換到圖譜自己的座標：原點＝圖譜中心、跟著自轉），
// 先跟包住整團的球做交點（沒穿過就不算點到），再找離射線最近的節點 ⇒ 那個節點屬於哪個專案就開哪個專案的 Graphify 圖譜。

public enum NeuralPick {
    /// 射線（origin＋t·dir，t ≥ 0）跟球的第一個交點 t；沒交到回 nil。原點在球裡回 0
    public static func raySphere(origin o: SIMD3<Double>, dir d: SIMD3<Double>, center c: SIMD3<Double>, radius r: Double) -> Double? {
        let len2 = simd_length_squared(d)
        guard len2 > 1e-18, r > 0 else { return nil }
        let oc = o - c
        // |oc + t·d|² = r² ⇒ len2·t² + 2(oc·d)·t + (|oc|² − r²) = 0
        let b = simd_dot(oc, d), cc = simd_length_squared(oc) - r * r
        if cc <= 0 { return 0 }                           // 從球裡面射出去
        let disc = b * b - len2 * cc
        guard disc >= 0 else { return nil }
        let t = (-b - disc.squareRoot()) / len2
        return t >= 0 ? t : nil                           // 球在背後
    }

    /// 點到射線（t ≥ 0 那半條）的距離
    public static func distance(_ p: SIMD3<Double>, origin o: SIMD3<Double>, dir d: SIMD3<Double>) -> Double {
        let len2 = simd_length_squared(d)
        guard len2 > 1e-18 else { return simd_length(p - o) }
        let t = max(0, simd_dot(p - o, d) / len2)
        return simd_length(p - (o + t * d))
    }

    /// 離射線最近的節點索引（只看 `maxDistance` 以內的；距離差不多（0.02 公尺內）取比較靠近鏡頭的）。沒有節點回 nil
    public static func nearest(_ points: [SIMD3<Double>], origin o: SIMD3<Double>, dir d: SIMD3<Double>,
                               maxDistance: Double = .infinity) -> Int? {
        let len2 = simd_length_squared(d)
        var best: (i: Int, dist: Double, t: Double)?
        for (i, p) in points.enumerated() {
            let dist = distance(p, origin: o, dir: d)
            guard dist <= maxDistance else { continue }
            let t = len2 > 1e-18 ? simd_dot(p - o, d) / len2 : 0
            if let b = best {
                if dist < b.dist - 0.02 || (abs(dist - b.dist) <= 0.02 && t < b.t) { best = (i, dist, t) }
            } else { best = (i, dist, t) }
        }
        return best?.i
    }

    /// 整套判定：射線穿過半徑 `radius`（圖譜半徑＋一點寬容）的球 ⇒ 回離射線最近的節點索引；沒穿過或沒節點回 nil
    public static func pick(_ points: [SIMD3<Double>], origin o: SIMD3<Double>, dir d: SIMD3<Double>, radius: Double) -> Int? {
        guard !points.isEmpty, raySphere(origin: o, dir: d, center: .zero, radius: radius) != nil else { return nil }
        return nearest(points, origin: o, dir: d)
    }
}
