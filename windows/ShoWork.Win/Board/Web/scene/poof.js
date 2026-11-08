// OfficePoof.swift＋ShoWorkCore/Poof.swift（PoofCurve）照搬（11-02 P8）。
//
// 忍術「ドロン」過場（10-21 Kang：關掉終端機，角色在 3D 裡憑空消失很突兀）。
//   離開：角色位置「砰」地爆出一團白灰體素煙（10 顆方塊往外往上擴散、放大、淡出），角色在煙最濃時縮到 0，0.8 秒後整團節點移除。
//   出現：反過來，先冒煙、角色從煙裡彈出來（略大再回原尺寸）。
// 曲線在 PoofCurve（純函式，Mac 有單元測試）；Poof 只是節點。一次性動作（customAction＋removeFromParentNode），不常駐；
// 煙的方塊共用一個 geometry＋一個材質（一個 draw call 一顆，0.8 秒內最多 10 個）。

import * as THREE from "three";
import { VoxMat, scnNode, setEuler, setOpacity } from "../kit.js";
import { Act, runAction, removeAllActions } from "./actions.js";

// MARK: - PoofCurve（ShoWorkCore/Poof.swift）

/// 忍術「ドロン」過場（10-21）：角色離開／出現時爆出一團體素煙霧。
/// 這裡只放「第 t 秒長什麼樣」的純函式（測試、定格截圖、動畫每幀都呼叫同一套）。
///   離開：0–0.05 秒煙冒出 → 角色在煙最濃時（0.05–0.14 秒）縮到 0 → 煙往外、往上擴散放大、淡出，0.8 秒散完
///   出現：先冒煙 → 0.12 秒角色從煙裡彈出來（0.3 秒放大到 1.15 倍、0.45 秒回到 1）→ 煙散掉
export const PoofCurve = {
  duration: 0.8,
  puffs: 10,

  clamp01(x) { return Math.min(1, Math.max(0, x)); },
  easeOut(x) { const k = PoofCurve.clamp01(x); return 1 - (1 - k) * (1 - k) * (1 - k); },

  /** 第 i 顆煙的方向（固定，不用亂數：每次長一樣，截圖可比）：繞一圈平均分布、高低交錯、略往上 */
  direction(i, n) {
    const a = i / n * 2 * Math.PI + 0.3;
    const up = i % 2 === 0 ? 0.55 : 0.15;
    const v = [Math.cos(a), up, Math.sin(a)];
    const l = Math.sqrt(v[0] * v[0] + v[1] * v[1] + v[2] * v[2]);
    return [v[0] / l, v[1] / l, v[2] / l];
  },

  /** 第 i 顆煙在第 t 秒：0.05 秒內冒到最濃（不透明、0.5→1 倍），之後往外飄 1 公尺、往上 0.35、放大到 1.6 倍（桌距 1.6 公尺：不要把隔壁的人整個蓋掉），
   *  0.25 秒起淡出、0.8 秒歸零。回 { offset: [x,y,z], scale, opacity, spin } */
  puff(i, t, n = PoofCurve.puffs) {
    const d = PoofCurve.direction(i, n), D = PoofCurve.duration;
    const k = PoofCurve.clamp01(t / D);
    const burst = PoofCurve.easeOut(t / 0.18);                     // 前 0.18 秒衝出去最快
    const dist = 0.55 * burst + 0.45 * PoofCurve.easeOut(k);      // 角色身體約 1 公尺寬：一冒出來就要在身體外圍
    const rise = 0.35 * k;                                         // 不要往上穿過天花板到上一層
    const grow = t < 0.05 ? 0.5 + 0.5 * (t / 0.05) : 1 + 0.6 * PoofCurve.easeOut((t - 0.05) / (D - 0.05));
    const fadeIn = PoofCurve.clamp01(t / 0.04);
    const fadeOut = t <= 0.25 ? 1 : 1 - PoofCurve.clamp01((t - 0.25) / (D - 0.25 - 0.02));
    const size = 0.75 + 0.25 * ((i * 5) % 3) / 2;                 // 大小交錯
    return { offset: [d[0] * dist, d[1] * dist + rise, d[2] * dist],
             scale: Math.max(0, grow * size), opacity: t >= D ? 0 : fadeIn * fadeOut,
             spin: i * 0.7 + (i % 2 === 0 ? 1 : -1) * 2.4 * k };
  },

  /** 角色的大小：離開＝0.05 秒前原尺寸、0.14 秒縮到 0（帶一點轉）；出現＝0.12 秒前 0、0.3 秒 1.15 倍、0.45 秒回 1。回 { scale, spin } */
  person(t, appear) {
    if (appear) {
      if (t < 0.12) return { scale: 0, spin: 0 };
      if (t < 0.3) { const k = PoofCurve.easeOut((t - 0.12) / 0.18); return { scale: 1.15 * k, spin: 0.6 * (1 - k) }; }
      if (t < 0.45) { const k = PoofCurve.clamp01((t - 0.3) / 0.15); return { scale: 1.15 - 0.15 * k * k * (3 - 2 * k), spin: 0 }; }
      return { scale: 1, spin: 0 };
    }
    if (t < 0.05) return { scale: 1, spin: 0 };
    if (t < 0.14) { const k = PoofCurve.clamp01((t - 0.05) / 0.09); return { scale: 1 - k * k, spin: 1.2 * k }; }
    return { scale: 0, spin: 1.2 };
  },
};

