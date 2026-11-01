// SCNAction／SCNTransaction 的轉寫版（11-02 P8，builder agent 擁有這個檔）。
// SceneKit 的動畫有兩種：
//   1. SCNAction：node.runAction(action, forKey:, completionHandler:)。這裡寫成 runAction(node, action, key, done)，
//      也掛在 THREE.Object3D.prototype 上，所以 node.runAction(a, "key") 一樣可以用。動作名稱跟 SCNAction 同名：
//        Act.moveBy(x, y, z, dur)、Act.move([x, y, z], dur)（＝moveTo）、Act.rotateBy(x, y, z, dur)、Act.rotateTo(x, y, z, dur)、
//        Act.scale(to, dur)、Act.scaleBy(k, dur)、Act.fadeOpacity(to, dur)、Act.fadeIn(dur)、Act.fadeOut(dur)、Act.fadeOpacityBy(d, dur)、
//        Act.sequence([...])、Act.group([...])、Act.repeat(a, n)、Act.repeatForever(a)、Act.wait(dur, range)、
//        Act.customAction(dur, (node, elapsed) => {})、Act.run(node => {})、Act.removeFromParentNode()、Act.hide()、Act.unhide()。
//      action.timingMode = "easeInEaseOut"（也可 "linear"／"easeIn"／"easeOut"）；action.reversed() 跟 Swift 一樣。
//      removeAction(node, key)、removeAllActions(node)、actionForKey(node, key)、hasActions(node)。
//      node.userData.isPaused = true ＝ SCNNode.isPaused（自己跟子孫的動作都停；setPaused(node, b) 也可以）。
//   2. SCNTransaction 隱式動畫：JS 不能攔 `n.opacity = 0` 這種賦值，所以改成：
//        SCNTransaction.begin(); SCNTransaction.animationDuration = 0.25;
//        SCNTransaction.opacity(n, 0); SCNTransaction.position(n, [x, y, z]); SCNTransaction.euler(n, x, y, z); SCNTransaction.scale(n, s)
//        SCNTransaction.completionBlock = () => {...}; SCNTransaction.commit();
//      沒開 transaction（或 duration 0）時這些 setter 立刻生效。opacity 跟 SceneKit 一樣「model 值立刻變、畫面慢慢變」：
//      userData.opacity＝model（dump、程式判斷用），userData.presOpacity＝畫面上的值（syncOpacity 用）。
//
// 時鐘：每幀由畫面迴圈呼叫 Act.tick(dt 秒)。Act.paused = true ＝ SCNScene.isPaused（視窗看不到時停；動作、隱式動畫全停）。
// 只有掛在 THREE.Scene 底下的節點會跑動作（跟 SceneKit 一樣：不在場景裡的節點動作不推進）。
//
// 節點透明度：three 沒有節點 opacity。每幀畫之前呼叫 syncOpacity(scene)：把祖先的 opacity 連乘，<1 的 mesh 換成透明的複製材質
// （每幀從原材質 copy，所以日夜換色、發光照樣跟著原材質），回到 1 換回原材質。

import * as THREE from "three";

// MARK: - 時間曲線（CAMediaTimingFunction 的三次 Bézier）

function bezier(x1, y1, x2, y2) {
  const cx = 3 * x1, bx = 3 * (x2 - x1) - cx, ax = 1 - cx - bx;
  const cy = 3 * y1, by = 3 * (y2 - y1) - cy, ay = 1 - cy - by;
  const sx = t => ((ax * t + bx) * t + cx) * t, sy = t => ((ay * t + by) * t + cy) * t;
  const dx = t => (3 * ax * t + 2 * bx) * t + cx;
  return x => {
    if (x <= 0) return 0; if (x >= 1) return 1;
    let t = x;
    for (let i = 0; i < 8; i++) {
      const e = sx(t) - x; if (Math.abs(e) < 1e-6) return sy(t);
      const d = dx(t); if (Math.abs(d) < 1e-6) break;
      t -= e / d;
    }
    let lo = 0, hi = 1; t = x;
    for (let i = 0; i < 30; i++) { const v = sx(t); if (Math.abs(v - x) < 1e-6) break; if (v < x) lo = t; else hi = t; t = (lo + hi) / 2; }
    return sy(t);
  };
}
export const Timing = {
  linear: x => x,
  easeIn: bezier(0.42, 0, 1, 1),
  easeOut: bezier(0, 0, 0.58, 1),
  easeInEaseOut: bezier(0.42, 0, 0.58, 1),
  /** CAMediaTimingFunction(name: .default) */
  default: bezier(0.25, 0.1, 0.25, 1),
};
const curve = m => typeof m === "function" ? m : (Timing[m] ?? Timing.linear);

