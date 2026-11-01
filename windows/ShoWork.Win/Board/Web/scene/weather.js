// OfficeRain.swift（WeatherFX）照搬（11-02 P8）＋ShoWorkCore/Weather.swift 的 WeatherKind.preset／WeatherLook.of／SkyLook.weathered（畫面要用的那幾段）。
//
// 3D 辦公室的雨與閃電（10-21 台北真實天氣，規範 §3.8.2）。
// 雨：一組粒子掛在鏡頭底下（跟著鏡頭走，只蓋住看得到的那一塊：鏡頭前 10 公尺到 ≈ 鏡頭距離 ×0.7），
//     粒子在鏡頭座標落下（isLocal，10-23）、拉長成雨絲（stretchFactor）；雨量決定數量、風速決定傾斜（往畫面右邊斜）。
//     不下雨就整個拿掉 ⇒ 不會讓場景一直畫（晴天、多雲、陰天 CPU 跟沒有天氣一樣）。
// 閃電：雷雨時 6–16 秒隨機閃一次（兩下）；用一盞平常關著的 ambient 光，閃完就藏起來。
//
// Swift → JS 的差別：
//   · SCNParticleSystem → 1 個 InstancedBufferGeometry（一條雨絲＝一個 instance 的四邊形，1 個 draw call）。粒子的位置全在 GPU 算：
//     每條雨絲有固定的出生點（發射盒裡均勻亂數）與相位，第 t 秒＝出生點＋方向×速度×((t＋相位) mod 壽命)；
//     等於 SceneKit 穩定狀態（birthRate × 壽命＝同時存在的數量；warmupDuration＝壽命 ⇒ 一開就是下到一半的樣子）。CPU 每幀只改 1 個 uniform。
//   · 粒子時間：畫面迴圈每幀呼叫 weatherFX.tick(dt)（SceneKit 是 SCNView 自己推進）。
//   · 擋雨盒：SceneKit 的 shaderModifier（.geometry）→ ShaderMaterial 的 vertex shader，做的事一樣。

import * as THREE from "three";
import { scnLight, scnNode, SColor, setScnIntensity, setCategory } from "../kit.js";

// MARK: - 天氣種類與畫面參數（ShoWorkCore/Weather.swift）

export const WeatherKind = {
  all: ["clear", "cloudy", "overcast", "lightRain", "heavyRain", "thunder", "typhoon"],
  /** 下雨（休息的人不上頂樓，改去一樓咖啡館） */
  isWet: k => ["lightRain", "heavyRain", "thunder", "typhoon"].includes(k),
  title: { clear: "晴", cloudy: "多雲", overcast: "陰", lightRain: "小雨", heavyRain: "大雨", thunder: "雷雨", typhoon: "颱風級強風" },
  typhoonGust: 17.2, typhoonWind: 13.9, heavyRate: 7.6, rainRate: 0.1,
  thunderCodes: new Set([95, 96, 99]),
  heavyCodes: new Set([65, 67, 75, 82, 86]),
  rainy: c => (c >= 51 && c <= 67) || (c >= 71 && c <= 77) || (c >= 80 && c <= 82) || c === 85 || c === 86,
  /** WeatherNow：{ code, rainRate, cloudCover, wind, gust } → 種類 */
  classify(w) {
    if (w.gust >= this.typhoonGust || w.wind >= this.typhoonWind) return "typhoon";
    if (this.thunderCodes.has(w.code)) return "thunder";
    if (this.heavyCodes.has(w.code) || w.rainRate >= this.heavyRate) return "heavyRain";
    if (this.rainy(w.code) || w.rainRate >= this.rainRate) return "lightRain";
    if (w.code === 3 || w.code === 45 || w.code === 48 || w.cloudCover >= 85) return "overcast";
    if (w.code === 2 || w.cloudCover >= 40) return "cloudy";
    return "clear";
  },
  /** 測試視窗的強制天氣（SHOWORK_OFFICE_WEATHER／SHOWORK_BENCH_WEATHER=clear|cloudy|overcast|rain|heavy|storm|typhoon）：每種一組代表性的觀測值 */
  preset(name) {
    const W = (code, rainRate, cloudCover, wind, gust) => ({ code, rainRate, cloudCover, wind, gust });
    switch (name) {
      case "clear": return W(0, 0, 5, 2, 4);
      case "cloudy": return W(2, 0, 55, 3, 6);
      case "overcast": return W(3, 0, 100, 4, 8);
      case "rain": return W(61, 1.2, 100, 4, 8);
      case "heavy": return W(65, 12, 100, 6, 12);
      case "storm": return W(95, 16, 100, 7, 15);
      case "typhoon": return W(65, 20, 100, 18, 33);
      default: return null;
    }
  },
};

