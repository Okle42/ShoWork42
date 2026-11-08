// 單層辦公室（11-08 H5 第三版，docs/OWN-SESSIONS.md）：取代大樓剖面；城市、地下室 B1、燈光、天氣、名牌照舊，只換「大樓」那一塊。
//   一層樓拆成多個房間：會議室（隊長）、主管室、茶水間（做完的）、廁所、走道、開放工作區（每個專案一區、每個 AI 一張桌）、
//   休息區（閒著的：撞球、手足球、沙發、懶骨頭）、前台（保全）。地板分區（木地板、地毯、磁磚、棋盤磚），牆有窗、百葉、玻璃隔間、門、門牌。
//   房間用「人的公尺」排（24 × 19.6），整棟縮 0.5 倍放進原本大樓那塊地（12 × 9.8），城市不用動；建築外圍一圈草地、樹、路燈、步道。
//   物件全部走 props.js 的註冊表：每種一個 glb 檔名，assets/models/manifest.json 有列就載模型，沒有就畫佔位方塊。
//   人：person_base.glb（有 idle／walk／sit 動畫）載得到就用，否則用 person.js 的程式人物；換位置時沿走道走過去。
//   燈：白天太陽（有陰影）；室內暖色點光＋吊燈、檯燈發光，夜裡比較亮；家具底下有接觸陰影（假 AO）。

import * as THREE from "three";
import { mergeGeometries } from "../vendor/three-r170/utils/BufferGeometryUtils.js";
import { clone as cloneSkinned } from "../vendor/three-r170/utils/SkeletonUtils.js";
import { VoxMat, TP, TD, scnNode, setEuler } from "../kit.js";
import { OfficeBuilder, projectId, KuboArt } from "./builder.js";
import { OfficeBasement } from "./basement.js";
import * as Tower from "./tower.js";
import { runAction, Act } from "./actions.js";
import { PROPS, Props, mat } from "./props.js";
import { makeHuman } from "./person.js";

/** 房間座標（人的公尺）→ 世界：縮 OS 倍、中心放在原本大樓那塊地的中心 */
export const OS = 0.5;
const HW = 12, HD = 9.8, WALL = 2.9;
const R = TD.room, CZ = TD.zC;
const toWorld = (x, y, z) => [x * OS, R + y * OS, CZ + z * OS];

// MARK: - 格局（人的公尺；+z 朝前＝鏡頭那邊）

export const Plan = {
  rooms: {
    meeting: { x0: -12, x1: -4.5, z0: -HD, z1: -4.0, title: "會議室", floor: "carpetBlue" },
    manager: { x0: -4.5, x1: 1.5, z0: -HD, z1: -4.0, title: "主管室", floor: "carpetRed" },
    pantry: { x0: 1.5, x1: 8, z0: -HD, z1: -4.0, title: "茶水間", floor: "tile" },
    toilets: { x0: 8, x1: 12, z0: -HD, z1: -4.0, title: "廁所", floor: "checker" },
    corridor: { x0: -12, x1: 12, z0: -4.0, z1: -2.6, title: "走道", floor: "woodDark" },
    work: { x0: -12, x1: 3.5, z0: -2.6, z1: HD, title: "工作區", floor: "wood" },
    lounge: { x0: 3.5, x1: 12, z0: -2.6, z1: 5.2, title: "休息區", floor: "woodDark" },
    lobby: { x0: 3.5, x1: 12, z0: 5.2, z1: HD, title: "前台", floor: "tileLight" },
  },
  /** 後排房間的門（在走道那面牆 z=-4.0 上）：x 中心、寬 */
  doors: { meeting: [-6.0, 1.2], manager: [-0.2, 1.0], pantry: [4.6, 1.4], toilets: [10.0, 1.0] },
  /** 工位：8 欄 × 5 排；人面向 +z，桌子在人前面 */
  cols: [-10.9, -9.2, -7.5, -5.8, -4.1, -2.4, -0.7, 1.0],
  rows: [-1.7, 0.6, 2.9, 5.2, 7.5],
  meetingSeats: [{ x: -11.0, z: -6.9, a: Math.PI / 2, sit: true },
                 ...[-9.6, -8.4, -7.2, -6.0].flatMap(x => [{ x, z: -7.95, a: 0, sit: true }, { x, z: -5.85, a: Math.PI, sit: true }])],
  /** 休息區（閒置、睡著）：撞球、手足球兩邊站著；沙發、懶骨頭坐著 */
  loungeSlots: [{ x: 6.2, z: 0.0, a: Math.PI / 2 }, { x: 9.6, z: -0.2, a: -Math.PI / 2 }, { x: 7.9, z: -1.6, a: 0 },
                { x: 4.6, z: 3.9, a: Math.PI / 2 }, { x: 6.9, z: 3.9, a: -Math.PI / 2 },
                { x: 10.6, z: 2.4, a: -Math.PI / 2, sit: true, seatY: 0.45 }, { x: 10.6, z: 3.2, a: -Math.PI / 2, sit: true, seatY: 0.45 },
                { x: 10.6, z: 4.0, a: -Math.PI / 2, sit: true, seatY: 0.45 }, { x: 8.6, z: 4.6, a: Math.PI, sit: true, seatY: 0.3 },
                { x: 4.5, z: 1.6, a: 0.6 }],
  /** 茶水間（做完的）：中島旁、高腳椅 */
  pantrySlots: [{ x: 3.6, z: -5.8, a: Math.PI / 2 }, { x: 4.4, z: -5.15, a: Math.PI, sit: true, seatY: 0.72 }, { x: 5.3, z: -5.15, a: Math.PI, sit: true, seatY: 0.72 },
                { x: 6.2, z: -5.15, a: Math.PI, sit: true, seatY: 0.72 }, { x: 6.9, z: -7.4, a: -Math.PI / 2 }, { x: 2.5, z: -6.8, a: Math.PI / 2 }],
  aisleSlots: [-10, -8, -6, -4, -2, 0, 2].map(x => ({ x, z: 8.9, a: 0 })),
  guard: { x: 8.0, z: 6.15, a: 0 },
  entrance: { x: 8.5, z: HD + 0.2 },
};

/** 心情 → 放哪裡 */
export function placeKind(p) {
  if (p.card?.captain) return "meeting";
  switch (p.mood) {
    case "working": case "waiting": case "stuck": return "desk";
    case "finished": return "pantry";
    default: return "lounge";
  }
}
function roomAt(x, z) {
  for (const [k, r] of Object.entries(Plan.rooms)) if (x >= r.x0 && x <= r.x1 && z >= r.z0 && z <= r.z1) return k;
  return "work";
}

// MARK: - 程式材質（木地板、磁磚、棋盤磚、地毯、百葉、草地）

