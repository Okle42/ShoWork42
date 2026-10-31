// ShoWork42 Windows 戰情中心：3D 辦公大樓（W6）。Mac 版 OfficeView／OfficeBuilder／OfficeTower（SceneKit）的 three.js 版，
// 照它的外觀與行為做，不是逐行翻譯。尺寸、色票、桌位（freeDesks）、角色（方塊 Kubo）比例照 Mac 的數字。
//   科技大樓剖面：一樓大廳＋前台 → 閒置薄層（門牌）→ 有 AI 的專案一層一樓（固定樓層號）→ 頂樓空中花園。
//   每層桌子＝實際 AI 數；角色顏色／動作反映狀態；面向鏡頭的牆淡掉（cutaway）。
// 省電（Surface i5-8250U 內顯）：靜態東西每層依材質合併成一個 mesh；牆四面全樓各合併成一個；陰影只算一次（資料或燈光變了才重算）；
//   沒動畫時不渲染（拖鏡頭才畫），有人在打字／等你時 12 fps；視窗看不到（WebView2 隱藏）時瀏覽器自己停掉 requestAnimationFrame。
// 資料：WebView2 的 PostWebMessageAsJson（Board\Office.cs 的 OfficeSnapshot）。點角色 → postMessage({type:"select", id}) 給 WinForms。
// 沒有 WebView2（瀏覽器開 ?demo=1）就用 demo-data.js 的假資料，點角色在頁面左下角顯示細節。

import * as THREE from "three";
import { OrbitControls } from "./vendor/three-r170/OrbitControls.js";

// MARK: 尺寸與色票（Mac TowerSpec／TD／TP）

const W = 12, D = 9.8, ZF = 2.8, ZB = ZF - D, ZC = (ZF + ZB) / 2, SLAB = 0.25, ROOM = SLAB + 0.01, BACKZ = ZB + 0.15;
const HEIGHT = { lobby: 4.4, project: 2.9, idle: 0.9, roof: 2.4 };
const SEAT_TOP = 0.56, KUBO = 1.6, CHAIR_BACK = 0.72;
const TP = {
  FL1: 0xCDBFA8, FL2: 0xBDBAB3, WL1: 0xEEEBE5, WL2: 0xE3DFD8, ST1: 0x2F3338, ST2: 0xA7A49E, ELEV: 0x5CE1FF, GL1: 0xB9D3D8,
  NE1: 0x8FE3EE, NE2: 0xFF5A5F, LT1: 0xFFD8A6, FN1: 0x8A6A4F, FN2: 0xC2A27F, FN3: 0x2B2C2F, FN4: 0x8F8B85, FN5: 0xF3F1EC,
  FN6: 0x1E2024, PL1: 0x5C7F55, PL2: 0x7C9A6A, POT: 0xD9D4CB, SOIL: 0x5A4A3A, CITYWIN: 0xE8C98F,
};
const SKY = { day: 0xD3DCE2, night: 0x141B26 }, GROUND = { day: 0xA4ABB0, night: 0x0D1218 };
// 狀態色＝光暈配色（C# 會帶使用者設定的顏色進來，沒有就用預設）
const MOOD_DEFAULT = { working: "#9E66FF", waiting: "#FF4040", finished: "#30D158", stuck: "#FF9F0A", idle: "#E5E5EA", asleep: "#8E8E93" };
const MOOD_TEXT = { working: "工作中", waiting: "等你回答", finished: "做完了", stuck: "卡住", idle: "休息", asleep: "睡覺" };

// 自由座（Mac TowerLayout.freeDesks）：桌心 x、z、人面向 a（0＝面向鏡頭 +z、π＝背對、±π/2＝面向右／左牆）
const FREE_DESKS = [
  [-0.7, -0.3, 0], [-1.5, -4.3, 0], [2.6, -2.6, Math.PI / 2], [-4.4, -4.6, -Math.PI / 2],
  [-0.7, 0.4, Math.PI], [-1.5, -3.6, Math.PI], [0.9, -0.3, 0], [0.1, -4.3, 0],
  [2.6, -4.4, Math.PI / 2], [-4.4, -3.0, -Math.PI / 2], [0.9, 0.4, Math.PI], [0.1, -3.6, Math.PI],
];

/** FNV-1a 64 位元（同 Mac：樓層從哪一區開始坐、桌面小物挑哪幾件） */
function fnv64(s) {
  let h = 0xcbf29ce484222325n;
  for (const b of new TextEncoder().encode(s)) { h ^= BigInt(b); h = (h * 0x100000001b3n) & 0xffffffffffffffffn; }
  return h;
}
const spin = id => (id ? Number(fnv64(id) % 4n) : 0);
function desk(i, floorId) {
  const k = spin(floorId), j = Math.min(Math.max(i, 0), FREE_DESKS.length - 1);
  const [x, z, a] = FREE_DESKS[Math.floor(j / 4) * 4 + ((j % 4) + k) % 4];
  return { x, z, a };
}
function seat(i, n, floorId) {
  if (i >= 12) { const k = i - 12, m = n - 12; return { x: 0.1 + (k - (m - 1) / 2) * 1.0, z: 2.2, a: 0, standing: true }; }
  const d = desk(i, floorId);
  return { x: d.x - CHAIR_BACK * Math.sin(d.a), z: d.z - CHAIR_BACK * Math.cos(d.a), a: d.a, standing: false };
}

// MARK: 方塊合併器：一堆方塊 → 一個 BufferGeometry（頂點色），一種材質一個 draw call

const FACES = [
  [[1, 0, 0], [[1, -1, -1], [1, 1, -1], [1, 1, 1], [1, -1, 1]]],
  [[-1, 0, 0], [[-1, -1, 1], [-1, 1, 1], [-1, 1, -1], [-1, -1, -1]]],
  [[0, 1, 0], [[-1, 1, 1], [1, 1, 1], [1, 1, -1], [-1, 1, -1]]],
  [[0, -1, 0], [[-1, -1, -1], [1, -1, -1], [1, -1, 1], [-1, -1, 1]]],
  [[0, 0, 1], [[-1, -1, 1], [1, -1, 1], [1, 1, 1], [-1, 1, 1]]],
  [[0, 0, -1], [[1, -1, -1], [-1, -1, -1], [-1, 1, -1], [1, 1, -1]]],
];
const _col = new THREE.Color();
class Vox {
  constructor() { this.p = []; this.n = []; this.c = []; }
  get empty() { return this.p.length === 0; }
  /** 方塊：x、z＝中心，y0＝底，w×h×d；xf＝{x,y,z,a} 先繞 Y 轉 a 再平移（家具、桌子用） */
  box(x, y0, z, w, h, d, color, xf) {
    _col.setHex(color);
    const cx = x, cy = y0 + h / 2, cz = z, hw = w / 2, hh = h / 2, hd = d / 2;
    const a = xf ? xf.a || 0 : 0, ca = Math.cos(a), sa = Math.sin(a);
    const ox = xf ? xf.x || 0 : 0, oy = xf ? xf.y || 0 : 0, oz = xf ? xf.z || 0 : 0;
    for (const [nm, cs] of FACES) {
      const nx = nm[0] * ca + nm[2] * sa, nz = -nm[0] * sa + nm[2] * ca;
      const pts = cs.map(([sx, sy, sz]) => {
        const lx = cx + sx * hw, ly = cy + sy * hh, lz = cz + sz * hd;
        return [ox + lx * ca + lz * sa, oy + ly, oz - lx * sa + lz * ca];
      });
      for (const k of [0, 1, 2, 0, 2, 3]) {
        this.p.push(...pts[k]); this.n.push(nx, nm[1], nz); this.c.push(_col.r, _col.g, _col.b);
      }
    }
  }
  geometry() {
    const g = new THREE.BufferGeometry();
    g.setAttribute("position", new THREE.Float32BufferAttribute(this.p, 3));
    g.setAttribute("normal", new THREE.Float32BufferAttribute(this.n, 3));
    g.setAttribute("color", new THREE.Float32BufferAttribute(this.c, 3));
    g.computeBoundingSphere();
    return g;
  }
  mesh(mat, shadow = false) {
    const m = new THREE.Mesh(this.geometry(), mat);
    m.castShadow = m.receiveShadow = shadow;
    return m;
  }
}

// MARK: 材質（全場共用；白天／夜晚只改強度，不重建）

const M = {
  solid: new THREE.MeshLambertMaterial({ vertexColors: true }),
  glow: new THREE.MeshBasicMaterial({ vertexColors: true }),
  glass: new THREE.MeshLambertMaterial({ vertexColors: true, transparent: true, opacity: 0.16, depthWrite: false }),
  city: new THREE.MeshLambertMaterial({ vertexColors: true }),
  cityWin: new THREE.MeshBasicMaterial({ vertexColors: true }),
  ground: new THREE.MeshLambertMaterial({ color: GROUND.day }),
  // 會被 cutaway 淡掉的三面牆（全樓各一個）
  back: new THREE.MeshLambertMaterial({ vertexColors: true }),
  left: new THREE.MeshLambertMaterial({ vertexColors: true }),
  right: new THREE.MeshLambertMaterial({ vertexColors: true }),
};
const FACADES = [
  { key: "back", n: [0, -1] }, { key: "left", n: [-1, 0] }, { key: "right", n: [1, 0] },
];

// MARK: 家具零件（本地座標：原點＝靠牆那一面的底部中心，正面朝 +z；xf 放到牆邊）

