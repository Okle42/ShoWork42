// 單層開放式辦公室（11-08 H5，docs/OWN-SESSIONS.md）：取代大樓剖面。城市、地下室 B1、燈光、天氣、名牌照舊，只換「大樓」那一塊。
//   一層樓、跟原本大樓同一塊地（TowerSpec.width × depth），前面、右邊不砌高牆（從右前方看進來）：
//     每個專案一區工位（有人要坐桌子的才佔位：工作中、等你、卡住），每個 AI 一張桌子；
//     會議室給隊長；休息區放閒著（閒置、睡著）的 AI；茶水間放做完的 AI；前台站保全。
//   家具是 Kenney Furniture Kit（CC0，assets/kenney-furniture/License.txt），載入後換成 VoxMat 的純色材質（跟日夜、停電一起變），
//   同材質的靜態家具合併成一個 mesh（幾十張桌子也只有十幾個 draw call）。模型是非同步載入的：先畫地板、隔間、人，家具載好再補上。
//   角色仍是原本的方塊 Kubo（OfficeBuilder.makePerson），狀態、名牌、點擊、等你回答都沿用；閒晃行程（電梯、頂樓）在單層樓不用。
//
// 對外介面跟 OfficeBuilder 一樣（sceneview／labels／office.js 不用知道換過）；另外多：
//   zones()            → [{ id, title, kind, center, accent }]：上方分頁用
//   frameZone(id)      → 總覽模式下鏡頭飛到那一區
//   walkStart()        → 走進去（第一人稱）的起點與朝向

import * as THREE from "three";
import { GLTFLoader } from "../vendor/three-r170/loaders/GLTFLoader.js";
import { mergeGeometries } from "../vendor/three-r170/utils/BufferGeometryUtils.js";
import { clone as cloneSkinned } from "../vendor/three-r170/utils/SkeletonUtils.js";
import { VoxMat, TP, TD, TowerSpec, scnNode, setCategory, VoxelMesh, Kit, Xf, TM, setEuler, scnLight, scnIntensity } from "../kit.js";
import { OfficeBuilder, projectId, KuboArt } from "./builder.js";
import { OfficeBasement } from "./basement.js";
import { CityBuilder } from "./city.js";
import * as Tower from "./tower.js";
import { runAction, Act } from "./actions.js";

const X0 = -TD.W / 2, X1 = TD.W / 2, Z0 = TD.zB, Z1 = TD.zF;     // 地：x −6…6、z −7…2.8（跟原本大樓一樣，城市不用動）
const R = TD.room;                                                  // 地坪高（樓板頂）
const WALL = 2.6;                                                   // 後牆、左牆高
const KUBO = TowerSpec.kuboScale;
/** 人和家具一起縮小（11-08：原尺寸的 Kubo 一層樓擠不下 20 個人）；地板格局用世界座標，等於房間變大 */
export const S = 0.68;
const TOP = R + 0.77 * S;                                           // 桌面高

/** 格局（世界座標；人＝{x, z, a}，a＝朝向，0＝面向 +z） */
export const OpenPlan = {
  meeting: { x0: -6, x1: -1.7, z0: Z0, z1: -4.3 },
  pantry: { x0: 2.5, x1: 6, z0: Z0, z1: -4.3 },
  lounge: { x0: 2.5, x1: 6, z0: -3.9, z1: 0.5 },
  front: { x0: 2.5, x1: 6, z0: 0.8, z1: Z1 },
  desks: { x0: -6, x1: 2.2, z0: -4.1, z1: Z1 },
  /** 工位格子：8 欄 × 4 排（前面留一條走道貼區域名稱），人面向 +z（看得到臉），桌子在人前面。cols[c][r]；extra＝後段中間 3 張（格子滿了才用） */
  cols: [-5.45, -4.4, -3.35, -2.3, -1.25, -0.2, 0.85, 1.9],
  rows: [-3.6, -2.2, -0.8, 0.6],
  extra: [{ x: -1.2, z: -6.1, a: 0 }, { x: -0.15, z: -6.1, a: 0 }, { x: 0.9, z: -6.1, a: 0 }],
  /** 會議室：長桌兩側＋主位（隊長坐主位，面向 +x 看整張桌子） */
  meetingSeats: [{ x: -5.35, z: -5.65, a: Math.PI / 2 }, { x: -4.3, z: -4.95, a: Math.PI }, { x: -3.2, z: -4.95, a: Math.PI },
                 { x: -4.3, z: -6.35, a: 0 }, { x: -3.2, z: -6.35, a: 0 }],
  /** 休息區：沙發前、地毯上站著（手上拿咖啡） */
  loungeSlots: [{ x: 3.35, z: -0.85, a: 0.4 }, { x: 4.3, z: -0.65, a: 0 }, { x: 5.25, z: -0.85, a: -0.4 }, { x: 3.0, z: 0.15, a: 0.3 },
                { x: 4.3, z: 0.25, a: 0 }, { x: 5.6, z: 0.15, a: -0.3 }, { x: 3.4, z: -2.75, a: 0.9 }, { x: 5.2, z: -2.75, a: -0.9 }],
  /** 茶水間：吧台前站著 */
  pantrySlots: [{ x: 3.1, z: -5.0, a: Math.PI }, { x: 4.1, z: -4.9, a: Math.PI }, { x: 5.1, z: -5.0, a: Math.PI },
                { x: 3.6, z: -4.5, a: 2.6 }, { x: 4.7, z: -4.5, a: -2.6 }, { x: 5.6, z: -4.6, a: -2.8 }],
  /** 位子不夠時站在走道 */
  aisleSlots: [{ x: -5.6, z: 2.3, a: 0.2 }, { x: -4.2, z: 2.3, a: 0 }, { x: -2.8, z: 2.3, a: 0 }, { x: -1.4, z: 2.3, a: 0 },
               { x: 0, z: 2.3, a: 0 }, { x: 1.4, z: 2.3, a: -0.2 }],
  guard: { x: 4.6, z: 1.9, a: -0.35 },
};