const texCache = new Map();
function canvasTex(key, draw, size = 256, repeat = [1, 1]) {
  const k = `${key}|${repeat}`;
  if (texCache.has(k)) return texCache.get(k);
  const c = document.createElement("canvas"); c.width = c.height = size;
  draw(c.getContext("2d"), size);
  const t = new THREE.CanvasTexture(c); t.colorSpace = THREE.SRGBColorSpace; t.wrapS = t.wrapT = THREE.RepeatWrapping; t.repeat.set(...repeat); t.anisotropy = 4;
  texCache.set(k, t);
  return t;
}
const noise = (g, n, a, s) => { for (let i = 0; i < n; i++) { g.fillStyle = `rgba(0,0,0,${Math.random() * a})`; g.fillRect(Math.random() * s, Math.random() * s, 2, 2); } };
const planks = (cs, edge) => (g, s) => { for (let i = 0; i < 8; i++) { g.fillStyle = cs[i % 4]; g.fillRect(0, i * s / 8, s, s / 8); g.fillStyle = edge; g.fillRect(0, i * s / 8, s, 1); g.fillRect(((i * 97) % s), i * s / 8, 1, s / 8); } noise(g, 600, 0.06, s); };
const grid = (bg, line, n) => (g, s) => { g.fillStyle = bg; g.fillRect(0, 0, s, s); g.strokeStyle = line; g.lineWidth = 2; for (let i = 0; i <= n; i++) { g.beginPath(); g.moveTo(i * s / n, 0); g.lineTo(i * s / n, s); g.stroke(); g.beginPath(); g.moveTo(0, i * s / n); g.lineTo(s, i * s / n); g.stroke(); } noise(g, 300, 0.05, s); };
const FLOORS = {
  wood: rep => canvasTex("wood", planks(["#C89A68", "#BE8F5E", "#D2A673", "#C49461"], "rgba(60,35,15,.35)"), 256, rep),
  woodDark: rep => canvasTex("woodDark", planks(["#9C6B44", "#93633E", "#A6744B", "#8E5F3B"], "rgba(40,20,8,.4)"), 256, rep),
  tile: rep => canvasTex("tile", grid("#E9E2D6", "rgba(120,110,95,.45)", 4), 256, rep),
  tileLight: rep => canvasTex("tileLight", grid("#D9D4CB", "rgba(100,95,85,.35)", 2), 256, rep),
  checker: rep => canvasTex("checker", (g, s) => { for (let i = 0; i < 4; i++) for (let j = 0; j < 4; j++) { g.fillStyle = (i + j) % 2 ? "#2C2E33" : "#E8E6E1"; g.fillRect(i * s / 4, j * s / 4, s / 4, s / 4); } }, 256, rep),
  carpetBlue: rep => canvasTex("carpetBlue", (g, s) => { g.fillStyle = "#4A5A6E"; g.fillRect(0, 0, s, s); noise(g, 4000, 0.12, s); }, 128, rep),
  carpetRed: rep => canvasTex("carpetRed", (g, s) => { g.fillStyle = "#7A3A32"; g.fillRect(0, 0, s, s); noise(g, 4000, 0.12, s); }, 128, rep),
  grass: rep => canvasTex("grass", (g, s) => { g.fillStyle = "#5E8C46"; g.fillRect(0, 0, s, s); for (let i = 0; i < 2500; i++) { g.fillStyle = `rgba(${30 + Math.random() * 40},${80 + Math.random() * 60},${20 + Math.random() * 30},.5)`; g.fillRect(Math.random() * s, Math.random() * s, 2, 3); } }, 128, rep),
  path: rep => canvasTex("path", grid("#B9B2A6", "rgba(80,75,65,.35)", 2), 128, rep),
};
const blindsTex = () => canvasTex("blinds", (g, s) => { g.fillStyle = "#EDE6D8"; g.fillRect(0, 0, s, s); for (let i = 0; i < 16; i++) { g.fillStyle = "rgba(120,100,70,.35)"; g.fillRect(0, i * s / 16 + s / 16 - 3, s, 3); } }, 128);
/** 接觸陰影（家具底下的柔和暗影；假 AO） */
const blobTex = () => canvasTex("blob", (g, s) => { const r = g.createRadialGradient(s / 2, s / 2, s * 0.1, s / 2, s / 2, s / 2); r.addColorStop(0, "rgba(0,0,0,.55)"); r.addColorStop(1, "rgba(0,0,0,0)"); g.fillStyle = r; g.fillRect(0, 0, s, s); }, 64);

function textTexture(text, { bg = "#1B1D21", fg = "#F3F1EC", accent = null, h = 72 } = {}) {
  const c = document.createElement("canvas");
  const font = `600 44px "PingFang TC","Microsoft JhengHei UI","Noto Sans TC",sans-serif`;
  const g0 = c.getContext("2d"); g0.font = font;
  const w = Math.ceil(Math.min(1000, g0.measureText(text).width + (accent != null ? 70 : 44)));
  c.width = w; c.height = h;
  const g = c.getContext("2d");
  g.fillStyle = bg; g.fillRect(0, 0, w, h);
  if (accent != null) { g.fillStyle = "#" + accent.toString(16).padStart(6, "0"); g.fillRect(0, 0, 12, h); }
  g.font = font; g.fillStyle = fg; g.textBaseline = "middle"; g.fillText(text, accent != null ? 32 : 22, h / 2 + 2);
  const t = new THREE.CanvasTexture(c); t.colorSpace = THREE.SRGBColorSpace; t.anisotropy = 4;
  return { t, aspect: w / h };
}

// MARK: - 批次（同材質合併）＋接觸陰影

class Batch {
  constructor() { this.byMat = new Map(); this.blobs = []; }
  push(g, m) { if (!this.byMat.has(m)) this.byMat.set(m, []); this.byMat.get(m).push(g); }
  /** 擺一個物件（房間座標；a＝繞 y 轉；y＝離地高） */
  add(name, x, z, a = 0, y = 0, { blob = true } = {}) {
    const parts = Props.parts(name);
    if (!parts.length) return false;
    const m = new THREE.Matrix4().makeRotationY(a).premultiply(new THREE.Matrix4().makeTranslation(x, y, z));
    for (const [g, mt] of parts) this.push(g.clone().applyMatrix4(m), mt);
    if (blob && y < 0.05 && y > -0.05) { const s = PROPS[name].size; this.blobs.push([x, z, a, s[0] * 1.25 + 0.2, s[2] * 1.25 + 0.2]); }
    return true;
  }
  box(w, h, d, x, y, z, m, ry = 0) { const g = new THREE.BoxGeometry(w, h, d); if (ry) g.rotateY(ry); g.translate(x, y + h / 2, z); this.push(g, m); }
  node(name) {
    const root = scnNode(name);
    for (const [m, gs] of this.byMat) {
      const g = mergeGeometries(gs.map(x => (x.index ? x.toNonIndexed() : x)), false);
      if (!g) continue;
      const mesh = new THREE.Mesh(g, m);
      mesh.castShadow = !m.transparent; mesh.receiveShadow = true;
      root.add(mesh);
    }
    if (this.blobs.length) {
      const gs = this.blobs.map(([x, z, a, w, d]) => { const g = new THREE.PlaneGeometry(w, d); g.rotateX(-Math.PI / 2); g.rotateY(a); g.translate(x, 0.012, z); return g; });
      const bm = new THREE.MeshBasicMaterial({ map: blobTex(), transparent: true, depthWrite: false, opacity: 0.85 });
      const n = new THREE.Mesh(mergeGeometries(gs, false), bm); n.renderOrder = 1; n.name = "contact-shadows";
      root.add(n);
    }
    return root;
  }
}

