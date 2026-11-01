// OfficeTower.swift 照搬（11-02）：科技大樓剖面的零件（10-20 Kang 拍板，規範 docs/design/office-tower/設計規範.md）。
//   一層樓＝一個模組（原點在樓板底面中心）：靜態東西（樓板、地坪、家具、桌子、吊燈、窗框）依材質合併成一個 VoxelMesh；
//   會被 cutaway 淡掉的四面牆（front 玻璃、back、left、right）各自一個節點；門牌一個節點。
//   素色：地坪全樓只有 FL-1 淺白橡木（辦公樓層、頂樓）與 FL-2 淺灰磨石（大廳、閒置薄層），不准依部門換色；
//   部門只靠主題家具（一件 ★ 用識別色）＋門牌色條區分。
//   電梯（左外側）、溜滑梯（右外側）、結構柱、天際線在模組外面，搬家飄出時不會撞到。
// 場景組裝在 builder.js（OfficeBuilder.swift）；動畫（搬家、閒晃）的每幀計算在這個檔最後的 MoveAnim／TripPath。
// TP／TD／TM／Kit 在 kit.js（OfficeTower.swift 開頭那段）；TowerProps／PropPlacer 在 tower-props.js（檔太長拆出去，這裡整包再 export）。
//
// SceneKit → three 對照（這個檔用到的）：
//   SCNBox／SCNPlane 用 three 的 BoxGeometry／PlaneGeometry；吃光的材質（TM.*）一律開頂點色 ⇒ 幾何要補一條全白的 color 屬性（scnBox()）。
//   .constant＋黑色 diffuse＋emission（車廂光暈）＝只剩 emission ⇒ 用 Lambert 黑底＋emissive，userData.lm＝"constant"（dump 的 key 跟 Mac 一樣）。
//   renderingOrder ＝ renderOrder；castsShadow 沒有陰影 ⇒ 不用。

import * as THREE from "three";
import { VoxelMesh, Kit, Xf, VoxMat, TP, TD, TM, TowerSpec, TowerLayout, SColor, skyCube, skyGlowCube, scnNode, setEuler } from "../kit.js";
import { OfficeBasement } from "./basement.js";
import { Act, runAction, removeAction, setNodeOpacity } from "./actions.js";
import { TowerProps, PropPlacer, PropBox, PropRow, TowerTheme, towerDesk, towerSpin } from "./tower-props.js";

export { TowerProps, PropPlacer, PropBox, PropRow, TowerTheme, towerDesk, towerSpin };

// MARK: - 小工具

/** SCNBox（chamfer 預設 0）：補全白頂點色（TM 的材質開 vertexColors）；chamfer ≠ 0 記在 userData.scn 給 dump 照抄 */
function scnBox(w, h, l, mat, chamfer = 0) {
  const g = new THREE.BoxGeometry(w, h, l);
  g.setAttribute("color", new THREE.Float32BufferAttribute(new Float32Array(g.attributes.position.count * 3).fill(1), 3));
  const n = new THREE.Mesh(g, mat);
  if (chamfer !== 0) n.userData.scn = { type: "SCNBox", params: { w, h, l, chamfer } };
  return n;
}
/** NSString.size(withAttributes:)：寬＝字寬＋每個字後面的 kern；高＝字型行高（ascender＋descender） */
function textSize(cx, s, kern) {
  const mt = cx.measureText(s);
  const asc = mt.fontBoundingBoxAscent, desc = mt.fontBoundingBoxDescent;
  return { width: mt.width + kern * [...s].length, height: asc + desc, asc, desc };
}
/** 畫字（AppKit 的 draw(at:) 原點在字框左下 ⇒ 換成 canvas 的左上原點、基線）；kern 用 canvas letterSpacing */
function drawText(cx, s, x, yTop, asc, kern) {
  cx.letterSpacing = `${kern}px`;
  cx.textBaseline = "alphabetic";
  cx.fillText(s, x, yTop + asc);
  cx.letterSpacing = "0px";
}
/** 文字貼圖：mip linear、縮小 linear（SceneKit diffuse.mipFilter／minificationFilter = .linear） */
function canvasTex(cv) {
  const t = new THREE.CanvasTexture(cv);
  t.colorSpace = THREE.SRGBColorSpace;
  t.minFilter = THREE.LinearMipmapLinearFilter; t.magFilter = THREE.LinearFilter; t.generateMipmaps = true;
  return t;
}
const v3add = (a, b) => [a[0] + b[0], a[1] + b[1], a[2] + b[2]];
const v3sub = (a, b) => [a[0] - b[0], a[1] - b[1], a[2] - b[2]];
const v3mul = (a, k) => [a[0] * k, a[1] * k, a[2] * k];

// MARK: - 文字牌（門牌：霧白底、深字、左側識別色條；PingFang TC Medium、字距 +4%）

export const TowerSign = {
  /** 夜晚門牌不要比牆亮（不受光，乘一個暖灰）：記下所有門牌材質，切日夜時一起改（Swift 是 weak 參照；JS 用 WeakRef） */
  plates: [],
  setNight(n) { this.setDark(n ? 1 : 0); },
  /** 10-21 日出日落：乘色依暗度從白混到暖灰 */
  setDark(d) {
    this.plates = this.plates.filter(w => w.deref());
    const c = this.multiply(d);
    for (const p of this.plates) { const m = p.deref(); if (m) { c.toThree(m.color); m.needsUpdate = true; } }
  },
  multiply(d) { return VoxMat.mix(new SColor(1, 1, 1, 1), VoxMat.color(0xC9C4BA), d); },

  /** 回傳 { canvas, width, height }：width／height 是 NSImage.size（點）；canvas 已經照 scale 畫成像素（＝OfficeBuilder.raster(img, scale)） */
  image(s, accent, { size = 44, dark = false, scale = 2 } = {}) {
    const font = `500 ${size}px "PingFang TC", "Microsoft JhengHei", sans-serif`;
    const probe = document.createElement("canvas").getContext("2d");
    probe.font = font;
    const kern = size * 0.04;
    const ts = textSize(probe, s, kern);
    const padX = size * 0.6, padY = size * 0.3, sw = accent == null ? 0 : size * 0.28;
    const W = Math.ceil(ts.width + padX * 2 + sw), H = Math.ceil(ts.height + padY * 2);
    const cv = document.createElement("canvas"); cv.width = Math.trunc(W * scale); cv.height = Math.trunc(H * scale);
    const cx = cv.getContext("2d");
    cx.scale(scale, scale);
    cx.fillStyle = (dark ? VoxMat.color(0x3A3E44) : VoxMat.color(TP.FN5)).css; cx.fillRect(0, 0, W, H);
    if (accent != null) { cx.fillStyle = accent.css; cx.fillRect(0, 0, sw, H); }
    cx.font = font; cx.fillStyle = (dark ? VoxMat.color(0xEDEBE6) : VoxMat.color(TP.INK)).css;
    // AppKit：在 (sw + padX, padY) 畫（原點左下、字框底）⇒ 字框頂 ＝ H − padY − 行高
    drawText(cx, s, sw + padX, H - padY - ts.height, ts.asc, kern);
    return { canvas: cv, width: W, height: H };
  },

  material(cv) {
    const m = new THREE.MeshBasicMaterial({ map: cv ? canvasTex(cv) : null });
    m.userData.lm = "constant";
    if (VoxMat.dark > 0) this.multiply(VoxMat.dark).toThree(m.color);
    this.plates.push(new WeakRef(m));
    return m;
  },

  /** 一塊門牌：高 height 公尺、寬照字數；原點在左緣中心（貼牆時往右長）。回傳 [node, w] */
  plate(s, accent, height, maxWidth = 99) {
    const img = this.image(s, accent);
    let h = height, w = height * img.width / img.height;
    if (w > maxWidth) { h *= maxWidth / w; w = maxWidth; }
    const inner = new THREE.Mesh(new THREE.PlaneGeometry(w, h), this.material(img.canvas));
    inner.position.x = w / 2;
    const n = scnNode("plate"); n.add(inner);
    return [n, w];
  },
};

// MARK: - 樓層模組

/** 會被 cutaway 淡掉的一面（外法線 n 在 XZ 平面，[x, z]）。glass＝透明的面（玻璃牆、玻璃門、玻璃欄杆、電梯井玻璃）：
 *  不擋視線 ⇒ 鏡頭怎麼轉都不藏（10-25 Kang）。cut＝內積超過這個才藏（牆 0.25＝斜 45° 兩面都藏；溜滑梯 0.5＝從右後方看才藏） */
export function facade(node, n, glass = false, cut = 0.25) { return { node, n, glass, cut }; }
export const Facade = facade;

/** 模組建好的結果（Swift 的 ModuleParts）：根節點（放在樓層 y）、四面牆、門牌（可換牆）、門牌寬 */
export function moduleParts() {
  return {
    node: scnNode(), facades: [], plate: null, plateW: 0, plateY: 0,
    plateWalls: new Set([0, 1, 2, 3]),       // 門牌可以搬去的牆（0 後、1 前、2 左、3 右）
    outsidePlate: false,                     // 閒置薄層：門牌貼在外面（朝鏡頭那一面）
    boxes: 0,
    items: 0,                                // 家具件數（不含桌椅、桌面小物）
    front: 0,                                // 其中放在前帶的
    deskItems: 0,                            // 桌面小物
    ghostSpots: [],                          // 影分身站位（PropPlacer 找的空地，模組本地座標 [x, z]）
  };
}
export const ModuleParts = moduleParts;

/** desks 的元素：[x, z, a]（Swift 的 (Float, Float, Float)） */
const deskTuple = d => [d.x, d.z, d.a];

