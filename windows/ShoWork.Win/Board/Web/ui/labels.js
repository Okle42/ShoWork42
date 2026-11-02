// OfficeLabels.swift 照搬（11-02 P8）：螢幕空間標籤（人物名牌、樓層名、城市名牌、+N 人）。
//   原本名牌與頭上符號畫在 3D 世界裡，跟著樓層一起縮：預設鏡頭下名牌 4.8 pt、門牌 5.9 pt，在電視上完全讀不到。
//   改成疊在 3D 上的一層（Mac：CALayer；這裡：HTML 疊層 #labels），固定點數：名字 14 pt、等你回答 16 pt。
//   位置只在「真的有畫一幀」時才算（Mac：didApplyConstraints；這裡：office.js 每畫一幀呼叫 frame()）：閒置不渲染時不會跑，不加 timer。
//   不讀深度、永遠在 3D 之上（被上一層樓板擋住的人照樣看得到）；碰撞避讓用 core.js 的 LabelLayout（ShoWorkCore 照搬）。
//   點標籤＝點角色（office.js 先問這裡、再問 3D）。
// 座標：跟 Swift 一樣用「view 座標、y 往上」（SceneKit projectPoint 的座標系），只在擺 DOM 時翻成 CSS 的 top。
// 字型：Mac 是系統字（SF）；Windows 用 "Segoe UI", "Microsoft JhengHei"。字寬用 canvas measureText 量（跟 DOM 同一個字型字串），
//   所以標籤框的大小跟 Mac 一樣「字寬＋留白」，只是字型本身寬度不同。

import * as THREE from "three";
import { TD, TP, TowerSpec } from "../kit.js";
import { KuboArt } from "../scene/builder.js";
import { LabelKind, LabelBox, PlacedLabel, LabelLayout, Board, overlapsP } from "./core.js";

export const FONT_STACK = `"Segoe UI", "Microsoft JhengHei UI", "Microsoft JhengHei", "PingFang TC", system-ui, sans-serif`;

/** 一個要畫的標籤（主執行緒組好） */
export function LabelSpec({ id, kind, text, bg, bgAlpha, dot = null, anchor = null, floor, short = null, fg = null, glass = false }) {
  return { id, kind, text, bg, bgAlpha, dot, anchor, floor, short, fg, glass };
}

const hex6 = (c, a = 1) => `rgba(${(c >>> 16) & 255},${(c >>> 8) & 255},${c & 255},${a})`;
const rect = (x, y, w, h) => ({ x, y, w, h });
const rectHits = (r, p) => p.x >= r.x && p.x <= r.x + r.w && p.y >= r.y && p.y <= r.y + r.h;
const rectsMeet = (a, b) => a.x < b.x + b.w && b.x < a.x + a.w && a.y < b.y + b.h && b.y < a.y + a.h;
const inScene = n => { let p = n; while (p) { if (p.isScene) return true; p = p.parent; } return false; };

export class OfficeLabels {
  /** 拉近到多近才顯示（樓層在畫面上的高度，點） */
  static detailPx = 70; static floorNamePx = 80; static idleNamesPx = 48; static idleTitlePx = 24;
  static maxTextures = 64;

  constructor(host) {
    this.view = host;                   // 疊在 3D 上、不吃滑鼠的那一層
    this.specs = []; this.floors = [];
    this.size = { width: 10, height: 10 };
    this.textures = new Map();          // 同字串只量一次、只建一次 DOM 樣式（超過 64 個整批清掉）
    this.shownSig = "";
    this.hits = [];
    this.lastStats = "";
    this.occluder = null;
    this.layers = new Map(); this.leaders = new Map();
    this.ctx = document.createElement("canvas").getContext("2d");
    this.v = new THREE.Vector3();
  }

  // MARK: 主執行緒：交資料

