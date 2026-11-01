// ShoWork42 Windows 戰情中心：3D 辦公大樓的地基（11-01 P0，Mac → Windows 逐檔照搬）。
// 這個檔＝Mac 的 OfficeVoxel.swift（PixelTex、VoxMat、Xf、VoxelMesh、PixelText）＋OfficeTower.swift 開頭的 TP／TD／TM／Kit
// ＋ShoWorkCore 的 TowerSpec／TowerLayout 數字，幾乎逐行轉寫成 three.js r170。之後 OfficeTower／OfficeCity／OfficeBuilder 等檔
// 全部建立在這裡，所以 API 盡量長得跟 Swift 一樣（名字、參數順序、預設值都照抄）。
//
// Swift → JS 對照（給轉寫的 agent）：
//   k.b(f, x, y0, z, w, h, d, Self.m(0x...))        → k.b(f, x, y0, z, w, h, d, m(0x...))          （Kit 同名同序）
//   m.box(xf, SIMD3(a,b,c), SIMD3(w,h,d), mat, top:, bottom:, uv: .fit) → m.box(xf, [a,b,c], [w,h,d], mat, { top, bottom, uv: UV.fit })
//   TM.f(h)／TM.glow(h, d, n)／TM.slab／TM.backWall／TM.glass(a, h) → 同名（slab、backWall 是 getter）
//   VoxMat.tex("grass", tint: c, emit: (d, n))       → VoxMat.tex("grass", { tint: c, emit: [d, n] })
//   VoxMat.flat(0x..., emit: (d, n))                 → VoxMat.flat(0x..., { emit: [d, n] })
//   VoxMat.dayNight(a, b, glow: g, emit: (d, n))     → VoxMat.dayNight(a, b, { glow: g, emit: [d, n] })
//   Xf(x:, y:, z:, a:)／.identity／xf.at(x,y,z,a:)   → new Xf(x, y, z, a)／Xf.identity／xf.at(x, y, z, a)
//   SIMD3<Float>                                      → [x, y, z]（純陣列）
//   NSColor（VoxMat.color(h)）                        → SColor（sRGB 0–1 的 r,g,b,a；toThree() 轉 THREE.Color）
//   SCNNode()                                         → new THREE.Group()（scnNode(name)）；VoxelMesh.node(name) 回傳 THREE.Mesh（沒方塊時是 Group）
//   node.eulerAngles = SCNVector3(x, y, z)            → setEuler(node, x, y, z)（SceneKit 是 R = Rz·Ry·Rx ＝ three 的 Euler 順序 'ZYX'，
//                                                       11-01 用 SCNNode 實測過；只轉 y 時直接 node.rotation.y = a 也一樣）
//   node.isHidden = true                              → node.visible = false
//   node.opacity = x                                  → setOpacity(node, x)（three 沒有節點透明度：記在 userData.opacity，dump 照抄；畫面要淡出得自己改材質）
//   node.categoryBitMask = m                          → setCategory(node, m)（只設這個節點，不往下傳；跟 SceneKit 一樣）
//   light.categoryBitMask = m                         → light.userData.cat = m（scnLight() 的 mask 參數）
//   SCNLight（intensity 1000＝1 倍）                  → scnLight({ type, intensity, color, mask, ... })：強度自動換算（見 scnIntensity）
//   PixelText.sign("字", bg: c)                        → PixelText.sign("字", { bg: c })
//
// categoryBitMask：three r170 沒有「這盞燈只照某些物件」的功能，這裡自己補（LightMask，改 three 的 shader chunk）：
//   物件的位元記在 geometry 的頂點屬性 aLmCat（setCategory 設在 userData.cat，每幀算之前由 LightMask.prepare 補屬性），
//   燈的位元記在 userData.cat（預設 −1＝全部）；fragment shader 每盞 directional／point／spot 燈先做 (燈 & 物件) != 0 才算。
//   ambient 跟 SceneKit 一樣不吃位元（10-21 Mac 實測：ambient 照樣照到全場）。

import * as THREE from "three";

// MARK: - ShoWorkCore 的數字（TowerSpec／TowerLayout）

export const TowerSpec = {
  lobbyHeight: 4.4, floorHeight: 2.9, idleHeight: 0.9, roofHeight: 2.4,
  width: 12.0, depth: 9.8, front: 2.8, slab: 0.25,
  get back() { return this.front - this.depth; },
  get backInner() { return this.back + 0.15; },
  platesPerIdle: 8, maxIdleLayers: 1, demoteAfter: 2 * 3600, firstNumber: 2,
  kuboScale: 1.6, seatTop: 0.56, kuboSeatedHead: 0.62,
  get seatedHead() { return this.seatTop + this.kuboSeatedHead * this.kuboScale; },
  get seatedHeadRatio() { return this.seatedHead / this.floorHeight; },
  label: n => String(n).padStart(2, "0"),
};

export const TowerLayout = {
  aisleZ: 1.45,
  elevatorDoor: { x: -5.7, z: -1.3 },
  elevator: { x: -7.05, z: -1.3 },
  elevators: [{ x: -7.05, z: -1.3 }, { x: -7.05, z: -2.9 }],
  elevatorDoors: [{ x: -5.7, z: -1.3 }, { x: -5.7, z: -2.9 }],
  doorIndex(x, z) { const i = this.elevatorDoors.findIndex(d => Math.abs(d.x - x) < 1e-6 && Math.abs(d.z - z) < 1e-6); return i < 0 ? null : i; },
  slideDoor: { x: 5.5, z: 2.8 - 9.8 + 0.55 },
  slideTop: { x: 5.4, z: 2.8 - 9.8 + 0.5 },
  lounge: [{ x: 3.0, z: 1.1 }, { x: 4.5, z: 0.9 }],
  chairBack: 0.72,
  backAisleZ: -1.6,
  freeDesks: [
    [-0.7, -0.3, 0], [-1.5, -4.3, 0], [2.6, -2.6, Math.PI / 2], [-4.4, -4.6, -Math.PI / 2],
    [-0.7, 0.4, Math.PI], [-1.5, -3.6, Math.PI], [0.9, -0.3, 0], [0.1, -4.3, 0],
    [2.6, -4.4, Math.PI / 2], [-4.4, -3.0, -Math.PI / 2], [0.9, 0.4, Math.PI], [0.1, -3.6, Math.PI],
  ].map(([x, z, a]) => ({ x, z, a })),
};

// MARK: - 色票（OfficeTower.swift TP；規範 §1.1，只准用這張表）

