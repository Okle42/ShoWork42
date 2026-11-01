// JS 端量尺（11-01 P0）：照 Mac OfficeBench.cityShots（--office-bench city／dump）一樣的順序建場景、擺鏡頭、出圖、出 dump。
// Mac 的順序：OfficeBuilder() → setNight(true) → update(示範資料) → frameCamera → updateLOD → updateCity →
//   夜、日各一輪 6 個鏡頭（place → updateLOD）→ 每輪最後回到 default 再 dump。霧距、zNear 有遲滯（跟上一個鏡頭有關），所以整個順序照跑。

import * as THREE from "three";
import { walkScene, hiddenPaths, hexOf, round4 as R, vec3r as V3, ScnPost } from "../kit.js";
import { OfficeBuilder } from "../scene/builder.js";
import { CityBuilder } from "../scene/city.js";

const q = new URLSearchParams(location.search);
const camName = q.get("cam") ?? "default";
const wantNight = q.get("night") === "1";
const wantDump = q.get("dump") === "1";
const test = q.get("test");
const W = +(q.get("w") ?? 1600), H = +(q.get("h") ?? 1000);

const renderer = new THREE.WebGLRenderer({ antialias: test !== "kit", preserveDrawingBuffer: true });
renderer.setPixelRatio(1);
renderer.setSize(W, H);
renderer.outputColorSpace = THREE.SRGBColorSpace;
renderer.toneMapping = THREE.NoToneMapping;
document.body.appendChild(renderer.domElement);
const post = new ScnPost(renderer);       // SceneKit 的 HDR bloom／vignette（只有 post.hdr 時才走）

function cameraDump(b, name) {
  const c = b.camera;
  c.updateMatrixWorld(true);
  const f = new THREE.Vector3(0, 0, -1).applyQuaternion(c.quaternion), u = new THREE.Vector3(0, 1, 0).applyQuaternion(c.quaternion);
  return { name, pos: V3(c.position), quat: [R(c.quaternion.x), R(c.quaternion.y), R(c.quaternion.z), R(c.quaternion.w)],
           front: V3(f), up: V3(u), target: V3(b.target), fov: R(c.fov), vertical: true, near: R(c.near), far: R(c.far),
           fogStart: R(b.fogStart), fogEnd: R(b.fogEnd), fogColor: hexOf(OfficeBuilder.bg.toThree()), fogExp: 1,
           hdr: b.post.hdr, bloom: R(b.post.bloom), bloomThreshold: R(b.post.bloomThreshold), bloomBlur: R(b.post.bloomBlur),
           vignette: R(b.post.vignette), vignettePower: R(b.post.vignettePower), hidden: hiddenPaths(b.scene) };
}
function sceneDump(b, night, cameras, only = null) {
  const w = walkScene(b.scene, only);
  return { source: "js", night, only: only ?? "", boxes: w.boxes, geoms: w.geoms, lights: w.lights, materials: [...w.mats].sort(), cameras,
           env: { background: b.scene.background?.isCubeTexture ? "cube6" : String(b.scene.background), bg: hexOf(OfficeBuilder.bg.toThree()),
                  fogColor: hexOf(OfficeBuilder.bg.toThree()) } };
}
const render = b => post.render(b.scene, b.camera, b.post);
const pos = b => b.cameraPosition;

async function city() {
  const input = await (await fetch("./mac-input.json")).json();
  const b = new OfficeBuilder({ aspect: W / H });
  b.setNight(true);
  b.update(input.tower, input.decor, input.wander, input.islands, input.guardStatus, false, true, new Date(input.now * 1000));
  b.frameCamera(W / H);
  b.updateLOD(pos(b), b.target);
  const s = input.city;
  b.updateCity(s, false);
  const views = [
    ["default", () => b.frameCamera(W / H)],
    ["overview", () => b.frameCity(W / H)],
    ["top", () => b.placeTest([0, 0, 4], 125, 0, 89)],
    ["branch", () => b.placeTest([CityBuilder.branchX + 1.9, 1, CityBuilder.laneZ + 1], 26, 25, 32)],
    ["airship", () => b.placeTest([-18.3, 4.5, CityBuilder.airshipDock(0)[2]], 32, -15, 14)],
    ["port", () => b.placeTest([CityBuilder.portX + 4, 0, CityBuilder.streetZ + 3], 30, 12, 30)],
  ];
  let dump = null;
  for (const night of [true, false]) {
    b.setNight(night);
    const cams = [];
    for (const [name, place] of views) {
      place();
      b.updateLOD(pos(b), b.target);
      cams.push(cameraDump(b, name));
      if (night === wantNight && name === camName) render(b);       // 畫進 canvas（preserveDrawingBuffer：之後不再畫就留著）
    }
    if (night === wantNight && wantDump) {
      views[0][1]();
      b.updateLOD(pos(b), b.target);
      dump = sceneDump(b, night, cams);
    }
    if (night === wantNight) break;
  }
  return dump;
}

async function kit() {
  const { kitScene, kitProbes } = await import("./kittest.js");
  const b = new OfficeBuilder({ aspect: W / H });
  b.world.add(kitScene());
  let dump = null;
  for (const night of [false, true]) {          // Mac kitTest：先白天、再夜晚
    b.setNight(night);
    b.placeTest([6.5, 1, -1.5], 28, 20, 32);
    b.updateLOD(pos(b), b.target);
    if (night !== wantNight) continue;
    render(b);
    if (wantDump) {
      dump = sceneDump(b, night, [cameraDump(b, "kit")], "kit-test");
      dump.lights = walkScene(b.scene).lights;
      dump.probes = kitProbes.map(([name, p]) => {
        const v = new THREE.Vector3(...p).project(b.camera);
        return { name, world: p, px: [R((v.x + 1) / 2 * W, 10), R((1 - v.y) / 2 * H, 10)] };
      });
    }
    break;
  }
  return dump;
}

try {
  const d = test === "kit" ? await kit() : await city();
  if (d) window.__dump = JSON.stringify(d);
  window.__info = { renderer: renderer.getContext().getParameter(renderer.getContext().VERSION), calls: renderer.info.render.calls };
} catch (e) {
  window.__error = String(e && e.stack || e);
  console.error(e);
}
window.__ready = true;