/** 心情 → 放哪裡 */
export function placeKind(p) {
  if (p.card?.captain) return "meeting";
  switch (p.mood) {
    case "working": case "waiting": case "stuck": return "desk";
    case "finished": return "pantry";
    default: return "lounge";           // idle、asleep
  }
}

// MARK: - Kenney 家具

/** 每種家具的縮放（Kenney 1 單位約 2 公尺；桌面要在 0.76、椅面約 0.56，跟 Kubo 的坐姿對齊） */
const SCALE = {
  desk: [1.75, 2.0, 1.75], chairDesk: [1.9, 1.9, 1.9], computerScreen: [1.6, 1.6, 1.6], computerKeyboard: [1.6, 1.6, 1.6],
  table: [2.4, 2.25, 2.6], chair: [2.0, 2.35, 2.0], loungeSofa: [2.1, 2.0, 2.1], loungeSofaLong: [2.0, 2.0, 2.0],
  loungeChair: [2.0, 2.0, 2.0], loungeDesignSofa: [2.0, 2.0, 2.0], tableCoffee: [2.0, 2.0, 2.0], rugRectangle: [2.2, 1, 2.0], rugRound: [2.2, 1, 2.2],
  kitchenBar: [2.0, 2.2, 2.2], kitchenBarEnd: [2.0, 2.2, 2.2], kitchenCabinet: [2.0, 2.0, 2.0], kitchenCabinetUpper: [2.0, 2.0, 2.0],
  kitchenFridgeLarge: [2.0, 2.0, 2.0], kitchenCoffeeMachine: [2.0, 2.0, 2.0], kitchenMicrowave: [2.0, 2.0, 2.0], kitchenSink: [2.0, 2.0, 2.0],
  stoolBar: [2.0, 2.2, 2.0], pottedPlant: [1.5, 1.5, 1.5], plantSmall1: [2.0, 2.0, 2.0], plantSmall2: [2.0, 2.0, 2.0], plantSmall3: [2.0, 2.0, 2.0],
  bookcaseOpen: [2.0, 2.0, 2.0], bookcaseOpenLow: [2.0, 2.0, 2.0], bookcaseClosedWide: [2.0, 2.0, 2.0], televisionModern: [2.0, 2.0, 2.0],
  cabinetTelevision: [2.0, 2.0, 2.0], lampRoundFloor: [2.0, 2.0, 2.0], lampSquareFloor: [2.0, 2.0, 2.0], trashcan: [1.6, 1.6, 1.6],
  coatRackStanding: [2.0, 2.0, 2.0], sideTable: [2.0, 2.0, 2.0], speaker: [1.6, 1.6, 1.6], cardboardBoxClosed: [1.6, 1.6, 1.6],
  laptop: [1.6, 1.6, 1.6], tableRound: [2.0, 2.0, 2.0], books: [1.6, 1.6, 1.6], radio: [1.6, 1.6, 1.6],
};

export const Kenney = {
  base: new URL("../assets/kenney-furniture/", import.meta.url).href,
  parts: new Map(),          // 名字 → [{ geometry（已置中、底在 0、縮放好）, material }]
  ready: null,
  failed: [],
  /** 全部載完才 resolve（個別載不到的記在 failed，不擋其他的） */
  load() {
    if (this.ready) return this.ready;
    const loader = new GLTFLoader();
    const names = Object.keys(SCALE);
    this.ready = Promise.all(names.map(n => new Promise(res => {
      loader.load(this.base + n + ".glb", g => { this.parts.set(n, this.flatten(g.scene, SCALE[n])); res(); },
        undefined, () => { this.failed.push(n); res(); });
    })));
    return this.ready;
  },
  /** glTF 場景 → 幾何（套上節點變換、置中、底貼 0、縮放）＋VoxMat 純色材質 */
  flatten(root, s) {
    root.updateMatrixWorld(true);
    const out = [];
    const box = new THREE.Box3().setFromObject(root);
    const cx = (box.min.x + box.max.x) / 2, cz = (box.min.z + box.max.z) / 2, y0 = box.min.y;
    const fix = new THREE.Matrix4().makeScale(s[0] * S, s[1] * S, s[2] * S).multiply(new THREE.Matrix4().makeTranslation(-cx, -y0, -cz));
    root.traverse(o => {
      if (!o.isMesh) return;
      const mats = Array.isArray(o.material) ? o.material : [o.material];
      const geo = o.geometry.clone().applyMatrix4(fix.clone().multiply(o.matrixWorld));
      const keep = ["position", "normal"];
      for (const k of Object.keys(geo.attributes)) if (!keep.includes(k)) geo.deleteAttribute(k);
      if (!geo.attributes.normal) geo.computeVertexNormals();
      if (mats.length === 1 || !geo.groups.length) { out.push({ geometry: geo, material: Kenney.mat(mats[0]) }); return; }
      for (const g of geo.groups) {          // 多材質：照 group 拆開
        const sub = geo.clone(); const idx = geo.index;
        if (idx) sub.setIndex(Array.from(idx.array.slice(g.start, g.start + g.count)));
        sub.clearGroups();
        out.push({ geometry: sub, material: Kenney.mat(mats[g.materialIndex] ?? mats[0]) });
      }
    });
    return out;
  },
  /** 保留模型原本的材質（11-08 使用者：壓成 VoxMat 純色還是方塊風）；同一個來源材質共用一份 */
  mats: new Map(),
  mat(m) {
    const key = m ? `${m.name}|${m.color?.getHexString?.() ?? ""}` : "none";
    if (!this.mats.has(key)) {
      const c = m ? m.clone() : new THREE.MeshStandardMaterial({ color: 0xCCCCCC });
      c.roughness = Math.max(c.roughness ?? 1, 0.75); c.metalness = Math.min(c.metalness ?? 0, 0.1);   // 沒有環境貼圖：金屬會黑掉
      this.mats.set(key, c);
    }
    return this.mats.get(key);
  },
};

// MARK: - 人物（Kenney Mini Characters，CC0；有 idle／walk／sit 等動畫）