// MARK: - 動作（樣板；跑的時候 make() 出一個 runner）

class SAction {
  constructor(duration, make, rev) { this.duration = duration; this._make = make; this._rev = rev; this.timingMode = "linear"; this.timingFunction = null; }
  /** runner：update(node, el) 推到本動作的第 el 秒（el 已夾在 [0, duration]），回傳 false＝要停（節點被移除等） */
  make(node) {
    const r = this._make(node), d = this.duration, f = this.timingFunction ?? curve(this.timingMode);
    if (f === Timing.linear || d <= 0) return r;
    return { update: (n, el) => r.update(n, f(el / d) * d), dur: r.dur };
  }
  reversed() { const a = this._rev ? this._rev() : this; if (a !== this) a.timingMode = this.timingMode; return a; }
}

const get3 = (a, b, c) => Array.isArray(a) ? a : (a && typeof a === "object" && "x" in a) ? [a.x, a.y, a.z] : [a, b, c];

/** 依比例套 delta 的動作（moveBy／rotateBy／fadeOpacityBy／scaleBy）：跟 SceneKit 一樣可以疊 */
function deltaAction(d, apply, rev) {
  return new SAction(d, () => {
    let prev = 0;
    return { update(n, el) { const p = d > 0 ? Math.min(1, el / d) : 1; apply(n, p - prev); prev = p; return true; } };
  }, rev);
}
/** 從開始時的值插到目標（moveTo／rotateTo／fadeOpacity to／scale to） */
function toAction(d, read, write) {
  return new SAction(d, () => {
    let from = null;
    return { update(n, el) { if (from === null) from = read(n); write(n, from, d > 0 ? Math.min(1, el / d) : 1); return true; } };
  });
}
const instant = (f, rev) => new SAction(0, () => { let did = false; return { update(n) { if (!did) { did = true; return f(n) !== false; } return true; } }; }, rev);

