// OfficeView.swift 的 OfficeScene（NSViewRepresentable）＋OfficeSCNView 照搬（11-02 P8）：渲染迴圈、鏡頭操作、點擊／懸停、螢幕空間標籤的資料。
//
// 按需渲染（10-20 Kang：全員閒置時 12 fps 一直畫，CPU 還是 3–20%）：
//   場景裡有持續動畫（「改檔」打字、保全掃描中、下雨、B1 圖譜自轉）才持續畫；其餘時候停住，資料變了／滑鼠動了才補畫一張。
//   會跑一下就停的（跳三下、鏡頭飛過去、慣性轉動、搬家、閒晃）用 playFor 播到時間到就停，到點只排一次 setTimeout，不輪詢。
//   幀率：搬家 24（只有那 2 秒）、有人在走 10、其餘 12（looping 時用基準 12）。
//   視窗看不到（document.visibilityState＋C# 的 {type:"visible"}）⇒ 整個場景暫停（不推進動作、不畫）。
//   機器熱（C# 的 {type:"heat", paused:true}）⇒ 持續動畫全停，只剩「操作或資料變了」那一下。
//   每一幀：b.tick(dt) → b.presentBegin() → 畫（風格後製或 ScnPost）→ b.presentEnd() → 標籤投影。
//
// 鏡頭（SceneKit defaultCameraController，interactionMode .orbitTurntable、inertiaEnabled、maximumVerticalAngle 55）：
//   左鍵拖曳＝繞轉軸轉（水平繞世界 Y、垂直改仰角，夾在 ±55°），放開有慣性；滾輪＝沿鏡頭→轉軸拉近拉遠（Mac 自己寫的 scrollWheel）；
//   中鍵拖曳＝平移（Mac 自己寫的 pan）；右鍵拖曳＝平移（SceneKit 預設；右鍵不拖＝選單）；觸控板捏合（ctrl＋滾輪）＝縮放；
//   WASD／方向鍵走動、Q／E 升降（Mac keyDown）。停下來後再算一次 LOD／cutaway（camMoved → updateLOD）。
//   SceneKit 自由鏡頭的坑（真滑鼠拖曳後 pointOfView 換成 kSCNFreeViewCameraName，掛在原鏡頭的雨留在原地）：
//   這裡只有一台鏡頭（builder.camera），拖曳直接改它，不會換鏡頭 ⇒ 雨永遠跟著；Swift 的 followRain／pov 對齊在這裡不需要。
// 轉動的靈敏度（SceneKit 沒公開）：每點 0.5°（拖過 360 點＝半圈）、慣性約 1 秒滑完；這兩個是照手感推定的，沒有 Mac 量尺。

import * as THREE from "three";
import { ScnPost, category } from "../kit.js";
import { OfficeBuilder } from "../scene/builder.js";
import { OpenOfficeBuilder } from "../scene/openoffice.js";
import { SCNTransaction } from "../scene/actions.js";
import { OfficeStyleFX } from "../scene/stylefx.js";
import { OfficeLabels } from "./labels.js";

const toArr = p => !p ? null : Array.isArray(p) ? p.slice() : [p.x, p.y, p.z];
const sub = (a, b) => [a[0] - b[0], a[1] - b[1], a[2] - b[2]];
const add = (a, b) => [a[0] + b[0], a[1] + b[1], a[2] + b[2]];
const len = a => Math.hypot(a[0], a[1], a[2]);
const nowS = () => performance.now() / 1000;

/** 一台 3D 視圖（Swift 的 OfficeSCNView）。host＝放 canvas 的容器；labelsHost＝標籤層 */
export class OfficeSCNView {
  static walkFps = 10; static moveFps = 24;
  static hoverThrottle = 0.05;

