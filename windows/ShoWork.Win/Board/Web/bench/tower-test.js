// tower.js 專用的量尺（11-02）：跟 Mac 的對照小程式（scratch 的 Probe，直接呼叫 OfficeTower.swift）建一模一樣的東西、dump 同一個格式。
//   16 主題 × 2 輪（不同人數、樓層號、亮燈、AI 擺設；第 2 輪最後一層沒有 decor）＋閒置薄層＋大廳（無／有招牌）＋頂樓＋搬家光框
//   ＋兩組電梯門（開 0.4）＋正門（開 0.7）＋車廂＋core（6 層）。每個模組往上疊 4 公尺。
//   tower-test.html 打開後把 dump JSON 寫進 <pre id="out">（headless Chrome --dump-dom 讀走）；也設 window.__dump。
// 案例產生器跟 Mac 那邊的 cases.json 同一個算法（改了兩邊一起改）。

import * as THREE from "three";
import { walkScene, round4 as R } from "../kit.js";
import { TowerModules, TowerCore, SlideDoor } from "../scene/tower.js";

const themes = "monitor app_studio library print_shop call_room trading_desk media_studio design_studio legal_room ledger_room game_lab hw_lab marketing dispatch_room drafting_room general".split(" ");
const seats = [0, 1, 2, 3, 4, 5, 7, 9, 12, 13, 6, 8, 10, 11, 3, 1];
const extra = ["console", "server_rack", "wall_clock", "standing_desk", "device_cart", "whiteboard", "long_table", "floor_lamp", "card_catalog", "globe", "workbench", "filament_rack", "finished_shelf", "sofa", "side_table", "mail_rack", "switchboard", "quad_monitor", "bull_statue", "safe", "softbox", "camera_tripod", "edit_bay", "drafting_table", "material_shelf", "easel", "file_cabinet", "law_shelf", "seal_desk", "receipt_tray", "cashier_counter", "ledger_shelf", "sprite_wall", "controller_shelf", "trophy_shelf", "parts_wall", "soldering_station", "test_rig", "ring_light", "product_table", "flight_board", "key_cabinet", "plan_chest", "model_plinth", "section_wall", "plant_low", "coffee_cart", "pendant_dome", "car_model", "esd_bench", "nonexistent_x"];
export function cases() {
  const out = [];
  for (let rnd = 0; rnd < 2; rnd++) themes.forEach((t, i) => {
    const j = i + rnd * 16;
    const props = [0, 1, 2].map(k => extra[(j * 3 + k) % extra.length]);
    out.push({ theme: rnd === 1 && i === 15 ? null : t, seats: seats[(i + rnd * 5) % 16], number: j + 2, active: j % 3 !== 0, project: `Proj${j}-${t}`, props });
  });
  return out;
}

const root = new THREE.Scene();
let y = 0;
const add = (n, name) => { n.name = name; n.position.set(0, y, 0); root.add(n); y += 4; };
const stats = [];
cases().forEach((c, i) => {
  const f = { kind: "project", id: "p:" + c.project.toLowerCase(), floorNo: String(c.number).padStart(2, "0"), project: c.project, number: c.number, active: c.active, seats: c.seats };
  const decor = c.theme ? { theme: c.theme, accentColor: "#000000", props: c.props } : null;
  const p = TowerModules.project(f, decor, () => {});
  stats.push({ i, items: p.items, front: p.front, deskItems: p.deskItems, boxes: p.boxes, ghost: p.ghostSpots.map(g => [R(g[0]), R(g[1])]) });
  add(p.node, `floor:case${i}`);
});
add(TowerModules.idle({ kind: "idle", id: "idle-0", floorNo: "" }).node, "floor:idle");
add(TowerModules.lobby(false).node, "floor:lobby0");
add(TowerModules.lobby(true).node, "floor:lobby1");
add(TowerModules.roof().node, "floor:roof");
add(TowerModules.glowFrame(), "glow");
for (let c = 0; c < 2; c++) { const d = TowerCore.landingDoor(c); TowerCore.setDoor(d, 0.4); add(d, `door${c}`); }
const fd = TowerCore.frontDoor(); TowerCore.setDoor(fd, 0.7, SlideDoor.front); add(fd, "fdoor");
add(TowerCore.car(), "car");
root.add(TowerCore.build(31.3, 28.9, [0, 4.4, 7.3, 8.2, 11.1, 28.9]).node);

const w = walkScene(root);
const dump = JSON.stringify({ source: "js", boxes: w.boxes, geoms: w.geoms, lights: [], materials: [...w.mats].sort(), cameras: [], stats });
window.__dump = dump;
document.getElementById("out").textContent = dump;
window.__ready = true;