export const TowerModules = {
  /** 四面牆（外法線 [x, z]）：後（−z）、前（+z）、左（−x）、右（+x） */
  normals: [[0, -1], [0, 1], [-1, 0], [1, 0]],

  /** 一面牆＝一個節點（一種材質）：沿著牆排方塊，gaps＝門洞（[沿牆方向的起, 訖, 高]）。
   *  extra＝跟著這面牆一起藏的東西（門框；10-20 第 4 棒：原本在靜態 mesh，牆藏起來後門框浮在半空） */
  wall(side, { h, mat, y0 = TD.room, gaps = [], name, extra = () => {} }) {
    const m = new VoxelMesh();
    extra(new Kit(m));
    const t = 0.15;
    const len = side < 2 ? TD.W : TD.D;
    let cuts = side < 2 ? [[-len / 2, len / 2]] : [[TD.zB, TD.zF]];   // 側牆沿 z：模組前緣固定、往後加深（10-22）
    for (const g of gaps) {
      cuts = cuts.flatMap(c => {
        if (g[1] <= c[0] || g[0] >= c[1]) return [c];
        return [[c[0], g[0]], [g[1], c[1]]].filter(q => q[1] - q[0] > 0.01);
      });
    }
    const put = (a, b, y, hh) => {
      const c = (a + b) / 2, l = b - a;
      switch (side) {
        case 0: m.box(Xf.identity, [c, y + hh / 2, TD.zB + t / 2], [l, hh, t], mat); break;
        case 1: m.box(Xf.identity, [c, y + hh / 2, TD.zF - t / 2], [l, hh, t], mat); break;
        case 2: m.box(Xf.identity, [-TD.W / 2 + t / 2, y + hh / 2, c], [t, hh, l], mat); break;
        default: m.box(Xf.identity, [TD.W / 2 - t / 2, y + hh / 2, c], [t, hh, l], mat);
      }
    };
    for (const c of cuts) put(c[0], c[1], y0, h);
    for (const g of gaps) if (g[2] < h) put(g[0], g[1], y0 + g[2], h - g[2]);      // 門楣
    return m.node(name);
  },

  /** 正面＝玻璃＋直框（每 2 公尺一支）＝一個 cutaway 節點。door＝[x0, x1, h]（門洞那段不放固定玻璃，只留門上的氣窗；滑門另外掛 frontDoor） */
  glassFront({ h, y0 = TD.room, alpha = 0.15, mullionsAt = [0, 1, 2, 3, 4, 5, 6].map(i => -6 + i * 2), door = null, extra = () => {} }) {
    const m = new VoxelMesh(), k = new Kit(m);
    if (door) {
      const [x0, x1, dh] = door, L = TD.W / 2;
      m.box(Xf.identity, [(-L + x0) / 2, y0 + h / 2, TD.zF - 0.02], [x0 + L, h, 0.02], TM.glass(alpha));
      m.box(Xf.identity, [(x1 + L) / 2, y0 + h / 2, TD.zF - 0.02], [L - x1, h, 0.02], TM.glass(alpha));
      m.box(Xf.identity, [(x0 + x1) / 2, y0 + dh + (h - dh) / 2, TD.zF - 0.02], [x1 - x0, h - dh, 0.02], TM.glass(alpha));
    } else {
      m.box(Xf.identity, [0, y0 + h / 2, TD.zF - 0.02], [TD.W, h, 0.02], TM.glass(alpha));
    }
    for (const x of mullionsAt) k.b(Xf.identity, x, y0, TD.zF - 0.03, 0.05, h, 0.05, TM.f(TP.ST1));
    extra(k);
    return m.node("front");
  },

  /** 樓板＋地坪＋前緣霓虹＋後側轉角細框 */
  shell(k, { floorColor, h, neon = true }) {
    const I = Xf.identity;
    k.b(I, 0, 0, TD.zC, TD.W, TD.slab, TD.D, TM.slab);
    k.b(I, 0, TD.slab, TD.zC, TD.W - 0.02, 0.01, TD.D - 0.02, TM.f(floorColor));
    if (neon) k.b(I, 0, TD.slab - 0.02, TD.zF + 0.011, TD.W, 0.02, 0.02, TM.glow(TP.NE1, 0, 0.9));
    const st = TM.f(TP.ST1);
    for (const x of [-TD.W / 2, TD.W / 2]) k.b(I, x, TD.room, TD.zB + 0.03, 0.05, h, 0.05, st);
  },

  /** 線性吊燈（座位帶正上方，離天花 0.45）；off＝這層沒人（2 小時緩衝），燈不亮 */
  pendant(k, { x, z, len, ceil, off }) {
    const I = Xf.identity, drop = 0.45;
    for (const dx of [-len / 2 + 0.3, len / 2 - 0.3]) k.b(I, x + dx, ceil - drop + 0.06, z, 0.02, drop - 0.06, 0.02, TM.f(TP.FN3));
    k.b(I, x, ceil - drop, z, len, 0.06, 0.12, TM.f(TP.FN3));
    k.b(I, x, ceil - drop - 0.02, z, len - 0.1, 0.02, 0.08, off ? TM.f(TP.FN5) : TM.glow(TP.LT1, 0, 1.4));
  },

  /** 一張標準座位：桌面 1.4×0.7 頂高 0.75、螢幕朝人、椅子在桌子後方 chairBack（角色放大 1.6 倍，椅面 0.56）。
   *  本地座標原點在桌心、螢幕在 +z；a＝人面向角（10-22 自由座，見 TowerLayout.freeDesks），整組照 a 旋轉 */
  desk(k, { x, z, a = 0 }) {
    const t = new Xf(x, TD.room, z, a);
    k.b(t, 0, 0.70, 0, 1.4, 0.05, 0.7, TM.f(TP.FN2));
    for (const [dx, dz] of [[-0.64, -0.3], [0.64, -0.3], [-0.64, 0.3], [0.64, 0.3]]) k.b(t, dx, 0, dz, 0.05, 0.7, 0.05, TM.f(TP.FN3));
    k.b(t, 0, 0.76, 0.2, 0.62, 0.20, 0.04, TM.f(TP.FN6));
    k.b(t, 0, 0.75, 0.24, 0.12, 0.05, 0.12, TM.f(TP.FN6));
    const cz = -TowerLayout.chairBack, seat = TowerSpec.seatTop;
    k.b(t, 0, seat - 0.08, cz, 0.55, 0.08, 0.55, TM.f(TP.FN4));
    k.b(t, 0, 0, cz, 0.06, seat - 0.08, 0.06, TM.f(TP.FN3));
    k.b(t, 0, seat, cz - 0.3, 0.55, 0.55, 0.06, TM.f(TP.FN4));
  },

  /** 桌面小物（§3.2）：依「專案名＋桌號」挑 2 件，放桌面左右（馬克杯、文件堆、小盆栽、檯燈、耳機、第二螢幕）；跟桌子一起照 a 旋轉 */
  deskItems(k, { x, z, a = 0, seed }) {
    let h = 1469598103934665603n;
    for (const b of new TextEncoder().encode(seed)) h = BigInt.asUintN(64, (h ^ BigInt(b)) * 1099511628211n);
    const t = new Xf(x, TD.room + 0.75, z, a), y = 0;   // 桌面本地座標（原點桌心、y 0＝桌面）
    const n = 2;                                         // 10-20 第 4 棒：每張桌子都 2 件（評審：桌上沒有生活物件）
    for (let i = 0; i < n; i++) {
      const kind = Number((h >> BigInt(8 + i * 5)) % 6n);
      const sx = i === 0 ? -0.48 : 0.48, cz = -0.08;
      switch (kind) {
        case 0: k.b(t, sx, y, cz, 0.09, 0.11, 0.09, TM.f(TP.FN5)); break;                          // 馬克杯
        case 1: k.b(t, sx, y, cz, 0.3, 0.06, 0.22, TM.f(TP.FN5)); k.b(t, sx + 0.02, y + 0.06, cz, 0.28, 0.02, 0.2, TM.f(TP.FN4)); break;   // 文件堆
        case 2: k.b(t, sx, y, cz, 0.14, 0.12, 0.14, TM.f(TP.POT)); k.b(t, sx, y + 0.12, cz, 0.16, 0.14, 0.16, TM.f(TP.PL2)); break;  // 小盆栽
        case 3:                                                                                                  // 檯燈
          k.b(t, sx, y, cz, 0.12, 0.03, 0.12, TM.f(TP.FN3)); k.b(t, sx, y + 0.03, cz, 0.03, 0.35, 0.03, TM.f(TP.FN3));
          k.b(t, sx, y + 0.36, cz + 0.04, 0.14, 0.08, 0.14, TM.glow(TP.LT1, 0, 0.8));
          break;
        case 4: k.b(t, sx, y, cz, 0.16, 0.06, 0.1, TM.f(TP.FN3)); break;                         // 耳機
        default:                                                                                                 // 第二螢幕（直立）
          k.b(t, sx, y, 0.18, 0.1, 0.12, 0.1, TM.f(TP.FN3)); k.b(t, sx, y + 0.1, 0.2, 0.22, 0.36, 0.03, TM.f(TP.FN6));
      }
    }
    return n;
  },

  /** 每張桌子的桌心＋人面向角 a（12 張以內）：[[x, z, a]] */
  deskCenters(seats, floor) {
    const n = Math.min(seats, 12), out = [];
    for (let i = 0; i < n; i++) out.push(deskTuple(towerDesk(i, n, floor)));
    return out;
  },

  // MARK: 專案樓層（12×5.6×2.9；10-20 UI/UX 優化 §3）

  /** f＝TowerFloor（mac-input.json 的格式）；decor＝FloorDecor（{theme, accentColor, props}）或 null */
  project(f, decor, log = () => {}) {
    const p = moduleParts();
    const m = new VoxelMesh(), k = new Kit(m), I = Xf.identity;
    const h = TD.clear;
    this.shell(k, { floorColor: TP.FL1, h });
    // 四面牆：左牆開兩部電梯門（z −1.75…−0.85、−3.35…−2.45）、後牆右端開往溜滑梯的門（x 5.35…5.95）
    const theme = TowerTheme.of(decor?.theme) ?? "general";
    // 識別色一律鎖主題預設色（10-20 §4.3）
    const accentHex = TP.hex(TowerTheme.accent[theme]) ?? TP.FN4;
    const accent = TM.f(accentHex);
    const N = this.normals;
    p.facades = [
      // 10-20 第 4 棒：後牆協作區那一段（3 公尺）刷主題識別色：遮掉門牌也認得出是哪個主題（跟著後牆一起藏）
      facade(this.wall(0, { h, mat: TM.backWall, gaps: [[5.35, 5.95, 2.1]], name: "back", extra: wk => {
        wk.b(I, -3.8, TD.room, TD.backZ + 0.012, 3.0, h, 0.02, accent);
        // 往溜滑梯的門：識別色門框（評審：電梯門、溜滑梯入口在截圖裡看不出來；用同一個材質，不加 draw call）
        for (const x of [5.3, 6.0]) wk.b(I, x, TD.room, TD.backZ + 0.02, 0.1, 2.2, 0.04, accent);
        wk.b(I, 5.65, TD.room + 2.1, TD.backZ + 0.02, 0.8, 0.1, 0.04, accent);
      } }), N[0], false),
      facade(this.glassFront({ h }), N[1], true),
      facade(this.wall(2, { h, mat: TM.f(TP.WL2), gaps: TD.elevs.map((_, c) => TD.elevGap(c, 2.1)), name: "left", extra: wk => {
        // 電梯門：石墨鋼門框＋門楣（兩部同一個材質，每層仍只多 1 個 draw call）
        for (const e of TD.elevs) {
          for (const z of [e.y - 0.5, e.y + 0.5]) wk.b(I, -TD.W / 2 + 0.17, TD.room, z, 0.06, 2.2, 0.1, TM.f(TP.ST1));
          wk.b(I, -TD.W / 2 + 0.17, TD.room + 2.1, e.y, 0.06, 0.12, 1.1, TM.f(TP.ST1));
        }
      } }), N[2], false),
      facade(this.wall(3, { h, mat: TM.f(TP.WL2), name: "right" }), N[3], false),
    ];
    const ag = (d, n) => TM.glow(accentHex, d, n);
    // 吊燈：前組四人桌上方一條；後組有人坐（2 人以上，第 2 個人就坐後段）再加一條
    this.pendant(k, { x: 0.1, z: 0.05, len: 3.2, ceil: TD.room + h, off: !f.active });
    if (f.seats > 0) this.pendant(k, { x: -0.7, z: -3.95, len: 3.2, ceil: TD.room + h, off: !f.active });
    // 桌子＝實際 AI 數（13 個以上的站前帶，不加桌子）
    const desks = this.deskCenters(f.seats, f.id);
    desks.forEach(([x, z, a], i) => {
      this.desk(k, { x, z, a });
      p.deskItems += this.deskItems(k, { x, z, a, seed: `${f.project ?? ""}#${i}` });
    });
    // 10-20 第 4 棒：人少的樓層補空桌（椅子靠進去、螢幕關著）：像一間辦公室，不是房間正中間一張桌子。
    // 10-22 自由座：只補 1 張空桌（Kang：補滿四張看起來滿滿的）
    const spare = (f.seats < 4 ? [f.seats] : []).map(i => deskTuple(towerDesk(i, 4, f.id)));
    spare.forEach(([x, z, a], j) => {
      this.desk(k, { x, z, a });
      p.deskItems += this.deskItems(k, { x, z, a, seed: `${f.project ?? ""}#spare${j}` });
    });
    // 10-20 UI/UX 優化：樓層名改在左側索引列＋拉近時的螢幕標籤（3D 門牌在預設鏡頭只有 6 pt，讀不到），專案樓層不再畫 3D 門牌
    const r = PropPlacer.place({ theme, props: decor?.props ?? [], desks: desks.concat(spare), mirror: (f.number ?? 0) % 2 === 1, lounge: f.number ?? 0, log });
    for (const [id, xf] of r.items) {
      const d = TowerProps.all[id];
      if (!d) continue;
      const xf2 = new Xf(xf.x, xf.y + TD.room, xf.z, xf.a);
      d.build(k, xf2, accent, ag);
    }
    p.items = r.items.length; p.front = r.front; p.ghostSpots = r.ghostSpots;
    p.boxes = m.boxes;
    p.node.add(m.node("static"));
    for (const fa of p.facades) p.node.add(fa.node);
    return p;
  },

  // MARK: 閒置薄層（只 1 層、高 0.9）：空的薄層（名字在左側索引列）

  idle(f) {
    const p = moduleParts();
    const m = new VoxelMesh(), k = new Kit(m), I = Xf.identity;
    const h = TowerSpec.idleHeight - TD.slab;
    k.b(I, 0, 0, TD.zC, TD.W, TD.slab, TD.D, TM.slab);
    k.b(I, 0, TD.slab, TD.zC, TD.W - 0.02, 0.01, TD.D - 0.02, TM.f(TP.FL2));
    for (const x of [-TD.W / 2 + 0.075, TD.W / 2 - 0.075]) k.b(I, x, TD.room, TD.zC, 0.15, h, TD.D, TM.f(TP.WL2));
    p.facades = [facade(this.wall(0, { h, mat: TM.f(TP.WL2), name: "back" }), this.normals[0], false)];
    // 10-20 第 4 棒：3D 大門牌拿掉（預設鏡頭下斜貼、7–8 pt 糊掉）⇒ 改成螢幕空間樓層名「閒置 N 個專案・名字在左側清單」（OfficeLabels）
    p.boxes = m.boxes;
    p.node.add(m.node("static"));
    p.node.add(this.storefront(0, TowerSpec.idleHeight));
    for (const fa of p.facades) p.node.add(fa.node);
    return p;
  },

  // MARK: 一樓大廳＋前台保全（12×5.6×3.6）

  lobby(sign = false) {
    const p = moduleParts();
    const m = new VoxelMesh(), k = new Kit(m), I = Xf.identity;
    const h = TowerSpec.lobbyHeight - TD.slab, r = TD.room;
    this.shell(k, { floorColor: TP.FL2, h, neon: true });
    // 正面（10-25 Kang）：大門搬到 Okle42 招牌正下方（x 0），原本右邊 x 3.8 的門拿掉；
    // 兩側改成整片純透明大玻璃（中間的直框全拿掉，只留兩端轉角），只有門框＋門楣
    const dx = SlideDoor.front.w + 0.04, x0 = TowerCore.frontX;
    const front = this.glassFront({ h, alpha: 0.1, mullionsAt: [-TD.W / 2, TD.W / 2], door: [x0 - dx, x0 + dx, 2.4], extra: fk => {
      for (const s of [-1, 1]) fk.b(I, x0 + s * dx, r, TD.zF - 0.05, 0.08, 2.4, 0.08, TM.f(TP.ST1));
      fk.b(I, x0, r + 2.4, TD.zF - 0.05, 2 * dx + 0.08, 0.08, 0.08, TM.f(TP.ST1));
    } });
    const N = this.normals;
    p.facades = [
      facade(this.wall(0, { h, mat: TM.backWall, name: "back", extra: wk => this.cafeBricks(wk, h) }), N[0], false),
      facade(front, N[1], true),
      facade(this.wall(2, { h, mat: TM.f(TP.WL2), gaps: TD.elevs.map(e => [e.y - 0.5, e.y + 0.5, 2.3]), name: "left", extra: wk => {
        for (const e of TD.elevs) {   // 兩部電梯門（10-22）：第 0 部 z −1.8…−0.8、第 1 部 z −3.4…−2.4。10-25：實心門板拿掉，改玻璃滑門（landingDoor）＋門框
          for (const z of [e.y - 0.5, e.y + 0.5]) wk.b(I, -TD.W / 2 + 0.17, r, z, 0.06, 2.3, 0.1, TM.f(TP.ST1));
          wk.b(I, -TD.W / 2 + 0.17, r + 2.1, e.y, 0.06, 0.2, 1.1, TM.f(TP.ST1));
        }
      } }), N[2], false),
      facade(this.wall(3, { h, mat: TM.f(TP.WL2), name: "right" }), N[3], false),
    ];
    // 主牆：胡桃木細格柵（10-22 大樓加深後變成前台跟後段咖啡館的隔屏，兩側留走道）
    const divZ = TowerLobby.divZ;
    // 只擋在前台正後方（x −1.4…2.0）：兩側看得進咖啡館
    k.b(I, 0.3, r, divZ, 3.5, 0.45, 0.12, TM.f(TP.FN1));
    for (let i = 0; i < 13; i++) k.b(I, -1.4 + i * 0.28, r + 0.45, divZ, 0.06, 2.35, 0.08, TM.f(TP.FN1));
    // 前台：胡桃木量體＋霧白檯面
    k.b(I, 0.3, r, 0.1, 2.6, 1.05, 0.75, TM.f(TP.FN1)); k.b(I, 0.3, r + 1.05, 0.1, 2.7, 0.04, 0.85, TM.f(TP.FN5));
    for (let i = 0; i < 3; i++) k.b(I, -0.45 + i * 0.75, r + 1.6, divZ + 0.14, 0.7, 0.44, 0.05, TM.f(TP.FN6));
    k.b(I, 1.4, r + 1.09, 0.3, 0.06, 0.6, 0.06, TM.f(0x9CA3AF));          // Wi-Fi 天線桿（10-21 稽核：原本 x 1.75 在檯面外、懸空，還插進保全的帽簷）
    // 等候長凳、植栽、雜誌架
    k.b(I, -3.9, r, 1.5, 2.0, 0.45, 0.5, TM.f(TP.FN2));
    const n4 = () => TM.f(TP.FN4);
    TowerProps.all["plant_tall"].build(k, new Xf(5.3, r, -2.1), TM.f(TP.FN4), n4);
    TowerProps.all["plant_low"].build(k, new Xf(-2.1, r, -2.3), TM.f(TP.FN4), n4);   // 左邊改矮盆栽：讓出電梯→咖啡館的走道、不擋沙發區
    TowerProps.all["plant_low"].build(k, new Xf(2.5, r, 2.2), TM.f(TP.FN4), n4);
    TowerProps.all["side_table"].build(k, new Xf(-5.3, r, 1.5), TM.f(TP.FN4), n4);
    this.pendant(k, { x: 0.3, z: 0.1, len: 3.4, ceil: r + h, off: false });
    k.b(I, TD.slideX, 0, TD.slideZ, 1.2, 0.1, 1.2, TM.slab);             // 溜滑梯出口落地平台
    this.cafe(k, h);
    // 10-20 第 4 棒：3D 門牌（「AI 工作戰情中心」「01 大廳・前台保全」）拿掉：遠看是讀不到的另一套字；樓層名改由螢幕空間標籤畫
    p.boxes = m.boxes;
    p.node.add(m.node("static"));
    p.node.add(TowerLobby.neon("Coffeeshop", [-3.6, r + 2.75, TD.backZ + 0.06], 2.6, 0.7));
    if (sign) p.node.add(this.storefront(TowerSpec.lobbyHeight - 0.55, 0.8));
    for (const fa of p.facades) p.node.add(fa.node);
    return p;
  },

  /** 一樓後段咖啡館的紅磚牆（貼在後牆內側，跟後牆一起 cutaway） */
  cafeBricks(k, h) {
    const I = Xf.identity;
    const z = TD.backZ + 0.015, x0 = -5.85, x1 = 5.2, top = Math.min(h, 3.5);
    k.b(I, (x0 + x1) / 2, TD.room, z - 0.005, x1 - x0, top, 0.01, TM.f(0xCDBFAE));      // 灰縫
    // 迴圈條件是 Float 累加後的比較（跟 Swift 同一個結果，逐步捨入成 float32）
    const F = Math.fround;
    const bw = F(0.42), bh = F(0.17);
    let row = 0;
    let y = F(F(TD.room) + F(0.02));
    while (F(y + bh) <= F(F(TD.room) + F(top))) {
      let x = F(F(x0) + (row % 2 === 0 ? F(0.02) : F(F(-bw / 2) + F(0.02))));
      let i = 0;
      while (x < F(F(x1) - F(0.05))) {
        const a = Math.max(x, F(F(x0) + F(0.02))), b = Math.min(F(F(x + bw) - F(0.03)), F(F(x1) - F(0.02)));
        if (F(b - a) > F(0.05)) {
          const c = [0x9A4631, 0xA9553B, 0x8C3F2C, 0xB0624A][(row * 7 + i * 3) % 4];
          k.b(I, (a + b) / 2, y, z + 0.012, b - a, bh - 0.03, 0.02, TM.f(c));
        }
        x = F(x + bw); i += 1;
      }
      y = F(y + bh); row += 1;
    }
  },

  /** 一樓後段：荷蘭 coffeeshop 風休息區（10-22 Kang：員工有地方 chill；下雨天休息的人都來這）
   *  左：橘色地毯＋沙發＋懶骨頭；中：立食桌；右：吧台（台夫特藍磁磚、咖啡機、吊燈）＋荷蘭腳踏車；隔屏後一排鬱金香 */
  cafe(k, h) {
    const I = Xf.identity;
    const r = TD.room, bz = TD.backZ, ceil = r + h;
    const none = () => TM.f(TP.FN4);
    // 地坪：咖啡館區換成深色木地板
    k.b(I, 0, TD.slab + 0.005, (bz + TowerLobby.divZ) / 2 - 0.1, TD.W - 0.32, 0.01, TowerLobby.divZ - bz - 0.25, TM.f(0x7A5A40));
    // 沙發區
    k.b(I, -3.6, r + 0.01, bz + 1.2, 3.4, 0.01, 1.7, TM.f(0xE07B39));                      // 荷蘭橘地毯
    k.b(I, -3.6, r, bz + 0.45, 2.2, 0.42, 0.8, TM.f(0x3E5A4C)); k.b(I, -3.6, r + 0.42, bz + 0.14, 2.2, 0.42, 0.18, TM.f(0x3E5A4C));   // 墨綠絨布沙發
    for (const dx of [-1.05, 1.05]) k.b(I, -3.6 + dx, r, bz + 0.45, 0.14, 0.62, 0.8, TM.f(0x34503F));
    for (const x of [-5.25, -1.95]) TowerProps.all["side_table"].build(k, new Xf(x, r, bz + 0.4), TM.f(TP.FN4), none);
    k.b(I, -5.25, r + 0.52, bz + 0.4, 0.14, 0.16, 0.14, TM.glow(TP.LT1, 0.2, 1.2));     // 小檯燈
    k.b(I, -1.95, r + 0.52, bz + 0.4, 0.1, 0.1, 0.1, TM.f(TP.FN5));                       // 咖啡杯
    TowerProps.all["beanbag"].build(k, new Xf(-1.2, r, bz + 0.55), TM.f(0xE0B04A), none);
    TowerProps.all["floor_lamp"].build(k, new Xf(-5.5, r, bz + 2.15), TM.f(TP.FN4), () => TM.glow(TP.LT1, 0.2, 1.4));
    // 立食桌
    const tz = bz + 1.15;
    k.b(I, 0, r, tz, 0.08, 1.0, 0.08, TM.f(TP.FN3)); k.b(I, 0, r, tz, 0.5, 0.04, 0.5, TM.f(TP.FN3));
    k.b(I, 0, r + 1.0, tz, 0.75, 0.05, 0.75, TM.f(TP.FN1));
    k.b(I, -0.15, r + 1.05, tz + 0.05, 0.09, 0.1, 0.09, TM.f(TP.FN5)); k.b(I, 0.18, r + 1.05, tz - 0.05, 0.09, 0.1, 0.09, TM.f(TP.FN5));
    // 吧台：胡桃木＋台夫特藍白磁磚腰帶
    const bx = 2.9, bw = 3.2, bzc = bz + 0.5;
    k.b(I, bx, r, bzc, bw, 1.02, 0.6, TM.f(TP.FN1)); k.b(I, bx, r + 1.02, bzc, bw + 0.1, 0.04, 0.7, TM.f(0x2B2C2F));
    for (let i = 0; i < 16; i++) for (let j = 0; j < 2; j++) {
      k.b(I, bx - bw / 2 + 0.1 + i * 0.2, r + 0.3 + j * 0.2, bzc + 0.305, 0.18, 0.18, 0.01, TM.f((i + j) % 2 === 0 ? 0x2F5FA8 : 0xF3F1EC));
    }
    k.b(I, 2.1, r + 1.06, bzc - 0.05, 0.55, 0.42, 0.4, TM.f(0xB8BCC2)); k.b(I, 2.1, r + 1.38, bzc + 0.16, 0.5, 0.06, 0.04, TM.f(0xC0392B));   // 咖啡機
    k.b(I, 2.75, r + 1.06, bzc - 0.05, 0.2, 0.45, 0.2, TM.f(TP.FN3));                     // 磨豆機
    for (let i = 0; i < 4; i++) k.b(I, 3.3 + i * 0.22, r + 1.06, bzc + 0.1, 0.1, 0.11, 0.1, TM.f(TP.FN5));   // 杯子
    // 吧台後：層板＋豆罐、黑板菜單
    k.b(I, bx, r + 1.45, bz + 0.15, 2.8, 0.04, 0.26, TM.f(TP.FN1));
    for (let i = 0; i < 7; i++) k.b(I, bx - 1.2 + i * 0.4, r + 1.49, bz + 0.15, 0.16, 0.24, 0.16, TM.f([0x6B4A33, 0xD9D4CB, 0x3E2A1E][i % 3]));
    k.b(I, bx, r + 1.85, bz + 0.04, 1.7, 0.7, 0.03, TM.f(0x24302A));
    for (let i = 0; i < 4; i++) k.b(I, bx - 0.25, r + 2.32 - i * 0.14, bz + 0.06, 0.9 - (i % 2) * 0.3, 0.03, 0.01, TM.f(0xE8E4DA));
    // 吧台吊燈
    for (const x of [2.0, 2.9, 3.8]) {
      k.b(I, x, ceil - 0.75, bzc + 0.1, 0.02, 0.75, 0.02, TM.f(TP.FN3));
      k.b(I, x, ceil - 0.95, bzc + 0.1, 0.3, 0.2, 0.3, TM.f(TP.FN3));
      k.b(I, x, ceil - 0.99, bzc + 0.1, 0.22, 0.05, 0.22, TM.glow(TP.LT1, 0.3, 1.6));
    }
    // 荷蘭腳踏車（墨綠車架、黑輪、前籃），靠右牆
    const wx = 5.55;
    for (const wz of [bz + 1.5, bz + 2.5]) {
      for (const [dy, dz, hh, dd] of [[0.0, 0.0, 0.05, 0.5], [0.6, 0.0, 0.05, 0.5], [0.05, -0.27, 0.55, 0.05], [0.05, 0.27, 0.55, 0.05]]) {
        k.b(I, wx, r + dy, wz + dz, 0.04, hh, dd, TM.f(0x1E2024));
      }
    }
    k.b(I, wx, r + 0.33, bz + 2.0, 0.05, 0.05, 1.0, TM.f(0x2E5A44));
    k.b(I, wx, r + 0.33, bz + 1.7, 0.05, 0.55, 0.05, TM.f(0x2E5A44)); k.b(I, wx, r + 0.85, bz + 1.7, 0.2, 0.06, 0.25, TM.f(0x3A2A1E));   // 座管＋座墊
    k.b(I, wx, r + 0.33, bz + 2.4, 0.05, 0.7, 0.05, TM.f(0x2E5A44)); k.b(I, wx, r + 1.02, bz + 2.4, 0.5, 0.04, 0.05, TM.f(0x1E2024));    // 龍頭
    k.b(I, wx, r + 0.72, bz + 2.65, 0.3, 0.22, 0.25, TM.f(0xB08A5A));                         // 前籃
    TowerProps.all["plant_tall"].build(k, new Xf(5.35, r, bz + 0.5), TM.f(TP.FN4), none);
    // 隔屏後一排鬱金香（紅、黃、粉、橘）
    k.b(I, 0.3, r, TowerLobby.divZ - 0.28, 3.4, 0.35, 0.3, TM.f(0x5A4A3A));
    for (let i = 0; i < 14; i++) {
      const x = -1.3 + i * 0.245;
      k.b(I, x, r + 0.35, TowerLobby.divZ - 0.28, 0.025, 0.25, 0.025, TM.f(TP.PL1));
      k.b(I, x, r + 0.58, TowerLobby.divZ - 0.28, 0.09, 0.11, 0.09, TM.f([0xD7263D, 0xF2C14E, 0xF08BB0, 0xF47C2C][i % 4]));
    }
    // 沙發區暖光吊燈
    k.b(I, -3.6, ceil - 0.6, bz + 1.05, 0.02, 0.6, 0.02, TM.f(TP.FN3));
    k.b(I, -3.6, ceil - 0.85, bz + 1.05, 0.5, 0.25, 0.5, TM.f(0xE0B04A)); k.b(I, -3.6, ceil - 0.88, bz + 1.05, 0.4, 0.04, 0.4, TM.glow(TP.LT1, 0.3, 1.6));
  },

  /** 公司招牌（10-22 Kang：一、二樓中間那條改成 Okle42 招牌）：閒置薄層（0.9 高）正面整條黑色招牌，白字置中；
   *  沒有閒置專案（沒有薄層）時改掛在大廳正面頂端。夜晚字會亮、停電跟著熄（走 VoxMat 的發光清單） */
  brand: "Okle42",
  /** 招牌材質（同尺寸只做一次：模組重建時不重複登記發光清單） */
  signMats: new Map(),
  signMaterial(w, h) {
    const key = `${w}x${h}`;
    const hit = this.signMats.get(key);
    if (hit) return hit;
    const px = 160;                      // 每公尺幾點
    const W = w * px, H = h * px;
    const cv = document.createElement("canvas"); cv.width = Math.trunc(W); cv.height = Math.trunc(H);   // raster(img, scale: 1)
    const cx = cv.getContext("2d");
    cx.fillStyle = VoxMat.color(0x16181C).css; cx.fillRect(0, 0, W, H);
    cx.fillStyle = VoxMat.color(0x2A2E35).css; cx.fillRect(0, 0, W, 6);       // 上緣一道亮邊（AppKit y＝H−6 往上 6 點＝canvas 最上面 6 點）
    // 10-22 Kang：字再大、「42」用金色
    const size = H * 0.8, kern = H * 0.05;
    cx.font = `800 ${size}px -apple-system, "SF Pro Display", "Segoe UI", system-ui, sans-serif`;     // NSFont.systemFont(weight: .heavy)
    const ts = textSize(cx, this.brand, kern);
    let x = (W - ts.width) / 2;
    const yTop = (H - ts.height) / 2;
    const g = this.brand.indexOf("42");
    const parts = g < 0 ? [[this.brand, 0xF4F2EE]] : [[this.brand.slice(0, g), 0xF4F2EE], ["42", 0xE0B04A], [this.brand.slice(g + 2), 0xF4F2EE]];
    for (const [s, c] of parts) {
      if (!s) continue;
      cx.fillStyle = VoxMat.color(c).css;
      drawText(cx, s, x, yTop, ts.asc, kern);
      x += textSize(cx, s, kern).width;
    }
    const m = new THREE.MeshLambertMaterial();
    m.userData.lm = "lambert";
    const t = canvasTex(cv);
    m.map = t; m.emissiveMap = t; m.emissive.setRGB(1, 1, 1);
    VoxMat.registerGlow(m, 0.35, 1.0);
    this.signMats.set(key, m);
    return m;
  },

  /** y0＝招牌底邊、h＝高（模組座標） */
  storefront(y0, hh) {
    const h = hh, y = y0 + h / 2;
    const n = scnNode("storefront");
    /** 一面招牌：中心 (x, z)、寬 w、朝向 a（0＝朝 +z）；黑盒厚 6 公分在後、字面在前 */
    const side = (w, x, z, a) => {
      // eulerAngles.y＝CGFloat，SceneKit 內部存 Float ⇒ π 會變成 Float.pi（比 π 大一點，Mac dump 的 yaw 是 −π）：照樣捨入
      const g = scnNode(); g.position.set(x, y, z); g.rotation.y = Math.fround(a);
      const face = new THREE.Mesh(new THREE.PlaneGeometry(w, h), this.signMaterial(w, h)); face.position.z = 0.035;
      const box = scnBox(w, h, 0.06, TM.f(0x16181C));
      g.add(box); g.add(face); n.add(g);
    };
    // 10-22 Kang：除了電梯那一側（左），前、右、後三面都要有招牌
    side(TD.W + 0.1, 0, TD.zF + 0.035, 0);                                  // 正面
    side(TD.D - 0.6, TD.W / 2 + 0.035, TD.zC, Math.PI / 2);                 // 右側：貼牆，夾在前後兩根結構柱中間（10-22 Kang：原本在柱子外面、看起來飄在空中）
    // 背面：整面（10-22 Kang：右端空一塊不行）；溜滑梯往後退到 zB−1.0，螺旋外緣離牆 0.18，不會穿過招牌
    side(TD.W + 0.1, 0, TD.zB - 0.035, Math.PI);
    // 四個角：結構柱轉到靠鏡頭那側會淡掉（cutaway）⇒ 招牌轉角露出一個缺口像破圖（10-22 Kang）。
    // 招牌高度那一段補一塊跟柱子同位置的黑色轉角塊，招牌自己的一部分，不跟著柱子藏
    for (const x of [-TD.W / 2 - 0.15, TD.W / 2 + 0.15]) {
      for (const z of [TD.zB + 0.15, TD.zF - 0.15]) {
        const c = scnBox(0.34, h, 0.34, TM.f(0x16181C));
        c.position.set(x, y, z);
        n.add(c);
      }
    }
    return n;
  },

  // MARK: 頂樓空中花園（12×5.6，棚架 2.1）

  roof() {
    const p = moduleParts();
    const m = new VoxelMesh(), k = new Kit(m), I = Xf.identity;
    const r = TD.room;
    this.shell(k, { floorColor: TP.FL1, h: 0, neon: true });
    for (const x of [-4.4, -0.9, 2.6]) {
      const z = TD.zB + 0.55;
      k.b(I, x, r, z, 2.2, 0.5, 0.8, TM.slab);
      k.b(I, x, r + 0.5, z, 2.0, 0.08, 0.6, TM.f(TP.soil));
      k.b(I, x, r + 0.55, z, 0.12, 0.9, 0.12, TM.f(TP.FN1));
      k.b(I, x, r + 1.35, z, 1.2, 0.85, 0.9, TM.f(TP.PL1));
      k.b(I, x + 0.2, r + 2.1, z - 0.05, 0.7, 0.5, 0.6, TM.f(TP.PL2));
    }
    // 黑鐵棚架＋暖光串燈
    for (const [x, z] of [[-2.4, -0.5], [1.4, -0.5], [-2.4, 1.9], [1.4, 1.9]]) k.b(I, x, r, z, 0.1, 2.1, 0.1, TM.f(TP.FN3));
    for (let i = 0; i < 6; i++) k.b(I, -2.4 + i * 0.76, r + 2.1, 0.7, 0.06, 0.1, 2.5, TM.f(TP.FN3));
    k.b(I, -0.5, r + 1.98, 0.7, 3.8, 0.02, 0.02, TM.glow(TP.LT1, 0, 1.6));
    // 長椅、咖啡吧
    k.b(I, -3.6, r, 1.9, 2.2, 0.42, 0.7, TM.f(TP.FN2)); k.b(I, -3.6, r + 0.42, 2.18, 2.2, 0.4, 0.15, TM.f(TP.FN2));
    k.b(I, 3.3, r, -0.15, 2.0, 1.0, 0.65, TM.f(TP.FN1)); k.b(I, 3.3, r + 1.0, -0.15, 2.1, 0.04, 0.75, TM.f(TP.FN5));
    k.b(I, 2.8, r + 1.04, -0.25, 0.3, 0.4, 0.3, TM.f(TP.FN3));
    // 溜滑梯入口平台、天線＋NE-2
    k.b(I, 5.6, r, TD.zB + 0.4, 0.7, 0.25, 0.7, TM.slab);
    k.b(I, 4.8, r, TD.zB + 0.4, 0.1, 2.4, 0.1, TM.f(0x9AA3B2)); k.b(I, 4.8, r + 2.4, TD.zB + 0.4, 0.26, 0.26, 0.26, TM.glow(TP.NE2, 0.5, 2.0));
    // 欄杆扶手（石墨鋼；玻璃是 cutaway 的四面）
    k.b(I, 0, r + 1.0, TD.zF - 0.05, TD.W, 0.05, 0.06, TM.f(TP.ST1));
    for (const x of [-TD.W / 2 + 0.05, TD.W / 2 - 0.05]) k.b(I, x, r + 1.0, TD.zC, 0.06, 0.05, TD.D, TM.f(TP.ST1));
    const rail = TM.glass(0.25);
    const railNode = side => {
      const mm = new VoxelMesh();
      switch (side) {
        case 0: mm.box(I, [0, r + 0.5, TD.zB + 0.03], [TD.W, 1.0, 0.03], rail); break;
        case 1: mm.box(I, [0, r + 0.5, TD.zF - 0.05], [TD.W, 1.0, 0.03], rail); break;
        case 2: mm.box(I, [-TD.W / 2 + 0.05, r + 0.5, TD.zC], [0.03, 1.0, TD.D], rail); break;
        default: mm.box(I, [TD.W / 2 - 0.05, r + 0.5, TD.zC], [0.03, 1.0, TD.D], rail);
      }
      return mm.node(`rail${side}`);
    };
    p.facades = [0, 1, 2, 3].map(i => facade(railNode(i), this.normals[i], true));
    p.boxes = m.boxes;
    p.node.add(m.node("static"));
    for (const fa of p.facades) p.node.add(fa.node);
    return p;
  },

  /** 搬家時樓板底下的 NE-1 光框 */
  glowFrame() {
    const m = new VoxelMesh(), mat = TM.glow(TP.NE1, 0.6, 1.6), I = Xf.identity;
    const w = TD.W + 0.2, d = TD.D + 0.2;
    m.box(I, [0, -0.03, TD.zC + d / 2], [w, 0.04, 0.04], mat);
    m.box(I, [0, -0.03, TD.zC - d / 2], [w, 0.04, 0.04], mat);
    m.box(I, [-w / 2, -0.03, TD.zC], [0.04, 0.04, d], mat);
    m.box(I, [w / 2, -0.03, TD.zC], [0.04, 0.04, d], mat);
    return m.node("glowframe");
  },
};