const CHAR_K = 1.45;                       // 模型 0.67 高 ⇒ 約 0.97 公尺（Q 版比例，跟縮小後的桌椅搭）
const SEAT_Y = 0.17;                       // 坐姿時模型原點離地（腳底在原點下 0.094×K）
export const People = {
  base: new URL("../assets/kenney-characters/", import.meta.url).href,
  names: ["male-a", "female-a", "male-b", "female-b", "male-c", "female-c", "male-d", "female-d", "male-e", "female-e", "male-f", "female-f"],
  models: new Map(),         // 名字 → { scene, clips: Map }
  ready: null,
  load() {
    if (this.ready) return this.ready;
    const loader = new GLTFLoader();
    this.ready = Promise.all([...this.names, "worker"].map(n => new Promise(res => {
      loader.load(`${this.base}character-${n}.glb`, g => {
        g.scene.traverse(o => { if (o.isMesh) { o.frustumCulled = false; const m = o.material; if (m) { m.roughness = 0.85; m.metalness = 0; } } });
        this.models.set(n, { scene: g.scene, clips: new Map(g.animations.map(a => [a.name, a])) });
        res();
      }, undefined, () => res());
    })));
    return this.ready;
  },
  /** 同一個人每次都是同一個造型（卡片 id 雜湊） */
  pick(id) {
    let h = 0;
    for (const ch of String(id)) h = (h * 31 + ch.charCodeAt(0)) >>> 0;
    return this.names[h % this.names.length];
  },
  /** 一隻人物：模型＋動畫（坐著＝sit 定格；站著＝idle 循環；做完＝點頭一次再 idle） */
  make(name, { seated, mood }) {
    const e = this.models.get(name) ?? this.models.get(this.names[0]);
    if (!e) return null;
    const model = cloneSkinned(e.scene);
    model.scale.setScalar(CHAR_K);
    model.position.y = seated ? SEAT_Y : 0;
    const mixer = new THREE.AnimationMixer(model);
    const play = (n, loop = true) => { const c = e.clips.get(n); if (!c) return null; const a = mixer.clipAction(c); a.setLoop(loop ? THREE.LoopRepeat : THREE.LoopOnce, Infinity); a.clampWhenFinished = !loop; a.play(); return a; };
    let animated = false;
    if (seated) { play("sit"); mixer.update(0.1); }
    else if (mood === "finished") {
      const a = play("emote-yes", false);
      if (a) mixer.addEventListener("finished", () => { a.fadeOut(0.3); play("idle").fadeIn(0.3); });
      else play("idle");
      animated = true;
    } else { const a = play("idle"); if (a) a.time = Math.random() * 1.3; animated = true; }
    mixer.update(0);
    return { model, mixer, animated };
  },
};

/** 靜態家具批次：放好位置的幾何照材質合併 */
class Batch {
  constructor() { this.byMat = new Map(); }
  add(name, x, z, a = 0, y = R, extra = null) {
    const parts = Kenney.parts.get(name);
    if (!parts) return false;
    const m = new THREE.Matrix4().makeRotationY(a).premultiply(new THREE.Matrix4().makeTranslation(x, y, z));
    if (extra) m.multiply(extra);
    for (const p of parts) {
      const g = p.geometry.clone().applyMatrix4(m);
      if (!this.byMat.has(p.material)) this.byMat.set(p.material, []);
      this.byMat.get(p.material).push(g);
    }
    return true;
  }
  node(name) {
    const root = scnNode(name);
    for (const [mat, gs] of this.byMat) {
      const g = mergeGeometries(gs, false);
      if (!g) continue;
      const mesh = new THREE.Mesh(g, mat);
      setCategory(mesh, 1);
      root.add(mesh);
    }
    return root;
  }
}

// MARK: - 招牌（區域名稱：吊在區域上方的板子，兩面都有字）

function signTexture(text, accent) {
  const c = document.createElement("canvas");
  const font = `600 44px "PingFang TC","Microsoft JhengHei UI","Noto Sans TC",sans-serif`;
  const g0 = c.getContext("2d"); g0.font = font;
  const w = Math.ceil(Math.min(900, g0.measureText(text).width + 70)), h = 72;
  c.width = w; c.height = h;
  const g = c.getContext("2d");
  g.fillStyle = "#14161A"; g.fillRect(0, 0, w, h);
  g.fillStyle = "#" + (accent ?? 0x8FE3EE).toString(16).padStart(6, "0"); g.fillRect(0, 0, 12, h);
  g.font = font; g.fillStyle = "#F3F1EC"; g.textBaseline = "middle"; g.fillText(text, 32, h / 2 + 2);
  const t = new THREE.CanvasTexture(c); t.colorSpace = THREE.SRGBColorSpace; t.anisotropy = 4;
  return { t, aspect: w / h };
}
function makeSign(text, accent, x, z, y = R + 1.75, a = 0, maxW = 3.2) {
  const { t, aspect } = signTexture(text, accent);
  const h = Math.min(0.4, maxW / aspect), w = h * aspect;
  const m = new THREE.MeshBasicMaterial({ map: t, side: THREE.DoubleSide });
  m.userData.emission = { color: null, intensity: 1 };
  const n = new THREE.Mesh(new THREE.PlaneGeometry(w, h), m);
  n.position.set(x, y, z); n.rotation.y = a; n.name = "sign";
  setCategory(n, 1);
  const g = scnNode("zone-sign"); g.add(n);
  // 兩條吊線
  const wire = VoxMat.flat(0x2F3338);
  for (const dx of [-w / 2 + 0.1, w / 2 - 0.1]) {
    const l = new THREE.Mesh(new THREE.BoxGeometry(0.015, 0.4, 0.015), wire);
    l.position.set(x + dx * Math.cos(a), y + h / 2 + 0.2, z - dx * Math.sin(a));
    g.add(l);
  }
  return g;
}

/** 地上的區域名稱（俯視看得清楚；貼在地毯前緣） */
function makeDecal(text, accent, x, z, maxW) {
  const { t, aspect } = signTexture(text, accent);
  const h = Math.min(0.42, maxW / aspect), w = h * aspect;
  const m = new THREE.MeshBasicMaterial({ map: t, transparent: true, opacity: 0.92, depthWrite: false });
  const n = new THREE.Mesh(new THREE.PlaneGeometry(w, h), m);
  n.rotation.x = -Math.PI / 2;
  n.position.set(x, TD.slab + 0.03, z);
  n.name = "decal";
  setCategory(n, 1);
  return n;
}

