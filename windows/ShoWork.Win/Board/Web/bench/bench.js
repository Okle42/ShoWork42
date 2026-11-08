// JS 端量尺（11-01 P0）：照 Mac OfficeBench.cityShots（--office-bench city／dump）一樣的順序建場景、擺鏡頭、出圖、出 dump。
// Mac 的順序：OfficeBuilder() → setNight(true) → update(示範資料) → frameCamera → updateLOD → updateCity →
//   夜、日各一輪 6 個鏡頭（place → updateLOD）→ 每輪最後回到 default 再 dump。霧距、zNear 有遲滯（跟上一個鏡頭有關），所以整個順序照跑。

import * as THREE from "three";
import { walkScene, hiddenPaths, hexOf, round4 as R, vec3r as V3, ScnPost } from "../kit.js";
import { OfficeBuilder } from "../scene/builder.js";
import { CityBuilder } from "../scene/city.js";
import { Act } from "../scene/actions.js";

// console error／未接住的例外都記下來（js_bench 讀 window.__info.errors；完成條件是 0 個）
const consoleErrors = [];
{ const ce = console.error.bind(console); console.error = (...a) => { consoleErrors.push(a.map(String).join(" ")); ce(...a); }; }
addEventListener("error", e => consoleErrors.push(String(e.message)));
addEventListener("unhandledrejection", e => consoleErrors.push(String(e.reason)));

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
const render = b => { b.presentBegin(); post.render(b.scene, b.camera, b.post); b.presentEnd(); };
const pos = b => b.cameraPosition;

