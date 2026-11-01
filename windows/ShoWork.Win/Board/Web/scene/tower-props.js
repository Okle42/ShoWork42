// OfficeTower.swift 照搬（11-02）之一：主題家具（TowerProps）＋擺放（PropPlacer）。
// 另外帶兩個 ShoWorkCore 的東西（kit.js 沒有）：TowerTheme 的預設識別色、TowerLayout.spin／desk（桌位輪轉）。
// 方塊尺寸、座標、順序全部照抄 Swift（規範 §2；只准用色票裡的顏色）。tower.js 會把這裡的東西整包再 export 一次。

import { Kit, Xf, TP, TD, TM, TowerSpec, TowerLayout } from "../kit.js";

/** Swift 的 Float 是 32 位元：擺放判斷（AABB 碰撞的 < 比較）要跟 Mac 同一個結果，計算過程逐步捨入成 float32 */
const F = Math.fround;

// MARK: - ShoWorkCore 的 TowerTheme（只搬畫面用得到的：rawValue、預設識別色）

/** 預設識別色（規範 §2.1）；key＝TowerTheme.rawValue */
export const TowerTheme = {
  accent: {
    monitor: "#5B8DB8", app_studio: "#4E9C8F", library: "#9C6B4E", print_shop: "#C98B3C",
    call_room: "#8C7BB5", trading_desk: "#3F8F5A", media_studio: "#B5525A", design_studio: "#D08A6E",
    legal_room: "#4A5A7A", ledger_room: "#A88C3E", game_lab: "#7A5FA8", hw_lab: "#C2703A",
    marketing: "#C56B86", dispatch_room: "#3E8FA8", drafting_room: "#6E8A6A", general: "#8F8B85",
  },
  /** 不認得的 rawValue（JSON 解不出來）⇒ Swift 的 decoder 會讓整個 FloorDecor 失敗 ⇒ 當成沒有 decor（general） */
  of(raw) { return raw && Object.prototype.hasOwnProperty.call(this.accent, raw) ? raw : null; },
};

// MARK: - ShoWorkCore 的 TowerLayout.spin／desk（Wander.swift；kit.js 的 TowerLayout 只有 freeDesks）

/** 每層從不同的區開始坐：用樓層 id 雜湊出 0–3 的位移（FNV-1a 64 位元，同一層永遠一樣） */
export function towerSpin(floor) {
  if (!floor) return 0;
  let h = 0xcbf29ce484222325n;
  for (const b of new TextEncoder().encode(floor)) { h ^= BigInt(b); h = BigInt.asUintN(64, h * 0x00000100000001B3n); }
  return Number(h % 4n);
}
/** 桌心位置與朝向（12 張以內）；floor＝樓層 id（決定這層從哪一區開始坐） */
export function towerDesk(i, n, floor = "") {
  const fd = TowerLayout.freeDesks;
  i = Math.min(Math.max(i, 0), fd.length - 1);
  const k = towerSpin(floor);
  return fd[Math.trunc(i / 4) * 4 + (i % 4 + k) % 4];
}

// MARK: - 主題家具（規範 §2；方塊尺寸照抄）

/** 擺在哪一列：wall＝靠後牆、mid＝後帶前緣（z −2.2）、front＝前帶（≤0.9 高）、high＝掛牆高處、attach＝放在別的家具上 */
export const PropRow = { wall: "wall", mid: "mid", front: "front", high: "high", ceiling: "ceiling", onDesk: "onDesk", onBench: "onBench" };

/** PropDef：w、d、h、y0、row、build(k, x, accent, ag)——kit、擺放框、識別色、識別色發光(白天, 夜晚) */
function def(w, d, h, y0OrRow, rowOrBuild, maybeBuild) {
  // Swift：def(w, d, h, y0: = 0, row, build)；JS 沒有具名參數 ⇒ 第 4 個是數字就是 y0
  if (typeof y0OrRow === "number") return { w, d, h, y0: y0OrRow, row: rowOrBuild, build: maybeBuild };
  return { w, d, h, y0: 0, row: y0OrRow, build: rowOrBuild };
}

function books(k, x, { w, h, d, rows, alt = null }) {
  const cols = alt !== null ? [TP.FN5, alt, TP.FN5] : [TP.FN5, TP.FN4, TP.FN2];      // 只用三色輪替（不准彩虹書）
  for (let r = 0; r < rows; r++) {
    const y = 0.12 + r * (h - 0.2) / rows;
    k.b(x, 0, y, d / 2 - 0.12, w - 0.15, 0.28, 0.25, TM.f(cols[r % cols.length]));
  }
}