/** 一樓咖啡館的共用尺寸＋霓虹字招牌 */
export const TowerLobby = {
  /** 前台格柵隔屏的位置（原本的後牆，加深前的 backZ） */
  divZ: -2.65,
  neonMats: new Map(),
  /** 霓虹字（綠，夜晚亮、停電熄）：貼牆的透明底平面。p＝[x, y, z] */
  neon(text, p, w = 2.2, h = 0.5) {
    let m = this.neonMats.get(text);
    if (!m) {
      const px = 200;
      const W = w * px, H = h * px;
      const cv = document.createElement("canvas"); cv.width = Math.trunc(W); cv.height = Math.trunc(H);
      const cx = cv.getContext("2d");
      cx.clearRect(0, 0, W, H);
      // SnellRoundhand-Bold（Mac 內建；Windows 沒有 ⇒ 退回系統粗體 0.7，同 Swift 的 fallback）
      const snell = document.fonts?.check?.(`bold ${H * 0.78}px "Snell Roundhand"`) ?? false;
      cx.font = snell ? `bold ${H * 0.78}px "Snell Roundhand"` : `bold ${H * 0.7}px -apple-system, "Segoe UI", system-ui, sans-serif`;
      cx.fillStyle = VoxMat.color(0x6BF08A).css;
      const ts = textSize(cx, text, 0);
      drawText(cx, text, (W - ts.width) / 2, (H - ts.height) / 2, ts.asc, 0);
      // .constant＋diffuse／emission 同一張圖：three 的 Basic 沒有 emissiveMap（設了 render 會壞）⇒ 用 Lambert＋emissiveMap，
      // userData.lm＝"constant"（dump 的 key 跟 Mac 一樣）；夜晚室內光弱，畫面上主要是 emission
      m = new THREE.MeshLambertMaterial({ transparent: true, depthWrite: false });
      m.userData.lm = "constant";
      const t = canvasTex(cv);
      m.map = t; m.emissiveMap = t; m.emissive.setRGB(1, 1, 1);
      VoxMat.registerGlow(m, 0.7, 1.0);
      this.neonMats.set(text, m);
    }
    const n = new THREE.Mesh(new THREE.PlaneGeometry(w, h), m); n.name = "neon";
    n.position.set(p[0], p[1], p[2]);
    return n;
  },
};