export const Act = {
  /** SCNScene.isPaused */
  paused: false,
  /** 目前的動畫時間（秒，暫停時不走） */
  time: 0,

  moveBy(x, y, z, duration) {
    const v = get3(x, y, z); if (Array.isArray(x)) duration = y;
    return deltaAction(duration, (n, k) => { n.position.x += v[0] * k; n.position.y += v[1] * k; n.position.z += v[2] * k; },
      () => Act.moveBy(-v[0], -v[1], -v[2], duration));
  },
  /** SCNAction.move(to:duration:) */
  move(to, duration) {
    const v = get3(to);
    return toAction(duration, n => n.position.clone(), (n, f, p) => n.position.set(f.x + (v[0] - f.x) * p, f.y + (v[1] - f.y) * p, f.z + (v[2] - f.z) * p));
  },
  moveTo(to, duration) { return Act.move(to, duration); },
  rotateBy(x, y, z, duration) {
    return deltaAction(duration, (n, k) => { n.rotation.x += x * k; n.rotation.y += y * k; n.rotation.z += z * k; },
      () => Act.rotateBy(-x, -y, -z, duration));
  },
  /** SCNAction.rotateTo(x:y:z:duration:usesShortestUnitArc:) */
  rotateTo(x, y, z, duration, shortest = false) {
    const w = (a, b) => { if (!shortest) return b; let d = (b - a) % (2 * Math.PI); if (d > Math.PI) d -= 2 * Math.PI; if (d < -Math.PI) d += 2 * Math.PI; return a + d; };
    return toAction(duration, n => [n.rotation.x, n.rotation.y, n.rotation.z],
      (n, f, p) => { n.rotation.x = f[0] + (w(f[0], x) - f[0]) * p; n.rotation.y = f[1] + (w(f[1], y) - f[1]) * p; n.rotation.z = f[2] + (w(f[2], z) - f[2]) * p; });
  },
  /** SCNAction.scale(to:duration:)（等比） */
  scale(to, duration) {
    return toAction(duration, n => n.scale.clone(), (n, f, p) => n.scale.set(f.x + (to - f.x) * p, f.y + (to - f.y) * p, f.z + (to - f.z) * p));
  },
  /** SCNAction.scale(by:duration:) */
  scaleBy(k, duration) {
    return new SAction(duration, () => {
      let prev = 1;
      return { update(n, el) { const p = duration > 0 ? Math.min(1, el / duration) : 1, cur = 1 + (k - 1) * p; n.scale.multiplyScalar(cur / prev); prev = cur; return true; } };
    }, () => Act.scaleBy(1 / k, duration));
  },
  fadeOpacity(to, duration) { return toAction(duration, n => opacityOf(n), (n, f, p) => setNodeOpacity(n, f + (to - f) * p)); },
  fadeOpacityBy(d, duration) { return deltaAction(duration, (n, k) => setNodeOpacity(n, opacityOf(n) + d * k), () => Act.fadeOpacityBy(-d, duration)); },
  fadeIn(duration) { return Act.fadeOpacity(1, duration); },
  fadeOut(duration) { return Act.fadeOpacity(0, duration); },
  hide() { return instant(n => { n.visible = false; }, () => Act.unhide()); },
  unhide() { return instant(n => { n.visible = true; }, () => Act.hide()); },
  removeFromParentNode() { return instant(n => { n.parent?.remove(n); return false; }); },
  /** SCNAction.run { node in } */
  run(f) { return instant(n => { f(n); }); },
  /** SCNAction.wait(duration:withRange:)：range 是總寬度（d ± range/2） */
  wait(duration, range = 0) {
    if (!range) return new SAction(duration, () => ({ update() { return true; } }));
    const a = new SAction(duration, () => ({ update() { return true; } }));
    a._random = range;
    return a;
  },
  /** SCNAction.customAction(duration:action:)：f(node, elapsed 秒) */
  customAction(duration, f) {
    return new SAction(duration, () => ({ update(n, el) { f(n, el); return true; } }));
  },
  sequence(list) {
    const acts = list.filter(Boolean), dur = acts.reduce((s, a) => s + a.duration, 0);
    return new SAction(dur, () => seqRunner(acts), () => Act.sequence(acts.slice().reverse().map(a => a.reversed())));
  },
  group(list) {
    const acts = list.filter(Boolean), dur = acts.reduce((s, a) => Math.max(s, a.duration), 0);
    return new SAction(dur, () => {
      const rs = acts.map(a => ({ a, r: a.make(), done: false }));
      return { update(n, el) {
        for (const x of rs) {
          if (x.done) continue;
          if (x.r.update(n, Math.min(el, x.a.duration)) === false) return false;
          if (el >= x.a.duration) x.done = true;
        }
        return true;
      } };
    }, () => Act.group(acts.map(a => a.reversed())));
  },
  repeat(a, count) {
    const d = a.duration;
    return new SAction(d * count, () => {
      let i = 0, r = a.make();
      return { update(n, el) {
        const k = d > 0 ? Math.min(count, Math.floor(el / d)) : count;
        while (i < k) { if (r.update(n, d) === false) return false; i++; if (i < count) r = a.make(); }
        if (i < count && d > 0) return r.update(n, el - i * d);
        return true;
      } };
    }, () => Act.repeat(a.reversed(), count));
  },
  repeatForever(a) {
    const d = a.duration, act = new SAction(Infinity, () => {
      let i = 0, r = a.make();
      return { update(n, el) {
        if (d <= 0) { if (r.update(n, 0) === false) return false; r = a.make(); return true; }   // 0 秒的動作：每幀跑一次
        const k = Math.floor(el / d);
        let guard = 0;
        while (i < k && guard++ < 1000) { if (r.update(n, d) === false) return false; i++; r = a.make(); }
        if (guard >= 1000) i = k;
        return r.update(n, el - i * d);
      } };
    }, () => Act.repeatForever(a.reversed()));
    act._forever = true;
    return act;
  },

  /** 每幀推進（dt 秒）。Act.paused 時不動 */
  tick(dt) {
    if (Act.paused || !(dt > 0)) return;
    Act.time += dt;
    for (const n of [...running]) stepNode(n, dt);
    stepImplicit(dt);
  },
};

/** wait(withRange:) 的實際長度在開跑時抽 */
function actualDuration(a) { return a._random ? Math.max(0, a.duration + (Math.random() - 0.5) * a._random) : a.duration; }

function seqRunner(acts) {
  let i = 0, start = 0, r = null, d = 0;
  return { update(n, el) {
    while (i < acts.length) {
      if (!r) { r = acts[i].make(n); d = actualDuration(acts[i]); }
      const local = el - start;
      if (local < d) return r.update(n, local) !== false;
      if (r.update(n, d) === false) return false;
      start += d; i++; r = null;
    }
    return true;
  } };
}

// MARK: - 節點上的動作

const running = new Set();
let serial = 0;

function table(n) { return n.userData._acts ??= new Map(); }

