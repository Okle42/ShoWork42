// B1／雨的 JS 量尺（11-02 P8）：照 Mac OfficeBench.run(mode: "rain") 的順序建場景、擺鏡頭、推進 t 秒、出圖。
// Mac 的順序：OfficeBuilder() → setNight(true) → update(示範資料) → frameCamera → updateLOD → setWeather(preset) → placeTest(target, dist, az, el)
//   → updateLOD（鏡頭 y < 0 ⇒ setUnderground：B1 出現、圖譜開始轉）→ 每幀 render(atTime: t)；第 t 秒存一張。
// SceneKit 的動作（圖譜自轉）、粒子（雨）都跟著 renderer 時間走 ⇒ 這裡用 Act.tick／weatherFX.tick 推到同一個 t。

import * as THREE from "three";
import { walkScene, hiddenPaths, hexOf, round4 as R, vec3r as V3, ScnPost } from "../kit.js";
import { OfficeBuilder } from "../scene/builder.js";
import { Act, syncOpacity } from "../scene/actions.js";
import { OfficeStyleFX } from "../scene/stylefx.js";
import { WeatherLook, WeatherKind, weathered } from "../scene/weather.js";

const q = new URLSearchParams(location.search);
const errs = [];
for (const k of ["error", "warn"]) { const f = console[k].bind(console); console[k] = (...a) => { errs.push(a.map(String).join(" ").slice(0, 300)); f(...a); }; }
const W = +(q.get("w_px") ?? 1600), H = +(q.get("h_px") ?? 1000);
const weather = q.get("w") ?? "typhoon";
const cam = (q.get("cam") ?? "16,25,180").split(",").map(Number);
const tgt = (q.get("target") ?? "").split(",").filter(s => s !== "").map(Number);
const T = +(q.get("t") ?? 2);
const wantDump = q.get("dump") === "1";

const renderer = new THREE.WebGLRenderer({ antialias: true, preserveDrawingBuffer: true });
renderer.setPixelRatio(1);
renderer.setSize(W, H);
renderer.outputColorSpace = THREE.SRGBColorSpace;
renderer.toneMapping = THREE.NoToneMapping;
document.body.appendChild(renderer.domElement);
const post = new ScnPost(renderer);

async function run() {
  const input = await (await fetch("./mac-input.json")).json();
  const b = new OfficeBuilder({ aspect: W / H });
  b.setNight(true);
  b.update(input.tower, input.decor, input.wander, input.islands, input.guardStatus, false, true, new Date(input.now * 1000));
  b.frameCamera(W / H);
  const pos = () => b.cameraPosition;
  b.updateLOD(pos(), b.target);
  const w = WeatherLook.of(WeatherKind.preset(weather));
  // OfficeBuilder.setWeather（builder.js 還沒有時直接交給 WeatherFX，天色另外疊 weathered）
  if (typeof b.setWeather === "function") b.setWeather(w);
  else if (b.weatherFX.set(w) && b.look) b.setLook(weathered(b.look, w));
  const c = tgt.length === 3 ? tgt : [0, b.totalHeight() / 2, 0];
  b.placeTest(c, cam[2], cam[0], cam[1]);
  b.updateLOD(pos(), b.target);
  b.weatherFX.aim();
  // 推進到第 T 秒（SceneKit render(atTime:)）：動作（圖譜自轉）、雨的粒子
  const steps = Math.max(1, Math.round(T * 10));
  for (let i = 0; i < steps; i++) { Act.tick(T / steps); b.weatherFX.tick(T / steps); }
  syncOpacity(b.scene);
  // style＝diorama｜blueprint：OfficeStyleFX 的後製（鏡頭沒換正交，只看 shader）
  const tech = OfficeStyleFX.technique(q.get("style") ?? "voxel");
  if (tech) tech.render(renderer, b.scene, b.camera); else post.render(b.scene, b.camera, b.post);
  let dump = null;
  if (wantDump) {
    const wk = walkScene(b.scene, "basement");
    dump = { source: "js", night: true, only: "basement", boxes: wk.boxes, geoms: wk.geoms, lights: wk.lights, materials: [...wk.mats].sort(),
             cameras: [], hidden: hiddenPaths(b.scene) };
  }
  window.__info = { underground: b.underground, raining: b.weatherFX.raining, drops: b.weatherFX.ps?.geometry.instanceCount ?? 0,
                    spin: b.basement.pivot.rotation.y, cam: V3(b.camera.position), calls: renderer.info.render.calls,
                    rig: { visible: b.weatherFX.rig.visible, parent: b.weatherFX.rig.parent?.type, pos: V3(b.weatherFX.rig.position) }, errs, shelter: { vis: b.weatherFX.shelterNode.visible, parent: b.weatherFX.shelterNode.parent?.type ?? null, pos: V3(b.weatherFX.shelterNode.position), box: b.weatherFX.shelterNode.userData.scn?.params } };
  // neural-edges 是 LineSegments：kit.js 的 walkScene 只收 Mesh ⇒ 這裡另外報它的 geometry（對 Mac dump 的 SCNGeometry bbox／verts）
  const e = b.basement.graphNode?.getObjectByName("neural-edges");
  if (e) { e.geometry.computeBoundingBox(); window.__info.edges = { bboxLo: V3(e.geometry.boundingBox.min), bboxHi: V3(e.geometry.boundingBox.max), verts: e.geometry.attributes.position.count }; }
  return dump;
}

try {
  const d = await run();
  if (d) window.__dump = JSON.stringify(d);
} catch (e) {
  window.__error = String(e && e.stack || e);
  console.error(e);
}
window.__ready = true;