export const TP = {
  FL1: 0xCDBFA8, FL2: 0xBDBAB3,
  WL1: 0xEEEBE5, WL2: 0xE3DFD8,
  ST1: 0x2F3338, ST2: 0xA7A49E,
  ELEV_LED: 0x5CE1FF, ELEV_LAMP: 0xEAF6FF,
  GL1: 0xB9D3D8,
  NE1: 0x8FE3EE, NE2: 0xFF5A5F,
  LT1: 0xFFD8A6,
  FN1: 0x8A6A4F, FN2: 0xC2A27F, FN3: 0x2B2C2F,
  FN4: 0x8F8B85, FN5: 0xF3F1EC, FN6: 0x1E2024,
  PL1: 0x5C7F55, PL2: 0x7C9A6A, POT: 0xD9D4CB,
  INK: 0x2F3338,
  soil: 0x5A4A3A,
  skyDay: 0xD3DCE2, skyNight: 0x141B26,
  zenithDay: 0xA9BCCB, zenithNight: 0x070A10,
  groundDay: 0xA4ABB0, groundNight: 0x0D1218,
  cityWindow: 0xE8C98F,
  hex(s) {
    const t = String(s).trim().replace(/#/g, "");
    if (t.length !== 6) return null;
    const v = parseInt(t, 16);
    return Number.isNaN(v) ? null : v;
  },
};

// MARK: - 尺寸（OfficeTower.swift TD；跟 TowerSpec／TowerLayout 一致）

export const TD = {
  W: TowerSpec.width, D: TowerSpec.depth,
  Wd: TowerSpec.width, Dd: TowerSpec.depth,
  zF: TowerSpec.front, zB: TowerSpec.front - TowerSpec.depth, zC: (TowerSpec.front + (TowerSpec.front - TowerSpec.depth)) / 2,
  zFd: TowerSpec.front, zBd: TowerSpec.front - TowerSpec.depth,
  slab: TowerSpec.slab,
  room: TowerSpec.slab + 0.01,
  clear: TowerSpec.floorHeight - TowerSpec.slab,
  backZ: TowerSpec.front - TowerSpec.depth + 0.15,
  elevX: TowerLayout.elevator.x, elevZ: TowerLayout.elevator.z,
  /** 兩部電梯：[x, z]（Swift 是 SIMD2，.x＝x、.y＝z） */
  elevs: TowerLayout.elevators.map(e => ({ x: e.x, y: e.z })),
  elevGap(c, h) { return [this.elevs[c].y - 0.45, this.elevs[c].y + 0.45, h]; },
  boardX: -10.6, boardZ: -1.0,
  slideX: 4.9, slideZ: TowerSpec.front - TowerSpec.depth - 1.0, slideR: 0.6,
  slideStep: 0.5, slideDrop: 0.16,
  slideA0: Math.PI / 4,
  slidePoint(th, top, y) { return [this.slideX + this.slideR * Math.cos(th), y, this.slideZ + this.slideR * Math.sin(th)]; },
  slideAngle(top, y) { return this.slideA0 + (top - y) / this.slideDrop * this.slideStep; },
};

// MARK: - 顏色（NSColor 的替身：sRGB 0–1）

export class SColor {
  constructor(r, g, b, a = 1) { this.r = r; this.g = g; this.b = b; this.a = a; }
  /** THREE.Color（three 內部是線性空間；這裡照 sRGB 轉進去，跟 SceneKit 的 sRGB NSColor 一樣） */
  toThree(out = new THREE.Color()) { return out.setRGB(this.r, this.g, this.b, THREE.SRGBColorSpace); }
  get css() { return `rgba(${Math.round(this.r * 255)},${Math.round(this.g * 255)},${Math.round(this.b * 255)},${this.a})`; }
  withAlpha(a) { return new SColor(this.r, this.g, this.b, a); }
}

// MARK: - 像素材質（PixelTex）

export const PixelTex = (() => {
  const M64 = (1n << 64n) - 1n;
  /** 固定種子的亂數（同 Swift：LCG 64 位元、取高 31 位） */
  class RNG {
    constructor(s) { this.s = BigInt.asUintN(64, BigInt(s)); }
    next() {
      this.s = (this.s * 6364136223846793005n + 1442695040888963407n) & M64;
      return Number(this.s >> 33n) / 2147483648;
    }
  }
  /** c(h, k)：色票 × 亮度倍數，每個分量上限 1 */
  const c = (h, k = 1) => [Math.min(1, ((h >>> 16) & 255) / 255 * k), Math.min(1, ((h >>> 8) & 255) / 255 * k), Math.min(1, (h & 255) / 255 * k)];
  /** 種子：name.unicodeScalars.reduce(7) { $0 &* 31 &+ scalar } | 1 */
  function seed(name) {
    let s = 7n;
    for (const ch of name) s = BigInt.asUintN(64, s * 31n + BigInt(ch.codePointAt(0)));
    return s | 1n;
  }
  /** 16×16 RGBA；UInt8(max(0, min(255, v * 255)))＝無條件捨去 */
  function make(name, f) {
    const n = 16, px = new Uint8Array(n * n * 4).fill(255), r = new RNG(seed(name));
    for (let y = 0; y < n; y++) {
      for (let x = 0; x < n; x++) {
        const col = f(x, y, r), i = (y * n + x) * 4;
        px[i] = Math.trunc(Math.max(0, Math.min(255, col[0] * 255)));
        px[i + 1] = Math.trunc(Math.max(0, Math.min(255, col[1] * 255)));
        px[i + 2] = Math.trunc(Math.max(0, Math.min(255, col[2] * 255)));
        px[i + 3] = 255;
      }
    }
    return px;
  }
  const noisy = (base, amp) => (_x, _y, r) => c(base, 1 - amp / 2 + r.next() * amp);
  const data = {};
  data.grass = make("grass", noisy(0x6aa84f, 0.35));
  data.dirtside = make("dirtside", (_, y, r) => y < 4 + Math.trunc(r.next() * 2) ? c(0x6aa84f, 0.8 + r.next() * 0.3) : c(0x8b5a2b, 0.8 + r.next() * 0.35));
  data.dirt = make("dirt", noisy(0x8b5a2b, 0.4));
  data.plank = make("plank", (x, y, r) => {
    const row = Math.trunc(y / 4), edge = y % 4 === 0 || (x + row * 5) % 16 === 0;
    return c(0xc8955c, edge ? 0.72 : 0.92 + r.next() * 0.16);
  });
  data.darkplank = make("darkplank", (x, y, r) => {
    const edge = y % 4 === 0 || (x + Math.trunc(y / 4) * 7) % 16 === 0;
    return c(0x7a4e2d, edge ? 0.7 : 0.9 + r.next() * 0.18);
  });
  data.stone = make("stone", noisy(0x9a9a9a, 0.3));
  data.cobble = make("cobble", (x, y, r) => (x % 8 === 0 || (y + Math.trunc(x / 8) * 4) % 8 === 0) ? c(0x6b6b6b, 0.9) : c(0xa3a3a3, 0.8 + r.next() * 0.3));
  data.leaf = make("leaf", (_x, _y, r) => r.next() < 0.15 ? c(0x2e6b2e) : c(0x4caf50, 0.75 + r.next() * 0.4));
  data.gold = make("gold", (x, y, r) => (x + y) % 7 === 0 ? c(0xfff3a0) : c(0xf2c230, 0.85 + r.next() * 0.2));
  data.wool = make("wool", (_x, _y, r) => { const v = 0.9 + r.next() * 0.1; return [v, v, v]; });
  data.lantern = make("lantern", (x, y, r) => (x < 3 || x > 12 || y < 3 || y > 12) ? c(0x3b3b3b) : c(0xffc95a, 0.85 + r.next() * 0.3));

  /** 名稱 → THREE.DataTexture（只產一次）。第 0 列＝圖的上緣＝uv v=0（跟 SceneKit 一樣，不翻轉）。
   *  近看最近鄰（一格一格的像素）、遠看 linear＋mipmap（不閃爍）、重複貼 */
  const all = {};
  for (const [name, px] of Object.entries(data)) {
    const t = new THREE.DataTexture(px, 16, 16, THREE.RGBAFormat, THREE.UnsignedByteType);
    t.colorSpace = THREE.SRGBColorSpace;
    t.magFilter = THREE.NearestFilter;
    t.minFilter = THREE.LinearMipmapLinearFilter;
    t.generateMipmaps = true;
    t.wrapS = t.wrapT = THREE.RepeatWrapping;
    t.flipY = false;
    t.needsUpdate = true;
    t.name = name;
    t.userData.pixName = name;
    all[name] = t;
  }
  return { RNG, c, make, noisy, data, all, seed };
})();

// MARK: - 材質快取（VoxMat）

/** 新材質：SceneKit .lambert ＝ MeshLambertMaterial。一律開頂點色（VoxelMesh 的 geometry 一定帶 color 屬性，沒假 AO 時全 1） */
function lambert() {
  const m = new THREE.MeshLambertMaterial({ vertexColors: true });
  m.userData.lm = "lambert";
  return m;
}

export const VoxMat = {
  cache: new Map(),
  glowing: [],            // [material, day, night]
  dayNightMats: [],       // [material, dayColor, nightColor]
  night: false,
  dark: 0, lamps: 0,
  power: 1,

  emitNow([day, night]) { return (day + (night - day) * this.lamps) * this.power; },
  /** 自己做的發光材質（招牌）也跟著日夜、停電一起變 */
  registerGlow(m, day, night) {
    m.emissiveIntensity = this.emitNow([day, night]);
    this.glowing.push([m, day, night]);
  },
  /** 電力：1＝正常、0.6 節電、0.35 吃緊、0 停電；所有發光材質一起乘。值沒變回 false */
  setPower(p) {
    p = Math.min(1, Math.max(0, p));
    if (!(Math.abs(p - this.power) > 0.001)) return false;
    this.power = p;
    for (const [m, d, n] of this.glowing) m.emissiveIntensity = this.emitNow([d, n]);
    return true;
  },
  /** sRGB 分量直接線性內插（跟 Swift 一樣，不是在線性空間混） */
  mix(a, b, t) {
    if (t <= 0) return a;
    if (t >= 1) return b;
    return new SColor(a.r + (b.r - a.r) * t, a.g + (b.g - a.g) * t, a.b + (b.b - a.b) * t, 1);
  },

  /** 像素材質（可乘一個顏色＝羊毛地毯的染色）。SceneKit 的 multiply 乘在打光之後；lambert 沒高光 ⇒ 等於 diffuse 乘 tint（color） */
  tex(name, { tint = null, emit = null } = {}) {
    const key = `t:${name}|${tint ? this.hex(tint) : ""}|${emit ? `${emit[0]},${emit[1]}` : ""}`;
    const hit = this.cache.get(key);
    if (hit) return hit;
    const m = lambert();
    m.map = PixelTex.all[name] ?? null;
    if (tint) { tint.toThree(m.color); m.userData.tint = tint; }
    if (emit) {
      m.emissiveMap = PixelTex.all[name] ?? null;
      if (tint) tint.toThree(m.emissive); else m.emissive.setRGB(1, 1, 1);     // multiply 也乘在自發光上
      m.emissiveIntensity = this.emitNow(emit);
      this.glowing.push([m, emit[0], emit[1]]);
    }
    m.name = key;
    this.cache.set(key, m);
    return m;
  },

  /** 純色方塊；emit＝會發光（螢幕、寶石）：emission 用同一個顏色 */
  flat(c, { emit = null } = {}) {
    if (typeof c === "number") c = this.color(c);
    const key = `f:${this.hex(c)}|${emit ? `${emit[0]},${emit[1]}` : ""}`;
    const hit = this.cache.get(key);
    if (hit) return hit;
    const m = lambert();
    c.toThree(m.color);
    if (emit) {
      c.toThree(m.emissive);
      m.emissiveIntensity = this.emitNow(emit);
      this.glowing.push([m, emit[0], emit[1]]);
    }
    m.name = key;
    this.cache.set(key, m);
    return m;
  },

  /** 白天、夜晚不同底色（切換時只改顏色）；有 glow／emit ＝ Swift 的 dayNight(_:_:glow:emit:) */
  dayNight(day, nightHex, { glow = null, emit = null } = {}) {
    const key = glow === null || emit === null ? `dn:${day}|${nightHex}` : `dng:${day}|${nightHex}|${glow}|${emit[0]},${emit[1]}`;
    const hit = this.cache.get(key);
    if (hit) return hit;
    const m = lambert();
    const d = this.color(day), n = this.color(nightHex);
    this.mix(d, n, this.dark).toThree(m.color);
    if (glow !== null && emit !== null) {
      this.color(glow).toThree(m.emissive);
      m.emissiveIntensity = this.emitNow(emit);
      this.glowing.push([m, emit[0], emit[1]]);
    }
    this.dayNightMats.push([m, d, n]);
    m.name = key;
    this.cache.set(key, m);
    return m;
  },

  /** 白天／夜晚 */
  setNight(n) { return this.setBlend(n ? 1 : 0, n ? 1 : 0); },
  /** 日出日落：暗度、燈連續混合；只改參數，不重建材質。值沒變回 false */
  setBlend(d, l) {
    d = Math.min(1, Math.max(0, d)); l = Math.min(1, Math.max(0, l));
    if (!(Math.abs(d - this.dark) > 0.001 || Math.abs(l - this.lamps) > 0.001)) return false;
    const dChanged = Math.abs(d - this.dark) > 0.001;
    this.dark = d; this.lamps = l; this.night = d >= 0.5;
    for (const [m, dd, nn] of this.glowing) m.emissiveIntensity = this.emitNow([dd, nn]);
    if (dChanged) for (const [m, a, b] of this.dayNightMats) this.mix(a, b, d).toThree(m.color);
    return true;
  },
  get count() { return this.cache.size; },

  color(h) { return new SColor(((h >>> 16) & 255) / 255, ((h >>> 8) & 255) / 255, (h & 255) / 255, 1); },
  /** Swift 的 hex(NSColor)：%02x%02x%02x%02x、Int(x * 255)（無條件捨去） */
  hex(c) {
    const b = x => Math.trunc(x * 255).toString(16).padStart(2, "0");
    return b(c.r) + b(c.g) + b(c.b) + b(c.a);
  },
};

// MARK: - 擺放（Xf）

/** 平面上的擺放：位置＋繞 Y 軸轉（跟 SCNNode.eulerAngles.y／three 的 rotation.y 同一個方向） */
export class Xf {
  constructor(x = 0, y = 0, z = 0, a = 0) { this.x = x; this.y = y; this.z = z; this.a = a; }
  static get identity() { return new Xf(); }
  apply(p) {
    const c = Math.cos(this.a), s = Math.sin(this.a);
    return [this.x + p[0] * c + p[2] * s, this.y + p[1], this.z - p[0] * s + p[2] * c];
  }
  rotate(v) {
    const c = Math.cos(this.a), s = Math.sin(this.a);
    return [v[0] * c + v[2] * s, v[1], -v[0] * s + v[2] * c];
  }
  /** 子座標系（child 是在這個座標系裡的擺放） */
  then(child) {
    const p = this.apply([child.x, child.y, child.z]);
    return new Xf(p[0], p[1], p[2], this.a + child.a);
  }
  at(x, y, z, a = 0) { return this.then(new Xf(x, y, z, a)); }
  get vector() { return new THREE.Vector3(this.x, this.y, this.z); }
  place(n) { n.position.set(this.x, this.y, this.z); n.rotation.y = this.a; }
}

// MARK: - 方塊合併器（VoxelMesh）

/** 材質怎麼貼：tile＝每幾公尺重複一次；fit＝每一面剛好一張；sideFit＝側面橫向重複、縱向剛好一張 */
export const UV = {
  tile: (t = 1) => ({ kind: "tile", t }),
  fit: { kind: "fit", t: 1 },
  sideFit: (t = 1) => ({ kind: "sideFit", t }),
  /** dump 用：跟 Swift 的 "\(uv)" 一樣（tile(1.0)、fit、sideFit(1.0)） */
  str(u) { return u.kind === "fit" ? "fit" : `${u.kind}(${Number.isInteger(u.t) ? u.t.toFixed(1) : String(u.t)})`; },
};

/** 6 面：法線、u 軸、v 軸（v 往下＝材質上緣在面的上緣）。順序跟 Swift 一樣：+z、+x、−z、−x、上、下 */
const FACES = [
  { n: [0, 0, 1], u: [1, 0, 0], v: [0, -1, 0] },
  { n: [1, 0, 0], u: [0, 0, -1], v: [0, -1, 0] },
  { n: [0, 0, -1], u: [-1, 0, 0], v: [0, -1, 0] },
  { n: [-1, 0, 0], u: [0, 0, 1], v: [0, -1, 0] },
  { n: [0, 1, 0], u: [1, 0, 0], v: [0, 0, 1] },
  { n: [0, -1, 0], u: [1, 0, 0], v: [0, 0, -1] },
];
const CORNERS = [[-1, -1], [1, -1], [1, 1], [-1, 1]];

/** 一堆方塊合併成一個 geometry：依材質分 group（一個 group＝一個 draw call） */
export class VoxelMesh {
  /** ao：頂點色假 AO 的地面高度（null＝不加；城市＝0） */
  constructor({ ao = null } = {}) {
    this.aoBase = ao;
    this.pos = []; this.nrm = []; this.tex = []; this.col = [];
    this.parts = [];            // [material, indices[]]
    this.index = new Map();     // material → slot
    this.boxes = 0;
    this.log = null;            // 穿插稽核（SHOWORK_CITY_AUDIT）：非 null 時記 {center, size, yaw}
    this.dumpBoxes = [];        // dump／scene_diff 用（JS 端一律記，便宜）
  }
  get isEmpty() { return this.boxes === 0; }
  static aoSide(y) {
    const t = Math.min(Math.max(y / 2.5, 0), 1);
    return 0.78 + 0.22 * t * t * (3 - 2 * t);
  }

  /** 一個方塊：xf＝擺放的座標系，c＝中心（在 xf 裡），s＝長寬高。m＝6 面同一種；top／bottom 另外指定 */
  box(xf, c, s, m, { top = null, bottom = null, uv = UV.tile(1) } = {}) {
    this.boxes += 1;
    if (this.log) this.log.push({ center: xf.apply(c), size: s.slice(), yaw: xf.a });
    const h = [s[0] / 2, s[1] / 2, s[2] / 2];
    const slots = [0, 0, 0];
    for (let k = 0; k < 6; k++) {
      const f = FACES[k];
      const mat = k === 4 ? (top ?? m) : k === 5 ? (bottom ?? m) : m;
      const hu = Math.abs(f.u[0] * h[0] + f.u[1] * h[1] + f.u[2] * h[2]);
      const hv = Math.abs(f.v[0] * h[0] + f.v[1] * h[1] + f.v[2] * h[2]);
      const du = hu * 2, dv = hv * 2;
      const center = [c[0] + f.n[0] * h[0], c[1] + f.n[1] * h[1], c[2] + f.n[2] * h[2]];
      const base = this.pos.length / 3;
      const wn = xf.rotate(f.n);
      for (const [su, sv] of CORNERS) {
        const p = xf.apply([center[0] + f.u[0] * hu * su + f.v[0] * hv * sv,
                            center[1] + f.u[1] * hu * su + f.v[1] * hv * sv,
                            center[2] + f.u[2] * hu * su + f.v[2] * hv * sv]);
        this.pos.push(p[0], p[1], p[2]); this.nrm.push(wn[0], wn[1], wn[2]);
        if (this.aoBase !== null) {
          const b = this.aoBase;
          const a = k === 4 ? (p[1] - b < 0.3 ? 0.97 : 1) : k === 5 ? 0.7 : VoxelMesh.aoSide(p[1] - b);
          this.col.push(a, a, a);
        } else {
          this.col.push(1, 1, 1);
        }
        const fu = (su + 1) / 2, fv = (sv + 1) / 2;
        switch (uv.kind) {
          case "tile": this.tex.push(fu * du / uv.t, fv * dv / uv.t); break;
          case "fit": this.tex.push(fu, fv); break;
          case "sideFit": if (k < 4) this.tex.push(fu * du / uv.t, fv); else this.tex.push(fu * du / uv.t, fv * dv / uv.t); break;
        }
      }
      const i = this.slot(mat);
      this.parts[i][1].push(base, base + 2, base + 1, base, base + 3, base + 2);
      if (k === 0) slots[0] = i; else if (k === 4) slots[1] = i; else if (k === 5) slots[2] = i;
    }
    this.dumpBoxes.push({ c: xf.apply(c), s: s.slice(), yaw: xf.a, side: slots[0], top: slots[1], bottom: slots[2], uv: UV.str(uv) });
  }

  slot(m) {
    if (!m) throw new Error("VoxelMesh.box：材質是空的");
    const i = this.index.get(m);
    if (i !== undefined) return i;
    this.parts.push([m, []]); this.index.set(m, this.parts.length - 1);
    return this.parts.length - 1;
  }

  /** 合併成一個節點（一個 geometry、每種材質一個 group）。沒有方塊 ⇒ 空的 Group（同 Swift 的空 SCNNode） */
  node(name = null) {
    if (this.pos.length === 0) { const g = new THREE.Group(); if (name) g.name = name; return g; }
    const g = new THREE.BufferGeometry();
    g.setAttribute("position", new THREE.Float32BufferAttribute(this.pos, 3));
    g.setAttribute("normal", new THREE.Float32BufferAttribute(this.nrm, 3));
    g.setAttribute("uv", new THREE.Float32BufferAttribute(this.tex, 2));
    g.setAttribute("color", new THREE.Float32BufferAttribute(this.col, 3));
    const idx = [];
    this.parts.forEach(([, ix], mi) => { g.addGroup(idx.length, ix.length, mi); for (const v of ix) idx.push(v); });
    g.setIndex(this.pos.length / 3 > 65535 ? new THREE.Uint32BufferAttribute(idx, 1) : new THREE.Uint16BufferAttribute(idx, 1));
    g.computeBoundingSphere();
    const n = new THREE.Mesh(g, this.parts.map(p => p[0]));
    if (name) n.name = name;
    n.userData.voxBoxes = this.dumpBoxes;
    n.userData.ao = this.aoBase;
    return n;
  }
}

// MARK: - 像素字（PixelText）

export const PixelText = {
  font: size => `600 ${size}px "Microsoft JhengHei", "PingFang TC", sans-serif`,
  /** 小字不反鋸齒畫進點陣圖（canvas 沒辦法關文字反鋸齒 ⇒ 畫完用 alpha ≥ 50% 二值化）。回傳 [canvas, W, H] */
  image(s, { fg = new SColor(1, 1, 1), bg, size = 11, padX = 4, padY = 2 } = {}) {
    const probe = document.createElement("canvas").getContext("2d");
    probe.font = this.font(size);
    const mt = probe.measureText(s);
    const asc = mt.fontBoundingBoxAscent ?? size * 0.8, desc = mt.fontBoundingBoxDescent ?? size * 0.2;
    const W = Math.ceil(mt.width) + padX * 2, H = Math.ceil(asc + desc) + padY * 2;
    // 文字層：透明底畫字，再逐像素二值化成 fg／bg
    const tc = document.createElement("canvas"); tc.width = W; tc.height = H;
    const tx = tc.getContext("2d");
    tx.font = this.font(size); tx.textBaseline = "alphabetic"; tx.fillStyle = "#fff";
    // Swift：在 (padX, padY − descender×0.15) 畫（原點左下）⇒ 換成左上原點的基線位置
    const top = padY - desc * 0.15;
    tx.fillText(s, padX, top + asc);
    const img = tx.getImageData(0, 0, W, H);
    const out = new ImageData(W, H);
    const F = [fg.r, fg.g, fg.b].map(x => Math.round(x * 255)), B = [bg.r, bg.g, bg.b].map(x => Math.round(x * 255));
    for (let i = 0; i < W * H; i++) {
      const on = img.data[i * 4 + 3] >= 128, c = on ? F : B;
      out.data[i * 4] = c[0]; out.data[i * 4 + 1] = c[1]; out.data[i * 4 + 2] = c[2];
      out.data[i * 4 + 3] = Math.round((on ? fg.a : bg.a) * 255);
    }
    const cv = document.createElement("canvas"); cv.width = W; cv.height = H;
    cv.getContext("2d").putImageData(out, 0, 0);
    return [cv, W, H];
  },
  /** 像素字招牌：一塊平面，每 pxPerMeter 個像素一公尺；SceneKit .constant ＝ MeshBasicMaterial（不吃光）、雙面 */
  sign(s, { fg = new SColor(1, 1, 1), bg, pxPerMeter = 32, size = 11 } = {}) {
    const [cv, W, H] = this.image(s, { fg, bg, size });
    const t = new THREE.CanvasTexture(cv);
    t.colorSpace = THREE.SRGBColorSpace;
    t.magFilter = THREE.NearestFilter; t.minFilter = THREE.LinearFilter; t.generateMipmaps = false;
    const m = new THREE.MeshBasicMaterial({ map: t, side: THREE.DoubleSide });
    m.userData.lm = "constant";
    const n = new THREE.Mesh(new THREE.PlaneGeometry(W / pxPerMeter, H / pxPerMeter), m);
    return n;
  },
};

// MARK: - 材質（TM）與積木（Kit）

const glassCache = new Map();
export const TM = {
  f: h => VoxMat.flat(h),
  glow: (h, day, night) => VoxMat.flat(h, { emit: [day, night] }),
  /** 樓板側邊（ST-2）：白天 #8E8B85、夜晚 #A7A49E */
  get slab() { return VoxMat.dayNight(0x8E8B85, TP.ST2); },
  /** 後牆（WL-1）：白天 #E6E1D8、夜晚 #EEEBE5 */
  get backWall() { return VoxMat.dayNight(0xE6E1D8, TP.WL1); },
  /** 透明玻璃（GL-1）：不寫深度、雙面；一種透明度一份（共用） */
  glass(alpha, h = TP.GL1) {
    const k = `${h}|${alpha}`;
    const hit = glassCache.get(k);
    if (hit) return hit;
    const m = lambert();
    VoxMat.color(h).toThree(m.color);
    m.transparent = true; m.opacity = alpha; m.depthWrite = false; m.side = THREE.DoubleSide;
    m.name = "glass:" + k;
    glassCache.set(k, m);
    return m;
  },
};

/** 一件家具的積木工具：b(…)＝底面在 y0 的方塊（座標在家具自己的框裡，+z＝正面朝鏡頭） */
export class Kit {
  constructor(m) { this.m = m; }
  b(xf, x, y0, z, w, h, d, mat) { this.m.box(xf, [x, y0 + h / 2, z], [w, h, d], mat); }
}

// MARK: - SceneKit 節點的替身

export function scnNode(name = null) { const g = new THREE.Group(); if (name) g.name = name; return g; }
/** SCNNode.eulerAngles：SceneKit 的旋轉矩陣是 Rz·Ry·Rx ⇒ three 的 Euler 順序 'ZYX'（11-01 SCNNode 實測，(0.3, 0.5, 0.7) 的 front 一致） */
export function setEuler(n, x, y, z) { n.rotation.set(x, y, z, "ZYX"); }
/** SCNNode 的 −Z 方向（simdWorldFront；只看自己的 rotation） */
export function frontOfEuler(x, y, z) { return new THREE.Vector3(0, 0, -1).applyEuler(new THREE.Euler(x, y, z, "ZYX")); }
/** categoryBitMask（只設這個節點；預設 1）。燈的 categoryBitMask 寫在燈的 userData.cat */
export function setCategory(n, mask) { n.userData.cat = mask | 0; LightMask.dirty = true; }
export function category(n) { return n.userData.cat ?? 1; }
/** SCNNode.opacity：three 沒有節點透明度，只記下來（dump 照抄；cutaway 實際用 visible） */
export function setOpacity(n, o) { n.userData.opacity = o; }
/** SCNNode.enumerateHierarchy：自己＋所有子孫 */
export function enumerateHierarchy(n, f) { n.traverse(f); }

// MARK: - 燈光換算（11-01 量尺驗證過，數字在 scnIntensity 的註解）

/**
 * SceneKit light.intensity → three r170 的強度。
 *   SceneKit：intensity 1000 ＝ 1 倍（lambert：diffuse × Σ 光色 × 強度/1000 × N·L＋ambient 光色 × 強度/1000 × diffuse）。
 *   three r170：物理光照（沒有 legacy 模式了），Lambert 的 BRDF＝diffuse/π，直射光 irradiance＝光色×強度×N·L ⇒ 要多乘 π 才一樣亮；
 *   AmbientLight 的 irradiance 一樣經過 BRDF_Lambert（/π）⇒ ambient 也乘 π。
 *   ⇒ three 強度 ＝ SceneKit 值 / 1000 × π。
 *   11-01 量尺（windows/tools/shots.sh --kit --dump；Mac SCNRenderer vs headless Chrome，同鏡頭、同一點 5×5 平均 sRGB）：
 *     白天：白方塊頂面 室內位元 255,255,251／戶外位元 250,246,242、正面 255,248,241、右側 193,199,204 ⇒ 兩邊完全一樣（差 0）；
 *           假 AO 柱、自發光、地面、omni 衰減那排全部差 ≤ 0.1。
 *     夜晚（加上 ScnPost 的 bloom／vignette）：最大差 2.5（bloom 光暈形狀是擬合的）。
 *   omni 衰減也量過：SceneKit ＝ pow(clamp((end − d)/(end − start)), falloff)，6 個距離兩邊差 ≤ 0.2。
 */
export function scnIntensity(i) { return i / 1000 * Math.PI; }
export function threeToScnIntensity(i) { return i * 1000 / Math.PI; }

/**
 * 一盞 SceneKit 燈的 three 版本：type＝"ambient"｜"directional"｜"omni"｜"spot"；mask＝categoryBitMask（預設 −1＝全部）。
 *   directional：SceneKit 的光沿節點的 −Z 照；這裡用 euler（[x,y,z]，ZYX）或 front（世界方向）定方向，target 固定在原點、燈放在 −front×100。
 *   omni：attenuation start／end／falloff（SceneKit 預設 falloff 2）。three 的 PointLight 衰減公式不一樣 ⇒ 用 decay 欄位傳 SceneKit 參數
 *         （decay < 0 ＝ SceneKit 模式：decay ＝ −(start + 1000 × falloff)），shader 裡改用 pow(clamp((end − d)/(end − start)), falloff)。
 */
export function scnLight({ type, intensity = 1000, color = 0xFFFFFF, mask = -1, euler = null, front = null, start = 0, end = 0, falloff = 2 } = {}) {
  const c = (typeof color === "number" ? VoxMat.color(color) : color).toThree();
  let l;
  switch (type) {
    case "ambient": l = new THREE.AmbientLight(c, scnIntensity(intensity)); break;
    case "directional": l = new THREE.DirectionalLight(c, scnIntensity(intensity)); break;
    case "omni": l = new THREE.PointLight(c, scnIntensity(intensity)); setAttenuation(l, start, end, falloff); break;
    case "spot": l = new THREE.SpotLight(c, scnIntensity(intensity)); setAttenuation(l, start, end, falloff); break;
    default: throw new Error("scnLight：不認得 " + type);
  }
  l.userData.cat = mask;
  l.userData.scnType = type;
  if (type === "directional") {
    if (euler) aimDirectional(l, frontOfEuler(...euler));
    else aimDirectional(l, front ?? new THREE.Vector3(0, 0, -1));
  }
  return l;
}
/** directional 燈的方向（世界座標的「光行進方向」＝SCNNode.simdWorldFront） */
export function aimDirectional(l, front) {
  const f = front.clone().normalize();
  l.position.copy(f).multiplyScalar(-100);
  l.target.position.set(0, 0, 0);
  l.userData.front = f;
}
export function setScnIntensity(l, i) { l.intensity = scnIntensity(i); }
export function setAttenuation(l, start, end, falloff = 2) {
  l.distance = end;
  l.decay = -(start + 1000 * falloff);
  l.userData.att = [start, end, falloff];
}

// MARK: - categoryBitMask 的燈光遮罩（LightMask）

/**
 * 做法：改 three 的 ShaderChunk／ShaderLib（全域，只做一次，要在第一次編譯 shader 之前呼叫 LightMask.install()）。
 *   vertex：attribute aLmCat（物件位元 −1）→ varying vLmCat；fragment：每盞 directional／point／spot 算光前乘 lmOn(燈位元)。
 *   燈的位元：每幀 render 前（scene.onBeforeRender）照 three 收集燈的順序（traverseVisible，沒有陰影時就是這個順序）填進共用的 Int32Array。
 *   物件位元：LightMask.prepare(scene) 幫每個 Mesh 的 geometry 補 aLmCat（共用 geometry 但位元不同的會複製一份）。
 *   沒有 aLmCat 的 geometry 讀到 0 ⇒ 位元 1（SceneKit 的預設），所以漏補也不會全黑。
 */
export const LightMask = {
  MAX_DIR: 16, MAX_POINT: 32, MAX_SPOT: 16,
  dir: new Int32Array(16).fill(-1),
  point: new Int32Array(32).fill(-1),
  spot: new Int32Array(16).fill(-1),
  installed: false,
  dirty: true,
  install() {
    if (this.installed) return;
    this.installed = true;
    const SC = THREE.ShaderChunk, SL = THREE.ShaderLib;
    const must = (s, a) => { if (!s.includes(a)) throw new Error("LightMask：three 的 shader 找不到 " + a); };
    // 燈：每盞算完 directLight 之後乘 0／1
    let lf = SC.lights_fragment_begin;
    for (const [a, arr] of [["getDirectionalLightInfo( directionalLight, directLight );", "uLmDir"],
                            ["getPointLightInfo( pointLight, geometryPosition, directLight );", "uLmPoint"],
                            ["getSpotLightInfo( spotLight, geometryPosition, directLight );", "uLmSpot"]]) {
      must(lf, a);
      lf = lf.replace(a, `${a}\n\t\tdirectLight.color *= lmOn( ${arr}[ i ] );`);
    }
    SC.lights_fragment_begin = lf;
    // 宣告＋SceneKit 的 omni 衰減（decay < 0）
    let lp = SC.lights_pars_begin;
    const att = "float distanceFalloff = 1.0 / max( pow( lightDistance, decayExponent ), 0.01 );";
    must(lp, att);
    lp = lp.replace(att, `if ( decayExponent < 0.0 ) {
\t\tfloat lmD = - decayExponent; float lmFe = floor( lmD / 1000.0 ); float lmSt = lmD - lmFe * 1000.0;
\t\treturn pow( saturate( ( cutoffDistance - lightDistance ) / max( cutoffDistance - lmSt, 1e-4 ) ), lmFe );
\t}
\t${att}`);
    SC.lights_pars_begin = `varying float vLmCat;
uniform int uLmDir[ ${this.MAX_DIR} ];
uniform int uLmPoint[ ${this.MAX_POINT} ];
uniform int uLmSpot[ ${this.MAX_SPOT} ];
float lmOn( const in int m ) { int c = int( round( vLmCat ) ) + 1; return ( ( m & c ) != 0 ) ? 1.0 : 0.0; }
` + lp;
    // 有吃燈的材質：vertex 把 aLmCat 傳下去、uniform 共用同一個 Int32Array（cloneUniforms 對 typed array 只複製參照）
    for (const k of ["lambert", "phong", "standard", "physical", "toon", "shadow"]) {
      const s = SL[k];
      if (!s) continue;
      must(s.vertexShader, "#include <common>"); must(s.vertexShader, "#include <begin_vertex>");
      s.vertexShader = s.vertexShader.replace("#include <common>", "#include <common>\nattribute float aLmCat;\nvarying float vLmCat;")
        .replace("#include <begin_vertex>", "#include <begin_vertex>\n\tvLmCat = aLmCat;");
      s.uniforms.uLmDir = { value: this.dir };
      s.uniforms.uLmPoint = { value: this.point };
      s.uniforms.uLmSpot = { value: this.spot };
    }
  },
  /**
   * SceneKit 實測（11-01，macOS 27，SCNRenderer）：omni、spot 燈「不吃」自己的 categoryBitMask —— 燈設 64、方塊設 1／16／64 三個一樣亮
   * （只有方塊位元 0 才完全不受光）；directional 有吃、ambient 不吃。Mac 的每層 omni 分位元（assignOmni）實際上沒有隔開樓層。
   * 為了跟 Mac 畫面一樣，這裡照實測：point／spot 一律當成 −1。要照「文件上的語意」就把這個改 false。
   */
  pointIgnoresMask: true,
  /** 每幀 render 前：燈的位元依 three 的收集順序排好 */
  updateLights(scene) {
    let di = 0, pi = 0, si = 0;
    scene.traverseVisible(o => {
      if (!o.isLight) return;
      const m = o.userData.cat ?? -1;
      if (o.isDirectionalLight && di < this.MAX_DIR) this.dir[di++] = m;
      else if (o.isPointLight && pi < this.MAX_POINT) this.point[pi++] = this.pointIgnoresMask ? -1 : m;
      else if (o.isSpotLight && si < this.MAX_SPOT) this.spot[si++] = this.pointIgnoresMask ? -1 : m;
    });
  },
  /** 物件位元 → geometry 的 aLmCat（值＝位元 − 1）；共用 geometry 但位元不同的就複製一份 */
  prepare(scene) {
    const owner = new Map();
    scene.traverse(o => {
      if (!o.isMesh || !o.geometry?.attributes?.position) return;
      const cat = o.userData.cat ?? 1, g = o.geometry;
      const prev = owner.get(g);
      if (prev !== undefined && prev !== cat) { o.geometry = g.clone(); o.geometry.userData = { ...g.userData }; }
      owner.set(o.geometry, cat);
      const geo = o.geometry, a = geo.attributes.aLmCat;
      if (a && geo.userData.lmCat === cat && a.count === geo.attributes.position.count) return;
      geo.setAttribute("aLmCat", new THREE.BufferAttribute(new Float32Array(geo.attributes.position.count).fill(cat - 1), 1));
      geo.userData.lmCat = cat;
    });
    this.dirty = false;
  },
  /** 掛到場景上：每幀算之前更新燈的位元、補物件屬性 */
  attach(scene) {
    this.install();
    const prev = scene.onBeforeRender;
    scene.onBeforeRender = (...a) => { this.prepare(scene); this.updateLights(scene); prev?.apply(scene, a); };
  },
};

// MARK: - SceneKit 相機後製（HDR bloom＋vignetting）

/**
 * SCNCamera 的 wantsHDR／bloomIntensity／bloomThreshold／bloomBlurRadius／vignettingIntensity／vignettingPower 的近似。
 * 11-01 用獨立 SceneKit 小場景量的（scratch 腳本：一整片灰平面量 vignette、黑底自發光方塊量 bloom 光暈）：
 *   vignette：線性倍數 ＝ 1 − 強度 × min(1, r²)，r＝NDC 半徑（不乘寬高比；x、y 各 −1…1）。強度 0.35 時邊緣中點 0.66、四角 0.65（飽和）。
 *             power 只量過 1（Mac 只用 1），這裡當指數用。
 *   bloom：亮部＝亮度超過門檻的量 x 經過 1 − e^(−1.55x)（會飽和：x 0.2→0.27、1.2→0.78、3.2→0.99），
 *          高斯模糊 σ ≈ 7.4 px（畫面高 1000 px、blurRadius 8；照畫面高等比例），再 × bloomIntensity 加回去。誤差：光暈形狀 ±10%。
 *   SceneKit 只有 wantsHDR 時才有 bloom／vignette（Mac 白天 wantsHDR＝false ⇒ 直接畫，跟沒後製一樣）。
 *   HDR 本身沒有 tone mapping（wantsExposureAdaptation＝false 時，同一個灰在 HDR 開關下都是 175）。
 */
export class ScnPost {
  constructor(renderer) {
    this.renderer = renderer;
    this.size = new THREE.Vector2();
    this.scene = new THREE.Scene();
    this.cam = new THREE.OrthographicCamera(-1, 1, 1, -1, 0, 1);
    const vs = "varying vec2 vUv; void main() { vUv = uv; gl_Position = vec4( position.xy, 0.0, 1.0 ); }";
    this.bright = new THREE.ShaderMaterial({ uniforms: { tSrc: { value: null }, thr: { value: 0.8 } }, vertexShader: vs, fragmentShader: `
      uniform sampler2D tSrc; uniform float thr; varying vec2 vUv;
      void main() {
        vec3 c = texture2D( tSrc, vUv ).rgb;
        float l = dot( c, vec3( 0.2126, 0.7152, 0.0722 ) );
        float b = 1.0 - exp( -1.55 * max( l - thr, 0.0 ) );
        gl_FragColor = vec4( c / max( l, 1e-4 ) * b, 1.0 );
      }` });
    this.blur = new THREE.ShaderMaterial({ uniforms: { tSrc: { value: null }, dir: { value: new THREE.Vector2() }, sigma: { value: 3.7 } }, vertexShader: vs, fragmentShader: `
      uniform sampler2D tSrc; uniform vec2 dir; uniform float sigma; varying vec2 vUv;
      void main() {
        vec3 acc = vec3( 0.0 ); float ws = 0.0;
        for ( int i = -14; i <= 14; i ++ ) {
          float w = exp( - float( i * i ) / ( 2.0 * sigma * sigma ) );
          acc += texture2D( tSrc, vUv + dir * float( i ) ).rgb * w; ws += w;
        }
        gl_FragColor = vec4( acc / ws, 1.0 );
      }` });
    this.comp = new THREE.ShaderMaterial({
      uniforms: { tScene: { value: null }, tBloom: { value: null }, bloom: { value: 0 }, vig: { value: 0 }, vigPow: { value: 1 } },
      vertexShader: vs, fragmentShader: `
      uniform sampler2D tScene; uniform sampler2D tBloom; uniform float bloom; uniform float vig; uniform float vigPow; varying vec2 vUv;
      void main() {
        vec3 c = texture2D( tScene, vUv ).rgb + bloom * texture2D( tBloom, vUv ).rgb;
        vec2 p = vUv * 2.0 - 1.0;
        c *= 1.0 - vig * pow( min( 1.0, dot( p, p ) ), vigPow );
        gl_FragColor = vec4( c, 1.0 );
        #include <colorspace_fragment>
      }` });
    this.quad = new THREE.Mesh(new THREE.PlaneGeometry(2, 2), this.comp);
    this.quad.frustumCulled = false;
    this.scene.add(this.quad);
    this.rt = null;
  }
  ensure(w, h) {
    if (this.rt && this.rt.width === w && this.rt.height === h) return;
    this.rt?.dispose(); this.a?.dispose(); this.b?.dispose();
    const samples = this.renderer.getContext().getContextAttributes().antialias ? 4 : 0;
    this.rt = new THREE.WebGLRenderTarget(w, h, { type: THREE.HalfFloatType, samples });
    const hw = Math.max(1, w >> 1), hh = Math.max(1, h >> 1);
    this.a = new THREE.WebGLRenderTarget(hw, hh, { type: THREE.HalfFloatType });
    this.b = new THREE.WebGLRenderTarget(hw, hh, { type: THREE.HalfFloatType });
  }
  pass(mat, target) { this.quad.material = mat; this.renderer.setRenderTarget(target); this.renderer.render(this.scene, this.cam); }
  /** post＝{ hdr, bloom, bloomThreshold, bloomBlur, vignette, vignettePower }（OfficeBuilder.post） */
  render(scene, camera, post) {
    const r = this.renderer;
    if (!post || !post.hdr) { r.setRenderTarget(null); r.render(scene, camera); return; }
    r.getDrawingBufferSize(this.size);
    const w = this.size.x, h = this.size.y;
    this.ensure(w, h);
    r.setRenderTarget(this.rt); r.render(scene, camera);
    if (post.bloom > 0) {
      this.bright.uniforms.tSrc.value = this.rt.texture; this.bright.uniforms.thr.value = post.bloomThreshold;
      this.pass(this.bright, this.a);
      const sigma = 7.4 * (post.bloomBlur / 8) * (h / 1000) / 2;          // 半解析度
      this.blur.uniforms.sigma.value = sigma;
      this.blur.uniforms.tSrc.value = this.a.texture; this.blur.uniforms.dir.value.set(1 / this.a.width, 0); this.pass(this.blur, this.b);
      this.blur.uniforms.tSrc.value = this.b.texture; this.blur.uniforms.dir.value.set(0, 1 / this.a.height); this.pass(this.blur, this.a);
    }
    this.comp.uniforms.tScene.value = this.rt.texture;
    this.comp.uniforms.tBloom.value = this.a.texture;
    this.comp.uniforms.bloom.value = post.bloom > 0 ? post.bloom : 0;
    this.comp.uniforms.vig.value = post.vignette; this.comp.uniforms.vigPow.value = post.vignettePower;
    this.pass(this.comp, null);
  }
}

// MARK: - 天空盒（TowerCore.sky：6 張 64×64，+X −X +Y −Y +Z −Z）

function canvasFrom(n, f) {
  const cv = document.createElement("canvas"); cv.width = n; cv.height = n;
  const cx = cv.getContext("2d"), img = cx.createImageData(n, n);
  for (let row = 0; row < n; row++) for (let x = 0; x < n; x++) {
    const c = f(row, x), i = (row * n + x) * 4;
    img.data[i] = Math.trunc(Math.min(255, Math.max(0, c[0]))); img.data[i + 1] = Math.trunc(Math.min(255, Math.max(0, c[1])));
    img.data[i + 2] = Math.trunc(Math.min(255, Math.max(0, c[2]))); img.data[i + 3] = 255;
  }
  cx.putImageData(img, 0, 0);
  return cv;
}
function cube(faces) {
  const t = new THREE.CubeTexture(faces);
  t.colorSpace = THREE.SRGBColorSpace;
  t.needsUpdate = true;
  return t;
}
/** 固定日夜的天空（地平線色、天頂色）：側面上半漸到天頂、下半＝地平線；頂＝天頂、底＝地平線 */
export function skyCube(h, z) {
  const n = 64, rgb = c => [(c >>> 16) & 255, (c >>> 8) & 255, c & 255];
  const ch = rgb(h), cz = rgb(z);
  const side = canvasFrom(n, row => {
    if (row >= n / 2) return ch;
    const t = (n / 2 - 1 - row) / (n / 2 - 1), s = t * t * (3 - 2 * t);
    return [ch[0] + (cz[0] - ch[0]) * s, ch[1] + (cz[1] - ch[1]) * s, ch[2] + (cz[2] - ch[2]) * s];
  });
  const top = canvasFrom(n, () => cz), bottom = canvasFrom(n, () => ch);
  return cube([side, side, top, bottom, side, side]);
}
/** 日出日落的天空：sky() 的上下漸層＋太陽那側地平線光暈（horizon／zenith／glow 是 0–1 的 [r,g,b]）。
 *  注意：three 的 CubeTexture 背景左右是鏡像的（flipEnvMap）；光暈的水平位置還沒跟 Mac 對過（固定日夜不受影響） */
export function skyGlowCube(horizon, zenith, glow, glowAmount, sunAngle) {
  const n = 64, sx = Math.sin(sunAngle), sz = -Math.cos(sunAngle);
  const faces = [[[1, 0, 0], [0, 0, -1]], [[-1, 0, 0], [0, 0, 1]], [[0, 0, 1], [1, 0, 0]], [[0, 0, -1], [-1, 0, 0]]];
  const ch = horizon.map(x => x * 255), cz = zenith.map(x => x * 255), cg = glow.map(x => x * 255);
  const sides = faces.map(([nrm, right]) => canvasFrom(n, (row, x) => {
    const u = (x + 0.5) / n * 2 - 1;
    const d = [nrm[0] + right[0] * u, 0, nrm[2] + right[2] * u];
    const len = Math.hypot(d[0], d[2]), hx = d[0] / len, hz = d[2] / len;
    const toward = Math.max(0, (hx * sx + hz * sz + 1) / 2), side = toward * toward * toward;
    let c = ch.slice(), up = 0;
    if (row < n / 2) {
      const t = (n / 2 - 1 - row) / (n / 2 - 1), s = t * t * (3 - 2 * t);
      c = [0, 1, 2].map(i => ch[i] + (cz[i] - ch[i]) * s); up = t;
    }
    const w = glowAmount * (0.18 + 0.82 * side) * Math.exp(-up * 3.2);
    return [0, 1, 2].map(i => c[i] + (cg[i] - c[i]) * Math.min(1, w));
  }));
  return cube([sides[0], sides[1], canvasFrom(n, () => cz), canvasFrom(n, () => ch), sides[2], sides[3]]);
}

// MARK: - dump（跟 Mac SceneDump.swift 同一個格式；windows/tools/scene_diff.py 比對）

const R = (x, p = 10000) => Number.isFinite(x) ? Math.round(x * p) / p : 0;
const V3 = v => [R(v[0] ?? v.x), R(v[1] ?? v.y), R(v[2] ?? v.z)];
const HEX = c => "#" + c.getHexString(THREE.SRGBColorSpace);
function texKey(t) { return t ? (t.userData?.pixName ? "tex:" + t.userData.pixName : "img") : null; }
/** 材質 key：lm|d|m|e|ec|a|ds|zw|bm（跟 SceneDump.matKey 一樣）。MeshBasicMaterial 沒有 emissive：要對照 Swift 的 constant＋emission 就在 userData.emission = {color: SColor, intensity} */
export function matKey(m) {
  const lm = m.userData?.lm ?? (m.isMeshLambertMaterial ? "lambert" : m.isMeshBasicMaterial ? "constant" : m.isMeshPhongMaterial ? "blinn" : m.isMeshStandardMaterial ? "pbr" : m.type);
  const white = m.color && m.color.getHex(THREE.SRGBColorSpace) === 0xffffff;
  const d = m.map ? texKey(m.map) : m.color ? HEX(m.color) : "#ffffff";
  const mul = m.map && m.color && !white ? HEX(m.color) : "";
  let ec = "", e = 0;
  if (m.emissiveMap) { ec = texKey(m.emissiveMap); e = m.emissiveIntensity; }
  else if (m.emissive && m.emissive.getHex() !== 0) { ec = HEX(m.emissive); e = m.emissiveIntensity; }
  else if (m.userData?.emission) { ec = HEX(m.userData.emission.color.toThree()); e = m.userData.emission.intensity; }
  const a = m.transparent ? m.opacity : 1;
  const bm = m.blending === THREE.AdditiveBlending ? "add" : "alpha";
  return [lm, d, mul, "e" + e.toFixed(2), ec, "a" + a.toFixed(2), m.side === THREE.DoubleSide ? "2s" : "1s", m.depthWrite ? "zw" : "nz", bm].join("|");
}
function yawOf(me) {
  const x = new THREE.Vector3(me[0], me[1], me[2]).normalize();
  return Math.atan2(-x.z, x.x);
}
function geomDesc(g, o) {
  const s = o.userData.scn;
  if (s) return [s.type, s.params];
  const p = g.parameters ?? {};
  switch (g.type) {
    case "PlaneGeometry": return ["SCNPlane", { w: R(p.width), h: R(p.height) }];
    case "BoxGeometry": return ["SCNBox", { w: R(p.width), h: R(p.height), l: R(p.depth), chamfer: 0 }];
    case "CylinderGeometry": return p.radiusTop === p.radiusBottom ? ["SCNCylinder", { r: R(p.radiusTop), h: R(p.height) }]
      : ["SCNCone", { r0: R(p.radiusTop), r1: R(p.radiusBottom), h: R(p.height) }];
    case "TorusGeometry": return ["SCNTorus", { ring: R(p.radius), pipe: R(p.tube) }];
    case "SphereGeometry": return ["SCNSphere", { r: R(p.radius) }];
    case "CapsuleGeometry": return ["SCNCapsule", { r: R(p.radius), h: R(p.length + 2 * p.radius) }];
    default: {
      if (!g.boundingBox) g.computeBoundingBox();
      const b = g.boundingBox;
      return ["SCNGeometry", { bboxLo: V3(b.min), bboxHi: V3(b.max), verts: g.attributes.position?.count ?? 0 }];
    }
  }
}
const LIGHT_TYPE = l => l.userData.scnType ?? (l.isAmbientLight ? "ambient" : l.isDirectionalLight ? "directional" : l.isPointLight ? "omni" : l.isSpotLight ? "spot" : l.type);

/** 走訪整個 three 場景（或路徑以 only 開頭的子樹）：方塊、其他 geometry、燈光、材質 */
export function walkScene(root, only = null) {
  root.updateMatrixWorld(true);
  const out = { boxes: [], geoms: [], lights: [], mats: new Set() };
  const walk = (n, path, hidden, opacity, isRoot) => {
    const p = !isRoot && n.name ? (path ? path + "/" + n.name : n.name) : path;
    const h = hidden || !n.visible, o = opacity * (n.userData.opacity ?? 1);
    const take = only === null || p.startsWith(only);
    const me = n.matrixWorld.elements;
    if (take && n.isLight) {
      const d = { type: LIGHT_TYPE(n), intensity: R(threeToScnIntensity(n.intensity), 1000), mask: n.userData.cat ?? -1,
                  pos: V3(new THREE.Vector3().setFromMatrixPosition(n.matrixWorld)), dir: [0, 0, -1], p, h, color: HEX(n.color) };
      if (n.isDirectionalLight) {
        const a = new THREE.Vector3().setFromMatrixPosition(n.matrixWorld), b = new THREE.Vector3().setFromMatrixPosition(n.target.matrixWorld);
        d.dir = V3(b.sub(a).normalize()); d.pos = [0, 0, 0];
      }
      if (n.userData.att) d.att = n.userData.att.map(x => R(x));
      out.lights.push(d);
    }
    if (take && (n.isMesh || n.isLine)) {        // isLine：THREE.LineSegments（B1 神經網路的 neural-edges＝Mac 的線段 SCNGeometry）
      const mats = Array.isArray(n.material) ? n.material : [n.material];
      const keys = mats.map(matKey);
      keys.forEach(k => out.mats.add(k));
      const sx = Math.hypot(me[0], me[1], me[2]), sy = Math.hypot(me[4], me[5], me[6]), sz = Math.hypot(me[8], me[9], me[10]);
      const tilt = Math.abs(me[5] / sy) < 0.9999;
      const cat = n.userData.cat ?? 1;
      if (n.userData.voxBoxes) {
        const ny = yawOf(me);
        const k = i => i < keys.length ? keys[i] : "?";
        for (const b of n.userData.voxBoxes) {
          const c = new THREE.Vector3(b.c[0], b.c[1], b.c[2]).applyMatrix4(n.matrixWorld);
          const d = { c: V3(c), s: V3([b.s[0] * sx, b.s[1] * sy, b.s[2] * sz]), yaw: R(ny + b.yaw), m: k(b.side), p, h, o: R(o, 1000), uv: b.uv };
          if (b.top !== b.side) d.mt = k(b.top);
          if (b.bottom !== b.side) d.mb = k(b.bottom);
          if (n.userData.ao !== null && n.userData.ao !== undefined) d.ao = R(n.userData.ao);
          if (tilt) d.tilt = true;
          if (cat !== 1) d.cat = cat;
          out.boxes.push(d);
        }
      } else {
        const [type, params] = geomDesc(n.geometry, n);
        const d = { type, pos: V3(new THREE.Vector3().setFromMatrixPosition(n.matrixWorld)), yaw: R(yawOf(me)), scale: V3([sx, sy, sz]),
                    m: keys, p, h, o: R(o, 1000), cat, params };
        if (tilt) { d.tilt = true; d.up = V3(new THREE.Vector3(me[4], me[5], me[6]).normalize()); }
        out.geoms.push(d);
      }
    }
    for (const c of n.children) walk(c, p, h, o, false);
  };
  walk(root, "", false, 1, true);
  return out;
}

/** 目前被藏起來的節點路徑（cutaway 跟鏡頭走；跟 Mac camera dump 的 hidden 一樣） */
export function hiddenPaths(root) {
  const out = [];
  const scan = (n, path, isRoot) => {
    const p = !isRoot && n.name ? (path ? path + "/" + n.name : n.name) : path;
    if (!n.visible) { out.push(p); return; }
    for (const c of n.children) scan(c, p, false);
  };
  scan(root, "", true);
  return out.sort();
}
export { R as round4, V3 as vec3r, HEX as hexOf };
