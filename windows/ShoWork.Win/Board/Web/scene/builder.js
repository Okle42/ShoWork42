// OfficeBuilder.swift 照搬（11-01 P0 地基 → 11-02 P8 全檔逐行轉寫）。
// 3D 辦公室第四版的場景：科技大樓剖面（10-20 Kang 拍板，規範 docs/design/office-tower/設計規範.md）。
//   樓層由下往上疊：一樓大廳＋前台保全 → 閒置薄層（只放門牌）→ 有 AI 的專案樓層（固定樓層號）→ 頂樓空中花園。資料來自 BoardModel.tower。
//   一層一個模組（OfficeTower.swift → scene/tower.js）：靜態東西合併成一個 mesh、四面牆各一個節點（面向鏡頭的那面淡掉＝cutaway）、門牌可以換牆。
//   樓層換位置（TowerPlan 變了）：整層像模組一樣往前飄出→升降→插回、其他樓層讓位，約 2 秒，播完停止渲染。
//   角色閒晃照 BoardModel.wander（WanderPlanner）：桌↔電梯↔頂樓↔別人樓層，≤10 fps，視窗被蓋住就直接落地。
//   燈光（office.lighting）：白天／夜晚／自動（10-21 起跟台北真實日出日落連續混合，規範 §3.8.1）；切換只改燈光與材質強度、不重建。
// 省電：沒人在走、沒在搬家、沒人打字時不渲染；樓層內容（主題、桌數、有沒有人）變了才重建那一層。
//
// 轉寫對照（Windows 版的差異）：
//   - SCNAction／SCNTransaction → scene/actions.js（Act、runAction、SCNTransaction.opacity(...)）。畫面迴圈每幀呼叫 Act.tick(dt)，
//     畫之前呼叫 builder.presentBegin()（節點透明度、看板 billboard），畫完 presentEnd()（換回原材質，dump 跟 Mac 一樣記 model 值）。
//   - Date → Unix 秒（number）。資料（TowerPlan、WanderPlan、Island…）照 bench/mac-input.json 的 JSON 形狀讀。
//   - DispatchQueue.main.asyncAfter → setTimeout；BoardWindow.testMode → OfficeBuilder.testMode；Look.reduceMotion → OfficeBuilder.reduceMotion。
//   - OfficeTower.swift 的 TowerModules／TowerCore／TowerLobby／TowerSign／MoveAnim／TripPath 由 tower agent 寫在 scene/tower.js，
//     這裡照 Swift 的呼叫方式用（namespace import：還沒寫好的部分跳過，畫面空著）。
//   - 後製：bloom、vignette 的數值記在 this.post，畫面由 kit.js 的 ScnPost 依 this.post 做。

import * as THREE from "three";
import { VoxMat, TP, TD, TowerSpec, TowerLayout, scnLight, scnNode, setCategory, category, aimDirectional, frontOfEuler, scnIntensity,
         LightMask, skyGlowCube, SColor, enumerateHierarchy, setOpacity, VoxelMesh, Kit, Xf, TM, PixelTex, setEuler } from "../kit.js";
import { SkyLook } from "./solar.js";
import * as Tower from "./tower.js";
import { CityBuilder } from "./city.js";
import * as CityModel from "./city-model.js";
import { OfficeBasement } from "./basement.js";
import { WeatherFX } from "./weather.js";
import { Act, runAction, removeAction, actionForKey, hasActions, removeAllActions, SCNTransaction, syncOpacity, restoreOpacity, opacityOf } from "./actions.js";

const { TowerModules, TowerCore } = Tower;

// 別的 agent 的檔（poof.js、stylefx.js）：還沒寫好時不擋整個場景（載不到就跳過過場）
let PoofMod = null;
import("./poof.js").then(m => { PoofMod = m; }).catch(() => {});

const ns = c => new SColor(c[0], c[1], c[2], 1);
const add = (a, b) => [a[0] + b[0], a[1] + b[1], a[2] + b[2]];
const sub = (a, b) => [a[0] - b[0], a[1] - b[1], a[2] - b[2]];
const mul = (a, k) => [a[0] * k, a[1] * k, a[2] * k];
const dot = (a, b) => a[0] * b[0] + a[1] * b[1] + a[2] * b[2];
const cross = (a, b) => [a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0]];
const norm = a => { const l = Math.hypot(a[0], a[1], a[2]); return [a[0] / l, a[1] / l, a[2] / l]; };
const len3 = a => Math.hypot(a[0], a[1], a[2]);
const sec = d => d === null || d === undefined ? null : d instanceof Date ? d.getTime() / 1000 : Number(d);
const nowSec = () => Date.now() / 1000;
// tower.js（TripPath.CarLeg、TowerCore.runDoor）用 JS Date：交界處換算
const toDate = s => new Date(s * 1000);
const dateLeg = l => ({ y0: l.y0, y1: l.y1, start: toDate(l.start), end: toDate(l.end) });
const dateStops = st => st.map(x => ({ from: toDate(x.from), to: toDate(x.to) }));
const runDoorS = (d, stops, now, g) => sec(TowerCore.runDoor(d, dateStops(stops), toDate(now), g));
const pos3 = n => [n.position.x, n.position.y, n.position.z];
const setPos = (n, p) => n.position.set(p[0], p[1], p[2]);
/** Swift 的 childNode(withName:recursively:) */
const child = (n, name, rec = true) => {
  if (!n) return null;
  if (!rec) return n.children.find(c => c.name === name) ?? null;
  let hit = null;
  n.traverse(c => { if (!hit && c !== n && c.name === name) hit = c; });
  return hit;
};
const shuffled = a => { const b = a.slice(); for (let i = b.length - 1; i > 0; i--) { const j = Math.floor(Math.random() * (i + 1)); [b[i], b[j]] = [b[j], b[i]]; } return b; };
const randIn = (a, b) => a + Math.random() * (b - a);
const randInt = (a, b) => a + Math.floor(Math.random() * (b - a + 1));
const randBool = () => Math.random() < 0.5;
/** SCNNode.insertChildNode(_:at: 0) */
function insertFirst(parent, c) { parent.add(c); parent.children.splice(parent.children.indexOf(c), 1); parent.children.unshift(c); }

// MARK: - ShoWorkCore 的小東西（Wander.swift 的 TowerLayout 座位、WanderSpot、Islands、卡片文字）
// kit.js 的 TowerLayout 只有數字；座位／站位的函式照 ShoWorkCore/Wander.swift 寫在這

/** WanderSpot（JSON："desk"｜{$case:"roof", $value:{slot}}｜{$case:"visit", $value:{floor, host}}…） */
export const Spot = {
  kind: s => typeof s === "string" ? s : s?.$case ?? "desk",
  slot: s => typeof s === "object" && s ? (s.$value?.slot ?? 0) : 0,
  isB1: s => Spot.kind(s) === "b1",
};

export const TowerLayoutCore = {
  ...TowerLayout,
  b1Floor: "b1",
  b1Y: -5.6,
  /** 每層從不同的區開始坐：FNV-1a 64 雜湊樓層 id 出 0–3 */
  spin(floor) {
    if (!floor) return 0;
    let h = 0xcbf29ce484222325n;
    for (const b of new TextEncoder().encode(floor)) { h ^= BigInt(b); h = (h * 0x100000001B3n) & 0xFFFFFFFFFFFFFFFFn; }
    return Number(h % 4n);
  },
  desk(i, n, floor = "") {
    const fd = TowerLayout.freeDesks;
    i = Math.min(Math.max(i, 0), fd.length - 1);
    const k = TowerLayoutCore.spin(floor);
    return fd[Math.trunc(i / 4) * 4 + (i % 4 + k) % 4];
  },
  /** 角色坐的位置（桌子後方 chairBack，順著朝向）。13 個以上：多的站前帶（z 2.2，間距 1.0，面向鏡頭） */
  seat(i, n, floor = "") {
    if (i >= 12) {
      const k = i - 12, m = n - 12;
      return { x: 0.1 + (k - (m - 1) / 2) * 1.0, z: 2.2, a: 0 };
    }
    const d = TowerLayoutCore.desk(i, Math.min(n, 12), floor);
    return { x: d.x - TowerLayout.chairBack * Math.sin(d.a), z: d.z - TowerLayout.chairBack * Math.cos(d.a), a: d.a };
  },
  roofSlot(i) {
    const fixed = [[-4.4, 1.1], [-2.7, 1.1], [2.4, 0.65], [4.1, 0.65], [-1.0, 0.1], [0.7, 0.2], [-0.2, 1.55]];
    if (i < fixed.length) return { x: fixed[i][0], z: fixed[i][1] };
    const k = i - fixed.length;
    return { x: -4.6 + (k % 6) * 1.75, z: -1.4 };
  },
  cafeSlot(i) {
    const bz = TowerSpec.backInner;
    const fixed = [[-4.4, bz + 1.4, 0], [-2.65, bz + 1.4, 0], [2.05, bz + 1.3, Math.PI], [3.8, bz + 1.3, Math.PI], [-0.95, bz + 1.7, 0.4], [0.95, bz + 1.7, -0.4]];
    if (i < fixed.length) return { x: fixed[i][0], z: fixed[i][1], a: fixed[i][2] };
    const k = i - fixed.length;
    return { x: -4.4 + (k % 3) * 1.75, z: bz + 2.45, a: 0 };
  },
  get b1Center() { return { x: 0, z: TowerSpec.front - TowerSpec.depth / 2 }; },
  b1Ring: 3.0, b1Outer: 4.1, b1WalkR: 3.55,
  b1Inner: [0, -0.25, 0.25, -0.5, 0.5, -0.75, 0.75, 1].map(x => x * Math.PI),
  b1OuterAngles: [0.375, -0.375, 0.625, -0.625, 0.875, -0.875].map(x => x * Math.PI),
  b1Front: [{ x: -3.5, z: 2.35 }, { x: 3.5, z: 2.35 }],
  b1Polar(i) {
    const L = TowerLayoutCore;
    if (i < L.b1Inner.length) return { phi: L.b1Inner[i], r: L.b1Ring };
    const k = i - L.b1Inner.length;
    if (k < L.b1OuterAngles.length) return { phi: L.b1OuterAngles[k], r: L.b1Outer };
    const f = k - L.b1OuterAngles.length;
    if (f < L.b1Front.length) return null;
    return { phi: L.b1OuterAngles[(f - L.b1Front.length) % L.b1OuterAngles.length], r: L.b1WalkR };
  },
  b1Point(phi, r) { const c = TowerLayoutCore.b1Center; return { x: c.x + r * Math.sin(phi), z: c.z - r * Math.cos(phi) }; },
  b1Slot(i) {
    const L = TowerLayoutCore, c = L.b1Center;
    const pr = L.b1Polar(Math.max(0, i));
    const p = pr ? L.b1Point(pr.phi, pr.r) : L.b1Front[(Math.max(0, i) - L.b1Inner.length - L.b1OuterAngles.length) % L.b1Front.length];
    return { x: p.x, z: p.z, a: Math.atan2(c.x - p.x, c.z - p.z) };
  },
};

/** TowerFloor.projectId */
export const projectId = name => "p:" + String(name).toLowerCase();
/** TowerPlan 的計算屬性 */
export const Plan = {
  totalHeight: p => { const l = p.floors[p.floors.length - 1]; return l ? l.y + l.height : 0; },
  projectFloors: p => p.floors.filter(f => f.kind === "project"),
  floor: (p, id) => p.floors.find(f => f.id === id) ?? null,
  floorOfProject: (p, project) => Plan.floor(p, projectId(project)),
  /** TowerPlan.moves(from:to:) */
  moves(old, nw) {
    const a = Plan.projectFloors(old).map(f => f.id), b = Plan.projectFloors(nw).map(f => f.id);
    const common = a.filter(x => b.includes(x)), commonNew = b.filter(x => a.includes(x));
    const out = [];
    for (const f of Plan.projectFloors(nw)) {
      const oi = old.floors.findIndex(x => x.id === f.id), ni = nw.floors.findIndex(x => x.id === f.id);
      const reordered = oi >= 0 && common.indexOf(f.id) !== commonNew.indexOf(f.id);
      if (oi < 0 || reordered) out.push({ project: f.project ?? f.id, floorId: f.id, fromIndex: oi < 0 ? null : oi, toIndex: ni < 0 ? null : ni, fromY: oi < 0 ? null : old.floors[oi].y, toY: f.y });
    }
    for (const f of Plan.projectFloors(old)) if (!Plan.floor(nw, f.id)) {
      out.push({ project: f.project ?? f.id, floorId: f.id, fromIndex: old.floors.findIndex(x => x.id === f.id), toIndex: null, fromY: f.y, toY: null });
    }
    return out;
  },
};

/** 卡片狀態色（KuboArt.tint）：設定面板的狀態光顏色（GlowSettings 預設值）；Windows 的設定可以改 KuboArt.looks */
export const KuboArt = {
  clay: VoxMat.color(0xD97757), clayDark: VoxMat.color(0xB35C3F), stuckOrange: VoxMat.color(0xFF6A00),
  looks: { working: 0x9E66FF, input: 0xFF4040, done: 0x30D158 },
  /** NSColor.systemGray（淺色外觀） */
  systemGray: VoxMat.color(0x8E8E93),
  tint(m) {
    switch (m) {
      case "working": return VoxMat.color(KuboArt.looks.working);
      case "waiting": return VoxMat.color(KuboArt.looks.input);
      case "finished": return VoxMat.color(KuboArt.looks.done);
      case "stuck": return KuboArt.stuckOrange;
      default: return KuboArt.systemGray;
    }
  },
};

export const BlockedReason = {
  symbol: r => ({ permission: "🔒", rateLimit: "⏳", apiError: "⚠️", testRun: "🧪", build: "🔨", install: "📦", unknown: "?" })[r] ?? "?",
  label: r => ({ permission: "等你按允許", rateLimit: "額度用完，等重置", apiError: "API 錯誤", testRun: "測試跑很久", build: "建置跑很久", install: "安裝跑很久", unknown: "原因不明" })[r] ?? "原因不明",
};
/** token 數縮寫：850、12K、1.2M、3.4B */
export function tokenShort(n) {
  const d = n;
  if (n < 1000) return `${n}`;
  if (n < 1_000_000) return d < 10_000 ? `${(d / 1e3).toFixed(1)}K` : `${Math.trunc(n / 1000)}K`;
  if (n < 1_000_000_000) return d < 10_000_000 ? `${(d / 1e6).toFixed(1)}M` : `${Math.trunc(n / 1_000_000)}M`;
  return `${(d / 1e9).toFixed(1)}B`;
}
/** BoardCard.tokens.total（TokenUsage.total＝input＋output＋cacheCreation＋cacheRead） */
const tokTotal = t => t.total ?? ((t.input ?? 0) + (t.output ?? 0) + (t.cacheCreation ?? 0) + (t.cacheRead ?? 0));
/** 一句話任務回報：要你決定的事 ＞ AI 自報摘要 ＞ AI 最後說的話 ＞ 欄位理由 */
export function bubbleLine(c) {
  if (c.handover && !c.report?.ask) return `🔁 ${c.handover}` + (c.report?.summary ? `：${c.report.summary}` : "");
  return c.report?.ask ? `要你決定：${c.report.ask}` : c.report?.summary ?? c.detail ?? c.reason ?? "";
}
/** 卡住／等你的原因放在一句回報前面（看板那一列、細節卡） */
export function officeLine(c) {
  const r = c.blockedReason;
  if (!r) return bubbleLine(c);
  return `${BlockedReason.symbol(r)} ${BlockedReason.label(r)}・${bubbleLine(c)}`;
}
/** ContextGuard.over：context 用到 tokenLimit 以上（預設 250k） */
export const ContextGuard = { tokenLimit: 250_000, over: (c, limit = ContextGuard.tokenLimit) => (c.tokens ?? 0) >= limit };
/** Island.count(mood) */
const islandCount = (i, m) => i.people.filter(p => p.mood === m).length;

// MARK: - OfficeBuilder

export class OfficeBuilder {
  static dayBg = VoxMat.color(TP.skyDay);
  static nightBg = VoxMat.color(TP.skyNight);
  /** 目前的天空地平線色（視窗底色、霧色；日出日落時跟著天色走） */
  static bg = OfficeBuilder.dayBg;
  /** 戶外的東西（城市、大地面）：categoryBitMask 拿掉第 0 位元 ⇒ 室內暖補光照不到（主光、環境光照得到） */
  static outdoorMask = 1 << 4;
  /** 夜晚室內暖補光強度（白天 fill 340）：每層有自己的燈之後只留一點，讓背光面不全黑 */
  static nightFill = 60;
  /** 專案樓層每層一盞室內燈的強度（頂樓 700；10-25 Kang 選 500） */
  static floorOmni = 500;
  /** 大廳那盞（10-25 Kang：700 → 900） */
  static lobbyOmni = 900;
  /** 每層室內燈的衰減終點（公尺） */
  static floorRange = 11;
  /** 測試：10-25 以前的夜晚燈光（量測對照用） */
  static legacyNight = false;
  /** 每層室內燈的光照位元：第 i 個專案樓層用 bit 8+(i%16)（SceneKit 每個 geometry 最多吃 8 盞燈） */
  static floorLightBit(i) { return 1 << (8 + i % 16); }
  static floorLightBits = Array.from({ length: 16 }, (_, i) => 1 << (8 + i)).reduce((a, b) => a | b, 0);
  static maxPeople = 16;
  static kuboScale = TowerSpec.kuboScale;
  /** 樓層看板只在鏡頭夠近時顯示（鏡頭停下來才算一次） */
  static boardDistance = 30;
  /** 點擊只找角色與保全（categoryBitMask 第 2 位元） */
  static pickMask = 2;
  /** cutaway：牆的外法線跟鏡頭方向的內積超過這個就淡掉 */
  static cutDot = 0.25;
  /** 牆淡出的秒數（bench 設 0） */
  static cutFade = 0.25;
  /** BoardWindow.testMode（測試視窗／bench：鏡頭直接定位、不排微動作與巡邏） */
  static testMode = false;
  /** Look.reduceMotion（系統「減少動態效果」） */
  static get reduceMotion() { return typeof matchMedia === "function" && matchMedia("(prefers-reduced-motion: reduce)").matches; }
  /** HeatGate.shared.paused（太熱暫停；Windows 沒有 ⇒ false，可由外面設） */
  static heatPaused = false;
  /** 測試：所有電梯門定格開幾成（SHOWORK_OFFICE_DOOR）；測試：路上的人定在行程第幾秒（SHOWORK_OFFICE_TRIP_T）；巡邏第幾秒（SHOWORK_OFFICE_PATROL） */
  static testDoor = null;
  static testTripT = null;
  static testPatrol = null;
  /** SHOWORK_OFFICE_TRACE */
  static trace = false;
  /** 主光（美術角度）：SCNVector3(-0.927, -0.885, 0)；光行進方向 ≈ (0.465, −0.800, −0.380) */
  static sunEuler = [-0.927, -0.885, 0];
  /** 真實太陽 → 世界座標：再轉 25.7°（美術主光對到 10 月台北 12:30 左右的太陽） */
  static compassOffset = 25.7;
  static worldAngle(azimuth) { return (azimuth + OfficeBuilder.compassOffset) * Math.PI / 180; }
  /** 美術主光的水平方向（≈ 230.7°） */
  static get artAngle() {
    const f = frontOfEuler(...OfficeBuilder.sunEuler), toSun = [-f.x, -f.y, -f.z];
    let a = Math.atan2(toSun[0], -toSun[2]); if (a < 0) a += 2 * Math.PI; return a;
  }
  /** 靜態假影子的方向：每 1 公尺高往水平方向位移多少（x, z） */
  static get shadowStep() { const f = frontOfEuler(...OfficeBuilder.sunEuler); return [f.x / -f.y, f.z / -f.y]; }
  /** 0→1 的平滑過渡（a→b，a 可以比 b 大） */
  static smooth(a, b, x) { const t = Math.min(1, Math.max(0, (x - a) / (b - a))); return t * t * (3 - 2 * t); }
  /** 畫面風格：voxel（預設）／diorama；微縮模型改用等角視角 */
  static style = "voxel";
  static baseAzimuth = 16;
  static baseElevation = 12;
  static get azimuth() { return OfficeBuilder.style === "diorama" ? 35 : OfficeBuilder.baseAzimuth; }
  static get elevation() { return OfficeBuilder.style === "diorama" ? 15 : OfficeBuilder.baseElevation; }
  /** 還沒讀到資料前：只有大廳和頂樓 */
  static fallback = { floors: [
    { kind: "lobby", id: "lobby", floorNo: "01", y: 0, height: TowerSpec.lobbyHeight, plates: [], seats: 0, active: false },
    { kind: "roof", id: "roof", floorNo: "RF", y: TowerSpec.lobbyHeight, height: TowerSpec.roofHeight, plates: [], seats: 0, active: false }] };