  constructor(host, labelsHost, { baseFps = 12, testMode = false, memory } = {}) {
    this.host = host;
    this.baseFps = baseFps;
    this.testMode = testMode;
    this.memory = memory;              // OfficeMemory（關窗重開要回到原樣的東西）
    this.renderer = new THREE.WebGLRenderer({ antialias: true, preserveDrawingBuffer: testMode });
    this.renderer.setPixelRatio(Math.min(2, window.devicePixelRatio || 1));
    this.renderer.outputColorSpace = THREE.SRGBColorSpace;
    this.renderer.toneMapping = THREE.NoToneMapping;
    this.canvas = this.renderer.domElement;
    this.canvas.tabIndex = 0;            // acceptsFirstResponder：WASD 要收得到
    host.appendChild(this.canvas);
    this.post = new ScnPost(this.renderer);
    this.builder = new OpenOfficeBuilder({ aspect: 1.6 });        // 11-08 H5：單層開放式辦公室（大樓剖面 OfficeBuilder 留作基底）
    this.builder.onAssets = () => this.playFor(0.3);
    this.builder.onLayout = () => this.renderTabs();
    this.mode = "overview";            // 總覽（繞著轉）／walk（走進去：第一人稱，拖曳＝轉頭、WASD＝走）
    this.installTabs();
    this.patchOrtho(this.builder.camera);
    this.builder.onOrtho = d => this.setOrthoScale(OfficeStyleFX.orthoScale(d));
    this.labels = new OfficeLabels(labelsHost);
    this.style = "voxel";
    this.technique = null;
    this.bounds = { width: 10, height: 10 };
    // 狀態（Swift 的屬性）
    this.framed = false; this.userMoved = false;
    this.lastReset = 0; this.lastCam = 0; this.lastCard = null;
    this.playUntil = 0; this.checkPending = null;
    this.lodDue = 0; this.lodPending = null;
    this.downAt = null; this.hoverId = null; this.prevWaiting = null;
    this.lastHoverPick = 0; this.hoverTrailing = null; this.hoverTrailingPending = false;
    this.labelSig = ""; this.lastGuard = null;
    this.hostVisible = true; this.hot = false;
    this.onHover = null; this.onHoverPoint = null; this.onClick = null; this.menuFor = null; this.onVisible = null;
    this.raf = 0; this.lastFrame = 0; this.lastTick = 0; this.frames = 0; this.frameSince = nowS();
    this.drag = null; this.spin = null;
    this.raycaster = new THREE.Raycaster();
    this.installInput();
    document.addEventListener("visibilitychange", () => this.occlusion());
    new ResizeObserver(() => this.setFrameSize()).observe(host);
    // 電纜光點（10-22：電力像慢慢輸入大樓）：每 30 秒播 3 秒讓光點流一段；機器熱、視窗看不到、在地下就不播
    setInterval(() => { if (this.windowVisible && !this.hot && !this.builder.underground) this.playFor(3); }, 30_000);
    this.setFrameSize();
  }

  // MARK: 正交鏡頭（微縮模型）：three 的 PerspectiveCamera 換投影矩陣（SceneKit 是同一台鏡頭切 usesOrthographicProjection）

  patchOrtho(cam) {
    const orig = cam.updateProjectionMatrix.bind(cam);
    cam.userData.orthoScale = 10;
    cam.updateProjectionMatrix = () => {
      if (!cam.isOrthographicCamera) { orig(); return; }
      const s = cam.userData.orthoScale, a = cam.aspect;
      cam.projectionMatrix.makeOrthographic(-s * a, s * a, s, -s, cam.near, cam.far);
      cam.projectionMatrixInverse.copy(cam.projectionMatrix).invert();
    };
  }
  setOrthoScale(s) { const c = this.builder.camera; c.userData.orthoScale = s; c.updateProjectionMatrix(); }
  get cam() { return this.builder.camera; }
  /** pov.position（model 值：取景動畫中也回終點） */
  get povPos() { return this.builder.cameraPosition; }
  get target() { return this.builder.target; }
  set target(t) { this.builder.target = t.slice(); }
  /** 直接定鏡頭（取消正在跑的取景動畫） */
  setPov(pos, quat = null) {
    SCNTransaction.position(this.cam, pos);
    if (quat) SCNTransaction.quaternion(this.cam, quat);
    this.cam.userData.modelPos = pos.slice();
    this.cam.updateMatrixWorld(true);
  }
  lookQuat(pos, t) {
    return new THREE.Quaternion().setFromRotationMatrix(new THREE.Matrix4().lookAt(new THREE.Vector3(...pos), new THREE.Vector3(...t), new THREE.Vector3(0, 1, 0)));
  }

  /** 換風格：後製＋鏡頭（微縮模型＝正交、等角視角；換完重新取景） */
  applyStyle(s) {
    this.style = s;
    OfficeBuilder.style = s;
    this.builder.setStyle(s);
    this.technique = OfficeStyleFX.technique(s);
    const c = this.cam;
    c.isOrthographicCamera = s === "diorama";
    if (s === "diorama") {
      const t = this.target, p = this.povPos;
      c.userData.orthoScale = OfficeStyleFX.orthoScale(len(sub(p, t)));
    }
    c.updateProjectionMatrix();
    this.framed = false;
    this.playFor(0.3);
  }

  // MARK: 大小

  setFrameSize() {
    const w = Math.max(1, this.host.clientWidth), h = Math.max(1, this.host.clientHeight);
    const changed = w !== this.bounds.width || h !== this.bounds.height;
    this.bounds = { width: w, height: h };
    this.renderer.setSize(w, h);
    this.cam.aspect = w / h; this.builder.aspect = w / h;
    this.cam.updateProjectionMatrix();
    if (changed && !this.userMoved) this.framed = false;
    this.labels.resize(w, h);
    this.frameIfNeeded();
    this.requestRender();
  }

  // MARK: 取景

  /** 你動過視角（拖、捲、走）之後，視窗改大小就不再自動取景；按「重設視角」才恢復 */
  frameIfNeeded() {
    if (this.framed || !(this.bounds.width > 10 && this.bounds.height > 10)) return;
    this.framed = true;
    this.builder.frameCamera(this.bounds.width / this.bounds.height);
    // 關窗重開（10-24 C）：你動過的視角接回去
    const m = this.memory?.camera;
    if (m && !this.userMoved) {
      this.setPov(m.pos, new THREE.Quaternion(...m.quat));
      this.target = m.target;
      this.userMoved = true;
    }
    this.camMoved(0.7);
    this.updateLOD();
  }

