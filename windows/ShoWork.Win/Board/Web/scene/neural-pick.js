// ShoWorkCore/NeuralPick.swift 照搬（11-02 P8）。純數字、不碰 three；向量一律 [x, y, z]。
//
// 地下室 B1 神經網路的點擊判定（10-22 Kang：「點中間那一坨神經網路，應該要可以用它原本應用的功能」）。
// 純數字、可測：畫面把滑鼠那一點轉成一條射線（已換到圖譜自己的座標：原點＝圖譜中心、跟著自轉），
// 先跟包住整團的球做交點（沒穿過就不算點到），再找離射線最近的節點 ⇒ 那個節點屬於哪個專案就開哪個專案的 Graphify 圖譜。

const dot = (a, b) => a[0] * b[0] + a[1] * b[1] + a[2] * b[2];
const sub = (a, b) => [a[0] - b[0], a[1] - b[1], a[2] - b[2]];
const len2 = a => dot(a, a);
const len = a => Math.sqrt(len2(a));

export const NeuralPick = {
  /** 射線（origin＋t·dir，t ≥ 0）跟球的第一個交點 t；沒交到回 null。原點在球裡回 0 */
  raySphere(o, d, c, r) {
    const l2 = len2(d);
    if (!(l2 > 1e-18) || !(r > 0)) return null;
    const oc = sub(o, c);
    // |oc + t·d|² = r² ⇒ len2·t² + 2(oc·d)·t + (|oc|² − r²) = 0
    const b = dot(oc, d), cc = len2(oc) - r * r;
    if (cc <= 0) return 0;                            // 從球裡面射出去
    const disc = b * b - l2 * cc;
    if (!(disc >= 0)) return null;
    const t = (-b - Math.sqrt(disc)) / l2;
    return t >= 0 ? t : null;                         // 球在背後
  },

  /** 點到射線（t ≥ 0 那半條）的距離 */
  distance(p, o, d) {
    const l2 = len2(d);
    if (!(l2 > 1e-18)) return len(sub(p, o));
    const t = Math.max(0, dot(sub(p, o), d) / l2);
    return len(sub(p, [o[0] + t * d[0], o[1] + t * d[1], o[2] + t * d[2]]));
  },

  /** 離射線最近的節點索引（只看 `maxDistance` 以內的；距離差不多（0.02 公尺內）取比較靠近鏡頭的）。沒有節點回 null */
  nearest(points, o, d, maxDistance = Infinity) {
    const l2 = len2(d);
    let best = null;
    points.forEach((p, i) => {
      const dist = NeuralPick.distance(p, o, d);
      if (!(dist <= maxDistance)) return;
      const t = l2 > 1e-18 ? dot(sub(p, o), d) / l2 : 0;
      if (best) {
        if (dist < best.dist - 0.02 || (Math.abs(dist - best.dist) <= 0.02 && t < best.t)) best = { i, dist, t };
      } else best = { i, dist, t };
    });
    return best ? best.i : null;
  },

  /** 整套判定：射線穿過半徑 `radius`（圖譜半徑＋一點寬容）的球 ⇒ 回離射線最近的節點索引；沒穿過或沒節點回 null */
  pick(points, o, d, radius) {
    if (!points.length || NeuralPick.raySphere(o, d, [0, 0, 0], radius) === null) return null;
    return NeuralPick.nearest(points, o, d);
  },
};