  constructor({ aspect = 1.6 } = {}) {
    LightMask.install();
    this.scene = new THREE.Scene();
    this.world = scnNode();
    this.scene.add(this.world);
    this.env = TowerCore.environment();
    setCategory(this.env, OfficeBuilder.outdoorMask);
    this.world.add(this.env);
    this.core = scnNode(); this.coreFacades = []; this.coreSig = "";
    /** 兩部電梯車廂（10-22 Kang：兩部電梯、搭電梯不要破圖）：第 c 部在 TD.elevs[c] */
    this.cars = TD.elevs.map(e => { const c = TowerCore.car() ?? scnNode("car"); c.position.set(e.x, TD.room, e.y); return c; });
    /** 每部車廂排好的上下段落＋最後停在哪層 */
    this.carLegs = this.cars.map(() => []); this.carRest = this.cars.map(() => "lobby");
    for (const c of this.cars) this.world.add(c);
    /** 外部空間城市（OfficeCity.swift → scene/city.js） */
    this.city = new CityBuilder();
    /** 地下室 B1 機房＋浮空神經網路（OfficeBasement.swift → scene/basement.js） */
    this.basement = new OfficeBasement();
    for (let c = 0; c < TD.elevs.length; c++) {      // B1 的電梯門（吃 B1 自己的冷光）
      const d = TowerCore.landingDoor(c);
      if (!d) continue;
      TowerCore.setDoor(d, OfficeBuilder.testDoor ?? 0);
      enumerateHierarchy(d, n => { if (n.isMesh) setCategory(n, (category(n) & ~1) | OfficeBasement.mask); });
      this.basement.root.add(d);
    }
    /** 搬家動畫掛在這個節點上跑 */
    this.driver = scnNode();
    this.world.add(this.driver);
    this.world.add(this.city.root);
    this.world.add(this.basement.root);
    this.ambient = scnLight({ type: "ambient" });
    this.scene.add(this.ambient);
    this.sun = scnLight({ type: "directional", mask: ~OfficeBasement.mask, euler: OfficeBuilder.sunEuler });     // 太陽照不進地下室（B1 只吃自己的冷光）
    this.scene.add(this.sun);
    // 室內暖補光（10-21 主光改版）：只照大樓（第 0 位元）；ambient 不吃位元 ⇒ 用 directional
    this.fill = scnLight({ type: "directional", mask: 1, euler: [-0.45, 0.2, 0], color: 0xFFE2BE });
    this.scene.add(this.fill);
    // 夜晚戶外月光補光（只照城市、大地面；從右前上方，跟主光對側）
    this.moonFill = scnLight({ type: "directional", mask: OfficeBuilder.outdoorMask, euler: [-0.85, 0.55, 0], color: 0x8E9CC4 });
    this.scene.add(this.moonFill);
    /** 夜晚 omni：大廳、頂樓各 1＋每個專案樓層 1（assignOmni 不夠才補） */
    this.omni = [];
    // 鏡頭：fov 34（垂直）、zNear 1、zFar 500；HDR、bloomThreshold 0.8、bloomBlurRadius 8
    this.camera = new THREE.PerspectiveCamera(34, aspect, 1, 500);
    this.aspect = aspect;
    this.scene.add(this.camera);
    /** 雨與閃電（OfficeRain.swift → scene/weather.js） */
    this.weatherFX = new WeatherFX();
    this.weatherFX.attach(this.camera, this.scene);
    /** SceneKit 相機的後製參數（ScnPost 照這組畫） */
    this.post = { hdr: true, bloom: 0, bloomThreshold: 0.8, bloomBlur: 8, vignette: 0, vignettePower: 1 };
    /** Swift 的 v.defaultCameraController.target */
    this.target = [0, 0, 0];
    this.fogStart = 0; this.fogEnd = 0; this.fogDist = -1;
    this.omniBase = 700;
    this.underground = false;

    this.modules = new Map();          // id → { parts, key, floor }
    this.tower = { floors: [] };
    this.decor = {};
    /** 一個角色：外觀（造型＋坐站）與位置分開記；只有位置變就搬節點，不重建 */
    this.persons = new Map();          // id → { node, look, place, mood, islander, floor, seat, seats }
    this.tripsDone = new Set();        // 播完的行程（等下次刷新清掉前不要重播）
    this.ghosts = new Map();           // floor id → { node, key }
    this.boards = new Map();           // floor id → { node, key }
    this.guardNode = null;
    this.guardKey = "";
    this.lit = null;
    this.lastWander = { states: {}, started: [], snapped: [], cars: [] };
    /** 場景裡有沒有一直在跑的動畫（「改檔」打字、保全掃描中轉天線）；有才持續渲染 */
    this.looping = false;
    /** 搬家／閒晃播到什麼時候（秒；畫面迴圈依這兩個決定幀率：搬家 24、閒晃 10） */
    this.moveUntil = -Infinity;
    this.walkUntil = -Infinity;
    this.moving = null;
    this.leaving = [];
    /** 這次更新新加、會自己停的動畫最長要播幾秒（跳三下、搖一下、搬家、閒晃） */
    this.transient = 0;
    this.look = null;
    this.lastApply = -Infinity;
    this.gridStage = "normal";
    this.gridSet = false;
    this.emergency = null; this.emergencySig = "";
    this.cooler = null; this.coolerSig = "";
    this.floorGlow = null;
    this.peopleSeeded = false;
    this.fidgetStarted = false;
    this.patrolling = false; this.patrolGen = 0; this.patrolStart = null; this.wasScanning = false;
    this.boardStale = new Map(); this.boardsDrawn = 0;
    this.lodDirty = true; this.lodAt = [0, 0, 0]; this.cutSig = ""; this.omniDirty = true; this.focusY = 0;
    this.cutV = null; this.cutFar = 0;
    this.framedOnce = false;
    /** 保全等級（取景要不要把大廳框進來：注意以上才框） */
    this.guardLevel = "normal";
    this._plinth = null;
    this._timers = new Set();
    LightMask.attach(this.scene);
    this.applyLights();
  }

  takeTransient() { const t = this.transient; this.transient = 0; return t; }
  bump(s) { this.transient = Math.max(this.transient, s); }
  /** DispatchQueue.main.asyncAfter（秒） */
  after(s, f) { const id = setTimeout(() => { this._timers.delete(id); f(); }, Math.max(0, s * 1000)); this._timers.add(id); return id; }
  /** 收掉所有排好的計時器（換場景、關視窗時） */
  dispose() { for (const id of this._timers) clearTimeout(id); this._timers.clear(); }

  // MARK: 燈光（規範 §3.8）

  /** 白天／夜晚固定（bench、舊呼叫）＝改版前的兩組燈光 */
  setNight(n) { return this.setLook(n ? SkyLook.night : SkyLook.day); }

  /** 微縮模型（10-22 Kang「跟體素太像」）：拿掉 1600 m 大地面，整座城放在一塊有木頭邊的底座上；底座外面由後製畫成桌面 */
  get plinth() {
    if (this._plinth) return this._plinth;
    const m = new VoxelMesh(), k = new Kit(m);
    const x0 = -33, x1 = (CityBuilder.harborX1 ?? 0) + 1, z0 = -15, z1 = (CityBuilder.waterZ1 ?? 0) + 1;   // 含港口水面（11-01 港口搬到正門對面）
    k.b(Xf.identity, (x0 + x1) / 2, -0.4, (z0 + z1) / 2, x1 - x0, 0.4, z1 - z0, VoxMat.dayNight(TP.groundDay, TP.groundNight));
    k.b(Xf.identity, (x0 + x1) / 2, -1.8, (z0 + z1) / 2, x1 - x0 + 0.6, 1.4, z1 - z0 + 0.6, VoxMat.dayNight(0x9A6A40, 0x4A3220));
    const n = m.node("plinth"); setCategory(n, OfficeBuilder.outdoorMask);
    return (this._plinth = n);
  }
  setStyle(s) {
    const dio = s === "diorama";
    this.env.visible = !dio;
    if (dio) { if (!this.plinth.parent) this.world.add(this.plinth); } else this.plinth.removeFromParent();
    this.city.setSkylineHidden(dio);            // 周邊高樓在底座外面，微縮模型風格不畫（11-01）
  }

  /** 日出日落（10-21，規範 §3.8.1）：天色依太陽仰角連續混合。只改燈光參數、背景、共用材質，不重建節點。
   *  跟上次差很少（仰角 < 0.2°、方位角 < 0.5°）就不動（回 false ⇒ 不重畫） */
  setLook(l) {
    const o = this.look;
    if (o && OfficeBuilder.close(o, l) && this.lastApply !== -Infinity) return false;
    // 晨昏時天色一直在變：同一段過渡裡最多 55 秒套一次；切換白天／夜晚／自動立刻套
    if (o && nowSec() - this.lastApply < 55 && (o.sunDir === null) === (l.sunDir === null) && o !== SkyLook.day && o !== SkyLook.night
        && l !== SkyLook.day && l !== SkyLook.night && Math.abs(o.dark - l.dark) < 0.05 && Math.abs(o.lamps - l.lamps) < 0.05) return false;
    this.look = l; this.lastApply = nowSec();
    this.applyLights();
    if (OfficeBuilder.testMode && OfficeBuilder.trace) console.log(`sky apply dark=${l.dark.toFixed(3)} lamps=${l.lamps.toFixed(3)} el=${l.sunDir ? l.sunDir.elevation.toFixed(2) : "-"}`);
    return true;
  }
  /** 天氣（10-21，規範 §3.8.2）：雨／閃電交給 WeatherFX。換天氣要在 setLook 之前呼叫：有變就讓接下來那次 setLook 不被 55 秒節流擋掉 */
  setWeather(w) {
    if (!this.weatherFX.set(w)) return false;
    this.lastApply = -Infinity;
    return true;
  }

  static close(a, b) {
    if (a === b) return true;
    if ((a.sunDir === null) !== (b.sunDir === null)) return false;
    if (a.sunDir && b.sunDir && (Math.abs(a.sunDir.elevation - b.sunDir.elevation) >= 0.2 || Math.abs(a.sunDir.azimuth - b.sunDir.azimuth) >= 0.5)) return false;
    const mx = (p, q) => Math.max(...p.map((x, i) => Math.abs(x - q[i])));
    return Math.abs(a.dark - b.dark) < 0.004 && Math.abs(a.lamps - b.lamps) < 0.004 && Math.abs(a.keyIntensity - b.keyIntensity) < 3
      && Math.abs(a.ambientIntensity - b.ambientIntensity) < 3 && mx(a.horizon, b.horizon) < 0.004
      && mx(a.keyColor, b.keyColor) < 0.004 && Math.abs((a.overcast ?? 0) - (b.overcast ?? 0)) < 0.01;
  }

  get gridScale() { return { normal: 1, dim: 0.6, flicker: 0.35, blackout: 0 }[this.gridStage] ?? 1; }

  applyLights() {
    const l = this.look ?? SkyLook.day;
    const fixedDay = l === SkyLook.day, fixedNight = l === SkyLook.night;
    VoxMat.setBlend(l.dark, l.lamps);
    Tower.TowerSign?.setDark?.(l.dark);
    this.updateBeam();
    // 漸層天空盒＋霧（霧色＝地平線色＝天空盒下半）；霧距跟鏡頭距離走（updateLOD 鏡頭停下時才算）
    if (fixedDay || fixedNight) {
      this.scene.background = fixedNight ? TowerCore.skyNight : TowerCore.skyDay;
      OfficeBuilder.bg = fixedNight ? OfficeBuilder.nightBg : OfficeBuilder.dayBg;
    } else {
      const az = l.sunDir ? OfficeBuilder.worldAngle(l.sunDir.azimuth) : OfficeBuilder.artAngle;
      if (this.scene.background && this.scene.background !== TowerCore.skyDay && this.scene.background !== TowerCore.skyNight) this.scene.background.dispose?.();
      this.scene.background = skyGlowCube(l.horizon, l.zenith, l.glow, l.glowAmount, az);
      OfficeBuilder.bg = ns(l.horizon);
    }
    this.applyFog();
    // 大地面底色
    const g = VoxMat.dayNight(TP.groundDay, TP.groundNight);
    (fixedDay ? VoxMat.color(TP.groundDay) : fixedNight ? VoxMat.color(TP.groundNight) : ns(l.ground)).toThree(g.color);
    // 冷暖分光：環境光冷、太陽暖（日）；夜晚月光藍＋冷環境光，暖光只留給大樓室內（焦點）
    this.ambient.intensity = scnIntensity(l.ambientIntensity);
    ns(l.ambientColor).toThree(this.ambient.color);
    this.sun.intensity = scnIntensity(l.keyIntensity);
    ns(l.keyColor).toThree(this.sun.color);
    // 主光方向：真實太陽（東升西落、仰角跟著變，最低 3°）；白天固定／夜晚月光＝美術角度
    if (l.sunDir) {
      const el = l.sunDir.elevation * Math.PI / 180, th = OfficeBuilder.worldAngle(l.sunDir.azimuth);
      const toSun = [Math.cos(el) * Math.sin(th), Math.sin(el), -Math.cos(el) * Math.cos(th)];
      aimDirectional(this.sun, new THREE.Vector3(-toSun[0], -toSun[1], -toSun[2]));
    } else {
      aimDirectional(this.sun, frontOfEuler(...OfficeBuilder.sunEuler));
    }
    const ps = this.gridScale;
    VoxMat.setPower(ps);
    // 10-25 Kang：每層一盞 omni（assignOmni），補光夜晚只開一點，讓背光面不全黑
    const fillI = l.fill + (OfficeBuilder.legacyNight ? 0 : OfficeBuilder.nightFill) * l.lamps;
    this.fill.intensity = scnIntensity(fillI * (0.4 + 0.6 * ps));
    this.fill.visible = !(fillI <= 0);
    this.moonFill.intensity = scnIntensity(l.moonFill);
    this.moonFill.visible = !(l.moonFill <= 0);
    // 靜態假影子是照美術主光方向烤好的：太陽轉到別的方向、或太低，就淡掉（夜晚那組保持原樣）
    let kDay = 1.0;
    if (l.sunDir) {
      let diff = Math.abs(OfficeBuilder.worldAngle(l.sunDir.azimuth) - OfficeBuilder.artAngle) % (2 * Math.PI);
      if (diff > Math.PI) diff = 2 * Math.PI - diff;
      kDay = OfficeBuilder.smooth(100, 45, diff * 180 / Math.PI) * OfficeBuilder.smooth(4, 15, l.sunDir.elevation);
    } else if (!fixedDay && l.dark >= 0.5) kDay = 0;      // 月光（仰角 −4° 以下）；天氣變暗的白天 dark ≤ 0.45 不算
    // 雲遮住太陽：假影子跟著淡（晴天 overcast 0 ⇒ 不變）
    const k = Math.max(kDay, OfficeBuilder.smooth(0.5, 0.95, l.dark)) * (1 - (l.overcast ?? 0));
    for (const m of [CityBuilder.shade, CityBuilder.shadeOut]) { const t = k < 1; if (m.transparent !== t) m.needsUpdate = true; m.transparent = t; m.opacity = k; }
    // 夜晚：bloom、四角壓暗；燈開始亮就開 HDR。地下室（神經網路、機櫃 LED）不分日夜一律開
    this.post.bloom = this.underground ? 0.9 : 0.6 * l.lamps * ps;
    this.post.hdr = this.underground || l.lamps > 0.001;
    this.basement.setPower(ps);
    this.post.vignette = 0.35 * l.dark;
    this.post.vignettePower = 1.0;
    this.omniBase = 700 * l.lamps * ps;
    this.weatherFX.setDark(l.dark);
    this.city.setDark(l.dark);          // 周邊高樓的窗戶燈（11-01）：暗下來才亮
    this.omniDirty = true;
    this.assignOmni();
  }

  /** SceneKit 的 fogStart／End＝0 ⇒ 沒有霧；three 的 Fog(0,0) 會整片霧 ⇒ 還沒算過霧距前不掛 */
  applyFog() {
    if (this.fogEnd > 0) {
      if (!this.scene.fog) this.scene.fog = new THREE.Fog(0xffffff, 1, 2);
      OfficeBuilder.bg.toThree(this.scene.fog.color);
      this.scene.fog.near = this.fogStart; this.scene.fog.far = this.fogEnd;
    } else this.scene.fog = null;
  }

  // MARK: 更新