  /** 鏡頭停下來時算一次：看板遠近、面向鏡頭的牆淡掉、門牌換牆、夜晚燈光指派（不每幀算） */
  updateLOD() {
    if (this.userMoved && this.memory) {
      const q = this.cam.quaternion;
      this.memory.camera = { pos: this.povPos, quat: [q.x, q.y, q.z, q.w], target: this.target.slice() };
      this.memory.save?.();
    }
    const wasUnder = this.builder.underground;
    const p = this.cam.position;
    if (this.builder.updateLOD([p.x, p.y, p.z], this.target)) this.playFor(0.3);
    // 進出地下室（10-22 B1 機房）：城市名牌要拿掉／放回；圖譜開始／停止自轉 ⇒ 重算要不要持續渲染
    if (this.builder.underground !== wasUnder) {
      if (this.lastGuard) this.refreshLabels(...this.lastGuard);
      this.refreshPlaying();
    }
    this.requestRender();
  }

  /** 標籤資料（誰、什麼狀態、錨點）：內容變了才交給標籤層，並補畫一張 */
  refreshLabels(guardStatus, scanning) {
    this.lastGuard = [guardStatus, scanning];
    const { people: ps, floors: fs } = this.builder.labelTargets();
    const specs = [];
    for (const p of ps.slice().sort((a, b) => a.id < b.id ? -1 : a.id > b.id ? 1 : 0)) {
      if (p.id === "guard") specs.push(OfficeLabels.guardSpec(guardStatus, scanning, p.anchor));
      else if (p.card) specs.push(OfficeLabels.spec(p.card, p.mood, p.anchor, p.floor));
    }
    for (const c of this.builder.cityLabelTargets()) specs.push(OfficeLabels.citySpec(c.id, c.text, c.alert, c.anchor));
    const floors = fs.map(f => ({ id: f.id, node: f.node, height: f.height, title: f.title, accent: f.accent ?? null, kind: f.kind, names: f.names }));
    const sig = specs.map(s => `${s.id}|${s.text}|${s.anchor?.uuid}`).join(",") + "#" + floors.map(f => `${f.id}|${f.title}|${f.node.uuid}`).join(",");
    if (sig === this.labelSig) return;
    this.labelSig = sig;
    this.labels.set(specs, floors);
    this.playFor(0.15);
  }

  /** 需要你列／索引列的鏡頭請求 */
  perform(t) {
    switch (t?.kind) {
      case "person": {
        const n = this.builder.personNode(t.id);
        if (!n) return;
        this.userMoved = true;
        this.flyTo(n, 16);          // 看得到整個人＋這層的左右（7 太近，只看到一顆頭）
        return;
      }
      case "city": {
        this.userMoved = true;
        const p = toArr(this.builder.city.point(t.id));
        if (p) this.fly(p, 26); else { this.builder.frameCity(this.aspect); this.camMoved(0.7); }
        return;
      }
      case "floor":
        if (t.id === "city") { this.builder.frameCity(this.aspect); this.userMoved = true; this.camMoved(0.7); return; }
        if (!this.builder.frameFloor(t.id, this.aspect)) return;
        this.userMoved = true;
        this.camMoved(0.7);
        return;
      default: return;
    }
  }
  get aspect() { return this.bounds.width / Math.max(1, this.bounds.height); }

  /** 出現「新的」等你回答：你沒在動視角 ⇒ 鏡頭飛過去（不自動飛回）；你動過視角 ⇒ 不搶鏡頭，只讓它頭上的符號多跳三下 */
  noticeWaiting(ids, loaded) {
    if (!loaded) return;          // 辦公室在第一次讀到卡片之前就畫出來了，還沒讀到卡片時不算「第一次載入」
    const prev = this.prevWaiting;
    this.prevWaiting = ids;
    if (!prev) return;
    const id = [...ids].filter(i => !prev.has(i)).sort()[0];
    const n = id && this.builder.personNode(id);
    if (!n) return;
    if (!this.userMoved && this.downAt === null && this.framed) this.flyTo(n);
    else this.playFor(this.builder.bounceMark(id));
  }

  /** 角色（或保全）身上的點：點擊盒中心 */
  center(n) {
    const hb = n.getObjectByName("hitbox") ?? n;
    return toArr(hb.getWorldPosition(new THREE.Vector3()));
  }
  flyTo(n, distance = null) { this.fly(this.center(n), distance, n.name === "guard"); }

