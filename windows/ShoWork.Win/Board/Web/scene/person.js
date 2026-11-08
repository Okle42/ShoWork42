// 佔位人物（11-08 H5 第三版）：程式畫的低多邊形人，有臉、髮型、不同衣服（照卡片 id 固定），程式動畫：待機、坐、走。
// 自製的 person_base.glb（assets/models/，帶 idle／walk／sit 動畫）載好之後由 openoffice.js 改用模型，這裡只是退路。
// 單位公尺：站著約 1.72 高；原點＝兩腳中間的地面（坐姿時原點仍在地面，臀部在椅面高 seatY）。面向 +Z。

import * as THREE from "three";
import { mat } from "./props.js";

const SKIN = [0xF2D0B1, 0xE3B48F, 0xC68B63, 0x9A6440, 0x6E4529];
const HAIR = [0x2A1E17, 0x4A2E1E, 0x8C5A2B, 0xC9A06A, 0x1C1C1F, 0x7A2E22, 0xB8B8B8];
const SHIRT = [0x3E6FB0, 0xD9534F, 0x5CB85C, 0xF0AD4E, 0x8E6CC9, 0x2E3A4A, 0xEDEDED, 0x1F8A8A, 0xC2185B, 0x6D4C41];
const PANTS = [0x2C3440, 0x3B3B3B, 0x51606F, 0x6B5444, 0x1F2A44];

function hash(s) { let h = 2166136261; for (const c of String(s)) h = Math.imul(h ^ c.charCodeAt(0), 16777619) >>> 0; return h; }
const box = (w, h, d, m, y = 0, x = 0, z = 0) => { const g = new THREE.BoxGeometry(w, h, d); g.translate(x, y, z); const n = new THREE.Mesh(g, m); n.castShadow = true; return n; };

