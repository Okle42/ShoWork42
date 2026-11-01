// 地基量尺的小測試場景：Mac SceneDump.kitScene()（--office-bench kit）的 JS 版，一行一行照抄。
// 三件家具的 PropDef（server_rack、console1、plant_tall）是從 OfficeTower.swift TowerProps.all 抄的（之後 tower 轉寫完可改成直接引用）。

import * as THREE from "three";
import { VoxelMesh, Kit, Xf, TM, TP, VoxMat, UV, PixelText, scnLight, setCategory } from "../kit.js";
import { OfficeBuilder } from "../scene/builder.js";

const props = {
  server_rack: (k, x) => {
    k.b(x, 0, 0, 0, 0.6, 2.0, 0.8, TM.f(TP.FN3));
    for (let i = 0; i < 6; i++) k.b(x, -0.2, 0.3 + i * 0.28, 0.41, 0.04, 0.04, 0.02, TM.glow(0x6FD08C, 0.6, 1.5));
  },
  console1: (k, x) => {
    k.b(x, 0, 0, 0, 1.2, 0.8, 0.7, TM.f(TP.FN3)); k.b(x, 0, 0.8, 0, 1.2, 0.04, 0.72, TM.f(TP.FN5));
    for (const sx of [-0.3, 0.3]) k.b(x, sx, 0.84, -0.2, 0.5, 0.3, 0.04, TM.f(TP.FN6));
  },
  plant_tall: (k, x) => {
    k.b(x, 0, 0, 0, 0.5, 0.5, 0.5, TM.f(TP.POT)); k.b(x, 0, 0.5, 0, 0.08, 0.6, 0.08, TM.f(TP.FN1));
    k.b(x, 0, 1.0, 0, 0.9, 0.7, 0.9, TM.f(TP.PL1)); k.b(x, 0.1, 1.7, -0.05, 0.6, 0.45, 0.6, TM.f(TP.PL2));
  },
};

export function kitScene() {
  const root = new THREE.Group(); root.name = "kit-test";
  const m = new VoxelMesh(), k = new Kit(m);
  const white = TM.f(0xFFFFFF);
  k.b(Xf.identity, 0, 0, 3, 1, 1, 1, white);
  props.server_rack(k, new Xf(-3, 0, 0, 0));
  props.console1(k, new Xf(-1, 0, 0.5, 0.4));
  props.plant_tall(k, Xf.identity.at(1.5, 0, 0, -Math.PI / 2).at(0.3, 0, 0.2));
  m.box(new Xf(3.5, 0, 1, 0.3), [0, 0.5, 0], [1, 1, 1], VoxMat.tex("dirtside"), { top: VoxMat.tex("grass"), bottom: VoxMat.tex("dirt"), uv: UV.sideFit(1) });
  m.box(Xf.identity, [5, 0.25, 1], [1.2, 0.5, 1.2], VoxMat.tex("wool", { tint: VoxMat.color(0xC85A5A) }), { uv: UV.fit });
  m.box(Xf.identity, [-5, 0.5, 2], [2, 1, 1], VoxMat.tex("plank"), { uv: UV.tile(1) });
  k.b(Xf.identity, 5, 0, -1.5, 1, 0.6, 1, VoxMat.dayNight(0x8E8B85, TP.ST2));
  k.b(Xf.identity, 6.5, 0, -1.5, 1, 0.6, 1, VoxMat.dayNight(TP.groundDay, TP.groundNight, { glow: TP.LT1, emit: [0, 0.6] }));
  k.b(Xf.identity, -1, 0, 3, 1.5, 1.5, 0.1, TM.glass(0.15));
  k.b(Xf.identity, 7.5, 0, 0.5, 0.6, 0.6, 0.6, TM.glow(0x6FD08C, 0.6, 1.5));
  root.add(m.node("kit-props"));
  const mo = new VoxelMesh(), ko = new Kit(mo);
  ko.b(Xf.identity, 2, 0, 3, 1, 1, 1, white);
  const out = mo.node("kit-outdoor"); setCategory(out, OfficeBuilder.outdoorMask);
  root.add(out);
  const ma = new VoxelMesh({ ao: 0 }), ka = new Kit(ma);
  ka.b(Xf.identity, -2.5, 0, 3, 1, 3, 1, white);
  const ao = ma.node("kit-ao"); setCategory(ao, OfficeBuilder.outdoorMask);
  root.add(ao);
  const sign = PixelText.sign("ABC 測試", { bg: VoxMat.color(TP.INK) });
  sign.name = "kit-sign"; sign.position.set(0, 2.6, 2);
  root.add(sign);
  // omni 衰減量尺
  const mr = new VoxelMesh(), kr = new Kit(mr), mn = new VoxelMesh(), kn = new Kit(mn);
  for (let i = 0; i < 6; i++) {
    kr.b(Xf.identity, 10 + i * 1.5, 0, -4, 1, 0.4, 1, white);
    kn.b(Xf.identity, 10 + i * 1.5, 0, -6, 1, 0.4, 1, white);
  }
  const rowLit = mr.node("kit-omni-row"); setCategory(rowLit, 64);
  const rowRef = mn.node("kit-omni-ref"); setCategory(rowRef, OfficeBuilder.outdoorMask);
  root.add(rowLit); root.add(rowRef);
  const o = scnLight({ type: "omni", intensity: 1000, color: 0xFFFFFF, start: 1, end: 9, falloff: 2, mask: 64 });
  o.name = "kit-omni"; o.position.set(10, 3, -4);
  root.add(o);
  return root;
}

export const kitProbes = [
  ["white-in-top", [0, 1.0, 3]], ["white-in-front", [0, 0.5, 3.5]], ["white-in-right", [0.5, 0.5, 3]],
  ["white-out-top", [2, 1.0, 3]], ["white-out-front", [2, 0.5, 3.5]], ["white-out-right", [2.5, 0.5, 3]],
  ["ao-front-low", [-2.5, 0.3, 3.5]], ["ao-front-mid", [-2.5, 1.25, 3.5]], ["ao-front-high", [-2.5, 2.7, 3.5]],
  ["glow-front", [7.5, 0.3, 0.8]], ["ground", [1, 0, 5.5]], ["sky", [0, 40, -150]],
  ...Array.from({ length: 6 }, (_, i) => [[`omni-lit-${i}`, [10 + i * 1.5, 0.4, -4]], [`omni-ref-${i}`, [10 + i * 1.5, 0.4, -6]]]).flat(),
];