/** 滑門的幾何（10-25）：兩片沿 axis 往外滑；第 side（L＝+1、R＝−1）片在開度 k 的位置 */
export class SlideDoor {
  constructor(axis, w, slide) { this.axis = axis; this.w = w; this.slide = slide; }
  pos(side, k) { return v3mul(this.axis, side * (this.w / 2 + this.slide * k)); }
  /** 電梯門：沿 z，各 0.45、滑 0.43（＝TowerCore.doorW／doorSlide） */
  static elevator = new SlideDoor([0, 0, 1], 0.45, 0.43);
  /** 1 樓正門（Kang：對開電動側滑玻璃門）：沿 x，招牌正下方，門洞 −0.9…0.9（兩側門框中心 ±0.9） */
  static front = new SlideDoor([1, 0, 0], 0.86, 0.82);
}
/** 呼叫端可以傳 SlideDoor 或名字（"elevator"／"front"） */
const slideDoorOf = g => (typeof g === "string" ? SlideDoor[g] : g) ?? SlideDoor.elevator;
const LR = [["L", 1], ["R", -1]];

// MARK: - 模組外：結構柱、電梯井、溜滑梯、天際線

export const TowerCore = {
  /** 結構柱＋玻璃電梯井（4 根角柱＋每層一道橫框，玻璃照 cutaway）＋溜滑梯（右後角、後牆後面，整條合併一個 mesh）。
   *  10-20 UI/UX 優化 §3.4：原本 2×2 灰色實心井（畫面左邊一大條）、溜滑梯在右外側半徑 1.1（佔畫面寬 12%）⇒ 視覺重量減半。
   *  回傳 { node（name "core"）, facades } */
  build(top, roofFloor, floorYs = []) {
    const root = scnNode("core");
    const m = new VoxelMesh(), k = new Kit(m), I = Xf.identity;
    const facades = [];
    // 四根結構柱：各自一個 cutaway 節點（10-20 UI/UX 優化：轉到側面時正前方那根柱子剛好切過整棟中間，跟著牆一起藏）
    for (const x of [-TD.W / 2 - 0.15, TD.W / 2 + 0.15]) {
      for (const z of [TD.zB + 0.15, TD.zF - 0.15]) {
        const cm = new VoxelMesh(); new Kit(cm).b(I, x, 0, z, 0.3, top + 0.3, 0.3, TM.f(TP.ST1));
        const node = cm.node("column"); root.add(node);
        const nx = x > 0 ? 1 : -1, nz = z > 0 ? 1 : -1, l = Math.hypot(nx, nz);
        facades.push(facade(node, [nx / l, nz / l], false, 0.8));
      }
    }
    // 電梯井（10-22 Kang 兩部電梯）：沿 z 排一列，每座 x 寬 1.4；相鄰兩座共用中間那道隔板（取兩車廂中心的中點：
    // z −1.3／−2.9 ⇒ 前緣 −0.6、隔板 −2.1、後緣 −3.6），角柱、橫框、玻璃都只畫一次，不重疊、不 z-fighting
    const H = top + 0.9, e = 0.7;
    const y0 = OfficeBasement.baseY;       // 10-22 Kang：電梯井往下通到 B1 機房
    const ex = TD.elevs.map(v => v.x), ez = TD.elevs.map(v => v.y);
    // 每座井沿 z 的範圍 [前緣, 後緣]：外側離車廂中心 0.7，中間取中點
    const spans = ez.map((_, c) => [c === 0 ? ez[c] + e : (ez[c - 1] + ez[c]) / 2, c === ez.length - 1 ? ez[c] - e : (ez[c] + ez[c + 1]) / 2]);
    // 每道橫向邊界（前緣、各隔板、後緣）各一組角柱＋每層橫框；左側每座各自一條縱框
    const bounds = [spans[0][0]].concat(spans.map(s => s[1]));
    const ys = floorYs.concat([y0]);
    bounds.forEach((z, i) => {
      const x = i < ex.length ? ex[i] : ex[ex.length - 1];
      for (const dx of [-e, e]) k.b(I, x + dx, y0, z, 0.08, H - y0, 0.08, TM.f(TP.ST1));
      for (const y of ys) k.b(I, x, y + 0.02, z, 1.4, 0.06, 0.06, TM.f(TP.ST1));
      // 10-22 Kang 科技感：外側角柱貼一條細 LED（白天淡、夜晚亮）
      k.b(I, x - e - 0.045, y0, z, 0.012, H - y0, 0.03, TM.glow(TP.ELEV_LED, 0.5, 2.2));
    });
    ez.forEach((_, c) => {
      const [z0, z1] = spans[c], d = z0 - z1;
      for (const y of ys) {
        k.b(I, ex[c] - e, y + 0.02, (z0 + z1) / 2, 0.06, 0.06, d, TM.f(TP.ST1));
        k.b(I, ex[c] - e - 0.035, y + 0.035, (z0 + z1) / 2, 0.012, 0.025, d - 0.1, TM.glow(TP.ELEV_LED, 0.5, 2.2));   // 每層一道發光橫框
      }
      // 頂蓋：只有最外側兩端各多出 0.05（跟原本 1.5 見方一樣出簷），中間接縫剛好接上、不重疊
      const c0 = z0 + (c === 0 ? 0.05 : 0), c1 = z1 - (c === ez.length - 1 ? 0.05 : 0);
      k.b(I, ex[c], H, (c0 + c1) / 2, 1.5, 0.1, c0 - c1, TM.f(TP.ST1));
    });
    // 樓層看板的立柱（10-21 稽核：看板原本浮在電梯井外的半空中、轉向鏡頭時還插進電梯井）：
    // 看板掛在這根柱子上、只繞柱子轉（柱心＝看板轉軸，看板永遠在柱子靠鏡頭那一側）
    // 只在有看板顯示時才出現（鏡頭遠時看板全藏，剩一根光禿禿的長桿很怪）：獨立節點，updateLOD 跟著看板開關
    const mast = new VoxelMesh(), mk = new Kit(mast);
    mk.b(I, TD.boardX, 0, TD.boardZ, 0.9, 0.12, 0.9, TM.f(TP.ST2));
    mk.b(I, TD.boardX, 0.12, TD.boardZ, 0.16, top + 0.2, 0.16, TM.f(TP.ST1));
    const mn = mast.node("board-mast"); mn.visible = false;
    root.add(mn);
    const pane = (name, c, s, n) => {
      const mm = new VoxelMesh(); mm.box(I, c, s, TM.glass(0.12));
      const node = mm.node(name); root.add(node);
      facades.push(facade(node, n, true));
    };
    // 玻璃（cutaway）：每座 back／left 各一片（名字加編號）；front 只有最前面那座有，後面幾座的前面＝前一座的 back（共用，不重複）
    ez.forEach((_, c) => {
      const [z0, z1] = spans[c], d = z0 - z1;
      const cy = (H + y0) / 2, hh = H - y0;
      if (c === 0) pane(`shaft-front${c}`, [ex[c], cy, z0], [1.4, hh, 0.02], [0, 1]);
      pane(`shaft-back${c}`, [ex[c], cy, z1], [1.4, hh, 0.02], [0, -1]);
      pane(`shaft-left${c}`, [ex[c] - e, cy, (z0 + z1) / 2], [0.02, hh, d], [-1, 0]);
    });
    // 溜滑梯：從頂樓平台往下螺旋到大廳；每 0.5 弧度一段（滑面＋外側擋板，ST-2 跟樓板同色、低對比），中央柱 ST-1
    const slideTop = roofFloor + TD.room + 0.25;
    const steps = Math.max(1, Math.trunc(Math.fround(Math.fround(slideTop - TD.room) / Math.fround(TD.slideDrop))));
    const sm = new VoxelMesh();
    for (let i = 0; i <= steps; i++) {
      const th = TD.slideA0 + i * TD.slideStep;
      const y = slideTop - i * TD.slideDrop;
      const p = TD.slidePoint(th, slideTop, y);
      sm.box(new Xf(p[0], y - 0.03, p[2], -th), [0, 0, 0], [0.45, 0.06, 0.3], TM.slab);
      const o = [TD.slideX + (TD.slideR + 0.22) * Math.cos(th), y + 0.06, TD.slideZ + (TD.slideR + 0.22) * Math.sin(th)];
      sm.box(new Xf(o[0], o[1], o[2], -th + Math.PI / 2), [0, 0, 0], [0.45, 0.16, 0.03], TM.slab);
    }
    new Kit(sm).b(I, TD.slideX, 0, TD.slideZ, 0.1, slideTop + 0.5, 0.1, TM.f(TP.ST1));
    const slide = sm.node("slide"); root.add(slide);
    facades.push(facade(slide, [Math.SQRT1_2, -Math.SQRT1_2], false, 0.5));   // 溜滑梯是實心的，擋到要藏
    // root.insertChildNode(_, at: 0)
    const cs = m.node("core-static");
    root.add(cs); root.children.pop(); root.children.unshift(cs);
    return { node: root, facades };
  },

  // MARK: 電梯玻璃滑門（10-25 Kang：每層都要有門、透明玻璃、左門往左滑右門往右滑、電梯到了才開）

  /** 門洞 0.9 寬：兩片各 0.45；開門時各往外滑 0.43（滑進牆裡） */
  doorW: 0.45, doorH: 2.08, doorSlide: 0.43,
  /** 開／關門動畫秒數、到站後開著等多久才關 */
  doorTime: 0.6, doorDwell: 3,

  /** 第 c 部電梯的一組滑門（掛在樓層模組底下，跟著樓層搬家）。站在大樓裡面向電梯看：左手邊＝+z、右手邊＝−z
   *  子節點 L（往 +z 滑）、R（往 −z 滑）；位置在牆的中線（關著剛好填滿門洞，開了滑進牆裡） */
  landingDoor(c) {
    const n = scnNode(`edoor-${c}`);
    n.position.set(-TD.W / 2 + 0.075, TD.room, TD.elevs[c].y);
    const steel = TM.f(TP.ST1), led = TM.glow(TP.ELEV_LED, 0.4, 1.8), I = Xf.identity;
    const doorW = this.doorW, doorH = this.doorH;
    for (const [name, side] of LR) {
      const panel = scnNode(name);
      panel.position.set(0, 0, side * doorW / 2);
      // 玻璃：不寫深度、排在不透明的後面畫（renderingOrder），不跟樓板、門框搶深度閃爍
      const g = scnBox(0.02, doorH - 0.1, doorW - 0.05, TM.glass(0.2));
      g.position.set(0, doorH / 2, 0); g.renderOrder = 10;
      panel.add(g);
      // 細鋼框（上下橫檔、外側直框）＋內側對接邊一條細 LED（關著時兩條併成門縫的一道光）
      const fm = new VoxelMesh(), fk = new Kit(fm);
      fk.b(I, 0, 0, 0, 0.035, 0.05, doorW, steel);
      fk.b(I, 0, doorH - 0.05, 0, 0.035, 0.05, doorW, steel);
      fk.b(I, 0, 0, side * (doorW / 2 - 0.0175), 0.035, doorH, 0.035, steel);
      fk.b(I, 0, 0.05, -side * (doorW / 2 - 0.008), 0.03, doorH - 0.1, 0.016, led);
      panel.add(fm.node("frame"));
      n.add(panel);
    }
    return n;
  },

  frontX: 0, frontH: 2.32,      // 10-25：招牌正下方（原本 x 3.8）

  /** 1 樓正門的一組滑門（掛在大廳模組底下）：兩片透明玻璃＋細鋼框＋對接邊 LED；L 往 +x、R 往 −x */
  frontDoor() {
    const g = SlideDoor.front, n = scnNode("fdoor");
    n.position.set(this.frontX, TD.room, TD.zF - 0.06);
    const steel = TM.f(TP.ST1), led = TM.glow(TP.ELEV_LED, 0.4, 1.8), I = Xf.identity, frontH = this.frontH;
    for (const [name, side] of LR) {
      const panel = scnNode(name); panel.position.set(...g.pos(side, 0));
      const gl = scnBox(g.w - 0.05, frontH - 0.1, 0.02, TM.glass(0.2));
      gl.position.set(0, frontH / 2, 0); gl.renderOrder = 10;
      panel.add(gl);
      const fm = new VoxelMesh(), fk = new Kit(fm);
      fk.b(I, 0, 0, 0, g.w, 0.05, 0.035, steel);
      fk.b(I, 0, frontH - 0.05, 0, g.w, 0.05, 0.035, steel);
      fk.b(I, side * (g.w / 2 - 0.0175), 0, 0, 0.035, frontH, 0.035, steel);
      fk.b(I, -side * (g.w / 2 - 0.008), 0.05, 0, 0.016, frontH - 0.1, 0.03, led);
      panel.add(fm.node("frame"));
      n.add(panel);
    }
    return n;
  },

  /** 門開幾成（0＝關、1＝全開）直接擺好（測試截圖、停車時用） */
  setDoor(door, k, g = SlideDoor.elevator) {
    g = slideDoorOf(g);
    for (const [name, side] of LR) {
      const p = door.children.find(c => c.name === name);
      if (!p) continue;
      removeAction(p, "door");
      p.position.set(...g.pos(side, k));
    }
  },

  /** 一次性排好這組門的開關（隊長 10-25：到站開、離站關；不 repeatForever、不每幀檢查）。
   *  stops＝車廂停在這層的時段（[{from: Date, to: Date}]）；每段到了開、結束前 doorTime 關。回傳最後一個動作結束的時間（給渲染延長） */
  runDoor(door, stops, now, g = SlideDoor.elevator) {
    g = slideDoorOf(g);
    const doorTime = this.doorTime, addS = (d, s) => new Date(d.getTime() + s * 1000), since = (a, b) => (a - b) / 1000;
    let end = now;
    for (const [name, side] of LR) {
      const p = door.children.find(c => c.name === name);
      if (!p) continue;
      removeAction(p, "door");
      const shut = g.pos(side, 0), open = g.pos(side, 1);
      const acts = [];
      let t = now, isOpen = Math.hypot(p.position.x - shut[0], p.position.y - shut[1], p.position.z - shut[2]) > 0.01;
      const move = to => {
        const a = Act.move(to, doorTime); a.timingMode = "easeInEaseOut";
        acts.push(a); t = addS(t, doorTime);
      };
      for (const st of stops.slice().sort((a, b) => a.from - b.from)) {
        const closeAt = addS(st.to, -doorTime);
        if (!(closeAt > Math.max(t, st.from) && closeAt > now)) continue;
        if (st.from > t) { acts.push(Act.wait(since(st.from, t))); t = st.from; }
        if (!isOpen) { move(open); isOpen = true; }
        if (closeAt > t) { acts.push(Act.wait(since(closeAt, t))); t = closeAt; }
        move(shut); isOpen = false;
      }
      if (isOpen) move(shut);                     // 這層沒有要停：開著的關起來
      if (acts.length) runAction(p, Act.sequence(acts), "door");
      if (t > end) end = t;
    }
    return end;
  },

  /** 電梯車廂 1.1×2.1×1.1：開口朝前、朝大樓（看得到裡面的人） */
  car() {
    const m = new VoxelMesh(), k = new Kit(m), w = TM.f(TP.FN5), I = Xf.identity;
    k.b(I, 0, 0, 0, 1.1, 0.05, 1.1, w); k.b(I, 0, 2.05, 0, 1.1, 0.05, 1.1, w);
    k.b(I, 0, 0, -0.52, 1.1, 2.1, 0.05, w); k.b(I, -0.52, 0, 0, 0.05, 2.1, 1.1, w);
    k.b(I, 0.53, 0, 0.53, 0.04, 2.1, 0.04, TM.f(TP.ST1));
    // 10-22 Kang：「電梯移動要有光（電梯裡照明、外面玻璃井打光，高級科技感）」——全用自發光材質＋一層加色光暈，不加真的燈（不多算光照）
    const led = TM.glow(TP.ELEV_LED, 1.4, 3.0);
    k.b(I, 0, 1.97, 0, 0.8, 0.04, 0.8, TM.glow(TP.ELEV_LAMP, 1.2, 2.6));            // 天花燈板
    for (const [x, z] of [[-0.48, -0.48], [0.48, -0.48], [-0.48, 0.48]]) {
      k.b(I, x, 0.08, z, 0.03, 1.88, 0.03, led);                                       // 角落直條燈
    }
    k.b(I, 0.53, 0.05, 0, 0.03, 0.025, 1.0, led);                                       // 門檻燈條（面向大樓那側）
    k.b(I, 0, 0.05, 0.53, 1.0, 0.025, 0.03, led);
    const node = m.node("car");
    // 光暈：比車廂大一圈的加色半透明盒子，跟著車廂走，隔著玻璃井看像一團光在井裡上下
    const halo = scnBox(1.3, 2.3, 1.3, this.haloMat ??= (() => {
      // .constant、diffuse 黑、emission＝ELEV_LED.blended(withFraction: 0.88, of: .black)（加色混合不吃 transparency：直接把光暈顏色壓暗）。
      // NSColor.blended 在 Mac 量到的結果是 #082329（dump），直接用這個值
      const hm = new THREE.MeshLambertMaterial({ color: 0x000000, transparent: true, blending: THREE.AdditiveBlending, depthWrite: false });
      hm.userData.lm = "constant";
      VoxMat.color(0x082329).toThree(hm.emissive); hm.emissiveIntensity = 1;
      return hm;
    })(), 0.05);
    halo.name = "car-halo"; halo.position.set(0, 1.05, 0);
    node.add(halo);
    return node;
  },
  haloMat: null,

  /** 大地面（城外的地；日夜共用一個節點，底色跟著 VoxMat.setNight 換）。
   *  10-21 Kang：背景的遠景大樓剪影拿掉（醜、佔畫面）；原本另有一塊大樓前路面被城市的路完全蓋住（重複），一起拿掉 */
  environment() {
    const m = new VoxelMesh(), k = new Kit(m);
    // 10-21 主光改版：520×420 → 1600×1600（邊緣落在霧完全遮住的距離外，夜晚不會露出一塊比天空暗的長方形）
    k.b(Xf.identity, 0, -0.4, 0, 1600, 0.4, 1600, VoxMat.dayNight(TP.groundDay, TP.groundNight));
    return m.node("env");
  },

  /** 漸層天空盒（6 張 64×64）：側面下半＝地平線色、上半漸到天頂；頂＝天頂、底＝地平線。日夜各產一次（kit.js skyCube） */
  _skyDay: null, _skyNight: null,
  get skyDay() { return this._skyDay ??= skyCube(TP.skyDay, TP.zenithDay); },
  get skyNight() { return this._skyNight ??= skyCube(TP.skyNight, TP.zenithNight); },
  /** 日出日落的天空盒（10-21）：kit.js skyGlowCube（horizon／zenith／glow 是 0–1 的 [r,g,b]；sunAngle＝太陽在世界座標的水平方向） */
  sky({ horizon, zenith, glow, glowAmount, sunAngle }) { return skyGlowCube(horizon, zenith, glow, glowAmount, sunAngle); },
};