const R = PropRow;
const all = (() => {
  const p = {};
  // ── 通用擺設庫
  p["plant_tall"] = def(0.9, 0.9, 2.15, R.wall, (k, x) => {
    k.b(x, 0, 0, 0, 0.5, 0.5, 0.5, TM.f(TP.POT)); k.b(x, 0, 0.5, 0, 0.08, 0.6, 0.08, TM.f(TP.FN1));
    k.b(x, 0, 1.0, 0, 0.9, 0.7, 0.9, TM.f(TP.PL1)); k.b(x, 0.1, 1.7, -0.05, 0.6, 0.45, 0.6, TM.f(TP.PL2));
  });
  p["plant_low"] = def(0.5, 0.5, 0.7, R.front, (k, x) => {
    k.b(x, 0, 0, 0, 0.4, 0.35, 0.4, TM.f(TP.POT)); k.b(x, 0, 0.35, 0, 0.5, 0.35, 0.5, TM.f(TP.PL2));
  });
  p["sofa"] = def(2.0, 0.8, 0.82, R.front, (k, x) => {
    k.b(x, 0, 0, 0, 2.0, 0.42, 0.8, TM.f(TP.FN4)); k.b(x, 0, 0.42, -0.31, 2.0, 0.40, 0.18, TM.f(TP.FN4));
  });
  p["lounge_chair"] = def(0.75, 0.75, 0.82, R.front, (k, x) => {
    k.b(x, 0, 0, 0, 0.75, 0.42, 0.75, TM.f(TP.FN4)); k.b(x, 0, 0.42, -0.3, 0.75, 0.40, 0.15, TM.f(TP.FN4));
  });
  p["coffee_cart"] = def(1.0, 0.55, 1.4, R.wall, (k, x) => {
    k.b(x, 0, 0, 0, 1.0, 0.95, 0.55, TM.f(TP.FN1)); k.b(x, -0.2, 0.95, 0, 0.35, 0.45, 0.35, TM.f(TP.FN3));
    for (let i = 0; i < 3; i++) k.b(x, 0.12 + i * 0.12, 0.95, 0.1, 0.08, 0.08, 0.08, TM.f(TP.FN5));      // 杯子
  });
  p["whiteboard"] = def(2.4, 0.12, 1.2, 0.88, R.wall, (k, x) => {
    k.b(x, 0, 0.02, -0.03, 2.4, 1.2, 0.06, TM.f(TP.FN5)); k.b(x, 0, 0, 0.0, 2.4, 0.04, 0.12, TM.f(TP.FN3));
  });
  p["meeting_table"] = def(2.0, 1.2, 0.74, R.mid, (k, x) => {
    k.b(x, 0, 0.7, 0, 1.2, 0.04, 1.2, TM.f(TP.FN2)); k.b(x, 0, 0, 0, 0.12, 0.7, 0.12, TM.f(TP.FN3));
    for (const sx of [-0.85, 0.85]) k.b(x, sx, 0, 0, 0.4, 0.45, 0.4, TM.f(TP.FN4));
  });
  p["bench"] = def(2.0, 0.45, 0.45, R.front, (k, x) => { k.b(x, 0, 0, 0, 2.0, 0.45, 0.45, TM.f(TP.FN2)); });
  p["wall_clock"] = def(0.45, 0.06, 0.45, 1.98, R.high, (k, x) => {
    k.b(x, 0, 0, 0, 0.45, 0.45, 0.05, TM.f(TP.FN5));
    k.b(x, 0, 0.22, 0.03, 0.02, 0.17, 0.01, TM.f(TP.FN3)); k.b(x, 0.06, 0.22, 0.03, 0.13, 0.02, 0.01, TM.f(TP.FN3));
  });
  // ── 1 監控中心
  p["video_wall"] = def(3.6, 0.14, 1.5, 0.9, R.wall, (k, x, _a, ag) => {
    k.b(x, 0, 0, -0.01, 3.6, 1.5, 0.12, TM.f(TP.ST1));
    for (let i = 0; i < 4; i++) for (let j = 0; j < 2; j++) {
      const acc = i === 1 && j === 1;
      k.b(x, -1.35 + i * 0.9, 0.08 + j * 0.68, 0.06, 0.8, 0.6, 0.02, acc ? ag(0.25, 0.8) : TM.glow(0x2A3A4A, 0.25, 0.8));
    }
  });
  p["status_beacon"] = def(0.3, 0.3, 1.3, R.wall, (k, x, _a, ag) => {
    k.b(x, 0, 0, 0, 0.3, 0.1, 0.3, TM.f(TP.FN3)); k.b(x, 0, 0.1, 0, 0.18, 1.2, 0.18, ag(0.15, 0.9));
  });
  p["console"] = def(3.7, 0.72, 0.84, R.mid, (k, x) => {
    for (let i = -1; i <= 1; i++) k.b(x, i * 1.25, 0, 0, 1.2, 0.8, 0.7, TM.f(TP.FN3));
    k.b(x, 0, 0.8, 0, 3.7, 0.04, 0.72, TM.f(TP.FN5));
  });
  p["console1"] = def(1.2, 0.72, 0.84, R.mid, (k, x) => {
    k.b(x, 0, 0, 0, 1.2, 0.8, 0.7, TM.f(TP.FN3)); k.b(x, 0, 0.8, 0, 1.2, 0.04, 0.72, TM.f(TP.FN5));
    for (const sx of [-0.3, 0.3]) k.b(x, sx, 0.84, -0.2, 0.5, 0.3, 0.04, TM.f(TP.FN6));
  });
  p["server_rack"] = def(0.6, 0.8, 2.0, R.wall, (k, x) => {
    k.b(x, 0, 0, 0, 0.6, 2.0, 0.8, TM.f(TP.FN3));
    for (let i = 0; i < 6; i++) k.b(x, -0.2, 0.3 + i * 0.28, 0.41, 0.04, 0.04, 0.02, TM.glow(0x6FD08C, 0.6, 1.5));
  });
  // ── 2 App 開發室
  p["phone_wall"] = def(2.0, 0.1, 1.2, 1.0, R.wall, (k, x) => {
    k.b(x, 0, 0, -0.02, 2.0, 1.2, 0.05, TM.f(TP.FN5));
    for (let i = 0; i < 6; i++) k.b(x, -0.75 + i * 0.3, 0.29, 0.02, 0.16, 0.32, 0.03, TM.f(TP.FN6));
  });
  p["beanbag"] = def(0.8, 0.8, 0.65, R.front, (k, x, a) => {
    k.b(x, 0, 0, 0, 0.8, 0.45, 0.8, a); k.b(x, 0, 0.45, -0.25, 0.6, 0.2, 0.25, a);
  });
  p["standing_desk"] = def(1.6, 0.7, 1.1, R.wall, (k, x) => {
    k.b(x, 0, 1.05, 0, 1.6, 0.05, 0.7, TM.f(TP.FN2));
    for (const sx of [-0.7, 0.7]) k.b(x, sx, 0, 0, 0.06, 1.05, 0.6, TM.f(TP.FN3));
  });
  p["device_cart"] = def(0.8, 0.5, 0.95, R.wall, (k, x) => {
    k.b(x, 0, 0, 0, 0.8, 0.9, 0.5, TM.f(TP.FN3));
    for (let i = 0; i < 3; i++) k.b(x, -0.25 + i * 0.25, 0.9, 0, 0.22, 0.02, 0.3, TM.f(TP.FN6));
  });
  // ── 3 研究書房
  p["bookshelf"] = def(2.9, 0.35, 2.2, R.wall, (k, x) => {
    for (let i = -1; i <= 1; i++) {
      const s = x.at(i * 1.0, 0, 0);
      k.b(s, 0, 0, 0, 0.9, 2.2, 0.33, TM.f(TP.FN1));
      books(k, s, { w: 0.9, h: 2.2, d: 0.35, rows: 5 });
    }
  });
  p["reading_chair"] = def(0.8, 0.8, 0.92, R.front, (k, x, a) => {
    k.b(x, 0, 0, 0, 0.8, 0.42, 0.8, a); k.b(x, 0, 0.42, -0.31, 0.8, 0.5, 0.18, a);
  });
  p["long_table"] = def(2.4, 0.9, 0.75, R.mid, (k, x) => {
    k.b(x, 0, 0.7, 0, 2.4, 0.05, 0.9, TM.f(TP.FN1));
    for (const [sx, sz] of [[-1.1, -0.38], [1.1, -0.38], [-1.1, 0.38], [1.1, 0.38]]) k.b(x, sx, 0, sz, 0.06, 0.7, 0.06, TM.f(TP.FN3));
  });
  p["floor_lamp"] = def(0.35, 0.35, 1.9, R.wall, (k, x) => {
    k.b(x, 0, 0, 0, 0.3, 0.04, 0.3, TM.f(TP.FN3)); k.b(x, 0, 0, 0, 0.05, 1.6, 0.05, TM.f(TP.FN3));
    k.b(x, 0, 1.6, 0, 0.35, 0.3, 0.35, TM.glow(TP.LT1, 0, 1.0));
  });
  p["card_catalog"] = def(0.9, 0.45, 1.1, R.wall, (k, x) => {
    k.b(x, 0, 0, 0, 0.9, 1.1, 0.45, TM.f(TP.FN1));
    for (let r = 0; r < 4; r++) k.b(x, 0, 0.2 + r * 0.25, 0.23, 0.8, 0.01, 0.01, TM.f(TP.FN3));
  });
  p["globe"] = def(0.4, 0.4, 1.2, R.wall, (k, x) => {
    k.b(x, 0, 0, 0, 0.3, 0.04, 0.3, TM.f(TP.FN3)); k.b(x, 0, 0, 0, 0.05, 0.8, 0.05, TM.f(TP.FN3));
    k.b(x, 0, 0.8, 0, 0.4, 0.4, 0.4, TM.f(0xB9B2A5));
  });
  // ── 4 3D 列印工坊
  p["printer"] = def(1.52, 0.62, 1.47, R.wall, (k, x) => {
    for (const sx of [-0.45, 0.45]) {
      k.b(x, sx, 0, 0, 0.62, 0.75, 0.62, TM.f(TP.FN4)); k.b(x, sx, 0.75, 0, 0.62, 0.72, 0.62, TM.f(TP.FN3));
      k.b(x, sx, 0.86, 0.315, 0.5, 0.5, 0.01, TM.f(0x9AB0B8));
    }
  });
  p["parts_bin"] = def(0.6, 0.45, 1.0, R.wall, (k, x, a) => {
    k.b(x, 0, 0, 0, 0.6, 1.0, 0.45, a);
    for (let r = 0; r < 4; r++) k.b(x, 0, 0.22 + r * 0.22, 0.23, 0.5, 0.01, 0.01, TM.f(TP.FN3));
  });
  p["workbench"] = def(2.0, 0.7, 2.1, R.wall, (k, x) => {
    k.b(x, 0, 0.88, 0, 2.0, 0.06, 0.7, TM.f(TP.FN2));
    for (const sx of [-0.9, 0.9]) k.b(x, sx, 0, 0, 0.06, 0.88, 0.6, TM.f(TP.FN3));
    k.b(x, 0, 1.2, -0.33, 1.6, 0.9, 0.04, TM.f(TP.FN4));
  });
  p["filament_rack"] = def(1.2, 0.35, 1.5, R.wall, (k, x) => {
    k.b(x, 0, 0, 0, 1.2, 1.5, 0.33, TM.f(TP.FN3));
    const c = [TP.FN5, TP.FN4, TP.FN6];
    for (let i = 0; i < 4; i++) for (let j = 0; j < 2; j++) k.b(x, -0.42 + i * 0.28, 0.35 + j * 0.55, 0.2, 0.22, 0.22, 0.12, TM.f(c[(i + j) % 3]));
  });
  p["finished_shelf"] = def(1.4, 0.35, 1.45, R.wall, (k, x) => {
    k.b(x, 0, 0, 0, 1.4, 1.2, 0.35, TM.f(TP.FN5));
    for (let i = 0; i < 3; i++) k.b(x, -0.45 + i * 0.45, 1.2, 0, 0.25, 0.25, 0.25, TM.f(TP.WL1));
  });
  // ── 5 秘書電話室
  p["phone_booth"] = def(1.1, 1.1, 2.2, R.wall, (k, x, a) => {
    k.b(x, 0, 0, 0, 1.1, 0.06, 1.1, a); k.b(x, 0, 2.12, 0, 1.1, 0.08, 1.1, a);
    for (const [sx, sz] of [[-0.53, -0.53], [0.53, -0.53], [-0.53, 0.53], [0.53, 0.53]]) k.b(x, sx, 0, sz, 0.05, 2.12, 0.05, TM.f(TP.FN3));
    k.b(x, 0, 0.08, 0.53, 1.0, 2.0, 0.02, TM.glass(0.3));
    k.b(x, 0, 0, -0.1, 0.4, 0.45, 0.4, TM.f(TP.FN4));
  });
  p["tablet_stand"] = def(0.34, 0.3, 1.4, R.wall, (k, x) => {
    k.b(x, 0, 0, 0, 0.3, 0.06, 0.3, TM.f(TP.FN3)); k.b(x, 0, 0.06, 0, 0.04, 1.1, 0.04, TM.f(TP.FN3));
    k.b(x, 0, 1.16, 0, 0.34, 0.24, 0.03, TM.f(TP.FN6)); k.b(x, 0, 1.18, 0.02, 0.3, 0.2, 0.01, TM.glow(0x7FB8C8, 0.3, 0.9));
  });
  p["side_table"] = def(0.5, 0.5, 0.52, R.front, (k, x) => {
    k.b(x, 0, 0, 0, 0.5, 0.5, 0.5, TM.f(TP.FN1)); k.b(x, 0.02, 0.5, 0, 0.3, 0.02, 0.22, TM.f(TP.FN5));      // 雜誌
  });
  p["mail_rack"] = def(1.0, 0.3, 0.8, 1.3, R.wall, (k, x) => {
    k.b(x, 0, 0, 0, 1.0, 0.8, 0.3, TM.f(TP.FN1));
    for (let r = 0; r < 3; r++) k.b(x, 0, 0.2 + r * 0.22, 0.16, 0.9, 0.02, 0.01, TM.f(TP.FN3));
  });
  p["switchboard"] = def(1.2, 0.5, 1.0, R.wall, (k, x) => {
    k.b(x, 0, 0, 0, 1.2, 1.0, 0.5, TM.f(TP.FN3));
    for (let i = 0; i < 6; i++) for (let j = 0; j < 2; j++) k.b(x, -0.45 + i * 0.18, 0.7 + j * 0.15, 0.26, 0.04, 0.04, 0.02, TM.glow(TP.LT1, 0.2, 1.0));
  });
  // ── 6 交易室
  p["ticker_wall"] = def(3.2, 0.12, 1.12, 1.2, R.wall, (k, x, _a, ag) => {
    k.b(x, 0, 0, -0.01, 3.0, 1.0, 0.1, TM.f(TP.ST1));
    for (let i = 0; i < 3; i++) for (let j = 0; j < 2; j++) k.b(x, -1.0 + i * 1.0, 0.04 + j * 0.5, 0.05, 0.9, 0.42, 0.01, TM.glow(0x20302A, 0.2, 0.6));
    k.b(x, 0, 0.99, 0.02, 3.2, 0.12, 0.04, ag(0.3, 1.0));        // ★ 跑馬燈（中心高 2.25）
  });
  p["quad_monitor"] = def(1.0, 0.3, 0.7, R.onDesk, (k, x) => {
    k.b(x, 0, 0, 0, 0.06, 0.4, 0.06, TM.f(TP.FN3));
    for (let i = 0; i < 2; i++) for (let j = 0; j < 2; j++) k.b(x, -0.26 + i * 0.52, 0.3 + j * 0.32, 0.03, 0.5, 0.3, 0.03, TM.f(TP.FN6));
  });
  p["bull_statue"] = def(0.6, 0.5, 1.4, R.wall, (k, x) => {
    k.b(x, 0, 0, 0, 0.5, 0.9, 0.5, TM.f(TP.FN5)); k.b(x, 0, 0.9, 0, 0.6, 0.5, 0.3, TM.f(TP.FN6));
  });
  p["safe"] = def(0.6, 0.6, 0.8, R.wall, (k, x) => { k.b(x, 0, 0, 0, 0.6, 0.8, 0.6, TM.f(TP.FN3)); });
  // ── 7 攝影棚
  p["backdrop"] = def(2.6, 0.85, 2.6, R.wall, (k, x, _a, ag) => {
    k.b(x, 0, 0, -0.4, 2.6, 2.4, 0.05, TM.f(TP.FN4)); k.b(x, 0, 0, 0, 2.6, 0.05, 0.8, TM.f(TP.FN4));
    k.b(x, -1.0, 2.4, -0.38, 0.6, 0.2, 0.08, ag(0.3, 1.2));       // ★ ON AIR 燈箱（掛高 2.5）
  });
  p["softbox"] = def(0.6, 0.6, 2.2, R.wall, (k, x) => {
    k.b(x, 0, 0, 0, 0.05, 1.6, 0.05, TM.f(TP.FN3)); k.b(x, 0, 1.6, 0, 0.6, 0.6, 0.25, TM.glow(TP.FN5, 0.1, 0.8));
  });
  p["camera_tripod"] = def(0.4, 0.4, 1.5, R.mid, (k, x) => {
    k.b(x, 0, 0, 0, 0.05, 1.3, 0.05, TM.f(TP.FN3)); k.b(x, 0, 1.3, 0, 0.3, 0.2, 0.2, TM.f(TP.FN6));
  });
  p["edit_bay"] = def(1.6, 0.8, 1.15, R.wall, (k, x) => {
    k.b(x, 0, 0, 0, 1.6, 0.75, 0.8, TM.f(TP.FN1));
    for (const sx of [-0.35, 0.35]) k.b(x, sx, 0.78, -0.2, 0.6, 0.35, 0.04, TM.f(TP.FN6));
  });
  // ── 8 設計工作室
  p["moodboard"] = def(2.4, 0.1, 1.4, 0.9, R.wall, (k, x) => {
    k.b(x, 0, 0, -0.02, 2.4, 1.4, 0.05, TM.f(TP.FN5));
    const c = [TP.FN4, TP.FN2, TP.FN1];
    for (let i = 0; i < 4; i++) for (let j = 0; j < 2; j++) k.b(x, -0.85 + i * 0.57, 0.25 + j * 0.55, 0.01, 0.4, 0.3, 0.01, TM.f(c[(i + j) % 3]));
  });
  p["pendant_dome"] = def(0.9, 0.9, 0.8, 2.45, R.ceiling, (k, x, a) => {
    k.b(x, 0, 0.32, 0, 0.02, 0.5, 0.02, TM.f(TP.FN3));
    k.b(x, 0, 0.02, 0, 0.9, 0.3, 0.9, a); k.b(x, 0, 0, 0, 0.7, 0.02, 0.7, TM.glow(TP.LT1, 0, 1.2));
  });
  p["drafting_table"] = def(1.4, 0.9, 1.05, R.mid, (k, x) => {
    for (const sx of [-0.62, 0.62]) k.b(x, sx, 0, 0, 0.06, 0.92, 0.7, TM.f(TP.FN3));
    k.b(x, 0, 0.9, 0.22, 1.4, 0.04, 0.45, TM.f(TP.FN2)); k.b(x, 0, 1.0, -0.22, 1.4, 0.04, 0.45, TM.f(TP.FN2));
  });
  p["material_shelf"] = def(1.2, 0.4, 1.6, R.wall, (k, x) => {
    k.b(x, 0, 0, 0, 1.2, 1.6, 0.38, TM.f(TP.FN2));
    const c = [TP.FN5, TP.FN4, TP.FN1];
    for (let r = 0; r < 3; r++) for (let i = 0; i < 4; i++) k.b(x, -0.42 + i * 0.28, 0.2 + r * 0.5, 0.2, 0.2, 0.2, 0.02, TM.f(c[(r + i) % 3]));
  });
  p["easel"] = def(0.8, 0.5, 1.7, R.wall, (k, x) => {
    for (const sx of [-0.3, 0.3]) k.b(x, sx, 0, 0, 0.05, 1.7, 0.05, TM.f(TP.FN1));
    k.b(x, 0, 0.75, 0.05, 0.7, 0.85, 0.03, TM.f(TP.FN5));
  });
  // ── 9 法務室
  p["conference_table"] = def(3.0, 2.0, 0.76, R.mid, (k, x) => {
    k.b(x, 0, 0.7, 0, 3.0, 0.06, 1.1, TM.f(TP.FN1));
    for (const sx of [-0.9, 0.9]) k.b(x, sx, 0, 0, 0.2, 0.7, 0.6, TM.f(TP.FN1));
    for (const sx of [-1.0, 0, 1.0]) for (const sz of [-0.8, 0.8]) k.b(x, sx, 0, sz, 0.45, 0.45, 0.4, TM.f(TP.FN4));
  });
  p["document_safe"] = def(0.8, 0.5, 1.3, R.wall, (k, x, a) => {
    k.b(x, 0, 0, 0, 0.8, 1.3, 0.5, a); k.b(x, 0.25, 0.7, 0.26, 0.08, 0.08, 0.04, TM.f(TP.FN5));
  });
  p["file_cabinet"] = def(1.6, 0.6, 1.3, R.wall, (k, x) => {
    for (let i = -1; i <= 1; i++) {
      k.b(x, i * 0.54, 0, 0, 0.5, 1.3, 0.6, TM.f(TP.FN3));
      for (let r = 0; r < 3; r++) k.b(x, i * 0.54, 0.35 + r * 0.4, 0.31, 0.3, 0.03, 0.01, TM.f(TP.FN4));
    }
  });
  p["law_shelf"] = def(1.8, 0.35, 2.0, R.wall, (k, x) => {
    k.b(x, 0, 0, 0, 1.8, 2.0, 0.33, TM.f(TP.FN1)); books(k, x, { w: 1.8, h: 2.0, d: 0.35, rows: 4, alt: 0x6B5B4B });
  });
  p["seal_desk"] = def(0.7, 0.5, 0.95, R.wall, (k, x) => { k.b(x, 0, 0, 0, 0.7, 0.95, 0.5, TM.f(TP.FN5)); });
  // ── 10 財務帳房
  p["ledger_cabinet"] = def(1.8, 0.45, 1.0, R.wall, (k, x) => {
    k.b(x, 0, 0, 0, 1.8, 1.0, 0.45, TM.f(TP.FN1));
    for (let r = 0; r < 3; r++) k.b(x, 0, 0.25 + r * 0.3, 0.23, 1.7, 0.01, 0.01, TM.f(TP.FN3));
  });
  p["brass_safe"] = def(0.7, 0.6, 0.9, R.wall, (k, x, a) => {
    k.b(x, 0, 0, 0, 0.7, 0.9, 0.6, a); k.b(x, 0, 0.45, 0.31, 0.18, 0.18, 0.04, TM.f(TP.FN3));
  });
  p["receipt_tray"] = def(0.5, 0.35, 0.08, R.onDesk, (k, x) => { k.b(x, 0, 0, 0, 0.5, 0.08, 0.35, TM.f(TP.FN5)); });
  p["cashier_counter"] = def(1.2, 0.6, 1.04, R.mid, (k, x) => {
    k.b(x, 0, 0, 0, 1.2, 1.0, 0.6, TM.f(TP.FN3)); k.b(x, 0, 1.0, 0, 1.25, 0.04, 0.65, TM.f(TP.FN5));
  });
  p["ledger_shelf"] = def(1.2, 0.35, 1.8, R.wall, (k, x) => {
    k.b(x, 0, 0, 0, 1.2, 1.8, 0.33, TM.f(TP.FN1)); books(k, x, { w: 1.2, h: 1.8, d: 0.35, rows: 4 });
  });
  // ── 11 遊戲工作室
  p["arcade"] = def(0.7, 0.8, 1.8, R.wall, (k, x, a) => {
    k.b(x, 0, 0, 0, 0.7, 1.8, 0.8, a); k.b(x, 0, 1.1, 0.4, 0.56, 0.46, 0.02, TM.f(TP.FN6));
    k.b(x, 0, 1.13, 0.41, 0.5, 0.4, 0.01, TM.glow(0xB18CFF, 0.3, 1.0));
  });
  p["arcade_n"] = def(0.7, 0.8, 1.8, R.wall, (k, x) => {          // 第二台大型機：中性色（識別色只用在一件）
    k.b(x, 0, 0, 0, 0.7, 1.8, 0.8, TM.f(TP.FN6)); k.b(x, 0, 1.1, 0.4, 0.56, 0.46, 0.02, TM.f(TP.FN3));
    k.b(x, 0, 1.13, 0.41, 0.5, 0.4, 0.01, TM.glow(0x6FA8DC, 0.3, 1.0));
  });
  p["playtest_tv"] = def(1.8, 0.45, 1.5, R.wall, (k, x) => {
    k.b(x, 0, 0, 0, 1.8, 0.5, 0.45, TM.f(TP.FN1)); k.b(x, 0, 0.6, -0.1, 1.6, 0.9, 0.08, TM.f(TP.FN6));
  });
  p["sprite_wall"] = def(2.0, 0.1, 1.2, 0.9, R.wall, (k, x) => {
    k.b(x, 0, 0, -0.02, 2.0, 1.2, 0.05, TM.f(TP.FN5));
    for (let i = 0; i < 4; i++) for (let j = 0; j < 3; j++) if ((i + j) % 2 === 0) k.b(x, -0.6 + i * 0.4, 0.2 + j * 0.35, 0.01, 0.36, 0.3, 0.01, TM.f(j === 1 ? TP.FN2 : TP.FN4));
  });
  p["controller_shelf"] = def(1.0, 0.3, 0.8, R.wall, (k, x) => {
    k.b(x, 0, 0, 0, 1.0, 0.8, 0.3, TM.f(TP.FN3));
    for (let i = 0; i < 3; i++) k.b(x, -0.3 + i * 0.3, 0.8, 0, 0.2, 0.06, 0.14, TM.f(TP.FN6));
  });
  p["trophy_shelf"] = def(1.0, 0.35, 1.9, R.wall, (k, x) => {
    k.b(x, 0, 0, 0, 1.0, 1.6, 0.33, TM.f(TP.FN1));
    for (let i = 0; i < 3; i++) k.b(x, -0.3 + i * 0.3, 1.6, 0, 0.15, 0.3, 0.15, TM.f(TP.FN5));
  });
  // ── 12 硬體實驗室
  p["esd_bench"] = def(2.0, 0.9, 1.1, R.wall, (k, x) => {
    k.b(x, 0, 0.71, 0, 2.0, 0.04, 0.9, TM.f(0x7E8A86));
    for (const [sx, sz] of [[-0.95, -0.4], [0.95, -0.4], [-0.95, 0.4], [0.95, 0.4]]) k.b(x, sx, 0, sz, 0.05, 0.71, 0.05, TM.f(TP.FN3));
    k.b(x, -0.5, 0.75, -0.1, 0.5, 0.3, 0.4, TM.f(TP.FN6)); k.b(x, -0.5, 0.8, 0.105, 0.3, 0.2, 0.01, TM.glow(0x7FD08C, 0.3, 0.9));
  });
  p["speaker_tower"] = def(0.4, 0.4, 1.1, R.wall, (k, x, a) => {
    k.b(x, 0, 0, 0, 0.4, 1.1, 0.4, a);
    for (const y of [0.3, 0.7]) k.b(x, 0, y, 0.205, 0.25, 0.25, 0.02, TM.f(TP.FN6));
  });
  p["parts_wall"] = def(1.6, 0.2, 1.2, 0.9, R.wall, (k, x) => {
    k.b(x, 0, 0, 0, 1.6, 1.2, 0.2, TM.f(TP.FN3));
    for (let i = 0; i < 4; i++) for (let j = 0; j < 3; j++) k.b(x, -0.54 + i * 0.36, 0.15 + j * 0.36, 0.1, 0.22, 0.12, 0.15, TM.f(TP.FN4));
  });
  p["soldering_station"] = def(0.4, 0.3, 0.3, R.onBench, (k, x) => {
    k.b(x, 0, 0, 0, 0.4, 0.3, 0.3, TM.f(TP.FN6)); k.b(x, 0.12, 0.3, 0, 0.03, 0.25, 0.03, TM.f(TP.FN3));
  });
  p["test_rig"] = def(1.0, 0.6, 1.4, R.wall, (k, x) => {
    k.b(x, 0, 0, 0, 1.0, 0.06, 0.6, TM.f(TP.FN3)); k.b(x, 0, 1.34, 0, 1.0, 0.06, 0.6, TM.f(TP.FN3));
    for (const sx of [-0.47, 0.47]) k.b(x, sx, 0, 0, 0.06, 1.4, 0.6, TM.f(TP.FN3));
    k.b(x, 0, 0.5, 0, 0.5, 0.4, 0.4, TM.f(TP.FN6));
  });
  // ── 13 行銷室
  p["content_wall"] = def(2.4, 0.1, 1.6, 1.0, R.wall, (k, x, _a, ag) => {
    k.b(x, 0, 0, -0.02, 2.4, 1.2, 0.05, TM.f(TP.FN5));
    for (let i = 0; i < 4; i++) for (let j = 0; j < 3; j++) k.b(x, -0.81 + i * 0.54, 0.12 + j * 0.36, 0.01, 0.45, 0.3, 0.01, TM.f((i + j) % 2 === 0 ? TP.FN4 : TP.FN2));
    k.b(x, 0, 1.24, 0, 1.2, 0.4, 0.08, ag(0.3, 1.2));           // ★ 標語燈箱（掛高 2.4）
  });
  p["ring_light"] = def(0.5, 0.3, 2.0, R.wall, (k, x) => {
    k.b(x, 0, 0, 0, 0.05, 1.5, 0.05, TM.f(TP.FN3));
    const l = TM.glow(TP.LT1, 0.2, 1.0);
    k.b(x, 0, 1.5, 0, 0.5, 0.06, 0.06, l); k.b(x, 0, 1.94, 0, 0.5, 0.06, 0.06, l);
    for (const sx of [-0.22, 0.22]) k.b(x, sx, 1.5, 0, 0.06, 0.5, 0.06, l);
  });
  p["product_table"] = def(1.2, 0.6, 0.9, R.mid, (k, x) => { k.b(x, 0, 0, 0, 1.2, 0.9, 0.6, TM.f(TP.FN5)); });
  // ── 14 調度中心
  p["route_map"] = def(3.0, 0.1, 1.4, 1.0, R.wall, (k, x, a) => {
    k.b(x, 0, 0, -0.02, 3.0, 1.4, 0.05, TM.f(TP.FN5));
    // 三條路線（各 3 段折線，只用識別色）
    const routes = [[[-1.3, 0.3], [-0.4, 0.3], [-0.4, 1.0], [0.8, 1.0]],
                    [[-1.1, 1.2], [0.0, 1.2], [0.0, 0.5], [1.3, 0.5]],
                    [[-0.8, 0.15], [0.6, 0.15], [0.6, 0.8], [1.2, 1.2]]];
    for (const r of routes) for (let s = 0; s + 1 < r.length; s++) {
      const p0 = r[s], p1 = r[s + 1];
      const cx = (p0[0] + p1[0]) / 2, cy = (p0[1] + p1[1]) / 2;
      k.b(x, cx, cy - 0.02 - Math.abs(p1[1] - p0[1]) / 2, 0.01, Math.max(0.04, Math.abs(p1[0] - p0[0]) + 0.04), Math.max(0.04, Math.abs(p1[1] - p0[1]) + 0.04), 0.01, a);
    }
  });
  p["radio_desk"] = def(2.4, 0.8, 1.1, R.mid, (k, x) => {
    k.b(x, 0, 0, 0, 2.4, 0.8, 0.8, TM.f(TP.FN3)); k.b(x, 0, 0.8, 0, 2.45, 0.04, 0.82, TM.f(TP.FN5));
    for (const sx of [-0.6, 0.6]) k.b(x, sx, 0.84, -0.2, 0.1, 0.25, 0.08, TM.f(TP.FN6));
  });
  p["flight_board"] = def(1.6, 0.1, 0.8, 1.3, R.wall, (k, x) => {
    k.b(x, 0, 0, 0, 1.6, 0.8, 0.08, TM.f(TP.FN6));
    for (let r = 0; r < 5; r++) k.b(x, 0, 0.1 + r * 0.14, 0.045, 1.4, 0.06, 0.01, TM.glow(TP.cityWindow, 0.2, 0.7));
  });
  p["key_cabinet"] = def(0.6, 0.25, 0.9, 1.0, R.wall, (k, x) => { k.b(x, 0, 0, 0, 0.6, 0.9, 0.25, TM.f(TP.FN1)); });
  // ── 15 建築製圖室
  p["plan_table"] = def(2.4, 1.2, 1.7, R.mid, (k, x, _a, ag) => {
    k.b(x, 0, 0.9, 0, 2.4, 0.06, 1.2, TM.f(TP.FN2));
    for (const sx of [-1.1, 1.1]) k.b(x, sx, 0, 0, 0.08, 0.9, 1.0, TM.f(TP.FN3));
    k.b(x, 0, 0.96, 0, 1.6, 0.01, 0.8, TM.f(TP.FN5));
    // ★ 懸臂燈（夾在大圖桌上）
    k.b(x, 0.85, 0.96, -0.4, 0.3, 0.05, 0.3, TM.f(TP.FN3)); k.b(x, 0.85, 1.0, -0.4, 0.03, 0.55, 0.03, TM.f(TP.FN3));
    k.b(x, 0.85, 1.5, -0.25, 0.22, 0.14, 0.22, ag(0, 0.6));
  });
  p["plan_chest"] = def(1.4, 0.9, 0.9, R.wall, (k, x) => {
    k.b(x, 0, 0, 0, 1.4, 0.9, 0.9, TM.f(TP.FN3));
    for (let r = 0; r < 4; r++) k.b(x, 0, 0.18 + r * 0.18, 0.455, 1.3, 0.01, 0.01, TM.f(0x55585E));
  });
  p["model_plinth"] = def(0.8, 0.8, 1.5, R.wall, (k, x) => {
    k.b(x, 0, 0, 0, 0.8, 1.0, 0.8, TM.f(TP.FN5));
    k.b(x, -0.12, 1.0, 0, 0.3, 0.5, 0.3, TM.f(TP.WL1)); k.b(x, 0.18, 1.0, 0.05, 0.25, 0.3, 0.4, TM.f(TP.WL1));
  });
  p["section_wall"] = def(2.0, 0.1, 1.2, 1.0, R.wall, (k, x) => {
    k.b(x, 0, 0, -0.02, 2.0, 1.2, 0.05, TM.f(TP.FN5));
    for (let r = 0; r < 4; r++) k.b(x, 0, 0.2 + r * 0.25, 0.01, 1.6 - (r % 2) * 0.5, 0.02, 0.01, TM.f(TP.FN3));
    for (let i = 0; i < 3; i++) k.b(x, -0.6 + i * 0.6, 0.15, 0.01, 0.02, 0.9, 0.01, TM.f(TP.FN3));
  });
  // ── 10-20 UI/UX 優化 §3.2 生活感共用組＋§3.3 主題新件（尺寸照規劃；只用色票裡的顏色，不新增材質種類）
  p["trash_bin"] = def(0.25, 0.25, 0.35, R.front, (k, x) => { k.b(x, 0, 0, 0, 0.25, 0.35, 0.25, TM.f(TP.FN3)); });
  p["coat_rack"] = def(0.45, 0.45, 1.75, R.wall, (k, x) => {
    k.b(x, 0, 0, 0, 0.35, 0.04, 0.35, TM.f(TP.FN3)); k.b(x, 0, 0, 0, 0.05, 1.7, 0.05, TM.f(TP.FN3));
    k.b(x, 0, 1.7, 0, 0.4, 0.05, 0.4, TM.f(TP.FN3)); k.b(x, 0.12, 0.95, 0.06, 0.3, 0.6, 0.15, TM.f(TP.FN4));
  });
  p["charging_shelf"] = def(0.9, 0.3, 0.9, R.wall, (k, x) => {
    k.b(x, 0, 0, 0, 0.9, 0.9, 0.3, TM.f(TP.FN3));
    for (let i = 0; i < 6; i++) k.b(x, -0.35 + (i % 3) * 0.35, 0.3 + Math.trunc(i / 3) * 0.32, 0.15, 0.1, 0.18, 0.02, TM.glow(0x7FB8C8, 0.3, 0.9));
  });
  p["box_stack"] = def(1.1, 0.4, 0.8, R.front, (k, x) => {
    k.b(x, -0.27, 0, 0, 0.5, 0.4, 0.4, TM.f(TP.FN2)); k.b(x, 0.27, 0, 0, 0.5, 0.4, 0.4, TM.f(TP.FN2));
    k.b(x, -0.1, 0.4, 0, 0.5, 0.4, 0.4, TM.f(TP.FN2));
  });
  p["news_tv"] = def(1.2, 0.08, 0.7, 1.45, R.high, (k, x) => {
    k.b(x, 0, 0, 0, 1.2, 0.7, 0.06, TM.f(TP.FN6)); k.b(x, 0, 0.06, 0.035, 1.1, 0.58, 0.01, TM.glow(0x5B7A99, 0.3, 0.9));
  });
  p["equipment_case"] = def(0.7, 0.45, 0.4, R.front, (k, x) => {
    k.b(x, 0, 0, 0, 0.7, 0.4, 0.45, TM.f(TP.FN3)); k.b(x, 0, 0.4, 0, 0.2, 0.04, 0.05, TM.f(TP.FN4));
  });
  p["sample_table"] = def(1.0, 0.6, 0.47, R.front, (k, x) => {
    k.b(x, 0, 0, 0, 1.0, 0.45, 0.6, TM.f(TP.FN2));
    [TP.FN4, TP.FN1, TP.FN5].forEach((c, i) => { k.b(x, -0.3 + i * 0.3, 0.45, 0, 0.2, 0.01, 0.3, TM.f(c)); });
  });
  p["cable_reel"] = def(0.9, 0.4, 0.4, R.wall, (k, x) => {
    for (const sx of [-0.24, 0.24]) { k.b(x, sx, 0, 0, 0.4, 0.4, 0.25, TM.f(TP.FN3)); k.b(x, sx, 0.1, 0.13, 0.2, 0.2, 0.01, TM.f(TP.FN2)); }
  });
  p["scope_cart"] = def(0.6, 0.45, 0.85, R.front, (k, x) => {
    k.b(x, 0, 0, 0, 0.6, 0.05, 0.45, TM.f(TP.FN3)); k.b(x, 0, 0.5, 0, 0.6, 0.05, 0.45, TM.f(TP.FN3));
    for (const sx of [-0.27, 0.27]) k.b(x, sx, 0, 0, 0.04, 0.55, 0.04, TM.f(TP.FN3));
    k.b(x, 0, 0.55, 0, 0.4, 0.3, 0.3, TM.f(TP.FN6)); k.b(x, 0, 0.6, 0.155, 0.28, 0.18, 0.01, TM.glow(0x7FD08C, 0.3, 0.9));
  });
  p["poster_stand"] = def(0.6, 0.3, 1.45, R.wall, (k, x, a) => {
    k.b(x, 0, 0, 0, 0.4, 0.04, 0.3, TM.f(TP.FN3)); k.b(x, 0, 0.04, 0, 0.6, 1.4, 0.05, TM.f(TP.FN5));
    k.b(x, 0, 0.9, 0.03, 0.5, 0.4, 0.01, a);
  });
  p["car_model"] = def(0.5, 0.25, 0.2, R.onDesk, (k, x) => {
    k.b(x, 0, 0, 0, 0.5, 0.12, 0.25, TM.f(TP.FN6)); k.b(x, -0.03, 0.12, 0, 0.28, 0.08, 0.22, TM.f(TP.FN6));
  });
  p["luggage"] = def(0.9, 0.3, 0.6, R.front, (k, x) => {
    for (const sx of [-0.24, 0.24]) { k.b(x, sx, 0, 0, 0.4, 0.6, 0.25, TM.f(TP.FN4)); k.b(x, sx, 0.6, 0, 0.12, 0.04, 0.04, TM.f(TP.FN3)); }
  });
  p["roll_bin"] = def(0.4, 0.4, 0.85, R.front, (k, x) => {
    k.b(x, 0, 0, 0, 0.35, 0.7, 0.35, TM.f(TP.FN3));
    for (const [dx, dz] of [[-0.08, -0.08], [0.08, -0.08], [0, 0], [-0.08, 0.08], [0.08, 0.08]]) k.b(x, dx, 0.5, dz, 0.07, 0.35, 0.07, TM.f(TP.FN5));
  });
  // ── 10-20 第 4 棒：生活感組新件（飲水機、影印機）
  p["water_cooler"] = def(0.42, 0.42, 1.2, R.wall, (k, x) => {
    k.b(x, 0, 0, 0, 0.4, 0.85, 0.4, TM.f(TP.FN5)); k.b(x, 0, 0.85, 0, 0.3, 0.35, 0.3, TM.f(TP.POT));
    k.b(x, 0.08, 0.55, 0.205, 0.08, 0.06, 0.02, TM.f(TP.FN3));
  });
  p["copier"] = def(0.9, 0.65, 1.0, R.wall, (k, x) => {
    k.b(x, 0, 0, 0, 0.9, 0.85, 0.65, TM.f(TP.FN5)); k.b(x, 0, 0.85, 0, 0.9, 0.12, 0.65, TM.f(TP.FN4));
    k.b(x, 0.25, 0.97, 0.15, 0.3, 0.03, 0.2, TM.f(TP.FN6)); k.b(x, -0.1, 0.5, 0.33, 0.6, 0.06, 0.02, TM.f(TP.FN4));
  });
  // ── 10-20 第 4 棒：每個主題一件「識別色★大件」（評審：遮掉門牌後 5 層看起來一樣）。
  //   寬 2.0（樓層寬的 17%）、放在角色左前方（前帶）、正面朝鏡頭；整座台子是識別色＋正面上緣一條亮邊（不用發光材質，材質數不增加）。
  //   台面上放這個主題才有的東西（≤ 1.25 高，不擋到後面的人）
  function hero(id, top) {
    p["hero_" + id] = def(2.0, 0.66, 1.25, R.front, (k, x, a, ag) => {
      k.b(x, 0, 0, 0, 2.0, 0.8, 0.6, a);
      k.b(x, 0, 0.72, 0.31, 2.0, 0.04, 0.02, TM.f(TP.FN5));       // 正面上緣一條亮邊（不加發光材質，材質數不變）
      k.b(x, 0, 0.1, 0.305, 1.86, 0.6, 0.02, a);
      k.b(x, 0, 0.8, 0, 2.06, 0.04, 0.66, TM.f(TP.FN5));
      top(k, x.at(0, 0.84, 0), ag);
    });
  }
  // 發光只用場景裡本來就有的幾種（材質共用，不增加材質數）。
  // Swift 在 static let all 初始化時取一次；JS 照樣在這裡取（VoxMat.flat 有快取，同一份材質）
  const scr = TM.glow(0x7FB8C8, 0.3, 0.9), led = TM.glow(TP.LT1, 0.2, 1.0), grn = TM.glow(0x6FD08C, 0.6, 1.5);
  hero("monitor", (k, x) => {                     // 監控台：三連螢幕
    for (let i = -1; i <= 1; i++) { k.b(x, i * 0.62, 0, -0.12, 0.58, 0.36, 0.04, TM.f(TP.FN6)); k.b(x, i * 0.62, 0.03, -0.095, 0.52, 0.3, 0.01, i === 0 ? grn : scr); }
  });
  hero("app_studio", (k, x) => {                  // 程式碼大螢幕＋手機測試架
    k.b(x, -0.4, 0, -0.15, 1.05, 0.4, 0.04, TM.f(TP.FN6));
    for (let r = 0; r < 4; r++) k.b(x, -0.5 + (r % 2) * 0.1, 0.07 + r * 0.08, -0.125, 0.6 - (r % 3) * 0.12, 0.03, 0.01, r === 1 ? grn : scr);
    k.b(x, 0.55, 0, 0, 0.75, 0.04, 0.3, TM.f(TP.FN3));
    for (let i = 0; i < 4; i++) { k.b(x, 0.3 + i * 0.17, 0.04, 0.02, 0.1, 0.2, 0.02, TM.f(TP.FN6)); k.b(x, 0.3 + i * 0.17, 0.06, 0.035, 0.08, 0.16, 0.005, scr); }
  });
  hero("library", (k, x) => {                     // 借還書台：書堆＋檯燈
    [TP.FN5, TP.FN2, TP.FN4, TP.FN5].forEach((c, i) => { k.b(x, -0.7 + i * 0.22, 0, 0, 0.2, 0.18 + (i % 2) * 0.12, 0.28, TM.f(c)); });
    k.b(x, 0.6, 0, 0, 0.12, 0.03, 0.12, TM.f(TP.FN3)); k.b(x, 0.6, 0, 0, 0.03, 0.35, 0.03, TM.f(TP.FN3)); k.b(x, 0.6, 0.33, 0.05, 0.18, 0.08, 0.18, led);
  });
  hero("print_shop", (k, x) => {                  // 大台 3D 印表機（透明罩）＋印好的件
    k.b(x, -0.35, 0, 0, 0.7, 0.4, 0.5, TM.f(TP.FN6)); k.b(x, -0.35, 0.04, 0.255, 0.6, 0.3, 0.01, TM.glass(0.3));
    k.b(x, -0.35, 0.05, 0, 0.18, 0.12, 0.18, TM.f(TP.FN5));
    for (let i = 0; i < 3; i++) k.b(x, 0.35 + i * 0.2, 0, 0.05, 0.14, 0.1 + i * 0.05, 0.14, TM.f(TP.WL1));
  });
  hero("call_room", (k, x) => {                   // 總機台：來電燈號列＋耳機架
    k.b(x, -0.2, 0, -0.15, 1.3, 0.34, 0.06, TM.f(TP.FN6));
    for (let i = 0; i < 6; i++) for (let j = 0; j < 2; j++) k.b(x, -0.75 + i * 0.22, 0.07 + j * 0.14, -0.115, 0.12, 0.08, 0.01, (i + j) % 3 === 0 ? scr : led);
    for (const sx of [0.62, 0.86]) { k.b(x, sx, 0, 0.05, 0.03, 0.3, 0.03, TM.f(TP.FN3)); k.b(x, sx, 0.28, 0.05, 0.16, 0.05, 0.05, TM.f(TP.FN6)); k.b(x, sx - 0.07, 0.18, 0.05, 0.03, 0.12, 0.05, TM.f(TP.FN6)); }
  });
  hero("trading_desk", (k, x) => {                // 交易台：雙螢幕＋行情條
    for (let i = 0; i < 2; i++) { k.b(x, -0.45 + i * 0.7, 0, -0.12, 0.64, 0.36, 0.04, TM.f(TP.FN6)); k.b(x, -0.45 + i * 0.7, 0.03, -0.095, 0.58, 0.3, 0.01, grn); }
    k.b(x, 0, 0.38, -0.12, 1.5, 0.06, 0.03, led);
  });
  hero("media_studio", (k, x) => {                // 主播台：ON AIR 燈箱＋麥克風
    k.b(x, -0.5, 0, -0.1, 0.6, 0.22, 0.08, led);
    k.b(x, 0.4, 0, 0, 0.1, 0.03, 0.1, TM.f(TP.FN3)); k.b(x, 0.4, 0, 0, 0.03, 0.3, 0.03, TM.f(TP.FN3)); k.b(x, 0.4, 0.28, 0.02, 0.07, 0.12, 0.07, TM.f(TP.FN6));
  });
  hero("design_studio", (k, x) => {               // 色票樣品台
    const c = [TP.FN5, TP.FN2, TP.FN1, TP.FN4, TP.PL2, TP.POT];
    c.forEach((h, i) => { k.b(x, -0.75 + i * 0.3, 0, 0, 0.24, 0.04 + (i % 3) * 0.05, 0.3, TM.f(h)); });
  });
  hero("legal_room", (k, x) => {                  // 文件堆＋天平
    for (let i = 0; i < 3; i++) k.b(x, -0.6 + i * 0.3, 0, 0, 0.26, 0.12 + i * 0.06, 0.34, TM.f(TP.FN5));
    k.b(x, 0.55, 0, 0, 0.04, 0.4, 0.04, TM.f(TP.FN2)); k.b(x, 0.55, 0.38, 0, 0.5, 0.03, 0.03, TM.f(TP.FN2));
    for (const sx of [-0.22, 0.22]) k.b(x, 0.55 + sx, 0.22, 0, 0.14, 0.03, 0.14, TM.f(TP.FN2));
  });
  hero("ledger_room", (k, x) => {                 // 帳房櫃台：帳本＋算盤＋金幣
    k.b(x, -0.55, 0, 0, 0.5, 0.06, 0.34, TM.f(TP.FN1)); k.b(x, -0.55, 0.06, 0, 0.46, 0.05, 0.3, TM.f(TP.FN5));
    k.b(x, 0.1, 0, 0, 0.5, 0.04, 0.26, TM.f(TP.FN1)); for (let r = 0; r < 3; r++) k.b(x, 0.1, 0.04, -0.08 + r * 0.08, 0.46, 0.03, 0.02, TM.f(TP.FN6));
    for (let i = 0; i < 3; i++) k.b(x, 0.62 + i * 0.12, 0, 0, 0.1, 0.06 + i * 0.05, 0.1, TM.f(TP.FN2));
  });
  hero("game_lab", (k, x) => {                    // 試玩台：電視＋手把
    k.b(x, -0.2, 0, -0.15, 1.1, 0.4, 0.05, TM.f(TP.FN6)); k.b(x, -0.2, 0.03, -0.12, 1.0, 0.33, 0.01, TM.glow(0xB18CFF, 0.3, 1.0));
    for (const sx of [0.55, 0.8]) k.b(x, sx, 0, 0.12, 0.18, 0.05, 0.1, TM.f(TP.FN6));
  });
  hero("hw_lab", (k, x) => {                      // 示波器＋電路板
    k.b(x, -0.45, 0, -0.05, 0.6, 0.38, 0.4, TM.f(TP.FN6)); k.b(x, -0.5, 0.06, 0.155, 0.4, 0.26, 0.01, grn);
    k.b(x, 0.4, 0, 0.05, 0.6, 0.03, 0.4, TM.f(TP.PL1)); for (let i = 0; i < 3; i++) k.b(x, 0.25 + i * 0.15, 0.03, 0.05, 0.08, 0.05, 0.08, TM.f(TP.FN6));
  });
  hero("marketing", (k, x) => {                   // 產品陳列台：三盒產品＋標語燈箱
    for (let i = 0; i < 3; i++) k.b(x, -0.65 + i * 0.35, 0, 0, 0.28, 0.2 + i * 0.06, 0.28, TM.f(i === 1 ? TP.FN5 : TP.FN2));
    k.b(x, 0.55, 0, -0.1, 0.6, 0.3, 0.06, led);
  });
  hero("dispatch_room", (k, x) => {               // 派車台：地圖螢幕＋無線電
    k.b(x, -0.35, 0, -0.15, 1.0, 0.4, 0.04, TM.f(TP.FN6));
    for (let r = 0; r < 3; r++) k.b(x, -0.55 + r * 0.2, 0.06 + r * 0.09, -0.125, 0.4, 0.03, 0.01, scr);
    k.b(x, 0.55, 0, 0, 0.3, 0.16, 0.2, TM.f(TP.FN3)); k.b(x, 0.62, 0.16, 0, 0.03, 0.28, 0.03, TM.f(TP.FN3));
  });
  hero("drafting_room", (k, x) => {               // 大圖桌：攤開的圖＋捲圖筒
    k.b(x, -0.3, 0, 0, 1.2, 0.01, 0.5, TM.f(TP.FN5));
    for (let r = 0; r < 3; r++) k.b(x, -0.3, 0.01, -0.15 + r * 0.15, 1.0 - (r % 2) * 0.4, 0.005, 0.02, TM.f(TP.FN3));
    for (let i = 0; i < 4; i++) k.b(x, 0.55 + (i % 2) * 0.12, 0, -0.1 + Math.trunc(i / 2) * 0.14, 0.09, 0.32 + i * 0.04, 0.09, TM.f(TP.FN5));
  });
  hero("general", (k, x) => {                     // 接待台：文件＋小盆栽
    k.b(x, -0.5, 0, 0, 0.3, 0.08, 0.22, TM.f(TP.FN5));
    k.b(x, 0.5, 0, 0, 0.18, 0.15, 0.18, TM.f(TP.POT)); k.b(x, 0.5, 0.15, 0, 0.24, 0.2, 0.24, TM.f(TP.PL2));
  });
  return p;
})();

