// OfficeBasement.swift 照搬（11-02 P8）：地下室 B1 伺服器機房＋浮空神經網路＋Agent交流互動板。
//
// 地下室 B1 伺服器機房（10-22 Kang 看了 Graphify 影片：「做在地下室，很像伺服器機房，中間有一個浮在空中的 3D 神經網路」）。
//   位置：大廳正下方（大廳地板 y 0，B1 地坪 y −5.6、淨高 5.2），範圍跟大樓模組一樣（x ±6、z TowerSpec.back…front）。
//   平常被城市地坪、大地面蓋住看不到；按住滾輪往下平移、鏡頭（世界 y）低於 0 才出現：地面淡出、B1 照一般樓層 cutaway。
//   機房：深色高架地板（細格線）、深灰牆、後牆＋兩側一排排黑色機櫃（正面一格格 LED：綠多、藍次之、少數琥珀；停電跟著熄）、
//   天花線槽、冷藍色燈；三面外側是土層剖面（跟著那面牆一起 cutaway）。全部合併成幾個 mesh（一種材質一個 draw call）。
//   中間浮著神經網路：資料是 NeuralGraph（Graphify 抽的程式碼知識圖譜，畫面不知道 Graphify）；
//   節點＝低面數八面體、全部合成 1 個 geometry（顏色走頂點色，同專案同色）；邊＝LineSegments 一次畫完（半透明青色、加法混色）。
//   整團約 60 秒自轉一圈，只在鏡頭在地下室時轉；地上時整個 B1 藏起來，不送進渲染、不每幀做事。
//   B1 的東西只吃自己的燈（categoryBitMask＝mask）：大樓的暖補光、太陽、夜晚 omni 都照不到；環境光（ambient 不吃位元）照得到。
//
// Swift → JS 的差別：
//   · SCNMaterial.diffuse.intensity（constant 材質的亮度倍數，HDR 下 >1 會泛光）→ 材質 shader 多乘一個 uniform（diffuseIntensity()）。
//   · 留言板資料：Mac 讀 B1Board 檔；Windows 由資料端設 OfficeBasement.boardFeed＝() => ({ stamp, posts })（posts＝B1Post 陣列，舊到新）。
//   · TowerModules.wall／glassFront：tower.js 還沒轉寫好之前，這裡用同檔的 b1Wall／b1GlassFront（逐行照 OfficeTower.swift 抄）；
//     tower.js 有了之後改呼叫它（行為一模一樣）。

import * as THREE from "three";
import { VoxelMesh, Kit, Xf, VoxMat, TD, TM, TP, TowerLayout, PixelTex, scnNode, scnLight, setScnIntensity, setCategory } from "../kit.js";
import { TowerModules, facade } from "./tower.js";
import { Act, runAction, setPaused, isPaused, SCNTransaction } from "./actions.js";
import { NeuralGraph } from "./neural-graph.js";
import { NeuralPick } from "./neural-pick.js";

/// 留言板計時器回呼找得到人（Timer 的 closure 不想抓 self）
export const BoardFeed = { basement: null };

/** OfficeBuilder.pickMask（避免循環 import：builder.js import 這個檔） */
const pickMask = 2;

export class OfficeBasement {
  /** B1 專用的光照位元（大樓 1、角色點擊 2、戶外 1<<4） */
  static mask = 1 << 5;
  /** B1 地坪（世界 y）、淨高 */
  static floorY = -5.6;      // 10-22 Kang：再深一點，好觀看（−4.2 → −5.6）
  static clear = 5.2;
  /** 模組原點（樓板底）：模組內座標跟其他樓層一樣（地坪面＝TD.room） */
  static baseY = OfficeBasement.floorY - TD.room;
  /** 土層剖面最底（世界 y；鏡頭 zNear 用的外框下緣） */
  static bottomY = OfficeBasement.baseY - 1.5;
  /** 圖譜中心（模組內座標）：機房正中間、離地 2.6；半徑 2.2（10-22 實測 1.6 在 12 公尺寬的機房裡太小） */
  static graphCenter = [0, TD.room + 2.6, TD.zC];
  static graphRadius = 2.2;
  /** 自轉一圈幾秒 */
  static spinPeriod = 60;
  static boardShown = 5;
  /** Windows：留言板資料來源（Mac 的 B1Board）。null＝沒有資料（畫空板）；() => ({ stamp: String, posts: [B1Post] }) */
  static boardFeed = null;

  /** 霓虹調色盤（同專案同色，依第一次出現的順序循環） */
  static palette = [0x22D3EE, 0xA78BFA, 0xF472B6, 0x34D399, 0xFBBF24, 0x60A5FA, 0xFB7185, 0xA3E635];

