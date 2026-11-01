// OfficeBuilder.swift 照搬（11-01 P0 地基）：場景組裝、燈光（applyLights）、取景（place／fit／frameCamera／frameCity）、
// 霧與近遠裁切（updateLOD／updateFog）、cutaway、夜晚 omni（assignOmni）。結構跟 Swift 一樣：
//   scene → world（大地面 env、樓層模組 floor:<id>、core、電梯車廂、driver、city.root、basement.root）＋ambient／sun／fill／moonFill＋camera。
// 人物、看板、保全、搬家、電梯門、閒晃、天氣等還沒搬（標 TODO 的掛點），由之後的 agent 照 Swift 填。
// 後製：bloom、vignette 的數值記在 this.post，畫面由 kit.js 的 ScnPost 依 this.post 做（量過，見 ScnPost 註解）。
// 霧：three 的線性霧用「視線方向的深度」算，SceneKit 的公式沒量到（目前只有大地面吃得到霧，等城市搬完再用 shots.sh 比遠景）。

import * as THREE from "three";
import { VoxMat, TP, TD, TowerSpec, scnLight, scnNode, setCategory, category, aimDirectional, frontOfEuler, scnIntensity,
         LightMask, skyGlowCube, SColor, enumerateHierarchy, setOpacity } from "../kit.js";
import { SkyLook } from "./solar.js";
import { TowerModules, TowerCore } from "./tower.js";
import { CityBuilder } from "./city.js";
import { OfficeBasement } from "./basement.js";
import { WeatherFX } from "./weather.js";

const ns = c => new SColor(c[0], c[1], c[2], 1);
const v3 = (x, y, z) => [x, y, z];
const add = (a, b) => [a[0] + b[0], a[1] + b[1], a[2] + b[2]];
const sub = (a, b) => [a[0] - b[0], a[1] - b[1], a[2] - b[2]];
const mul = (a, k) => [a[0] * k, a[1] * k, a[2] * k];
const dot = (a, b) => a[0] * b[0] + a[1] * b[1] + a[2] * b[2];
const cross = (a, b) => [a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0]];
const norm = a => { const l = Math.hypot(a[0], a[1], a[2]); return [a[0] / l, a[1] / l, a[2] / l]; };