  /** 飛到某一點：維持你現在的水平方向，但仰角壓低（大樓剖面：從太高的地方看會被上一層樓板擋住） */
  fly(target, distance = null, guardView = false) {
    const t0 = this.target, p = this.povPos;
    let dir = sub(p, t0);
    const l = len(dir);
    dir = l < 0.001 ? [0.37, 0.15, 0.92] : [dir[0] / l, dir[1] / l, dir[2] / l];
    // 保全：從大廳正面偏右看進去（看得到櫃台旁的保全和後面的監控螢幕）
    if (guardView) dir = [0.35, 0.16, 0.92];
    const hz = Math.max(0.001, Math.hypot(dir[0], dir[2])), y = OfficeBuilder.style === "diorama" ? 0.26 : Math.min(Math.max(dir[1], 0.06), 0.24), k = Math.sqrt(1 - y * y) / hz;
    dir = [dir[0] * k, y, dir[2] * k];
    if (dir[2] < 0.2) dir[2] = 0.2;      // 從背後看：後牆擋住，轉到前半圈
    const dist = distance ?? Math.min(Math.max(l, 6), 10);
    const pos = [target[0] + dir[0] * dist, target[1] + dir[1] * dist, target[2] + dir[2] * dist];
    this.stopSpin();
    SCNTransaction.begin(); SCNTransaction.animationDuration = this.testMode ? 0 : 1.0;
    SCNTransaction.animationTimingFunction = "easeInEaseOut";
    SCNTransaction.position(this.cam, pos);
    SCNTransaction.quaternion(this.cam, this.lookQuat(pos, target));      // 10-21：沿用舊 up 會歪
    SCNTransaction.commit();
    this.cam.userData.modelPos = pos;
    this.target = target;
    if (this.cam.isOrthographicCamera) this.setOrthoScale(OfficeStyleFX.orthoScale(dist));
    this.camMoved(1.2);
  }

  // MARK: 按需渲染

  get windowVisible() { return document.visibilityState === "visible" && this.hostVisible; }
  /** 可以播搬家／閒晃動畫嗎：測試模式一律直接到位 */
  get canAnimate() { return !this.testMode && !OfficeBuilder.reduceMotion && this.windowVisible; }

  playFor(s) {
    if (s > 0) this.playUntil = Math.max(this.playUntil, nowS() + s);
    this.refreshPlaying();
    this.scheduleCheck();
  }
  scheduleCheck() {
    const wait = this.playUntil - nowS();
    if (this.checkPending || !(wait > 0)) return;
    this.checkPending = setTimeout(() => { this.checkPending = null; this.refreshPlaying(); this.scheduleCheck(); }, (wait + 0.05) * 1000);
  }
  refreshPlaying() {
    const visible = this.testMode || this.windowVisible;
    this.paused = !visible;          // SCNScene.isPaused：動作停在原地，回來接著跑
    const now = Date.now() / 1000, b = this.builder;
    this.fps = now < b.moveUntil ? OfficeSCNView.moveFps : b.looping ? this.baseFps : now < b.walkUntil ? OfficeSCNView.walkFps : this.baseFps;
    // 機器熱 ⇒ 持續動畫全停；地下室神經網路自轉（只在鏡頭在 B1 時）也算持續動畫
    const want = visible && ((((b.looping || b.basementSpinning) && !this.hot)) || nowS() < this.playUntil || !!this.spin);
    if (this.isPlaying !== want) this.isPlaying = want;
    if (want) this.loop(); else this.requestRender();
  }

  /** 補畫一張（停住時資料變了／滑鼠動了） */
  requestRender() {
    if (this.paused && !this.testMode) return;
    if (this.raf) return;
    this.raf = requestAnimationFrame(t => { this.raf = 0; this.draw(t); if (this.isPlaying) this.loop(); });
  }
  loop() {
    if (this.raf) return;
    this.raf = requestAnimationFrame(t => {
      this.raf = 0;
      if (!this.isPlaying || this.paused) return;
      // 幀率：依 this.fps 跳過 vsync 的幀
      if (t - this.lastFrame >= 1000 / this.fps - 4) this.draw(t);
      this.loop();
    });
  }
  draw(t) {
    const s = t / 1000;
    const dt = this.lastTick ? Math.min(0.5, Math.max(0, s - this.lastTick)) : 0;
    this.lastTick = s; this.lastFrame = t;
    this.stepSpin(dt);
    const b = this.builder;
    if (!this.paused) b.tick(dt);
    b.presentBegin();
    if (this.technique) this.technique.render(this.renderer, b.scene, this.cam);
    else this.post.render(b.scene, this.cam, b.post);
    b.presentEnd();
    this.labels.frame(this.cam);
    this.frames += 1;
  }

  /** 鏡頭動了（拖、捲、走、飛）：播到慣性停，停了再算一次 cutaway */
  camMoved(s) {
    this.playFor(s);
    this.lodDue = Math.max(this.lodDue, nowS() + s);
    if (this.lodPending) return;
    this.lodPending = true;
    this.fireLOD();
  }
  fireLOD() {
    const wait = this.lodDue - nowS();
    setTimeout(() => {
      if (this.lodDue - nowS() > 0) { this.fireLOD(); return; }
      this.lodPending = false;
      this.updateLOD();
    }, (Math.max(0, wait) + 0.05) * 1000);
  }