// MARK: - 動畫（SceneKit 在渲染執行緒呼叫 customAction；JS 由 actions.js 每幀推進）

/** 搬家（規範 §3.7）：0–0.45 秒往前飄出、0.45–1.45 升降（讓位的同時移動）、1.45–2.0 滑回。
 *  items：[{ node, fromY, toY, floats, glow }] */
export class MoveAnim {
  static duration = 2.0;
  constructor(items) { this.items = items; }
  static ease(t) { return t * t * (3 - 2 * t); }
  /** 第 t 秒的姿勢（測試截圖直接呼叫；動畫每幀呼叫） */
  apply(t) {
    for (const it of this.items) {
      let y = it.fromY, z = 0, a = 0, lift = 0, g = 0;
      const mid = Math.min(Math.max((t - 0.45) / 1.0, 0), 1);
      y = it.fromY + (it.toY - it.fromY) * MoveAnim.ease(mid);
      if (it.floats) {
        if (t < 0.45) { const k = 1 - Math.pow(1 - t / 0.45, 2); z = 4 * k; lift = 0.3 * k; a = -0.08 * k; g = k; }
        else if (t < 1.45) { z = 4; lift = 0.3; a = -0.08; g = 1; }
        else { const k = Math.min(1, (t - 1.45) / 0.55); const e = k * k; z = 4 * (1 - e); lift = 0.3 * (1 - e); a = -0.08 * (1 - e); g = 1 - e; }
      }
      it.node.position.set(0, y + lift, z);
      it.node.rotation.y = a;
      if (it.glow) setNodeOpacity(it.glow, g);
    }
  }
  static action(anim) { return Act.customAction(MoveAnim.duration, (_n, el) => anim.apply(el)); }
  /** 跑在 driver 節點上；播完呼叫 done */
  static run(anim, driver, done) { runAction(driver, MoveAnim.action(anim), "move", done); }
}