/** 一件家具放哪：x、z（null＝貼後牆）、y（null＝家具預設離地高）、a（繞 Y 轉） */
function S(id, x, z = null, { y = null, a = 0 } = {}) { return { id, x, z, y, a }; }

export const TowerProps = {
  def, books, all, S,
  /** 主題擺設表（10-20 UI/UX 優化 §3.3；座標是模組本地，x 協作區 −5.3…−2.3、工作區 −2.3…2.5、休憩角 2.5…5.3；z 前帶 1.1…2.8 只放 ≤0.9 高的）。
   *  排在前面的優先（★ 識別色那件在前）。跟 §3.3 表格不同的地方：兩座書櫃／兩台印表機的家具本來就是一組 3 格／2 台，只放一組；
   *  會互相撞到的照撞的結果微調了 x（例：時鐘移到伺服器機櫃上方、新聞電視移到咖啡車左邊） */
  layout(t) { return [S(`hero_${t}`, -3.6, 2.2)].concat(this.themeLayout(t)); },
  themeLayout(t) {
    switch (t) {
      case "monitor": return [S("status_beacon", 2.8), S("video_wall", 0.1), S("server_rack", -4.9), S("server_rack", -4.2), S("console1", -3.6, -1.4),
                              S("wall_clock", -5.15, null, { y: 2.05 }), S("wall_clock", -4.55, null, { y: 2.05 }), S("wall_clock", -3.95, null, { y: 2.05 }), S("bench", -4.2, 2.3)];
      case "app_studio": return [S("beanbag", -1.0, 2.2), S("phone_wall", -3.8, null, { y: 0.9 }), S("standing_desk", -3.8, -1.2), S("whiteboard", 0.1),
                                 S("device_cart", -1.9, -2.3), S("charging_shelf", 2.9)];
      case "library": return [S("reading_chair", -4.6, 2.0), S("bookshelf", -3.85), S("long_table", -3.8, -0.9), S("card_catalog", -1.6),
                              S("whiteboard", 0.6), S("globe", -3.2, 0.75)];
      case "print_shop": return [S("parts_bin", 2.8), S("printer", -4.55), S("workbench", -2.75), S("filament_rack", -0.6), S("finished_shelf", 1.0),
                                 S("box_stack", -4.4, 2.3)];
      case "call_room": return [S("phone_booth", -4.7, -2.15), S("switchboard", -3.3), S("tablet_stand", -1.6, -2.4), S("tablet_stand", -1.0, -2.4),
                                S("mail_rack", 0.8, null, { y: 1.3 }), S("sofa", -3.6, 2.2, { a: Math.PI }), S("side_table", -2.2, 2.3)];
      case "trading_desk": return [S("ticker_wall", 0.1), S("safe", -4.9), S("bull_statue", -3.7), S("quad_monitor", 0), S("news_tv", 3.0), S("bench", -4.0, 2.3)];
      case "media_studio": return [S("backdrop", -3.8), S("softbox", -5.0, -1.0), S("softbox", -2.7, -1.0), S("camera_tripod", -3.8, 0.3),
                                   S("edit_bay", 0.8), S("equipment_case", -2.6, 2.2)];
      case "design_studio": return [S("pendant_dome", 0.1, 0.5, { y: TD.clear - 0.85 }), S("drafting_table", -3.8, -1.2), S("easel", -5.0), S("moodboard", 0.1),
                                    S("material_shelf", -2.0), S("sample_table", -3.6, 2.2)];
      case "legal_room": return [S("document_safe", 2.8), S("conference_table", -3.8, -1.0), S("law_shelf", 0.4), S("file_cabinet", -1.5), S("seal_desk", -5.0)];
      case "ledger_room": return [S("brass_safe", 2.8), S("ledger_cabinet", -4.0), S("cashier_counter", -3.8, -0.9), S("ledger_shelf", 0.1),
                                  S("receipt_tray", 0), S("wall_clock", -1.2, null, { y: 2.0 })];
      case "game_lab": return [S("arcade", -5.0), S("arcade_n", -4.2), S("sprite_wall", 0.6), S("trophy_shelf", -1.2), S("playtest_tv", -2.8),
                               S("sofa", -2.8, 1.9, { a: Math.PI }), S("controller_shelf", -4.6, 2.3)];
      case "hw_lab": return [S("speaker_tower", 2.8), S("esd_bench", -3.8, -1.0), S("soldering_station", 0), S("test_rig", -5.0), S("parts_wall", 0.1),
                             S("cable_reel", -1.6), S("scope_cart", -2.6, 2.2)];
      case "marketing": return [S("content_wall", 0.1), S("product_table", -3.8, -1.0), S("ring_light", -5.0, -1.0), S("sofa", -3.6, 2.2, { a: Math.PI }), S("poster_stand", 2.8)];
      case "dispatch_room": return [S("route_map", 0.1), S("radio_desk", -3.8, -1.4), S("key_cabinet", -5.0, null, { y: 1.0 }), S("flight_board", -2.6, null, { y: 1.3 }),
                                    S("car_model", 0), S("luggage", -4.4, 2.3)];
      case "drafting_room": return [S("plan_table", -3.8, -1.0), S("plan_chest", -4.55), S("section_wall", 0.1), S("model_plinth", -1.6), S("roll_bin", -2.6, 2.3)];
      default: return [S("whiteboard", 0.1), S("meeting_table", -3.8, -0.9), S("bookshelf", -3.85)];       // general
    }
  },
  /** 每層都放的生活感組（§3.2），依優先序；整層家具（主題＋AI 擺設＋這組）最多 16 件，放滿就停。
   *  10-20 第 4 棒：評審「右側休息區每層一模一樣」⇒ 三種休息區輪流（樓層號 mod 3：咖啡角／沙發＋飲水機／小會議桌＋影印機），相鄰兩層一定不同；
   *  每種都至少 3 件放前帶（≤0.95 高） */
  common(variant) {
    const shared = [S("trash_bin", 99, 0), S("coat_rack", -5.0, TD.backZ + 0.35), S("plant_low", -5.6, 2.4)];
    switch (((variant % 3) + 3) % 3) {
      case 1:
        return [S("water_cooler", 4.4), S("copier", 3.1), S("sofa", 4.0, 2.1), S("side_table", 5.5, 2.2), S("news_tv", 4.4, null, { y: 1.5 }),
                S("plant_tall", 5.0, 0.6), S("box_stack", 2.0, 2.3)].concat(shared);
      case 2:
        return [S("coffee_cart", 3.2), S("meeting_table", 4.15, -0.5), S("bench", 4.1, 2.3), S("plant_tall", 4.85), S("wall_clock", 4.6, null, { y: 2.0 }),
                S("floor_lamp", 5.6, 1.0), S("box_stack", 2.4, 2.35)].concat(shared);
      default:
        return [S("coffee_cart", 3.9), S("lounge_chair", 3.3, 1.9), S("plant_tall", 4.85), S("side_table", 4.0, 2.05), S("wall_clock", 3.9, null, { y: 1.98 }),
                S("floor_lamp", 5.5, 1.0), S("lounge_chair", 4.7, 1.9)].concat(shared);
    }
  },
  maxItems: 12,      // 10-22 Kang：16 件太滿；加深後空間大，少一點才有呼吸感
};