  // 視窗看不到 ⇒ 停止渲染；告訴資料層不要排閒晃、路上的人直接落地
  occlusion() {
    if (!this.windowVisible) this.builder.settle();
    this.lastTick = 0;
    this.onVisible?.(this.windowVisible && !OfficeBuilder.reduceMotion && !this.hot);
    this.refreshPlaying();
  }
  setHostVisible(v) { this.hostVisible = !!v; this.occlusion(); }
  /** 熱了／退燒了：路上的人直接落地、重算要不要播 */
  heatChanged(paused) {
    this.hot = !!paused;
    OfficeBuilder.heatPaused = this.hot;
    if (this.hot) this.builder.settle();
    this.onVisible?.(this.windowVisible && !OfficeBuilder.reduceMotion && !this.hot);
    this.refreshPlaying();
    this.playFor(0.2);
  }

  /** 鏡頭一越過地面就切地下室（10-22：原本要等鏡頭停下來才切，移下去要等一下才有畫面） */
  checkUnderground() {
    const y = this.povPos[1];
    const was = this.builder.underground;
    this.builder.setUnderground(y < 0);
    if (this.builder.underground !== was) {
      if (this.lastGuard) this.refreshLabels(...this.lastGuard);
      this.refreshPlaying(); this.playFor(0.4);
    }
  }

  // MARK: 鏡頭操作

  /** 轉（orbitTurntable）：水平繞世界 Y、垂直改仰角（maximumVerticalAngle 55）。度 */
  rotate(dAz, dEl) {
    if (this.mode === "walk") { this.look(-dAz, -dEl); return; }
    const t = this.target, v = sub(this.povPos, t);
    const r = len(v);
    if (r < 0.001) return;
    let az = Math.atan2(v[0], v[2]), el = Math.asin(Math.max(-1, Math.min(1, v[1] / r)));
    az += dAz * Math.PI / 180;
    el = Math.max(-55 * Math.PI / 180, Math.min(55 * Math.PI / 180, el + dEl * Math.PI / 180));
    const pos = [t[0] + r * Math.cos(el) * Math.sin(az), t[1] + r * Math.sin(el), t[2] + r * Math.cos(el) * Math.cos(az)];
    this.setPov(pos, this.lookQuat(pos, t));
  }
  /** 走進去：轉頭（鏡頭不動、看的方向轉）。度；仰俯夾在 ±60° */
  look(dAz, dEl) {
    const p = this.povPos, v = sub(this.target, p);
    const r = Math.max(0.5, len(v));
    let az = Math.atan2(v[0], v[2]), el = Math.asin(Math.max(-1, Math.min(1, v[1] / r)));
    az += dAz * Math.PI / 180;
    el = Math.max(-60 * Math.PI / 180, Math.min(60 * Math.PI / 180, el + dEl * Math.PI / 180));
    const t = [p[0] + r * Math.cos(el) * Math.sin(az), p[1] + r * Math.sin(el), p[2] + r * Math.cos(el) * Math.cos(az)];
    this.target = t;
    this.setPov(p, this.lookQuat(p, t));
  }

  // MARK: 總覽／走進去、各區分頁（11-08 H5）

  setMode(m) {
    this.mode = m;
    this.stopSpin();
    if (m === "walk") {
      const w = this.builder.walkStart?.();
      if (!w) { this.mode = "overview"; return; }
      SCNTransaction.begin(); SCNTransaction.animationDuration = this.testMode ? 0 : 0.8;
      SCNTransaction.position(this.cam, w.pos);
      SCNTransaction.quaternion(this.cam, this.lookQuat(w.pos, w.target));
      SCNTransaction.commit();
      this.cam.userData.modelPos = w.pos.slice();
      this.target = w.target;
      this.userMoved = true;
      this.canvas.focus({ preventScroll: true });
    } else {
      this.userMoved = false; this.framed = false; this.frameIfNeeded();
    }
    this.renderTabs();
    this.camMoved(0.9);
  }

  installTabs() {
    const wrap = this.host.parentElement;
    if (!wrap) return;
    const bar = document.createElement("div");
    bar.id = "zoneTabs";
    wrap.appendChild(bar);
    this.tabsEl = bar;
    this.renderTabs();
  }

  renderTabs() {
    const bar = this.tabsEl;
    if (!bar) return;
    const zones = this.builder.zones?.() ?? [];
    bar.innerHTML = "";
    const btn = (text, on, f, dot = null, title = "") => {
      const b = document.createElement("button");
      b.className = "ztab" + (on ? " on" : "");
      if (dot !== null) { const i = document.createElement("i"); i.style.background = "#" + dot.toString(16).padStart(6, "0"); b.appendChild(i); }
      b.appendChild(document.createTextNode(text));
      if (title) b.title = title;
      b.onclick = e => { e.stopPropagation(); f(); };
      bar.appendChild(b);
      return b;
    };
    btn("總覽", this.mode === "overview" && !this.zoneOn, () => { this.zoneOn = null; this.setMode("overview"); }, null, "從上面看整層");
    btn("走進去", this.mode === "walk", () => { this.zoneOn = null; this.setMode("walk"); }, null, "第一人稱：拖曳轉頭、WASD 走、滾輪前後");
    const sep = document.createElement("span"); sep.className = "zsep"; bar.appendChild(sep);
    for (const z of zones) btn(z.title, this.zoneOn === z.id, () => this.goZone(z.id), z.accent ?? null);
  }