/** 一趟閒晃的世界座標路線（模組不轉，所以本地→世界只是加樓層 y）。keys：[{ t, p: [x, y, z], face（null＝沒指定）, ride }] */
export class TripPath {
  constructor(keys) {
    this.keys = keys; this.duration = keys.length ? keys[keys.length - 1].t : 0;
    // 每段（keys[i-1]→keys[i]）：是不是走路、走路方向、進這段前面向哪、累積走路距離（段首）、所在連續走路區間的起訖距離
    const segs = keys.map(() => ({ walking: false, heading: 0, enter: 0, d0: 0, len: 0, runStart: 0, runEnd: 0 }));
    let d = 0, face = keys[0]?.face ?? 0;
    for (let i = 1; i < keys.length; i++) {
      const a = keys[i - 1], b = keys[i], v = v3sub(b.p, a.p);
      const g = { walking: false, heading: 0, enter: 0, d0: 0, len: 0, runStart: 0, runEnd: 0 };
      g.len = Math.hypot(v[0], v[2]);
      g.walking = !b.ride && g.len > 0.01;
      g.heading = g.walking ? Math.atan2(v[0], v[2]) : (b.face ?? a.face ?? face);
      g.enter = face;
      g.d0 = d;
      if (g.walking) d += g.len;
      face = g.walking ? g.heading : (b.face ?? a.face ?? face);
      segs[i] = g;
    }
    // 連續走路的區間：起步、停下時擺幅漸入漸出
    let i = 1;
    while (i < keys.length) {
      if (!segs[i].walking) { i += 1; continue; }
      let j = i;
      while (j + 1 < keys.length && segs[j + 1].walking) j += 1;
      const s0 = segs[i].d0, s1 = segs[j].d0 + segs[j].len;
      for (let k = i; k <= j; k++) { segs[k].runStart = s0; segs[k].runEnd = s1; }
      i = j + 1;
    }
    this.segs = segs;
  }