  constructor() {
    this.root = scnNode("basement");
    this.facades = [];
    /** 圖譜的轉軸（自轉的動作掛在這；不在地下室時 isPaused） */
    this.pivot = scnNode();
    this.graphNode = null;
    this.graphCount = { nodes: 0, edges: 0 };
    /** 目前畫的擺放（點擊判定用：節點位置、屬於哪個專案） */
    this.placement = null;
    /** 神經網路、投影台光圈自己管亮度（停電只暗到 0.25，不跟一般發光材質一起熄）：[material, base] */
    this.neuralMats = [];
    this.power = 1;
    this.live = false;
    /** Agent交流互動板（10-24 Kang：要掛在 B1 牆上）：後牆機櫃上方一面螢幕，畫最近幾則；檔案變了才重畫 */
    this.boardMat = null;
    this.boardStamp = null;
    this.boardTimer = null;
    this.boardScreen = null;

    this.root.position.set(0, OfficeBasement.baseY, 0);
    this.root.visible = false;                 // 鏡頭到地下才出現
    this.buildRoom();
    this.pivot.name = "neural";
    this.pivot.position.set(...OfficeBasement.graphCenter);
    this.root.add(this.pivot);
    // 自轉：一直掛著、用 isPaused 開關（停的時候停在當下角度，下次接著轉）
    runAction(this.pivot, Act.repeatForever(Act.rotateBy(0, 2 * Math.PI, 0, OfficeBasement.spinPeriod)), "spin");
    setPaused(this.pivot, true);
    // 冷藍色主燈（從前上方往下照）＋圖譜中心一盞青色 omni（照亮投影台四周地板）：只照 B1
    this.key = scnLight({ type: "directional", mask: OfficeBasement.mask, color: 0x9CC8FF, euler: [-1.05, 0.35, 0] });
    this.root.add(this.key); this.root.add(this.key.target);       // target 也掛在 root 下：方向＝SceneKit 節點的 −Z（不受 root 位移影響）
    this.glowLight = scnLight({ type: "omni", mask: OfficeBasement.mask, color: 0x5EEAD4, start: 0.5, end: 4.5 });
    this.glowLight.position.set(...OfficeBasement.graphCenter);
    this.root.add(this.glowLight);
    this.setPower(1);
    this.setGraph(NeuralGraph.demo());
  }

  /** 鏡頭在不在地下室：在 ⇒ 整個 B1 出現、圖譜開始轉（reduceMotion 不轉） */
  setLive(on, spin = true) {
    const was = this.live;
    this.live = on;
    this.root.visible = on;
    setPaused(this.pivot, !(on && spin));
    // 留言板：進 B1 時看一次檔案，人在 B1 的期間每 10 秒看一次（只比 stamp，沒變不重畫）
    if (on && !was) {
      this.refreshBoard();
      clearInterval(this.boardTimer);
      this.boardTimer = setInterval(() => BoardFeed.basement?.refreshBoard(), 10000);
      BoardFeed.basement = this;
    } else if (!on) { clearInterval(this.boardTimer); this.boardTimer = null; }
  }

  refreshBoard(force = false) {
    const feed = OfficeBasement.boardFeed?.() ?? null;
    const st = feed?.stamp ?? "none";
    if (!(force || st !== this.boardStamp)) return;
    this.boardStamp = st;
    const all = feed?.posts ?? [];
    setCanvas(this.boardMat, OfficeBasement.boardImage(all.slice(-OfficeBasement.boardShown).reverse(), all.length));
  }

  /**
   * 留言板畫面（1840×840 px）：標題＋最新在上的幾則，每則「#編號 名字（專案）時間」一行＋內容最多兩行。
   * posts：[{ id, at: Date, sid, name, project, text, re? }]（Swift 的 B1Post）
   */
  static boardImage(posts, total) {
    const W = 920, H = 420, scale = 2;
    const cv = document.createElement("canvas"); cv.width = W * scale; cv.height = H * scale;
    const g = cv.getContext("2d");
    g.scale(scale, scale);
    g.fillStyle = "rgb(10,18,28)"; g.fillRect(0, 0, W, H);                       // (0.04, 0.07, 0.11)
    const cyan = "rgba(94,235,212,1)";                                           // (0.37, 0.92, 0.83)
    g.strokeStyle = "rgba(94,235,212,0.8)"; g.lineWidth = 3;
    roundRect(g, 4, 4, W - 8, H - 8, 10); g.stroke();
    draw(g, "Agent交流互動板", 26, 16, 30, 700, cyan, 400);
    const sub = total === 0 ? "" : `共 ${total} 則・最新在上`;
    draw(g, sub, W - 226, 28, 16, 500, "rgb(179,179,179)", 200);
    if (!posts.length) {
      draw(g, "還沒有留言。Agent 到 B1 休息時會留下工作心得。", 26, 90, 20, 400, "rgb(191,191,191)", W - 52);
      return cv;
    }
    const p2 = n => String(n).padStart(2, "0");
    const fmt = d => `${p2(d.getMonth() + 1)}-${p2(d.getDate())} ${p2(d.getHours())}:${p2(d.getMinutes())}`;
    let y = 66;
    posts.forEach((p, i) => {
      let sum = 0;
      for (const ch of p.name) sum = (sum + ch.codePointAt(0)) | 0;
      const c = VoxMat.color(OfficeBasement.palette[sum % OfficeBasement.palette.length]).css;
      const head = `#${p.id}  ${p.name}` + (p.project ? `（${p.project}）` : "") + (p.re != null ? `  ↪#${p.re}` : "") + "  " + fmt(new Date(p.at));
      draw(g, head, 26, y, 16, 600, c, W - 52);
      wrap(g, p.text, 26, y + 22, W - 52, 2, 18, "rgb(237,237,237)");
      y += 70;
      if (i < posts.length - 1) { g.fillStyle = "rgba(255,255,255,0.08)"; g.fillRect(26, y - 5, W - 52, 1); }
    });
    return cv;
  }