/** SCNNode.runAction(_:forKey:completionHandler:) */
export function runAction(node, action, key = null, done = null) {
  if (!node || !action) return;
  const t = table(node), k = key ?? `\u0000${serial++}`;
  t.delete(k);                                // 同 key 的舊動作直接換掉（不跑它的 completion，跟 SceneKit 一樣）
  t.set(k, { action, r: action.make(node), el: 0, dur: action._forever ? Infinity : actualDuration(action), done });
  running.add(node);
}
export function removeAction(node, key) { const t = node?.userData._acts; if (t) { t.delete(key); if (!t.size) running.delete(node); } }
export function removeAllActions(node) { const t = node?.userData._acts; if (t) { t.clear(); running.delete(node); } }
export function actionForKey(node, key) { return node?.userData._acts?.get(key)?.action ?? null; }
export function hasActions(node) { return (node?.userData._acts?.size ?? 0) > 0; }
export function setPaused(node, p) { node.userData.isPaused = !!p; }
export function isPaused(node) { return !!node.userData.isPaused; }

/** 節點有沒有在場景裡、有沒有被（自己或祖先的）isPaused 停掉 */
function live(n) {
  let p = n;
  while (p) { if (p.userData?.isPaused) return false; if (p.isScene) return true; p = p.parent; }
  return false;
}

function stepNode(n, dt) {
  const t = n.userData._acts;
  if (!t || !t.size) { running.delete(n); return; }
  if (!live(n)) return;
  for (const [k, e] of [...t]) {
    if (t.get(k) !== e) continue;
    e.el += dt;
    const el = Math.min(e.el, e.dur);
    const ok = e.r.update(n, e.action._forever ? e.el : el);
    if (t.get(k) !== e) continue;              // 動作自己把自己換掉了（customAction 裡又 runAction 同 key）
    if (ok === false) { t.delete(k); continue; }
    if (e.el >= e.dur) { t.delete(k); e.done?.(); }
  }
  if (!t.size) running.delete(n);
}

// 也掛到 Object3D 上：node.runAction(a, key, done) 等同 SceneKit 的寫法
for (const [name, f] of Object.entries({
  runAction(a, key, done) { runAction(this, a, key, done); },
  removeAction(key) { removeAction(this, key); },
  removeAllActions() { removeAllActions(this); },
  actionForKey(key) { return actionForKey(this, key); },
})) if (!(name in THREE.Object3D.prototype)) Object.defineProperty(THREE.Object3D.prototype, name, { value: f, writable: true, configurable: true });
if (!("hasActions" in THREE.Object3D.prototype)) Object.defineProperty(THREE.Object3D.prototype, "hasActions", { get() { return hasActions(this); }, configurable: true });

// MARK: - 節點透明度

export function opacityOf(n) { return n.userData.opacity ?? 1; }
/** 直接設（動作用）：model 跟畫面一起變 */
export function setNodeOpacity(n, o) { n.userData.opacity = o; delete n.userData.presOpacity; }

const OPAQUE = 0.999;
/** 每幀畫之前：祖先 opacity 連乘，<1 的 mesh 換成透明複製材質 */
export function syncOpacity(root) {
  const walk = (n, o) => {
    const eff = o * (n.userData.presOpacity ?? n.userData.opacity ?? 1);
    if (n.material) applyMat(n, eff);
    for (const c of n.children) walk(c, eff);
  };
  walk(root, 1);
}
function applyMat(n, eff) {
  const u = n.userData;
  if (eff >= OPAQUE) {
    if (u._baseMat) { n.material = u._baseMat; u._baseMat = null; u._fadeMat = null; }
    return;
  }
  if (!u._baseMat) {
    u._baseMat = n.material;
    u._fadeMat = Array.isArray(n.material) ? n.material.map(m => m.clone()) : n.material.clone();
    n.material = u._fadeMat;
  }
  const base = Array.isArray(u._baseMat) ? u._baseMat : [u._baseMat], fade = Array.isArray(u._fadeMat) ? u._fadeMat : [u._fadeMat];
  base.forEach((b, i) => {
    const f = fade[i], wasT = f.transparent;
    f.copy(b);
    f.transparent = true;
    f.opacity = (b.transparent ? b.opacity : 1) * Math.max(0, eff);
    f.visible = b.visible && eff > 0.001;
    if (!wasT) f.needsUpdate = true;
  });
}

// MARK: - SCNTransaction（隱式動畫）

const implicit = new Map();        // key: node.uuid + prop → { node, prop, from, to, t, d, f, group }
let open = null;                   // 目前開著的 transaction（可巢狀：stack）
const stack = [];

class TxGroup {
  constructor(d, f, done) { this.d = d; this.f = f; this.done = done; this.left = 0; }
  finish() { if (--this.left === 0) this.done?.(); }
}

