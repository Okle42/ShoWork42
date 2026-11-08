// 辦公室物件註冊表（11-08 H5 第三版）：每種物件一個 glTF 檔名＋尺寸，自製模型做好丟進 assets/models/ 並寫進 manifest.json 就會換上；
// 沒有檔的先用程式畫的佔位方塊（看得出是什麼、尺寸對、擺位對）。物件清單同步寫在 docs/OWN-SESSIONS.md「3D 物件清單」。
//
// 規則（自製模型照這個做就能直接換）：
//   - 單位公尺，Y 朝上，模型正面朝 +Z（人坐的那一側／面向使用者的那一面），原點在底面中心。
//   - 載入後會照下表的 size 等比例縮到「長寬高都塞得進」並貼地置中；材質照模型自己的（PBR 或 Lambert 都可）。
//   - person_base.glb 要帶動畫：idle、walk、sit（名稱照這三個）；沒有就用程式動畫的佔位人物（person.js）。

import * as THREE from "three";
import { GLTFLoader } from "../vendor/three-r170/loaders/GLTFLoader.js";

// MARK: - 材質（佔位用；PBR，給陰影和暖光吃）

const matCache = new Map();
export function mat(hex, { rough = 0.8, metal = 0, emit = 0, opacity = 1 } = {}) {
  const k = `${hex}|${rough}|${metal}|${emit}|${opacity}`;
  if (matCache.has(k)) return matCache.get(k);
  const m = new THREE.MeshStandardMaterial({ color: hex, roughness: rough, metalness: metal });
  if (emit) { m.emissive = new THREE.Color(hex); m.emissiveIntensity = emit; }
  if (opacity < 1) { m.transparent = true; m.opacity = opacity; m.depthWrite = false; }
  matCache.set(k, m);
  return m;
}
const C = {
  wood: 0xB98552, woodDark: 0x7A5233, woodLight: 0xD8B48A, white: 0xF2EEE8, black: 0x24262A, metal: 0x9AA3AB, dark: 0x3A3D42,
  screen: 0x7FB8FF, green: 0x2E7D4F, felt: 0x1F7A4A, red: 0xB5402F, orange: 0xE07A2E, cream: 0xEFE3CC, leaf: 0x4E8F4A, pot: 0xC9B8A0,
  fabric: 0x5D6B7A, gold: 0xD9A93A, blue: 0x2F5D8C, cork: 0xC79A5B, paper: 0xFAF7F0,
};

/** 佔位幾何的小工具：b(寬, 高, 深, x, y底, z, 材質)；c(半徑, 高, x, y底, z, 材質)；s(半徑, x, y中心, z, 材質, 壓扁) */
class Kit {
  constructor() { this.parts = []; }
  b(w, h, d, x, y, z, m, ry = 0) { const g = new THREE.BoxGeometry(w, h, d); if (ry) g.rotateY(ry); g.translate(x, y + h / 2, z); this.parts.push([g, m]); return this; }
  c(r, h, x, y, z, m, seg = 12, r2 = null) { const g = new THREE.CylinderGeometry(r2 ?? r, r, h, seg); g.translate(x, y + h / 2, z); this.parts.push([g, m]); return this; }
  s(r, x, y, z, m, sy = 1, seg = 10) { const g = new THREE.SphereGeometry(r, seg, Math.max(6, seg - 3)); g.scale(1, sy, 1); g.translate(x, y, z); this.parts.push([g, m]); return this; }
  /** 橫放的圓柱：沿 z 軸（axis="z"）或 x 軸，中心在 (x, y, z) */
  rod(r, len, x, y, z, m, axis = "z", seg = 8) { const g = new THREE.CylinderGeometry(r, r, len, seg); if (axis === "z") g.rotateX(Math.PI / 2); else g.rotateZ(Math.PI / 2); g.translate(x, y, z); this.parts.push([g, m]); return this; }
  cone(r, h, x, y, z, m, seg = 8) { const g = new THREE.ConeGeometry(r, h, seg); g.translate(x, y + h / 2, z); this.parts.push([g, m]); return this; }
}