// MARK: - 人（模型或程式人物）

const PERSON_SEAT = 0.48;
function makeBody(id, { sit, seatY = PERSON_SEAT }) {
  const g = Props.glb.get("person_base");
  if (g?.clips?.length) {           // 自製模型：照尺寸縮放，播 idle／sit／walk
    const model = cloneSkinned(g.scene);
    const box = new THREE.Box3().setFromObject(g.scene), k = 1.72 / Math.max(0.1, box.max.y - box.min.y);
    model.scale.setScalar(k);
    const mixer = new THREE.AnimationMixer(model);
    const clip = n => g.clips.find(c => c.name.toLowerCase().includes(n));
    let act = null;
    const setPose = p => { act?.fadeOut(0.25); const c = clip(p === "sit" ? "sit" : p === "walk" ? "walk" : "idle"); act = c ? mixer.clipAction(c).reset().fadeIn(0.25).play() : null; model.position.y = p === "sit" ? seatY - 0.45 : 0; };
    setPose(sit ? "sit" : "stand");
    return { node: model, setPose, update: (_t, dt) => mixer.update(dt), headTop: p => (p === "sit" ? seatY + 0.9 : 1.75) };
  }
  const hm = makeHuman(id, { seatY });
  hm.setPose(sit ? "sit" : "stand");
  return hm;
}

// MARK: - 辦公室

export class OpenOfficeBuilder extends OfficeBuilder {
  constructor(opts) {
    super(opts);
    for (const c of this.cars) c.removeFromParent();      // 單層樓：沒有電梯
    this.root = scnNode("office-root");
    this.root.position.set(0, R, CZ); this.root.scale.setScalar(OS);
    this.world.add(this.root);
    this.office = null; this.officeSig = "";
    this.furniture = null; this.furnitureSig = "";
    this.outdoor = null;
    this.zoneList = []; this.assign = new Map(); this.seats = [];
    this.bodies = new Map();       // card id → { body, walk }
    this.clock = 0;
    this.lastIslands = []; this.lastGuard = null;
    this.onAssets = null; this.onLayout = null;
    this.indoor = [];              // 室內暖光
    // 陰影：太陽投影
    this.sun.castShadow = true;
    this.sun.shadow.mapSize.set(2048, 2048);
    const sc = this.sun.shadow.camera; sc.left = -11; sc.right = 11; sc.top = 11; sc.bottom = -11; sc.near = 60; sc.far = 160;
    this.sun.shadow.bias = -0.0006; this.sun.shadow.normalBias = 0.02; this.sun.shadow.radius = 4;
    Props.load().then(() => {        // 自製模型載好（或沒有）：重畫家具、人
      Props.reset(); this.furnitureSig = ""; this.buildFurniture();
      for (const p of this.persons.values()) p.look = "";
      this.guardKey = "";
      this.updatePeople(this.lastIslands, null, false);
      if (this.lastGuard) this.updateGuard(this.lastGuard, false);
      this.onAssets?.();
    });
  }

  // MARK: 資料 → 格局

  update(newPlan, decor, wander, islands, guardStatus, scanning, animate, now = new Date()) {
    islands = islands ?? [];
    guardStatus = guardStatus ?? { level: "normal", hasData: false };
    this.decor = decor ?? {};
    this.tower = newPlan?.floors?.length ? newPlan : { floors: [] };
    this.guardLevel = guardStatus.level ?? "normal";
    const first = !this.office;
    this.layout(islands);
    if (!this.office || this.officeSig !== this.layoutSig) { this.buildShell(); this.onLayout?.(); }
    if (!this.outdoor) this.buildOutdoor();
    this.buildFurniture();
    this.lastIslands = islands; this.lastGuard = guardStatus;
    this.updatePeople(islands, null, animate);
    this.updateGuard(guardStatus, scanning);
    this.highlight(this.lit);
    this.looping = !OfficeBuilder.reduceMotion && (scanning || this.weatherFX.raining || this.bodies.size > 0);
    this.omniDirty = true; this.assignOmni();
    return first ? "layout" : "none";
  }

  projectOrder(islands) {
    const byFloor = new Map(this.tower.floors.filter(f => f.kind === "project").map(f => [String(f.project ?? "").toLowerCase(), Number(f.floorNo ?? 99)]));
    return islands.slice().sort((a, b) => {
      const fa = byFloor.get(String(a.project).toLowerCase()) ?? 999, fb = byFloor.get(String(b.project).toLowerCase()) ?? 999;
      return fa - fb || String(a.project).localeCompare(String(b.project));
    });
  }
  accentOf(project) {
    const d = this.decor[String(project ?? "").toLowerCase()];
    const th = d?.theme ?? "general";
    return TP.hex(d?.accentColor ?? "") ?? TP.hex(Tower.TowerTheme?.accent?.[th] ?? "") ?? 0x8FE3EE;
  }