// MARK: - 擺放（AABB 不重疊；放不下的丟掉）

export class PropBox {
  constructor(x0, x1, y0, y1, z0, z1) { this.x0 = F(x0); this.x1 = F(x1); this.y0 = F(y0); this.y1 = F(y1); this.z0 = F(z0); this.z1 = F(z1); }
  hits(o) { return this.x0 < o.x1 && o.x0 < this.x1 && this.y0 < o.y1 && o.y0 < this.y1 && this.z0 < o.z1 && o.z0 < this.z1; }
}

/** Swift Float 版的 Xf.apply（每一步捨入成 float32；sin／cos 用 double 算完再捨入，跟 sinf 最多差 1 ulp） */
function fapply(t, p) {
  const c = F(Math.cos(t.a)), s = F(Math.sin(t.a));
  return [F(F(t.x + F(p[0] * c)) + F(p[2] * s)), F(t.y + p[1]), F(F(t.z - F(p[0] * s)) + F(p[2] * c))];
}

export const PropPlacer = {
  /** AI 挑的、不在主題表裡的擺設：照列找空位（中心 z） */
  rowZ(d) {
    switch (d.row) {
      case R.wall: case R.high: return F(F(F(TD.backZ) + F(d.d / 2)) + F(0.02));
      case R.mid: return -1.6;
      case R.front: return 2.3;
      case R.ceiling: return 0.5;
      default: return 0;        // onDesk、onBench
    }
  },

  /** 影分身站位（10-22 Kang：「像幽靈半透明的娃娃站在窗台邊、有一點穿圖」——原本固定站 x −4.8 起、z 2.3，剛好疊在每層★大件 (−3.6, 2.2) 上）：
   *  前帶從左到右找沒被家具／座位帶佔走的 0.7×0.7 空地（站著的 Kubo 寬約 0.6），最多 4 格。回傳 [x, z] */
  ghostSpots(taken) {
    const out = [], used = taken.slice();
    for (const z of [F(2.2), F(1.85)]) {
      let x = F(-4.9);
      while (x <= F(4.9) && out.length < 4) {
        const b = new PropBox(F(x - F(0.35)), F(x + F(0.35)), 0, F(1.6), F(z - F(0.35)), F(z + F(0.35)));
        if (used.some(o => o.hits(b))) { x = F(x + F(0.2)); continue; }
        used.push(b); out.push([x, z]); x = F(x + F(0.85));
      }
    }
    return out;
  },

  /** 主題表 → AI 擺設 → 生活感組（最多 16 件）。desks＝每張桌子中心＋人面向角 a（[x, z, a]）；mirror＝樓層號奇數時協作區左右鏡射（同主題相鄰兩層不要一模一樣，§4.4）。
   *  回傳 { items: [[id, Xf]], front, dropped, ghostSpots } */
  place({ theme, props, desks, mirror, lounge = 0, log = () => {} }) {
    const taken = [];
    // 電梯門口、溜滑梯門口：不放家具
    for (const e of TD.elevs) taken.push(new PropBox(-6.2, -5.25, 0, 2.3, F(F(e.y) - F(0.65)), F(F(e.y) + F(0.65))));   // 兩部電梯門口（10-22）
    taken.push(new PropBox(5.3, 6.2, 0, 2.3, F(F(TD.zB) - F(0.1)), F(F(TD.zB) + F(0.7))));
    // 座位帶（桌椅＋坐著的人）：本地框 x ±0.75、z 往人那側 chairBack+0.45、另一側 0.4，依桌子朝向轉（側向時 x/z 對調）
    for (const [x, z, a] of desks) {
      const t = { x: F(x), y: 0, z: F(z), a: F(a) }, back = F(F(TowerLayout.chairBack) + F(0.45));
      const c = [[-0.75, -back], [0.75, -back], [-0.75, 0.4], [0.75, 0.4]].map(q => fapply(t, [F(q[0]), 0, F(q[1])]));
      taken.push(new PropBox(Math.min(...c.map(v => v[0])), Math.max(...c.map(v => v[0])), 0, 1.7, Math.min(...c.map(v => v[2])), Math.max(...c.map(v => v[2]))));
    }
    const r = { items: [], front: 0, dropped: [], ghostSpots: [] };
    let benchAt = null;
    const lo = F(F(-TD.W / 2) + F(0.15)), hi = F(F(TD.W / 2) - F(0.15));
    const box = (d, x, z, y0, a) => {
      const side = Math.abs(Math.sin(F(a))) > 0.5;
      const w = F(side ? d.d : d.w), dd = F(side ? d.w : d.d);
      return new PropBox(F(x - F(w / 2)), F(x + F(w / 2)), y0, F(F(y0) + F(d.h)), F(z - F(dd / 2)), F(z + F(dd / 2)));
    };
    const put = (s, auto = false) => {
      if (!(r.items.length < TowerProps.maxItems || [R.onDesk, R.onBench].includes(TowerProps.all[s.id]?.row))) return false;
      const d = TowerProps.all[s.id];
      if (!d) { log(`unknown prop ${s.id}`); return false; }
      switch (d.row) {
        case R.onDesk: {
          if (!desks.length) { r.dropped.push(s.id); log(`drop ${s.id}（沒有桌子）`); return false; }
          const [x, z, a] = desks[0];
          r.items.push([s.id, new Xf(x, 0.75, z, a).at(-0.35, 0, -0.05)]); return true;
        }
        case R.onBench: {
          if (!benchAt) { r.dropped.push(s.id); log(`drop ${s.id}（沒有工作台）`); return false; }
          r.items.push([s.id, benchAt.at(0.55, 0.75, 0)]); return true;
        }
        default: break;
      }
      let xs = [s.x];
      if (auto) xs = xs.concat([-4.0, -1.0, 2.0, -3.0, 1.0, -2.0, 3.0, 0, 4.0]);
      // 前帶的矮東西被★大件佔走位置：往右挪到角色前面再試（前帶只放 ≤0.95 高，不擋人）
      else if ((s.z ?? 0) > 1.1) xs = xs.concat([F(F(s.x) + F(2.6)), F(F(s.x) + F(3.6))]);
      for (const x0 of xs) {
        let x = F(x0);
        if (mirror && !auto && x < F(-2.3)) x = F(F(-7.6) - x);
        const z = F(s.z ?? F(F(F(TD.backZ) + F(d.d / 2)) + F(0.02)));
        const y0 = F(s.y ?? d.y0);
        const half = F(Math.abs(Math.sin(F(s.a))) > 0.5 ? d.d / 2 : d.w / 2);
        x = Math.min(Math.max(x, F(lo + half)), F(hi - half));
        const b = box(d, x, z, y0, s.a);
        // 前帶（z > 1.1）只放矮的（≤ 0.95，不擋人）
        //（★大件例外：它在角色左前方的協作區，不在任何人前面；高 1.25 以內）
        if (b.z1 > F(F(1.1) + F(0.05)) && z > F(1.1) && b.y1 > F(0.95) && !s.id.startsWith("hero_")) continue;
        if (taken.some(o => o.hits(b))) continue;
        taken.push(b);
        if (s.id === "esd_bench") benchAt = new Xf(x, 0, z);
        r.items.push([s.id, new Xf(x, y0, z, s.a)]);
        if (z > F(1.1)) r.front += 1;
        return true;
      }
      r.dropped.push(s.id); log(`drop ${s.id}（放不下）`);
      return false;
    };
    const table = TowerProps.layout(theme);
    for (const s of table) put(s);
    for (const id of props) {
      if (table.some(s => s.id === id) || !TowerProps.all[id]) continue;
      const d = TowerProps.all[id];
      put({ id, x: -4.0, z: this.rowZ(d), y: null, a: 0 }, true);
    }
    // 垃圾桶：第一張桌子旁邊（依朝向的右側 0.95）
    for (const s of TowerProps.common(lounge)) {
      if (s.id === "trash_bin") {
        if (!desks.length) continue;
        const [x, z, a] = desks[0];
        const p = fapply({ x: F(x), y: 0, z: F(z), a: F(a) }, [F(0.95), 0, F(-0.1)]);
        put({ id: s.id, x: p[0], z: p[2], y: null, a });
      } else put(s);
    }
    r.ghostSpots = this.ghostSpots(taken);
    return r;
  },
};

export { Kit, TowerSpec };