// MARK: - 物件表：名稱 → 尺寸（寬 x、高 y、深 z，公尺）、放在哪一區、佔位畫法

export const PROPS = {
  // 工作區
  desk:          { size: [1.4, 0.75, 0.7], zone: "工作區", note: "單人辦公桌", ph: k => k.b(1.4, 0.04, 0.7, 0, 0.71, 0, mat(C.woodLight)).b(0.04, 0.71, 0.66, -0.66, 0, 0, mat(C.white)).b(0.04, 0.71, 0.66, 0.66, 0, 0, mat(C.white)).b(1.28, 0.4, 0.02, 0, 0.3, -0.3, mat(C.white)) },
  desk_divider:  { size: [1.4, 0.45, 0.04], zone: "工作區", note: "桌上隔板（布面）", ph: k => k.b(1.4, 0.45, 0.04, 0, 0, 0, mat(0x6F8A9E, { rough: 1 })).b(1.42, 0.03, 0.05, 0, 0.45, 0, mat(C.metal)) },
  chair_office:  { size: [0.6, 1.05, 0.6], zone: "工作區", note: "辦公椅（滾輪）", ph: k => k.c(0.26, 0.05, 0, 0.04, 0, mat(C.black)).c(0.03, 0.4, 0, 0.06, 0, mat(C.metal)).b(0.5, 0.08, 0.48, 0, 0.46, 0, mat(C.dark)).b(0.48, 0.5, 0.07, 0, 0.55, -0.24, mat(C.dark)) },
  monitor_dual:  { size: [1.05, 0.48, 0.22], zone: "工作區", note: "雙螢幕（螢幕面發光，顏色＝狀態）", ph: k => k.b(0.5, 0.3, 0.03, -0.27, 0.16, 0, mat(C.black), 0.18).b(0.5, 0.3, 0.03, 0.27, 0.16, 0, mat(C.black), -0.18).b(0.05, 0.16, 0.05, 0, 0, -0.04, mat(C.metal)).b(0.3, 0.02, 0.18, 0, 0, -0.03, mat(C.metal)) },
  keyboard:      { size: [0.45, 0.03, 0.15], zone: "工作區", note: "鍵盤", ph: k => k.b(0.45, 0.025, 0.15, 0, 0, 0, mat(C.dark)) },
  mug:           { size: [0.09, 0.1, 0.09], zone: "工作區、茶水間", note: "馬克杯", ph: k => k.c(0.045, 0.1, 0, 0, 0, mat(C.white), 10) },
  documents:     { size: [0.3, 0.05, 0.22], zone: "工作區", note: "一疊文件", ph: k => k.b(0.3, 0.05, 0.22, 0, 0, 0, mat(C.paper), 0.15) },
  desk_lamp:     { size: [0.2, 0.45, 0.2], zone: "工作區", note: "檯燈（燈罩發暖光）", ph: k => k.c(0.08, 0.02, 0, 0, 0, mat(C.dark)).c(0.012, 0.35, 0, 0.02, 0, mat(C.dark), 6).cone(0.09, 0.1, 0, 0.35, 0.04, mat(0xFFE2A8, { emit: 0.8 })) },
  cork_board:    { size: [1.2, 0.9, 0.04], zone: "工作區", note: "軟木公佈欄（掛牆）", ph: k => k.b(1.2, 0.9, 0.04, 0, 0, 0, mat(C.woodDark)).b(1.1, 0.8, 0.02, 0, 0.05, 0.02, mat(C.cork)).b(0.18, 0.22, 0.01, -0.3, 0.45, 0.035, mat(C.paper)).b(0.2, 0.15, 0.01, 0.1, 0.55, 0.035, mat(0xFFE58A)).b(0.16, 0.2, 0.01, 0.35, 0.3, 0.035, mat(0xA8D8FF)) },
  poster:        { size: [0.6, 0.85, 0.02], zone: "工作區、走道", note: "海報（掛牆）", ph: k => k.b(0.6, 0.85, 0.02, 0, 0, 0, mat(C.white)).b(0.5, 0.5, 0.01, 0, 0.27, 0.012, mat(C.orange)).b(0.4, 0.06, 0.01, 0, 0.12, 0.012, mat(C.dark)) },
  // 會議室
  meeting_table: { size: [4.0, 0.75, 1.3], zone: "會議室", note: "長會議桌", ph: k => k.b(4.0, 0.06, 1.3, 0, 0.69, 0, mat(C.woodDark, { rough: 0.5 })).b(0.12, 0.69, 0.8, -1.5, 0, 0, mat(C.dark)).b(0.12, 0.69, 0.8, 1.5, 0, 0, mat(C.dark)) },
  chair_meeting: { size: [0.55, 0.95, 0.55], zone: "會議室", note: "會議椅", ph: k => k.c(0.03, 0.42, 0, 0, 0, mat(C.metal)).b(0.5, 0.08, 0.48, 0, 0.42, 0, mat(0x22252A)).b(0.48, 0.45, 0.06, 0, 0.5, -0.23, mat(0x22252A)) },
  projector_screen: { size: [2.4, 1.6, 0.06], zone: "會議室", note: "投影幕（掛後牆，畫面發光）", ph: k => k.b(2.5, 0.08, 0.1, 0, 1.52, 0, mat(C.dark)).b(2.4, 1.4, 0.02, 0, 0.12, 0, mat(0xDDE6F0, { emit: 0.25 })) },
  whiteboard:    { size: [1.8, 1.1, 0.05], zone: "會議室", note: "白板（掛側牆）", ph: k => k.b(1.8, 1.1, 0.04, 0, 0, 0, mat(C.metal)).b(1.72, 1.02, 0.01, 0, 0.04, 0.025, mat(0xFBFBFB, { rough: 0.3 })).b(0.5, 0.02, 0.01, -0.4, 0.7, 0.032, mat(C.blue)).b(0.7, 0.02, 0.01, 0.1, 0.55, 0.032, mat(C.red)) },
  // 主管室
  exec_desk:     { size: [1.9, 0.78, 0.9], zone: "主管室", note: "主管大桌", ph: k => k.b(1.9, 0.06, 0.9, 0, 0.72, 0, mat(C.woodDark, { rough: 0.45 })).b(1.86, 0.7, 0.05, 0, 0.02, -0.4, mat(C.woodDark)).b(0.05, 0.72, 0.86, -0.92, 0, 0, mat(C.woodDark)).b(0.05, 0.72, 0.86, 0.92, 0, 0, mat(C.woodDark)) },
  chair_exec:    { size: [0.7, 1.25, 0.7], zone: "主管室", note: "主管椅（高背皮椅）", ph: k => k.c(0.3, 0.05, 0, 0.04, 0, mat(C.black)).c(0.035, 0.4, 0, 0.06, 0, mat(C.metal)).b(0.62, 0.12, 0.58, 0, 0.46, 0, mat(0x3B2A20)).b(0.6, 0.72, 0.1, 0, 0.55, -0.28, mat(0x3B2A20)) },
  bookshelf:     { size: [1.2, 2.0, 0.4], zone: "主管室、工作區", note: "書櫃（滿書）", ph: k => { k.b(1.2, 2.0, 0.4, 0, 0, 0, mat(C.woodDark)); for (let r = 0; r < 4; r++) { k.b(1.1, 0.03, 0.36, 0, 0.1 + r * 0.48, 0.03, mat(C.wood)); const cols = [C.red, C.blue, C.green, C.cream, C.orange]; for (let i = 0; i < 7; i++) k.b(0.11, 0.3 + (i % 3) * 0.04, 0.26, -0.45 + i * 0.14, 0.13 + r * 0.48, 0.06, mat(cols[(i + r) % 5])); } } },
  trophy:        { size: [0.2, 0.35, 0.2], zone: "主管室", note: "獎盃", ph: k => k.b(0.16, 0.06, 0.16, 0, 0, 0, mat(C.dark)).c(0.02, 0.12, 0, 0.06, 0, mat(C.gold, { rough: 0.3, metal: 0.6 })).c(0.08, 0.14, 0, 0.18, 0, mat(C.gold, { rough: 0.3, metal: 0.6 }), 12, 0.04) },
  globe:         { size: [0.4, 0.55, 0.4], zone: "主管室", note: "地球儀", ph: k => k.c(0.12, 0.03, 0, 0, 0, mat(C.woodDark)).c(0.015, 0.2, 0, 0.03, 0, mat(C.gold)).s(0.17, 0, 0.38, 0, mat(0x3E7CB1)) },
  chart_board:   { size: [0.8, 1.6, 0.5], zone: "主管室", note: "圖表看板（畫架）", ph: k => k.b(0.04, 1.5, 0.04, -0.3, 0, 0.15, mat(C.woodDark)).b(0.04, 1.5, 0.04, 0.3, 0, 0.15, mat(C.woodDark)).b(0.04, 1.5, 0.04, 0, 0, -0.2, mat(C.woodDark)).b(0.8, 0.6, 0.03, 0, 0.85, 0.12, mat(C.white)).b(0.1, 0.2, 0.01, -0.2, 0.95, 0.14, mat(C.blue)).b(0.1, 0.32, 0.01, -0.05, 0.95, 0.14, mat(C.blue)).b(0.1, 0.42, 0.01, 0.1, 0.95, 0.14, mat(C.orange)) },
  // 休息區
  pool_table:    { size: [2.5, 0.85, 1.4], zone: "休息區", note: "撞球桌", ph: k => k.b(2.5, 0.16, 1.4, 0, 0.68, 0, mat(C.woodDark, { rough: 0.5 })).b(2.26, 0.02, 1.16, 0, 0.84, 0, mat(C.felt, { rough: 1 })).b(0.16, 0.68, 0.16, -1.05, 0, -0.5, mat(C.woodDark)).b(0.16, 0.68, 0.16, 1.05, 0, -0.5, mat(C.woodDark)).b(0.16, 0.68, 0.16, -1.05, 0, 0.5, mat(C.woodDark)).b(0.16, 0.68, 0.16, 1.05, 0, 0.5, mat(C.woodDark)).s(0.03, 0.4, 0.89, 0.1, mat(C.white)).s(0.03, -0.3, 0.89, -0.2, mat(C.red)).s(0.03, -0.2, 0.89, 0.15, mat(C.gold)) },
  foosball:      { size: [1.4, 0.95, 0.75], zone: "休息區", note: "手足球台", ph: k => { k.b(1.2, 0.25, 0.7, 0, 0.62, 0, mat(C.woodDark)).b(1.1, 0.02, 0.6, 0, 0.83, 0, mat(C.green)); for (const x of [-0.5, 0.5]) for (const z of [-0.28, 0.28]) k.b(0.08, 0.62, 0.08, x, 0, z, mat(C.dark)); for (let i = 0; i < 6; i++) k.rod(0.012, 1.0, -0.45 + i * 0.18, 0.78, 0, mat(C.metal)); } },
  beanbag:       { size: [0.9, 0.7, 0.9], zone: "休息區", note: "懶骨頭", ph: k => k.s(0.45, 0, 0.32, 0, mat(C.red, { rough: 1 }), 0.72, 14) },
  sofa:          { size: [2.2, 0.85, 0.9], zone: "休息區", note: "三人沙發", ph: k => k.b(2.2, 0.42, 0.9, 0, 0, 0, mat(C.fabric, { rough: 1 })).b(2.2, 0.45, 0.2, 0, 0.4, -0.35, mat(C.fabric, { rough: 1 })).b(0.2, 0.25, 0.9, -1.0, 0.4, 0, mat(C.fabric, { rough: 1 })).b(0.2, 0.25, 0.9, 1.0, 0.4, 0, mat(C.fabric, { rough: 1 })) },
  armchair:      { size: [0.9, 0.85, 0.85], zone: "休息區", note: "單人沙發椅", ph: k => k.b(0.9, 0.42, 0.85, 0, 0, 0, mat(C.cream, { rough: 1 })).b(0.9, 0.45, 0.18, 0, 0.4, -0.33, mat(C.cream, { rough: 1 })).b(0.15, 0.22, 0.85, -0.38, 0.4, 0, mat(C.cream)).b(0.15, 0.22, 0.85, 0.38, 0.4, 0, mat(C.cream)) },
  rug_large:     { size: [3.2, 0.02, 2.2], zone: "休息區、主管室", note: "大地毯", ph: k => k.b(3.2, 0.015, 2.2, 0, 0, 0, mat(0x2D5D6E, { rough: 1 })).b(3.0, 0.017, 2.0, 0, 0, 0, mat(0x34707F, { rough: 1 })) },
  tv_wall:       { size: [1.8, 1.05, 0.08], zone: "休息區", note: "壁掛電視", ph: k => k.b(1.8, 1.05, 0.06, 0, 0, 0, mat(C.black, { rough: 0.3 })).b(1.7, 0.95, 0.01, 0, 0.05, 0.035, mat(0x284A6E, { emit: 0.3 })) },
  coffee_table:  { size: [1.1, 0.42, 0.6], zone: "休息區", note: "茶几", ph: k => k.b(1.1, 0.05, 0.6, 0, 0.37, 0, mat(C.wood)).b(1.0, 0.37, 0.5, 0, 0, 0, mat(C.woodDark)) },
  // 茶水間
  kitchen_counter: { size: [3.0, 0.92, 0.65], zone: "茶水間", note: "靠牆流理台（含上櫃）", ph: k => k.b(3.0, 0.88, 0.62, 0, 0, 0, mat(C.white)).b(3.04, 0.04, 0.66, 0, 0.88, 0, mat(0x55585C, { rough: 0.4 })).b(3.0, 0.7, 0.35, 0, 1.55, -0.15, mat(C.white)).b(0.5, 0.06, 0.4, 0.6, 0.92, 0, mat(C.metal, { metal: 0.5, rough: 0.3 })) },
  kitchen_island:{ size: [2.2, 0.95, 0.9], zone: "茶水間", note: "中島", ph: k => k.b(2.1, 0.9, 0.8, 0, 0, 0, mat(C.dark)).b(2.2, 0.05, 0.9, 0, 0.9, 0, mat(C.cream, { rough: 0.35 })).b(0.3, 0.2, 0.3, -0.5, 0.95, 0, mat(C.woodLight)).s(0.06, 0.4, 1.0, 0.1, mat(C.orange)).s(0.06, 0.5, 1.0, -0.05, mat(0xD94A3A)) },
  bar_stool:     { size: [0.4, 0.75, 0.4], zone: "茶水間", note: "高腳椅", ph: k => k.c(0.18, 0.02, 0, 0, 0, mat(C.metal)).c(0.025, 0.66, 0, 0.02, 0, mat(C.metal), 6).c(0.19, 0.06, 0, 0.68, 0, mat(C.woodLight), 14) },
  fridge:        { size: [0.8, 1.9, 0.7], zone: "茶水間", note: "冰箱", ph: k => k.b(0.8, 1.9, 0.7, 0, 0, 0, mat(0xC8302C, { rough: 0.35 })).b(0.03, 0.5, 0.03, 0.3, 1.2, 0.36, mat(C.metal)).b(0.76, 0.01, 0.01, 0, 1.25, 0.355, mat(C.dark)) },
  vending_machine: { size: [1.0, 1.9, 0.8], zone: "茶水間", note: "販賣機（前面發光）", ph: k => { k.b(1.0, 1.9, 0.8, 0, 0, 0, mat(0x1F3B5C)).b(0.7, 1.4, 0.02, -0.1, 0.35, 0.4, mat(0xEAF4FF, { emit: 0.55 })); for (let r = 0; r < 5; r++) for (let i = 0; i < 4; i++) k.b(0.12, 0.18, 0.03, -0.35 + i * 0.17, 0.42 + r * 0.27, 0.41, mat([C.red, C.orange, C.green, C.blue][(r + i) % 4])); } },
  water_dispenser: { size: [0.35, 1.3, 0.35], zone: "茶水間", note: "飲水機", ph: k => k.b(0.33, 0.95, 0.33, 0, 0, 0, mat(C.white)).c(0.15, 0.35, 0, 0.95, 0, mat(0x9CC9F0, { opacity: 0.7, rough: 0.2 }), 14) },
  // 廁所
  toilet_stall:  { size: [1.0, 2.0, 1.5], zone: "廁所", note: "廁所隔間（含馬桶）", ph: k => k.b(0.04, 2.0, 1.5, -0.5, 0, 0, mat(0xD8DDE0)).b(0.04, 2.0, 1.5, 0.5, 0, 0, mat(0xD8DDE0)).b(0.96, 2.0, 0.04, 0, 0, 0.73, mat(0xB8C4CC)).b(0.4, 0.4, 0.5, 0, 0, -0.45, mat(C.white, { rough: 0.3 })).b(0.4, 0.4, 0.15, 0, 0.4, -0.68, mat(C.white, { rough: 0.3 })) },
  sink_counter:  { size: [1.6, 0.9, 0.55], zone: "廁所", note: "洗手台＋鏡子", ph: k => k.b(1.6, 0.85, 0.52, 0, 0, 0, mat(C.woodDark)).b(1.62, 0.05, 0.55, 0, 0.85, 0, mat(C.white, { rough: 0.3 })).c(0.16, 0.05, -0.4, 0.86, 0, mat(0xE8ECEF), 14).c(0.16, 0.05, 0.4, 0.86, 0, mat(0xE8ECEF), 14).b(1.4, 0.8, 0.02, 0, 1.2, -0.26, mat(0xBFD6E3, { rough: 0.05, metal: 0.4 })) },
  // 共用
  plant_tall:    { size: [0.6, 1.6, 0.6], zone: "各區", note: "大盆栽", ph: k => k.c(0.24, 0.42, 0, 0, 0, mat(C.pot), 12, 0.2).s(0.42, 0, 0.95, 0, mat(C.leaf, { rough: 1 }), 1.2, 10).s(0.3, 0.12, 1.35, 0.05, mat(0x5FA35A, { rough: 1 }), 1.1, 8) },
  plant_small:   { size: [0.3, 0.45, 0.3], zone: "各區（桌上、櫃上）", note: "小盆栽", ph: k => k.c(0.1, 0.16, 0, 0, 0, mat(C.white), 10, 0.08).s(0.14, 0, 0.27, 0, mat(C.leaf, { rough: 1 }), 1.0, 8) },
  floor_fan:     { size: [0.45, 1.3, 0.35], zone: "工作區、休息區", note: "落地扇", ph: k => k.c(0.18, 0.03, 0, 0, 0, mat(C.white)).c(0.02, 1.0, 0, 0.03, 0, mat(C.white), 6).rod(0.22, 0.08, 0, 1.15, 0, mat(C.white), "z", 16) },
  pendant_lamp:  { size: [0.5, 0.9, 0.5], zone: "各區（天花板吊下）", note: "吊燈（燈罩發暖光；原點在燈罩底）", ph: k => k.c(0.008, 0.6, 0, 0.3, 0, mat(C.dark), 4).cone(0.24, 0.3, 0, 0.02, 0, mat(0xFFD9A0, { emit: 1.2 }), 16) },
  trash_bin:     { size: [0.3, 0.45, 0.3], zone: "各區", note: "垃圾桶", ph: k => k.c(0.14, 0.45, 0, 0, 0, mat(C.dark), 12, 0.12) },
  reception_desk:{ size: [2.6, 1.1, 0.8], zone: "前台", note: "前台櫃台", ph: k => k.b(2.6, 1.05, 0.7, 0, 0, 0, mat(C.woodDark)).b(2.7, 0.06, 0.4, 0, 1.05, 0.2, mat(C.cream, { rough: 0.3 })).b(2.4, 0.6, 0.02, 0, 0.3, 0.36, mat(0xD9A93A, { emit: 0.15 })) },
  door:          { size: [1.0, 2.2, 0.08], zone: "各房間", note: "室內門（玻璃門片）", ph: k => k.b(1.0, 2.2, 0.06, 0, 0, 0, mat(C.dark)).b(0.8, 1.9, 0.02, 0, 0.12, 0.02, mat(0xA9C7D6, { opacity: 0.55, rough: 0.1 })) },
  // 戶外
  tree:          { size: [2.0, 4.0, 2.0], zone: "戶外", note: "樹", ph: k => k.c(0.12, 1.4, 0, 0, 0, mat(0x6B4A2E), 7, 0.09).s(0.95, 0, 2.2, 0, mat(0x3F7A3A, { rough: 1 }), 1.15, 9).s(0.7, 0.35, 2.9, 0.2, mat(0x4E8F44, { rough: 1 }), 1.0, 8) },
  bush:          { size: [1.0, 0.7, 1.0], zone: "戶外", note: "灌木", ph: k => k.s(0.5, 0, 0.35, 0, mat(0x467F3E, { rough: 1 }), 0.75, 9) },
  street_lamp:   { size: [0.4, 3.6, 0.4], zone: "戶外", note: "路燈（燈頭發暖光）", ph: k => k.c(0.06, 3.4, 0, 0, 0, mat(C.dark), 8).b(0.36, 0.12, 0.36, 0, 3.4, 0, mat(C.dark)).b(0.3, 0.06, 0.3, 0, 3.36, 0, mat(0xFFDDA0, { emit: 1.5 })) },
  bench:         { size: [1.6, 0.85, 0.6], zone: "戶外", note: "長椅", ph: k => k.b(1.6, 0.06, 0.45, 0, 0.42, 0, mat(C.wood)).b(1.6, 0.4, 0.05, 0, 0.45, -0.22, mat(C.wood)).b(0.06, 0.42, 0.45, -0.7, 0, 0, mat(C.dark)).b(0.06, 0.42, 0.45, 0.7, 0, 0, mat(C.dark)) },
};