  set(specs, floors) { this.specs = specs; this.floors = floors; }
  resize(w, h) { this.size = { width: w, height: h }; }
  /** 左下角開著卡片（回答卡、保全卡、細節卡）：那一塊不畫標籤（標籤層在 3D 上面，會疊到卡片的字） */
  setOccluder(r) {
    const changed = JSON.stringify(this.occluder) !== JSON.stringify(r);
    this.occluder = r; if (changed) this.shownSig = "";
  }
  /** 點到哪個標籤（座標＝view 座標，y 往上） */
  label(p) {
    for (let i = this.hits.length - 1; i >= 0; i--) {
      const [id, r] = this.hits[i];
      if (rectHits(r, p) && !id.startsWith("floor:") && !id.startsWith("more:")) return id;
    }
    return null;
  }
  /** 某個標籤現在的框（PROBE 點點看用） */
  rect(id) { return this.hits.find(h => h[0] === id)?.[1] ?? null; }
  get stats() { return this.lastStats + ` textures=${this.textures.size}`; }

  /** SceneKit 的 projectPoint：x、y＝view 點（y 往上），z＝0（近）…1（遠）；鏡頭背後 z > 1 */
  project(camera, p) {
    const v = this.v.set(p[0] ?? p.x, p[1] ?? p.y, p[2] ?? p.z).project(camera);
    return { x: (v.x + 1) / 2 * this.size.width, y: (v.y + 1) / 2 * this.size.height, z: (v.z + 1) / 2 };
  }
  wp(n) { const w = n.getWorldPosition(new THREE.Vector3()); return w; }

  // MARK: 每畫一幀（Swift：renderer(_:didApplyConstraintsAtTime:)）