  /** 每個人分到哪：工位（每個專案佔整欄、一欄 5 張、用到的欄置中）、會議室、休息區、茶水間、走道 */
  layout(islands) {
    const P = Plan, nr = P.rows.length, nc = P.cols.length;
    const seats = [], zones = [], assign = new Map();
    const used = { meeting: 0, lounge: 0, pantry: 0, aisle: 0 };
    const spill = id => assign.set(id, { kind: "aisle", slot: used.aisle++ % P.aisleSlots.length });
    const order = this.projectOrder(islands).map(i => {
      const people = i.people.slice().sort((a, b) => (a.card.id < b.card.id ? -1 : 1)).slice(0, OfficeBuilder.maxPeople);
      return { i, people, desk: people.filter(p => placeKind(p) === "desk") };
    });
    const want = order.map(o => Math.ceil(o.desk.length / nr));
    while (want.reduce((a, b) => a + b, 0) > nc) { const k = want.indexOf(Math.max(...want)); want[k] -= 1; }
    let col = Math.floor((nc - want.reduce((a, b) => a + b, 0)) / 2);
    order.forEach((o, k) => {
      const fid = projectId(o.i.project), mine = [], c0 = col;
      col += want[k];
      let n = 0;
      for (const p of o.people) {
        const kind = placeKind(p);
        if (kind === "desk") {
          if (n >= want[k] * nr) { spill(p.card.id); continue; }
          const c = c0 + Math.floor(n / nr), r = n % nr; n++;
          seats.push({ x: P.cols[c], z: P.rows[r], a: 0, sit: true });
          mine.push(seats.length - 1);
          assign.set(p.card.id, { kind: "desk", slot: seats.length - 1, zone: fid });
        } else {
          const list = { meeting: P.meetingSeats, lounge: P.loungeSlots, pantry: P.pantrySlots }[kind];
          if (used[kind] < list.length) assign.set(p.card.id, { kind, slot: used[kind]++, zone: fid });
          else spill(p.card.id);
        }
      }
      if (mine.length) {
        const pts = mine.map(i => seats[i]);
        zones.push({ id: fid, project: o.i.project, title: o.i.project, accent: this.accentOf(o.i.project), seats: mine,
                     rect: { x0: Math.min(...pts.map(q => q.x)) - 0.8, x1: Math.max(...pts.map(q => q.x)) + 0.8,
                             z0: Math.min(...pts.map(q => q.z)) - 0.7, z1: Math.max(...pts.map(q => q.z)) + 1.2 } });
      }
    });
    this.seats = seats; this.zoneList = zones; this.assign = assign;
    this.layoutSig = JSON.stringify([zones.map(z => [z.id, z.seats.length, z.accent, z.rect.x0]), seats.length]);
  }

  // MARK: 房子：地板、牆、窗、百葉、玻璃隔間、門、門牌、區域名稱

  buildShell() {
    this.office?.removeFromParent();
    const root = scnNode("open-office");
    const b = new Batch();
    b.box(2 * HW + 0.4, 0.3, 2 * HD + 0.4, 0, -0.3, 0, mat(0x8E8B85));             // 樓板
    for (const r of Object.values(Plan.rooms)) {                                     // 地板：每個房間一種
      const w = r.x1 - r.x0, d = r.z1 - r.z0;
      const m = new THREE.MeshStandardMaterial({ map: FLOORS[r.floor]([w / 2, d / 2]), roughness: r.floor.startsWith("carpet") ? 1 : 0.7 });
      const g = new THREE.PlaneGeometry(w, d); g.rotateX(-Math.PI / 2); g.translate((r.x0 + r.x1) / 2, 0.002, (r.z0 + r.z1) / 2);
      b.push(g, m);
    }
    for (const z of this.zoneList) {                                                  // 工作區：每個專案一塊地毯
      const r = z.rect, col = new THREE.Color(z.accent).lerp(new THREE.Color(0x8C7A66), 0.55);
      const g = new THREE.PlaneGeometry(r.x1 - r.x0, r.z1 - r.z0); g.rotateX(-Math.PI / 2); g.translate((r.x0 + r.x1) / 2, 0.006, (r.z0 + r.z1) / 2);
      b.push(g, mat(col.getHex(), { rough: 1 }));
    }
    const wallM = mat(0xE8E1D5, { rough: 0.95 }), wallAccent = mat(0x8A4B35, { rough: 0.9 }), frameM = mat(0x2E3136, { rough: 0.5 });
    const glassM = mat(0xA9C7D6, { opacity: 0.3, rough: 0.05 }), blindsM = new THREE.MeshStandardMaterial({ map: blindsTex(), roughness: 1 });
    const winM = mat(0xBFD8E6, { rough: 0.1, emit: 0.25 });
    const wallRun = (x0, z0, x1, z1, h, m, t = 0.2) => { const len = Math.hypot(x1 - x0, z1 - z0), a = Math.atan2(x1 - x0, z1 - z0); b.box(t, h, len, (x0 + x1) / 2, 0, (z0 + z1) / 2, m, a); };
    // 外牆：後牆、左牆全高（有窗＋百葉）；前牆、右牆只到窗台（剖面看進去），上面是淡玻璃
    wallRun(-HW, -HD, HW, -HD, WALL, wallM);
    wallRun(-HW, -HD, -HW, HD, WALL, wallM);
    wallRun(-HW, HD, Plan.entrance.x - 1.1, HD, 0.95, wallM);
    wallRun(Plan.entrance.x + 1.1, HD, HW, HD, 0.95, wallM);
    wallRun(HW, -HD, HW, HD, 0.95, wallM);
    for (let x = -10.5; x < HW - 1; x += 3.0) {
      b.box(1.9, 1.5, 0.04, x + 0.95, 0.9, -HD + 0.12, winM);
      b.box(1.9, 0.75, 0.03, x + 0.95, 1.65, -HD + 0.15, blindsM);
      b.box(2.0, 0.06, 0.12, x + 0.95, 0.86, -HD + 0.16, frameM);
    }
    for (let z = -2.0; z < HD - 1; z += 3.0) {
      b.box(0.04, 1.5, 1.9, -HW + 0.12, 0.9, z + 0.95, winM);
      b.box(0.03, 0.75, 1.9, -HW + 0.15, 1.65, z + 0.95, blindsM);
    }
    b.box(0.08, 1.4, 2 * HD, HW - 0.04, 0.95, 0, glassM);
    b.box(Plan.entrance.x - 1.1 + HW, 1.4, 0.08, (-HW + Plan.entrance.x - 1.1) / 2, 0.95, HD - 0.04, glassM);
    b.box(HW - Plan.entrance.x - 1.1, 1.4, 0.08, (Plan.entrance.x + 1.1 + HW) / 2, 0.95, HD - 0.04, glassM);
    // 走道那面牆（z=-4.0）：門洞＋門楣；會議室那段是玻璃隔間；主管室那段是深色牆
    const cw = -4.0, gaps = Object.values(Plan.doors).map(([x, w]) => [x - w / 2, x + w / 2]).sort((a, c) => a[0] - c[0]);
    let x = -HW;
    for (const [g0, g1] of gaps) {
      if (g0 > x) {
        if (x < -4.5) { b.box(g0 - x, 0.1, 0.12, (x + g0) / 2, 0, cw, frameM); b.box(g0 - x, 2.6, 0.06, (x + g0) / 2, 0.1, cw, glassM); b.box(g0 - x, 0.2, 0.14, (x + g0) / 2, 2.7, cw, frameM); }
        else b.box(g0 - x, WALL, 0.16, (x + g0) / 2, 0, cw, x < 1.5 ? wallAccent : wallM);
      }
      b.box(g1 - g0, WALL - 2.25, 0.16, (g0 + g1) / 2, 2.25, cw, wallM);
      x = g1;
    }
    b.box(HW - x, WALL, 0.16, (x + HW) / 2, 0, cw, wallM);
    for (const [dx] of Object.values(Plan.doors)) b.add("door", dx - 0.15, cw + 0.42, 1.2, 0, { blob: false });
    for (const wx of [-4.5, 1.5, 8]) wallRun(wx, -HD, wx, cw, WALL, wx === 8 ? mat(0xC9CED2) : wallM, 0.14);
    b.box(0.35, 1.1, 5.0, 3.5, 0, 0.2, mat(0x7A5233));                // 工作區／休息區之間的矮櫃
    b.box(0.4, 0.04, 5.0, 3.5, 1.1, 0.2, mat(0xD8B48A));
    const signs = scnNode("signs");
    for (const [k, [dx]] of Object.entries(Plan.doors)) {             // 門牌（門楣上，兩面都貼）
      const { t, aspect } = textTexture(k === "toilets" ? "TOILETS 廁所" : Plan.rooms[k].title, { bg: "#22252A" });
      const h = 0.32, w = h * aspect;
      for (const side of [1, -1]) {
        const n = new THREE.Mesh(new THREE.PlaneGeometry(w, h), new THREE.MeshBasicMaterial({ map: t }));
        n.position.set(dx, 2.55, cw + side * 0.09); if (side < 0) n.rotation.y = Math.PI;
        signs.add(n);
      }
    }
    const decal = (text, accent, x, z, maxW) => {                       // 區域名稱：貼在地上
      const { t, aspect } = textTexture(text, { accent });
      const h = Math.min(0.75, maxW / aspect), w = h * aspect;
      const n = new THREE.Mesh(new THREE.PlaneGeometry(w, h), new THREE.MeshBasicMaterial({ map: t, transparent: true, opacity: 0.92, depthWrite: false }));
      n.rotation.x = -Math.PI / 2; n.position.set(x, 0.02, z); n.renderOrder = 2;
      signs.add(n);
    };
    for (const z of this.zoneList) decal(z.title, z.accent, (z.rect.x0 + z.rect.x1) / 2, Math.min(9.35, z.rect.z1 + 0.4), Math.max(1.2, z.rect.x1 - z.rect.x0 - 0.2));
    decal("休息區・閒著", 0xF59E0B, 7.8, -2.15, 4.5);
    decal("前台・保全", 0x1E3A8A, 5.6, 9.3, 3.0);
    root.add(b.node("office-shell")); root.add(signs);
    const mods = new Map();          // 假模組：每區一個節點（給 focusPoint、左側索引列用）
    const addMod = (id, r, kind) => { const n = scnNode(`floor:${id}`); n.position.set((r.x0 + r.x1) / 2, 0, (r.z0 + r.z1) / 2); root.add(n); mods.set(id, { parts: { node: n, facades: [] }, key: id, floor: { id, kind, y: 0, height: WALL } }); };
    for (const z of this.zoneList) addMod(z.id, z.rect, "project");
    addMod("lobby", Plan.rooms.lobby, "lobby"); addMod("roof", Plan.rooms.lounge, "roof");
    this.modules = mods;
    this.root.add(root);
    this.office = root; this.officeSig = this.layoutSig; this.furnitureSig = "";
    const lo = toWorld(-HW, 0, -HD), hi = toWorld(HW, WALL + 0.3, HD);
    this.weatherFX.shelter(this.world, [lo[0], 0, lo[2]], hi);
    this.cutSig = ""; this.lodDirty = true; this.omniDirty = true;
    if (this.guardNode) { this.guardNode.removeFromParent(); this.guardNode = null; this.guardKey = ""; }
  }