  /** 圖譜正在轉（畫面迴圈依這個決定要不要持續渲染） */
  get spinning() { return this.live && !isPaused(this.pivot) && this.graphCount.nodes > 0; }

  /** 電力乘數（1 正常 … 0 停電）：機房燈跟著暗；神經網路、光圈最暗 0.25（停電時還看得到一團微光） */
  setPower(p) {
    this.power = p;
    setScnIntensity(this.key, 650 * p);
    setScnIntensity(this.glowLight, 420 * p);
    this.key.visible = !(p <= 0.001); this.glowLight.visible = !(p <= 0.001);
    const k = Math.max(0.25, p);
    for (const [m, base] of this.neuralMats) m.userData.diffInt.value = base * k;
  }

  neural(m, base) {
    m.userData.diffInt.value = base * Math.max(0.25, this.power);
    this.neuralMats.push([m, base]);
    return m;
  }

  // MARK: 機房（靜態，合併成幾個 mesh）

  buildRoom() {
    const m = new VoxelMesh(), k = new Kit(m);
    const r = TD.room, h = OfficeBasement.clear, top = -OfficeBasement.baseY - 0.02;     // top＝世界 y −0.02（地表下一點點，不跟大地面打架）
    const W = TD.W, zB = TD.zB, zF = TD.zF, zC = TD.zC, D = TD.D;
    const I = Xf.identity;
    // 樓板＋高架地板（深色，0.6 公尺一格的細格線）
    k.b(I, 0, 0, zC, W, TD.slab, D, TM.f(0x23272D));
    k.b(I, 0, TD.slab, zC, W - 0.02, 0.01, D - 0.02, TM.f(0x1A1E24));
    const line = TM.f(0x343C47);
    for (const x of strideTo(-W / 2 + 0.6, W / 2 - 0.1, 0.6)) k.b(I, x, r, zC, 0.02, 0.004, D - 0.32, line);
    for (const z of strideTo(zB + 0.6, zF - 0.1, 0.6)) k.b(I, 0, r, z, W - 0.32, 0.004, 0.02, line);
    // 中間冷通道幾塊打孔地板（亮一階）
    const perf = TM.f(0x262C35);
    const tiles = [[-1.8, zC - 1.8], [1.8, zC - 1.8], [-1.8, zC + 1.8], [1.8, zC + 1.8], [0, zC + 2.4], [0, zC - 2.4]];
    for (const [x, z] of tiles) k.b(I, x, r, z, 0.56, 0.006, 0.56, perf);
    // 樓板前緣冷光條
    k.b(I, 0, TD.slab - 0.02, zF + 0.011, W, 0.02, 0.02, TM.glow(0x38BDF8, 0.9, 0.9));
    // 天花（B1 頂板：r+h → 地表下）
    k.b(I, 0, r + h, zC, W, top - r - h, D, TM.f(0x1C1F24));
    // 天花線槽：後排一條（沿 x）、兩側各一條（沿 z），吊桿每 1.5 公尺；槽上兩色電纜
    const tray = TM.f(0x454B54), rod = TM.f(0x2F3338), cableA = TM.f(0x1E40AF), cableB = TM.f(0xB45309);
    const ty = r + h - 0.38;
    const trayX = (z, x0, x1) => {
      k.b(I, (x0 + x1) / 2, ty, z, x1 - x0, 0.06, 0.4, tray);
      k.b(I, (x0 + x1) / 2, ty + 0.06, z - 0.08, x1 - x0, 0.06, 0.12, cableA);
      k.b(I, (x0 + x1) / 2, ty + 0.06, z + 0.09, x1 - x0, 0.05, 0.1, cableB);
      for (const x of strideThrough(x0 + 0.3, x1 - 0.3, 1.5)) k.b(I, x, ty + 0.06, z, 0.02, r + h - ty - 0.06, 0.02, rod);
    };
    const trayZ = (x, z0, z1) => {
      k.b(I, x, ty, (z0 + z1) / 2, 0.4, 0.06, z1 - z0, tray);
      k.b(I, x - 0.08, ty + 0.06, (z0 + z1) / 2, 0.12, 0.06, z1 - z0, cableA);
      k.b(I, x + 0.09, ty + 0.06, (z0 + z1) / 2, 0.1, 0.05, z1 - z0, cableB);
      for (const z of strideThrough(z0 + 0.3, z1 - 0.3, 1.5)) k.b(I, x, ty + 0.06, z, 0.02, r + h - ty - 0.06, 0.02, rod);
    };
    trayX(TD.backZ + 0.55, -5.0, 5.0);
    trayZ(-5.3, zB + 1.0, zF - 1.0);
    trayZ(5.3, zB + 1.0, zF - 1.0);
    // 天花冷白燈條（兩條沿 z，讓開中間的圖譜）
    const strip = TM.glow(0xCFE8FF, 0.9, 0.9);
    for (const x of [-3.0, 3.0]) k.b(I, x, r + h - 0.05, zC, 0.12, 0.05, D - 2.4, strip);

    // 機櫃：後牆一排 15 座（面向 +z）、兩側各 11 座（面向室內）
    const rng = new PixelTex.RNG(0xB15E4FE2);
    const led = [TM.glow(0x22C55E, 1.5, 1.5), TM.glow(0x3B82F6, 1.5, 1.5), TM.glow(0xF59E0B, 1.5, 1.5)];
    const body = TM.f(0x0F1114), unit = TM.f(0x1A1D22), vent = TM.f(0x2A2F36);
    const rack = xf => {
      k.b(xf, 0, r, 0, 0.6, 2.1, 1.0, body);
      k.b(xf, 0, r + 2.1, 0, 0.5, 0.03, 0.8, vent);
      for (let u = 0; u < 8; u++) {
        const y = r + 0.12 + u * 0.24;
        k.b(xf, 0, y, 0.505, 0.54, 0.2, 0.01, unit);
        for (let i = 0; i < 4; i++) {
          const v = rng.next();
          if (!(v > 0.12)) continue;                         // 一成多不亮（看起來才不像整齊的燈牆）
          const mat = v < 0.62 ? led[0] : v < 0.92 ? led[1] : led[2];
          k.b(xf, -0.21 + i * 0.055, y + 0.13, 0.515, 0.03, 0.02, 0.01, mat);
        }
        if (rng.next() < 0.35) k.b(xf, 0.17, y + 0.04, 0.515, 0.12, 0.012, 0.01, led[1]);   // 硬碟活動燈條
      }
    };
    for (let i = 0; i < 15; i++) rack(new Xf(-4.55 + i * 0.65, 0, TD.backZ + 0.55, 0));
    for (let i = 0; i < 11; i++) {
      const z = zB + 1.8 + i * 0.65;
      if (!(z > -3.75 && z < -0.45)) rack(new Xf(-W / 2 + 0.7, 0, z, Math.PI / 2));     // 左牆讓出兩部電梯的門口
      rack(new Xf(W / 2 - 0.7, 0, z, -Math.PI / 2));
    }
    // 機櫃排前的地面冷光條（高架地板縫透出來的藍光）
    const floorGlow = TM.glow(0x38BDF8, 0.8, 0.8);
    k.b(I, 0, r, TD.backZ + 1.1, 9.6, 0.01, 0.03, floorGlow);
    for (const s of [-1, 1]) k.b(I, s * (W / 2 - 1.25), r, zB + 1.8 + 3.25, 0.03, 0.01, 7.0, floorGlow);

    // 投影台底座（光圈另外一個 mesh，亮度跟神經網路一起管）
    k.b(I, 0, r, zC, 1.3, 0.1, 1.3, TM.f(0x15181D));
    k.b(I, 0, r + 0.1, zC, 1.0, 0.02, 1.0, TM.f(0x0B0D10));

    // 土層剖面底部（B1 樓板下）
    k.b(I, 0, -1.5, zC - 1.5, W + 7, 1.5, D + 3, TM.f(0x241E19));
    const st = m.node("basement-static");
    this.root.add(st);

    // 光圈：兩圈發光小段（地上投影台）＋底座頂面的方形光板
    const rm = new VoxelMesh(), rk = new Kit(rm);
    const ringMat = this.neural(constant(0x5EEAD4), 1.4);
    for (const [rad, n] of [[1.15, 48], [0.8, 32]]) {
      for (let i = 0; i < n; i++) {
        const t = i / n * 2 * Math.PI;
        rk.b(new Xf(Math.cos(t) * rad, 0, zC + Math.sin(t) * rad, -t), 0, r + 0.003, 0, 0.05, 0.012, rad * 2 * Math.PI / n * 0.62, ringMat);
      }
    }
    rk.b(I, 0, r + 0.12, zC, 0.7, 0.01, 0.7, this.neural(constant(0x22D3EE), 0.9));
    this.root.add(rm.node("basement-ring"));

    // 牆：後、左、右各一面（深灰）＋外側土層（跟著那面牆一起 cutaway）；正面玻璃
    const wall = TM.f(0x2A2E35);
    const bands = [[0, 1.0, 0x2B241E], [1.0, 2.6, 0x332A22], [2.6, 3.9, 0x3B3027], [3.9, top, 0x4A3A2C]];
    const earth = (wk, x, z, w, d) => {
      for (const [y0, y1, c] of bands) if (y1 > y0) wk.b(I, x, y0, z, w, y1 - y0, d, TM.f(c));
    };
    this.facades = [
      facade(b1Wall(0, { h, mat: wall, name: "b1-back" }, wk => earth(wk, 0, zB - 1.5, W, 3)), TowerModules.normals[0], false),
      facade(b1GlassFront({ h, alpha: 0.12 }), TowerModules.normals[1], true),
      // 左牆：兩部電梯的門（10-22 Kang：B1 要留電梯出口）；左側土層讓出電梯井（x −7.8…−6.0、z −3.65…−0.55）
      facade(b1Wall(2, { h, mat: wall, gaps: TowerLayout.elevatorDoors.map(d => [d.z - 0.45, d.z + 0.45, 2.1]), name: "b1-left" }, wk => {
        const z0 = zC - 1.5 - (D + 3) / 2, z1 = zC - 1.5 + (D + 3) / 2;
        earth(wk, -W / 2 - 2.65, zC - 1.5, 1.7, D + 3);
        earth(wk, -W / 2 - 0.9, (-0.55 + z1) / 2, 1.8, z1 + 0.55);
        earth(wk, -W / 2 - 0.9, (z0 - 3.65) / 2, 1.8, -3.65 - z0);
        for (const d of TowerLayout.elevatorDoors) {
          const dz = d.z;
          for (const z of [dz - 0.5, dz + 0.5]) wk.b(I, -W / 2 + 0.17, TD.room, z, 0.06, 2.2, 0.1, TM.f(0x5FD4FF));
          wk.b(I, -W / 2 + 0.17, TD.room + 2.1, dz, 0.06, 0.12, 1.1, TM.f(0x5FD4FF));
        }
      }), TowerModules.normals[2], false),
      facade(b1Wall(3, { h, mat: wall, name: "b1-right" }, wk => earth(wk, W / 2 + 1.75, zC - 1.5, 3.5, D + 3)), TowerModules.normals[3], false),
    ];
    // 牆面頂端到天花之間的空隙：牆只到 r+h，頂板從 r+h 起 ⇒ 剛好接上
    for (const f of this.facades) this.root.add(f.node);
    // 留言板：後牆、機櫃上方（機櫃頂 r+2.13），面向 +z；掛在後牆節點下 ⇒ 後牆 cutaway 時一起藏
    const bw = 4.6, bh = 2.1;
    const bg = new THREE.BoxGeometry(bw + 0.12, bh + 0.12, 0.06);
    bg.setAttribute("color", new THREE.Float32BufferAttribute(new Float32Array(bg.attributes.position.count * 3).fill(1), 3));   // lambert 材質開了頂點色
    const bezel = new THREE.Mesh(bg, TM.f(0x0B0D10));
    bezel.userData.scn = { type: "SCNBox", params: { w: bw + 0.12, h: bh + 0.12, l: 0.06, chamfer: 0.02 } };
    bezel.position.set(0, r + 2.45 + bh / 2, TD.backZ + 0.05);
    this.boardMat = new THREE.MeshBasicMaterial();
    this.boardMat.userData.lm = "constant";
    setCanvas(this.boardMat, OfficeBasement.boardImage([], 0));
    diffuseIntensity(this.boardMat);
    const sn = new THREE.Mesh(new THREE.PlaneGeometry(bw, bh), this.neural(this.boardMat, 1.0));
    sn.name = "b1-board"; sn.position.z = 0.032;
    bezel.add(sn);
    this.facades[0].node.add(bezel);
    this.boardScreen = sn;
    OfficeBasement.mark(this.root);
    // 10-24 Kang：留言板要能點開看全部 ⇒ 螢幕也吃點擊位元（畫面的點選認 "b1-board"）
    setCategory(this.boardScreen, OfficeBasement.mask | pickMask);
  }