  /**
   * 樓層內容（主題、桌數、有沒有人、門牌）變了才重建那一層；樓層換位置播搬家；狀態變只換那個人／那面看板。
   * `animate`＝視窗看得到、不是測試視窗、沒開「減少動態效果」（不然一律直接跳到結果）。回傳 "none"｜"layout"｜"size"（Reframe）
   */
  update(newPlan, decor, wander, islands, guardStatus, scanning, animate, now = new Date()) {
    now = sec(now);
    wander = wander ?? { states: {}, started: [], snapped: [], cars: [] };
    islands = islands ?? [];
    guardStatus = guardStatus ?? { level: "normal", hasData: false };
    const plan = !newPlan?.floors?.length ? OfficeBuilder.fallback : newPlan;
    const old = this.tower;
    const first = this.modules.size === 0;
    const sig = p => JSON.stringify(p.floors.map(f => `${f.id}@${f.y}`));
    const structural = sig(plan) !== sig(old);
    if (structural && this.moving) this.finishMove();
    this.decor = decor ?? {};
    this.tower = plan;
    this.guardLevel = guardStatus.level ?? "normal";

    // 1. 模組：內容變了的重建（位置先放舊的 y，等一下統一處理）
    const created = new Set();
    for (const f of plan.floors) {
      const key = this.moduleKey(f);
      const m = this.modules.get(f.id);
      if (m && m.key === key) { m.floor = f; continue; }
      const parts = this.buildModule(f);
      if (f.kind === "lobby") {       // 10-25 1 樓正門：對開電動側滑玻璃門
        const d = TowerCore.frontDoor(); if (d) { TowerCore.setDoor(d, OfficeBuilder.testDoor ?? 0, "front"); parts.node.add(d); }
      }
      if (f.kind !== "idle") {        // 10-25 電梯玻璃滑門（薄層沒有電梯門洞）
        for (let c = 0; c < TD.elevs.length; c++) { const d = TowerCore.landingDoor(c); if (d) { TowerCore.setDoor(d, OfficeBuilder.testDoor ?? 0); parts.node.add(d); } }
      }
      if (m) {
        parts.node.position.copy(m.parts.node.position);
        m.parts.node.removeFromParent();
        if (this.guardNode?.parent === m.parts.node) { this.guardNode = null; this.guardKey = ""; }
      } else {
        parts.node.position.set(0, f.y, 0);
        created.add(f.id);
      }
      this.cutNow(parts);
      this.world.add(parts.node);
      this.modules.set(f.id, { parts, key, floor: f });
      this.boards.delete(f.id); this.ghosts.delete(f.id);
      this.lodDirty = true; this.cutSig = ""; this.omniDirty = true;      // 新樓層要分到自己的燈、自己的光照位元
      if (OfficeBuilder.trace) console.log("office rebuild floor", f.id, `boxes=${parts.boxes}`);
    }
    const gone = [...this.modules.keys()].filter(id => !plan.floors.some(f => f.id === id));

    // 2. 位置：第一次／不能播 ⇒ 直接到位；樓層換位置 ⇒ 搬家動畫
    const moves = first ? [] : Plan.moves(old, plan);
    if (structural && animate && !first && !OfficeBuilder.reduceMotion && Tower.MoveAnim) {
      this.startMove(old, plan, moves, created, gone);
    } else {
      for (const id of gone) { this.modules.get(id)?.parts.node.removeFromParent(); this.modules.delete(id); }
      for (const f of plan.floors) { const m = this.modules.get(f.id); if (m) { m.parts.node.position.set(0, f.y, 0); m.parts.node.rotation.y = 0; } }
    }
    for (const id of gone) if (this.modules.has(id) && !this.moving) { this.modules.get(id).parts.node.removeFromParent(); this.modules.delete(id); }
    if (structural && OfficeBuilder.trace) console.log("office tower", plan.floors.map(f => f.id), "moves", moves.map(m => m.floorId));

    // 3. 電梯井、溜滑梯、結構柱：大樓高度變了才重建（搬家中用比較高的那個）
    const top = Math.max(Plan.totalHeight(plan), !this.moving ? 0 : Plan.totalHeight(old));
    const roofY = Plan.floor(plan, "roof")?.y ?? 0;
    this.rebuildCore(top, roofY);
    if (structural) this.omniDirty = true;
    this.assignOmni();        // 10-25：樓層讀進來之後沒有重新分燈 ⇒ 只有大廳、頂樓有燈（鏡頭動了才補上）

    // 4. 人、影分身、看板、保全
    const byKey = new Map();
    for (const i of islands) { const k = String(i.project).toLowerCase(); if (!byKey.has(k)) byKey.set(k, i); }
    if (structural && this.moving) this.snapTravelers();
    this.lastWander = wander;
    this.updatePeople(islands, wander, animate && !this.moving, now);
    this.updateGhosts(byKey);
    this.updateBoards(byKey);
    this.updateGuard(guardStatus, scanning);
    this.updateEmergency();
    this.updateCooler(this.city.state?.power);
    this.highlight(this.lit);
    if (!this.fidgetStarted) { this.fidgetStarted = true; this.scheduleFidget(); }
    this.looping = !OfficeBuilder.reduceMotion && (scanning || this.weatherFX.raining || [...this.persons.values()].some(p => p.mood === "working" && p.islander.card.activity === "editing"));
    if (first) return "layout";
    return Plan.totalHeight(old) !== Plan.totalHeight(plan) ? "size" : "none";
  }
  totalHeight(p = this.tower) { return Plan.totalHeight(p); }
  projectFloors(p = this.tower) { return Plan.projectFloors(p); }
  floor(id) { return Plan.floor(this.tower, id); }

  moduleKey(f) {
    switch (f.kind) {
      case "project": {
        const d = this.decor[(f.project ?? "").toLowerCase()];
        return `p|${f.project ?? ""}|${f.floorNo}|${f.seats}|${f.active}|${d?.theme ?? ""}|${d?.accentColor ?? ""}|${(d?.props ?? []).join(",")}`;
      }
      case "idle": return "i|" + (f.plates ?? []).map(p => `${p.floorNo}:${p.name}:${p.accent ?? ""}`).join(",");
      case "lobby": return `lobby|${this.tower.floors.some(x => x.kind === "idle")}`;
      default: return "roof";
    }
  }
  buildModule(f) {
    let p;
    switch (f.kind) {
      case "project": p = TowerModules.project(f, this.decor[(f.project ?? "").toLowerCase()], s => { if (OfficeBuilder.trace) console.log("office prop", f.id, s); }); break;
      case "idle": p = TowerModules.idle(f); break;
      case "lobby": p = TowerModules.lobby(!this.tower.floors.some(x => x.kind === "idle")); break;
      default: p = TowerModules.roof();
    }
    p.node.name = `floor:${f.id}`;
    return p;
  }
  rebuildCore(top, roofFloor) {
    const ys = this.tower.floors.map(f => f.y);
    const sig = `${top}|${roofFloor}|${ys}`;
    if (sig === this.coreSig) return;
    this.coreSig = sig;
    this.core.removeFromParent();
    const { node, facades } = TowerCore.build(top, roofFloor, ys);
    this.core = node; this.coreFacades = facades;
    this.cutNow({ facades });
    this.world.add(this.core);
    // 擋雨盒：一樓地面到頂樓花園地板（沒有頂樓就到樓頂），牆外緣
    const roofTop = Plan.floor(this.tower, "roof") ? roofFloor + TowerSpec.slab : top;
    this.weatherFX.shelter(this.world, [-TD.W / 2, 0, TD.zB], [TD.W / 2, roofTop, TD.zF]);
    this.cutSig = ""; this.lodDirty = true;
  }

  // MARK: 搬家（規範 §3.7）

  startMove(old, plan, moves, created, gone) {
    const { MoveAnim } = Tower;
    const floaters = new Set(moves.map(m => m.floorId));
    // 從薄層冒出來／降回薄層的位置：舊（新）大樓第一層薄層，沒有薄層就是大廳頂
    const oldIdle = old.floors.find(f => f.kind === "idle")?.y ?? TowerSpec.lobbyHeight;
    const newIdle = plan.floors.find(f => f.kind === "idle")?.y ?? TowerSpec.lobbyHeight;
    const items = [];
    for (const f of plan.floors) {
      const m = this.modules.get(f.id);
      if (!m) continue;
      const from = created.has(f.id) ? (floaters.has(f.id) ? oldIdle : f.y) : m.parts.node.position.y;
      let glow = null;
      if (floaters.has(f.id)) { const g = TowerModules.glowFrame(); m.parts.node.add(g); glow = g; }
      items.push({ node: m.parts.node, fromY: from, toY: f.y, floats: floaters.has(f.id), glow });
    }
    this.leaving = [];
    for (const id of gone) {
      const m = this.modules.get(id);
      if (!m) continue;
      const g = TowerModules.glowFrame(); m.parts.node.add(g);
      items.push({ node: m.parts.node, fromY: m.parts.node.position.y, toY: newIdle, floats: true, glow: g });
      this.leaving.push(m.parts.node);
      this.modules.delete(id);
    }
    const anim = new MoveAnim(items);
    anim.apply(0);
    this.moving = anim;
    this.moveUntil = nowSec() + MoveAnim.duration + 0.1;
    this.bump(MoveAnim.duration + 0.1);
    MoveAnim.run(anim, this.driver, () => this.finishMove());
  }

  /** 搬家結束（或被新的變化打斷）：直接到最後的位置、拿掉光框、離開的樓層移掉 */
  finishMove() {
    const anim = this.moving;
    if (!anim) return;
    this.moving = null;
    removeAction(this.driver, "move");
    anim.apply(Tower.MoveAnim.duration);
    for (const it of anim.items) it.glow?.removeFromParent();
    for (const n of this.leaving) n.removeFromParent();
    this.leaving = [];
    this.moveUntil = -Infinity;
    this.rebuildCore(Plan.totalHeight(this.tower), Plan.floor(this.tower, "roof")?.y ?? 0);
    this.parkCars(true);   // 樓層高度變了：停著的車廂跟著停的那層走
    this.cutSig = ""; this.lodDirty = true; this.omniDirty = true;
    this.assignOmni();
  }

  /** 視窗被蓋住／縮小：搬家直接到結果、路上的人直接落地（不留一半） */
  settle() {
    this.finishMove();
    if (![...this.persons.values()].some(p => p.place.startsWith("trip:"))) return;
    this.snapTravelers();
    for (const [id, p] of this.persons) if (p.place === "") {
      this.placePerson(p.islander, p.floor, p.seat, p.seats, this.lastWander.states?.[id], false, nowSec());
    }
  }

  /** 測試截圖（SHOWORK_OFFICE_MOVE=<專案>[@秒]）：假裝這層剛從薄層升上來，定在第 t 秒的樣子 */
  debugPoseMove(project, t) {
    const f = Plan.floorOfProject(this.tower, project), m = f && this.modules.get(f.id);
    if (!m || !Tower.MoveAnim) return false;
    const idleY = this.tower.floors.find(x => x.kind === "idle")?.y ?? TowerSpec.lobbyHeight;
    const items = [];
    for (const g of this.tower.floors) if (g.y > f.y) {
      const mm = this.modules.get(g.id);
      if (mm) items.push({ node: mm.parts.node, fromY: g.y - TowerSpec.floorHeight, toY: g.y, floats: false, glow: null });
    }
    const glow = TowerModules.glowFrame(); m.parts.node.add(glow);
    items.push({ node: m.parts.node, fromY: idleY, toY: f.y, floats: true, glow });
    new Tower.MoveAnim(items).apply(t);
    return true;
  }

  // MARK: 角色（座位、頂樓、閒晃）

  /** 造型有關的才算（token 每則訊息都變，不放進來，免得一直重建） */
  static personKey(p) {
    const c = p.card;
    return `${p.mood}|${p.accessory ?? ""}|${c.title}|${c.activity}|${c.blockedReason ?? ""}|` + (c.subagents ?? []).map(s => s.description).join(",");
  }

  floorY(id) {
    if (id === TowerLayoutCore.b1Floor) return OfficeBasement.baseY;       // B1（10-22）：不在 TowerPlan 裡，固定在大廳正下方
    const m = this.modules.get(id);
    if (m) return m.parts.node.position.y;
    return Plan.floor(this.tower, id)?.y ?? 0;
  }

  /** 過場可以播嗎：沒開「減少動態效果」、沒因為太熱暫停 */
  static get poofOK() { return !OfficeBuilder.reduceMotion && !OfficeBuilder.heatPaused && !!PoofMod?.Poof; }

  updatePeople(islands, wander, animate, now) {
    const seen = new Set();
    for (const i of islands) {
      const fid = projectId(i.project);
      if (!this.modules.has(fid)) continue;
      const all = i.people.slice().sort((a, b) => (a.card.id < b.card.id ? -1 : a.card.id > b.card.id ? 1 : 0));
      all.forEach((p, k) => {
        if (k >= OfficeBuilder.maxPeople) return;
        seen.add(p.card.id);
        this.placePerson(p, fid, k, all.length, wander.states?.[p.card.id], animate, now);
      });
    }
    // 離開的人（session 關掉）：忍術「ドロン」——爆一團煙、在煙裡縮掉（10-21 Kang：原本憑空消失很突兀）
    for (const [id, old] of [...this.persons]) if (!seen.has(id)) {
      this.persons.delete(id);
      const parent = old.node.parent;
      if (animate && OfficeBuilder.poofOK && parent) {
        new PoofMod.Poof(pos3(old.node), parent, old.node, false).run();
        this.bump((PoofMod.PoofCurve?.duration ?? 0.8) + 0.1);
      } else {
        old.node.removeFromParent();
      }
    }
    this.peopleSeeded = this.peopleSeeded || islands.length > 0;
    const live = new Set(Object.values(wander.states ?? {}).filter(s => s.trip).map(s => `${s.trip.sid}@${sec(s.trip.start)}`));
    this.tripsDone = new Set([...this.tripsDone].filter(id => live.has(id)));
  }

  /** 一個人現在該在哪：路上（播行程）、自己的座位、頂樓站位。外觀沒變只搬位置 */
  placePerson(p, fid, k, n, state, animate, now) {
    const id = p.card.id;
    const st = state ?? { spot: "desk", trip: null };
    let trip = st.trip ?? null;
    if (trip && this.tripsDone.has(`${trip.sid}@${sec(trip.start)}`)) trip = null;
    const tripEnd = t => sec(t.start) + (t.nodes.length ? t.nodes[t.nodes.length - 1].t : 0);
    if (trip && OfficeBuilder.testTripT === null && (!animate || now >= tripEnd(trip))) trip = null;
    const seatPos = TowerLayoutCore.seat(k, n, fid);
    const seatedAtDesk = k < 12;
    let w;
    const sk = Spot.kind(st.spot);
    if (trip) w = { kind: "trip", t: trip };
    else if (sk === "roof" && this.modules.has("roof")) w = { kind: "roof", s: Math.max(0, Spot.slot(st.spot)) };
    else if (sk === "cafe" && this.modules.has("lobby")) w = { kind: "cafe", s: Math.max(0, Spot.slot(st.spot)) };
    else if (sk === "b1") w = { kind: "b1", s: Math.max(0, Spot.slot(st.spot)) };
    else w = { kind: "desk" };
    const isB1 = w.kind === "b1";
    let seated, place;
    switch (w.kind) {
      case "desk": seated = seatedAtDesk; place = `desk:${fid}:${k}/${n}`; break;
      case "roof": seated = false; place = `roof:${w.s}`; break;
      case "cafe": seated = false; place = `cafe:${w.s}`; break;
      case "b1": seated = false; place = `b1:${w.s}`; break;
      default: seated = false; place = `trip:${sec(w.t.start)}`;
    }
    // 地下室禁止飲食（10-22 Kang）：在 B1、或正要去 B1 的人手上不拿咖啡杯
    const noCup = isB1 || (trip ? Spot.isB1(trip.dest) : false);
    const look = OfficeBuilder.personKey(p) + `|${seated}|${seatedAtDesk}|${noCup}`;
    const parent = w.kind === "desk" ? this.modules.get(fid)?.parts.node
      : w.kind === "roof" ? this.modules.get("roof")?.parts.node
      : w.kind === "cafe" ? this.modules.get("lobby")?.parts.node
      : w.kind === "b1" ? this.basement.root            // 鏡頭在地上時 basement.root 藏著 ⇒ 人也跟著看不到（正常）
      : this.world;
    let person, isNew = false;
    const old = this.persons.get(id);
    if (old && old.look === look) {
      person = old;
      // 同一個人、同一個位置、還掛在對的樓層上（樓層重建過要重新掛）⇒ 不動
      if (old.place === place && old.node.parent === parent && parent) { old.islander = p; return; }
    } else {
      isNew = !old;
      const intro = old ? old.mood !== p.mood : true;
      old?.node.removeFromParent();
      const node = this.makePerson(p, seated, seated && seatedAtDesk, noCup, intro);
      person = { node, look, place: "", mood: p.mood, islander: p, floor: fid, seat: k, seats: n };
      if (OfficeBuilder.trace) console.log("office rebuild person", id.slice(0, 8), place);
    }
    removeAction(person.node, "trip");
    person.place = place; person.mood = p.mood; person.islander = p; person.floor = fid; person.seat = k; person.seats = n;
    this.persons.set(id, person);
    const node = person.node;
    if (node.parent !== parent) { node.removeFromParent(); parent?.add(node); }
    OfficeBuilder.b1Lit(node, isB1);
    switch (w.kind) {
      case "desk":
        node.position.set(seatPos.x, TD.room, seatPos.z); node.rotation.y = seatPos.a;   // 自由座：照座位朝向
        break;
      case "roof": {
        const r = TowerLayoutCore.roofSlot(w.s);
        node.position.set(r.x, TD.room, r.z); node.rotation.y = w.s % 3 === 0 ? 0.3 : w.s % 3 === 1 ? -0.3 : 0;
        break;
      }
      case "cafe": {
        const c = TowerLayoutCore.cafeSlot(w.s);
        node.position.set(c.x, TD.room, c.z); node.rotation.y = c.a;
        break;
      }
      case "b1": {
        // B1 模組本地座標（地坪＝TD.room），面向圖譜中心看神經網路
        const b = TowerLayoutCore.b1Slot(w.s);
        node.position.set(b.x, TD.room, b.z); node.rotation.y = b.a;
        break;
      }
      default: {
        const t = w.t;
        if (!Tower.TripPath) break;
        const path = this.tripPath(t, { floor: fid, pos: seatPos });
        const el = OfficeBuilder.testTripT ?? now - sec(t.start);
        path.apply(node, el);
        if (OfficeBuilder.testTripT !== null) this.poseCars(t, OfficeBuilder.testTripT);   // 測試定格：車廂也定在同一秒（人才在車廂裡）
        if (OfficeBuilder.testTripT === null) {
          const key = `${t.sid}@${sec(t.start)}`;
          Tower.TripPath.run(path, el, node, () => this.tripEnded(id, key));
          this.scheduleCars(t, now);
          this.walkUntil = Math.max(this.walkUntil, tripEnd(t));
          this.bump(Math.max(0.1, tripEnd(t) - now));
        }
      }
    }
    // 新來的人（新開的 session）：先冒一團煙、從煙裡彈出來（開窗第一次載入不播）
    if (isNew && this.peopleSeeded && animate && OfficeBuilder.poofOK && node.parent) {
      new PoofMod.Poof(pos3(node), node.parent, node, true).run();
      this.bump((PoofMod.PoofCurve?.duration ?? 0.8) + 0.1);
    }
  }