  /** 轉角不瞬間轉向：進新的一段前 0.3 秒內從原本的朝向轉過去 */
  static turnTime = 0.3;
  static lerpAngle(a, b, k) {
    let d = (b - a) % (2 * Math.PI);          // truncatingRemainder＝JS 的 %（同號）
    if (d > Math.PI) d -= 2 * Math.PI; else if (d < -Math.PI) d += 2 * Math.PI;
    return a + d * k;
  }

  /** 第 t 秒的位置、朝向、是不是在走路、走了多遠（步伐相位用）、擺幅（起步／停下漸變 0–1） */
  pose(t) {
    const keys = this.keys, first = keys[0];
    if (!first) return { p: [0, 0, 0], face: 0, walking: false, dist: 0, amp: 0 };
    if (t <= first.t) return { p: first.p, face: first.face ?? 0, walking: false, dist: 0, amp: 0 };
    for (let i = 1; i < keys.length; i++) {
      if (!(t < keys[i].t)) continue;
      const a = keys[i - 1], b = keys[i], g = this.segs[i];
      const k = b.t > a.t ? (t - a.t) / (b.t - a.t) : 1;
      const p = v3add(a.p, v3mul(v3sub(b.p, a.p), k));
      if (!g.walking) {
        // 停著（左右掃、等電梯）照 key 的朝向內插；搭乘（電梯、溜滑梯）同
        const fa = a.face ?? g.enter, fb = b.face ?? fa;
        return { p, face: TripPath.lerpAngle(fa, fb, k), walking: false, dist: g.d0, amp: 0 };
      }
      const turn = Math.min(1, (t - a.t) / TripPath.turnTime);
      const face = TripPath.lerpAngle(g.enter, g.heading, turn * turn * (3 - 2 * turn));
      const d = g.d0 + g.len * k;
      const amp = Math.min(1, Math.max(0, Math.min(d - g.runStart, g.runEnd - d) / 0.3));
      return { p, face, walking: true, dist: d, amp };
    }
    const l = keys[keys.length - 1];
    return { p: l.p, face: l.face ?? 0, walking: false, dist: 0, amp: 0 };
  }