  /** 只吃 B1 自己的燈 */
  static mark(n) {
    if (n.isMesh || n.isLine || n.isPoints) setCategory(n, OfficeBasement.mask);
    for (const c of n.children) OfficeBasement.mark(c);
  }

  // MARK: 神經網路

  /** 換圖譜（重建 2 個 geometry：節點、邊）；空圖 ⇒ 只剩投影台。g＝NeuralGraph 或 neural-graph.js 開頭那份 JSON */
  setGraph(g) {
    if (!(g instanceof NeuralGraph)) g = NeuralGraph.fromJSON(g);
    if (this.graphNode) {
      this.graphNode.removeFromParent();
      this.graphNode.traverse(o => { o.geometry?.dispose(); o.material?.dispose?.(); });
      this.graphNode = null;
    }
    this.neuralMats = this.neuralMats.filter(([m]) => !(m.name === "neural-dots" || m.name === "neural-edges"));
    const p = g.placement({ radius: OfficeBasement.graphRadius, palette: OfficeBasement.palette.length });
    this.placement = p;
    this.graphCount = { nodes: p.dots.length, edges: p.edges.length };
    if (!p.dots.length) return;
    const n = scnNode("neural-graph");
    n.add(OfficeBasement.dotsNode(p, this.neural(named(constant(0xFFFFFF), "neural-dots"), 1.6)));
    if (p.edges.length) n.add(OfficeBasement.edgesNode(p, this.neural(named(constant(0x67E8F9, 0.38), "neural-edges"), 1.2)));
    OfficeBasement.mark(n);
    this.pivot.add(n);
    this.graphNode = n;
  }