// MARK: - Poof（OfficePoof.swift）

let cubeGeo = null, cubeMat = null;
// 註：節點透明度（SCNNode.opacity）由畫面迴圈每幀呼叫 actions.js 的 syncOpacity(scene) 落實

export class Poof {
  /** 共用的煙：一個 0.42 立方的方塊、一個材質（淡灰白、微微自發光：白天夜晚都看得到） */
  static get cube() {
    if (!cubeGeo) {
      cubeGeo = new THREE.BoxGeometry(0.42, 0.42, 0.42);
      const m = new THREE.MeshLambertMaterial();            // 有明暗才看得出是一顆顆方塊（.constant 會糊成一片白）
      m.userData.lm = "lambert";
      VoxMat.color(0xE4E2DD).toThree(m.color);
      VoxMat.color(0xE4E2DD).toThree(m.emissive); m.emissiveIntensity = 0.35;     // 夜晚也看得到
      m.depthWrite = false;                                  // 半透明的煙互相疊不要擋來擋去
      m.name = "poof";
      cubeMat = m;
    }
    return { geometry: cubeGeo, material: cubeMat };
  }

  /** 在 parent 裡、角色所在位置建一團煙；person＝離開時要縮掉的角色（會被搬進煙的節點底下，煙散完一起移除）／出現時要彈出來的角色。
   *  pos：[x, y, z]（parent 座標） */
  constructor(pos, parent, person, appear) {
    this.root = scnNode("poof");
    this.root.position.set(pos[0], pos[1], pos[2]);
    this.person = person ?? null; this.appear = appear;
    this.personScale = person ? person.scale.clone() : new THREE.Vector3(1, 1, 1);
    this.baseYaw = person ? person.rotation.y : 0;
    const { geometry, material } = Poof.cube;
    this.puffs = [];
    for (let i = 0; i < PoofCurve.puffs; i++) {
      // 節點透明度走 actions.js 的 syncOpacity（userData.opacity <1 時自動換成透明複本），geometry、材質照 Swift 共用
      const n = new THREE.Mesh(geometry, material); n.renderOrder = 5;
      n.userData.scn = { type: "SCNBox", params: { w: 0.42, h: 0.42, l: 0.42, chamfer: 0 } };
      this.root.add(n); this.puffs.push(n);
    }
    parent.add(this.root);
    if (person && !appear) {
      // 離開：角色搬進煙的節點底下（位置不變），煙散完整團一起移除
      this.root.attach(person);
    }
  }

  /** 第 t 秒的樣子（定格截圖、動畫每幀都呼叫）。煙的中心在角色身體中間（1 公尺；坐著的 Kubo 身體約 1 公尺寬，煙一冒出來就要包住身體） */
  apply(t) {
    this.puffs.forEach((n, i) => {
      const p = PoofCurve.puff(i, t);
      n.position.set(p.offset[0], p.offset[1] + 1.0, p.offset[2]);
      n.scale.setScalar(p.scale);
      setEuler(n, 0.35, p.spin, 0.2);
      setOpacity(n, p.opacity);
      n.visible = !(p.opacity <= 0.001);
    });
    if (this.person) {
      const s = PoofCurve.person(t, this.appear);
      this.person.scale.set(this.personScale.x * s.scale, this.personScale.y * s.scale, this.personScale.z * s.scale);
      this.person.visible = !(s.scale <= 0.001);
      this.person.rotation.y = this.baseYaw + s.spin;
    }
  }

  /** 播一次：0.8 秒後拿掉煙（離開的話角色也一起）；出現的角色回到原尺寸、留在原位 */
  run() {
    this.apply(0);
    const a = Act.customAction(PoofCurve.duration, (_, el) => this.apply(el));
    const finish = Act.run(() => { queueMicrotask(() => this.finish()); });
    runAction(this.root, Act.sequence([a, finish]), "poof");
  }

  finish() {
    removeAllActions(this.root);
    if (this.appear && this.person) { this.person.visible = true; this.person.scale.copy(this.personScale); this.person.rotation.y = this.baseYaw; }
    this.root.removeFromParent();
  }
}