  // MARK: 家具（佔位或自製模型）

  buildFurniture() {
    if (!this.office) return;
    const sig = this.layoutSig + "|" + Props.glb.size;
    if (sig === this.furnitureSig) return;
    this.furnitureSig = sig;
    this.furniture?.removeFromParent();
    const b = new Batch();
    this.seats.forEach((s, i) => {                     // 工位：桌、隔板、雙螢幕、鍵盤、椅子；隔幾張放文件、馬克杯、檯燈、小盆栽
      b.add("desk", s.x, s.z + 0.6, Math.PI);
      b.add("desk_divider", s.x, s.z + 0.97, 0, 0.75, { blob: false });
      b.add("monitor_dual", s.x, s.z + 0.78, Math.PI, 0.75, { blob: false });
      b.add("keyboard", s.x, s.z + 0.45, 0, 0.75, { blob: false });
      b.add("chair_office", s.x, s.z - 0.05, 0);
      if (i % 2 === 0) b.add("documents", s.x + 0.45, s.z + 0.55, 0, 0.75, { blob: false });
      if (i % 3 === 1) b.add("mug", s.x - 0.55, s.z + 0.4, 0, 0.75, { blob: false });
      if (i % 4 === 2) b.add("desk_lamp", s.x - 0.55, s.z + 0.75, 0.4, 0.75, { blob: false });
      if (i % 5 === 3) b.add("plant_small", s.x + 0.55, s.z + 0.8, 0, 0.75, { blob: false });
    });
    for (const [x, n] of [[-11, "poster"], [-8.8, "cork_board"], [-2.6, "poster"], [2.6, "cork_board"], [6.8, "poster"]]) b.add(n, x, -3.9, 0, 1.0, { blob: false });
    for (const x of [-11.4, -3.3, 3.0, 11.4]) b.add("plant_tall", x, -3.3, 0);
    b.add("floor_fan", -11.4, 8.9, 0.6); b.add("bookshelf", -11.75, 3.2, Math.PI / 2); b.add("bookshelf", -11.75, 4.5, Math.PI / 2);
    b.add("trash_bin", 2.9, 8.9, 0); b.add("plant_tall", 2.9, -2.1, 0);
    // 會議室
    b.add("meeting_table", -7.8, -6.9, 0);
    for (const s of Plan.meetingSeats) b.add("chair_meeting", s.x - Math.sin(s.a) * 0.05, s.z - Math.cos(s.a) * 0.05, s.a);
    b.add("projector_screen", -7.8, -9.62, 0, 0.6, { blob: false });
    b.add("whiteboard", -11.86, -6.9, Math.PI / 2, 0.9, { blob: false });
    b.add("plant_tall", -5.1, -9.2, 0); b.add("plant_small", -7.8, -6.9, 0, 0.75, { blob: false });
    // 主管室
    b.add("rug_large", -1.5, -6.6, 0, 0, { blob: false });
    b.add("exec_desk", -1.5, -7.9, 0); b.add("chair_exec", -1.5, -8.7, 0);
    b.add("bookshelf", -3.6, -9.55, 0); b.add("bookshelf", 0.6, -9.55, 0);
    b.add("trophy", -2.2, -7.9, 0, 0.78, { blob: false }); b.add("globe", 0.8, -5.0, 0); b.add("chart_board", -3.8, -5.0, 0.5);
    b.add("plant_tall", 1.0, -8.9, 0); b.add("armchair", -1.0, -5.0, Math.PI); b.add("armchair", -2.2, -5.0, Math.PI);
    // 茶水間
    b.add("kitchen_counter", 4.4, -9.45, 0); b.add("fridge", 6.8, -9.35, 0); b.add("vending_machine", 2.15, -9.35, 0);
    b.add("water_dispenser", 7.6, -6.2, -Math.PI / 2); b.add("kitchen_island", 5.3, -6.4, 0);
    for (const x of [4.4, 5.3, 6.2]) b.add("bar_stool", x, -5.15, 0);
    b.add("mug", 4.8, -6.4, 0, 0.95, { blob: false }); b.add("trash_bin", 7.6, -8.9, 0);
    // 廁所
    for (const x of [8.7, 9.75, 10.8]) b.add("toilet_stall", x, -8.95, 0, 0, { blob: false });
    b.add("sink_counter", 11.6, -5.6, -Math.PI / 2);
    // 休息區
    b.add("rug_large", 7.9, 0.0, 0, 0, { blob: false }); b.add("pool_table", 7.9, 0.0, 0);
    b.add("foosball", 5.75, 3.9, 0);
    b.add("sofa", 11.05, 3.2, -Math.PI / 2); b.add("coffee_table", 9.6, 3.2, Math.PI / 2);
    b.add("beanbag", 8.6, 4.6, 0); b.add("beanbag", 7.2, 4.7, 0.4);
    b.add("tv_wall", 11.7, -1.0, -Math.PI / 2, 1.0, { blob: false });
    b.add("plant_tall", 11.4, -2.1, 0); b.add("plant_tall", 4.0, 4.8, 0); b.add("floor_fan", 4.0, -2.0, 0.8);
    // 前台
    b.add("reception_desk", 8.0, 6.9, Math.PI);
    b.add("plant_tall", 11.3, 9.2, 0); b.add("plant_tall", 4.0, 9.2, 0); b.add("bench", 10.6, 8.9, Math.PI);
    // 吊燈：會議桌、主管桌、中島、撞球桌、前台、工作區
    const lamps = [[-8.8, -6.9], [-6.8, -6.9], [-1.5, -7.6], [5.3, -6.4], [7.3, 0], [8.5, 0], [8.0, 6.9]];
    for (const c of [1, 3, 5, 7]) for (const r of [0, 2, 4]) lamps.push([Plan.cols[c] - 0.85, Plan.rows[r] + 0.6]);
    for (const [lx, lz] of lamps) b.add("pendant_lamp", lx, lz, 0, WALL - 0.9, { blob: false });
    const n = b.node("furniture");
    this.office.add(n);
    this.furniture = n;
    this.omniDirty = true;
    this.bump(0.2);
  }