  // MARK: 點擊（10-22 Kang：點中間那一坨神經網路 ⇒ 開 Graphify 原本的互動圖譜）

  /** 點擊判定的寬容：比圖譜半徑大一點（外圍的小節點也點得到） */
  static pickSlack = 0.35;

  /** 世界座標的射線（滑鼠那一點從近平面到遠平面；a、b＝[x,y,z] 或 THREE.Vector3）點到圖譜 ⇒ 離射線最近的節點屬於哪個專案；沒點到回 null。
   *  不在地下室、圖譜空的都回 null。射線換到圖譜轉軸自己的座標（自轉中的當下角度）再交給 NeuralPick */
  pickProject(a, b) {
    const placement = this.placement;
    if (!this.live || !placement || !placement.dots.length) return null;
    const v = q => Array.isArray(q) ? new THREE.Vector3(q[0], q[1], q[2]) : q.clone();
    this.pivot.updateWorldMatrix(true, false);
    const la = this.pivot.worldToLocal(v(a)), lb = this.pivot.worldToLocal(v(b));
    const o = [la.x, la.y, la.z], d = [lb.x - la.x, lb.y - la.y, lb.z - la.z];
    const pts = placement.dots.map(q => [q.x, q.y, q.z]);
    const i = NeuralPick.pick(pts, o, d, OfficeBasement.graphRadius + OfficeBasement.pickSlack);
    if (i === null) return null;
    const k = placement.dots[i].project;
    return k >= 0 && k < placement.projects.length ? placement.projects[k] : null;
  }