  frame(camera) {
    const specs = this.specs, floors = this.floors, size = this.size, occ = this.occluder;
    const W = size.width, H = size.height;
    const cam = camera.getWorldPosition(new THREE.Vector3());
    const P = q => this.project(camera, q);
    const hw = TD.W / 2, hd = TD.zF, hb = TD.zB;
    // 面向鏡頭的那一面（10-20 第 4 棒：轉到側面時，樓層名要貼在「看得到的那面」的左上角，不是固定在正面）
    const faces = [[0, 1, [[-hw, hd], [hw, hd]]], [1, 0, [[hw, hd], [hw, hb]]], [0, -1, [[hw, hb], [-hw, hb]]], [-1, 0, [[-hw, hb], [-hw, hd]]]];
    let best = faces[0];
    for (const f of faces) if (f[0] * cam.x + f[1] * cam.z > best[0] * cam.x + best[1] * cam.z) best = f;
    const face = best[2];
    // 每層：世界 y 範圍＋看得到那面的左上／右上、左下（點）
    const geo = new Map();
    for (const f of floors) {
      const y = this.wp(f.node).y, top = y + f.height;
      const p0 = P([face[0][0], top, face[0][1]]), p1 = P([face[1][0], top, face[1][1]]);
      const [a, b, left] = p0.x <= p1.x ? [p0, p1, face[0]] : [p1, p0, face[1]];
      const right = left === face[0] ? face[1] : face[0];
      let bl = P([left[0], y + TD.room, left[1]]);
      const br = P([right[0], y + TD.room, right[1]]);
      // 拉近時樓層左角在畫面外：沿著樓板前緣（畫面上是直線）取畫面左緣那一點，不用畫面外的延伸點（10-20 第 4 棒：04 的名字掛到 05 裡）
      let tl = a;
      if (a.x < 4 && b.x > a.x) {
        const t = (4 - a.x) / (b.x - a.x);
        tl = { x: 4, y: a.y + (b.y - a.y) * t, z: a.z + (b.z - a.z) * t };
        const tb = (4 - bl.x) / Math.max(0.001, br.x - bl.x);
        bl = { x: 4, y: bl.y + (br.y - bl.y) * tb, z: bl.z };
      }
      // front：這層看得到那面的兩個上角都在鏡頭前面（10-21 稽核：大樓整個在鏡頭背後時，投影出來的點會落在畫面裡，名字掛在空中）
      const front = [p0, p1, bl, br].every(q => q.z > 0 && q.z < 1);
      geo.set(f.id, { y0: y, y1: top, tl, tr: b, bl, br, px: Math.abs(tl.y - bl.y), front });
    }
    /** 這一點朝鏡頭水平走到大樓外緣（樓板前緣就是你眼睛看到的那條線） */
    const edge = p => {
      let dx = cam.x - p.x, dz = cam.z - p.z;
      const l = Math.max(0.001, Math.hypot(dx, dz)); dx /= l; dz /= l;
      const tx = dx > 0.001 ? (hw - p.x) / dx : dx < -0.001 ? (-hw - p.x) / dx : Infinity;
      const tz = dz > 0.001 ? (hd - p.z) / dz : dz < -0.001 ? (-hd - p.z) / dz : Infinity;
      const t = Math.max(0, Math.min(tx, tz));
      return [p.x + dx * t, p.z + dz * t];
    };
    // 樓層名（先放、當障礙物）：只在那層真的在畫面裡、標籤整塊塞得進那層時畫；畫面外的樓層不夾到畫面頂端
    const text = new Map();
    let fixed = [];
    for (const f of floors) {
      // 10-21 稽核：整棟在畫面左邊外面時，「沿樓板前緣取畫面左緣那一點」會外插出一個假的點 ⇒ 右角也要在畫面裡
      const g = geo.get(f.id);
      if (!(g && g.front && g.tl.z > 0 && g.tl.z < 1 && g.tr.x > 60 && g.tl.x < W - 40)) continue;
      const need = f.kind === "idle" ? OfficeLabels.idleTitlePx : OfficeLabels.floorNamePx;
      if (!(g.px >= need)) continue;
      const s = LabelSpec({ id: `floor:${f.id}`, kind: LabelKind.floor, text: f.title, bg: 0x14161A, bgAlpha: 0.86, dot: f.accent, floor: f.id });
      const t = this.texture(s);
      const x = Math.max(2, g.tl.x + 8);
      // 11-03（Windows 補）：沒有閒置薄層時 Okle42 招牌改掛在大廳正面頂端（TowerModules.lobby(sign)，招牌底邊＝大廳高 −0.55），
      //   樓層名照原本的「頂端往下 8 點」會整塊壓在招牌上。Mac 規則是「招牌那層的名字不擋招牌」（閒置薄層的名字不畫）；
      //   有閒置薄層時大廳名字就在招牌正下方 ⇒ 這裡同樣改從招牌底邊往下排。Mac 的 Kang 一直有閒置層，所以 Mac 上沒出現過
      let top = g.tl.y;
      if (f.kind === "lobby" && !floors.some(x => x.kind === "idle")) top = this.signBottom(P, g, face, this.wp(f.node).y + TowerSpec.lobbyHeight - 0.55);
      const y = f.kind === "idle" ? (g.tl.y + g.bl.y) / 2 - t.h / 2 : Math.min(top - t.h - 8, H - t.h - 4);
      if (!((y >= g.bl.y + 2 || f.kind === "idle") && y >= 2 && y + t.h <= H && x + t.w <= W)) continue;
      text.set(s.id, [s, t]);
      fixed.push(PlacedLabel({ id: s.id, kind: LabelKind.floor, x, y, w: t.w, h: t.h, leader: false, ax: 0, ay: 0 }));
    }
    // 每個人：錨點投影；自己那層的天花／地坪（朝鏡頭的外緣）在畫面上的 y ⇒ 標籤不得越層
    const boxes = [], cityBoxes = [], cityDist = new Map(), hiddenSmall = {}, anchorAt = new Map();
    for (let s of specs) {
      // 錨點已經不在場景裡（出港的船開完了）：不畫
      const anchor = s.anchor;
      if (!anchor || !anchor.parent || !inScene(anchor)) continue;
      const wp = this.wp(anchor);
      const p = P(wp);
      if (!(p.z > 0 && p.z <= 1 && p.x > -40 && p.x < W + 40 && p.y > -40 && p.y < H + 60)) continue;
      // 外部空間城市（10-21）：不屬於任何樓層；另外放（大樓當障礙物，名牌不壓到大樓）
      if (s.floor === "city") {
        if (!(p.x >= 0 && p.x <= W && p.y >= 0 && p.y <= H)) continue;
        const t = this.texture(s);
        text.set(s.id, [s, t]);
        anchorAt.set(s.id, p);
        cityBoxes.push(LabelBox({ id: s.id, kind: s.kind, ax: p.x, ay: p.y, w: t.w, h: t.h, group: "city" }));
        cityDist.set(s.id, Math.hypot(wp.x - cam.x, wp.z - cam.z));      // 水平距離（跟大樓軸比）
        continue;
      }
      // 錨點在哪一層（走在路上的人照所在高度算）；B1（地面以下，10-22）：自成一組、不受樓層天花限制
      const fid = wp.y < -0.5 ? "b1" : floors.find(f => { const g = geo.get(f.id); return g ? wp.y >= g.y0 && wp.y < g.y1 : false; })?.id ?? s.floor;
      let ceil = Infinity, bottom = -Infinity, floorPx = 999;
      const g = geo.get(fid);
      if (g) {
        const [ex, ez] = edge(wp);
        const c = P([ex, g.y1, ez]), b = P([ex, g.y0 + TD.room, ez]);
        ceil = c.y + 3; bottom = b.y + 2;      // 評審上限：天花 +4 pt
        // 轉到側面時人在樓層深處：頭頂已經在上一層樓板前緣「上面」⇒ 改用人那個深度的天花，名牌跟著頭走
        if (p.y + 4 > ceil) ceil = P([wp.x, g.y1, wp.z]).y + 3;
        floorPx = g.px;
      }
      if (!LabelKind.mustShow(s.kind) && floorPx < OfficeLabels.detailPx) { hiddenSmall[fid] = (hiddenSmall[fid] ?? 0) + 1; continue; }
      if (floorPx < OfficeLabels.detailPx && s.short) s = { ...s, text: s.short, fg: s.fg, glass: s.glass };
      const t = this.texture(s);
      text.set(s.id, [s, t]);
      anchorAt.set(s.id, p);
      boxes.push(LabelBox({ id: s.id, kind: s.kind, ax: p.x, ay: p.y, w: t.w, h: t.h, group: fid, ceil, floorY: bottom }));
    }
    const { placed, hidden } = LabelLayout.place(boxes, W, H, fixed);
    // 每層被收起來的「+N」放在那層看得到那面的右上角；收起來的有等你／卡住的 ⇒ 紅底
    const urgentHidden = new Set(boxes.filter(b => LabelKind.mustShow(b.kind) && !placed.some(p => p.id === b.id)).map(b => b.group));
    const more = [];
    const merged = { ...hidden };
    for (const [k, n] of Object.entries(hiddenSmall)) merged[k] = (merged[k] ?? 0) + n;
    for (const [fid, n] of Object.entries(merged)) {
      if (!(n > 0)) continue;
      const g = geo.get(fid);
      if (!g) continue;
      const urgent = urgentHidden.has(fid);
      const s = LabelSpec({ id: `more:${fid}`, kind: LabelKind.more, text: urgent ? `! +${n} 人` : `+${n} 人`, bg: urgent ? 0xEF4444 : 0x14161A,
                            bgAlpha: urgent ? 1 : 0.75, floor: fid });
      const t = this.texture(s);
      text.set(s.id, [s, t]);
      if (!(g.front && g.tr.x > 60 && g.tl.x < W - 40)) continue;
      const y0 = Math.min(g.tr.y - t.h - 8, H - t.h - 4);
      if (!(y0 >= g.bl.y)) continue;
      // 10-21 稽核：「+N 人」原本直接蓋在那層右上角，會壓到已經放好的名牌 ⇒ 往下、再往左找空位
      const x0 = Math.min(g.tr.x - t.w - 8, W - t.w - 4);
      const others = [...fixed, ...placed, ...more];
      const free = (x, y) => !others.some(o => x < o.x + o.w + 4 && o.x < x + t.w + 4 && y < o.y + o.h + 3 && o.y < y + t.h + 3);
      let spot = null;
      search: for (let dx = 0; dx <= 240; dx += 60) {
        for (let dy = 0; dy <= y0 - g.bl.y; dy += t.h + 4) {
          if (!(x0 - dx >= 2)) continue;
          if (free(x0 - dx, y0 - dy)) { spot = [x0 - dx, y0 - dy]; break search; }
        }
      }
      if (!spot) continue;
      more.push(PlacedLabel({ id: s.id, kind: LabelKind.more, x: spot[0], y: spot[1], w: t.w, h: t.h, leader: false, ax: 0, ay: 0 }));
    }
    // 城市名牌：大樓（每層一塊，含電梯井、溜滑梯）在畫面上的範圍當障礙物，再避開已經放好的標籤
    const bldg = [];
    let cityPlaced = [], cityHidden = 0;
    if (cityBoxes.length) {
      for (const f of floors) {
        const y0 = this.wp(f.node).y, y1 = y0 + f.height + (f.kind === "roof" ? 1.2 : 0);
        let x0 = Infinity, x1 = -Infinity, b0 = Infinity, b1 = -Infinity, ok = true;
        for (const x of [-7.9, 6.6]) for (const y of [y0, y1]) for (const z of [-4.6, 3.0]) {
          const q = P([x, y, z]);
          if (q.z <= 0 || q.z >= 1) ok = false;
          x0 = Math.min(x0, q.x); x1 = Math.max(x1, q.x); b0 = Math.min(b0, q.y); b1 = Math.max(b1, q.y);
        }
        if (!ok) continue;
        bldg.push(PlacedLabel({ id: `bldg:${f.id}`, kind: LabelKind.floor, x: x0, y: b0, w: x1 - x0, h: b1 - b0, leader: false, ax: 0, ay: 0 }));
      }
      // 10-21 稽核：被大樓擋住的建築（錨點在大樓畫面範圍內、而且比大樓離鏡頭遠）名牌不畫
      const towerDist = Math.hypot(cam.x, cam.z) + TD.zF;
      const keep = cityBoxes.filter(b => !((cityDist.get(b.id) ?? 0) > towerDist && bldg.some(r => b.ax >= r.x && b.ax <= r.x + r.w && b.ay >= r.y && b.ay <= r.y + r.h)));
      const r = LabelLayout.place(keep, W, H, [...fixed, ...bldg, ...placed, ...more]);
      cityPlaced = r.placed; cityHidden = Object.values(r.hidden).reduce((a, b) => a + b, 0);
    }
    // 10-22：閒置薄層正面已是 Okle42 招牌，樓層名和專案名字標籤會擋住招牌 ⇒ 都不畫（清單在左側索引列「閒置」）
    const idleIds = new Set(floors.filter(f => f.kind === "idle").map(f => `floor:${f.id}`));
    fixed = fixed.filter(p => !idleIds.has(p.id));
    const all = [...fixed, ...cityPlaced.slice().reverse(), ...placed.slice().reverse(), ...more];      // 後畫的在上面：優先序高的最後畫
    const items = [];
    for (const p of all) {
      const e = text.get(p.id);
      if (!e) continue;
      const [s, t] = e;
      if (occ && rectsMeet(occ, rect(p.x, p.y, t.w, t.h))) continue;
      items.push({ id: p.id, spec: s, tex: t, frame: rect(Math.round(p.x), Math.round(p.y), t.w, t.h),
                   leader: p.leader ? rect(p.ax - 0.75, p.ay, 1.5, Math.max(1, p.y - p.ay)) : null });
    }
    // 有變才改 DOM（位置四捨五入到點；鏡頭沒動時每幀都一樣 ⇒ 不動）
    const sig = items.map(it => `${it.id}@${it.frame.x},${it.frame.y}|${it.tex.key}`).join(";");
    if (sig !== this.shownSig) { this.shownSig = sig; this.apply(items); }
    this.hits = [...placed, ...cityPlaced, ...more, ...fixed].map(p => [p.id, rect(p.x, p.y, p.w, p.h)]);
    // 驗收：標籤離本人頭頂多遠、有沒有越過自己那層的天花
    const minH = placed.length ? Math.min(...placed.map(p => p.h)) : 0;
    let maxDist = 0, outOfFloor = 0;
    for (const p of placed) {
      const a = anchorAt.get(p.id), b = boxes.find(x => x.id === p.id);
      if (!a || !b) continue;
      const dx = Math.max(p.x - a.x, 0, a.x - (p.x + p.w)), dy = Math.max(p.y - a.y, 0, a.y - (p.y + p.h));
      maxDist = Math.max(maxDist, Math.hypot(dx, dy));
      if (p.y + p.h > b.ceil + 1 || p.y < b.floorY - 1) outOfFloor += 1;
    }
    const cityOnBldg = cityPlaced.filter(c => bldg.some(b => overlapsP(b, c))).length;
    const kinds = {};
    for (const p of placed) kinds[LabelKind.name(p.kind)] = (kinds[LabelKind.name(p.kind)] ?? 0) + 1;
    this.lastStats = `labels n=${placed.length} overlaps=${LabelLayout.overlaps([...placed, ...fixed, ...more, ...cityPlaced])} city=${cityPlaced.length}/hidden ${cityHidden}/onBuilding ${cityOnBldg} more=${more.length} floors=${fixed.length} `
      + `minH=${minH.toFixed(0)}pt maxDist=${maxDist.toFixed(0)}pt outOfFloor=${outOfFloor} kinds=` + Object.entries(kinds).map(([k, v]) => `${k}:${v}`).sort().join(",")
      + " floorNames=" + fixed.map(p => p.id.replace("floor:", "")).join(",");
    this.placedNow = { placed, cityPlaced, more, fixed, anchorAt };
  }