  /** 人在 B1：吃 B1 自己的冷光（OfficeBasement.mask）、不吃大樓的暖補光（第 0 位元）；回到地上換回來。點擊位元（pickMask）不動 */
  static b1Lit(n, on) {
    const set = c => {
      if (!c.isMesh) return;
      setCategory(c, on ? (category(c) & ~1) | OfficeBasement.mask : (category(c) & ~OfficeBasement.mask) | 1);
    };
    n.traverse(set);
  }

  /** 測試定格（SHOWORK_OFFICE_POOF=<秒>[,in]）：第一個人（id 排序）直接擺成過場第 t 秒的樣子。回傳 [id, 煙的世界座標] 給鏡頭對準 */
  debugPoof(t, appear) {
    const hit = [...this.persons].sort((a, b) => (a[0] < b[0] ? -1 : 1)).find(([, p]) => p.place.startsWith("desk:"));
    if (!hit || !PoofMod?.Poof) return null;
    const [id, p] = hit, parent = p.node.parent;
    if (!parent) return null;
    const f = new PoofMod.Poof(pos3(p.node), parent, p.node, appear);
    f.apply(t);
    const w = f.root.getWorldPosition(new THREE.Vector3());
    return [id, [w.x, w.y + 0.9, w.z]];
  }

  /** 探針：場景節點總數（過場結束後要回到原本的數量） */
  get nodeCount() { let n = 0; this.scene.traverse(() => { n += 1; }); return n; }

  /** 行程播完：回到座位／頂樓（同一個行程在下次刷新清掉之前不要重播） */
  tripEnded(id, key) {
    this.tripsDone.add(key);
    const p = this.persons.get(id);
    if (!p) return;
    p.place = "";
    this.placePerson(p.islander, p.floor, p.seat, p.seats, this.lastWander.states?.[id], false, nowSec());
  }

  /** 開始搬家時：路上的人直接落地（規範：搬家期間不同時播閒晃） */
  snapTravelers() {
    for (const [id, p] of this.persons) if (p.place.startsWith("trip:")) {
      removeAction(p.node, "trip");
      const t = this.lastWander.states?.[id]?.trip;
      if (t) this.tripsDone.add(`${t.sid}@${sec(t.start)}`);
      p.place = "";
    }
    this.parkCars();
    this.walkUntil = -Infinity;
  }

  /** 這趟的車廂段落（世界座標、絕對時間）：有 carMoves 照它（含空車先去接人）；舊排程沒有 ⇒ 退回搭乘段落、全算第 0 部 */
  tripCarLegs(t) {
    const t0 = sec(t.start);
    const moves = t.carMoves ?? [];
    if (!moves.length) {
      const out = [];
      for (let i = 1; i < t.nodes.length; i++) {
        const a = t.nodes[i - 1], b = t.nodes[i];
        if (b.move !== "elevator") continue;
        out.push({ car: b.car ?? 0, leg: { y0: this.floorY(a.floor) + TD.room, y1: this.floorY(b.floor) + TD.room, start: t0 + a.t, end: t0 + b.t }, to: b.floor });
      }
      return out.filter(x => x.car >= 0 && x.car < this.cars.length);
    }
    return moves.filter(m => m.car >= 0 && m.car < this.cars.length).map(m =>
      ({ car: m.car, leg: { y0: this.floorY(m.from) + TD.room, y1: this.floorY(m.to) + TD.room, start: t0 + m.start, end: t0 + m.end }, to: m.to }));
  }

  /** 把這趟的車廂段落併進各部車廂的排程、重新播（同一段只留一份；同一趟重新掛上來不會重複） */
  scheduleCars(t, now) {
    const touched = new Set();
    for (const { car: c, leg, to } of this.tripCarLegs(t)) {
      this.carLegs[c] = this.carLegs[c].filter(l => !(l.start === leg.start && l.end === leg.end));
      this.carLegs[c].push(leg);
      touched.add(c);
      if (leg.end >= Math.max(...this.carLegs[c].map(l => l.end))) this.carRest[c] = to;
    }
    for (const c of [...touched].sort()) {
      this.carLegs[c] = this.carLegs[c].filter(l => !(l.end < now - 60));
      this.carLegs[c].sort((a, b) => a.start - b.start);
      const e = TD.elevs[c];
      Tower.TripPath.runCar(this.cars[c], e.x, e.y, this.carLegs[c].map(dateLeg), this.cars[c].position.y, toDate(now));
      this.scheduleDoors(c, now);
    }
  }

  // MARK: 電梯門（10-25）

  /** 第 c 部電梯每一層的門＋那層地坪的世界高度（車廂底＝這個高度） */
  doors(c) {
    const out = [];
    const b = child(this.basement.root, `edoor-${c}`, false);
    if (b) out.push({ y: OfficeBasement.baseY + TD.room, node: b });
    for (const m of this.modules.values()) {
      const d = child(m.parts.node, `edoor-${c}`, false);
      if (d) out.push({ y: m.parts.node.position.y + TD.room, node: d });
    }
    return out;
  }

  /** 照第 c 部車廂的排程排門：停在某層的時段那層開，其他層關。一次性動作，跑完就停 */
  scheduleDoors(c, now) {
    const legs = this.carLegs[c];
    const stops = [];
    if (legs.length && legs[0].start > now) stops.push({ y: legs[0].y0, from: now, to: legs[0].start });   // 車廂已經在這層、等人上車
    // 到站：提早 doorTime 開始開，車廂停好時門剛好全開（人走出來不穿過玻璃）
    const early = -TowerCore.doorTime;
    for (let i = 1; i < legs.length; i++) { const a = legs[i - 1], b = legs[i]; if (b.start > a.end) stops.push({ y: a.y1, from: a.end + early, to: b.start }); }
    if (legs.length) { const l = legs[legs.length - 1]; stops.push({ y: l.y1, from: l.end + early, to: l.end + TowerCore.doorDwell }); }
    let end = now;
    for (const d of this.doors(c)) {
      const mine = stops.filter(s => Math.abs(s.y - d.y) < 0.05).map(s => ({ from: s.from, to: s.to }));
      end = Math.max(end, runDoorS(d.node, mine, now));
    }
    this.bump(Math.max(0.1, end - now + 0.1));
  }

  /** 測試定格（SHOWORK_OFFICE_TRIP_T）：車廂直接放到這趟第 t 秒的高度 */
  poseCars(t, s) {
    const at = sec(t.start) + s;
    const legs = new Map();
    for (const { car: c, leg } of this.tripCarLegs(t)) { if (!legs.has(c)) legs.set(c, []); legs.get(c).push(leg); }
    for (const [c, l] of legs) {
      const e = TD.elevs[c];
      removeAction(this.cars[c], "car");
      this.cars[c].position.set(e.x, Tower.TripPath.carY(l.slice().sort((a, b) => a.start - b.start).map(dateLeg), toDate(at), this.cars[c].position.y), e.y);
    }
  }

  /** 車廂直接停到最後的樓層：排程那邊有記（WanderPlan.cars）就照它，否則照最後播的那段終點；`onlyIdle`＝只動沒在跑的車廂 */
  parkCars(onlyIdle = false) {
    this.cars.forEach((car, c) => {
      if (onlyIdle && actionForKey(car, "car")) return;
      removeAction(car, "car");
      this.carLegs[c] = [];
      const wc = this.lastWander.cars ?? [];
      if (c < wc.length) this.carRest[c] = wc[c].floor;
      const id = this.modules.has(this.carRest[c]) || Plan.floor(this.tower, this.carRest[c]) || this.carRest[c] === TowerLayoutCore.b1Floor ? this.carRest[c] : "lobby";
      const e = TD.elevs[c];
      car.position.set(e.x, this.floorY(id) + TD.room, e.y);
      for (const d of this.doors(c)) TowerCore.setDoor(d.node, OfficeBuilder.testDoor ?? 0);     // 停著＝門關
    });
  }

  /** 行程 → 世界座標路線：走路照節點直線、電梯垂直、溜滑梯沿螺旋、瞬移直接跳。
   *  `seat`＝這個人的樓層＋座位：從座位出發、走回座位的那一刻，身體轉成座位的朝向 a */
  tripPath(t, seat) {
    const keys = [];
    const K = (t, p, face, ride) => ({ t, p, face, ride });
    const atSeat = n => n.floor === seat.floor && Math.abs(n.x - seat.pos.x) < 0.05 && Math.abs(n.z - seat.pos.z) < 0.05;
    const seatFace = seat.pos.a;
    const roofY = this.floorY("roof");
    const slideTop = roofY + TD.room + 0.3;
    t.nodes.forEach((n, i) => {
      const y = this.floorY(n.floor) + TD.room;
      const p = [n.x, y, n.z];
      switch (n.move) {
        case "start": keys.push(K(n.t, p, atSeat(n) ? seatFace : 0, false)); break;
        case "walk": keys.push(K(n.t, p, null, false)); break;
        case "elevator": keys.push(K(n.t, p, Math.PI / 2, true)); break;
        case "teleport": {
          const last = keys[keys.length - 1];
          if (last) keys.push(K(n.t, last.p, last.face, true));
          keys.push(K(n.t, p, null, true));
          break;
        }
        case "wait": {
          // 拜訪：面向主人（主人在左邊 0.9）；茶水角：面向鏡頭
          let face = 0;
          if (Spot.kind(t.dest) === "visit") face = -Math.PI / 2;
          // 在電梯門口等電梯（10-22 Kang：沒有電梯要等）：面向電梯門
          if (TowerLayout.elevatorDoors.some(d => Math.abs(d.x - n.x) < 0.3 && Math.abs(d.z - n.z) < 0.3)) face = -Math.PI / 2;
          const last = keys[keys.length - 1];
          if (last) keys[keys.length - 1] = K(last.t, last.p, face, last.ride);
          keys.push(K(n.t, p, face, true));
          break;
        }
        case "slide": {
          // 溜滑梯：先走到螺旋起點，再沿螺旋滑到這層的高度，最後走進右門
          const t0 = i > 0 ? t.nodes[i - 1].t : n.t;
          const a0 = TD.slideA0, a1 = TD.slideAngle(slideTop, y);
          const steps = Math.max(2, Math.trunc((a1 - a0) / TD.slideStep));
          const span = n.t - t0;
          keys.push(K(t0 + span * 0.05, TD.slidePoint(a0, slideTop, slideTop + 0.04), null, false));
          for (let s = 1; s <= steps; s++) {
            const a = a0 + (a1 - a0) * s / steps;
            const yy = slideTop - (a - a0) / TD.slideStep * TD.slideDrop + 0.04;
            keys.push(K(t0 + span * (0.05 + 0.85 * s / steps), TD.slidePoint(a, slideTop, yy), a + Math.PI / 2, true));
          }
          keys.push(K(n.t, p, null, false));
          break;
        }
      }
    });
    // 最後一步走回座位：抵達那一刻轉成座位朝向（走路中途仍照前進方向）
    const last = t.nodes[t.nodes.length - 1], k = keys[keys.length - 1];
    if (last && atSeat(last) && k) keys[keys.length - 1] = K(k.t, k.p, seatFace, k.ride);
    return new Tower.TripPath(keys);
  }

  /** 螢幕空間標籤要的東西：每個人（含保全）的錨點節點＋卡片＋狀態＋所在樓層；樓層（id、節點、高度、樓層號、專案、主題） */
  labelTargets() {
    const ps = [];
    for (const [id, p] of this.persons) {
      const a = child(p.node, "anchor");
      if (!a) continue;
      if (p.place.startsWith("b1:") && !this.underground) continue;    // 在 B1 看神經網路的人：鏡頭在地上時看不到，名牌也不畫
      ps.push({ id, anchor: a, card: p.islander.card, mood: p.mood, floor: p.place.startsWith("b1:") ? "b1" : p.floor });
    }
    const ga = child(this.guardNode, "anchor");
    if (ga) ps.push({ id: "guard", anchor: ga, card: null, mood: "idle", floor: "lobby" });
    const themeOf = f => this.decor[(f.project ?? "").toLowerCase()]?.theme ?? "general";
    const fs = this.tower.floors.flatMap(f => {
      const m = this.modules.get(f.id);
      if (!m) return [];
      let title;
      switch (f.kind) {
        case "project": title = `${f.floorNo}  ${f.project ?? ""}・${Tower.TowerTheme?.title?.[themeOf(f)] ?? themeOf(f)}`; break;
        case "idle": title = `閒置 ${(f.plates ?? []).length} 個專案・名字在左側清單`; break;
        case "lobby": title = "01  大廳・前台保全"; break;
        default: title = "RF  空中花園";
      }
      const accent = f.kind === "project" ? TP.hex(Tower.TowerTheme?.accent?.[themeOf(f)] ?? "") : f.kind === "lobby" ? 0x1E3A8A : null;
      return [{ id: f.id, node: m.parts.node, height: f.height, floorNo: f.floorNo, title, kind: f.kind,
                names: (f.plates ?? []).map(p => !p.floorNo ? p.name : `${p.floorNo} ${p.name}`), accent }];
    });
    return { people: ps, floors: fs };
  }

  /** 城市的名牌（建築＋出港的船） */
  cityLabelTargets() {
    if (this.underground) return [];       // 鏡頭在地下室：城市藏起來了，名牌也不畫
    return [...(this.city.labels ?? []), ...(this.city.shipLabels ?? []).map(s => ({ id: s.id, anchor: s.anchor, text: s.text, alert: false }))];
  }

  /** 城市資料變了：有變才重建；狀態剛變的警示燈、出港的船要播幾秒 */
  updateCity(s, animate) {
    this.bump(this.city.update(s, animate) ?? 0);       // 原始 JSON 直接給：city.update 自己轉成 CityState（city-model.js）
    const st = this.city.state ?? {};
    this.setGrid(st.grid?.stage ?? "normal", animate);
    this.updateCooler(st.power);
  }

  // MARK: 電力（10-22 電廠＝AI 額度）

  /** 額度階段 → 燈光乘數、逃生燈、AI 定格。只在跨門檻時做事；進入「吃緊」閃 2 秒（一次性），之後穩定變暗 */
  setGrid(st, animate) {
    if (st === this.gridStage && this.gridSet) return;
    const rank = s => ({ normal: 0, dim: 1, flicker: 2, blackout: 3 })[s] ?? 0;
    const old = this.gridStage;
    this.gridStage = st; this.gridSet = true;
    OfficeBuilder.onBlackout?.(st === "blackout");          // HeatGate.shared.setBlackout
    this.updateEmergency();
    if (st === "flicker" && rank(old) < rank("flicker") && animate && !OfficeBuilder.reduceMotion) {
      const steps = [];
      for (let i = 0; i < 8; i++) steps.push([i * 0.25, i % 2 === 0 ? 0.1 : 0.8]);
      for (const [t, v] of steps) this.after(t, () => { if (this.gridStage !== "flicker") return; VoxMat.setPower(v); });
      this.after(2.1, () => this.applyLights());
      this.bump(2.2);
    }
    this.applyLights();
    this.bump(0.3);
  }

  /** 停電：每層正面右邊一盞綠色逃生燈（不吃電力乘數） */
  updateEmergency() {
    const ys = this.gridStage === "blackout" ? this.tower.floors.map(f => f.y) : [];
    const sig = JSON.stringify(ys);
    if (sig === this.emergencySig) return;
    this.emergencySig = sig;
    this.emergency?.removeFromParent(); this.emergency = null;
    if (!ys.length || !CityBuilder.signal) return;
    const m = new VoxelMesh({ ao: 0 }), k = new Kit(m);
    for (const y of ys) k.b(Xf.identity, TD.W / 2 - 0.7, y + TD.room - 0.55, TD.zF + 0.02, 0.5, 0.22, 0.04, CityBuilder.signal(0x22C55E));
    const n = m.node("emergency");
    this.world.add(n); this.emergency = n;
  }

  /** 頂樓冷卻水塔（cool42；10-22 從城市搬上來，電廠讓給額度）：右前方空地，煙量＝溫度、hot 以上紅燈 */
  updateCooler(power) {
    const roof = this.modules.get("roof")?.parts.node;
    if (!roof) return;
    const p = power instanceof CityModel.CityPower ? power : new CityModel.CityPower(power ?? {});
    const n = CityModel.CityRules.smoke ? CityModel.CityRules.smoke(p)
      : (!p.known ? 0 : Math.min(5, Math.max(0, Math.trunc((CityModel.CityRules.tempStep(p.temp) - 40) / 10))));
    const sig = `${roof.uuid}|${n}|${p.alert}|${p.known}|${p.level ?? ""}`;
    if (sig === this.coolerSig) return;
    this.coolerSig = sig;
    this.cooler?.removeFromParent();
    const m = new VoxelMesh({ ao: 0 }), k = new Kit(m);
    const x = 5.0, z = 1.6, r = TD.room;
    const rs = [0.55, 0.48, 0.42, 0.42, 0.48];
    rs.forEach((w, i) => k.b(Xf.identity, x, r + i * 0.26, z, w * 2, 0.26, w * 2, TM.f(TP.ST2)));
    const top = r + rs.length * 0.26;
    k.b(Xf.identity, x, top, z, 0.8, 0.03, 0.8, TM.f(TP.FN6));
    const col = p.alert || p.level === "warm" ? VoxMat.dayNight(0xC9B79A, 0x5A606A) : VoxMat.dayNight(0xE6E3DE, 0x5A606A);
    for (let i = 0; i < n; i++) {
      const sz = 0.4 + i * 0.14;
      k.b(Xf.identity, x + i * 0.18, top + 0.12 + i * 0.38, z - i * 0.06, sz, sz * 0.8, sz, col);
    }
    if (p.alert && CityBuilder.red) k.b(Xf.identity, x, top + 0.03, z + 0.5, 0.14, 0.14, 0.14, CityBuilder.red);
    const node = m.node("cooler");
    roof.add(node); this.cooler = node;
    roof.updateMatrixWorld(true);
    const wp = new THREE.Vector3(x, top + 0.4, z).applyMatrix4(roof.matrixWorld);
    this.city.setPoint?.("city:cooler", [wp.x, wp.y, wp.z]);
  }