export class OfficeBuilder {
  static dayBg = VoxMat.color(TP.skyDay);
  static nightBg = VoxMat.color(TP.skyNight);
  /** 目前的天空地平線色（視窗底色、霧色） */
  static bg = OfficeBuilder.dayBg;
  /** 戶外的東西（城市、大地面）：categoryBitMask 拿掉第 0 位元 ⇒ 室內暖補光照不到 */
  static outdoorMask = 1 << 4;
  static nightFill = 60;
  static floorOmni = 500;
  static lobbyOmni = 900;
  static floorRange = 11;
  static legacyNight = false;
  static floorLightBit(i) { return 1 << (8 + i % 16); }
  static floorLightBits = Array.from({ length: 16 }, (_, i) => 1 << (8 + i)).reduce((a, b) => a | b, 0);
  static maxPeople = 16;
  static kuboScale = TowerSpec.kuboScale;
  static boardDistance = 30;
  static pickMask = 2;
  static cutDot = 0.25;
  static cutFade = 0.25;
  /** 主光（美術角度）：SCNVector3(-0.927, -0.885, 0)；光行進方向 ≈ (0.465, −0.800, −0.380) */
  static sunEuler = [-0.927, -0.885, 0];
  static compassOffset = 25.7;
  static worldAngle(azimuth) { return (azimuth + OfficeBuilder.compassOffset) * Math.PI / 180; }
  static get artAngle() {
    const f = frontOfEuler(...OfficeBuilder.sunEuler), toSun = [-f.x, -f.y, -f.z];
    let a = Math.atan2(toSun[0], -toSun[2]); if (a < 0) a += 2 * Math.PI; return a;
  }
  static get shadowStep() { const f = frontOfEuler(...OfficeBuilder.sunEuler); return [f.x / -f.y, f.z / -f.y]; }
  static smooth(a, b, x) { const t = Math.min(1, Math.max(0, (x - a) / (b - a))); return t * t * (3 - 2 * t); }
  /** 畫面風格：voxel（預設）／diorama */
  static style = "voxel";
  static baseAzimuth = 16;
  static baseElevation = 12;
  static get azimuth() { return OfficeBuilder.style === "diorama" ? 35 : OfficeBuilder.baseAzimuth; }
  static get elevation() { return OfficeBuilder.style === "diorama" ? 15 : OfficeBuilder.baseElevation; }
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
    this.cars = TD.elevs.map(e => { const c = TowerCore.car(); if (c) c.position.set(e.x, TD.room, e.y); return c; });
    this.carLegs = this.cars.map(() => []); this.carRest = this.cars.map(() => "lobby");
    for (const c of this.cars) if (c) this.world.add(c);
    this.city = new CityBuilder();
    this.basement = new OfficeBasement();
    for (let c = 0; c < TD.elevs.length; c++) {      // B1 的電梯門（吃 B1 自己的冷光）
      const d = TowerCore.landingDoor(c);
      if (!d) continue;
      TowerCore.setDoor(d, 0);
      enumerateHierarchy(d, n => { if (n.isMesh) setCategory(n, (category(n) & ~1) | OfficeBasement.mask); });
      this.basement.root.add(d);
    }
    this.driver = scnNode();
    this.world.add(this.driver);
    this.world.add(this.city.root);
    this.world.add(this.basement.root);
    this.ambient = scnLight({ type: "ambient" });
    this.scene.add(this.ambient);
    this.sun = scnLight({ type: "directional", mask: ~OfficeBasement.mask, euler: OfficeBuilder.sunEuler });     // 太陽照不進地下室
    this.scene.add(this.sun);
    // 室內暖補光：只照大樓（第 0 位元）；ambient 不吃位元 ⇒ 用 directional（同 Swift）
    this.fill = scnLight({ type: "directional", mask: 1, euler: [-0.45, 0.2, 0], color: 0xFFE2BE });
    this.scene.add(this.fill);
    // 夜晚戶外月光補光（只照城市、大地面）
    this.moonFill = scnLight({ type: "directional", mask: OfficeBuilder.outdoorMask, euler: [-0.85, 0.55, 0], color: 0x8E9CC4 });
    this.scene.add(this.moonFill);
    this.omni = [];
    // 鏡頭：fov 34（垂直）、zNear 1、zFar 500
    this.camera = new THREE.PerspectiveCamera(34, aspect, 1, 500);
    this.aspect = aspect;
    this.scene.add(this.camera);
    this.weatherFX = new WeatherFX();
    this.weatherFX.attach(this.camera, this.scene);
    /** SceneKit 相機的後製參數（three 這邊還沒做 bloom／vignette；先記數值給 dump 比） */
    this.post = { hdr: true, bloom: 0, bloomThreshold: 0.8, bloomBlur: 8, vignette: 0, vignettePower: 1 };
    this.target = [0, 0, 0];             // Swift 的 v.defaultCameraController.target
    this.fogStart = 0; this.fogEnd = 0; this.fogDist = -1;
    this.modules = new Map();
    this.tower = { floors: [] };
    this.decor = {};
    this.guardLevel = "normal";
    this.gridStage = "normal";
    this.underground = false;
    this.look = null;
    this.lodDirty = true; this.lodAt = [0, 0, 0]; this.cutSig = ""; this.omniDirty = true; this.focusY = 0;
    this.cutV = null; this.cutFar = 0;
    this.framedOnce = false;
    // TODO(轉寫)：persons、ghosts、boards、guard、emergency…（weatherFX 只有 attach）
    LightMask.attach(this.scene);
    this.applyLights();
  }

  // MARK: 燈光（規範 §3.8）

  setNight(n) { return this.setLook(n ? SkyLook.night : SkyLook.day); }

  /** 天色（Swift setLook 的節流先不搬：bench／Windows 呼叫端自己控制頻率） */
  setLook(l) { this.look = l; this.applyLights(); return true; }

  get gridScale() { return { normal: 1, dim: 0.6, flicker: 0.35, blackout: 0 }[this.gridStage] ?? 1; }

  applyLights() {
    const l = this.look ?? SkyLook.day;
    const fixedDay = l === SkyLook.day, fixedNight = l === SkyLook.night;
    VoxMat.setBlend(l.dark, l.lamps);
    // TODO(轉寫)：TowerSign.setDark(l.dark)、updateBeam()
    if (fixedDay || fixedNight) {
      this.scene.background = fixedNight ? TowerCore.skyNight : TowerCore.skyDay;
      OfficeBuilder.bg = fixedNight ? OfficeBuilder.nightBg : OfficeBuilder.dayBg;
    } else {
      const az = l.sunDir ? OfficeBuilder.worldAngle(l.sunDir.azimuth) : OfficeBuilder.artAngle;
      this.scene.background?.dispose?.();
      this.scene.background = skyGlowCube(l.horizon, l.zenith, l.glow, l.glowAmount, az);
      OfficeBuilder.bg = ns(l.horizon);
    }
    this.applyFog();
    // 大地面底色
    const g = VoxMat.dayNight(TP.groundDay, TP.groundNight);
    (fixedDay ? VoxMat.color(TP.groundDay) : fixedNight ? VoxMat.color(TP.groundNight) : ns(l.ground)).toThree(g.color);
    // 冷暖分光
    this.ambient.intensity = scnIntensity(l.ambientIntensity);
    ns(l.ambientColor).toThree(this.ambient.color);
    this.sun.intensity = scnIntensity(l.keyIntensity);
    ns(l.keyColor).toThree(this.sun.color);
    if (l.sunDir) {
      const el = l.sunDir.elevation * Math.PI / 180, th = OfficeBuilder.worldAngle(l.sunDir.azimuth);
      const toSun = [Math.cos(el) * Math.sin(th), Math.sin(el), -Math.cos(el) * Math.cos(th)];
      aimDirectional(this.sun, new THREE.Vector3(-toSun[0], -toSun[1], -toSun[2]));
    } else {
      aimDirectional(this.sun, frontOfEuler(...OfficeBuilder.sunEuler));
    }
    const ps = this.gridScale;
    VoxMat.setPower(ps);
    const fillI = l.fill + (OfficeBuilder.legacyNight ? 0 : OfficeBuilder.nightFill) * l.lamps;
    this.fill.intensity = scnIntensity(fillI * (0.4 + 0.6 * ps));
    this.fill.visible = !(fillI <= 0);
    this.moonFill.intensity = scnIntensity(l.moonFill);
    this.moonFill.visible = !(l.moonFill <= 0);
    // 靜態假影子：太陽轉到別的方向、或太低，就淡掉
    let kDay = 1.0;
    if (l.sunDir) {
      let diff = Math.abs(OfficeBuilder.worldAngle(l.sunDir.azimuth) - OfficeBuilder.artAngle) % (2 * Math.PI);
      if (diff > Math.PI) diff = 2 * Math.PI - diff;
      kDay = OfficeBuilder.smooth(100, 45, diff * 180 / Math.PI) * OfficeBuilder.smooth(4, 15, l.sunDir.elevation);
    } else if (!fixedDay && l.dark >= 0.5) kDay = 0;
    const k = Math.max(kDay, OfficeBuilder.smooth(0.5, 0.95, l.dark)) * (1 - (l.overcast ?? 0));
    for (const m of [CityBuilder.shade, CityBuilder.shadeOut]) { m.transparent = k < 1; m.opacity = k; m.needsUpdate = true; }
    // 夜晚：bloom、四角壓暗（three 這邊只記數值）
    this.post.bloom = this.underground ? 0.9 : 0.6 * l.lamps * ps;
    this.post.hdr = this.underground || l.lamps > 0.001;
    this.basement.setPower(ps);
    this.post.vignette = 0.35 * l.dark;
    this.post.vignettePower = 1.0;
    this.omniBase = 700 * l.lamps * ps;
    this.weatherFX.setDark(l.dark);
    this.city.setDark(l.dark);
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
   * 樓層內容變了才重建那一層；樓層換位置（搬家動畫）還沒搬：一律直接到位。
   * tower＝TowerPlan（{floors:[…]}，mac-input.json 的格式）；decor＝專案（小寫）→ FloorDecor。回傳 "none"｜"layout"｜"size"
   */
  update(newPlan, decor, wander, islands, guardStatus, scanning, animate, now = new Date()) {
    const plan = !newPlan?.floors?.length ? OfficeBuilder.fallback : newPlan;
    const old = this.tower;
    const first = this.modules.size === 0;
    this.decor = decor ?? {};
    this.tower = plan;
    this.guardLevel = guardStatus?.level ?? "normal";
    // 1. 模組：內容變了的重建
    for (const f of plan.floors) {
      const key = this.moduleKey(f);
      const m = this.modules.get(f.id);
      if (m && m.key === key) { m.floor = f; continue; }
      const parts = this.buildModule(f);
      if (f.kind === "lobby") { const d = TowerCore.frontDoor(); if (d) { TowerCore.setDoor(d, 0, "front"); parts.node.add(d); } }
      if (f.kind !== "idle") for (let c = 0; c < TD.elevs.length; c++) { const d = TowerCore.landingDoor(c); if (d) { TowerCore.setDoor(d, 0); parts.node.add(d); } }
      if (m) { parts.node.position.copy(m.parts.node.position); m.parts.node.removeFromParent(); }
      else parts.node.position.set(0, f.y, 0);
      this.cutNow(parts);
      this.world.add(parts.node);
      this.modules.set(f.id, { parts, key, floor: f });
      this.lodDirty = true; this.cutSig = ""; this.omniDirty = true;
    }
    const gone = [...this.modules.keys()].filter(id => !plan.floors.some(f => f.id === id));
    // 2. 位置：搬家動畫 TODO(轉寫 startMove)；先直接到位
    for (const id of gone) { this.modules.get(id)?.parts.node.removeFromParent(); this.modules.delete(id); }
    for (const f of plan.floors) { const m = this.modules.get(f.id); if (m) { m.parts.node.position.set(0, f.y, 0); m.parts.node.rotation.y = 0; } }
    // 3. 電梯井、溜滑梯、結構柱
    const top = this.totalHeight(plan);
    const roofY = plan.floors.find(f => f.id === "roof")?.y ?? 0;
    this.rebuildCore(top, roofY);
    this.omniDirty = true;
    this.assignOmni();
    // 4. TODO(轉寫)：人、影分身、看板、保全（updatePeople／updateGhosts／updateBoards／updateGuard／updateEmergency／updateCooler）
    if (first) return "layout";
    return this.totalHeight(old) !== this.totalHeight(plan) ? "size" : "none";
  }
  totalHeight(p = this.tower) { const l = p.floors[p.floors.length - 1]; return l ? l.y + l.height : 0; }
  projectFloors(p = this.tower) { return p.floors.filter(f => f.kind === "project"); }
  floor(id) { return this.tower.floors.find(f => f.id === id) ?? null; }

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
      case "project": p = TowerModules.project(f, this.decor[(f.project ?? "").toLowerCase()], () => {}); break;
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
    // TODO(轉寫)：weatherFX.shelter（擋雨盒，Mac 路徑 weather-shelter）
    this.cutSig = ""; this.lodDirty = true;
  }

  updateCity(s, animate) { this.city.update(s, animate); }

  // MARK: 鏡頭停下來時算一次：cutaway、霧、夜晚 omni（看板遠近 TODO）

  updateLOD(p, target) {
    const ug = this.setUnderground(p[1] < 0);
    if (!(this.lodDirty || Math.hypot(p[0] - this.lodAt[0], p[1] - this.lodAt[1], p[2] - this.lodAt[2]) > 0.5)) return ug;
    this.lodDirty = false; this.lodAt = p.slice();
    // TODO(轉寫)：boards 遠近、board-mast
    if (Math.abs(this.focusY - target[1]) > 0.5) { this.focusY = target[1]; this.omniDirty = true; }
    const lo = [-TD.W / 2 - 1, OfficeBasement.bottomY, TD.zB - 2], hi = [TD.W / 2 + 1, this.totalHeight() + 3, TD.zF + 1];
    const cl = [0, 1, 2].map(i => Math.min(Math.max(p[i], lo[i]), hi[i]));
    const near = Math.hypot(p[0] - cl[0], p[1] - cl[1], p[2] - cl[2]);
    this.updateFog(Math.hypot(p[0] - target[0], p[1] - target[1], p[2] - target[2]), near);
    this.assignOmni();
    return this.applyCutaway(p) || ug;
  }

  setUnderground(u) {
    if (u === this.underground) return false;
    this.underground = u;
    this.basement.setLive(u, true);
    for (const n of [this.env, this.city.root]) { if (u) { setOpacity(n, 0); n.visible = false; } else { n.visible = true; setOpacity(n, 1); } }
    this.cutSig = ""; this.lodDirty = true;
    this.applyLights();
    return true;
  }

  /** 霧距＝鏡頭到轉軸距離 ×1.3 → ×2.6（至少 60 → 230）；zFar 跟著霧；zNear 鏡頭遠時拉大、最近距離的一半為上限 */
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

  /** 面向鏡頭的實心牆藏起來（玻璃不藏）；門牌搬到離鏡頭最遠的那面牆 */
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
    const set = f => { const on = !f.glass && d2(f.n, v) > f.cut; f.node.visible = !on; setOpacity(f.node, on ? 0 : 1); };
    for (const m of this.modules.values()) { m.parts.facades.forEach(set); this.placePlate(m.parts, far); }
    this.coreFacades.forEach(set);
    this.basement.facades.forEach(set);
    return true;
  }
  cutNow(p) {
    if (!this.cutV) return;
    const v = this.cutV;
    for (const f of p.facades ?? []) { const on = !f.glass && f.n[0] * v[0] + f.n[1] * v[1] > f.cut; setOpacity(f.node, on ? 0 : 1); f.node.visible = !on; }
    if (p.plate !== undefined) this.placePlate(p, this.cutFar);
  }
  /** 門牌貼在哪面牆：0 後、1 前（內側）、2 左、3 右 */
  placePlate(p, far) {
    const plate = p.plate;
    if (!plate) return;
    const w = p.plateW, y = p.plateY, inset = 0.17;
    if (p.outsidePlate) {
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

  /** 夜晚 omni：大廳 1、頂樓 1、每個專案樓層 1（衰減 1→11、只照那層的光照位元）；白天全關 */
  assignOmni() {
    if (!this.omniDirty) return;
    this.omniDirty = false;
    if (!(VoxMat.lamps > 0.001)) { this.omni.forEach(o => { o.visible = false; }); return; }
    const spots = [];
    const lobby = this.modules.get("lobby"), roof = this.modules.get("roof");
    if (lobby) spots.push([[0.3, lobby.parts.node.position.y + 3.0, 0.5], OfficeBuilder.lobbyOmni / 700, 11]);
    if (roof) spots.push([[-0.5, roof.parts.node.position.y + 2.0, 0.7], 1, 11]);
    const masks = spots.map(() => 1);
    this.projectFloors().forEach((f, i) => {
      const m = this.modules.get(f.id);
      if (!m) return;
      const bit = OfficeBuilder.floorLightBit(i);
      enumerateHierarchy(m.parts.node, n => { if (n.isMesh) setCategory(n, (category(n) & ~OfficeBuilder.floorLightBits) | bit); });
      for (const g of m.parts.facades) if (g.glass) enumerateHierarchy(g.node, n => { if (n.isMesh) setCategory(n, category(n) & ~OfficeBuilder.floorLightBits); });
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
    const roof = this.floor("roof");
    if (roof && Math.abs(roof.y - (last.y + last.height)) < 0.01) hi = roof.y + TowerSpec.slab + 0.15;
    const lobby = this.floor("lobby");
    if (this.guardLevel !== "normal" && lobby) lo = Math.min(lo, lobby.y + 0.4 * lobby.height);
    const idle = this.tower.floors.find(f => f.kind === "idle");
    if (this.guardLevel === "normal" && idle && idle.y + idle.height <= first.y + 0.01) lo = Math.max(lo, idle.y + idle.height * 0.5);
    return [lo, hi];
  }
  /** 從右前方、略高一點看「有人的樓層」（方位 16°、仰角 12°） */
  frameCamera(aspect = this.aspect) {
    aspect = Math.max(0.4, aspect);
    const [lo, hi] = this.frameRange();
    const az = OfficeBuilder.azimuth, el = OfficeBuilder.elevation;
    const [dist, t] = OfficeBuilder.fit([-TD.Wd / 2, lo, TD.zFd - 4.8], [TD.Wd / 2, hi, TD.zFd], aspect, az * Math.PI / 180, el * Math.PI / 180, 34, 1.02);
    this.place(t, dist, az, el);
  }
  frameCity(aspect = this.aspect) {
    aspect = Math.max(0.4, aspect);
    const b = CityBuilder.bounds;
    const el = aspect < 1 ? 55 : 46;
    const [dist, t] = OfficeBuilder.fit(b.lo, b.hi, aspect, 18 * Math.PI / 180, el * Math.PI / 180, 34, 0.98);
    this.place(t, dist, 18, el);
  }
  placeTest(t, dist, az, el) { this.place(t, dist, az, el); }
  place(t, dist, az, el) {
    const d = OfficeBuilder.dir(az * Math.PI / 180, el * Math.PI / 180);
    this.framedOnce = true;
    this.camera.position.set(t[0] + d[0] * dist, t[1] + d[1] * dist, t[2] + d[2] * dist);
    this.camera.up.set(0, 1, 0);
    this.camera.lookAt(t[0], t[1], t[2]);
    this.camera.updateMatrixWorld(true);
    this.target = t.slice();
    this.lodDirty = true; this.focusY = t[1]; this.omniDirty = true;
  }
  get cameraPosition() { const p = this.camera.position; return [p.x, p.y, p.z]; }

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
}