  goZone(id) {
    this.zoneOn = id;
    this.mode = "overview";
    if (this.builder.frameZone?.(id, this.aspect)) { this.userMoved = true; this.camMoved(0.9); }
    this.renderTabs();
  }

  stopSpin() { this.spin = null; }
  stepSpin(dt) {
    const s = this.spin;
    if (!s || !(dt > 0)) return;
    this.rotate(s.vx * dt, s.vy * dt);
    const k = Math.exp(-dt * 5);       // 慣性：約 1 秒滑完（放開時的速度打五折）
    s.vx *= k; s.vy *= k;
    if (Math.hypot(s.vx, s.vy) < 2) { this.spin = null; this.camMoved(0.05); }
    this.checkUnderground();
  }

  /** 滾輪＝放大縮小：沿著鏡頭→轉軸那條線拉近拉遠 */
  scrollWheel(dy) {
    this.userMoved = true;
    if (this.mode === "walk") { this.walk([0, 0, dy * 6]); return; }
    if (dy === 0) { this.checkUnderground(); return; }
    const t = this.target, p = this.povPos, v = sub(p, t);
    const dist = len(v);
    if (!(dist > 0.001)) return;
    const next = Math.min(Math.max(dist * Math.exp(-dy), 2), 260);       // 往上滾（dy>0）拉近
    const k = next / dist;
    this.stopSpin();
    this.setPov([t[0] + v[0] * k, t[1] + v[1] * k, t[2] + v[2] * k]);
    // 微縮模型（正交鏡頭）沒有近大遠小：只移鏡頭畫面不會變，要跟著改畫面大小
    if (this.cam.isOrthographicCamera) this.setOrthoScale(OfficeStyleFX.orthoScale(next));
    this.camMoved(0.3);
    this.checkUnderground();
  }

  /** 平移：鏡頭和轉軸一起沿畫面的左右／上下移動，滑鼠底下的東西跟著手走 */
  pan(dx, dy) {
    const t = this.target, p = this.povPos;
    const dist = len(sub(p, t));
    // 每一點像素對應的世界距離：依鏡頭到轉軸的距離和視角換算
    const fov = (this.cam.fov ?? 42) * Math.PI / 180;
    let k = 2 * dist * Math.tan(fov / 2) / Math.max(1, this.bounds.height);
    if (this.cam.isOrthographicCamera) k = 2 * this.cam.userData.orthoScale / Math.max(1, this.bounds.height);   // 正交：畫面高＝2×orthographicScale
    const r = new THREE.Vector3(1, 0, 0).applyQuaternion(this.cam.quaternion), u = new THREE.Vector3(0, 1, 0).applyQuaternion(this.cam.quaternion);
    const d = [-r.x * dx * k + u.x * dy * k, -r.y * dx * k + u.y * dy * k, -r.z * dx * k + u.z * dy * k];
    this.setPov(add(p, d));
    this.target = add(t, d);
  }

  /** WASD／方向鍵：在地面上走（鏡頭跟轉軸一起平移）；Q／E 升降 */
  /** 走進去：沿地面走（不升降），夾在辦公室裡。d＝[右, 0, 前]（公尺） */
  walk(d) {
    const fw = new THREE.Vector3(0, 0, -1).applyQuaternion(this.cam.quaternion);
    let f = [fw.x, 0, fw.z];
    const fl = Math.max(0.001, Math.hypot(f[0], f[2])); f = [f[0] / fl, 0, f[2] / fl];
    const r = [-f[2], 0, f[0]];
    const p = this.povPos, b = this.builder.walkBounds;
    let nx = p[0] + r[0] * d[0] + f[0] * d[2], nz = p[2] + r[2] * d[0] + f[2] * d[2];
    if (b) { nx = Math.min(Math.max(nx, b.lo[0]), b.hi[0]); nz = Math.min(Math.max(nz, b.lo[1]), b.hi[1]); }
    const delta = [nx - p[0], 0, nz - p[2]];
    const pos = [nx, p[1], nz];
    SCNTransaction.begin(); SCNTransaction.animationDuration = 0.12;
    SCNTransaction.position(this.cam, pos);
    SCNTransaction.commit();
    this.cam.userData.modelPos = pos;
    this.target = add(this.target, delta);
    this.camMoved(0.25);
  }