  /** 看得到那面左緣在高度 yS（世界）的畫面 y：同樓層幾何的取法（左角在畫面外 ⇒ 沿那條線取畫面左緣 x＝4 那點） */
  signBottom(P, g, face, yS) {
    const q0 = P([face[0][0], yS, face[0][1]]), q1 = P([face[1][0], yS, face[1][1]]);
    const [a, b] = q0.x <= q1.x ? [q0, q1] : [q1, q0];
    if (a.x < 4 && b.x > a.x) return a.y + (b.y - a.y) * (4 - a.x) / (b.x - a.x);
    return a.y;
  }

  // MARK: 「貼圖」：Mac 畫成 2× 點陣圖；這裡量字寬、定框的大小與樣式（同字串只量一次；超過 64 個整批清掉）

  texture(s) {
    const key = `${s.kind}|${s.bg}|${s.dot ?? 0}|${s.fg ?? 0}|${s.glass}|${s.text}`;
    const t = this.textures.get(key);
    if (t) return t;
    if (this.textures.size >= OfficeLabels.maxTextures) this.textures.clear();
    const n = this.draw(s); n.key = key;
    this.textures.set(key, n);
    return n;
  }

  /** NSFont.systemFont(ofSize:weight:) */
  static font(k) {
    switch (k) {
      case LabelKind.waiting: return [16, 800];
      case LabelKind.stuck: return [14, 700];
      case LabelKind.finished: case LabelKind.working: return [14, 600];
      case LabelKind.rest: case LabelKind.idleName: case LabelKind.more: return [13, 500];
      case LabelKind.floor: case LabelKind.guardian: return [13, 600];
      case LabelKind.cityAlert: return [14, 700];
      default: return [12, 500];        // city
    }
  }
  measure(text, size, weight) {
    this.ctx.font = `${weight} ${size}px ${FONT_STACK}`;
    return { w: this.ctx.measureText(text).width, h: Math.ceil(size * 1.2) };     // NSString.size 的高度≈字級 ×1.19（SF）
  }