/** 天氣 → 畫面（疊在日出日落的 SkyLook 上，不取代）。clear ＝全部 0 ⇒ 畫面跟沒有天氣一模一樣 */
export const WeatherLook = {
  make() { return { cloud: 0, dim: 0, rain: 0, tilt: 0, fallSpeed: 30, lampBoost: 0, lightning: false, kind: "clear" }; },
  get clear() { return WeatherLook.make(); },
  equal(a, b) { return ["cloud", "dim", "rain", "tilt", "fallSpeed", "lampBoost", "lightning", "kind"].every(k => a[k] === b[k]); },
  /** w：WeatherNow（{ code, rainRate, cloudCover, wind, gust }）或 null */
  of(w) {
    if (!w) return WeatherLook.clear;
    const l = WeatherLook.make(); l.kind = WeatherKind.classify(w);
    const base = Math.min(1, Math.log1p(Math.max(0, w.rainRate)) / Math.log1p(40));     // 1 mm/h ≈ 0.19、12 ≈ 0.69、40 mm/h 以上 1
    const rain = minimum => Math.min(1, Math.max(base, minimum));
    switch (l.kind) {
      case "clear": return WeatherLook.clear;
      case "cloudy": l.cloud = 0.15 + 0.3 * Math.min(1, w.cloudCover / 100); l.dim = 0.03; break;
      case "overcast": l.cloud = 0.8; l.dim = 0.12; break;
      case "lightRain": l.cloud = 0.85; l.dim = 0.2; l.rain = rain(0.22); break;
      case "heavyRain": l.cloud = 0.95; l.dim = 0.38; l.rain = rain(0.6); l.lampBoost = 0.2; break;
      case "thunder": l.cloud = 1; l.dim = 0.48; l.rain = rain(0.6); l.lampBoost = 0.3; l.lightning = true; break;
      case "typhoon": l.cloud = 1; l.dim = 0.56; l.rain = rain(0.75); l.lampBoost = 0.4; l.lightning = WeatherKind.thunderCodes.has(w.code); break;
    }
    // 風：平均風與陣風混合；颱風級至少斜 1.4（約 55°）
    const eff = 0.6 * w.wind + 0.4 * w.gust;
    l.tilt = Math.min(1.8, eff / 14);
    if (l.kind === "typhoon") l.tilt = Math.max(1.4, l.tilt);
    l.fallSpeed = 28 + 16 * l.rain + (l.kind === "typhoon" ? 10 : 0);
    return l;
  },
};

/** SkyLook.weathered（Weather.swift 的 extension）：疊上天氣：天空往灰混、主光變弱變中性、環境光略壓暗、地面變暗（濕）、暗天氣城市燈提早亮。
 *  晴天回原值（像素不變）。sky＝solar.js 的 SkyLook 物件（顏色是 [r,g,b]） */
export function weathered(sky, w) {
  if (!(w.cloud > 0 || w.dim > 0)) return sky;
  const s = { ...sky };
  const c = w.cloud, d = w.dim;
  const mix = (a, b, f) => a.map((x, i) => x + (b[i] - x) * f);
  const lum = x => x[0] * 0.2126 + x[1] * 0.7152 + x[2] * 0.0722;
  const tint = [0.95, 0.98, 1.03];           // 雨天的灰略偏冷
  const hex = h => [((h >>> 16) & 255) / 255, ((h >>> 8) & 255) / 255, (h & 255) / 255];
  const L = lum(sky.horizon), hor = tint.map(t => L * t * (1 - 0.55 * d));
  s.horizon = mix(sky.horizon, hor, c);
  s.zenith = mix(sky.zenith, hor.map(x => x * 0.9), c);       // 陰天整片天幾乎一樣灰，天頂稍暗
  s.glowAmount = sky.glowAmount * (1 - c);
  s.ground = mix(sky.ground, sky.ground.map(x => x * (1 - 0.45 * d)), c);
  s.keyIntensity = sky.keyIntensity * (1 - 0.7 * c);
  s.keyColor = mix(sky.keyColor, hex(0xE4E8EE), c);
  s.ambientIntensity = sky.ambientIntensity * (1 + 0.15 * c) * Math.max(0.35, 1 - 1.1 * d);
  s.ambientColor = mix(sky.ambientColor, hex(0xC8D0DA), c * 0.7);
  s.fill = sky.fill * (1 - 0.4 * c) * Math.max(0.2, 1 - 1.2 * d);
  s.moonFill = sky.moonFill * (1 - 0.5 * c);
  if (sky.dark < 0.45) s.dark = Math.min(0.45, sky.dark + 0.9 * d);     // 白天變暗但不會被當成夜晚（isNight 是 ≥ 0.5）
  s.lamps = Math.max(sky.lamps, w.lampBoost);
  s.overcast = c;
  return s;
}