  /** 俯瞰城市（左側索引列「城市」）：從右前方高處看整個街區，大樓在中間 */
  frameCity(aspect = this.aspect) {
    aspect = Math.max(0.4, aspect);
    const b = CityBuilder.bounds;
    // 直式視窗（寬高比 < 1）：46° 時寬度先頂到 ⇒ 改 55° 更俯視（研究 R2-2-6）
    const el = aspect < 1 ? 55 : 46;
    const [dist, t] = OfficeBuilder.fit(b.lo, b.hi, aspect, 18 * Math.PI / 180, el * Math.PI / 180, 34, 0.98);
    this.place(t, dist, 18, el);
  }

  peopleNodes() { return [...this.persons].map(([k, p]) => [k, p.node]).concat(this.guardNode ? [["guard", this.guardNode]] : []); }
  personNode(id) { return id === "guard" ? this.guardNode : this.persons.get(id)?.node ?? null; }

  /** 鏡頭對準用的點：roof／lobby／floor:<專案> */
  focusPoint(key) {
    let id;
    if (key === "roof" || key === "lobby") id = key;
    else if (key.startsWith("floor:")) id = projectId(key.slice(6));
    else return null;
    const m = this.modules.get(id);
    if (!m) return null;
    return [0, m.parts.node.position.y + TD.room + 1.3, 0.5];
  }

  /** 頭上的符號多跳三下（你動過視角、鏡頭不飛過去時用）；回傳要播幾秒 */
  bounceMark(id) {
    const m = OfficeBuilder.reduceMotion ? null : child(this.personNode(id), "gem");
    if (!m) return 0;
    runAction(m, OfficeBuilder.hop(0.18, 3));
    return 3 * 0.6 + 0.2;
  }
  static hop(h, times) {
    return Act.repeat(Act.sequence([Act.moveBy(0, h, 0, 0.2), Act.moveBy(0, -h, 0, 0.2), Act.wait(0.2)]), times);
  }

  /** 左側索引列滑鼠停在某層：那層樓板底下亮一圈 NE-1 光框（同搬家的光框；只加一個節點） */
  highlightFloor(id) {
    const cur = this.floorGlow?.parent?.name ?? null;
    const want = id ? `floor:${id}` : null;
    if (cur === want) return false;
    this.floorGlow?.removeFromParent(); this.floorGlow = null;
    const m = id && this.modules.get(id);
    if (m) { const g = TowerModules.glowFrame(); m.parts.node.add(g); this.floorGlow = g; }
    return true;
  }

  highlight(id) {
    this.lit = id;
    // 只在真的變了才寫
    const set = (n, h) => { if (n && n.visible !== !h) n.visible = !h; };
    for (const [pid, p] of this.persons) set(child(p.node, "halo", false), pid !== id);
    set(child(this.guardNode, "halo"), id !== "guard");
  }

  /** 影分身：從別的專案 cd 過來逛的，半透明站在這層前帶 */
  updateGhosts(byKey) {
    for (const f of this.projectFloors()) {
      const island = byKey.get((f.project ?? "").toLowerCase());
      const key = (island?.ghosts ?? []).map(g => `${g.id}|${g.mood}`).join(",");
      if (this.ghosts.get(f.id)?.key === key) continue;
      this.ghosts.get(f.id)?.node.removeFromParent();
      const g = scnNode();
      // 站在 PropPlacer 找的空地（10-22）；空地不夠就少畫幾個
      const spots = this.modules.get(f.id)?.parts.ghostSpots ?? [];
      (island?.ghosts ?? []).slice(0, spots.length).forEach((x, i) => {
        const at = spots[i];
        const n = this.makeKubo(x.mood, x.accessory ?? null, { seated: false, intro: false });
        setOpacity(n, 0.4);
        n.position.set(at.x ?? at[0], TD.room, at.y ?? at[1]);
        g.add(n);
      });
      this.modules.get(f.id)?.parts.node.add(g);
      this.ghosts.set(f.id, { node: g, key });
    }
  }

  /** 一個人：角色（坐在椅子上面向桌子，或站在咖啡吧）＋亮著的螢幕＋名牌＋頭上符號＋子 agent＋點擊盒
   *  `intro`＝狀態剛變（等你＝跳三下、做完＝搖一下）；只是搬位置重建時不重播 */
  makePerson(p, seated, atDesk, noCup = false, intro = true) {
    const root = scnNode(`p:${p.card.id}`);
    const tint = KuboArt.tint(p.mood);
    const act = p.mood === "working" ? p.card.activity : "none";
    // 螢幕：亮的顏色＝狀態（紫打字、紅等你、綠做完、橘卡住；休息／睡覺＝暗）。兩面都亮，背對你的人也看得到
    if (atDesk && seated && p.mood !== "idle" && p.mood !== "asleep" && !p.card.captain) {
      const scr = new THREE.Mesh(new THREE.BoxGeometry(0.58, 0.17, 0.05), VoxMat.flat(tint, { emit: [0.7, 3.0] }));
      scr.position.set(0, 0.86, TowerLayout.chairBack + 0.2);        // 桌上螢幕（OfficeTower desk：桌心前 0.2、底高 0.76）
      root.add(scr);
    }
    const kubo = this.makeKubo(p.mood, p.accessory ?? null, { activity: act, seated, cup: p.mood === "idle" && !seated && !noCup, intro });
    kubo.position.y = seated ? TowerSpec.seatTop : 0;      // 椅面頂（OfficeTower.desk）
    root.add(kubo);
    // 子 agent：椅子後面縮小、半透明的小 Kubo（最多 3 隻）
    let subs = p.card.subagents ?? [];
    if (act === "delegating" && !subs.length) subs = [{ description: "子任務" }];
    const spots = [[-0.75, -0.6], [0.75, -0.6], [0, -1.1]];
    subs.slice(0, 3).forEach((_, k) => {
      const [x, z] = spots[k];
      const mini = this.makeKubo("working", null, { seated: false, gem: false, intro: false });
      mini.scale.set(0.6, 0.6, 0.6); setOpacity(mini, 0.6);
      mini.position.set(x, 0, z);
      root.add(mini);
    });
    // 名牌與頭上符號改成螢幕空間標籤（OfficeLabels）；3D 裡只留一個不畫的錨點給標籤投影用（頭頂）
    const anchor = scnNode("anchor");
    anchor.position.set(0, seated ? TowerSpec.seatedHead + 0.05 : 0.92 * OfficeBuilder.kuboScale + 0.05, 0);
    root.add(anchor);
    this.addHaloAndHitbox(root);
    OfficeBuilder.pickable(root);
    return root;
  }

  /** 滑鼠停上去：地上一圈白光；點擊範圍：整個角色一個透明盒 */
  addHaloAndHitbox(root, size = 1.1) {
    const tg = new THREE.TorusGeometry(0.6 * size, 0.035, 12, 48);
    tg.rotateX(-Math.PI / 2);                // SCNTorus 躺在 XZ 平面（three 的在 XY）
    const hm = new THREE.MeshBasicMaterial({ color: 0xffffff });
    hm.userData.emission = { color: new SColor(1, 1, 1), intensity: 1 };
    const hn = new THREE.Mesh(tg, hm); hn.name = "halo"; hn.position.set(0, 0.06, 0); hn.visible = false;
    root.add(hn);
    const hitM = new THREE.MeshPhongMaterial({ color: 0xffffff, transparent: true, opacity: 0, depthWrite: false });
    hitM.specular.setRGB(0, 0, 0);
    const hitN = new THREE.Mesh(new THREE.BoxGeometry(size, 2.2, size), hitM); hitN.name = "hitbox"; hitN.position.set(0, 1.1, 0);
    hitN.visible = false;        // 不畫；點擊時 hitTest 照樣找得到（Raycaster 不看 visible）
    root.add(hitN);
  }

  static pickable(n) {
    n.traverse(c => setCategory(c, category(c) | OfficeBuilder.pickMask));
  }

  /** 方塊 Kubo：陶土橘身體、方塊眼睛、小手；`seated`＝坐在椅子上（腿往前彎），原點＝椅面（坐著）或地面（站著）。
   *  面向 +z。`activity`＝進行中在用哪類工具（換道具，只有改檔會動）；頭上寶石＝狀態色 */
  makeKubo(mood, accessory, { activity = "none", seated, gem = true, gemColor = null, cup = false, cap = false, intro = true } = {}) {
    const k = scnNode();
    const S = OfficeBuilder.kuboScale;
    k.scale.set(S, S, S);
    // 夜晚身體微微自己亮（10-20 審查：離燈籠遠的 Kubo 夜晚幾乎看不見；只改共用材質的強度，不加燈）
    const clay = VoxMat.flat(KuboArt.clay, { emit: [0, 0.32] }), dark = VoxMat.flat(KuboArt.clayDark, { emit: [0, 0.28] }), ink = VoxMat.flat(0x2a1d18);
    const still = OfficeBuilder.reduceMotion;
    // 腿：站著＝直的；坐著＝大腿往前、小腿往下（在身體外，不跟著跳）
    if (seated) {
      const legs = new VoxelMesh();
      for (const x of [-0.17, 0.17]) {
        legs.box(Xf.identity, [x, 0.06, 0.2], [0.14, 0.12, 0.36], dark);
        legs.box(Xf.identity, [x, -0.17, 0.33], [0.13, 0.36, 0.13], dark);
      }
      k.add(legs.node());
    } else {
      // 站著：兩條腿各自一個節點、軸心在髖（y 0.3），走路時 TripPath 前後擺
      for (const [x, name] of [[-0.17, "legL"], [0.17, "legR"]]) {
        const leg = new VoxelMesh();
        leg.box(Xf.identity, [0, -0.15, 0], [0.14, 0.3, 0.14], dark);
        const n = leg.node(); n.name = name;
        n.position.set(x, 0.3, 0);
        n.rotation.order = "ZYX";
        k.add(n);
      }
    }
    // 身體：以前的座標（身體底在 0.3）；坐著整個往下 0.3（身體底＝椅面）
    const body = scnNode("body");
    body.rotation.order = "ZYX";
    body.position.y = seated ? -0.3 : 0;
    k.add(body);
    const mesh = new VoxelMesh();
    mesh.box(Xf.identity, [0, 0.61, 0], [0.66, 0.62, 0.5], clay);
    // 眼睛（面向 +z）；讀檔、搜尋時往下看（瞇一點）
    const eh = mood === "asleep" ? 0.03 : mood === "finished" ? 0.05 : (activity === "reading" || activity === "searching") ? 0.08 : 0.15;
    for (const x of [-0.14, 0.14]) mesh.box(Xf.identity, [x, activity === "reading" ? 0.64 : 0.68, 0.255], [0.09, eh, 0.02], ink);
    // 手的位置跟著道具走（坐著打字：手在桌上的鍵盤）
    const kbY = seated ? 0.43 : 0.40;         // 坐著：鍵盤剛好在桌面上（椅面 0.56、放大 1.6）
    const hands = activity === "reading" ? [[-0.24, 0.5, 0.36], [0.24, 0.5, 0.36]]
      : activity === "editing" ? [[-0.16, kbY + 0.07, 0.42], [0.16, kbY + 0.07, 0.42]]
      : activity === "searching" ? [[-0.4, 0.55, 0.12], [0.42, 0.62, 0.3]]
      : [[-0.4, 0.55, 0.12], [0.4, 0.55, 0.12]];
    const typing = mood === "working" && activity === "editing" && !still;
    hands.forEach((h, n) => {
      if (typing) {
        // 打字：唯一一直在動的動畫（其他動作都是靜態造型）
        const a = new THREE.Mesh(new THREE.BoxGeometry(0.12, 0.12, 0.12), clay);
        a.position.set(h[0], h[1], h[2]);
        const up = Act.moveBy(0, 0.05, 0, 0.125), down = up.reversed();
        runAction(a, Act.repeatForever(n === 0 ? Act.sequence([up, down]) : Act.sequence([down, up])));
        body.add(a);
      } else {
        mesh.box(Xf.identity, h, [0.12, 0.12, 0.12], clay);
      }
    });
    // 頭上的狀態寶石（像徽章的小寶石）：紫工作／紅等你／綠做完／橘卡住
    const gc = gemColor ?? (gem ? (["working", "waiting", "finished", "stuck"].includes(mood) ? KuboArt.tint(mood) : null) : null);
    if (gc) {
      const g = new THREE.Mesh(new THREE.BoxGeometry(0.2, 0.2, 0.2), VoxMat.flat(gc, { emit: [0.6, 1.3] }));
      g.position.set(0, accessory === "crown" ? 1.28 : 1.16, 0); setEuler(g, 0.6, 0.78, 0);
      g.name = "gem";
      body.add(g);
    }
    switch (activity) {
      case "reading":
        // 書：封面＋白色內頁，往自己這邊斜
        mesh.box(new Xf(0, 0.52, 0.4), [0, 0, 0], [0.46, 0.32, 0.03], VoxMat.flat(0x3361bf));
        for (const x of [-0.105, 0.105]) mesh.box(new Xf(x, 0.53, 0.43), [0, 0, 0], [0.2, 0.28, 0.02], VoxMat.flat(0xf5f5f5));
        break;
      case "editing":
        // 鍵盤（坐著＝在桌上）
        mesh.box(Xf.identity, [0, kbY, 0.44], [0.56, 0.035, 0.2], VoxMat.flat(0x2e2e2e));
        mesh.box(Xf.identity, [0, kbY + 0.022, 0.44], [0.5, 0.01, 0.15], VoxMat.flat(0xbf99ff, { emit: [0.5, 1.2] }));
        break;
      case "running": {
        // 一台小終端機：黑底綠字「$ ▋」（坐著＝放在桌上右邊，不擋臉）
        const tn = new THREE.Mesh(new THREE.BoxGeometry(0.42, 0.28, 0.12), VoxMat.flat(0x242424));
        if (seated) tn.position.set(0.5, 0.6, 0.42); else tn.position.set(0, 0.36, 0.42);
        const face = new THREE.PlaneGeometry(0.36, 0.22);
        const fm = new THREE.MeshBasicMaterial({ map: OfficeBuilder.terminalFace, side: THREE.DoubleSide });
        for (const z of [0.061, -0.061]) { const fnode = new THREE.Mesh(face, fm); fnode.position.z = z; tn.add(fnode); }
        body.add(tn);
        break;
      }
      case "searching": {
        // 放大鏡：鏡框＋淡藍鏡片＋握把，右手舉著
        const lens = scnNode(); lens.position.set(0.42, 0.86, 0.34); lens.rotation.order = "ZYX"; lens.rotation.z = -0.35;
        const rimG = new THREE.TorusGeometry(0.13, 0.025, 12, 32); rimG.rotateX(-Math.PI / 2);
        const rn = new THREE.Mesh(rimG, VoxMat.flat(0xd9b34d)); rn.rotation.order = "ZYX"; rn.rotation.x = Math.PI / 2; lens.add(rn);
        const gn = new THREE.Mesh(new THREE.CylinderGeometry(0.12, 0.12, 0.01, 24), VoxMat.flat(0x99d9ff, { emit: [0.6, 1.0] }));
        gn.rotation.order = "ZYX"; gn.rotation.x = Math.PI / 2; setOpacity(gn, 0.55); lens.add(gn);
        const hn = new THREE.Mesh(new THREE.BoxGeometry(0.05, 0.2, 0.05), VoxMat.flat(0x593823)); hn.position.y = -0.23; lens.add(hn);
        body.add(lens);
        break;
      }
      case "thinking":
        // 頭上旁邊一顆想法泡泡「…」：白泡泡＋三顆深色方點（純方塊）
        mesh.box(Xf.identity, [-0.62, 1.16, 0.1], [0.42, 0.22, 0.06], VoxMat.flat(0xf7f7f7));
        for (let i = 0; i < 3; i++) mesh.box(Xf.identity, [-0.74 + i * 0.12, 1.16, 0.14], [0.06, 0.06, 0.02], VoxMat.flat(0x2F3338));
        mesh.box(Xf.identity, [-0.38, 0.95, 0.1], [0.07, 0.07, 0.07], VoxMat.flat(0xf7f7f7));
        mesh.box(Xf.identity, [-0.31, 0.88, 0.1], [0.05, 0.05, 0.05], VoxMat.flat(0xf7f7f7));
        break;
      default: break;      // 交辦：旁邊的小 Kubo 就是（makePerson 畫）
    }
    if (cup) mesh.box(Xf.identity, [0.45, 0.68, 0.18], [0.12, 0.16, 0.12], VoxMat.flat(0xf5f0e6));
    // 配件
    switch (accessory) {
      case "crown": {
        const gold = VoxMat.flat(0xffcc33, { emit: [0.5, 1.0] });
        mesh.box(Xf.identity, [0, 0.95, 0], [0.5, 0.1, 0.4], gold);
        for (const [x, z] of [[-0.2, -0.15], [0.2, -0.15], [-0.2, 0.15], [0.2, 0.15], [0, 0.15]]) mesh.box(Xf.identity, [x, 1.04, z], [0.09, 0.1, 0.09], gold);
        break;
      }
      case "headset":
        mesh.box(Xf.identity, [0, 0.94, 0], [0.7, 0.05, 0.08], VoxMat.flat(0x262626));
        for (const x of [-0.35, 0.35]) mesh.box(Xf.identity, [x, 0.7, 0], [0.06, 0.2, 0.16], VoxMat.flat(0x262626));
        break;
      case "glasses":
        mesh.box(Xf.identity, [0, 0.69, 0.265], [0.5, 0.04, 0.02], VoxMat.flat(0x1a1a1a));
        for (const x of [-0.14, 0.14]) mesh.box(Xf.identity, [x, 0.68, 0.27], [0.16, 0.13, 0.015], VoxMat.flat(0x1a1a1a));
        break;
      default: break;
    }
    if (cap) {
      // 保全：藍色警帽＋帽徽＋胸前盾牌
      const blue = VoxMat.flat(0x1e3a8a);
      mesh.box(Xf.identity, [0, 0.98, 0], [0.74, 0.14, 0.6], blue);
      mesh.box(Xf.identity, [0, 0.93, 0.36], [0.74, 0.04, 0.22], blue);
      mesh.box(Xf.identity, [0, 1.0, 0.31], [0.12, 0.09, 0.02], VoxMat.flat(0xfacc15, { emit: [0.4, 0.8] }));
      mesh.box(Xf.identity, [-0.15, 0.46, 0.255], [0.13, 0.15, 0.02], VoxMat.flat(0xfacc15));
    }
    insertFirst(body, mesh.node());
    // 等你＝跳三下、做完＝搖一下，之後靜止
    if (!still && intro) {
      switch (mood) {
        case "waiting": runAction(body, OfficeBuilder.hop(0.18, 3)); this.bump(3 * 0.6 + 0.2); break;
        case "finished":
          runAction(body, Act.sequence([Act.rotateBy(0, 0, 0.08, 0.6), Act.rotateBy(0, 0, -0.16, 1.2), Act.rotateBy(0, 0, 0.08, 0.6)]));
          this.bump(2.6);
          break;
        default: break;
      }
    }
    if (mood === "asleep") setOpacity(k, 0.85);
    return k;
  }