  /** 圓角底＋字（樣式交給 apply 建 DOM）：回傳框的大小（點）＋樣式 */
  draw(s) {
    if (s.glass) return this.drawGlass(s);
    const [size, weight] = OfficeLabels.font(s.kind);
    const fg = s.kind === LabelKind.rest ? "#D6D3CE" : s.kind === LabelKind.idleName ? hex6(TP.INK ?? 0x2A2A2A) : "#FFFFFF";
    const ts = this.measure(s.text, size, weight);
    const padX = 7, dotW = s.dot === null || s.dot === undefined ? 0 : (s.kind === LabelKind.floor ? 7 : 12);
    const W = Math.ceil(ts.w + padX * 2 + dotW), H = Math.ceil(ts.h + 6);
    return { w: W, h: H, size, weight, fg, padX, dotW, glass: false };
  }

  /** 玻璃名牌（hig42 §3.1a）：膠囊形、約 40% 深色暗化層、上半部一道淡白反光、上緣亮的邊光，字用狀態色＋一圈淡陰影 */
  drawGlass(s) {
    const [size, weight] = OfficeLabels.font(s.kind);
    const ts = this.measure(s.text, size, weight);
    const padX = 9;
    const W = Math.ceil(ts.w + padX * 2), H = Math.ceil(ts.h + 7);
    return { w: W, h: H, size, weight, fg: s.fg !== null && s.fg !== undefined ? hex6(s.fg) : "#FFFFFF", padX, dotW: 0, glass: true };
  }