  /** 步態（10-24 Kang：原本兩格硬切、看起來很假）：依走過的距離算相位，腳不會在地上滑
   *  一個完整步伐循環（左右各一步）＝ stride 公尺；腿前後 sin 擺、身體在雙腳垂直時最高（上下兩次／循環）、
   *  左右微晃（重心移到支撐腳）、身體微微前傾；起步與停下 0.3 公尺內擺幅漸變 */
  static stride = 0.84; static legSwing = 0.5; static bobH = 0.035; static sway = 0.07; static lean = 0.06;

  apply(node, t) {
    const q = this.pose(t);
    const ph = q.dist / TripPath.stride * 2 * Math.PI;
    const bob = q.walking ? TripPath.bobH * q.amp * (1 + Math.cos(2 * ph)) / 2 : 0;
    node.position.set(q.p[0], q.p[1] + bob, q.p[2]);
    node.rotation.y = q.face;
    const swing = TripPath.legSwing * q.amp * Math.sin(ph);
    const legL = node.getObjectByName("legL"), legR = node.getObjectByName("legR");
    if (legL) legL.rotation.x = swing;
    if (legR) legR.rotation.x = -swing;
    const body = node.getObjectByName("body");
    if (body) setEuler(body, TripPath.lean * q.amp, body.rotation.y, TripPath.sway * q.amp * Math.sin(ph));
  }

  static run(path, elapsed, node, done) {
    const rest = Math.max(0.05, path.duration - elapsed);
    const a = Act.customAction(rest, (n, el) => path.apply(n, elapsed + el));
    runAction(node, a, "trip", done);
  }

  /** 車廂的一段上下（世界座標高度＋絕對時間）：{ y0, y1, start: Date, end: Date } */
  static CarLeg(y0, y1, start, end) { return { y0, y1, start, end }; }

  /** 第 at 秒車廂的高度：照排好的段落線性內插（跟搭乘的人同一條線，人才不會穿出車廂）；
   *  第一段開始前停在 rest（現在停的高度），段落之間停在上一段的終點 */
  static carY(legs, at, rest) {
    let y = rest;
    for (const l of legs) {
      if (!(l.start <= at)) continue;
      if (at < l.end) {
        const k = ((at - l.start) / 1000) / Math.max(0.05, (l.end - l.start) / 1000);
        return l.y0 + (l.y1 - l.y0) * Math.min(1, Math.max(0, k));
      }
      y = l.y1;
    }
    return y;
  }

  /** 一部電梯車廂照排程上下（10-22 兩部電梯：同一部可能接連載好幾趟，整份排程一次播完；其他時間停著，不跳回大廳） */
  static runCar(car, x, z, legs, rest, now) {
    removeAction(car, "car");
    const last = legs.length ? new Date(Math.max(...legs.map(l => l.end.getTime()))) : null;
    if (!last || !(last > now)) {
      car.position.set(x, TripPath.carY(legs, now, rest), z);
      return;
    }
    const dur = Math.max(0.05, (last - now) / 1000);
    const a = Act.customAction(dur, (n, el) => {
      n.position.set(x, TripPath.carY(legs, new Date(now.getTime() + el * 1000), rest), z);
    });
    runAction(car, a, "car");
  }
}