  /** 小終端機的螢幕（只畫一次）：180×110 點，2 倍 */
  static get terminalFace() {
    if (OfficeBuilder._terminalFace) return OfficeBuilder._terminalFace;
    const s = 2, cv = document.createElement("canvas"); cv.width = 180 * s; cv.height = 110 * s;
    const g = cv.getContext("2d"); g.scale(s, s);
    g.fillStyle = "rgb(8,15,10)"; g.fillRect(0, 0, 180, 110);
    g.font = `bold 30px ui-monospace, Menlo, Consolas, monospace`; g.fillStyle = "rgb(89,255,128)"; g.textBaseline = "top";
    g.fillText("$ ▋", 16, 34);
    const t = new THREE.CanvasTexture(cv); t.colorSpace = THREE.SRGBColorSpace;
    return (OfficeBuilder._terminalFace = t);
  }

  // MARK: 前台・保全（大廳；規範 §3.4：站在前台右側、不被櫃台擋住）

  static guardColor(l) {
    switch (l) {
      case "notice": return VoxMat.color(0xfacc15);
      case "alert": return VoxMat.color(0xef4444);
      default: return VoxMat.color(0x22c55e);
    }
  }

  updateGuard(g, scanning) {
    const lobby = this.modules.get("lobby")?.parts.node;
    if (!lobby) return;
    const level = g.level ?? "normal", hasData = !!g.hasData;
    const key = `${level}|${hasData}|${scanning}`;
    if (key === this.guardKey && this.guardNode && this.guardNode.parent === lobby) return;
    this.guardKey = key;
    // 巡邏中重建（掃描開始／結束、等級變了）：記下走到第幾秒，重建後從那裡接著走
    const resume = this.patrolling && this.patrolStart !== null ? nowSec() - this.patrolStart : null;
    this.guardNode?.removeFromParent();
    const r = scnNode("guard");
    const lv = OfficeBuilder.guardColor(level), wifi = VoxMat.color(0x38bdf8);
    // 監控螢幕：左右兩面＝資安等級、中間＝Wi-Fi；警示＝三面都紅
    const gray = VoxMat.color(0x6b7280);
    const cols = !hasData ? [gray, wifi, gray] : level === "alert" ? [lv, lv, lv] : [lv, wifi, lv];
    const divZ = Tower.TowerLobby?.divZ ?? -2.65;
    cols.forEach((c, i) => {
      const s = new THREE.Mesh(new THREE.BoxGeometry(0.62, 0.36, 0.02), VoxMat.flat(c, { emit: [0.4, 1.3] }));
      s.position.set(-0.45 + i * 0.75, TD.room + 1.82, divZ + 0.235);   // 前台隔屏上的螢幕
      r.add(s);
    });
    // Wi-Fi 天線頂的寶石：掃描中會轉
    const ant = new THREE.Mesh(new THREE.BoxGeometry(0.2, 0.2, 0.2), VoxMat.flat(wifi, { emit: [0.8, 1.6] }));
    ant.position.set(1.4, TD.room + 1.78, 0.3); setEuler(ant, 0.6, 0.78, 0);
    if (scanning && !OfficeBuilder.reduceMotion) runAction(ant, Act.repeatForever(Act.rotateBy(0, Math.PI, 0, 1.2)));
    r.add(ant);
    // 保全 Kubo：深藍警帽，站在前台右側、朝鏡頭偏左 20°
    const man = scnNode("guard-man"); setPos(man, OfficeBuilder.guardPost); man.rotation.y = OfficeBuilder.guardFace;
    const k = this.makeKubo("idle", null, { seated: false, gemColor: lv, cap: true, intro: false });
    man.add(k);
    this.addHaloAndHitbox(man, 1.2);
    r.add(man);
    // 名牌與頭上符號：螢幕空間標籤（OfficeLabels「Security」），這裡只留錨點
    const anchor = scnNode("anchor"); anchor.position.set(0, 1.25 * OfficeBuilder.kuboScale + 0.1, 0);
    man.add(anchor);
    OfficeBuilder.pickable(r);
    lobby.add(r);
    this.guardNode = r;
    this.patrolling = false;
    const scanStarted = scanning && !this.wasScanning;
    this.wasScanning = scanning;
    const tp = OfficeBuilder.testPatrol;
    if (tp !== null && Tower.TripPath) {     // 測試定格：巡邏第 t 秒的位置
      man.children[0]?.add(OfficeBuilder.flashlight(this.beamLit));
      const path = this.patrolPath();
      path.apply(man, tp);
      this.poseFrontDoor(path, tp);
    } else if (resume !== null && this.startPatrol(resume, true)) {
    } else if (scanStarted && this.startPatrol(0, true)) {
      // 10-23 Kang：按「立即掃描」（或定時掃描開始）⇒ 保全馬上出門巡一趟
    } else {
      this.schedulePatrol();
    }
  }

  // MARK: 微動作（10-23 Kang：人物整天定著不動、超級死板 ⇒ 方案 A）
  // 每 3–6 秒挑 1～2 個在座位／休息點（不在路上）的人做一個 1 秒左右的小動作，做完畫面又停下（bump 只多畫那一下）

  scheduleFidget() {
    if (OfficeBuilder.reduceMotion || OfficeBuilder.testMode) return;
    this.after(randIn(3, 6), () => { this.fidget(); this.scheduleFidget(); });
  }

  fidget() {
    if (this.moving) return;
    // 鏡頭在地下室：只動 B1 的人（地上的看不到，動了白畫）；在地上反過來
    const pool = [...this.persons.values()].filter(p => !p.place.startsWith("trip:") && p.place !== "" && p.place.startsWith("b1:") === this.underground);
    for (const p of shuffled(pool).slice(0, randInt(1, 2))) {
      const body = child(p.node, "body");
      if (!body || hasActions(body)) continue;
      const [a, d] = OfficeBuilder.fidgetAction(p.mood, p.islander.card.activity, !p.place.startsWith("desk:"));
      runAction(body, a);
      this.bump(d);
    }
  }

  /** 回傳 [動作, 秒數]。全部是「做完回到原位」的相對動作 ⇒ 疊不歪 */
  static fidgetAction(mood, act, resting) {
    const swing = ({ x = 0, y = 0, z = 0 }, t, hold = 0) => {
      const go = Act.rotateBy(x, y, z, t); go.timingMode = "easeInEaseOut";
      const back = Act.rotateBy(-x, -y, -z, t); back.timingMode = "easeInEaseOut";
      return [Act.sequence([go, Act.wait(hold), back]), t * 2 + hold];
    };
    switch (mood) {
      case "waiting": return [OfficeBuilder.hop(0.1, 1), 0.6];
      case "finished": return swing({ z: 0.08 }, 0.35, 0.1);
      case "stuck": return swing({ z: -0.1 }, 0.4, 0.4);
      case "asleep": {
        const up = Act.scale(1.04, 0.9), down = Act.scale(1, 0.9);
        return [Act.sequence([up, down]), 1.8];
      }
      case "idle":
        if (resting && randBool()) return swing({ y: randBool() ? 0.6 : -0.6 }, 0.4, 1.6);   // 轉頭跟旁邊的人聊天
        return swing({ x: -0.12 }, 0.35, 0.5);                                                // 喝一口
      default:
        switch (act) {
          case "reading": return swing({ x: 0.1 }, 0.3, 0.2);
          case "thinking": return swing({ z: randBool() ? 0.12 : -0.12 }, 0.4, 0.5);
          case "searching": return swing({ y: randBool() ? 0.4 : -0.4 }, 0.35, 0.3);
          case "editing": return swing({ x: 0.05 }, 0.2);
          default: return swing({ y: randBool() ? 0.25 : -0.25 }, 0.3, 0.4);
        }
    }
  }

  // MARK: 保全巡邏（10-23 Kang：保全偶爾要帶手電筒去巡貨櫃場、大樓周圍、電力站）
  // 每 6–10 分鐘一趟：前台 → 大門 → 廣場 → 電廠正門（停下照一照）→ 回廣場 → 匯流道 → 貨櫃場入口（停下照一照）→ 原路回崗位。
  // 共用閒晃的 TripPath（折線節點、步行 1.1 m/s）；警示（三面螢幕都紅）時守在螢幕前；減少動態、搬家中、鏡頭在地下室時不出發

  static guardPost = [2.25, TD.room, -0.3];
  static guardFace = -0.35;

  schedulePatrol() {
    this.patrolGen += 1;
    const gen = this.patrolGen;
    if (OfficeBuilder.reduceMotion || OfficeBuilder.testMode) return;
    this.after(randIn(360, 600), () => { if (this.patrolGen !== gen) return; this.startPatrol(); });
  }

  /** 回傳 true＝出發了（測試／手動觸發也走這裡） */
  startPatrol(elapsed = 0, force = false) {
    const ok = this._startPatrol(elapsed, force);
    if (!this.patrolling) this.schedulePatrol();
    return ok;
  }
  _startPatrol(elapsed, force) {
    // force（掃描觸發、重建後接著走）：警示等級也照走；搬家中、地下室、減少動態仍不走
    const man = child(this.guardNode, "guard-man", false), kubo = man?.children[0];
    if (this.patrolling || !(force || this.guardLevel !== "alert") || this.moving || this.underground || OfficeBuilder.reduceMotion || !man || !kubo || !Tower.TripPath) return false;
    const path = this.patrolPath();
    if (!(elapsed < path.duration)) return false;
    this.patrolling = true;
    this.patrolStart = nowSec() - elapsed;
    const light = OfficeBuilder.flashlight(this.beamLit);
    kubo.add(light);
    this.patrolGen += 1;                          // 新的一趟：舊趟的收尾回呼、排好的下一趟都作廢
    const gen = this.patrolGen;
    const rest = path.duration - elapsed;
    path.apply(man, elapsed);
    Tower.TripPath.run(path, elapsed, man, () => this.endPatrol(gen));
    this.walkUntil = Math.max(this.walkUntil, nowSec() + rest);
    this.bump(rest);
    this.scheduleFrontDoor(path, this.patrolStart, nowSec());
    if (elapsed === 0) console.log(`OFFICE 保全出門巡邏 ${Math.trunc(path.duration)} 秒${force ? "（掃描觸發）" : ""}`);
    // 動畫沒推進（視窗被蓋住）時 done 不會來：時間到了照樣收回崗位
    this.after(rest + 5, () => this.endPatrol(gen));
    return true;
  }

  endPatrol(gen) {
    const man = child(this.guardNode, "guard-man", false);
    if (!this.patrolling || gen !== this.patrolGen || !man) return;
    this.patrolling = false; this.patrolStart = null;
    removeAction(man, "trip");
    child(man.children[0], "flashlight", false)?.removeFromParent();
    setPos(man, OfficeBuilder.guardPost); man.rotation.y = OfficeBuilder.guardFace;
    const d = this.frontDoor;
    if (d) runDoorS(d, [], nowSec(), "front");     // 提早收回崗位：開著的門關起來
    this.schedulePatrol();
  }

  // MARK: 1 樓正門（10-25 Kang：對開電動側滑玻璃門，有人進出才開）

  get frontDoor() { return child(this.modules.get("lobby")?.parts.node, "fdoor", false); }

  /** 照行程排正門：人走進門口 1.4 公尺內提早 doorTime 開；最後一個人離開 1 秒後才關。一次性動作 */
  scheduleFrontDoor(path, start, now) {
    const d = this.frontDoor;
    if (!d) return;
    const stops = this.frontDoorStops(path, start);
    const end = runDoorS(d, stops, now, "front");
    this.bump(Math.max(0.1, end - now + 0.1));
    if (OfficeBuilder.trace) console.log("office front door", stops.map(s => [Math.trunc(s.from - start), Math.trunc(s.to - start)]));
  }

  /** 測試定格（SHOWORK_OFFICE_PATROL=t）：正門擺成巡邏第 t 秒該有的開度 */
  poseFrontDoor(path, t) {
    const d = this.frontDoor;
    if (!d) return;
    const s = 0, at = s + t, dt = TowerCore.doorTime;
    let k = 0;
    for (const st of this.frontDoorStops(path, s)) if (at >= st.from && at <= st.to) k = Math.min(1, (at - st.from) / dt, (st.to - at) / dt);
    TowerCore.setDoor(d, k, "front");
    console.log(`office front door t=${t} open=${k.toFixed(2)} stops=${JSON.stringify(this.frontDoorStops(path, s).map(x => [Math.trunc(x.from - s), Math.trunc(x.to - s)]))}`);
  }

  frontDoorStops(path, start) {
    const c = [TowerCore.frontX, TD.zF];
    const near = [];
    let enter = null, t = 0.0;
    while (t <= path.duration + 0.1) {
      const q = path.pose(t).p;
      const isNear = Math.hypot(q[0] - c[0], q[2] - c[1]) < 1.4;
      if (isNear && enter === null) enter = t;
      if (!isNear && enter !== null) { near.push({ from: start + enter, to: start + t }); enter = null; }
      t += 0.1;
    }
    if (enter !== null) near.push({ from: start + enter, to: start + path.duration });
    // 開：提早 doorTime；關：離開後 1 秒＋關門動畫；兩段重疊或接著就合併（不會關到一半又開）
    const stops = [];
    for (const n of near) {
      const s = n.from - TowerCore.doorTime, e = n.to + 1 + TowerCore.doorTime;
      const last = stops[stops.length - 1];
      if (last && s <= last.to + TowerCore.doorTime) last.to = Math.max(last.to, e);
      else stops.push({ from: s, to: e });
    }
    return stops;
  }

  /** 巡邏路線（大廳模組本地座標；模組不轉 ⇒ 室外 = 世界座標減大廳高度） */
  patrolPath() {
    const out = (CityBuilder.ry ?? 0) - this.floorY("lobby");
    const doorX = TowerCore.frontX, plazaZ = TD.zF + 0.8;
    // 10-25 大門搬到正中央（前台正前方）：從崗位先繞到前台右前方再走向門口，不穿過前台
    const deskTurn = [1.95, TD.room, 1.3];
    const P = CityBuilder.powerX, PZ = CityBuilder.powerZ;
    let pts = [                    // [位置, 到了停幾秒]
      [deskTurn, 0],
      [[doorX, TD.room, TD.zF - 0.6], 0],
      [[doorX, out, plazaZ], 0],
      [[P, out, plazaZ], 0],
      [[P, out, PZ + 2.4], 4],     // 電廠正門前：照一照
      [[P, out, plazaZ], 0],
    ];
    if ((this.city.state?.disks ?? []).length) {
      const yz = CityBuilder.yardZ(0), T = CityBuilder.trunkX;    // 第一座堆場的中線
      pts = pts.concat([[[T, out, plazaZ], 0], [[T, out, yz], 0],
        [[-13.4, out, yz], 4],                                     // 堆場入口：照一照貨櫃
        [[T, out, yz], 0], [[T, out, plazaZ], 0]]);
    }
    pts = pts.concat([[[doorX, out, plazaZ], 0], [[doorX, TD.room, TD.zF - 0.6], 0], [deskTurn, 0], [OfficeBuilder.guardPost, 0]]);
    const keys = [{ t: 0, p: OfficeBuilder.guardPost, face: OfficeBuilder.guardFace, ride: false }];
    let t = 0.0, last = OfficeBuilder.guardPost;
    for (const [p, stay] of pts) {
      t += len3(sub(p, last)) / 1.1;
      keys.push({ t, p, face: null, ride: false });
      if (stay > 0) {
        // 停下：面向原本走的方向（照向電廠／貨櫃），左右掃一下
        const d = sub(p, last), f = Math.atan2(d[0], d[2]);
        // 抵達那一點仍是走路（ride 會讓「走過來」那段變成滑過來、腳不動）
        keys[keys.length - 1] = { t, p, face: f, ride: false };
        keys.push({ t: t + stay * 0.33, p, face: f + 0.5, ride: true });
        keys.push({ t: t + stay * 0.66, p, face: f - 0.5, ride: true });
        t += stay;
        keys.push({ t, p, face: f, ride: true });
      }
      last = p;
    }
    keys.push({ t: t + 0.01, p: OfficeBuilder.guardPost, face: OfficeBuilder.guardFace, ride: true });
    return new Tower.TripPath(keys);
  }

  /** 手電筒要不要開：路燈亮了（晨昏、夜晚）才開（11-01 Kang：白天巡邏不用開手電筒） */
  get beamLit() { return (this.look ?? SkyLook.day).lamps >= 0.5; }
  /** 天色換了：巡邏途中的手電筒跟著開關 */
  updateBeam() {
    const b = child(child(child(this.guardNode, "guard-man", false)?.children[0], "flashlight", false), "beam", false);
    if (!b) return;
    b.visible = this.beamLit;
  }
  /** 手電筒：右手一支＋往前的淡黃光錐（自發光、加法混色，不是真的燈）；白天光錐關著、只拿在手上 */
  static flashlight(lit) {
    const n = scnNode("flashlight");
    n.position.set(0.42, 0.62, 0.3);
    const body = new THREE.Mesh(new THREE.BoxGeometry(0.08, 0.08, 0.22), VoxMat.flat(0x262626));
    n.add(body);
    const h = 1.8;
    const cone = new THREE.CylinderGeometry(0.04, 0.36, h, 24, 1, true);
    // Swift 寫 transparency 0.22，但 SceneKit 的 additive 材質不套透明度（B1 agent 11-02 量測）⇒ 照畫面行為給 1
    const m = new THREE.MeshBasicMaterial({ color: new SColor(1, 0.93, 0.6).toThree(), transparent: true, opacity: 1,
                                            blending: THREE.AdditiveBlending, depthWrite: false, side: THREE.DoubleSide });
    // 軸心＝窄口（手上）：beam 繞 x 轉 −90° ⇒ 本地 −y 朝前；光錐掛在 −h/2，窄口（+y）剛好在軸心；再加 0.25 讓光往下照
    const beam = scnNode("beam");
    beam.position.set(0, 0, 0.13);
    beam.rotation.order = "ZYX"; beam.rotation.x = -Math.PI / 2 + 0.25;
    beam.visible = lit;
    const c = new THREE.Mesh(cone, m);
    c.position.set(0, -h / 2, 0);
    c.castShadow = false;
    beam.add(c);
    n.add(beam);
    // 10-24 Kang：光錐會穿過牆、櫃台、電廠 ⇒ 每 0.1 秒沿光軸打一條線，撞到東西就把光錐縮到撞點
    const full = h;
    runAction(n, Act.repeatForever(Act.sequence([Act.run(f => { const b = child(f, "beam", false); if (b) OfficeBuilder.clipBeam(b, full); }), Act.wait(0.1)])), "beam");
    return n;
  }