  /** 標籤那一層：每個標籤一個 div（Mac：CALayer）、被往上推的畫一條 1.5 點引線。不吃滑鼠（點擊由 office.js 問 label()） */
  apply(items) {
    const H = this.size.height;
    const used = new Set();
    items.forEach((it, z) => {
      used.add(it.id);
      let el = this.layers.get(it.id);
      if (!el) { el = document.createElement("div"); el.className = "lbl"; this.view.appendChild(el); this.layers.set(it.id, el); }
      if (el.dataset.key !== it.tex.key) { el.dataset.key = it.tex.key; this.style(el, it.spec, it.tex); }
      el.style.transform = `translate(${it.frame.x}px, ${H - it.frame.y - it.frame.h}px)`;
      el.style.zIndex = String(2 * z + 2);
      if (it.leader) {
        let ld = this.leaders.get(it.id);
        if (!ld) { ld = document.createElement("div"); ld.className = "lbl-leader"; this.view.appendChild(ld); this.leaders.set(it.id, ld); }
        const r = it.leader;
        ld.style.transform = `translate(${r.x}px, ${H - r.y - r.h}px)`;
        ld.style.height = `${r.h}px`; ld.style.zIndex = String(2 * z + 1); ld.hidden = false;
      } else { const ld = this.leaders.get(it.id); if (ld) ld.hidden = true; }
    });
    for (const [id, el] of this.layers) if (!used.has(id)) { el.remove(); this.layers.delete(id); this.leaders.get(id)?.remove(); this.leaders.delete(id); }
  }