  /** 點到時閃一下：節點、邊、光圈亮度 0.08 秒拉到 2.4 倍、再 0.6 秒退回（跟著目前電力） */
  flash() {
    if (!this.graphNode) return;
    const mats = this.neuralMats.slice(), k = Math.max(0.25, this.power);
    SCNTransaction.begin(); SCNTransaction.animationDuration = 0.08;
    for (const [m, base] of mats) SCNTransaction.value(m.userData.diffInt, "value", base * k * 2.4);
    SCNTransaction.completionBlock = () => {
      queueMicrotask(() => {
        const k2 = Math.max(0.25, this.power ?? 1);      // 閃的期間停電／復電：退回時用當下電力
        SCNTransaction.begin(); SCNTransaction.animationDuration = 0.6;
        for (const [m, base] of mats) SCNTransaction.value(m.userData.diffInt, "value", base * k2);
        SCNTransaction.commit();
      });
    };
    SCNTransaction.commit();
  }

  static rgb(h) { return [((h >>> 16) & 255) / 255, ((h >>> 8) & 255) / 255, (h & 255) / 255]; }

  /** 節點：每個一顆八面體（8 面、每面 3 個頂點，面各自明暗 ⇒ 不吃燈也看得出立體），顏色＝頂點色；全部 1 個 geometry */
  static dotsNode(p, mat) {
    const N = p.dots.length;
    const pos = new Float32Array(N * 72), col = new Float32Array(N * 96), idx = new Uint32Array(N * 24);
    const ax = [[1, 0, 0], [-1, 0, 0], [0, 1, 0], [0, -1, 0], [0, 0, 1], [0, 0, -1]];
    // 8 個面：(x±, y±, z±) 各取一個；逆時針朝外
    const faces = [[0, 2, 4], [4, 2, 1], [1, 2, 5], [5, 2, 0], [4, 3, 0], [1, 3, 4], [5, 3, 1], [0, 3, 5]];
    const L = norm([0.3, 1, 0.5]);
    let pi = 0, ci = 0, ii = 0;
    for (const d of p.dots) {
      // Swift 是 Float（32 位元）：先轉成 Float32 再算，跟 Mac 的頂點一樣
      const c = [Math.fround(d.x), Math.fround(d.y), Math.fround(d.z)], s = Math.fround(d.size) / 2;
      const base = OfficeBasement.rgb(OfficeBasement.palette[d.color % OfficeBasement.palette.length]);
      for (const f of faces) {
        const a = add(c, mul(ax[f[0]], s)), b = add(c, mul(ax[f[1]], s)), e = add(c, mul(ax[f[2]], s));
        const nrm = norm(cross(sub(b, a), sub(e, a)));
        const shade = 0.62 + 0.38 * Math.max(0, dot3(nrm, L));
        const k = pi / 3;
        for (const v of [a, b, e]) {
          pos[pi++] = v[0]; pos[pi++] = v[1]; pos[pi++] = v[2];
          col[ci++] = base[0] * shade; col[ci++] = base[1] * shade; col[ci++] = base[2] * shade; col[ci++] = 1;
        }
        idx[ii++] = k; idx[ii++] = k + 1; idx[ii++] = k + 2;
      }
    }
    const g = new THREE.BufferGeometry();
    g.setAttribute("position", new THREE.BufferAttribute(pos, 3));
    g.setAttribute("color", new THREE.BufferAttribute(col, 4));
    g.setIndex(new THREE.BufferAttribute(idx, 1));
    g.computeBoundingSphere();
    mat.vertexColors = true;
    const n = new THREE.Mesh(g, mat);
    n.name = "neural-dots";
    return n;
  }