  /** 光軸從手到光錐末端打一條線，最近的非保全自己的東西 ⇒ 光錐長度縮到那裡。
   *  SceneKit hitTestWithSegment（categoryBitMask 1、不剔背面）：方塊用 voxBoxes 做射線 × 轉向方塊（雙面），其他 geometry 用 Raycaster */
  static clipBeam(beam, full) {
    const root = OfficeBuilder.sceneRoot(beam);
    if (!root) return;
    root.updateMatrixWorld(true);
    const a = new THREE.Vector3().setFromMatrixPosition(beam.matrixWorld);
    const b = new THREE.Vector3(0, -full, 0).applyMatrix4(beam.matrixWorld);
    const worldLen = a.distanceTo(b);
    if (!(worldLen > 0.01)) return;
    const dir = b.clone().sub(a).divideScalar(worldLen);
    let best = worldLen;
    const ray = new THREE.Ray(a, dir), rc = new THREE.Raycaster(a, dir, 0, worldLen);
    const inv = new THREE.Matrix4(), lo = new THREE.Vector3(), hi = new THREE.Vector3(), box = new THREE.Box3(), hit = new THREE.Vector3();
    const walk = (n, hidden) => {
      const h = hidden || !n.visible;
      if (h || n.name === "guard-man") return;
      if (n.isMesh && (category(n) & 1)) {
        if (n.userData.voxBoxes) {
          for (const vb of n.userData.voxBoxes) {
            // 方塊世界座標：node 矩陣 × 方塊（中心＋yaw）
            const m = new THREE.Matrix4().makeRotationY(vb.yaw).setPosition(vb.c[0], vb.c[1], vb.c[2]).premultiply(n.matrixWorld);
            inv.copy(m).invert();
            const lr = ray.clone().applyMatrix4(inv);
            lo.set(-vb.s[0] / 2, -vb.s[1] / 2, -vb.s[2] / 2); hi.set(vb.s[0] / 2, vb.s[1] / 2, vb.s[2] / 2);
            box.set(lo, hi);
            if (lr.intersectBox(box, hit)) { hit.applyMatrix4(m); const d = a.distanceTo(hit); if (d < best) best = d; }
          }
        } else {
          const r = rc.intersectObject(n, false);
          if (r.length && r[0].distance < best) best = r[0].distance;
        }
      }
      for (const c of n.children) walk(c, h);
    };
    walk(root, false);
    const k = Math.max(0.04, best / worldLen);
    if (Math.abs(beam.scale.y - k) > 0.01) beam.scale.set(1, k, 1);
  }

  static sceneRoot(n) { let p = n; while (p.parent) p = p.parent; return p === n ? null : p; }
  static isGuard(n) { let p = n; while (p) { if (p.name === "guard-man") return true; p = p.parent; } return false; }

  // MARK: 樓層看板（大樓左外側、電梯外；只在鏡頭近時顯示）

  static boardKey(i) {
    return i.people.slice(0, OfficeBuilder.maxPeople).map(p => {
      const c = p.card;
      return `${c.title}|${p.mood}|${c.report?.progress ?? c.review?.progress ?? -1}|${c.report?.confidence ?? c.review?.confidence ?? -1}|${Math.trunc(c.ctx?.percent ?? -1)}|${officeLine(c)}|${c.tokens ? tokenShort(tokTotal(c.tokens)) : ""}`;
    }).join("\n") + `|${i.queued ?? 0}|${i.people.length}`;
  }

  /** 看不到的看板只記下「內容過期」，等鏡頭停在附近（updateLOD）要顯示時才畫；內容沒變永遠不重畫 */
  boardWorld(fid) {
    const m = this.modules.get(fid);
    if (!m) return null;
    const p = m.parts.node.position;
    return [TD.boardX, p.y + TD.room + 0.2, TD.boardZ];
  }
  boardNear(fid) {
    const q = this.boardWorld(fid);
    if (!q) return false;
    return Math.hypot(Math.hypot(this.lodAt[0] - q[0], this.lodAt[1] - q[1]), this.lodAt[2] - q[2]) <= OfficeBuilder.boardDistance;
  }

  updateBoards(byKey) {
    const has = k => { const f = Plan.floor(this.tower, k); const i = f && byKey.get((f.project ?? "").toLowerCase()); return i ? i.people.length > 0 : false; };
    for (const [k, b] of [...this.boards]) if (!has(k)) { b.node.removeFromParent(); this.boards.delete(k); }
    for (const k of [...this.boardStale.keys()]) if (!has(k)) this.boardStale.delete(k);
    for (const f of this.projectFloors()) {
      const i = byKey.get((f.project ?? "").toLowerCase());
      if (!i || !i.people.length || !this.modules.has(f.id)) continue;
      const key = OfficeBuilder.boardKey(i);
      const b = this.boards.get(f.id);
      if (b?.key === key && b.node.parent) { this.boardStale.delete(f.id); continue; }
      if (!this.boardNear(f.id)) { this.boardStale.set(f.id, i); if (b) b.node.visible = false; continue; }
      this.drawBoard(f.id, i, key);
    }
    this.lodDirty = true;
  }

  drawBoard(fid, i, key) {
    const f = Plan.floor(this.tower, fid), mod = this.modules.get(fid);
    if (!f || !mod) return;
    this.boards.get(fid)?.node.removeFromParent();
    this.boardStale.delete(fid);
    const d = this.decor[(f.project ?? "").toLowerCase()];
    const ah = d ? TP.hex(d.accentColor ?? "") : null;
    const accent = ah !== null && ah !== undefined ? VoxMat.color(ah) : VoxMat.color(TP.FN4);
    const n = this.makeBoard(i, accent);
    n.position.set(TD.boardX, TD.room + 0.2, TD.boardZ);
    n.visible = true;
    mod.parts.node.add(n);
    this.boards.set(fid, { node: n, key });
    this.boardsDrawn += 1;
    if (OfficeBuilder.trace) console.log("office redraw board", fid, "total", this.boardsDrawn);
  }

  makeBoard(i, color) {
    const [cv, iw, ih] = OfficeBuilder.boardImage(i, color);
    let w = 4.4;
    let h = w * ih / iw;
    if (h > 3.2) { w *= 3.2 / h; h = 3.2; }          // 不高過一層樓
    const t = new THREE.CanvasTexture(cv);
    t.colorSpace = THREE.SRGBColorSpace;
    t.minFilter = THREE.LinearMipmapLinearFilter; t.magFilter = THREE.LinearFilter; t.generateMipmaps = true;
    const m = new THREE.MeshBasicMaterial({ map: t, side: THREE.DoubleSide });
    // 節點＝billboard 轉軸（SCNBillboardConstraint freeAxes .Y）；pivot（底邊對齊位置、往鏡頭那側讓出 0.14）＝子節點的位移
    const n = scnNode("board");
    const plane = new THREE.Mesh(new THREE.PlaneGeometry(w, h), m);
    plane.position.set(0, h / 2, 0.14);
    n.add(plane);
    n.userData.billboardY = true;
    return n;
  }

  // MARK: 鏡頭停下來時算一次：看板遠近、cutaway、門牌換牆、夜晚 omni 指派

  /** 回傳有沒有改到畫面（有的話要補畫一下） */
  updateLOD(p, target) {
    const ug = this.setUnderground(p[1] < 0);
    if (!(this.lodDirty || Math.hypot(Math.hypot(p[0] - this.lodAt[0], p[1] - this.lodAt[1]), p[2] - this.lodAt[2]) > 0.5)) return ug;
    this.lodDirty = false; this.lodAt = p.slice();
    for (const [fid, b] of this.boards) {
      const h = !this.boardNear(fid) || this.boardStale.has(fid);
      if (b.node.visible !== !h) b.node.visible = !h;
    }
    // 內容過期、現在走近了：這時才重畫
    for (const [fid, i] of [...this.boardStale]) if (this.boardNear(fid)) this.drawBoard(fid, i, OfficeBuilder.boardKey(i));
    const mast = child(this.core, "board-mast", false);
    if (mast) {
      const h = ![...this.boards.values()].some(b => b.node.visible);
      if (mast.visible !== !h) mast.visible = !h;
    }
    if (Math.abs(this.focusY - target[1]) > 0.5) { this.focusY = target[1]; this.omniDirty = true; }
    this.weatherFX.aim();
    // 鏡頭到大樓外框最近的距離（10-22 Kang：拉近到樓頂時樓板被 zNear 切成三角形）；下緣到地下室土層底
    const lo = [-TD.W / 2 - 1, OfficeBasement.bottomY, TD.zB - 2], hi = [TD.W / 2 + 1, this.totalHeight() + 3, TD.zF + 1];
    const cl = [0, 1, 2].map(i => Math.min(Math.max(p[i], lo[i]), hi[i]));
    const near = Math.hypot(p[0] - cl[0], p[1] - cl[1], p[2] - cl[2]);
    this.weatherFX.setInside(near === 0);   // 鏡頭鑽進大樓：擋雨盒從裡面看不到 ⇒ 雨直接藏起來
    this.updateFog(Math.hypot(Math.hypot(p[0] - target[0], p[1] - target[1]), p[2] - target[2]), near);
    this.assignOmni();
    return this.applyCutaway(p) || ug;
  }

  // MARK: 地下室 B1（10-22）

  /** 換神經網路的資料（GraphSource 讀到新的 Graphify 圖譜時呼叫） */
  setNeuralGraph(g) { this.basement.setGraph(g); this.bump(0.2); }
  /** 圖譜正在自轉（鏡頭在地下室）：畫面迴圈依這個持續渲染 */
  get basementSpinning() { return !!this.basement.spinning; }

  /** 鏡頭進出地下室：地下 ⇒ 大地面、城市淡出藏起來、雨停在地上、B1 出現並開始轉；回到地上全部恢復。回傳有沒有變 */
  setUnderground(u) {
    if (u === this.underground) return false;
    this.underground = u;
    this.basement.setLive(u, !OfficeBuilder.reduceMotion);
    this.weatherFX.setHidden(u);
    const ground = [this.env, this.city.root];
    SCNTransaction.begin(); SCNTransaction.animationDuration = OfficeBuilder.testMode ? 0 : OfficeBuilder.cutFade;
    for (const n of ground) {
      if (u) SCNTransaction.opacity(n, 0); else { n.visible = true; SCNTransaction.opacity(n, 1); }
    }
    SCNTransaction.completionBlock = () => {
      setTimeout(() => {
        if (!this.underground) return;
        for (const n of ground) if (opacityOf(n) === 0) n.visible = false;
      }, 0);
    };
    SCNTransaction.commit();
    this.cutSig = ""; this.lodDirty = true;      // B1 的牆、玻璃馬上套 cutaway
    this.applyLights();          // HDR／泛光跟著切
    if (OfficeBuilder.trace) console.log("office underground", u);
    return true;
  }

  /** 霧距＝鏡頭到轉軸距離 ×1.3 → ×2.6（至少 60 → 230）；zFar 跟著霧；zNear 鏡頭遠時拉大、最近距離的一半為上限。只在鏡頭停下時算 */
  updateFog(d, near) {
    this.camera.near = Math.min(Math.max(d * 0.02, 1), 4, Math.max(near * 0.5, 0.15));
    this.camera.updateProjectionMatrix();
    if (!(Math.abs(d - this.fogDist) > Math.max(1, this.fogDist * 0.04))) return;
    this.fogDist = d;
    this.weatherFX.size(d);
    this.fogStart = Math.max(d * 1.3, 60); this.fogEnd = Math.max(d * 2.6, 230);
    this.applyFog();
    this.camera.far = Math.max(500, this.fogEnd * 1.15);
    this.camera.updateProjectionMatrix();
  }

  /** 面向鏡頭的實心牆淡掉不畫（玻璃不藏），其他照常；門牌搬到離鏡頭最遠的那面牆（規範 §3.6） */
  applyCutaway(p) {
    let v = [p[0], p[2]];
    const len = Math.hypot(v[0], v[1]);
    v = len < 0.1 ? [0, 1] : [v[0] / len, v[1] / len];
    const d2 = (a, b) => a[0] * b[0] + a[1] * b[1];
    const N = TowerModules.normals;
    const facing = N.map(n => d2(n, v) > OfficeBuilder.cutDot).concat(this.coreFacades.map(f => d2(f.n, v) > f.cut));
    let far = 0;
    for (let i = 1; i < N.length; i++) if (d2(N[i], v) < d2(N[far], v)) far = i;
    const sig = facing.map(x => (x ? "1" : "0")).join("") + `|${far}`;
    if (sig === this.cutSig) return false;
    this.cutSig = sig; this.cutV = v; this.cutFar = far;
    // 0.25 秒淡到 0，淡完設 isHidden（真的不送進渲染）；要顯示的先取消 isHidden 再淡回 1
    SCNTransaction.begin(); SCNTransaction.animationDuration = OfficeBuilder.testMode ? 0 : OfficeBuilder.cutFade;
    const all = [];
    const set = f => {
      const on = !f.glass && d2(f.n, v) > f.cut;      // 10-25 Kang：玻璃不擋視線，不跟著鏡頭藏
      if (on) { if (f.node.visible) SCNTransaction.opacity(f.node, 0); } else { f.node.visible = true; SCNTransaction.opacity(f.node, 1); }
      all.push(f.node);
    };
    for (const m of this.modules.values()) { m.parts.facades.forEach(set); this.placePlate(m.parts, far); }
    this.coreFacades.forEach(set);
    (this.basement.facades ?? []).forEach(set);
    const sigNow = sig;
    SCNTransaction.completionBlock = () => {
      const fin = () => { if (this.cutSig !== sigNow) return; for (const n of all) if (opacityOf(n) === 0 && n.visible) n.visible = false; };
      // Swift 用 DispatchQueue.main.async（下一輪才藏）：同一輪裡的 dump 是「opacity 0、還沒 hidden」，跟 Mac 一樣
      setTimeout(fin, 0);
    };
    SCNTransaction.commit();
    return true;
  }

  /** 新建（重建）的樓層／核心：直接套用目前的 cutaway（不淡出） */
  cutNow(p) {
    const v = this.cutV;
    if (v) for (const f of p.facades ?? []) { const on = !f.glass && f.n[0] * v[0] + f.n[1] * v[1] > f.cut; setOpacity(f.node, on ? 0 : 1); f.node.visible = !on; }
    if (v && p.plate !== undefined) this.placePlate(p, this.cutFar);
  }

  /** 門牌貼在哪面牆：0 後、1 前（內側）、2 左、3 右；不能貼的牆就留在後牆 */
  placePlate(p, far) {
    const plate = p.plate;
    if (!plate) return;
    const w = p.plateW, y = p.plateY, inset = 0.17;
    if (p.outsidePlate) {
      // 閒置薄層只有 0.9 高：後牆會被上一層樓板擋住 ⇒ 門牌貼在靠鏡頭那一面、朝外
      if (far === 1) { plate.position.set(w / 2, y, TD.zB - 0.02); plate.rotation.y = Math.PI; }
      else { plate.position.set(-w / 2, y, TD.zF + 0.02); plate.rotation.y = 0; }
      return;
    }
    const wall = p.plateWalls.has(far) ? far : 0;
    switch (wall) {
      case 1: plate.position.set(TD.W / 2 - 0.3, y, TD.zF - inset); plate.rotation.y = Math.PI; break;
      case 2: plate.position.set(-TD.W / 2 + inset, y, Math.min(TD.zF - 0.3, w / 2)); plate.rotation.y = Math.PI / 2; break;
      case 3: plate.position.set(TD.W / 2 - inset, y, -Math.min(TD.zF - 0.3, w / 2)); plate.rotation.y = -Math.PI / 2; break;
      default: plate.position.set(-TD.W / 2 + 0.3, y, TD.backZ + 0.02); plate.rotation.y = 0;
    }
  }

  /** 夜晚 omni：大廳 1、頂樓 1、每個專案樓層 1（只改位置；不夠才新增，多的藏起來）；白天全關。
   *  每層一盞真的燈：天花板下、樓層中央，只照大樓（光照位元分層）。外牆的外側面背對燈 ⇒ 不會亮 */
  assignOmni() {
    if (!this.omniDirty) return;
    this.omniDirty = false;
    if (!(VoxMat.lamps > 0.001)) { this.omni.forEach(o => { o.visible = false; }); return; }
    const spots = [];     // 位置、強度倍數、衰減終點
    const lobby = this.modules.get("lobby"), roof = this.modules.get("roof");
    if (lobby) spots.push([[0.3, lobby.parts.node.position.y + 3.0, 0.5], OfficeBuilder.lobbyOmni / 700, 11]);
    if (roof) spots.push([[-0.5, roof.parts.node.position.y + 2.0, 0.7], 1, 11]);
    const masks = spots.map(() => 1);          // 大廳、頂樓的燈照第 0 位元（照舊）
    if (OfficeBuilder.legacyNight) {           // 測試：舊版夜晚（離鏡頭焦點最近 4 層各一盞、不分層）
      const ys = this.projectFloors().flatMap(f => { const m = this.modules.get(f.id); return m ? [m.parts.node.position.y] : []; });
      for (const y of ys.sort((a, b) => Math.abs(a + 1.4 - this.focusY) - Math.abs(b + 1.4 - this.focusY)).slice(0, 4)) {
        spots.push([[0.1, y + TD.room + TD.clear - 0.35, 0.5], 1, 11]); masks.push(~OfficeBasement.mask);
      }
    }
    (OfficeBuilder.legacyNight ? [] : this.projectFloors()).forEach((f, i) => {
      const m = this.modules.get(f.id);
      if (!m) return;
      const bit = OfficeBuilder.floorLightBit(i);
      enumerateHierarchy(m.parts.node, n => { if (n.isMesh) setCategory(n, (category(n) & ~OfficeBuilder.floorLightBits) | bit); });
      for (const g of m.parts.facades) if (g.glass) {      // 玻璃不吃室內燈（不然整片玻璃被從裡面照亮）
        enumerateHierarchy(g.node, n => setCategory(n, category(n) & ~OfficeBuilder.floorLightBits));
      }
      spots.push([[0.1, m.parts.node.position.y + TD.room + TD.clear - 0.35, TD.zC + 0.4], OfficeBuilder.floorOmni / 700, OfficeBuilder.floorRange]);
      masks.push(bit);
    });
    while (this.omni.length < spots.length) {
      const l = scnLight({ type: "omni", color: TP.LT1, mask: 1, start: 1, end: 11 });
      l.visible = false;
      this.world.add(l); this.omni.push(l);
    }
    this.omni.forEach((o, i) => {
      if (i >= spots.length) { o.visible = false; return; }
      o.position.set(...spots[i][0]); o.visible = true;
      o.intensity = scnIntensity(this.omniBase * spots[i][1]);
      o.distance = spots[i][2];
      o.userData.att = [1, spots[i][2], 2];
      o.userData.cat = masks[i];
    });
    if (OfficeBuilder.trace) console.log("office omni", spots.length, `盞 base=${Math.trunc(this.omniBase)} floors=${this.projectFloors().length} modules=${this.modules.size}`);
  }