  style(el, s, t) {
    el.textContent = "";
    el.className = "lbl" + (t.glass ? " glass" : "") + (s.kind === LabelKind.rest ? " rest" : "");
    Object.assign(el.style, {
      width: `${t.w}px`, height: `${t.h}px`, lineHeight: `${t.h}px`, font: `${t.weight} ${t.size}px ${FONT_STACK}`, color: t.fg,
      paddingLeft: `${t.padX + t.dotW}px`, borderRadius: t.glass ? `${t.h / 2}px` : "6px",
      background: t.glass ? "" : hex6(s.bg, s.bgAlpha), "--fg": t.fg,
    });
    if (t.glass) el.style.setProperty("--tint", t.fg);
    el.append(document.createTextNode(s.text));
    if (!t.glass && s.dot !== null && s.dot !== undefined) {      // 玻璃名牌不畫點（drawGlass 沒有點）
      const d = document.createElement("i");
      d.className = s.kind === LabelKind.floor ? "bar" : "dot";
      d.style.background = hex6(s.dot);
      if (s.kind !== LabelKind.floor) { d.style.left = `${t.padX}px`; d.style.top = `${(t.h - 8) / 2}px`; }
      el.append(d);
    }
  }

  // MARK: 文字（組 LabelSpec 時用）

  static shortName(c) {
    const n = String(c.title ?? "").split("-")[0] ?? c.title;
    const a = [...n];
    return a.length > 14 ? a.slice(0, 13).join("") + "…" : n;
  }
  static blockedShort(r) {
    switch (r) {
      case "permission": return "權限";
      case "rateLimit": return "額度";
      case "apiError": return "API 錯誤";
      case "testRun": return "測試跑很久";
      case "build": return "建置跑很久";
      case "install": return "安裝跑很久";
      default: return "卡住";
    }
  }