  keyDown(e) {
    if (this.mode === "walk") {
      const st = e.shiftKey ? 1.2 : 0.5;
      const m = { w: [0, 0, st], arrowup: [0, 0, st], s: [0, 0, -st], arrowdown: [0, 0, -st], a: [-st, 0, 0], d: [st, 0, 0] }[e.key.toLowerCase()];
      if (m) { this.userMoved = true; this.walk(m); return true; }
      if (e.key === "ArrowLeft") { this.look(6, 0); this.camMoved(0.2); return true; }
      if (e.key === "ArrowRight") { this.look(-6, 0); this.camMoved(0.2); return true; }
      if (e.key === "Escape") { this.setMode("overview"); return true; }
      return false;
    }
    const step = e.shiftKey ? 2.4 : 1.0;
    const fw = new THREE.Vector3(0, 0, -1).applyQuaternion(this.cam.quaternion);
    let f = [fw.x, 0, fw.z];
    const fl = Math.max(0.001, Math.hypot(f[0], f[2])); f = [f[0] / fl, 0, f[2] / fl];
    const r = [-f[2], 0, f[0]];
    let d;
    switch (e.key.toLowerCase()) {
      case "w": case "arrowup": d = [f[0] * step, 0, f[2] * step]; break;
      case "s": case "arrowdown": d = [-f[0] * step, 0, -f[2] * step]; break;
      case "a": case "arrowleft": d = [-r[0] * step, 0, -r[2] * step]; break;
      case "d": case "arrowright": d = [r[0] * step, 0, r[2] * step]; break;
      case "q": d = [0, -step, 0]; break;
      case "e": d = [0, step, 0]; break;
      default: return false;
    }
    this.userMoved = true;
    this.stopSpin();
    const pos = add(this.povPos, d);
    SCNTransaction.begin(); SCNTransaction.animationDuration = 0.12;
    SCNTransaction.position(this.cam, pos);
    SCNTransaction.commit();
    this.cam.userData.modelPos = pos;
    this.camMoved(0.25);
    this.target = add(this.target, d);
    this.checkUnderground();
    return true;
  }

  // MARK: 點擊、懸停

  /** 事件 → view 座標（y 往上，跟標籤層一樣） */
  viewPoint(e) {
    const r = this.canvas.getBoundingClientRect();
    return { x: e.clientX - r.left, y: r.height - (e.clientY - r.top), top: e.clientY - r.top };
  }
  /** 這一點的世界射線（近平面 → 遠平面；正交鏡頭也對） */
  ray(p) {
    const nx = p.x / this.bounds.width * 2 - 1, ny = p.y / this.bounds.height * 2 - 1;
    this.cam.updateMatrixWorld(true);
    const a = new THREE.Vector3(nx, ny, -1).unproject(this.cam), b = new THREE.Vector3(nx, ny, 1).unproject(this.cam);
    return [a, b];
  }

  /** 先問螢幕空間標籤（標籤在 3D 之上），沒點到再問 3D */
  pick(p) { return this.labels.label(p) ?? this.person(p); }

  /** 點到哪個角色（節點名 "p:<卡片 id>"，或保全 "guard"、城市 "city:…"，往上找）。
   *  只找角色與保全（categoryBitMask＝pickMask），不在整層樓的大 mesh 上算三角形；先認看得到的東西，都沒有才認透明點擊盒 */
  person(p) {
    const [a, b] = this.ray(p);
    const meshes = [];
    this.builder.scene.traverse(n => { if (n.isMesh && (category(n) & OfficeBuilder.pickMask)) meshes.push(n); });
    this.raycaster.set(a, b.clone().sub(a).normalize());
    this.raycaster.far = a.distanceTo(b);
    const hits = this.raycaster.intersectObjects(meshes, false);
    const owner = node => {
      let n = node;
      while (n) {
        const s = n.name;
        if (s) {
          if (s.startsWith("p:")) return s.slice(2);
          if (s.startsWith("city:")) return s;
          if (s === "guard") return "guard";
          if (s === "b1-board") return this.builder.underground ? s : null;      // 地上時 B1 藏著，點不到
        }
        n = n.parent;
      }
      return null;
    };
    for (const h of hits) if (h.object.name !== "hitbox") { const id = owner(h.object); if (id) return id; }
    for (const h of hits) if (h.object.name === "hitbox") { const id = owner(h.object); if (id) return id; }
    return null;
  }

  /** 鏡頭在地下室時，這一點有沒有點到中間那團神經網路（點到 ⇒ 最近的節點屬於哪個專案）。地上一律 null */
  neuralProject(p) {
    if (!this.builder.underground) return null;
    const [a, b] = this.ray(p);
    return this.builder.basement.pickProject(a, b);
  }