  // MARK: 戶外：草地、步道、樹、灌木、路燈、長椅（原本大樓那塊地的邊緣一圈）

  buildOutdoor() {
    // 前面緊貼城市的人行道（只留一條窄草皮＋路燈）；左、後兩邊有比較寬的綠地
    const b = new Batch();
    const grass = new THREE.MeshStandardMaterial({ map: FLOORS.grass([8, 7]), roughness: 1 });
    const g = new THREE.PlaneGeometry(2 * HW + 4.4, 2 * HD + 3.4); g.rotateX(-Math.PI / 2); g.translate(-0.6, -0.29, -0.6);
    b.push(g, grass);
    const path = new THREE.MeshStandardMaterial({ map: FLOORS.path([1, 1]), roughness: 0.95 });
    const p1 = new THREE.PlaneGeometry(2.4, 1.2); p1.rotateX(-Math.PI / 2); p1.translate(Plan.entrance.x, -0.27, HD + 0.6); b.push(p1, path);
    for (const [x, z] of [[-HW - 1.3, -HD - 1.0], [HW + 0.6, -HD - 1.2], [-HW - 1.4, 1.5], [-HW - 1.3, HD - 0.5]]) b.add("tree", x, z, 0, -0.3, { blob: false });
    for (let x = -HW + 1; x < HW; x += 2.6) b.add("bush", x, -HD - 0.7, 0, -0.3, { blob: false });
    for (let z = -HD + 1; z < HD - 1; z += 2.6) b.add("bush", -HW - 0.7, z, 0, -0.3, { blob: false });
    for (const x of [-10, -2, 6.6, 10.4]) b.add("street_lamp", x, HD + 0.5, 0, -0.3, { blob: false });
    const n = b.node("outdoor");
    this.root.add(n);
    this.outdoor = n;
  }

  // MARK: 人

  updatePeople(islands, _wander, animate) {
    const seen = new Set();
    for (const i of islands) {
      const fid = projectId(i.project);
      for (const p of i.people.slice(0, OfficeBuilder.maxPeople)) {
        const a = this.assign.get(p.card.id);
        if (!a || !this.office) continue;
        seen.add(p.card.id);
        this.placeOpen(p, fid, a, animate);
      }
    }
    for (const [id, old] of [...this.persons]) if (!seen.has(id)) { this.persons.delete(id); this.bodies.delete(id); old.node.removeFromParent(); }
    this.peopleSeeded = this.peopleSeeded || islands.length > 0;
  }

  slot(a) {
    switch (a.kind) {
      case "desk": return this.seats[a.slot];
      case "meeting": return Plan.meetingSeats[a.slot];
      case "lounge": return Plan.loungeSlots[a.slot];
      case "pantry": return Plan.pantrySlots[a.slot];
      default: return Plan.aisleSlots[a.slot];
    }
  }

  /** 一個人：身體（模型或程式人物）＋腳下狀態光圈＋頭上寶石＋名牌錨點＋點擊盒 */
  makeOpenPerson(p, slot) {
    const root = scnNode(`p:${p.card.id}`);
    const body = makeBody(p.card.id, { sit: !!slot.sit, seatY: slot.seatY ?? PERSON_SEAT });
    root.add(body.node);
    const tint = KuboArt.tint(p.mood);
    const lit = p.mood !== "idle" && p.mood !== "asleep";
    const ring = new THREE.Mesh(new THREE.TorusGeometry(0.42, 0.035, 8, 40).rotateX(-Math.PI / 2), VoxMat.flat(tint, { emit: lit ? [0.9, 2.0] : null }));
    ring.position.y = 0.04; ring.name = "status-ring";
    root.add(ring);
    const top = body.headTop(slot.sit ? "sit" : "stand");
    if (lit) { const gem = new THREE.Mesh(new THREE.OctahedronGeometry(0.13), VoxMat.flat(tint, { emit: [0.9, 2.2] })); gem.position.y = top + 0.3; gem.name = "gem"; root.add(gem); }
    const anchor = scnNode("anchor"); anchor.position.y = top + 0.55; root.add(anchor);
    this.addHaloAndHitbox(root, 1.2);
    OfficeBuilder.pickable(root);
    return { root, body };
  }