// MARK: - 雨的粒子（SCNParticleSystem 的替身）

/** 同時存在的雨絲上限（particles(1)＝3000） */
const MAX_DROPS = 3000;

const RAIN_VS = `
uniform vec3 uBox;        // 發射盒（寬、高、深）
uniform vec3 uDir;        // 落下方向（rig 本地座標，已正規化）
uniform float uSpeed, uSpeedVar, uLife, uLifeVar, uTime, uSize, uStretch, uSpread;
attribute vec2 corner;    // (−1/1 橫向, 0 頭／1 尾)
attribute vec4 aSeed;     // 出生點 xyz（0–1）、相位
attribute vec4 aVar;      // 速度、壽命、方向抖動、透明度（各 0–1）
varying vec2 vUv;
varying float vA;
void main() {
  float life = uLife * (1.0 + (aVar.y - 0.5) * 2.0 * uLifeVar);
  float speed = uSpeed * (1.0 + (aVar.x - 0.5) * 2.0 * uSpeedVar);
  // spreadingAngle：方向在小圓錐內抖一下
  vec3 up = abs(uDir.y) < 0.99 ? vec3(0.0, 1.0, 0.0) : vec3(1.0, 0.0, 0.0);
  vec3 t1 = normalize(cross(uDir, up)), t2 = cross(uDir, t1);
  float ang = aVar.z * 6.2831853, r = uSpread * sqrt(aSeed.w);
  vec3 dir = normalize(uDir + (t1 * cos(ang) + t2 * sin(ang)) * r);
  float age = mod(uTime + aSeed.w * life, life);
  vec3 p = (aSeed.xyz - 0.5) * uBox + dir * speed * age;
  // 拉長成雨絲：頭在 p、尾巴往回 speed × stretchFactor；寬 2×uSize（11-02 量尺：Mac 雨絲直切寬 3.4 px，寬＝size 時 1.6 px、2×size 時 3.0 px）；面向鏡頭
  vec4 head = modelViewMatrix * vec4(p, 1.0);
  vec4 tail = modelViewMatrix * vec4(p - dir * (speed * uStretch + uSize), 1.0);
  vec3 axis = tail.xyz - head.xyz;
  vec3 side = normalize(cross(axis, head.xyz)) * uSize;
  vec3 v = mix(head.xyz, tail.xyz, corner.y) + side * corner.x;
  vUv = vec2(corner.x, corner.y * 2.0 - 1.0);
  vA = aVar.w;
  gl_Position = projectionMatrix * vec4(v, 1.0);
}`;
const RAIN_FS = `
uniform vec4 uColor;
uniform float uAlphaVar;
varying vec2 vUv;
varying float vA;
void main() {
  // 粒子圖＝白色圓點、往外漸透明（NSGradient 白 → 透明）；拉長後變成兩頭尖的雨絲
  float r = length(vUv);
  if (r >= 1.0) discard;
  float a = clamp(uColor.a + (vA - 0.5) * 2.0 * uAlphaVar, 0.0, 1.0) * (1.0 - r);
  gl_FragColor = vec4(uColor.rgb, a);
  #include <colorspace_fragment>
}`;