// MARK: - 開放式辦公室

export class OpenOfficeBuilder extends OfficeBuilder {
  constructor(opts) {
    super(opts);
    for (const c of this.cars) c.removeFromParent();      // 單層樓：沒有電梯
    this.office = null; this.officeSig = "";
    this.furniture = null; this.furnitureSig = "";
    this.zoneList = [];         // [{ id, project, title, accent, seats: [i…], rect }]
    this.assign = new Map();    // card id → { kind, slot, zone }
    this.onAssets = null;       // 家具載好了（sceneview 補畫一張）
    this.onLayout = null;       // 區域變了（sceneview 重畫上方分頁）
    Kenney.load().then(() => { this.furnitureSig = ""; this.buildFurniture(); this.onAssets?.(); });
    this.mixers = new Set();      // 播動畫的人（tick 時推進）
    this.lastIslands = [];
    People.load().then(() => {        // 人物載好：方塊 Kubo 換成人物（重建一次）
      for (const p of this.persons.values()) p.look = "";
      this.guardKey = "";
      this.updatePeople(this.lastIslands, null, false, Date.now() / 1000);
      this.updateGuard(this.lastGuard ?? { level: "normal" }, false);
      this.looping = this.looping || (this.animating && !OfficeBuilder.reduceMotion);
      this.onAssets?.(); this.onLayout?.();
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
    this.buildFurniture();
    this.lastIslands = islands; this.lastGuard = guardStatus;
    this.updatePeople(islands, null, animate, now);
    this.updateGuard(guardStatus, scanning);
    this.updateEmergency();
    this.highlight(this.lit);
    if (!this.fidgetStarted) { this.fidgetStarted = true; this.scheduleFidget(); }
    this.looping = !OfficeBuilder.reduceMotion && (scanning || this.weatherFX.raining || this.animating
      || [...this.persons.values()].some(p => p.mood === "working" && p.islander.card.activity === "editing"));
    this.omniDirty = true; this.assignOmni();
    return first ? "layout" : "none";
  }

  /** 專案順序：照 TowerPlan 的樓層號（穩定），沒在 plan 裡的照名字 */
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

  /** 每個人分到哪：工位（每個專案佔整欄，一欄 4 個位子；用到的欄置中）、會議室、休息區、茶水間、走道 */
  layout(islands) {
    const P = OpenPlan, nr = P.rows.length, nc = P.cols.length;
    const seats = [];               // 這次用到的位子（index＝slot）
    const zones = [], assign = new Map();
    const used = { meeting: 0, lounge: 0, pantry: 0, aisle: 0 };
    const spill = id => { assign.set(id, { kind: "aisle", slot: used.aisle++ % P.aisleSlots.length }); };
    const order = this.projectOrder(islands).map(i => {
      const people = i.people.slice().sort((a, b) => (a.card.id < b.card.id ? -1 : 1)).slice(0, OfficeBuilder.maxPeople);
      return { i, people, desk: people.filter(p => placeKind(p) === "desk") };
    });
    // 欄數：每個專案 ceil(要坐桌子的人 / 4)；總數超過 8 欄就從人最多的專案開始少給（多的人走後段、再不夠站走道）
    const want = order.map(o => Math.ceil(o.desk.length / nr));
    while (want.reduce((a, b) => a + b, 0) > nc) { const k = want.indexOf(Math.max(...want)); want[k] -= 1; }
    let col = Math.floor((nc - want.reduce((a, b) => a + b, 0)) / 2);
    let extra = 0;
    order.forEach((o, k) => {
      const fid = projectId(o.i.project);
      const mine = [];
      const c0 = col; col += want[k];
      let n = 0;
      for (const p of o.people) {
        const kind = placeKind(p);
        if (kind === "desk") {
          let at = null;
          if (n < want[k] * nr) { const c = c0 + Math.floor(n / nr), r = n % nr; at = { x: P.cols[c], z: P.rows[r], a: 0 }; n++; }
          else if (extra < P.extra.length) at = P.extra[extra++];
          if (!at) { spill(p.card.id); continue; }
          seats.push(at); mine.push(seats.length - 1);
          assign.set(p.card.id, { kind: "desk", slot: seats.length - 1, zone: fid });
        } else {
          const cap = { meeting: P.meetingSeats.length, lounge: P.loungeSlots.length, pantry: P.pantrySlots.length }[kind];
          if (used[kind] < cap) assign.set(p.card.id, { kind, slot: used[kind]++, zone: fid });
          else spill(p.card.id);
        }
      }
      if (mine.length) {
        const pts = mine.map(i => seats[i]).filter(q => q.z > -5);          // 區域範圍只算前面的格子（後段那 3 張不算）
        if (!pts.length) return;
        const rect = { x0: Math.min(...pts.map(q => q.x)) - 0.5, x1: Math.max(...pts.map(q => q.x)) + 0.5,
                       z0: Math.min(...pts.map(q => q.z)) - 0.42, z1: Math.max(...pts.map(q => q.z)) + 0.98 };
        zones.push({ id: fid, project: o.i.project, title: o.i.project, accent: this.accentOf(o.i.project), seats: mine, rect });
      }
    });
    this.seats = seats;
    this.zoneList = zones;
    this.assign = assign;
    this.layoutSig = JSON.stringify([zones.map(z => [z.id, z.seats, z.accent]), seats.length]);
  }

  // MARK: 地板、牆、隔間（方塊）

  buildShell() {
    this.office?.removeFromParent();
    const root = scnNode("open-office");
    const m = new VoxelMesh(), k = new Kit(m);
    const I = Xf.identity;
    const W = X1 - X0, D = Z1 - Z0, cx = (X0 + X1) / 2, cz = (Z0 + Z1) / 2;
    // 樓板＋木地板
    k.b(I, cx, 0, cz, W, TD.slab, D, TM.slab);
    k.b(I, cx, TD.slab, cz, W - 0.1, 0.01, D - 0.1, VoxMat.dayNight(0xC9B79C, 0xB8A68C));
    // 後牆、左牆（有窗）；前面、右邊只有矮玻璃欄杆
    const wall = TM.backWall, frame = TM.f(TP.ST1), glassM = TM.glass(0.28);
    k.b(I, cx, R, Z0 + 0.075, W, WALL, 0.15, wall);
    k.b(I, X0 + 0.075, R, cz, 0.15, WALL, D, wall);
    for (let x = X0 + 1.2; x < X1 - 0.8; x += 2.4) {          // 後牆的窗（夜裡看得到城市燈）
      k.b(I, x, R + 0.9, Z0 + 0.16, 1.6, 1.2, 0.02, VoxMat.dayNight(0xB9D3D8, 0x22303F));
      k.b(I, x, R + 0.85, Z0 + 0.17, 1.7, 0.05, 0.04, frame);
    }
    for (let z = Z0 + 1.4; z < Z1 - 1.0; z += 2.4) {
      k.b(I, X0 + 0.16, R + 0.9, z, 0.02, 1.2, 1.6, VoxMat.dayNight(0xB9D3D8, 0x22303F));
    }
    k.b(I, cx, R, Z1 - 0.03, W, 0.06, 0.06, frame);           // 前緣、右緣：踢腳＋玻璃欄杆
    k.b(I, X1 - 0.03, R, cz, 0.06, 0.06, D, frame);
    // 會議室：玻璃隔間（右牆、前牆；門在前牆右邊）
    const mt = OpenPlan.meeting;
    for (const z of [mt.z0 + 0.15, mt.z1]) k.b(I, mt.x1, R, z, 0.07, 2.3, 0.07, frame);          // 玻璃隔間的柱子
    k.b(I, mt.x1, R, (mt.z0 + mt.z1) / 2, 0.06, 0.06, mt.z1 - mt.z0, frame);
    k.b(I, (mt.x0 + mt.x1 - 1.0) / 2, R, mt.z1, mt.x1 - mt.x0 - 1.0, 0.06, 0.06, frame);
    k.b(I, (mt.x0 + mt.x1 - 1.0) / 2, R + 2.24, mt.z1, mt.x1 - mt.x0 - 1.0, 0.06, 0.06, frame);
    k.b(I, mt.x1, R + 2.24, (mt.z0 + mt.z1) / 2, 0.06, 0.06, mt.z1 - mt.z0, frame);
    // 茶水間：地磚（跟木地板分開）
    const pt = OpenPlan.pantry;
    k.b(I, (pt.x0 + pt.x1) / 2, TD.slab + 0.012, (pt.z0 + pt.z1) / 2, pt.x1 - pt.x0, 0.01, pt.z1 - pt.z0, VoxMat.dayNight(0xE4E1DB, 0xD3D0CA));
    // 前台：矮櫃台＋監控螢幕架
    k.b(I, 4.4, R, 1.3, 2.2, 0.72, 0.45, VoxMat.dayNight(0x2F3338, 0x3A3F45));
    k.b(I, 4.4, R + 0.72, 1.3, 2.3, 0.04, 0.55, TM.f(TP.FN5));
    // 工位區：每區一塊地毯（區域顏色）
    for (const z of this.zoneList) {
      const r = z.rect, col = VoxMat.mix(VoxMat.color(z.accent), VoxMat.color(0xC9B79C), 0.55);
      k.b(I, (r.x0 + r.x1) / 2, TD.slab + 0.014, (r.z0 + r.z1) / 2, r.x1 - r.x0, 0.01, r.z1 - r.z0, VoxMat.flat(col));
    }
    const shell = m.node("office-shell");
    setCategory(shell, 1);
    root.add(shell);
    // 會議室的玻璃（另外一個 mesh：透明）
    const gm = new VoxelMesh(), gk = new Kit(gm);
    gk.b(I, mt.x1, R + 0.06, (mt.z0 + mt.z1) / 2, 0.03, 2.18, mt.z1 - mt.z0, glassM);
    gk.b(I, (mt.x0 + mt.x1 - 1.0) / 2, R + 0.06, mt.z1, mt.x1 - mt.x0 - 1.0, 2.18, 0.03, glassM);
    gk.b(I, (X0 + X1) / 2, R + 0.06, Z1 - 0.03, W, 0.95, 0.02, glassM);
    gk.b(I, X1 - 0.03, R + 0.06, cz, 0.02, 0.95, D, glassM);
    root.add(gm.node("office-glass"));
    // 區域名稱：貼在地上（俯視看得清楚、不擋人）
    const signs = scnNode("signs");
    signs.add(makeDecal("會議室・隊長", 0x1E3A8A, (mt.x0 + mt.x1) / 2, mt.z1 - 0.35, 3.4));
    signs.add(makeDecal("茶水間・做完", 0x30D158, (pt.x0 + pt.x1) / 2, pt.z1 - 0.3, 3.0));
    const lg = OpenPlan.lounge;
    signs.add(makeDecal("休息區・閒著", 0xF59E0B, (lg.x0 + lg.x1) / 2, lg.z1 - 0.15, 3.0));
    signs.add(makeDecal("前台・保全", 0x1E3A8A, 3.6, Z1 - 0.3, 1.9));
    for (const z of this.zoneList) signs.add(makeDecal(z.title, z.accent, (z.rect.x0 + z.rect.x1) / 2, z.rect.z1 + 0.32, z.rect.x1 - z.rect.x0 - 0.1));
    root.add(signs);
    // 假模組：每區一個節點（位置在區域中心；給 focusPoint、highlightFloor、左側索引列用）
    const mods = new Map();
    const addMod = (id, cx2, cz2, f) => { const n = scnNode(`floor:${id}`); n.position.set(cx2, 0, cz2); root.add(n); mods.set(id, { parts: { node: n, facades: [] }, key: id, floor: f }); };
    for (const z of this.zoneList) addMod(z.id, (z.rect.x0 + z.rect.x1) / 2, (z.rect.z0 + z.rect.z1) / 2, { id: z.id, kind: "project", project: z.project, y: 0, height: WALL });
    addMod("lobby", 4.4, 1.6, { id: "lobby", kind: "lobby", y: 0, height: WALL });
    addMod("roof", (lg.x0 + lg.x1) / 2, (lg.z0 + lg.z1) / 2, { id: "roof", kind: "roof", y: 0, height: WALL });
    this.modules = mods;
    this.world.add(root);
    this.office = root; this.officeSig = this.layoutSig;
    this.furnitureSig = "";
    this.weatherFX.shelter(this.world, [X0, 0, Z0], [X1, R + WALL + 0.4, Z1]);
    this.cutSig = ""; this.lodDirty = true; this.omniDirty = true;
    if (this.guardNode) { this.guardNode.removeFromParent(); this.guardNode = null; this.guardKey = ""; }
  }

  // MARK: 家具（Kenney；載好才有）

  buildFurniture() {
    if (!Kenney.parts.size || !this.office) return;
    const sig = this.layoutSig + "|" + Kenney.parts.size;
    if (sig === this.furnitureSig) return;
    this.furnitureSig = sig;
    this.furniture?.removeFromParent();
    const b = new Batch();
    // 工位：有分到人的位子才擺桌子＋椅子＋螢幕＋鍵盤（沒人用的地方留空，看得出一區一區）
    this.seats.forEach(s => {
      b.add("desk", s.x, s.z + 0.92 * S, Math.PI);
      b.add("chairDesk", s.x, s.z - 0.02, Math.PI);
      b.add("computerScreen", s.x, s.z + 1.1 * S, 0, TOP);
      b.add("computerKeyboard", s.x, s.z + 0.8 * S, 0, TOP);
    });
    // 會議室：長桌＋椅子＋電視
    const mt = OpenPlan.meeting;
    b.add("table", -3.75, -5.65, 0);
    for (const s of OpenPlan.meetingSeats) b.add("chair", s.x - Math.sin(s.a) * 0.05, s.z - Math.cos(s.a) * 0.05, s.a + Math.PI);
    b.add("bookcaseOpenLow", mt.x1 - 0.35, -6.4, -Math.PI / 2);
    b.add("pottedPlant", mt.x0 + 0.35, mt.z1 - 0.35, 0);
    // 茶水間：吧台一排（背牆）＋冰箱＋咖啡機
    const pt = OpenPlan.pantry;
    for (let x = pt.x0 + 0.45; x < pt.x1 - 1.4; x += 0.86 * S) b.add("kitchenCabinet", x, Z0 + 0.6, Math.PI);
    b.add("kitchenSink", pt.x0 + 1.31, Z0 + 0.6, Math.PI);
    b.add("kitchenFridgeLarge", pt.x1 - 0.7, Z0 + 0.55, Math.PI);
    b.add("kitchenCoffeeMachine", pt.x0 + 0.45, Z0 + 0.55, Math.PI, R + 0.85 * S);
    b.add("kitchenMicrowave", pt.x0 + 2.17, Z0 + 0.55, Math.PI, R + 0.85 * S);
    for (let x = pt.x0 + 0.7; x < pt.x1 - 0.4; x += 0.9 * S) b.add("kitchenBar", x, -5.75, 0);
    for (let x = pt.x0 + 0.7; x < pt.x1 - 0.4; x += 0.9) b.add("stoolBar", x, -5.1, 0);
    // 休息區：地毯、沙發、茶几、電視、植物、立燈
    const lg = OpenPlan.lounge;
    b.add("rugRectangle", (lg.x0 + lg.x1) / 2, (lg.z0 + lg.z1) / 2 - 0.4, 0);
    b.add("loungeSofaLong", 4.3, -3.3, 0);
    b.add("loungeChair", 2.95, -1.8, Math.PI / 2);
    b.add("loungeChair", 5.65, -1.8, -Math.PI / 2);
    b.add("tableCoffee", 4.3, -1.8, 0);
    b.add("pottedPlant", 5.7, 0.2, 0);
    b.add("lampRoundFloor", 2.8, -3.5, 0);
    b.add("bookcaseOpen", 5.75, -3.6, -Math.PI / 2);
    // 前台旁、工位區角落的植物、垃圾桶
    b.add("pottedPlant", 2.8, 2.4, 0);
    b.add("plantSmall2", 5.3, 1.3, 0, R + 1.05);
    b.add("pottedPlant", -5.6, -3.9, 0);
    b.add("trashcan", 2.15, 2.5, 0);
    b.add("bookcaseClosedWide", -5.65, 1.4, Math.PI / 2);
    b.add("coatRackStanding", 2.3, -4.0, 0);
    const n = b.node("furniture");
    this.office.add(n);
    this.furniture = n;
    this.bump(0.2);
  }

  // MARK: 人

  updatePeople(islands, _wander, animate, now) {
    const seen = new Set();
    for (const i of islands) {
      const fid = projectId(i.project);
      for (const p of i.people.slice(0, OfficeBuilder.maxPeople)) {
        const a = this.assign.get(p.card.id);
        if (!a) continue;
        seen.add(p.card.id);
        this.placeOpen(p, fid, a, animate);
      }
    }
    for (const [id, old] of [...this.persons]) if (!seen.has(id)) { this.persons.delete(id); old.node.removeFromParent(); this.mixers.delete(old.node.userData.mixer); }
    this.peopleSeeded = this.peopleSeeded || islands.length > 0;
  }

  /** 一個人：Kenney 人物（載好前先用方塊 Kubo）＋腳下狀態光圈＋頭上寶石＋桌上亮的螢幕＋名牌錨點＋點擊盒 */
  makePerson(p, seated, atDesk, noCup = false, intro = true) {
    if (!People.models.size) { const k = super.makePerson(p, seated, atDesk, noCup, intro); k.userData.kubo = true; return k; }
    const root = scnNode(`p:${p.card.id}`);
    const ch = People.make(People.pick(p.card.id), { seated, mood: p.mood });
    root.add(ch.model);
    const tint = KuboArt.tint(p.mood);
    const lit = p.mood !== "idle" && p.mood !== "asleep";
    // 狀態色（11-08 使用者：不要整隻變色）：腳下光圈＋頭上寶石；閒著的只有淡灰圈、沒有寶石
    const ring = new THREE.Mesh(new THREE.TorusGeometry(0.36, 0.025, 8, 40).rotateX(-Math.PI / 2), VoxMat.flat(tint, { emit: lit ? [0.8, 1.8] : null }));
    ring.position.y = 0.03; ring.name = "status-ring";
    root.add(ring);
    const top = (seated ? 0.521 * CHAR_K + SEAT_Y : 0.68 * CHAR_K);
    if (lit) {
      const gem = new THREE.Mesh(new THREE.OctahedronGeometry(0.09), VoxMat.flat(tint, { emit: [0.9, 2.0] }));
      gem.position.y = top + 0.16; gem.name = "gem";
      root.add(gem);
    }
    if (atDesk && seated && lit && !p.card.captain) {          // 桌上螢幕亮狀態色（背對你的人也看得到在忙什麼）
      const scr = new THREE.Mesh(new THREE.PlaneGeometry(0.26, 0.15), VoxMat.flat(tint, { emit: [0.7, 2.6] }));
      scr.position.set(0, TOP - R + 0.19, 0.735); scr.rotation.y = Math.PI;
      root.add(scr);
    }
    const anchor = scnNode("anchor"); anchor.position.y = top + 0.3; root.add(anchor);
    this.addHaloAndHitbox(root, 0.85);
    OfficeBuilder.pickable(root);
    root.userData.mixer = ch.mixer;
    if (ch.animated && !OfficeBuilder.reduceMotion) this.mixers.add(ch.mixer);
    return root;
  }

  get animating() { return this.mixers.size > 0 && !OfficeBuilder.heatPaused; }

  tick(dt) {
    super.tick(dt);
    if (!(dt > 0) || OfficeBuilder.heatPaused) return;
    for (const m of this.mixers) m.update(dt);
  }

  // 方塊 Kubo 的小動作（點頭、轉頭）：人物有自己的待機動畫，不用
  scheduleFidget() {}

  slot(a) {
    switch (a.kind) {
      case "desk": return this.seats[a.slot];
      case "meeting": return OpenPlan.meetingSeats[a.slot];
      case "lounge": return OpenPlan.loungeSlots[a.slot];
      case "pantry": return OpenPlan.pantrySlots[a.slot];
      default: return OpenPlan.aisleSlots[a.slot];
    }
  }

  placeOpen(p, fid, a, animate) {
    const id = p.card.id;
    const seated = a.kind === "desk" || a.kind === "meeting";
    const atDesk = a.kind === "desk";
    const look = OfficeBuilder.personKey(p) + `|${seated}|${atDesk}`;
    const place = `${a.kind}:${a.slot}`;
    const parent = this.office;
    let person = this.persons.get(id);
    if (person && person.look === look) {
      if (person.place === place && person.node.parent === parent) { person.islander = p; return; }
    } else {
      const intro = person ? person.mood !== p.mood : true;
      if (person) { person.node.removeFromParent(); this.mixers.delete(person.node.userData.mixer); }
      const node = this.makePerson(p, seated, atDesk, false, intro);
      person = { node, look, place: "", mood: p.mood, islander: p, floor: fid, seat: a.slot, seats: 1 };
    }
    person.place = place; person.mood = p.mood; person.islander = p; person.floor = a.kind === "desk" ? fid : a.kind;
    this.persons.set(id, person);
    const node = person.node;
    node.scale.setScalar(node.userData.kubo ? S : 1);
    if (node.parent !== parent) { node.removeFromParent(); parent.add(node); }
    const s = this.slot(a);
    node.position.set(s.x, R, s.z); node.rotation.y = s.a;
  }

  // 閒晃、電梯、搬家：單層樓不用
  settle() {}
  snapTravelers() {}
  parkCars() {}
  rebuildCore() {}
  updateGhosts() {}
  updateBoards() {}
  updateCooler() {}

  // MARK: 保全（站在前台；不巡邏）

  updateGuard(g, scanning) {
    if (!this.office) return;
    const level = g.level ?? "normal", hasData = !!g.hasData;
    const key = `${level}|${hasData}|${scanning}`;
    if (key === this.guardKey && this.guardNode?.parent === this.office) return;
    this.guardKey = key;
    if (this.guardNode) { this.guardNode.removeFromParent(); this.guardNode.traverse(o => { if (o.userData?.gm) this.mixers.delete(o.userData.gm); }); }
    const r = scnNode("guard");
    const lv = OfficeBuilder.guardColor(level), wifi = VoxMat.color(0x38bdf8), gray = VoxMat.color(0x6b7280);
    const cols = !hasData ? [gray, wifi, gray] : level === "alert" ? [lv, lv, lv] : [lv, wifi, lv];
    cols.forEach((c, i) => {           // 櫃台上三面監控螢幕
      const s = new THREE.Mesh(new THREE.BoxGeometry(0.5, 0.3, 0.03), VoxMat.flat(c, { emit: [0.4, 1.3] }));
      s.position.set(3.75 + i * 0.65, R + 0.95, 1.2);
      r.add(s);
    });
    const ant = new THREE.Mesh(new THREE.BoxGeometry(0.16, 0.16, 0.16), VoxMat.flat(wifi, { emit: [0.8, 1.6] }));
    ant.position.set(5.35, R + 0.9, 1.3); setEuler(ant, 0.6, 0.78, 0);
    if (scanning && !OfficeBuilder.reduceMotion) runAction(ant, Act.repeatForever(Act.rotateBy(0, Math.PI, 0, 1.2)));
    r.add(ant);
    const man = scnNode("guard-man"); if (!People.models.size) man.scale.setScalar(S);
    const gp = OpenPlan.guard;
    man.position.set(gp.x, R, gp.z); man.rotation.y = gp.a;
    const gm = People.models.size ? People.make("worker", { seated: false, mood: "idle" }) : null;
    if (gm) { man.add(gm.model); man.userData.gm = gm.mixer; if (!OfficeBuilder.reduceMotion) this.mixers.add(gm.mixer); }
    else man.add(this.makeKubo("idle", null, { seated: false, gemColor: lv, cap: true, intro: false }));
    const gr = new THREE.Mesh(new THREE.TorusGeometry(0.36, 0.025, 8, 40).rotateX(-Math.PI / 2), VoxMat.flat(lv, { emit: [0.8, 1.8] }));
    gr.position.y = 0.03; man.add(gr);
    this.addHaloAndHitbox(man, 1.2);
    const anchor = scnNode("anchor"); anchor.position.set(0, gm ? 0.68 * CHAR_K + 0.3 : 1.25 * KUBO + 0.1, 0);
    man.add(anchor);
    r.add(man);
    OfficeBuilder.pickable(r);
    this.office.add(r);
    this.guardNode = r;
  }
  schedulePatrol() {}
  startPatrol() { return false; }

  updateEmergency() {}

  // MARK: 名牌（一整層當一層樓）

  labelTargets() {
    const ps = [];
    for (const [id, p] of this.persons) {
      const a = p.node.getObjectByName("anchor");
      if (a) ps.push({ id, anchor: a, card: p.islander.card, mood: p.mood, floor: "office" });
    }
    const ga = this.guardNode?.getObjectByName("anchor");
    if (ga) ps.push({ id: "guard", anchor: ga, card: null, mood: "idle", floor: "office" });
    const fs = this.office ? [{ id: "office", node: this.office, height: WALL + 0.6, floorNo: "", title: "", kind: "open", names: [], accent: null }] : [];
    return { people: ps, floors: fs };
  }

  /** 上方分頁用：各區 */
  zones() {
    const out = this.zoneList.map(z => ({ id: z.id, title: z.title, kind: "project", accent: z.accent }));
    return [{ id: "meeting", title: "會議室", kind: "room" }, ...out, { id: "lounge", title: "休息區", kind: "room" },
            { id: "pantry", title: "茶水間", kind: "room" }, { id: "lobby", title: "前台", kind: "room" }];
  }

  zoneRect(id) {
    const z = this.zoneList.find(x => x.id === id);
    if (z) return z.rect;
    switch (id) {
      case "meeting": return OpenPlan.meeting;
      case "lounge": case "roof": return OpenPlan.lounge;
      case "pantry": return OpenPlan.pantry;
      case "lobby": return OpenPlan.front;
      default: return null;
    }
  }

  // MARK: 燈（夜晚：天花板下 4 盞）

  assignOmni() {
    if (!this.omniDirty) return;
    this.omniDirty = false;
    if (!(VoxMat.lamps > 0.001)) { this.omni.forEach(o => { o.visible = false; }); return; }
    const spots = [[-3.5, -1.5], [1.0, -1.0], [4.2, -2.0], [-3.8, -5.6], [4.2, -5.6], [4.3, 1.6]];
    while (this.omni.length < spots.length) {
      const l = scnLight_omni(); this.world.add(l); this.omni.push(l);
    }
    this.omni.forEach((o, i) => {
      if (i >= spots.length) { o.visible = false; return; }
      o.position.set(spots[i][0], R + 2.7, spots[i][1]); o.visible = true;
      o.intensity = scnIntensityOf(this.omniBase * 0.55);
      o.distance = 7; o.userData.att = [1, 7, 2]; o.userData.cat = 1;
    });
  }

  applyCutaway() { return false; }
  highlightFloor() { return false; }
  cutNow() {}

  // MARK: 取景

  /** 總覽：從右前方高處看整層（方位 24°、仰角 42°） */
  frameCamera(aspect = this.aspect) {
    aspect = Math.max(0.4, aspect);
    const az = 24, el = 42;
    const [dist, t] = OfficeBuilder.fit([X0, 0, Z0], [X1, R + WALL, Z1], aspect, az * Math.PI / 180, el * Math.PI / 180, 34, 1.0);
    this.place(t, dist, az, el);
  }
  frameRange() { return [0, R + WALL]; }
  /** 一區：框那一區（略俯視） */
  frameZone(id, aspect = this.aspect) {
    if (id === "b1") {                 // 地下室 B1：鏡頭移到地面以下（sceneview 會切地下室模式）
      const y = OfficeBasement.baseY + R + 1.2;
      this.place([0, y, -2.1], 13, 20, 14);
      return true;
    }
    const r = this.zoneRect(id);
    if (!r) return false;
    aspect = Math.max(0.4, aspect);
    const az = 18, el = 50;
    const [dist, t] = OfficeBuilder.fit([r.x0 - 0.3, R, r.z0 - 0.3], [r.x1 + 0.3, R + 2.0, r.z1 + 0.3], aspect, az * Math.PI / 180, el * Math.PI / 180, 34, 0.95);
    this.place(t, Math.max(dist, 6), az, el);
    return true;
  }
  frameFloor(id, aspect = this.aspect) { return this.frameZone(id, aspect); }
  focusPoint(key) {
    const id = key === "roof" || key === "lobby" ? key : key.startsWith("floor:") ? projectId(key.slice(6)) : null;
    const r = id && this.zoneRect(id);
    return r ? [(r.x0 + r.x1) / 2, R + 1.3, (r.z0 + r.z1) / 2] : null;
  }
  totalHeight() { return R + WALL; }
  projectFloors() { return []; }

  /** 走進去：從前台旁的入口、眼睛高度，看向工位區 */
  walkStart() { return { pos: [2.3, R + 1.85, 2.7], target: [-2.6, R + 0.5, -3.4] }; }
  get walkBounds() { return { lo: [X0 + 0.4, Z0 + 0.4], hi: [X1 - 0.3, Z1 + 1.5] }; }
}

/** 夜晚 omni（跟 builder 同一種燈） */
function scnLight_omni() { const l = scnLight({ type: "omni", color: TP.LT1, mask: 1, start: 1, end: 7 }); l.visible = false; return l; }
function scnIntensityOf(v) { return scnIntensity(v); }