  placeOpen(p, fid, a, animate) {
    const id = p.card.id;
    const s = this.slot(a);
    const look = OfficeBuilder.personKey(p) + `|${!!s.sit}|${s.seatY ?? ""}|${Props.glb.has("person_base")}`;
    const place = `${a.kind}:${a.slot}`;
    let person = this.persons.get(id);
    const from = person ? person.node.position.clone() : null;
    if (person && person.look === look && person.place === place && person.node.parent === this.office) { person.islander = p; return; }
    if (!person || person.look !== look) {
      person?.node.removeFromParent();
      const { root, body } = this.makeOpenPerson(p, s);
      person = { node: root, look, place: "", mood: p.mood, islander: p, floor: fid, seat: a.slot, seats: 1 };
      this.bodies.set(id, { body, walk: null });
    }
    person.place = place; person.mood = p.mood; person.islander = p; person.floor = a.kind === "desk" ? fid : a.kind;
    this.persons.set(id, person);
    const node = person.node;
    if (node.parent !== this.office) { node.removeFromParent(); this.office.add(node); }
    node.rotation.y = s.a;
    const ctl = this.bodies.get(id);
    // 換位置：沿走道走過去；第一次載入、減少動態效果、太熱 ⇒ 直接到位
    if (from && animate && this.peopleSeeded && !OfficeBuilder.reduceMotion && !OfficeBuilder.heatPaused && Math.hypot(from.x - s.x, from.z - s.z) > 0.3) {
      const pts = this.route(from.x, from.z, s.x, s.z);
      const lens = pts.slice(1).map((q, i) => Math.hypot(q[0] - pts[i][0], q[1] - pts[i][1]));
      ctl.walk = { pts, lens, t: 0, end: s };
      ctl.body.setPose("walk");
      node.position.set(from.x, 0, from.z);
      this.walkUntil = Math.max(this.walkUntil, Date.now() / 1000 + lens.reduce((x, y) => x + y, 0) / 1.3 + 0.2);
    } else {
      ctl.walk = null;
      ctl.body.setPose(s.sit ? "sit" : "stand");
      node.position.set(s.x, 0, s.z);
    }
  }

  /** 走路的路線：後排房間要走門；工作區 ↔ 休息區／前台從走道那頭繞過矮櫃 */
  route(x0, z0, x1, z1) {
    const out = [[x0, z0]];
    const r0 = roomAt(x0, z0), r1 = roomAt(x1, z1);
    const door = r => Plan.doors[r];
    if (door(r0)) { out.push([door(r0)[0], -4.7]); out.push([door(r0)[0], -3.3]); }
    if (door(r1) && r1 !== r0) { out.push([door(r1)[0], -3.3]); out.push([door(r1)[0], -4.7]); }
    else if (!door(r0) && (r0 === "work") !== (r1 === "work")) out.push([3.5, -3.0]);
    out.push([x1, z1]);
    return out;
  }

  get animating() { return this.bodies.size > 0 && !OfficeBuilder.heatPaused; }

  tick(dt) {
    super.tick(dt);
    if (!(dt > 0) || OfficeBuilder.heatPaused) return;
    this.clock += dt;
    for (const [id, c] of this.bodies) {
      c.body.update(this.clock, dt);
      const w = c.walk;
      if (!w) continue;
      w.t += dt * 1.3;
      const node = id === "guard" ? null : this.persons.get(id)?.node;
      if (!node) { c.walk = null; continue; }
      let d = w.t, i = 0;
      while (i < w.lens.length && d > w.lens[i]) { d -= w.lens[i]; i++; }
      if (i >= w.lens.length) {
        node.position.set(w.end.x, 0, w.end.z); node.rotation.y = w.end.a;
        c.body.setPose(w.end.sit ? "sit" : "stand"); c.walk = null; continue;
      }
      const a = w.pts[i], b2 = w.pts[i + 1], k = d / Math.max(1e-3, w.lens[i]);
      node.position.set(a[0] + (b2[0] - a[0]) * k, 0, a[1] + (b2[1] - a[1]) * k);
      node.rotation.y = Math.atan2(b2[0] - a[0], b2[1] - a[1]);
    }
  }

  // 閒晃、電梯、搬家、方塊 Kubo 的小動作：單層樓不用；視窗看不到時走路的人直接到位
  settle() { for (const c of this.bodies.values()) if (c.walk) c.walk.t = 1e9; this.tick(0.001); }
  snapTravelers() {}
  parkCars() {}
  rebuildCore() {}
  updateGhosts() {}
  updateBoards() {}
  updateCooler() {}
  updateEmergency() {}
  scheduleFidget() {}
  schedulePatrol() {}
  startPatrol() { return false; }

  // MARK: 保全（前台後面站著；櫃台上三面監控螢幕）

  updateGuard(g, scanning) {
    if (!this.office) return;
    const level = g.level ?? "normal", hasData = !!g.hasData;
    const key = `${level}|${hasData}|${scanning}|${Props.glb.has("person_base")}`;
    if (key === this.guardKey && this.guardNode?.parent === this.office) return;
    this.guardKey = key;
    if (this.guardNode) { this.guardNode.removeFromParent(); this.bodies.delete("guard"); }
    const r = scnNode("guard");
    const lv = OfficeBuilder.guardColor(level), wifi = VoxMat.color(0x38bdf8), gray = VoxMat.color(0x6b7280);
    const cols = !hasData ? [gray, wifi, gray] : level === "alert" ? [lv, lv, lv] : [lv, wifi, lv];
    cols.forEach((c, i) => {
      const s = new THREE.Mesh(new THREE.BoxGeometry(0.5, 0.32, 0.03), VoxMat.flat(c, { emit: [0.5, 1.4] }));
      s.position.set(7.3 + i * 0.7, 1.28, 6.62);
      r.add(s);
    });
    const ant = new THREE.Mesh(new THREE.BoxGeometry(0.18, 0.18, 0.18), VoxMat.flat(wifi, { emit: [0.8, 1.6] }));
    ant.position.set(9.1, 1.25, 6.8); setEuler(ant, 0.6, 0.78, 0);
    if (scanning && !OfficeBuilder.reduceMotion) runAction(ant, Act.repeatForever(Act.rotateBy(0, Math.PI, 0, 1.2)));
    r.add(ant);
    const man = scnNode("guard-man");
    const gp = Plan.guard;
    man.position.set(gp.x, 0, gp.z); man.rotation.y = gp.a;
    const body = makeBody("guard-security-0001", { sit: false });
    man.add(body.node);
    const ring = new THREE.Mesh(new THREE.TorusGeometry(0.42, 0.035, 8, 40).rotateX(-Math.PI / 2), VoxMat.flat(lv, { emit: [0.9, 2.0] }));
    ring.position.y = 0.04; man.add(ring);
    this.addHaloAndHitbox(man, 1.2);
    const anchor = scnNode("anchor"); anchor.position.set(0, body.headTop("stand") + 0.55, 0); man.add(anchor);
    r.add(man);
    OfficeBuilder.pickable(r);
    this.office.add(r);
    this.guardNode = r;
    this.bodies.set("guard", { body, walk: null });
  }