function makeRain() {
  const g = new THREE.InstancedBufferGeometry();
  g.setAttribute("corner", new THREE.Float32BufferAttribute([-1, 0, 1, 0, 1, 1, -1, 1], 2));
  g.setIndex([0, 1, 2, 0, 2, 3]);
  // 固定種子的亂數（每次長一樣：截圖可比）
  let s = 0x5EED1234 >>> 0;
  const rnd = () => { s = (Math.imul(s, 1664525) + 1013904223) >>> 0; return s / 4294967296; };
  const seed = new Float32Array(MAX_DROPS * 4), vari = new Float32Array(MAX_DROPS * 4);
  for (let i = 0; i < MAX_DROPS * 4; i++) { seed[i] = rnd(); vari[i] = rnd(); }
  g.setAttribute("aSeed", new THREE.InstancedBufferAttribute(seed, 4));
  g.setAttribute("aVar", new THREE.InstancedBufferAttribute(vari, 4));
  g.instanceCount = 0;
  const u = {
    uBox: { value: new THREE.Vector3(1, 1, 1) }, uDir: { value: new THREE.Vector3(0, -1, 0) },
    uSpeed: { value: 30 }, uSpeedVar: { value: 0.12 }, uLife: { value: 1 }, uLifeVar: { value: 0.2 }, uTime: { value: 0 },
    uSize: { value: 0.02 }, uStretch: { value: 0.03 }, uSpread: { value: Math.tan(2 * Math.PI / 180) },
    uColor: { value: new THREE.Vector4(1, 1, 1, 0.5) }, uAlphaVar: { value: 0.25 },
  };
  const m = new THREE.ShaderMaterial({ uniforms: u, vertexShader: RAIN_VS, fragmentShader: RAIN_FS,
    transparent: true, depthWrite: false, depthTest: true, blending: THREE.NormalBlending, fog: false, side: THREE.DoubleSide });
  m.userData.lm = "constant";
  const mesh = new THREE.Mesh(g, m);
  mesh.name = "rain";
  mesh.frustumCulled = false;
  mesh.userData.scn = { type: "SCNParticleSystem", params: {} };
  // 雨不吃燈（isLightingEnabled＝false）；位元設成不會被點選、不被當成大樓
  setCategory(mesh, 0);
  return mesh;
}

// MARK: - WeatherFX

export class WeatherFX {
  /** 測試：SHOWORK_OFFICE_FLASH=1 ⇒ 閃電一直亮著（截圖看閃光的樣子）。Windows：設 WeatherFX.holdFlash = true */
  static holdFlash = false;

  constructor() {
    this.rig = scnNode("weather-rain");
    this.camera = null;
    this.ps = null;
    this.flash = null;
    this.weather = WeatherLook.clear;
    this.dist = 80;
    this.dark = 0.0;
    this.flashGen = 0;
    this.time = 0;
    /** 地下室、鏡頭鑽進大樓裡時藏起來 */
    this.hidden = { underground: false, inside: false };
    this.flashTimers = [];
    this.shelterNode = WeatherFX.makeShelterNode();
  }
  /** 下雨中（粒子要動 ⇒ 場景要持續渲染） */
  get raining() { return this.ps !== null; }

  /** 粒子數（整個雨區同時存在的雨絲）：雨量 0 → 400、1 → 3000 */
  static particles(rain) { return 400 + 2600 * rain; }
  /** 10-23 Kang：鏡頭拉近時雨看起來太密（雨盒變淺、雨絲離鏡頭近、每條都變大）⇒ 拉近減半：鏡頭距離 ≤40 → ×0.5、≥120 → ×1，中間線性 */
  static closeFactor(dist) { return 0.5 + 0.5 * Math.min(1, Math.max(0, (dist - 40) / 80)); }

  attach(camera, scene) {
    this.camera = camera;
    this.rig.name = "weather-rain";
    this.rig.renderOrder = 1000;       // 在擋雨盒（900）之後畫
    camera.add(this.rig);
    this.flash = scnLight({ type: "ambient", color: new SColor(0.82, 0.86, 1.0), intensity: 0 });
    this.flash.visible = false;
    scene.add(this.flash);
  }

  /** 每幀（畫面迴圈呼叫）：粒子時間往前走。SceneKit 由 SCNView 自己推進；這裡不下雨就什麼都不做 */
  tick(dt) {
    if (!this.ps || !(dt > 0)) return;
    this.time += dt;
    this.ps.material.uniforms.uTime.value = this.time;
  }

  /** 10-23 Kang（第二輪）：雨要掛在「實際在畫的那台」鏡頭；換過就搬（只比一個指標，0 額外成本）。回 true＝剛搬過 */
  follow(pov) {
    if (!pov || this.rig.parent === pov) return false;
    pov.add(this.rig);
    this.camera = pov;
    this.aim();
    return true;
  }