  /** 狀態色（跟終端機發光同一組設定）。太暗的顏色往白提亮，玻璃上才讀得到 */
  static glassText(m) {
    const c = KuboArt.tint(m);
    let r = c.r, g = c.g, b = c.b;
    const lum = 0.2126 * r + 0.7152 * g + 0.0722 * b;
    if (lum < 0.45) { const k = Math.min(0.6, (0.45 - lum) / 0.45 + 0.15); r += (1 - r) * k; g += (1 - g) * k; b += (1 - b) * k; }
    return (Math.trunc(r * 255) << 16) | (Math.trunc(g * 255) << 8) | Math.trunc(b * 255);
  }

  /** 一個人的標籤（狀態決定樣式）。10-23：名字前不放 ✓／!／?／🔒 符號，狀態只靠字色分；休息 ☕／🧠、睡著 Zzz 保留 */
  static spec(c, mood, anchor, floor) {
    const l = OfficeLabels.plainSpec(c, mood, anchor, floor);
    l.glass = true;
    l.fg = mood === "idle" || mood === "asleep" ? 0xE7E5E4 : OfficeLabels.glassText(mood);
    return l;
  }
  static plainSpec(c, mood, anchor, floor) {
    const name = OfficeLabels.shortName(c);
    switch (mood) {
      case "waiting": {
        let q;
        if (c.blockedReason === "permission") q = "等你按允許";
        else if (c.report?.ask) q = "要你決定：" + Board.plain(c.report.ask);
        else q = c.reason;
        const qa = [...q], qs = qa.length > 14 ? qa.slice(0, 14).join("") + "…" : q;
        return LabelSpec({ id: c.id, kind: LabelKind.waiting, text: `${name}・${qs}`, bg: 0xEF4444, bgAlpha: 1, anchor, floor, short: name });
      }
      case "stuck":
        return LabelSpec({ id: c.id, kind: LabelKind.stuck, text: `${name}・${OfficeLabels.blockedShort(c.blockedReason)}`, bg: 0xF97316, bgAlpha: 1, anchor, floor, short: name });
      case "finished":
        return LabelSpec({ id: c.id, kind: LabelKind.finished, text: name, bg: 0x16A34A, bgAlpha: 1, anchor, floor });
      case "working": {
        const subs = (c.subagents ?? []).length;
        return LabelSpec({ id: c.id, kind: LabelKind.working, text: subs > 0 ? `${name}・子 agent ${subs}` : name, bg: 0x14161A, bgAlpha: 0.82, dot: 0xA78BFA, anchor, floor });
      }
      case "idle":
        // B1 機房禁止飲食（10-22）：在那裡休息的是在看神經網路，不是喝咖啡
        return LabelSpec({ id: c.id, kind: LabelKind.rest, text: `${floor === "b1" ? "🧠" : "☕"} ${name}`, bg: 0x14161A, bgAlpha: 0.6, anchor, floor });
      default:
        return LabelSpec({ id: c.id, kind: LabelKind.rest, text: `Zzz ${name}`, bg: 0x14161A, bgAlpha: 0.6, anchor, floor });
    }
  }

  /** 城市建築的名牌：正常小字深底；警示紅底、跟等你同級 */
  static citySpec(id, text, alert, anchor) {
    return LabelSpec({ id, kind: alert ? LabelKind.cityAlert : LabelKind.city, text: alert ? "! " + text : text, bg: alert ? 0xDC2626 : 0x14161A,
                       bgAlpha: alert ? 1 : 0.72, anchor, floor: "city" });
  }

  static guardSpec(g, scanning, anchor) {
    // 10-24：名牌改英文「🛡️ Security」；狀態靠字色分（掃描中藍、注意橘、正常綠），只有警示在最後加 🚨
    const t = !scanning && g.level === "alert" ? "🛡️ Security 🚨" : "🛡️ Security";
    const fg = scanning ? 0x7DB8FF : g.level === "alert" ? OfficeLabels.glassText("waiting") : g.level === "notice" ? OfficeLabels.glassText("stuck") : OfficeLabels.glassText("finished");
    return LabelSpec({ id: "guard", kind: LabelKind.guardian, text: t, bg: 0, bgAlpha: 0, anchor, floor: "lobby", fg, glass: true });
  }
}

