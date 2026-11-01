// OfficeTower.swift 的掛點（11-01 P0 地基）：TowerModules（樓層模組）、TowerCore（電梯井、溜滑梯、結構柱、大地面、天空）。
// 這個檔現在只有骨架：environment()（大地面）、天空盒、ModuleParts／Facade 的形狀、normals 是照抄好的；
// 樓層模組（project／idle／lobby／roof）、TowerCore.build／car／landingDoor／frontDoor 由轉寫 OfficeTower.swift 的 agent 填進來，
// 回傳的形狀不要改（OfficeBuilder 靠它）。家具的 PropDef 也放這裡（TowerProps）。

import * as THREE from "three";
import { VoxelMesh, Kit, Xf, VoxMat, TP, TD, skyCube, scnNode } from "../kit.js";

/** 一面會被 cutaway 的牆：node、外法線 n（[x, z]）、glass（玻璃不藏）、cut（內積門檻） */
export function facade(node, n, glass = false, cut = 0.25) { return { node, n, glass, cut }; }

/** 模組建好的結果（Swift 的 ModuleParts） */
export function moduleParts() {
  return {
    node: scnNode(), facades: [], plate: null, plateW: 0, plateY: 0, plateWalls: new Set([0, 1, 2, 3]), outsidePlate: false,
    boxes: 0, items: 0, front: 0, deskItems: 0, ghostSpots: [],
  };
}

export const TowerModules = {
  /** 牆的外法線（[x, z]）：0 後、1 前、2 左、3 右 */
  normals: [[0, -1], [0, 1], [-1, 0], [1, 0]],
  // TODO(轉寫 OfficeTower.swift)：以下四個照 Swift 填。現在回傳空模組（樓層位置、燈、取景照常算）
  project(f, decor, log) { return moduleParts(); },
  idle(f) { return moduleParts(); },
  lobby(sign = false) { return moduleParts(); },
  roof() { return moduleParts(); },
};

export const TowerCore = {
  /** 地面（城外的地；日夜共用一個節點，底色跟著 VoxMat.setNight 換）：1600×1600 */
  environment() {
    const m = new VoxelMesh(), k = new Kit(m);
    k.b(Xf.identity, 0, -0.4, 0, 1600, 0.4, 1600, VoxMat.dayNight(TP.groundDay, TP.groundNight));
    return m.node("env");
  },
  _skyDay: null, _skyNight: null,
  get skyDay() { return this._skyDay ??= skyCube(TP.skyDay, TP.zenithDay); },
  get skyNight() { return this._skyNight ??= skyCube(TP.skyNight, TP.zenithNight); },
  // TODO(轉寫 OfficeTower.swift TowerCore)：電梯井、溜滑梯、結構柱、看板立柱。回傳 { node（name "core"）, facades }
  build(top, roofFloor, floorYs = []) { return { node: scnNode("core"), facades: [] }; },
  /** 電梯車廂（name "car"）；還沒轉寫 ⇒ null（OfficeBuilder 會跳過） */
  car() { return null; },
  landingDoor(c) { return null; },
  frontDoor() { return null; },
  setDoor(door, open, g) {},
};