  setHidden(h) { this.hidden.underground = h; this.rig.visible = !(this.hidden.underground || this.hidden.inside); }
  setInside(i) { this.hidden.inside = i; this.rig.visible = !(this.hidden.underground || this.hidden.inside); }

  /** 10-23 Kang：雨穿進室內。雨盒在鏡頭前 10 公尺起、蓋住整個畫面；大樓是剖面（面向鏡頭的牆淡掉）⇒ 雨絲疊在樓層上，看起來像室內在下雨。
   *  擋雨盒：大樓外框一個只寫深度、不畫顏色的盒子，排在大樓之後、雨之前畫。頂點著色器把每個頂點沿視線拉到離鏡頭 7 公尺
   *  （比雨盒的 10 公尺近、比 zNear 最大 4 遠）⇒ 螢幕上的輪廓跟大樓一樣，深度卻在所有雨絲前面 ⇒ 大樓那一塊不下雨，四周照下。
   *  GPU 每格自己算（跟著鏡頭轉不用 CPU 更新）；一個盒子 12 個三角形，跟著雨一起出現（晴天藏起來）。頂到頂樓花園地板（花園照樣下雨） */
  static makeShelterNode() {
    const n = new THREE.Mesh(new THREE.BufferGeometry(), WeatherFX.shelterMaterial);
    n.name = "weather-shelter";
    n.renderOrder = 900;
    setCategory(n, 1 << 20);           // 不被燈光、點選當成大樓
    n.castShadow = false;
    n.frustumCulled = false;
    n.visible = false;
    return n;
  }
  static _shelterMat = null;
  static get shelterMaterial() {
    if (WeatherFX._shelterMat) return WeatherFX._shelterMat;
    const m = new THREE.ShaderMaterial({
      vertexShader: `
        void main() {
          // 鏡頭在模型座標的位置（＝scn_node.inverseModelViewTransform × 原點）
          vec3 c = (inverse(modelViewMatrix) * vec4(0.0, 0.0, 0.0, 1.0)).xyz;
          vec3 d = position - c;
          vec3 p = c + d * (7.0 / max(length(d), 0.001));
          gl_Position = projectionMatrix * modelViewMatrix * vec4(p, 1.0);
        }`,
      fragmentShader: "void main() { gl_FragColor = vec4(0.0); }",
      // readsFromDepthBuffer = false：GL 關掉深度測試時也不會寫深度 ⇒ 改成測試開著、永遠通過（AlwaysDepth），一樣不讀、照寫
      colorWrite: false, depthWrite: true, depthTest: true, depthFunc: THREE.AlwaysDepth, side: THREE.DoubleSide,
      transparent: true,                 // 排進透明那一輪（大樓玻璃 0 → 擋雨盒 900 → 雨 1000，跟 SceneKit 的 renderingOrder 一樣先後）
    });
    m.userData.lm = "constant";
    return (WeatherFX._shelterMat = m);
  }

  shelter(parent, lo, hi) {
    if (this.shelterNode.parent !== parent) parent.add(this.shelterNode);
    const e = [hi[0] - lo[0], hi[1] - lo[1], hi[2] - lo[2]];
    const old = this.shelterNode.geometry;
    this.shelterNode.geometry = new THREE.BoxGeometry(e[0], e[1], e[2]);     // 實際尺寸（不用 scale：著色器量的是模型座標的長度）
    old.dispose();
    this.shelterNode.userData.scn = { type: "SCNBox", params: { w: e[0], h: e[1], l: e[2], chamfer: 0 } };
    this.shelterNode.position.set((lo[0] + hi[0]) / 2, (lo[1] + hi[1]) / 2, (lo[2] + hi[2]) / 2);
  }

  /** 換天氣；回 true＝有變（畫面要重套燈光）。w＝WeatherLook */
  set(w) {
    if (WeatherLook.equal(w, this.weather)) return false;
    this.weather = { ...w };
    if (w.rain > 0) {
      if (!this.ps) { const p = makeRain(); this.rig.add(p); this.ps = p; }
      this.configure();
    } else if (this.ps) {
      this.ps.removeFromParent(); this.ps.geometry.dispose(); this.ps.material.dispose(); this.ps = null;
    }
    this.shelterNode.visible = this.ps !== null;
    this.flashGen += 1;
    this.flash.visible = false; setScnIntensity(this.flash, 0);
    if (w.lightning) {
      if (WeatherFX.holdFlash) { this.flash.visible = true; setScnIntensity(this.flash, 800); } else this.scheduleFlash(this.flashGen);
    }
    return true;
  }