  // MARK: 名牌（一整層當一層樓，kind "open"：不受樓層天花限制）

  labelTargets() {
    const ps = [];
    for (const [id, p] of this.persons) {
      const a = p.node.getObjectByName("anchor");
      if (a) ps.push({ id, anchor: a, card: p.islander.card, mood: p.mood, floor: "office" });
    }
    const ga = this.guardNode?.getObjectByName("anchor");
    if (ga) ps.push({ id: "guard", anchor: ga, card: null, mood: "idle", floor: "office" });
    const fs = this.office ? [{ id: "office", node: this.root, height: (WALL + 1.2) * OS, floorNo: "", title: "", kind: "open", names: [], accent: null }] : [];
    return { people: ps, floors: fs };
  }

  /** 上方分頁、左側索引列：各區 */
  zones() {
    const out = this.zoneList.map(z => ({ id: z.id, title: z.title, kind: "project", accent: z.accent }));
    return [{ id: "meeting", title: "會議室", kind: "room" }, { id: "manager", title: "主管室", kind: "room" }, ...out,
            { id: "lounge", title: "休息區", kind: "room" }, { id: "pantry", title: "茶水間", kind: "room" },
            { id: "toilets", title: "廁所", kind: "room" }, { id: "lobby", title: "前台", kind: "room" }];
  }
  zoneRect(id) {
    const z = this.zoneList.find(x => x.id === id);
    if (z) return z.rect;
    return Plan.rooms[id === "roof" ? "lounge" : id] ?? null;
  }

  // MARK: 燈：室內暖色點光（吊燈下）；夜裡比較亮

  assignOmni() {
    if (!this.omniDirty || !this.root) return;
    this.omniDirty = false;
    const spots = [[-7.8, -6.9], [-1.5, -7.2], [5.0, -6.8], [10.0, -6.8], [7.9, 0.0], [8.0, 6.9], [-8.0, 1.0], [-2.5, 1.0], [-8.0, 6.5], [-2.5, 6.5], [0, -3.3]];
    while (this.indoor.length < spots.length) {
      const l = new THREE.PointLight(0xFFC98A, 1, 4.5, 1.6); l.userData.cat = 1;
      this.root.add(l); this.indoor.push(l);
    }
    const night = VoxMat.lamps;            // 0 白天 → 1 夜晚
    this.indoor.forEach((l, i) => {
      l.position.set(spots[i][0], WALL - 0.4, spots[i][1]);
      l.intensity = (0.25 + night * 1.1) * Math.PI;
      l.distance = 9 * OS; l.visible = true;
    });
    for (const o of this.omni) o.visible = false;
  }
  applyLights() {
    super.applyLights();
    if (this.indoor) { this.omniDirty = true; this.assignOmni(); }
  }
  applyCutaway() { return false; }
  cutNow() {}
  highlightFloor() { return false; }

  // MARK: 取景（世界座標）

  frameCamera(aspect = this.aspect) {
    aspect = Math.max(0.4, aspect);
    const az = 24, el = 46;
    const [dist, t] = OfficeBuilder.fit(toWorld(-HW, 0, -HD), toWorld(HW, WALL, HD), aspect, az * Math.PI / 180, el * Math.PI / 180, 34, 1.0);
    this.place(t, dist, az, el);
  }
  frameRange() { return [0, R + WALL * OS]; }
  frameZone(id, aspect = this.aspect) {
    if (id === "b1") { this.place([0, OfficeBasement.baseY + R + 1.2, -2.1], 13, 20, 14); return true; }
    const r = this.zoneRect(id);
    if (!r) return false;
    aspect = Math.max(0.4, aspect);
    const az = 18, el = 48;
    const [dist, t] = OfficeBuilder.fit(toWorld(r.x0 - 0.5, 0, r.z0 - 0.5), toWorld(r.x1 + 0.5, 2.2, r.z1 + 0.5), aspect, az * Math.PI / 180, el * Math.PI / 180, 34, 0.95);
    this.place(t, Math.max(dist, 4), az, el);
    return true;
  }
  frameFloor(id, aspect = this.aspect) { return this.frameZone(id, aspect); }
  focusPoint(key) {
    const id = key === "roof" || key === "lobby" ? key : key.startsWith("floor:") ? projectId(key.slice(6)) : null;
    const r = id && this.zoneRect(id);
    return r ? toWorld((r.x0 + r.x1) / 2, 1.3, (r.z0 + r.z1) / 2) : null;
  }
  totalHeight() { return R + WALL * OS; }
  projectFloors() { return []; }

  /** 走進去：從大門進來、眼睛高度，看向工作區；指定區域就站在那一區的門口看進去 */
  walkStart(id = null) {
    const at = {
      meeting: [[-5.0, -4.5], [-10.0, -7.8]], manager: [[1.0, -4.5], [-2.4, -8.6]], pantry: [[7.6, -4.5], [3.2, -8.4]],
      toilets: [[10.0, -4.3], [9.6, -8.8]], lounge: [[11.4, 5.0], [6.0, -1.2]], lobby: [[11.2, 9.2], [6.0, 5.6]], work: [[3.0, 9.0], [-5.5, -0.5]],
    }[id];
    const z = this.zoneList.find(q => q.id === id);
    const [p, t] = at ?? (z ? [[(z.rect.x0 + z.rect.x1) / 2 + 1.2, Math.min(9.2, z.rect.z1 + 1.4)], [(z.rect.x0 + z.rect.x1) / 2, z.rect.z0]] : [[3.0, 9.0], [-5.5, -0.5]]);
    return { pos: toWorld(p[0], 1.65, p[1]), target: toWorld(t[0], 0.9, t[1]) };
  }
  get walkBounds() { const lo = toWorld(-HW + 0.6, 0, -HD + 0.6), hi = toWorld(HW - 0.6, 0, HD + 1.5); return { lo: [lo[0], lo[2]], hi: [hi[0], hi[2]] }; }
}