// MARK: - 載入（manifest 有列的才載；其他用佔位）

const fitCache = new Map();
export const Props = {
  base: new URL("../assets/models/", import.meta.url).href,
  glb: new Map(),            // 名稱 → { scene, clips }（已載入）
  ready: null,
  load() {
    if (this.ready) return this.ready;
    this.ready = fetch(this.base + "manifest.json").then(r => (r.ok ? r.json() : { models: [] })).catch(() => ({ models: [] })).then(m => {
      const loader = new GLTFLoader();
      return Promise.all((m.models ?? []).map(file => new Promise(res => {
        loader.load(this.base + file, g => {
          g.scene.traverse(o => { if (o.isMesh) { o.castShadow = true; o.receiveShadow = true; } });
          this.glb.set(file.replace(/\.glb$/, ""), { scene: g.scene, clips: g.animations });
          res();
        }, undefined, () => res());
      })));
    });
    return this.ready;
  },
  /** 這個物件的零件（幾何已經在物件座標、底面中心＝原點）：[[geometry, material]…] */
  parts(name) {
    if (fitCache.has(name)) return fitCache.get(name);
    const spec = PROPS[name];
    if (!spec) return [];
    let out;
    const g = this.glb.get(name);
    if (g) {
      g.scene.updateMatrixWorld(true);
      const box = new THREE.Box3().setFromObject(g.scene), sz = box.getSize(new THREE.Vector3());
      const k = Math.min(spec.size[0] / Math.max(sz.x, 1e-3), spec.size[1] / Math.max(sz.y, 1e-3), spec.size[2] / Math.max(sz.z, 1e-3));
      const fix = new THREE.Matrix4().makeScale(k, k, k).multiply(new THREE.Matrix4().makeTranslation(-(box.min.x + box.max.x) / 2, -box.min.y, -(box.min.z + box.max.z) / 2));
      out = [];
      g.scene.traverse(o => { if (o.isMesh && !o.isSkinnedMesh) out.push([o.geometry.clone().applyMatrix4(fix.clone().multiply(o.matrixWorld)), o.material]); });
    } else {
      const k = new Kit(); spec.ph(k); out = k.parts;
    }
    fitCache.set(name, out);
    return out;
  },
  isModel(name) { return this.glb.has(name); },
  reset() { fitCache.clear(); },
};