  /** 邊：所有線段一個 LineSegments（頂點＝節點中心） */
  static edgesNode(p, mat) {
    const pos = new Float32Array(p.dots.length * 3), col = new Float32Array(p.dots.length * 4).fill(1);
    p.dots.forEach((d, i) => { pos[i * 3] = d.x; pos[i * 3 + 1] = d.y; pos[i * 3 + 2] = d.z; });
    const idx = new Uint32Array(p.edges.length * 2);
    p.edges.forEach((e, i) => { idx[i * 2] = e.a; idx[i * 2 + 1] = e.b; });
    const g = new THREE.BufferGeometry();
    g.setAttribute("position", new THREE.BufferAttribute(pos, 3));
    g.setAttribute("color", new THREE.BufferAttribute(col, 4));
    g.setIndex(new THREE.BufferAttribute(idx, 1));
    g.computeBoundingSphere();
    const n = new THREE.LineSegments(g, mat);
    n.name = "neural-edges";
    n.renderOrder = 10;        // 透明的最後畫
    return n;
  }
}

// MARK: - 材質小工具

/**
 * SCNMaterial.diffuse.intensity 的替身：three 的 MeshBasic／LineBasic 沒有「diffuse 乘一個倍數」，在 shader 的 color_fragment 之後多乘 uniform。
 * 值放在 m.userData.diffInt.value（SCNTransaction.value(m.userData.diffInt, "value", x) 可以做隱式動畫）。
 */
function diffuseIntensity(m) {
  if (m.userData.diffInt) return m;
  const u = { value: 1 };
  m.userData.diffInt = u;
  // SceneKit 的 blendMode .add 實測（11-02，B1 量尺：Mac 線條像素 G 中位數 219、JS 照 alpha 混 153、不乘 alpha 216）：
  //   加法混色「不乘」transparency ⇒ src × 1 ＋ dst。three：AdditiveBlending＋premultipliedAlpha ＝ blendFunc(ONE, ONE)，
  //   再把 shader 裡的 premultiplied_alpha_fragment 拿掉（不然 rgb 又乘一次 alpha）。dump 的 key 照樣是 a0.38｜add
  const addIgnoresAlpha = m.blending === THREE.AdditiveBlending;
  if (addIgnoresAlpha) m.premultipliedAlpha = true;
  m.onBeforeCompile = sh => {
    sh.uniforms.uDiffInt = u;
    sh.fragmentShader = sh.fragmentShader.replace("void main() {", "uniform float uDiffInt;\nvoid main() {")
      .replace("#include <color_fragment>", "#include <color_fragment>\n\tdiffuseColor.rgb *= uDiffInt;");
    if (addIgnoresAlpha) sh.fragmentShader = sh.fragmentShader.replace("#include <premultiplied_alpha_fragment>", "");
  };
  m.customProgramCacheKey = () => addIgnoresAlpha ? "sw-diffint-add" : "sw-diffint";
  return m;
}

/** 自發光感的純色（不吃燈光；亮度＝diffuse 乘倍數，HDR 下超過 1 會泛光）。alpha < 1：加法混色、不寫深度 */
function constant(h, alpha = 1) {
  const m = new THREE.MeshBasicMaterial();
  m.userData.lm = "constant";
  VoxMat.color(h).toThree(m.color);
  if (alpha < 1) { m.transparent = true; m.opacity = alpha; m.blending = THREE.AdditiveBlending; m.depthWrite = false; }
  return diffuseIntensity(m);
}
/** LineSegments 要 LineBasicMaterial：把 constant() 的設定搬過去（dump 的 key 一樣） */
function named(m, s) {
  m.name = s;
  if (s === "neural-edges") {
    const l = new THREE.LineBasicMaterial({ color: m.color, transparent: m.transparent, opacity: m.opacity, blending: m.blending, depthWrite: m.depthWrite, vertexColors: true });
    l.userData.lm = "constant"; l.name = s;
    return diffuseIntensity(l);
  }
  return m;
}

function setCanvas(m, cv) {
  const old = m.map;
  const t = new THREE.CanvasTexture(cv);
  t.colorSpace = THREE.SRGBColorSpace;
  t.anisotropy = 4;
  m.map = t; m.needsUpdate = true;
  old?.dispose();
}

// MARK: - 畫字（OfficeBuilder.draw 的 canvas 版：單行、超出寬度用「…」截掉）