const P = {
  shelf(v, g, xf, ac, w = 2.4, h = 2.0, books = true) {
    const d = 0.4;
    v.box(0, 0, d / 2, w, 0.05, d, TP.FN1, xf);
    for (const x of [-w / 2 + 0.03, w / 2 - 0.03]) v.box(x, 0, d / 2, 0.05, h, d, TP.FN1, xf);
    v.box(0, 0, 0.02, w, h, 0.03, TP.FN1, xf);
    const rows = Math.floor(h / 0.45), cols = [ac, 0x5B6F8C, 0xB8A27A, 0x7E5A4A, 0xD9D4CB, 0x3E5E4E];
    for (let r = 0; r < rows; r++) {
      const y = 0.05 + r * 0.45;
      v.box(0, y + 0.4, d / 2, w, 0.04, d, TP.FN1, xf);
      if (!books) continue;
      let x = -w / 2 + 0.12, i = r * 3;
      while (x < w / 2 - 0.2) {
        const bw = 0.07 + ((i * 37) % 5) * 0.015, bh = 0.24 + ((i * 13) % 4) * 0.035;
        v.box(x + bw / 2, y, d / 2, bw, bh, 0.26, cols[i % cols.length], xf);
        x += bw + 0.012; i++;
      }
    }
  },
  console(v, g, xf, ac) {
    v.box(0, 0, 0.5, 2.6, 0.74, 0.8, TP.FN3, xf);
    v.box(0, 0.74, 0.5, 2.7, 0.05, 0.85, ac, xf);
    for (const x of [-0.85, 0, 0.85]) { v.box(x, 0.8, 0.25, 0.78, 0.48, 0.05, TP.FN6, xf); g.box(x, 0.84, 0.28, 0.7, 0.4, 0.01, x === 0 ? 0x6FE3A0 : 0x7FB5FF, xf); }
    g.box(0, 1.55, 0.03, 2.2, 0.5, 0.02, 0x2E6E9E, xf);
  },
  serverRack(v, g, xf, ac) {
    for (const x of [-0.42, 0.42]) {
      v.box(x, 0, 0.45, 0.78, 2.0, 0.85, TP.FN6, xf);
      for (let r = 0; r < 9; r++) g.box(x - 0.2, 0.2 + r * 0.19, 0.88, 0.22, 0.03, 0.01, r % 3 === 0 ? ac : 0x5CE1FF, xf);
    }
  },
  whiteboard(v, g, xf, ac) {
    for (const x of [-0.85, 0.85]) v.box(x, 0, 0.35, 0.05, 1.9, 0.05, TP.ST1, xf);
    v.box(0, 0.85, 0.35, 1.9, 1.05, 0.04, TP.FN5, xf);
    for (let i = 0; i < 4; i++) v.box(-0.35 + (i % 2) * 0.5, 1.2 + i * 0.15, 0.38, 0.6 - i * 0.08, 0.03, 0.01, i % 2 ? 0x3A6EA5 : ac, xf);
    v.box(0, 0.83, 0.42, 1.4, 0.03, 0.08, TP.FN4, xf);
  },
  standingDesk(v, g, xf, ac) {
    v.box(0, 1.02, 0.45, 1.3, 0.05, 0.7, TP.FN2, xf);
    for (const x of [-0.55, 0.55]) v.box(x, 0, 0.45, 0.08, 1.02, 0.08, TP.ST1, xf);
    v.box(0, 1.07, 0.3, 0.6, 0.4, 0.04, TP.FN6, xf); g.box(0, 1.1, 0.33, 0.54, 0.34, 0.01, 0x7FB5FF, xf);
    v.box(0.45, 1.07, 0.55, 0.16, 0.3, 0.02, ac, xf);
  },
  floorLamp(v, g, xf) {
    v.box(0, 0, 0.4, 0.3, 0.04, 0.3, TP.FN3, xf); v.box(0, 0, 0.4, 0.04, 1.5, 0.04, TP.FN3, xf); g.box(0, 1.45, 0.4, 0.36, 0.3, 0.36, TP.LT1, xf);
  },
  globe(v, g, xf, ac) {
    v.box(0, 0, 0.4, 0.4, 0.06, 0.4, TP.FN1, xf); v.box(0, 0, 0.4, 0.05, 0.75, 0.05, TP.FN1, xf);
    v.box(0, 0.75, 0.4, 0.42, 0.42, 0.42, 0x3A7CA5, xf); v.box(0.05, 0.86, 0.4, 0.44, 0.2, 0.3, ac, xf);
  },
  workbench(v, g, xf, ac) {
    v.box(0, 0.78, 0.45, 2.4, 0.06, 0.8, TP.FN1, xf);
    for (const x of [-1.1, 1.1]) for (const z of [0.12, 0.8]) v.box(x, 0, z, 0.06, 0.78, 0.06, TP.FN3, xf);
    for (const x of [-0.6, 0.6]) {
      v.box(x, 0.84, 0.45, 0.62, 0.62, 0.6, TP.FN6, xf);
      g.box(x, 0.9, 0.76, 0.5, 0.45, 0.01, 0xFFB86B, xf);
      v.box(x, 0.84, 0.45, 0.66, 0.06, 0.64, ac, xf);
    }
  },
  filamentRack(v, g, xf) {
    P.shelf(v, g, xf, 0xC98B3C, 1.4, 1.6, false);
    const cols = [0xE05A47, 0x4E9C8F, 0xF2C14E, 0x2F3338, 0xF3F1EC, 0x5B8DB8];
    for (let r = 0; r < 3; r++) for (let i = 0; i < 4; i++) v.box(-0.48 + i * 0.32, 0.1 + r * 0.45, 0.2, 0.24, 0.24, 0.12, cols[(r * 4 + i) % cols.length], xf);
  },
  sofa(v, g, xf, ac) {
    v.box(0, 0, 0.45, 2.0, 0.42, 0.85, ac, xf);
    v.box(0, 0.42, 0.12, 2.0, 0.45, 0.22, ac, xf);
    for (const x of [-0.92, 0.92]) v.box(x, 0.42, 0.45, 0.16, 0.22, 0.85, ac, xf);
    for (const x of [-0.5, 0.5]) v.box(x, 0.42, 0.5, 0.86, 0.1, 0.6, 0xE9E3D8, xf);
    v.box(0, 0, 1.3, 0.8, 0.38, 0.5, TP.FN2, xf);
  },
  switchboard(v, g, xf, ac) {
    v.box(0, 0, 0.3, 2.2, 0.75, 0.55, TP.FN3, xf); v.box(0, 0.75, 0.3, 2.3, 0.04, 0.6, ac, xf);
    v.box(0, 0.8, 0.04, 2.1, 1.1, 0.05, TP.FN6, xf);
    for (let r = 0; r < 4; r++) for (let i = 0; i < 9; i++) g.box(-0.9 + i * 0.225, 0.95 + r * 0.24, 0.07, 0.08, 0.08, 0.01, (r + i) % 4 ? 0x6FE3A0 : 0xFF6B6B, xf);
    v.box(0.7, 0.79, 0.4, 0.3, 0.08, 0.2, TP.FN6, xf);
  },
  quadMonitor(v, g, xf, ac) {
    v.box(0, 0.72, 0.45, 2.4, 0.05, 0.8, TP.FN2, xf);
    for (const x of [-1.1, 1.1]) v.box(x, 0, 0.45, 0.06, 0.72, 0.7, TP.FN3, xf);
    for (const x of [-0.4, 0.4]) for (const y of [0.85, 1.28]) {
      v.box(x, y, 0.25, 0.76, 0.42, 0.04, TP.FN6, xf);
      g.box(x, y + 0.03, 0.28, 0.7, 0.36, 0.01, (x > 0) === (y > 1) ? 0x3FBF6A : 0xE0524B, xf);
    }
    v.box(0, 0.77, 0.3, 0.06, 0.1, 0.06, ac, xf);
  },
  bull(v, g, xf, ac) {
    v.box(0, 0, 0.45, 0.8, 0.5, 0.6, TP.ST1, xf);
    v.box(0, 0.5, 0.45, 0.7, 0.32, 0.32, ac, xf);
    v.box(0, 0.62, 0.68, 0.24, 0.24, 0.22, ac, xf);
    for (const x of [-0.16, 0.16]) v.box(x, 0.84, 0.7, 0.06, 0.12, 0.06, 0xE8D9B0, xf);
  },
  editBay(v, g, xf, ac) {
    v.box(0, 0.72, 0.45, 2.2, 0.05, 0.8, TP.FN3, xf);
    for (const x of [-1.0, 1.0]) v.box(x, 0, 0.45, 0.06, 0.72, 0.7, TP.FN3, xf);
    v.box(0, 0.8, 0.22, 1.5, 0.62, 0.05, TP.FN6, xf); g.box(0, 0.84, 0.25, 1.42, 0.54, 0.01, 0x8E6FD8, xf);
    for (let i = 0; i < 6; i++) g.box(-0.6 + i * 0.24, 0.86, 0.26, 0.18, 0.08, 0.01, i % 2 ? ac : 0xF2C14E, xf);
  },
  softbox(v, g, xf, ac) {
    for (const x of [-0.25, 0.25]) v.box(x, 0, 0.5, 0.04, 0.2, 0.5, TP.ST1, xf);
    v.box(0, 0, 0.5, 0.05, 1.6, 0.05, TP.ST1, xf);
    v.box(0, 1.5, 0.45, 0.8, 0.8, 0.3, TP.FN6, xf); g.box(0, 1.55, 0.61, 0.7, 0.7, 0.02, 0xFFF4E0, xf);
    v.box(0, 1.45, 0.45, 0.85, 0.05, 0.35, ac, xf);
  },
  cameraTripod(v, g, xf, ac) {
    for (const [x, z] of [[-0.25, 0.3], [0.25, 0.3], [0, 0.75]]) v.box(x, 0, z, 0.04, 1.2, 0.04, TP.ST1, xf);
    v.box(0, 1.2, 0.45, 0.4, 0.28, 0.3, TP.FN6, xf); v.box(0, 1.25, 0.66, 0.14, 0.14, 0.16, ac, xf);
  },
  draftingTable(v, g, xf, ac) {
    for (const x of [-0.6, 0.6]) v.box(x, 0, 0.5, 0.06, 0.9, 0.06, TP.FN3, xf);
    for (let i = 0; i < 4; i++) v.box(0, 0.9 + i * 0.07, 0.75 - i * 0.18, 1.4, 0.07, 0.2, TP.FN5, xf);
    v.box(0.2, 1.0, 0.5, 0.5, 0.02, 0.35, ac, xf);
  },
  easel(v, g, xf, ac) {
    for (const x of [-0.3, 0.3]) v.box(x, 0, 0.5, 0.05, 1.7, 0.05, TP.FN1, xf);
    v.box(0, 0, 0.3, 0.05, 1.6, 0.05, TP.FN1, xf);
    v.box(0, 0.7, 0.55, 0.8, 0.04, 0.1, TP.FN1, xf);
    v.box(0, 0.74, 0.55, 0.75, 0.85, 0.03, TP.FN5, xf); v.box(-0.1, 0.95, 0.57, 0.4, 0.4, 0.01, ac, xf);
  },
  fileCabinet(v, g, xf, ac) {
    for (const x of [-0.5, 0, 0.5]) {
      v.box(x, 0, 0.32, 0.46, 1.32, 0.62, x === 0 ? ac : TP.FN4, xf);
      for (let r = 0; r < 4; r++) v.box(x, 0.18 + r * 0.32, 0.64, 0.16, 0.03, 0.02, TP.FN6, xf);
    }
  },
  wallClock(v, g, xf, ac) {
    v.box(0, 1.9, 0.03, 0.5, 0.5, 0.05, ac, xf); g.box(0, 1.95, 0.06, 0.4, 0.4, 0.01, TP.FN5, xf);
    v.box(0, 2.13, 0.07, 0.03, 0.16, 0.01, TP.FN6, xf); v.box(0.06, 2.13, 0.07, 0.12, 0.03, 0.01, TP.FN6, xf);
  },
  cashierCounter(v, g, xf, ac) {
    v.box(0, 0, 0.4, 2.2, 1.0, 0.7, TP.FN2, xf); v.box(0, 0.4, 0.76, 2.2, 0.08, 0.02, ac, xf);
    v.box(0, 1.0, 0.4, 2.3, 0.05, 0.8, TP.FN5, xf);
    v.box(-0.6, 1.05, 0.3, 0.4, 0.3, 0.3, TP.FN6, xf); g.box(-0.6, 1.2, 0.46, 0.3, 0.12, 0.01, 0x6FE3A0, xf);
    for (let i = 0; i < 3; i++) v.box(0.3 + i * 0.25, 1.05, 0.4, 0.2, 0.05 + i * 0.04, 0.28, TP.FN5, xf);
    P.wallClock(v, g, xf, ac);
  },
  arcade(v, g, xf, ac) {
    for (const x of [-0.5, 0.5]) {
      v.box(x, 0, 0.4, 0.7, 1.75, 0.7, x < 0 ? ac : TP.FN6, xf);
      g.box(x, 1.0, 0.76, 0.56, 0.45, 0.01, x < 0 ? 0x7FE0FF : 0xFF7FD0, xf);
      v.box(x, 0.8, 0.8, 0.6, 0.06, 0.2, TP.FN3, xf);
    }
  },
  trophyShelf(v, g, xf, ac) {
    P.shelf(v, g, xf, ac, 1.2, 1.4, false);
    for (let r = 0; r < 3; r++) for (const x of [-0.3, 0.05, 0.35]) v.box(x, 0.1 + r * 0.45, 0.2, 0.14, 0.2, 0.14, 0xF2C14E, xf);
  },
  partsWall(v, g, xf, ac) {
    v.box(0, 0.8, 0.03, 2.4, 1.3, 0.04, 0xB8A27A, xf);
    for (let r = 0; r < 4; r++) for (let i = 0; i < 8; i++) if ((r * 8 + i) % 3) v.box(-1.0 + i * 0.28, 0.95 + r * 0.3, 0.07, 0.1 + (i % 2) * 0.08, 0.16, 0.04, [ac, TP.FN3, 0x5B8DB8, TP.FN4][(r + i) % 4], xf);
    v.box(0, 0.75, 0.45, 2.4, 0.05, 0.8, TP.FN1, xf);
    for (const x of [-1.1, 1.1]) v.box(x, 0, 0.45, 0.06, 0.75, 0.7, TP.FN3, xf);
  },
  soldering(v, g, xf, ac) {
    v.box(0, 0.75, 0.45, 1.6, 0.05, 0.8, TP.FN3, xf);
    for (const x of [-0.72, 0.72]) v.box(x, 0, 0.45, 0.06, 0.75, 0.7, TP.FN3, xf);
    v.box(-0.4, 0.8, 0.4, 0.4, 0.2, 0.3, ac, xf); g.box(-0.4, 0.86, 0.56, 0.2, 0.06, 0.01, 0xFF6B3D, xf);
    v.box(0.3, 0.8, 0.45, 0.5, 0.02, 0.4, 0x2E7D4F, xf);
    g.box(0.5, 1.0, 0.2, 0.14, 0.14, 0.14, TP.LT1, xf); v.box(0.5, 0.8, 0.2, 0.03, 0.2, 0.03, TP.FN3, xf);
  },
  ringLight(v, g, xf, ac) {
    v.box(0, 0, 0.5, 0.05, 1.5, 0.05, TP.ST1, xf); v.box(0, 0, 0.5, 0.4, 0.03, 0.4, TP.ST1, xf);
    for (const [x, y, w, h] of [[0, 1.85, 0.6, 0.07], [0, 1.25, 0.6, 0.07], [-0.27, 1.32, 0.07, 0.53], [0.27, 1.32, 0.07, 0.53]]) g.box(x, y, 0.5, w, h, 0.07, 0xFFF4E0, xf);
    v.box(0, 1.5, 0.52, 0.12, 0.2, 0.02, ac, xf);
  },
  productTable(v, g, xf, ac) {
    v.box(0, 0.72, 0.5, 2.0, 0.05, 0.9, TP.FN5, xf);
    for (const x of [-0.9, 0.9]) v.box(x, 0, 0.5, 0.06, 0.72, 0.8, TP.FN3, xf);
    const cols = [ac, 0xF2C14E, 0x4E9C8F, 0xE9E3D8];
    for (let i = 0; i < 4; i++) v.box(-0.65 + i * 0.43, 0.77, 0.5, 0.26, 0.18 + (i % 2) * 0.16, 0.26, cols[i], xf);
    v.box(0, 1.0, 0.03, 1.8, 0.9, 0.03, ac, xf);
  },
  flightBoard(v, g, xf, ac) {
    v.box(0, 0.95, 0.04, 2.6, 1.15, 0.06, TP.FN6, xf); v.box(0, 2.1, 0.04, 2.6, 0.08, 0.07, ac, xf);
    for (let r = 0; r < 6; r++) for (let i = 0; i < 5; i++) g.box(-1.05 + i * 0.52, 1.05 + r * 0.17, 0.08, 0.44, 0.09, 0.01, i === 4 ? (r % 3 ? 0x6FE3A0 : 0xFF6B6B) : TP.CITYWIN, xf);
    v.box(0, 0, 0.45, 2.2, 0.74, 0.7, TP.FN3, xf); v.box(0, 0.74, 0.45, 2.3, 0.04, 0.75, TP.FN5, xf);
  },
  keyCabinet(v, g, xf, ac) {
    v.box(0, 1.0, 0.08, 0.9, 0.8, 0.14, ac, xf);
    for (let r = 0; r < 3; r++) for (let i = 0; i < 5; i++) v.box(-0.32 + i * 0.16, 1.12 + r * 0.22, 0.16, 0.05, 0.1, 0.02, 0xE8D9B0, xf);
    v.box(0, 0, 0.3, 0.9, 0.85, 0.55, TP.FN4, xf);
  },
  planChest(v, g, xf, ac) {
    v.box(0, 0, 0.5, 2.2, 0.9, 0.95, TP.FN4, xf);
    for (let r = 0; r < 5; r++) v.box(0, 0.1 + r * 0.16, 0.98, 0.3, 0.03, 0.02, TP.FN6, xf);
    v.box(0, 0.9, 0.5, 2.3, 0.04, 1.0, ac, xf);
    v.box(-0.3, 0.94, 0.5, 1.0, 0.02, 0.7, TP.FN5, xf); v.box(-0.3, 0.96, 0.5, 0.7, 0.01, 0.02, 0x3A6EA5, xf);
  },
  modelPlinth(v, g, xf, ac) {
    v.box(0, 0, 0.5, 1.0, 0.85, 0.8, TP.FN5, xf);
    v.box(-0.2, 0.85, 0.45, 0.3, 0.5, 0.3, TP.FN5, xf); v.box(0.15, 0.85, 0.55, 0.3, 0.3, 0.4, ac, xf); v.box(0.15, 0.85, 0.3, 0.2, 0.7, 0.2, 0xD9D4CB, xf);
  },
  coffeeCart(v, g, xf, ac) {
    v.box(0, 0.15, 0.4, 1.0, 0.75, 0.6, TP.FN1, xf); v.box(0, 0.9, 0.4, 1.05, 0.04, 0.65, TP.FN5, xf);
    for (const x of [-0.42, 0.42]) v.box(x, 0, 0.4, 0.15, 0.15, 0.55, TP.FN3, xf);
    v.box(-0.2, 0.94, 0.35, 0.35, 0.42, 0.32, TP.FN3, xf); g.box(-0.2, 1.2, 0.52, 0.12, 0.06, 0.01, ac, xf);
    for (const x of [0.15, 0.3]) v.box(x, 0.94, 0.45, 0.09, 0.11, 0.09, TP.FN5, xf);
  },
  plantTall(v, g, xf) {
    v.box(0, 0, 0.35, 0.45, 0.45, 0.45, TP.POT, xf); v.box(0, 0.45, 0.35, 0.08, 0.6, 0.08, TP.FN1, xf);
    v.box(0, 1.0, 0.35, 0.75, 0.6, 0.75, TP.PL1, xf); v.box(0.05, 1.5, 0.3, 0.5, 0.45, 0.5, TP.PL2, xf);
  },
  plantLow(v, g, xf) {
    v.box(0, 0, 0.3, 0.55, 0.35, 0.4, TP.POT, xf); v.box(0, 0.35, 0.3, 0.62, 0.35, 0.48, TP.PL2, xf); v.box(0.1, 0.62, 0.28, 0.3, 0.2, 0.3, TP.PL1, xf);
  },
};