const props = {
  opacity: {
    read: n => n.userData.presOpacity ?? opacityOf(n),
    model: (n, v) => { n.userData.opacity = v; },
    pres: (n, v) => { n.userData.presOpacity = v; },
    end: n => { delete n.userData.presOpacity; },
    lerp: (a, b, p) => a + (b - a) * p,
  },
  position: {
    read: n => [n.position.x, n.position.y, n.position.z],
    model: () => {}, pres: (n, v) => n.position.set(v[0], v[1], v[2]), end: () => {},
    lerp: (a, b, p) => [a[0] + (b[0] - a[0]) * p, a[1] + (b[1] - a[1]) * p, a[2] + (b[2] - a[2]) * p],
  },
  euler: {
    read: n => [n.rotation.x, n.rotation.y, n.rotation.z],
    model: () => {}, pres: (n, v) => { n.rotation.x = v[0]; n.rotation.y = v[1]; n.rotation.z = v[2]; }, end: () => {},
    lerp: (a, b, p) => [a[0] + (b[0] - a[0]) * p, a[1] + (b[1] - a[1]) * p, a[2] + (b[2] - a[2]) * p],
  },
  scale: {
    read: n => [n.scale.x, n.scale.y, n.scale.z],
    model: () => {}, pres: (n, v) => n.scale.set(v[0], v[1], v[2]), end: () => {},
    lerp: (a, b, p) => [a[0] + (b[0] - a[0]) * p, a[1] + (b[1] - a[1]) * p, a[2] + (b[2] - a[2]) * p],
  },
  /** 任意數值（例：燈的 intensity）：SCNTransaction.value(obj, "intensity", v) */
};

function txSet(n, prop, to, spec) {
  const key = n.uuid + "|" + prop;
  if (open) { open.changes.push({ n, prop, to, key, spec, from: spec.read(n) }); spec.model(n, to); return; }
  const old = implicit.get(key); if (old) { implicit.delete(key); old.group.finish(); }
  spec.model(n, to); spec.pres(n, to); spec.end(n);
}

export const SCNTransaction = {
  animationDuration: 0,
  animationTimingFunction: null,
  completionBlock: null,
  begin() {
    if (open) stack.push(open);
    open = { duration: 0, changes: [] };
    SCNTransaction.animationDuration = 0; SCNTransaction.animationTimingFunction = null; SCNTransaction.completionBlock = null;
  },
  commit() {
    if (!open) return;
    const tx = open;
    tx.duration = SCNTransaction.animationDuration;
    const f = curve(SCNTransaction.animationTimingFunction ?? "linear"), done = SCNTransaction.completionBlock;
    open = stack.pop() ?? null;
    SCNTransaction.completionBlock = null;
    if (!(tx.duration > 0) || !tx.changes.length) {
      for (const c of tx.changes) { c.spec.pres(c.n, c.to); c.spec.end(c.n); }
      done?.();
      return;
    }
    const g = new TxGroup(tx.duration, f, done);
    for (const c of tx.changes) {
      const old = implicit.get(c.key);
      const from = old ? c.spec.read(c.n) : c.from;
      if (old) { implicit.delete(c.key); old.group.finish(); }
      g.left++;
      implicit.set(c.key, { ...c, from, t: 0, group: g });
    }
  },
  // setter（隱式動畫的屬性）：開著 transaction 就排動畫，不然立刻設
  opacity(n, v) { txSet(n, "opacity", v, props.opacity); },
  position(n, v) { txSet(n, "position", get3(v), props.position); },
  euler(n, x, y, z) { txSet(n, "euler", get3(x, y, z), props.euler); },
  scale(n, s) { txSet(n, "scale", typeof s === "number" ? [s, s, s] : get3(s), props.scale); },
  /** 物件的任一數值屬性（燈的 intensity、材質的 opacity…） */
  value(obj, field, v) {
    if (!obj.uuid) obj.uuid = THREE.MathUtils.generateUUID();
    txSet(obj, field, v, { read: o => o[field], model: () => {}, pres: (o, x) => { o[field] = x; }, end: () => {}, lerp: (a, b, p) => a + (b - a) * p });
  },
};

function stepImplicit(dt) {
  for (const [k, a] of [...implicit]) {
    a.t += dt;
    const p = Math.min(1, a.t / a.group.d);
    a.spec.pres(a.n, a.spec.lerp(a.from, a.to, a.group.f(p)));
    if (p >= 1) { implicit.delete(k); a.spec.end(a.n); a.group.finish(); }
  }
}

/** 測試用：所有隱式動畫直接跳到終點（BoardWindow.testMode 的 duration 0 同效果） */
export function finishImplicit() { stepImplicit(1e9); }