const FONT = (size, weight) => `${weight} ${size}px "Microsoft JhengHei UI", "Microsoft JhengHei", "PingFang TC", "Segoe UI", sans-serif`;
function draw(g, s, x, y, size, weight, color, width) {
  if (!s) return;
  g.font = FONT(size, weight); g.fillStyle = color; g.textBaseline = "top";
  g.fillText(truncate(g, s.replace(/\n/g, " "), width), x, y + size * 0.1);
}
function truncate(g, s, width) {
  if (g.measureText(s).width <= width) return s;
  const cs = Array.from(s);
  while (cs.length && g.measureText(cs.join("") + "…").width > width) cs.pop();
  return cs.join("") + "…";
}
/** 內容：換行（中文逐字、英文盡量照字），最多 lines 行，最後一行超出用「…」 */
function wrap(g, s, x, y, width, lines, size, color) {
  g.font = FONT(size, 400); g.fillStyle = color; g.textBaseline = "top";
  const out = [];
  let cur = "";
  const tokens = String(s).replace(/\n/g, " ").match(/[A-Za-z0-9_\-./:@#]+|\s+|./gu) ?? [];
  for (const t of tokens) {
    if (g.measureText(cur + t).width <= width || !cur) { cur += t; continue; }
    out.push(cur); cur = t.trimStart();
    if (out.length === lines) break;
  }
  if (out.length < lines && cur) out.push(cur);
  const truncated = out.length === lines && Array.from(out.join("")).length < Array.from(String(s).replace(/\n/g, " ")).length - 1;
  out.slice(0, lines).forEach((l, i) => {
    let t = truncate(g, l, width);
    if (i === lines - 1 && truncated && !t.endsWith("…")) {
      const cs = Array.from(l.trimEnd());
      while (cs.length && g.measureText(cs.join("") + "…").width > width) cs.pop();
      t = cs.join("") + "…";
    }
    g.fillText(t, x, y + i * size * 1.22);
  });
}
function roundRect(g, x, y, w, h, r) {
  g.beginPath();
  g.moveTo(x + r, y); g.arcTo(x + w, y, x + w, y + h, r); g.arcTo(x + w, y + h, x, y + h, r);
  g.arcTo(x, y + h, x, y, r); g.arcTo(x, y, x + w, y, r); g.closePath();
}

// MARK: - 向量、stride（Swift 的 stride(from:to:by:)／stride(from:through:by:)：浮點用 start + i·step，不累加）

const add = (a, b) => [a[0] + b[0], a[1] + b[1], a[2] + b[2]];
const sub = (a, b) => [a[0] - b[0], a[1] - b[1], a[2] - b[2]];
const mul = (a, k) => [a[0] * k, a[1] * k, a[2] * k];
const dot3 = (a, b) => a[0] * b[0] + a[1] * b[1] + a[2] * b[2];
const cross = (a, b) => [a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0]];
const norm = a => { const l = Math.hypot(a[0], a[1], a[2]); return [a[0] / l, a[1] / l, a[2] / l]; };
function strideTo(from, to, by) { const out = []; for (let i = 0; ; i++) { const v = from + i * by; if (!(v < to)) break; out.push(v); } return out; }
function strideThrough(from, through, by) { const out = []; for (let i = 0; ; i++) { const v = from + i * by; if (!(v <= through)) break; out.push(v); } return out; }

// MARK: - TowerModules.wall／glassFront（OfficeTower.swift 逐行照抄；tower.js 轉寫好之後改呼叫 TowerModules）

/** 一面牆＝一個節點（一種材質）：沿著牆排方塊，gaps＝門洞（[沿牆方向的起, 迄, 高]）；extra＝跟著這面牆一起藏的東西 */
function b1Wall(side, { h, mat, y0 = TD.room, gaps = [], name }, extra = () => {}) {
  const m = new VoxelMesh();
  extra(new Kit(m));
  const t = 0.15;
  const len = side < 2 ? TD.W : TD.D;
  let cuts = side < 2 ? [[-len / 2, len / 2]] : [[TD.zB, TD.zF]];     // 側牆沿 z：模組前緣固定、往後加深（10-22）
  for (const g of gaps) {
    cuts = cuts.flatMap(c => {
      if (g[1] <= c[0] || g[0] >= c[1]) return [c];
      return [[c[0], g[0]], [g[1], c[1]]].filter(q => q[1] - q[0] > 0.01);
    });
  }
  const put = (a, b, y, hh) => {
    const c = (a + b) / 2, l = b - a;
    switch (side) {
      case 0: m.box(Xf.identity, [c, y + hh / 2, TD.zB + t / 2], [l, hh, t], mat); break;
      case 1: m.box(Xf.identity, [c, y + hh / 2, TD.zF - t / 2], [l, hh, t], mat); break;
      case 2: m.box(Xf.identity, [-TD.W / 2 + t / 2, y + hh / 2, c], [t, hh, l], mat); break;
      default: m.box(Xf.identity, [TD.W / 2 - t / 2, y + hh / 2, c], [t, hh, l], mat);
    }
  };
  for (const c of cuts) put(c[0], c[1], y0, h);
  for (const g of gaps) if (g[2] < h) put(g[0], g[1], y0 + g[2], h - g[2]);      // 門楣
  return m.node(name);
}

/** 正面＝玻璃＋直框（每 2 公尺一支）＝一個 cutaway 節點（B1 沒有門洞） */
function b1GlassFront({ h, y0 = TD.room, alpha = 0.15, mullionsAt = [0, 1, 2, 3, 4, 5, 6].map(i => -6 + i * 2) }, extra = () => {}) {
  const m = new VoxelMesh(), k = new Kit(m);
  m.box(Xf.identity, [0, y0 + h / 2, TD.zF - 0.02], [TD.W, h, 0.02], TM.glass(alpha));
  for (const x of mullionsAt) k.b(Xf.identity, x, y0, TD.zF - 0.03, 0.05, h, 0.05, TM.f(TP.ST1));
  extra(k);
  return m.node("front");
}