// 主題 → 三件擺設：後牆（★ 識別色）、右牆、左前角（Mac TowerProps 的精簡版）
const THEME_PROPS = {
  monitor: ["console", "serverRack", "plantTall"],
  app_studio: ["whiteboard", "standingDesk", "plantLow"],
  library: ["shelf", "floorLamp", "globe"],
  print_shop: ["workbench", "filamentRack", "plantLow"],
  call_room: ["switchboard", "sofa", "plantTall"],
  trading_desk: ["quadMonitor", "bull", "plantLow"],
  media_studio: ["editBay", "softbox", "cameraTripod"],
  design_studio: ["shelf", "draftingTable", "easel"],
  legal_room: ["shelf", "fileCabinet", "plantTall"],
  ledger_room: ["cashierCounter", "fileCabinet", "plantLow"],
  game_lab: ["arcade", "sofa", "trophyShelf"],
  hw_lab: ["partsWall", "soldering", "plantLow"],
  marketing: ["productTable", "sofa", "ringLight"],
  dispatch_room: ["flightBoard", "keyCabinet", "plantTall"],
  drafting_room: ["planChest", "modelPlinth", "plantLow"],
  general: ["whiteboard", "coffeeCart", "plantTall"],
};

// MARK: 樓層模組

const hex = s => (typeof s === "string" && /^#[0-9a-f]{6}$/i.test(s) ? parseInt(s.slice(1), 16) : TP.FN4);

/** 牆：沿著牆排方塊，gaps＝門洞（沿牆方向的區間、門高） */
function wall(v, side, y0, h, color, gaps = []) {
  const t = 0.15;
  let cuts = side === "back" ? [[-W / 2, W / 2]] : [[ZB, ZF]];
  for (const [g0, g1] of gaps) cuts = cuts.flatMap(([a, b]) => (g1 <= a || g0 >= b ? [[a, b]] : [[a, g0], [g1, b]].filter(([p, q]) => q - p > 0.01)));
  const put = (a, b, y, hh) => {
    const c = (a + b) / 2, l = b - a;
    if (side === "back") v.box(c, y, ZB + t / 2, l, hh, t, color);
    else if (side === "left") v.box(-W / 2 + t / 2, y, c, t, hh, l, color);
    else v.box(W / 2 - t / 2, y, c, t, hh, l, color);
  };
  for (const [a, b] of cuts) put(a, b, y0, h);
  for (const [g0, g1, gh] of gaps) if (gh < h) put(g0, g1, y0 + gh, h - gh);
}

/** 樓板＋地坪＋前緣霓虹＋後側轉角細框 */
function shell(B, y, floorColor, h, neon = true) {
  B.solid.box(0, y, ZC, W, SLAB, D, TP.ST2);
  B.solid.box(0, y + SLAB, ZC, W - 0.02, 0.01, D - 0.02, floorColor);
  if (neon) B.glow.box(0, y + SLAB - 0.03, ZF + 0.015, W, 0.025, 0.025, TP.NE1);
  for (const x of [-W / 2, W / 2]) B.solid.box(x, y + ROOM, ZB + 0.03, 0.05, h, 0.05, TP.ST1);
}

/** 正面玻璃＋直框（每 2 公尺一支）；door＝門洞 [x0, x1, 門高] */
function glassFront(B, y0, h, door) {
  if (door) {
    const [x0, x1, dh] = door, L = W / 2;
    B.glass.box((-L + x0) / 2, y0, ZF - 0.02, x0 + L, h, 0.02, TP.GL1);
    B.glass.box((x1 + L) / 2, y0, ZF - 0.02, L - x1, h, 0.02, TP.GL1);
    B.glass.box((x0 + x1) / 2, y0 + dh, ZF - 0.02, x1 - x0, h - dh, 0.02, TP.GL1);
  } else B.glass.box(0, y0, ZF - 0.02, W, h, 0.02, TP.GL1);
  for (let i = 0; i <= 6; i++) B.solid.box(-6 + i * 2, y0, ZF - 0.03, 0.05, h, 0.05, TP.ST1);
}

/** 線性吊燈（離天花 0.45）；off＝這層沒人，燈不亮 */
function pendant(B, y, x, z, len, ceil, off) {
  const drop = 0.45;
  for (const dx of [-len / 2 + 0.3, len / 2 - 0.3]) B.solid.box(x + dx, y + ceil - drop + 0.06, z, 0.02, drop - 0.06, 0.02, TP.FN3);
  B.solid.box(x, y + ceil - drop, z, len, 0.06, 0.12, TP.FN3);
  (off ? B.solid : B.glow).box(x, y + ceil - drop - 0.02, z, len - 0.1, 0.02, 0.08, off ? TP.FN5 : TP.LT1);
}

/** 一張座位：桌面 1.4×0.7 頂高 0.75、螢幕朝人（本地 +z）、椅子在桌子後方 */
function deskSet(B, y, d, lit, seed) {
  const xf = { x: d.x, y: y + ROOM, z: d.z, a: d.a }, v = B.solid;
  v.box(0, 0.70, 0, 1.4, 0.05, 0.7, TP.FN2, xf);
  for (const [dx, dz] of [[-0.64, -0.3], [0.64, -0.3], [-0.64, 0.3], [0.64, 0.3]]) v.box(dx, 0, dz, 0.05, 0.7, 0.05, TP.FN3, xf);
  v.box(0, 0.76, 0.2, 0.62, 0.38, 0.04, TP.FN6, xf);
  v.box(0, 0.75, 0.24, 0.12, 0.05, 0.12, TP.FN6, xf);
  (lit ? B.glow : v).box(0, 0.79, 0.175, 0.56, 0.32, 0.01, lit ? 0x8FB8FF : 0x2A2C30, xf);
  const cz = -CHAIR_BACK;
  v.box(0, SEAT_TOP - 0.08, cz, 0.55, 0.08, 0.55, TP.FN4, xf);
  v.box(0, 0, cz, 0.06, SEAT_TOP - 0.08, 0.06, TP.FN3, xf);
  v.box(0, SEAT_TOP, cz - 0.3, 0.55, 0.55, 0.06, TP.FN4, xf);
  // 桌面小物（Mac deskItems：依「專案名＋桌號」挑 2 件）
  const h = fnv64(seed), top = { x: d.x, y: y + ROOM + 0.75, z: d.z, a: d.a };
  for (let i = 0; i < 2; i++) {
    const kind = Number((h >> BigInt(8 + i * 5)) % 6n), sx = i === 0 ? -0.48 : 0.48, cz2 = -0.08;
    switch (kind) {
      case 0: v.box(sx, 0, cz2, 0.09, 0.11, 0.09, TP.FN5, top); break;
      case 1: v.box(sx, 0, cz2, 0.3, 0.06, 0.22, TP.FN5, top); v.box(sx + 0.02, 0.06, cz2, 0.28, 0.02, 0.2, TP.FN4, top); break;
      case 2: v.box(sx, 0, cz2, 0.14, 0.12, 0.14, TP.POT, top); v.box(sx, 0.12, cz2, 0.16, 0.14, 0.16, TP.PL2, top); break;
      case 3: v.box(sx, 0, cz2, 0.12, 0.03, 0.12, TP.FN3, top); v.box(sx, 0.03, cz2, 0.03, 0.35, 0.03, TP.FN3, top); B.glow.box(sx, 0.36, cz2 + 0.04, 0.14, 0.08, 0.14, TP.LT1, top); break;
      case 4: v.box(sx, 0, cz2, 0.16, 0.06, 0.1, TP.FN3, top); break;
      default: v.box(sx, 0, 0.18, 0.1, 0.12, 0.1, TP.FN3, top); v.box(sx, 0.1, 0.2, 0.22, 0.36, 0.03, TP.FN6, top);
    }
  }
}

function projectFloor(B, f, y) {
  const h = HEIGHT.project - SLAB, accent = hex(f.accent);
  shell(B, y, TP.FL1, h);
  wall(B.back, "back", y + ROOM, h, TP.WL1);
  B.back.box(-3.8, y + ROOM, BACKZ + 0.012, 3.0, h, 0.02, accent);       // 後牆協作區刷識別色（遮掉門牌也認得出主題）
  wall(B.left, "left", y + ROOM, h, TP.WL2, [[-1.75, -0.85, 2.1], [-3.35, -2.45, 2.1]]);
  for (const ez of [-1.3, -2.9]) {
    for (const z of [ez - 0.5, ez + 0.5]) B.left.box(-W / 2 + 0.17, y + ROOM, z, 0.06, 2.2, 0.1, TP.ST1);
    B.left.box(-W / 2 + 0.17, y + ROOM + 2.1, ez, 0.06, 0.12, 1.1, TP.ST1);
  }
  wall(B.right, "right", y + ROOM, h, TP.WL2);
  glassFront(B, y + ROOM, h);
  pendant(B, y + ROOM, 0.1, 0.05, 3.2, h, !f.active);
  if (f.seats > 0) pendant(B, y + ROOM, -0.7, -3.95, 3.2, h, !f.active);
  const n = Math.min(f.seats, 12);
  for (let i = 0; i < n; i++) deskSet(B, y, desk(i, f.id), f.active, `${f.project || ""}#${i}`);
  if (f.seats < 4) deskSet(B, y, desk(f.seats, f.id), false, `${f.project || ""}#spare0`);   // 人少補一張空桌（像一間辦公室）
  const [p0, p1, p2] = THEME_PROPS[f.theme] || THEME_PROPS.general;
  const mirror = (f.number || 0) % 2 === 1;
  P[p0](B.solid, B.glow, { x: mirror ? 1.6 : 2.6, y: y + ROOM, z: BACKZ + 0.02, a: 0 }, accent);
  P[p1](B.solid, B.glow, { x: W / 2 - 0.17, y: y + ROOM, z: 0.7, a: -Math.PI / 2 }, accent);
  P[p2](B.solid, B.glow, { x: -4.7, y: y + ROOM, z: 1.55, a: 0 }, accent);
  P.plantLow(B.solid, B.glow, { x: W / 2 - 0.6, y: y + ROOM, z: -5.6, a: -Math.PI / 2 });
}

function idleFloor(B, f, y) {
  const h = HEIGHT.idle - SLAB;
  B.solid.box(0, y, ZC, W, SLAB, D, TP.ST2);
  B.solid.box(0, y + SLAB, ZC, W - 0.02, 0.01, D - 0.02, TP.FL2);
  for (const x of [-W / 2 + 0.075, W / 2 - 0.075]) B.solid.box(x, y + ROOM, ZC, 0.15, h, D, TP.WL2);
  wall(B.back, "back", y + ROOM, h, TP.WL2);
  B.glass.box(0, y + ROOM, ZF - 0.02, W, h, 0.02, TP.GL1);
  // 一排門牌（薄層只留門牌：樓層號色塊）
  const n = Math.min(f.plates.length, 8);
  for (let i = 0; i < n; i++) B.solid.box(-W / 2 + 1.0 + i * 1.3, y + ROOM + 0.12, BACKZ + 0.03, 1.0, 0.36, 0.03, TP.FN5);
}

function lobbyFloor(B, y, sign) {
  const h = HEIGHT.lobby - SLAB, v = B.solid;
  shell(B, y, TP.FL2, h);
  wall(B.back, "back", y + ROOM, h, TP.WL1);
  wall(B.left, "left", y + ROOM, h, TP.WL2, [[-1.75, -0.85, 2.1], [-3.35, -2.45, 2.1]]);
  wall(B.right, "right", y + ROOM, h, TP.WL2);
  glassFront(B, y + ROOM, h - 0.8, [-0.9, 0.9, 2.4]);
  // 招牌帶（玻璃上方）
  v.box(0, y + h - 0.55, ZF - 0.05, W, 0.8, 0.1, TP.FN6);
  B.glow.box(0, y + h - 0.6, ZF + 0.005, W, 0.03, 0.02, TP.NE1);
  // 前台：櫃台＋識別色燈條
  v.box(0.4, y + ROOM, -0.2, 3.2, 1.05, 0.7, TP.FN5);
  v.box(0.4, y + ROOM + 1.05, -0.2, 3.3, 0.05, 0.78, TP.FN2);
  B.glow.box(0.4, y + ROOM + 0.2, 0.16, 3.2, 0.04, 0.01, TP.NE1);
  v.box(1.4, y + ROOM + 1.1, -0.35, 0.5, 0.32, 0.04, TP.FN6);
  // 後牆形象牆（字在 sign 那張貼圖）
  v.box(0, y + ROOM + 0.9, BACKZ + 0.04, 4.4, 1.8, 0.06, TP.FN6);
  // 後段咖啡館（Mac 10-22：一樓加深做休息區）
  v.box(3.6, y + ROOM, -6.2, 2.6, 1.0, 0.7, TP.FN1); v.box(3.6, y + ROOM + 1.0, -6.2, 2.7, 0.05, 0.8, TP.FN5);
  B.glow.box(3.6, y + ROOM + 1.7, BACKZ + 0.03, 2.2, 0.5, 0.02, TP.CITYWIN);
  for (const [x, z] of [[-3.2, -4.6], [-0.8, -5.2], [1.6, -4.4]]) {
    v.box(x, y + ROOM, z, 0.08, 0.72, 0.08, TP.FN3); v.box(x, y + ROOM + 0.72, z, 0.8, 0.04, 0.8, TP.FN5);
    for (const dx of [-0.65, 0.65]) v.box(x + dx, y + ROOM, z, 0.4, 0.45, 0.4, TP.FN2);
  }
  P.plantTall(v, B.glow, { x: -5.2, y: y + ROOM, z: 1.6, a: 0 });
  P.plantTall(v, B.glow, { x: 5.2, y: y + ROOM, z: 1.6, a: 0 });
  P.sofa(v, B.glow, { x: -4.6, y: y + ROOM, z: -1.0, a: Math.PI / 2 }, 0x5B6F8C);
  sign.position.set(0, y + h - 0.15, ZF + 0.02);
  sign.visible = true;
}

function roofFloor(B, y) {
  const v = B.solid, top = y + ROOM;
  shell(B, y, TP.FL1, 0.01);
  // 玻璃欄杆（前、左、右）
  B.glass.box(0, top, ZF - 0.05, W, 1.1, 0.04, TP.GL1);
  B.glass.box(-W / 2 + 0.05, top, ZC, 0.04, 1.1, D, TP.GL1);
  B.glass.box(W / 2 - 0.05, top, ZC, 0.04, 1.1, D, TP.GL1);
  v.box(0, top + 1.1, ZF - 0.05, W, 0.05, 0.07, TP.ST1);
  for (const x of [-W / 2 + 0.05, W / 2 - 0.05]) v.box(x, top + 1.1, ZC, 0.07, 0.05, D, TP.ST1);
  wall(B.back, "back", top, 1.1, TP.WL2);
  // 棚架
  for (const [x, z] of [[-0.6, -0.4], [4.6, -0.4], [-0.6, -4.6], [4.6, -4.6]]) v.box(x, top, z, 0.14, 2.1, 0.14, TP.FN1);
  for (const z of [-0.4, -4.6]) v.box(2.0, top + 2.1, z, 5.6, 0.12, 0.14, TP.FN1);
  for (let i = 0; i < 9; i++) v.box(-0.4 + i * 0.6, top + 2.22, -2.5, 0.08, 0.08, 4.8, TP.FN2);
  // 樹（方塊樹）、植栽槽、長椅、咖啡吧
  for (const [x, z, s] of [[-4.4, -5.6, 1.2], [-2.0, -6.0, 1.0], [5.0, -6.0, 1.1], [-5.0, -1.8, 0.9]]) {
    v.box(x, top, z, 1.1, 0.45, 1.1, TP.POT); v.box(x, top + 0.42, z, 1.0, 0.05, 1.0, TP.SOIL);
    v.box(x, top + 0.45, z, 0.18, 1.0 * s, 0.18, TP.FN1);
    v.box(x, top + 0.45 + 0.8 * s, z, 1.2 * s, 0.9 * s, 1.2 * s, TP.PL1);
    v.box(x + 0.1, top + 0.45 + 1.5 * s, z - 0.1, 0.75 * s, 0.6 * s, 0.75 * s, TP.PL2);
  }
  for (const x of [-4.4, -2.7]) { v.box(x, top, 1.6, 1.4, 0.42, 0.45, TP.FN2); v.box(x, top + 0.42, 1.42, 1.4, 0.4, 0.08, TP.FN2); }
  v.box(3.2, top, 0.2, 2.0, 1.0, 0.6, TP.FN5); v.box(3.2, top + 1.0, 0.2, 2.1, 0.05, 0.7, TP.FN1);
  for (let i = 0; i < 6; i++) B.glow.box(-0.2 + i * 0.9, top + 2.05, -0.4, 0.12, 0.12, 0.12, TP.LT1);  // 棚架串燈
  // 天線
  v.box(4.6, top, -6.2, 0.12, 3.2, 0.12, TP.ST1);
  B.glow.box(4.6, top + 3.2, -6.2, 0.2, 0.2, 0.2, TP.NE2);
}

/** 模組外：四角結構柱、左外側電梯井（玻璃＋青色燈條）、電梯車廂 */
function core(B, topY) {
  for (const x of [-W / 2 - 0.12, W / 2 + 0.12]) for (const z of [ZF + 0.1, ZB - 0.1]) B.solid.box(x, 0, z, 0.3, topY, 0.3, TP.ST1);
  const ex0 = -W / 2 - 1.55, ex1 = -W / 2 - 0.05, ez0 = -3.8, ez1 = -0.4, ecx = (ex0 + ex1) / 2, ecz = (ez0 + ez1) / 2;
  B.glass.box(ecx, 0, ez1, ex1 - ex0, topY, 0.03, TP.GL1);
  B.glass.box(ex0, 0, ecz, 0.03, topY, ez1 - ez0, TP.GL1);
  for (const [x, z] of [[ex0, ez1], [ex0, ez0]]) B.solid.box(x, 0, z, 0.1, topY, 0.1, TP.ST1);
  B.glow.box(ex0 + 0.06, 0, ez1 - 0.06, 0.03, topY, 0.03, TP.ELEV);
  B.solid.box(ecx, 0.3, -1.3, 1.25, 2.3, 1.25, 0x3A3F46);
  B.glow.box(ecx, 2.55, -1.3, 1.0, 0.03, 1.0, 0xEAF6FF);
}

// MARK: 角色（方塊 Kubo；Mac makeKubo 的比例，原點＝椅面、面向 +z）

const CLAY_MAT = new THREE.MeshLambertMaterial({ color: 0xD97757 });
function moodColor(mood) { return new THREE.Color(state.colors[mood] || MOOD_DEFAULT[mood] || "#8E8E93"); }
const HAND_GEO = new THREE.BoxGeometry(0.12, 0.12, 0.12);
const RING_GEO = new THREE.RingGeometry(0.48, 0.66, 32).rotateX(-Math.PI / 2);
const DISC_GEO = new THREE.CircleGeometry(0.62, 32).rotateX(-Math.PI / 2);

function makeKubo(p, standing) {
  const root = new THREE.Group(), body = new THREE.Group();
  root.add(body);
  const v = new Vox(), g = new Vox();
  const clay = 0xD97757, dark = 0xB35C3F, ink = 0x2A1D18, mood = p.mood;
  const off = standing ? 0 : -0.3;                     // 坐著：身體整個往下 0.3（身體底＝椅面）
  if (standing) for (const x of [-0.17, 0.17]) v.box(x, 0, 0, 0.14, 0.3, 0.14, dark);
  else for (const x of [-0.17, 0.17]) { v.box(x, 0, 0.2, 0.14, 0.12, 0.36, dark); v.box(x, -0.35, 0.33, 0.13, 0.36, 0.13, dark); }
  const bv = new Vox();
  bv.box(0, 0.3 + off, 0, 0.66, 0.62, 0.5, clay);
  const eh = mood === "asleep" ? 0.03 : mood === "finished" ? 0.05 : 0.15;
  for (const x of [-0.14, 0.14]) bv.box(x, 0.68 + off - eh / 2, 0.255, 0.09, eh, 0.02, ink);
  const typing = mood === "working";
  const kbY = (standing ? 0.40 : 0.43) + off;
  const hands = typing ? [[-0.16, kbY + 0.07, 0.42], [0.16, kbY + 0.07, 0.42]] : [[-0.4, 0.55 + off, 0.12], [0.4, 0.55 + off, 0.12]];
  if (typing) {
    bv.box(0, kbY - 0.0175, 0.44, 0.56, 0.035, 0.2, 0x2E2E2E);
    g.box(0, kbY + 0.0175, 0.44, 0.5, 0.01, 0.15, 0xBF99FF);
  }
  if (mood === "idle") bv.box(0.45, 0.6 + off, 0.18, 0.12, 0.16, 0.12, 0xF5F0E6);       // 咖啡杯
  switch (p.accessory) {
    case "crown":
      g.box(0, 0.9 + off, 0, 0.5, 0.1, 0.4, 0xFFCC33);
      for (const [x, z] of [[-0.2, -0.15], [0.2, -0.15], [-0.2, 0.15], [0.2, 0.15], [0, 0.15]]) g.box(x, 0.99 + off, z, 0.09, 0.1, 0.09, 0xFFCC33);
      break;
    case "headset":
      bv.box(0, 0.915 + off, 0, 0.7, 0.05, 0.08, 0x262626);
      for (const x of [-0.35, 0.35]) bv.box(x, 0.6 + off, 0, 0.06, 0.2, 0.16, 0x262626);
      break;
    case "glasses":
      bv.box(0, 0.67 + off, 0.265, 0.5, 0.04, 0.02, 0x1A1A1A);
      for (const x of [-0.14, 0.14]) bv.box(x, 0.615 + off, 0.27, 0.16, 0.13, 0.015, 0x1A1A1A);
      break;
  }
  if (p.cap) {
    bv.box(0, 0.91 + off, 0, 0.74, 0.14, 0.6, 0x1E3A8A); bv.box(0, 0.91 + off, 0.36, 0.74, 0.04, 0.22, 0x1E3A8A);
    g.box(0, 0.955 + off, 0.31, 0.12, 0.09, 0.02, 0xFACC15); bv.box(-0.15, 0.385 + off, 0.255, 0.13, 0.15, 0.02, 0xFACC15);
  }
  if (!v.empty) root.add(v.mesh(M.solid));
  const bodyMesh = bv.mesh(M.solid);
  body.add(bodyMesh);
  if (!g.empty) body.add(g.mesh(M.glow));
  const handMeshes = hands.map(([x, y, z]) => {
    const m = new THREE.Mesh(HAND_GEO, CLAY_MAT);
    m.position.set(x, y, z); body.add(m); return m;
  });
  // 頭上的狀態寶石：紫工作／紅等你／綠做完／橘卡住
  if (["working", "waiting", "finished", "stuck"].includes(mood)) {
    const gem = new THREE.Mesh(HAND_GEO, new THREE.MeshBasicMaterial({ color: moodColor(mood) }));
    gem.scale.setScalar(1.6);
    gem.position.set(0, (p.accessory === "crown" ? 1.28 : 1.16) + off, 0);
    gem.rotation.set(0.6, 0.78, 0);
    body.add(gem);
  }
  root.scale.setScalar(KUBO);
  return { root, body, hands: handMeshes, bodyMesh };
}

// MARK: 場景狀態

const state = {
  data: null, colors: {}, reduceMotion: false, structureKey: "", peopleKey: "",
  floors: [], people: [], labels: [], selected: null, userMoved: false, lighting: localStorage.getItem("office.lighting") || "auto",
  frames: 0, ready: false, night: false, animUntil: 0,
};
window.__office = state;                                 // 測試、截圖用（frames、ready、debug）

const params = new URLSearchParams(location.search);
const host = window.chrome && window.chrome.webview;
if (params.get("light")) state.lighting = params.get("light");

const stage = document.getElementById("stage"), labelLayer = document.getElementById("labels");
const renderer = new THREE.WebGLRenderer({ antialias: true, powerPreference: "low-power" });
renderer.setPixelRatio(Math.min(window.devicePixelRatio || 1, 1.5));
renderer.setSize(stage.clientWidth, stage.clientHeight);
renderer.shadowMap.enabled = true;
renderer.shadowMap.type = THREE.PCFSoftShadowMap;
renderer.shadowMap.autoUpdate = false;                   // 陰影只在重建／換燈光時算一次
stage.appendChild(renderer.domElement);

const scene = new THREE.Scene();
const camera = new THREE.PerspectiveCamera(32, stage.clientWidth / Math.max(1, stage.clientHeight), 0.5, 400);
const controls = new OrbitControls(camera, renderer.domElement);
controls.enableDamping = false;                          // 不要慣性：拖完就停，不用一直畫
controls.mouseButtons = { LEFT: THREE.MOUSE.ROTATE, MIDDLE: THREE.MOUSE.PAN, RIGHT: THREE.MOUSE.PAN };
controls.zoomToCursor = true;
controls.minDistance = 4; controls.maxDistance = 140;
controls.maxPolarAngle = Math.PI * 0.495;
controls.addEventListener("change", () => requestRender());
controls.addEventListener("start", () => { state.userMoved = true; });

state.debug = { camera, controls, select, apply: d => apply(d), requestRender: () => requestRender() };
const hemi = new THREE.HemisphereLight(0xffffff, 0x8a8f94, 1.5);
const sun = new THREE.DirectionalLight(0xfff2dc, 2.4);
const amb = new THREE.AmbientLight(TP.LT1, 0);
sun.castShadow = true;
sun.shadow.mapSize.set(2048, 2048);
sun.shadow.bias = -0.0006;
sun.shadow.normalBias = 0.02;
scene.add(hemi, sun, sun.target, amb);

const world = new THREE.Group(); scene.add(world);
const towerGroup = new THREE.Group(), peopleGroup = new THREE.Group(), cityGroup = new THREE.Group(), lightGroup = new THREE.Group();
world.add(towerGroup, peopleGroup, cityGroup, lightGroup);

// 一樓招牌字（貼圖只畫一次）
const sign = (() => {
  const c = document.createElement("canvas"); c.width = 1024; c.height = 128;
  const x = c.getContext("2d");
  x.font = "800 92px 'Segoe UI', 'Helvetica Neue', Arial, sans-serif"; x.textAlign = "center"; x.textBaseline = "middle";
  x.fillStyle = "#F4F4F4"; x.fillText("ShoWork", 450, 68);
  x.fillStyle = "#F2C14E"; x.fillText("42", 450 + x.measureText("ShoWork").width / 2 + 52, 68);
  const tex = new THREE.CanvasTexture(c); tex.colorSpace = THREE.SRGBColorSpace; tex.anisotropy = 4;
  const m = new THREE.Mesh(new THREE.PlaneGeometry(4.8, 0.6), new THREE.MeshBasicMaterial({ map: tex, transparent: true }));
  m.visible = false;
  return m;
})();
scene.add(sign);

// MARK: 城市背景（簡化：地面、道路、四周方塊大樓；夜晚窗戶亮）

function buildCity() {
  const ground = new THREE.Mesh(new THREE.PlaneGeometry(600, 600).rotateX(-Math.PI / 2), M.ground);
  ground.position.y = -0.01; ground.receiveShadow = true;
  cityGroup.add(ground);
  const v = new Vox(), win = new Vox();
  v.box(0, 0, 9.5, 120, 0.02, 7, 0x4A4F55);                       // 前面的馬路
  for (let i = -10; i <= 10; i++) v.box(i * 6, 0.02, 9.5, 2.4, 0.01, 0.15, 0xE8E4D8);
  v.box(0, 0, 5.2, 120, 0.12, 1.6, 0xB9B4AA);                     // 人行道
  let seed = 42;
  const rnd = () => ((seed = (seed * 16807) % 2147483647) / 2147483647);
  const shades = [0x8E98A3, 0x9DA6AE, 0x7F8994, 0xA9AFB4, 0x6E7884];
  const spots = [];
  for (let gx = -9; gx <= 9; gx++) for (let gz = -9; gz <= 3; gz++) {
    const x = gx * 9 + (rnd() - 0.5) * 3, z = gz * 9 - 6 + (rnd() - 0.5) * 3;
    if (Math.abs(x) < 24 && z > -26) continue;                    // 大樓本身與前面留空
    if (z > -2 && Math.abs(x) < 40) continue;                     // 鏡頭前方不要擋
    if (Math.hypot(x, z) > 85 || rnd() < 0.25) continue;
    spots.push([x, z]);
  }
  for (const [x, z] of spots) {
    const w = 4 + rnd() * 4, d = 4 + rnd() * 4, h = 5 + rnd() * (Math.hypot(x, z) < 45 ? 12 : 26);
    v.box(x, 0, z, w, h, d, shades[Math.floor(rnd() * shades.length)]);
    // 窗戶（朝 +z 與朝大樓那一側）
    for (let yy = 1.5; yy < h - 1; yy += 1.6) for (let xx = -w / 2 + 0.8; xx < w / 2 - 0.5; xx += 1.2) {
      if (rnd() < 0.28) win.box(x + xx, yy, z + d / 2 + 0.02, 0.6, 0.7, 0.02, rnd() < 0.8 ? TP.CITYWIN : 0xBFD8FF);
    }
  }
  const city = v.mesh(M.city); city.receiveShadow = true;
  cityGroup.add(city);
  const w = win.mesh(M.cityWin); w.name = "windows";
  cityGroup.add(w);
}
buildCity();

// MARK: 組大樓（資料結構變了才重建）

function disposeGroup(g) {
  for (const o of [...g.children]) {
    g.remove(o);
    o.traverse(c => { if (c.geometry && c.geometry !== HAND_GEO && c.geometry !== RING_GEO && c.geometry !== DISC_GEO) c.geometry.dispose(); });
  }
}

function layout(floors) {
  let y = 0;
  return floors.map(f => { const h = HEIGHT[f.kind] || HEIGHT.project; const o = { ...f, y, h }; y += h; return o; });
}

function buildTower(floors) {
  disposeGroup(towerGroup); disposeGroup(lightGroup);
  sign.visible = false;
  const B = { solid: new Vox(), glow: new Vox(), glass: new Vox(), back: new Vox(), left: new Vox(), right: new Vox() };
  for (const f of floors) {
    if (f.kind === "lobby") lobbyFloor(B, f.y, sign);
    else if (f.kind === "idle") idleFloor(B, f, f.y);
    else if (f.kind === "roof") roofFloor(B, f.y);
    else projectFloor(B, f, f.y);
  }
  const top = floors.length ? floors[floors.length - 1].y + 0.3 : 4;
  core(B, top);
  towerGroup.add(B.solid.mesh(M.solid, true), B.glow.mesh(M.glow), B.glass.mesh(M.glass));
  for (const fc of FACADES) { const m = B[fc.key].mesh(M[fc.key], true); fc.mesh = m; towerGroup.add(m); }
  // 夜晚：有 AI 的樓層＋大廳各一盞室內暖光（最多 8 盞；白天關掉）
  const lit = floors.filter(f => f.kind === "lobby" || (f.kind === "project" && f.active)).slice(-8);
  for (const f of lit) {
    const l = new THREE.PointLight(TP.LT1, f.kind === "lobby" ? 30 : 22, 13, 1.6);
    l.position.set(0, f.y + f.h - 0.7, -1.6);
    lightGroup.add(l);
  }
  state.towerTop = top;
  // 陰影範圍＝整棟樓
  const s = sun.shadow.camera, r = Math.max(14, top * 0.62);
  s.left = -r; s.right = r; s.top = r; s.bottom = -r; s.near = 1; s.far = 220; s.updateProjectionMatrix();
  sun.target.position.set(0, top / 2, ZC);
  applyLighting();
  renderer.shadowMap.needsUpdate = true;
}

function buildPeople(floors) {
  disposeGroup(peopleGroup);
  state.people = [];
  for (const f of floors) {
    if (f.kind !== "project") continue;
    const n = f.people.length;
    f.people.forEach((p, i) => {
      const s = seat(i, n, f.id);
      const k = makeKubo(p, s.standing);
      k.root.position.set(s.x, f.y + ROOM + (s.standing ? 0 : SEAT_TOP), s.z);
      k.root.rotation.y = s.a;
      k.root.userData.id = p.id;
      // 地上的狀態光圈（同光暈配色）
      if (["working", "waiting", "finished", "stuck"].includes(p.mood)) {
        const disc = new THREE.Mesh(DISC_GEO, new THREE.MeshBasicMaterial({ color: moodColor(p.mood), transparent: true, opacity: 0.28, depthWrite: false }));
        disc.position.set(s.x, f.y + ROOM + 0.015, s.z);
        peopleGroup.add(disc);
      }
      const ring = new THREE.Mesh(RING_GEO, new THREE.MeshBasicMaterial({ color: 0xffffff, transparent: true, opacity: 0.9, depthWrite: false }));
      ring.position.set(s.x, f.y + ROOM + 0.02, s.z); ring.visible = false;
      peopleGroup.add(ring, k.root);
      state.people.push({ p, f, ...k, ring, phase: Number(fnv64(p.id) % 1000n), born: performance.now(),
        // 名牌錨點：x 跟著人、z 拉到正面玻璃（後段的人投影會比前段高，名牌會跑進樓上那層）、高度在這層的頭頂附近
        head: new THREE.Vector3(s.x, f.y + ROOM + 1.55 + (s.z < -2 ? 0.3 : 0), ZF),
        // 拉近時改用真正的頭頂（正面玻璃那個點在近處會偏離本人）
        headNear: new THREE.Vector3(s.x, f.y + ROOM + (s.standing ? 1.75 : SEAT_TOP + 1.45), s.z) });
    });
  }
  // 保全（前台旁邊、戴警帽；Windows 沒有 WiFi 監控資料，只是站著）
  const lobby = floors.find(f => f.kind === "lobby");
  if (lobby) {
    const g = makeKubo({ id: "guard", mood: "idle-guard", cap: true }, true);
    g.root.position.set(2.45, lobby.y + ROOM, 0.45); g.root.rotation.y = -0.35;
    peopleGroup.add(g.root);
  }
}

// MARK: 畫面上的標籤（樓層名、角色名牌）：每次渲染投影一次

function el(cls, html) { const d = document.createElement("div"); d.className = cls; d.innerHTML = html; labelLayer.appendChild(d); return d; }
const esc = s => String(s ?? "").replace(/[&<>"]/g, c => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c]));

function buildLabels(floors) {
  labelLayer.innerHTML = "";
  state.labels = [];
  for (const f of floors) {
    let html, cls = "tag";
    if (f.kind === "lobby") html = `<i class="bar" style="background:#5CE1FF"></i><span class="no">01</span> 大廳・前台`;
    else if (f.kind === "roof") html = `<i class="bar" style="background:#7C9A6A"></i><span class="no">RF</span> 空中花園`;
    else if (f.kind === "idle") {
      cls += " idle";
      html = `閒置 ${f.plates.length} 個專案：${f.plates.map(p => esc((p.floorNo ? p.floorNo + " " : "") + p.name)).join("、")}`;
    } else {
      if (!f.active) cls += " dark";
      html = `<i class="bar" style="background:${esc(f.accent || "#8F8B85")}"></i><span class="no">${esc(f.floorNo)}</span> ${esc(f.project)}・${esc(f.themeTitle || "")}` +
        (f.active ? (f.queued ? ` <span class="sub">＋${f.queued} 排隊</span>` : "") : ` <span class="sub">燈暗（沒人）</span>`);
    }
    const d = el(cls, html);
    const yy = f.kind === "idle" ? f.y + 0.6 : f.y + f.h - 0.3;
    state.labels.push({ el: d, pos: new THREE.Vector3(-W / 2 + 0.3, yy, ZF + 0.1), kind: "floor" });
  }
  for (const it of state.people) {
    const p = it.p, c = state.colors[p.mood] || MOOD_DEFAULT[p.mood] || "#E5E5EA";
    const icon = p.mood === "waiting" ? "❗ " : p.mood === "idle" ? "☕ " : p.mood === "asleep" ? "💤 " : p.mood === "stuck" ? "⚠ " : "";
    const task = p.task ? `<span class="task">・${esc(p.task.length > 10 ? p.task.slice(0, 10) + "⋯" : p.task)}</span>` : "";
    const d = el("pill", `<span style="color:${esc(c)}">${icon}${esc(p.name)}</span>${task}`);
    d.title = `${p.name}（${MOOD_TEXT[p.mood] || p.mood}）\n${p.title || ""}\n${p.reason || ""}`;
    d.addEventListener("click", e => { e.stopPropagation(); select(p.id); });
    state.labels.push({ el: d, pos: it.head, near: it.headNear, kind: "person", id: p.id });
  }
  for (const l of state.labels) { l.w = l.el.offsetWidth; l.h = l.el.offsetHeight; }
}

const _v = new THREE.Vector3();
function placeLabels() {
  const w = renderer.domElement.clientWidth, h = renderer.domElement.clientHeight;
  const far = camera.position.distanceTo(controls.target) > (state.homeDist || 40) * 1.3;   // 拉遠才只顯示名字
  const placed = [];
  const people = [];
  // 遠＝名牌拉到正面玻璃那一面（不會跑進樓上）；近＝貼著本人頭頂；中間連續混合
  const k = THREE.MathUtils.clamp((camera.position.distanceTo(controls.target) / (state.homeDist || 40) - 0.35) / 0.4, 0, 1);
  for (const l of state.labels) {
    if (l.near) _v.lerpVectors(l.near, l.pos, k); else _v.copy(l.pos);
    _v.project(camera);
    if (_v.z > 1 || _v.z < -1) { l.el.style.display = "none"; continue; }
    const x = (_v.x + 1) / 2 * w, y = (1 - _v.y) / 2 * h;
    l.sx = l.kind === "floor" ? x : x - l.w / 2; l.sy = y - l.h / 2;                                   // 名牌中心對準頭頂
    if (l.kind === "person") people.push(l); else placed.push(l);
    l.el.style.display = "";
  }
  // 名牌不疊在一起：照原位、下一列、上一列各試「原地／往右讓／往左讓」，挑第一個空位（只在這層的上下一列內挪，不跑進別層）
  people.sort((a, b) => a.sy - b.sy || a.sx - b.sx);
  const boxes = placed.map(l => ({ x: l.sx, y: l.sy, w: l.w, h: l.h }));   // 也不要蓋住樓層名
  const hitAt = (x, y, w, h) => boxes.find(b => x < b.x + b.w + 3 && b.x < x + w + 3 && y < b.y + b.h + 1 && b.y < y + h + 1);
  for (const l of people) {
    l.el.classList.toggle("far", far);
    const x0 = l.sx, y0 = l.sy, row = l.h + 2;
    let best = null;
    for (const dy of [0, row, -row * 0.6, row * 2]) {
      const y = y0 + dy, hit = hitAt(x0, y, l.w, l.h);
      if (!hit) { best = [x0, y]; break; }
      const right = hit.x + hit.w + 4, left = hit.x - l.w - 4;
      for (const x of Math.abs(right - x0) <= Math.abs(left - x0) ? [right, left] : [left, right])
        if (Math.abs(x - x0) < l.w * 1.6 && !hitAt(x, y, l.w, l.h)) { best = [x, y]; break; }
      if (best) break;
    }
    [l.sx, l.sy] = best || [x0, y0];
    boxes.push({ x: l.sx, y: l.sy, w: l.w, h: l.h });
  }
  for (const l of [...placed, ...people]) l.el.style.transform = `translate(${Math.round(l.sx)}px, ${Math.round(l.sy)}px)`;
}

// MARK: cutaway：面向鏡頭的牆淡掉（Mac：外法線和視線內積 > 0.25 就藏）

function updateCutaway() {
  const dx = camera.position.x - controls.target.x, dz = camera.position.z - controls.target.z, len = Math.hypot(dx, dz) || 1;
  for (const fc of FACADES) {
    const facing = (fc.n[0] * dx + fc.n[1] * dz) / len > 0.25, mat = M[fc.key];
    if (fc.facing === facing) continue;
    fc.facing = facing;
    mat.transparent = facing; mat.opacity = facing ? 0.1 : 1; mat.depthWrite = !facing; mat.needsUpdate = true;
    if (fc.mesh) fc.mesh.castShadow = !facing;
  }
}

// MARK: 燈光（白天／夜晚／自動：06:00–18:00 白天）

function isNight() {
  if (state.lighting === "day") return false;
  if (state.lighting === "night") return true;
  const h = new Date().getHours();
  return h < 6 || h >= 18;
}
let clockTimer = 0;
function scheduleClock() {
  clearTimeout(clockTimer);
  if (state.lighting !== "auto") return;
  const now = new Date(), next = new Date(now);
  const h = now.getHours();
  next.setHours(h < 6 ? 6 : h < 18 ? 18 : 30, 0, 5, 0);       // 30 點＝隔天 06:00
  clockTimer = setTimeout(() => { applyLighting(); scheduleClock(); }, next - now);   // 一次性，不輪詢
}

function applyLighting() {
  const night = isNight();
  state.night = night;
  const sky = new THREE.Color(night ? SKY.night : SKY.day);
  scene.background = sky;
  scene.fog = new THREE.Fog(sky, night ? 60 : 80, night ? 190 : 230);
  hemi.color.set(night ? 0x8899BB : 0xffffff); hemi.groundColor.set(night ? 0x1A2028 : 0x8A8F94); hemi.intensity = night ? 0.35 : 1.5;
  sun.color.set(night ? 0xA8B8E0 : 0xFFF2DC); sun.intensity = night ? 0.35 : 2.4;
  const az = night ? -0.6 : 0.75;                                  // 白天太陽在右前上方
  const top = state.towerTop || 20;
  sun.position.set(Math.sin(az) * 60, top / 2 + 70, ZC + Math.cos(az) * 60);
  amb.color.set(night ? TP.LT1 : 0xffffff); amb.intensity = night ? 0.5 : 0.55;   // 白天也補一點，室內不要被上一層樓板的陰影壓黑
  lightGroup.visible = night;
  M.glow.color.setScalar(night ? 1.0 : 0.82);
  M.city.color.setScalar(night ? 0.22 : 1);
  M.ground.color.set(night ? GROUND.night : GROUND.day);
  const win = cityGroup.getObjectByName("windows"); if (win) win.visible = night;
  document.getElementById("lightIcon").textContent = state.lighting === "auto" ? "◐" : night ? "☾" : "☀";
  const sel = document.getElementById("lighting");
  sel.options[0].textContent = `自動・${night ? "夜晚" : "白天"}`;
  sel.value = state.lighting;
  renderer.shadowMap.needsUpdate = true;
  requestRender();
}

// MARK: 鏡頭

function defaultView() {
  const top = state.towerTop || 10;
  const target = new THREE.Vector3(-0.6, top / 2, ZC + 0.8);
  const fov = THREE.MathUtils.degToRad(camera.fov), aspect = camera.aspect;
  const needH = top / 2 + 3.2, needW = W / 2 + 2.6;
  const dist = Math.max(needH / Math.tan(fov / 2), needW / (Math.tan(fov / 2) * aspect)) + D / 2 + 1;
  const az = THREE.MathUtils.degToRad(16), el = THREE.MathUtils.degToRad(10);
  const pos = new THREE.Vector3(target.x + Math.sin(az) * Math.cos(el) * dist, target.y + Math.sin(el) * dist, target.z + Math.cos(az) * Math.cos(el) * dist);
  state.homeDist = pos.distanceTo(target);
  return { pos, target };
}

let tween = null;
function resetView(animate) {
  const v = defaultView();
  state.userMoved = false;
  if (!animate || state.reduceMotion) {
    camera.position.copy(v.pos); controls.target.copy(v.target); controls.update(); requestRender(); return;
  }
  tween = { t0: performance.now(), dur: 600, p0: camera.position.clone(), t0v: controls.target.clone(), p1: v.pos, t1: v.target };
  requestRender();
}

// MARK: 選人（點角色 → 通知 WinForms；瀏覽器單獨開就自己顯示）

function markSelected(id) {
  state.selected = id;
  for (const it of state.people) it.ring.visible = it.p.id === id;
  for (const l of state.labels) if (l.kind === "person") l.el.classList.toggle("sel", l.id === id);
}

function select(id) {
  markSelected(id);
  const it = state.people.find(x => x.p.id === id);
  if (host) host.postMessage({ type: "select", id: id || null });
  else showDetail(it ? it : null);
  requestRender();
}

function showDetail(it) {
  const box = document.getElementById("detail");
  if (!it) { box.hidden = true; return; }
  const p = it.p, c = state.colors[p.mood] || MOOD_DEFAULT[p.mood];
  box.innerHTML = `<span class="x" title="關閉">✕</span><div class="h" style="color:${esc(c)}">${esc(p.name)}・${esc(MOOD_TEXT[p.mood] || p.mood)}</div>` +
    `<div>${esc(it.f.floorNo)} ${esc(it.f.project)}</div><div>${esc(p.title)}</div><div class="r">${esc(p.reason)}</div>`;
  box.querySelector(".x").onclick = () => select(null);
  box.hidden = false;
}

const ray = new THREE.Raycaster(), ndc = new THREE.Vector2();
let downAt = null;
renderer.domElement.addEventListener("pointerdown", e => { downAt = [e.clientX, e.clientY]; });
renderer.domElement.addEventListener("pointerup", e => {
  if (!downAt || e.button !== 0 || Math.hypot(e.clientX - downAt[0], e.clientY - downAt[1]) > 4) { downAt = null; return; }
  downAt = null;
  const r = renderer.domElement.getBoundingClientRect();
  ndc.set((e.clientX - r.left) / r.width * 2 - 1, -(e.clientY - r.top) / r.height * 2 + 1);
  ray.setFromCamera(ndc, camera);
  const hits = ray.intersectObjects(state.people.map(x => x.root), true);
  const hit = hits.length ? state.people.find(x => { let o = hits[0].object; while (o && o !== x.root) o = o.parent; return o === x.root; }) : null;
  select(hit ? hit.p.id : null);
});
renderer.domElement.addEventListener("pointermove", e => {
  if (e.buttons) return;
  const r = renderer.domElement.getBoundingClientRect();
  ndc.set((e.clientX - r.left) / r.width * 2 - 1, -(e.clientY - r.top) / r.height * 2 + 1);
  ray.setFromCamera(ndc, camera);
  renderer.domElement.style.cursor = ray.intersectObjects(state.people.map(x => x.root), true).length ? "pointer" : "";
});

// MARK: 動畫與渲染（要動才畫；有人在打字／等你時 12 fps）

function animating(now) {
  if (tween) return true;
  if (state.reduceMotion) return false;
  return state.people.some(it => it.p.mood === "working" || it.p.mood === "waiting" || (it.p.mood === "finished" && now - it.born < 2600));
}

function animate(now) {
  if (tween) {
    const k = Math.min(1, (now - tween.t0) / tween.dur), e = k * k * (3 - 2 * k);
    camera.position.lerpVectors(tween.p0, tween.p1, e); controls.target.lerpVectors(tween.t0v, tween.t1, e); controls.update();
    if (k >= 1) tween = null;
  }
  if (state.reduceMotion) return;
  const t = now / 1000;
  for (const it of state.people) {
    const ph = it.phase / 1000 * Math.PI * 2;
    switch (it.p.mood) {
      case "working":                                              // 打字：唯一一直在動的
        it.hands.forEach((m, i) => { m.position.y = m.userData.y0 ?? (m.userData.y0 = m.position.y); m.position.y += (Math.sin(t * 25 + ph + i * Math.PI) > 0 ? 0.05 : 0); });
        break;
      case "waiting": {                                            // 等你：每 3 秒跳三下
        const c = (t + ph) % 3;
        it.body.position.y = c < 1.2 ? Math.abs(Math.sin(c / 0.4 * Math.PI)) * 0.14 : 0;
        break;
      }
      case "finished": {                                           // 做完：剛出現時搖一下
        const a = (now - it.born) / 1000;
        it.body.rotation.z = a < 2.6 ? Math.sin(a / 2.4 * Math.PI * 2) * 0.08 : 0;
        break;
      }
    }
  }
}

let raf = 0, dirty = true, last = 0;
function requestRender() { dirty = true; if (!raf) raf = requestAnimationFrame(loop); }
function loop(now) {
  raf = 0;
  const anim = animating(now);
  if (anim && now - last >= 1000 / 12 - 2) { animate(now); last = now; dirty = true; }
  if (dirty) {
    dirty = false;
    updateCutaway();
    renderer.render(scene, camera);
    placeLabels();
    state.frames++;
  }
  if (anim) raf = requestAnimationFrame(loop);
}

addEventListener("resize", () => {
  const w = stage.clientWidth, h = stage.clientHeight;
  renderer.setSize(w, h); camera.aspect = w / Math.max(1, h); camera.updateProjectionMatrix();
  if (!state.userMoved) resetView(false);
  requestRender();
});

// MARK: 資料進來

function apply(data) {
  if (!data || data.type !== "office" || !Array.isArray(data.floors)) return;
  state.data = data;
  state.colors = data.colors || {};
  state.reduceMotion = !!data.reduceMotion || matchMedia("(prefers-reduced-motion: reduce)").matches;
  const floors = layout(data.floors);
  const sKey = JSON.stringify(floors.map(f => [f.kind, f.id, f.floorNo, f.seats, f.theme, f.accent, f.active, f.queued, (f.plates || []).map(p => p.name + p.floorNo)]));
  const pKey = JSON.stringify([sKey, floors.map(f => (f.people || []).map(p => [p.id, p.mood, p.name, p.task, p.accessory, p.title, p.reason])), state.colors]);
  const oldTop = state.towerTop;
  if (sKey !== state.structureKey) { state.structureKey = sKey; buildTower(floors); }
  if (pKey !== state.peopleKey) {
    state.peopleKey = pKey;
    buildPeople(floors);
    buildLabels(floors);
    if (state.selected && !state.people.some(x => x.p.id === state.selected)) select(null); else markSelected(state.selected);
  }
  state.floors = floors;
  renderCounts(data.counts || {});
  document.getElementById("empty").hidden = true;
  if (!state.ready || (!state.userMoved && oldTop !== state.towerTop)) resetView(false);
  state.ready = true;
  requestRender();
}

function renderCounts(c) {
  const chip = (n, mood, text) => n ? `<span class="chip"><i style="background:${esc(state.colors[mood] || MOOD_DEFAULT[mood])}"></i>${n}<span>${text}</span></span>` : "";
  document.getElementById("counts").innerHTML =
    chip(c.waiting, "waiting", "等你回答") + chip(c.stuck, "stuck", "卡住") + chip(c.finished, "finished", "做完了") + chip(c.working, "working", "工作中");
}

// MARK: 工具列

document.getElementById("lighting").addEventListener("change", e => {
  state.lighting = e.target.value;
  try { localStorage.setItem("office.lighting", state.lighting); } catch { }
  applyLighting(); scheduleClock();
});
document.getElementById("reset").addEventListener("click", () => { select(null); resetView(true); });
document.getElementById("help").addEventListener("click", () => { const h = document.getElementById("helpPop"); h.hidden = !h.hidden; });

// MARK: 開始

applyLighting();
scheduleClock();
if (host) {
  host.addEventListener("message", e => {
    const d = e.data;
    if (d && d.type === "deselect") { markSelected(null); requestRender(); return; }
    apply(d);
  });
  document.getElementById("empty").hidden = false;
  host.postMessage({ type: "ready" });
} else if (params.has("demo")) {
  import("./demo-data.js").then(m => apply(m.demo));
} else {
  const e = document.getElementById("empty");
  e.textContent = "沒有資料：在 ShoWork42 戰情中心裡開，或加 ?demo=1 看示範";
  e.hidden = false;
}