  /** 懸停偵測（節流）：只在滑鼠移動時做，最多每 50 ms 一次；中間丟掉的那一下由最後一次補做（一次性 setTimeout） */
  hover(p) {
    const now = nowS();
    if (now - this.lastHoverPick < OfficeSCNView.hoverThrottle) {
      this.hoverTrailing = p;
      if (!this.hoverTrailingPending) {
        this.hoverTrailingPending = true;
        setTimeout(() => {
          this.hoverTrailingPending = false;
          if (this.hoverTrailing) { const q = this.hoverTrailing; this.hoverTrailing = null; this.hover(q); }
        }, OfficeSCNView.hoverThrottle * 1000);
      }
      return;
    }
    this.lastHoverPick = now;
    this.hoverTrailing = null;
    const id = this.pick(p);
    if (id !== this.hoverId) {
      this.hoverId = id; this.builder.highlight(id);
      if (id !== null) this.onHoverPoint?.({ x: p.x, y: p.top });     // 「3D 區域左上角為原點」
      this.onHover?.(id);
      this.requestRender();
    }
  }

  installInput() {
    const c = this.canvas;
    c.addEventListener("contextmenu", e => e.preventDefault());
    c.addEventListener("pointerdown", e => {
      c.focus({ preventScroll: true });
      try { c.setPointerCapture(e.pointerId); } catch { /* 合成事件沒有指標 */ }
      this.stopSpin();
      this.drag = { button: e.button, x: e.clientX, y: e.clientY, x0: e.clientX, y0: e.clientY, moved: false, samples: [] };
      if (e.button === 0) this.downAt = { x: e.clientX, y: e.clientY };
    });
    c.addEventListener("pointermove", e => {
      const d = this.drag;
      if (!d) { this.hover(this.viewPoint(e)); return; }
      const dx = e.clientX - d.x, dy = e.clientY - d.y;
      d.x = e.clientX; d.y = e.clientY;
      if (Math.hypot(e.clientX - d.x0, e.clientY - d.y0) >= 4) d.moved = true;
      if (!d.moved) return;
      this.userMoved = true;
      if (d.button === 0) {
        // 轉視角有慣性：拖曳中與放開後播一秒，讓慣性滑完
        const dAz = -dx * 0.5, dEl = dy * 0.5;
        this.rotate(dAz, dEl);
        d.samples.push([performance.now(), dAz, dEl]);
        while (d.samples.length && performance.now() - d.samples[0][0] > 100) d.samples.shift();
        this.camMoved(1.0);
      } else {
        this.pan(dx, dy);
        this.camMoved(0.3);
      }
      this.checkUnderground();
    });
    const up = e => {
      const d = this.drag;
      if (!d) return;
      this.drag = null;
      try { c.releasePointerCapture(e.pointerId); } catch { /* 已經放掉 */ }
      if (d.button === 0) {
        this.camMoved(1.0);
        if (d.moved && d.samples.length > 1) {
          const t0 = d.samples[0][0], t1 = performance.now(), T = Math.max(16, t1 - t0) / 1000;
          const vx = d.samples.reduce((a, s) => a + s[1], 0) / T, vy = d.samples.reduce((a, s) => a + s[2], 0) / T;
          if (Math.hypot(vx, vy) > 20 && this.mode !== "walk") { this.spin = { vx: vx * 0.5, vy: vy * 0.5 }; this.refreshPlaying(); }
        }
        // 拖曳是轉視角，不算點
        if (!d.moved) {
          const p = this.viewPoint(e);
          const id = this.pick(p);
          if (id) this.onClick?.(id);
          else {
            const proj = this.neuralProject(p);
            // 10-22：點地下室中間那團神經網路 ⇒ 開知識星雲（OfficeView.click 處理 "neural:" 開頭）
            if (proj) { this.builder.basement.flash(); this.playFor(0.8); this.onClick?.("neural:" + proj); }
          }
        }
        this.downAt = null;
      } else if (d.button === 2 && !d.moved) {
        // 右鍵（沒拖）＝選單
        const id = this.pick(this.viewPoint(e));
        if (id) this.menuFor?.(id, e.clientX, e.clientY);
      }
    };
    c.addEventListener("pointerup", up);
    c.addEventListener("pointercancel", up);
    c.addEventListener("pointerleave", () => {
      if (this.drag) return;
      this.hoverTrailing = null; this.hoverId = null; this.builder.highlight(null); this.onHover?.(null); this.requestRender();
    });
    c.addEventListener("wheel", e => {
      e.preventDefault();
      if (e.ctrlKey) {        // 觸控板捏合（magnify）
        this.userMoved = true;
        this.scrollWheel(-e.deltaY * 0.01);
        return;
      }
      // 滾輪一格（約 100 像素）＝Mac 的一行（×0.1）；觸控板（小數、小的像素量）＝Mac 的 precise（×0.01）
      const lines = e.deltaMode === 1 ? -e.deltaY : e.deltaMode === 2 ? -e.deltaY * 3 : null;
      const precise = lines === null && (!Number.isInteger(e.deltaY) || Math.abs(e.deltaY) < 40);
      const dy = lines !== null ? lines * 0.1 : precise ? -e.deltaY * 0.01 : -e.deltaY / 100 * 0.1;
      this.scrollWheel(dy);
    }, { passive: false });
    c.addEventListener("keydown", e => {
      if (e.metaKey || e.ctrlKey || e.altKey) return;
      if (this.keyDown(e)) e.preventDefault();
    });
  }
}