  // MARK: 取景

  /** 預設取景的上下範圍：有人的專案樓層上下各多 0.4 層；大廳只在保全「注意」以上才框；頂樓只露樓板 */
  frameRange() {
    const pf = this.projectFloors();
    const occupied = pf.filter(f => f.seats > 0);
    const floors = occupied.length ? occupied : pf;
    if (!floors.length) return [-0.2, this.totalHeight() + 0.8];
    const first = floors[0], last = floors[floors.length - 1];
    const pad = 0.4 * TowerSpec.floorHeight;
    let lo = first.y - pad, hi = last.y + last.height + pad;
    // 頂樓：預設鏡頭只露頂樓樓板（一條線），不露半截樹
    const roof = this.floor("roof");
    if (roof && Math.abs(roof.y - (last.y + last.height)) < 0.01) hi = roof.y + TowerSpec.slab + 0.15;
    const lobby = this.floor("lobby");
    if (this.guardLevel !== "normal" && lobby) lo = Math.min(lo, lobby.y + 0.4 * lobby.height);   // 只框到保全頭頂＋名牌
    // 閒置薄層緊貼在最低那層專案樓層下面：多框的 0.4 層不要讓它露出太多（≤ 薄層一半）
    const idle = this.tower.floors.find(f => f.kind === "idle");
    if (this.guardLevel === "normal" && idle && idle.y + idle.height <= first.y + 0.01) lo = Math.max(lo, idle.y + idle.height * 0.5);
    return [lo, hi];
  }
  /** 從右前方、略高一點看「有人的樓層」（方位 16°、仰角 12°） */
  frameCamera(aspect = this.aspect) {
    aspect = Math.max(0.4, aspect);
    const [lo, hi] = this.frameRange();
    const az = OfficeBuilder.azimuth, el = OfficeBuilder.elevation;
    // 寬度是瓶頸：框「正面＋前緣往後 4.8 公尺」就好
    const [dist, t] = OfficeBuilder.fit([-TD.Wd / 2, lo, TD.zFd - 4.8], [TD.Wd / 2, hi, TD.zFd], aspect, az * Math.PI / 180, el * Math.PI / 180, 34, 1.02);
    this.place(t, dist, az, el);
  }
  /** 點左側索引列的樓層：鏡頭拉近到這層（框「這層的人＋左右各一段」） */
  frameFloor(id, aspect = this.aspect) {
    const f = this.floor(id), m = this.modules.get(id);
    if (!f || !m) return false;
    const y = m.parts.node.position.y;
    aspect = Math.max(0.4, aspect);
    const h = Math.max(f.height, 1.2);
    const xs = [...this.persons.values()].filter(p => p.floor === id).map(p => p.node.position.x);
    const cx = xs.length ? (Math.min(...xs) + Math.max(...xs)) / 2 : 0.1;
    // 閒置薄層只有 0.9 公尺高：照高度算會拉到只剩 1.5 公尺寬 ⇒ 一律框整層寬
    const half = f.kind === "idle" ? TD.Wd / 2 : Math.min(TD.Wd / 2, Math.max(h / 0.5 * aspect * 0.42, xs.length ? (Math.max(...xs) - Math.min(...xs)) / 2 + 1.2 : 0));
    const c = Math.min(Math.max(cx, -TD.Wd / 2 + half), TD.Wd / 2 - half);
    const [dist, t] = OfficeBuilder.fit([c - half, y + TD.room - 0.05, -0.4], [c + half, y + h, TD.zFd], aspect,
      OfficeBuilder.azimuth * Math.PI / 180, OfficeBuilder.elevation * Math.PI / 180, 34, 0.98);
    this.place(t, dist, OfficeBuilder.azimuth, OfficeBuilder.elevation);
    return true;
  }
  /** 測試：SHOWORK_OFFICE_CAM 定鏡頭 */
  placeTest(t, dist, az, el) { this.place(t, dist, az, el); }
  place(t, dist, az, el) {
    const d = OfficeBuilder.dir(az * Math.PI / 180, el * Math.PI / 180);
    // 第一次取景直接定位（不從原點飛過來）；測試視窗一律直接定位
    const first = !this.framedOnce; this.framedOnce = true;
    const pos = [t[0] + d[0] * dist, t[1] + d[1] * dist, t[2] + d[2] * dist];
    // look(at:up:localFront:)：算出目標朝向（不動目前的值，交給 transaction 慢慢轉過去）
    const probe = new THREE.Object3D();
    probe.position.set(...pos); probe.up.set(0, 1, 0); probe.lookAt(t[0], t[1], t[2]);
    // three 的 Object3D.lookAt 對非鏡頭物件是 +z 朝目標；鏡頭要 −z 朝目標 ⇒ 用 Matrix4.lookAt(eye, target, up)
    const q = new THREE.Quaternion().setFromRotationMatrix(new THREE.Matrix4().lookAt(new THREE.Vector3(...pos), new THREE.Vector3(...t), new THREE.Vector3(0, 1, 0)));
    SCNTransaction.begin(); SCNTransaction.animationDuration = first || OfficeBuilder.testMode ? 0 : 0.5;
    SCNTransaction.position(this.camera, pos);
    SCNTransaction.quaternion(this.camera, q);
    SCNTransaction.commit();
    this.camera.up.set(0, 1, 0);
    this.camera.userData.modelPos = pos;
    this.camera.updateMatrixWorld(true);
    this.target = t.slice();
    if (this.camera.isOrthographicCamera) this.onOrtho?.(dist);      // OfficeStyleFX.orthoScale（stylefx.js）
    this.lodDirty = true; this.focusY = t[1]; this.omniDirty = true;
  }
  /** 鏡頭位置（model 值：取景動畫中也回終點，跟 SceneKit 的 camera.position 一樣） */
  get cameraPosition() { const m = this.camera.userData.modelPos; if (m) return m.slice(); const p = this.camera.position; return [p.x, p.y, p.z]; }

  /** 樓層在畫面上的高度（像素）與樓板寬佔畫面寬的比例（PROBE 量驗收用） */
  floorPixels(width, height) {
    const proj = (x, y, z) => { const v = new THREE.Vector3(x, y, z).project(this.camera); return [(v.x + 1) / 2 * width, (1 - v.y) / 2 * height]; };
    return this.tower.floors.flatMap(f => {
      const m = this.modules.get(f.id);
      if (!m) return [];
      const y = m.parts.node.position.y;
      const a = proj(0, y, TD.zF), b = proj(0, y + f.height, TD.zF), l = proj(-TD.W / 2, y, TD.zF), r = proj(TD.W / 2, y, TD.zF);
      return [[f.floorNo ? f.floorNo : f.id, Math.abs(b[1] - a[1]), Math.abs(r[0] - l[0]) / Math.max(1, width)]];
    });
  }

  static dir(az, el) { return [Math.cos(el) * Math.sin(az), Math.sin(el), Math.cos(el) * Math.cos(az)]; }

  /** 取景：鏡頭從方位 az、仰角 el 看向 target，找最近的距離讓整個外框（8 個角）都進畫面，並把投影置中 */
  static fit(lo, hi, aspect, az, el, fov = 34, margin = 0.92) {
    const ty = Math.tan(fov / 2 * Math.PI / 180) * margin, tx = ty * aspect;
    const d = OfficeBuilder.dir(az, el), f = mul(d, -1);
    const r = norm(cross(f, [0, 1, 0])), u = cross(r, f);
    const pts = [];
    for (const x of [lo[0], hi[0]]) for (const y of [lo[1], hi[1]]) for (const z of [lo[2], hi[2]]) pts.push([x, y, z]);
    const extent = (D, T) => {
      const C = add(T, mul(d, D));
      let ok = true, x0 = Infinity, x1 = -Infinity, y0 = Infinity, y1 = -Infinity;
      for (const p of pts) {
        const v = sub(p, C), depth = dot(v, f);
        if (!(depth > 0.1)) { ok = false; continue; }
        const px = dot(v, r) / depth, py = dot(v, u) / depth;
        x0 = Math.min(x0, px); x1 = Math.max(x1, px); y0 = Math.min(y0, py); y1 = Math.max(y1, py);
      }
      return { ok: ok && x0 >= -tx && x1 <= tx && y0 >= -ty && y1 <= ty, x0, x1, y0, y1 };
    };
    const search = T => {
      let a = 4.0, b = 900.0;
      for (let i = 0; i < 40; i++) { const m = (a + b) / 2; if (extent(m, T).ok) b = m; else a = m; }
      return b;
    };
    let T = mul(add(lo, hi), 0.5), D = search(T);
    for (let i = 0; i < 4; i++) {
      const e = extent(D, T);
      T = add(T, add(mul(r, (e.x0 + e.x1) / 2 * D), mul(u, (e.y0 + e.y1) / 2 * D)));
      D = search(T);
    }
    return [Math.max(D, 8), T];
  }

  // MARK: 量測

  /** 大樓由下往上（PROBE 印出來比） */
  towerLayout() { return this.tower.floors.map(f => `${f.floorNo ? f.floorNo + ":" : ""}${f.project ?? f.id}@${f.y.toFixed(1)}`).join(" "); }

  /** 節點數、估計的 draw call（看得到的 geometry 數；opacity 0 的算看不到）、燈數、材質快取數；另附每層的 draw call */
  stats() {
    let nodes = 0, lights = 0;
    const walk = (n, hidden) => {
      nodes += 1;
      const h = hidden || !n.visible || n.userData.opacity === 0;
      let c = 0;
      if (!h && n.isMesh) c += Array.isArray(n.material) ? n.material.length : 1;
      if (!h && n.isLight) lights += 1;
      for (const ch of n.children) c += walk(ch, h);
      return c;
    };
    const calls = walk(this.scene, false);
    const per = [], items = [];
    for (const f of this.tower.floors) {
      const m = this.modules.get(f.id);
      if (!m) continue;
      const tag = f.floorNo ? f.floorNo : f.id;
      per.push(`${tag}=${this.walkCount(m.parts.node)}`);
      if (f.kind === "project") items.push(`${tag}=${m.parts.items}件/前帶${m.parts.front}/桌面${m.parts.deskItems}/${this.decor[(f.project ?? "").toLowerCase()]?.theme ?? "general"}`);
    }
    const bs = [...this.boards.values()];
    return `nodes=${nodes} drawcalls≈${calls} city=${this.walkCount(this.city.root)} lights=${lights} materials=${VoxMat.count} people=${this.persons.size} boards=${bs.length}/visible ${bs.filter(b => b.node.visible).length}/drawn ${this.boardsDrawn}/stale ${this.boardStale.size} floors[${per.join(" ")}] items[${items.join(" ")}]`;
  }
  walkCount(n) {
    if (!n.visible || n.userData.opacity === 0) return 0;
    return (n.isMesh ? (Array.isArray(n.material) ? n.material.length : 1) : 0) + n.children.reduce((s, c) => s + this.walkCount(c), 0);
  }

  /** 看板內容沿用第二版（每人📈🎯🧠🔤＋一句回報），外框換成像素木框。回傳 [canvas, 寬, 高]（點；canvas 是 2.5 倍） */
  static boardImage(i, color) {
    const people = i.people.slice(0, OfficeBuilder.maxPeople);
    const W = 560, rowH = 70, headH = 64, fr = 14;
    const H = headH + Math.max(people.length, 1) * rowH + ((i.queued ?? 0) > 0 ? 34 : 0) + 14 + fr;
    const accent = color;
    const S = 2.5, cv = document.createElement("canvas");
    cv.width = Math.trunc(W * S); cv.height = Math.trunc(H * S);
    const g = cv.getContext("2d"); g.scale(S, S);
    const rgb = (r, gg, b, a = 1) => `rgba(${Math.round(r * 255)},${Math.round(gg * 255)},${Math.round(b * 255)},${a})`;
    const fill = (css, x, y, w, h) => { g.fillStyle = css; g.fillRect(x, y, w, h); };
    // 木框：一格 7 點的深淺木頭
    const rng = new PixelTex.RNG(99);
    const cell = 7;
    for (let y = 0; y < H; y += cell) {
      for (let x = 0; x < W; x += cell) {
        if (!(x < fr || x >= W - fr || y < fr || y >= H - fr)) continue;
        const k = 0.78 + rng.next() * 0.3;
        fill(rgb(0x7a / 255 * k, 0x4e / 255 * k, 0x2d / 255 * k), x, y, cell, cell);
      }
    }
    fill(rgb(0.09, 0.075, 0.065, 0.96), fr, fr, W - fr * 2, H - fr * 2);
    // 標題列（部門色）：accent.blended(withFraction: 0.25, of: .black)
    fill(rgb(accent.r * 0.75, accent.g * 0.75, accent.b * 0.75), fr, fr, W - fr * 2, headH - fr - 4);
    const draw = OfficeBuilder.drawText.bind(null, g);
    draw(i.project, fr + 12, fr + 8, 28, 800, "#fff", W * 0.58);
    const counts = [["waiting", "等你"], ["stuck", "卡住"], ["finished", "做完"], ["working", "進行"], ["idle", "休息"]]
      .filter(([m]) => islandCount(i, m) > 0).map(([m, s]) => `${islandCount(i, m)} ${s}`).join("  ");
    draw(counts || "全員休息", W * 0.6, fr + 14, 19, 700, "#fff", W * 0.4 - fr - 6);
    people.forEach((p, n) => {
      const y = headH + n * rowH;
      const c = p.card, tint = KuboArt.tint(p.mood);
      fill(tint.css, fr + 10, y + 12, 14, 14);       // 方塊點（像素風）
      draw(c.title, fr + 32, y + 4, 22, 700, "#fff", W * 0.44 - fr - 36);
      const prog = c.report?.progress ?? c.review?.progress ?? null, conf = c.report?.confidence ?? c.review?.confidence ?? null;
      const ctx = c.ctx ? (c.ctx.tokens !== null && c.ctx.tokens !== undefined ? `${Math.trunc(c.ctx.tokens / 1000)}k` : `${Math.trunc(c.ctx.percent)}%`) : null;
      const tok = c.tokens ? `  🔤${tokenShort(tokTotal(c.tokens))}` : "";
      const gs = `📈${prog !== null ? `${prog}%` : "—"}  🎯${conf !== null ? `${conf}%` : "—"}  🧠${ctx ?? "—"}` + tok;
      const ctxHot = c.ctx ? ContextGuard.over(c.ctx) : false;
      draw(gs, W * 0.44, y + 7, 17, 600, ctxHot ? "rgb(255,59,48)" : rgb(0.92, 0.92, 0.92), W * 0.56 - fr - 6);
      if (prog !== null) {
        fill("rgba(255,255,255,0.12)", fr + 32, y + 56, W - fr * 2 - 44, 4);
        fill(tint.css, fr + 32, y + 56, (W - fr * 2 - 44) * Math.min(100, Math.max(0, prog)) / 100, 4);
      }
      draw(officeLine(c), fr + 32, y + 32, 17, 400,
        p.mood === "waiting" ? rgb(1, 0.6, 0.6) : c.blockedReason ? rgb(1, 0.75, 0.45) : rgb(0.75, 0.75, 0.75), W - fr * 2 - 44);
    });
    if (!people.length) draw("沒有人在這裡", fr + 12, headH + 18, 20, 400, rgb(0.6, 0.6, 0.6), W - fr * 2 - 24);
    if ((i.queued ?? 0) > 0) draw(`📥 排隊中 ${i.queued} 則`, fr + 12, H - fr - 40, 18, 500, rgb(0.78, 0.78, 0.78), W - fr * 2 - 24);
    return [cv, W, H];
  }

  /** 單行、超出寬度用「…」截掉（NSString.draw(in:) 的 byTruncatingTail；左上角＝(x, y)） */
  static drawText(g, s, x, y, size, weight, color, width) {
    g.font = `${weight} ${size}px -apple-system, "PingFang TC", "Microsoft JhengHei", "Segoe UI", sans-serif`;
    g.fillStyle = color; g.textBaseline = "top";
    let t = String(s ?? "").replace(/\n/g, " ");
    if (g.measureText(t).width > width) {
      const chars = [...t];
      while (chars.length && g.measureText(chars.join("") + "…").width > width) chars.pop();
      t = chars.join("") + "…";
    }
    g.fillText(t, x, y + size * 0.1);
  }

  // MARK: 畫面（Windows 版多的：SceneKit 自己做的事）

  /** 每幀推進（畫面迴圈呼叫；視窗看不到時不要呼叫＝SCNScene.isPaused）：SCNAction／隱式動畫、雨的粒子 */
  tick(dt) {
    Act.tick(dt);
    this.weatherFX.tick?.(dt);
  }

  /** 每幀畫之前：節點透明度（SCNNode.opacity）、看板 billboard（SCNBillboardConstraint .Y） */
  presentBegin() {
    syncOpacity(this.scene);
    const cam = new THREE.Vector3();
    this.camera.getWorldPosition(cam);
    for (const b of this.boards.values()) {
      const n = b.node;
      if (!n.visible || !n.parent) continue;
      n.parent.updateMatrixWorld(true);
      const w = new THREE.Vector3().setFromMatrixPosition(n.matrixWorld);
      const parentYaw = new THREE.Euler().setFromRotationMatrix(n.parent.matrixWorld, "YXZ").y;
      n.userData.modelYaw ??= n.rotation.y;
      n.rotation.y = Math.atan2(cam.x - w.x, cam.z - w.z) - parentYaw;
    }
  }
  /** 畫完：換回 model 值（dump 跟 Mac 一樣記節點本身的值，不記畫面上的值） */
  presentEnd() {
    restoreOpacity(this.scene);
    for (const b of this.boards.values()) { const n = b.node; if (n.userData.modelYaw !== undefined) { n.rotation.y = n.userData.modelYaw; delete n.userData.modelYaw; } }
  }
}

export { Act };