  /** 天色暗度變了（日出日落／天氣）：雨絲顏色跟著換（白天淺灰、夜晚暗藍灰） */
  setDark(d) {
    if (!(Math.abs(d - this.dark) > 0.02)) return;
    this.dark = d;
    if (this.ps) this.applyColor();
  }

  /** 鏡頭距離變了（updateFog，鏡頭停下才算）：雨區深度跟著變 */
  size(d) {
    if (!(Math.abs(d - this.dist) > Math.max(2, this.dist * 0.1))) return;
    this.dist = d;
    if (this.ps) this.configure();
  }

  /** 鏡頭停下來：雨絲方向重新對準（世界的「往下＋往畫面右邊斜」換成鏡頭座標） */
  aim() {
    const p = this.ps, cam = this.camera;
    if (!p || !cam) return;
    cam.updateMatrixWorld(true);
    const r = new THREE.Vector3().setFromMatrixColumn(cam.matrixWorld, 0).normalize();      // simdWorldRight
    let h = new THREE.Vector3(r.x, 0, r.z);
    h = h.length() > 1e-4 ? h.normalize() : new THREE.Vector3(1, 0, 0);
    const world = new THREE.Vector3(0, -1, 0).addScaledVector(h, this.weather.tilt).normalize();
    // 世界方向 → 鏡頭座標（rig 掛在鏡頭底下、沒有旋轉 ⇒ 就是 rig 的本地座標）
    const inv = new THREE.Matrix4().copy(cam.matrixWorld).invert();
    const local = world.clone().transformDirection(inv);
    p.material.uniforms.uDir.value.copy(local);
  }

  get color() {
    const k = Math.min(1, Math.max(0, this.dark));
    const a = 0.32 + 0.22 * this.weather.rain;
    // 白天 #E6ECF5 → 夜晚 #8C9AB4
    return new SColor(0.90 - 0.35 * k, 0.925 - 0.32 * k, 0.96 - 0.255 * k, a);
  }
  applyColor() {
    const c = this.color, t = c.toThree();
    this.ps.material.uniforms.uColor.value.set(t.r, t.g, t.b, c.a);
  }

  configure() {
    const p = this.ps;
    if (!p) return;
    const w = this.weather, u = p.material.uniforms;
    // 看得到的那一塊：鏡頭前 near → far；垂直視角 34°（tan 17° ≈ 0.306），寬度照最寬 2:1 的視窗算
    const near = 10, far = Math.min(70, Math.max(24, this.dist * 0.7));
    const halfH = 0.306 * far * 1.1, halfW = halfH * 2;
    const v = w.fallSpeed;
    const margin = halfH;          // 上方多留一截：雨從畫面外落進來，上緣才不會稀
    const boxH = halfH * 2 + margin;
    u.uBox.value.set(halfW * 2, boxH, far - near);
    this.rig.position.set(0, margin / 2, -(near + far) / 2);
    const life = boxH / v;
    u.uLife.value = life;
    u.uLifeVar.value = 0.2;
    // 同時存在的數量＝birthRate × 壽命＝particles × closeFactor
    p.geometry.instanceCount = Math.min(MAX_DROPS, Math.round(WeatherFX.particles(w.rain) * WeatherFX.closeFactor(this.dist)));
    u.uSpeed.value = v;
    u.uSpeedVar.value = 0.12;
    u.uSize.value = w.kind === "typhoon" ? 0.026 : 0.018 + 0.006 * w.rain;
    u.uStretch.value = 0.03;
    this.applyColor();
    this.aim();
  }

  scheduleFlash(gen) {
    const t = setTimeout(() => {
      if (this.flashGen !== gen) return;
      // 兩下：亮 0.12 秒、暗 0.1 秒、再亮 0.1 秒（12 fps 下每下至少一格）
      const steps = [[0, 800], [0.12, 0], [0.22, 500], [0.32, 0]];
      for (const [dt, i] of steps) {
        setTimeout(() => {
          if (this.flashGen !== gen) return;
          setScnIntensity(this.flash, i);
          this.flash.visible = !(i === 0);
        }, dt * 1000);
      }
      this.scheduleFlash(gen);
    }, (6 + Math.random() * 10) * 1000);
    this.flashTimers.push(t);
    if (this.flashTimers.length > 8) this.flashTimers.shift();
  }
}