async function city() {
  const input = await (await fetch(q.get("input") ?? "./mac-input.json")).json();   // input＝別份 Mac 輸入（同一次 Mac dump 的 mac-input.json）
  OfficeBuilder.cutFade = 0;          // Mac：bench 把牆的淡出設 0（SCNRenderer 裡隱式動畫走不完）
  const b = new OfficeBuilder({ aspect: W / H });
  b.setNight(true);
  b.update(input.tower, input.decor, input.wander, input.islands, input.guardStatus, false, true, new Date((input.now + +(q.get("nowShift") ?? 0)) * 1000));   // nowShift：Mac 的 update 用 Date()，比 input.now 早一點（路上的人位置差在這）
  b.frameCamera(W / H);
  b.updateLOD(pos(b), b.target);
  OfficeBuilder.testMode = true;      // Mac cityShots：BoardWindow.testMode = true（之後的取景直接定位）
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

// MARK: 動畫模式（對 Mac --office-bench move／poof／rain＋SHOWORK_BENCH_PATROL；walk 見 anim()）
// Mac 用 SCNRenderer 照 fps 一張張畫、動作照實際時間推；這裡用固定步長推 Act（1/fps 秒一步，不看實際時間 ⇒ 每次結果一樣），
// 每個檢查點把 Mac 會印的東西放進 window.__log（同樣的字），js_bench／人工對照 Mac 的輸出。
async function anim(mode) {
  await import("../scene/poof.js").catch(() => null);       // builder 的過場是非同步載入：先等它好
  await new Promise(r => setTimeout(r, 0));
  const input = await (await fetch(q.get("input") ?? "./mac-input.json")).json();
  const fps = +(q.get("fps") ?? (mode === "move" ? 24 : 10));
  const log = [], say = s => { log.push(s); console.log(s); };
  OfficeBuilder.cutFade = 0;
  const b = new OfficeBuilder({ aspect: W / H });
  b.setNight(q.get("night") === "1");
  const now0 = input.now + +(q.get("nowShift") ?? 0);
  let tower = input.tower, islands = input.islands;
  const upd = (isl = islands, scanning = false) => b.update(tower, input.decor, input.wander, isl, input.guardStatus, scanning, true, new Date(now0 * 1000));
  upd();
  b.frameCamera(W / H);
  b.updateLOD(pos(b), b.target);
  let t = 0;
  const step = n => { for (let i = 0; i < n; i++) { b.tick(1 / fps); t += 1 / fps; } };
  if (mode === "move") {
    // 把最上面兩個專案樓層對調（Mac：模擬固定號碼的專案進出造成換位置）
    const fl = tower.floors.map(f => ({ ...f }));
    const idx = fl.map((f, i) => f.kind === "project" ? i : -1).filter(i => i >= 0);
    const a = idx[idx.length - 2], c = idx[idx.length - 1];
    const ya = fl[a].y; [fl[a], fl[c]] = [fl[c], fl[a]]; fl[a].y = ya; fl[c].y = ya + fl[a].height;
    tower = { floors: fl };
    upd();
    b.updateLOD(pos(b), b.target);
    for (const k of [1.0, 1 + 1 / fps, 2.0, 2.2]) {
      step(Math.round((k - t) * fps));
      const ys = b.world.children.filter(n => n.name?.startsWith("floor:p:")).map(n => `${n.name} y=${n.position.y.toFixed(2)} z=${n.position.z.toFixed(2)}`);
      say(`bench 搬家中第 ${t.toFixed(3)} 秒： ${ys.join("、")}`);
    }
  } else if (mode === "poof") {
    // 第 0.5 秒拿掉一個人（離開過場）、第 2 秒放回來（出現過場）；每個階段印節點數，結束要回到原本的數量
    const victim = islands.find(i => i.project === "Demo-動作").people[0].card.id;
    const without = islands.map(i => ({ ...i, people: i.people.filter(p => p.card.id !== victim) }));
    step(Math.round(0.5 * fps));
    const base = b.nodeCount; upd(without);
    say(`bench poof 離開 開始 nodes ${base} → ${b.nodeCount}（煙 10 顆＋煙的根）`);
    step(Math.round(0.4 * fps)); say(`bench poof 離開 第 0.4 秒 nodes ${b.nodeCount}`);
    step(Math.round(0.7 * fps)); await new Promise(r => setTimeout(r, 0));
    say(`bench poof 離開 結束 nodes ${b.nodeCount}（少了那個人的節點）`);
    upd(); say(`bench poof 出現 開始 nodes ${b.nodeCount}`);
    step(Math.round(1.2 * fps)); await new Promise(r => setTimeout(r, 0));
    say(`bench poof 出現 結束 nodes ${b.nodeCount}（應＝原本 ${base}）${b.nodeCount === base ? " OK" : " 不一致"}`);
  } else if (mode === "patrol") {
    // Mac rain＋SHOWORK_BENCH_PATROL=1：示範城市資料、保全馬上出門
    OfficeBuilder.testMode = true;
    if (q.get("city") !== "0") b.updateCity(input.city, false);     // city=0：同 Mac 沒開 CityMonitor.demo（沒有堆場 ⇒ 不巡貨櫃場）
    const cam = (q.get("benchCam") ?? "16,25,180").split(",").map(Number);
    b.placeTest([0, b.totalHeight() / 2, 0], cam[2], cam[0], cam[1]);
    b.updateLOD(pos(b), b.target);
    say(`bench patrol 出發 ${b.startPatrol()}`);
    const man = b.guardNode.getObjectByName("guard-man");
    const path = b.patrolPath();
    say(`bench patrol 路線 ${path.duration.toFixed(2)} 秒、正門 ${JSON.stringify(b.frontDoorStops(path, 0).map(s => [+s.from.toFixed(2), +s.to.toFixed(2)]))}`);
    const door = b.frontDoor, L = door?.getObjectByName("L");
    for (const k of q.get("at")?.split(",").map(Number) ?? [5, 20, 40, 60]) {
      step(Math.round((k - t) * fps));
      const beam = man.getObjectByName("beam");
      say(`bench patrol t=${t.toFixed(1)} man=${[man.position.x, man.position.y, man.position.z].map(x => x.toFixed(3))} face=${man.rotation.y.toFixed(3)} door=${L ? L.position.x.toFixed(3) : "-"} beam=${beam ? `${beam.visible}/${beam.scale.y.toFixed(2)}` : "-"}`);
    }
  } else if (mode === "walk") {
    // 輸入裡路上的人照行程走（Mac walk 模式的行程由 WanderPlanner 現算，JS 沒有 ⇒ 用 mac-input 的 wander）：每秒印路上的人位置
    const trips = Object.entries(input.wander.states).filter(([, s]) => s.trip);
    say(`bench walk 路上的人 ${trips.length}`);
    for (let k = 1; k <= +(q.get("secs") ?? 5); k++) {
      step(fps);
      for (const [id] of trips) { const n = b.personNode(id); if (n) say(`bench walk t=${t.toFixed(1)} ${id} ${[n.position.x, n.position.y, n.position.z].map(x => x.toFixed(3))} face=${n.rotation.y.toFixed(3)} car0=${b.cars[0].position.y.toFixed(3)} car1=${b.cars[1].position.y.toFixed(3)}`); }
    }
  }
  render(b);
  window.__log = log;
  return null;
}

try {
  const mode = q.get("mode");
  const d = test === "kit" ? await kit() : mode ? await anim(mode) : await city();
  if (d) window.__dump = JSON.stringify(d);
  window.__info = { renderer: renderer.getContext().getParameter(renderer.getContext().VERSION), calls: renderer.info.render.calls, errors: consoleErrors };
} catch (e) {
  window.__error = String(e && e.stack || e);
  console.error(e);
}
window.__ready = true;