/** 一個人：回傳 { node, setPose("stand"|"sit"|"walk"), update(t) , headTop } */
export function makeHuman(id, { seatY = 0.48 } = {}) {
  const h = hash(id);
  const pick = (a, k) => a[(h >>> k) % a.length];
  const skin = mat(pick(SKIN, 3)), hair = mat(pick(HAIR, 7), { rough: 0.9 }), shirt = mat(pick(SHIRT, 11), { rough: 0.9 }), pants = mat(pick(PANTS, 15), { rough: 0.95 });
  const shoe = mat(0x1E1E22), white = mat(0xFFFFFF, { rough: 0.4 }), dark = mat(0x16181C, { rough: 0.4 });
  const style = (h >>> 19) % 4;       // 0 短髮、1 長髮、2 包頭、3 鴨舌帽
  const glasses = ((h >>> 23) & 7) === 0;

  const node = new THREE.Group(); node.name = "human";
  const hips = new THREE.Group(); hips.position.y = 0.9; node.add(hips);
  // 腿：大腿（髖關節）→ 小腿（膝蓋）
  const legs = [-0.1, 0.1].map(x => {
    const thigh = new THREE.Group(); thigh.position.set(x, 0, 0); hips.add(thigh);
    thigh.add(box(0.15, 0.44, 0.17, pants, -0.22));
    const knee = new THREE.Group(); knee.position.y = -0.44; thigh.add(knee);
    knee.add(box(0.14, 0.42, 0.15, pants, -0.21));
    knee.add(box(0.15, 0.07, 0.26, shoe, -0.43, 0, 0.05));
    return { thigh, knee };
  });
  // 身體
  const torso = new THREE.Group(); hips.add(torso);
  torso.add(box(0.42, 0.56, 0.24, shirt, 0.3));
  torso.add(box(0.44, 0.08, 0.26, pants, 0.02));                    // 腰帶
  const arms = [-0.27, 0.27].map(x => {
    const sh = new THREE.Group(); sh.position.set(x, 0.54, 0); torso.add(sh);
    sh.add(box(0.12, 0.34, 0.13, shirt, -0.17));
    const el = new THREE.Group(); el.position.y = -0.34; sh.add(el);
    el.add(box(0.1, 0.28, 0.11, skin, -0.14));
    el.add(box(0.11, 0.09, 0.12, skin, -0.32));
    return { sh, el };
  });
  // 頭：脖子、臉（眼睛、眉毛、嘴）、頭髮
  const head = new THREE.Group(); head.position.y = 0.6; torso.add(head);
  head.add(box(0.11, 0.08, 0.11, skin, 0.03));
  head.add(box(0.27, 0.29, 0.26, skin, 0.21));
  for (const x of [-0.065, 0.065]) {
    head.add(box(0.045, 0.05, 0.01, white, 0.23, x, 0.131));
    head.add(box(0.025, 0.035, 0.012, dark, 0.226, x, 0.137));
    head.add(box(0.06, 0.012, 0.01, hair, 0.275, x, 0.132));
  }
  head.add(box(0.08, 0.015, 0.01, mat(0x9C4A3A), 0.135, 0, 0.131));
  if (glasses) for (const x of [-0.065, 0.065]) head.add(box(0.075, 0.06, 0.008, mat(0x222222, { opacity: 0.55 }), 0.23, x, 0.142));
  head.add(box(0.29, 0.08, 0.28, hair, 0.37));                    // 頭頂
  if (style === 0) head.add(box(0.29, 0.12, 0.08, hair, 0.29, 0, -0.1));
  if (style === 1) { head.add(box(0.3, 0.3, 0.1, hair, 0.22, 0, -0.12)); head.add(box(0.05, 0.22, 0.24, hair, 0.24, -0.15, -0.01)); head.add(box(0.05, 0.22, 0.24, hair, 0.24, 0.15, -0.01)); }
  if (style === 2) head.add(box(0.14, 0.12, 0.14, hair, 0.46, 0, -0.06));
  if (style === 3) { head.add(box(0.31, 0.08, 0.3, mat(pick(SHIRT, 27)), 0.4)); head.add(box(0.26, 0.025, 0.16, mat(pick(SHIRT, 27)), 0.37, 0, 0.2)); }
  const headTopStand = 0.9 + 0.6 + 0.42;

  let pose = "stand", phase = (h % 1000) / 1000 * Math.PI * 2;
  function setPose(p) {
    pose = p;
    for (const l of legs) { l.thigh.rotation.x = 0; l.knee.rotation.x = 0; }
    for (const a of arms) { a.sh.rotation.set(0, 0, 0); a.el.rotation.x = 0; }
    hips.position.y = 0.9; torso.rotation.x = 0;
    if (p === "sit") {
      hips.position.y = seatY + 0.04;
      for (const l of legs) { l.thigh.rotation.x = -Math.PI / 2; l.knee.rotation.x = Math.PI / 2; }
      for (const a of arms) { a.sh.rotation.x = -0.75; a.el.rotation.x = -0.55; }    // 手放在桌上（打字）
    }
  }
  /** 每幀：t＝秒 */
  function update(t, dt) {
    const s = t * 1.0 + phase;
    if (pose === "stand") {
      hips.position.y = 0.9 + Math.sin(s * 1.6) * 0.006;
      torso.rotation.x = Math.sin(s * 1.6) * 0.01;
      arms[0].sh.rotation.z = -0.05 + Math.sin(s * 0.8) * 0.03; arms[1].sh.rotation.z = 0.05 - Math.sin(s * 0.8) * 0.03;
      head.rotation.y = Math.sin(s * 0.35) * 0.25;
    } else if (pose === "walk") {
      const w = Math.sin(t * 7.5);
      legs[0].thigh.rotation.x = w * 0.5; legs[1].thigh.rotation.x = -w * 0.5;
      legs[0].knee.rotation.x = Math.max(0, -w) * 0.6; legs[1].knee.rotation.x = Math.max(0, w) * 0.6;
      arms[0].sh.rotation.x = -w * 0.45; arms[1].sh.rotation.x = w * 0.45;
      hips.position.y = 0.9 + Math.abs(Math.cos(t * 7.5)) * 0.03;
    } else if (pose === "sit") {
      arms[0].el.rotation.x = -0.55 + Math.sin(t * 9 + phase) * 0.06;    // 打字
      arms[1].el.rotation.x = -0.55 + Math.sin(t * 9 + phase + 1.7) * 0.06;
      head.rotation.y = Math.sin(s * 0.3) * 0.12;
    }
  }
  setPose("stand");
  return { node, setPose, update, headTop: p => (p === "sit" ? seatY + 0.04 + 0.6 + 0.42 + 0.02 : headTopStand) };
}
