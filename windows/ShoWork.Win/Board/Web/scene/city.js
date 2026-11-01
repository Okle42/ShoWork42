// OfficeCity.swift 照搬（11-02 P8）：CityBuilder。Swift 的函式名、常數名、註解都照抄，以後 Mac 改了這裡逐行跟著改。
// 資料模型（CityState 的計算屬性、CityRules、CityText、CityBox）在 city-model.js（＝ShoWorkCore/City.swift）。
// 細節卡、懸停卡（CityCard／CityHoverCard／CityDetail／UsageBar，SwiftUI）不在這裡：Windows 的 UI 另外做。
//
// 外部空間城市的 3D（10-21）：大樓四周地面上的街區，資料來自 CityState（CitySource.swift 收集）。
//   左邊：貨櫃堆場（一個磁碟一個；層數＝已用比例；≥90% 堆到圍籬外＋倉庫頂紅燈；拔掉＝整座堆場消失（11-01））
//   右後：電廠（AI 5 小時額度）＋油槽（7 天額度）；冷卻塔 10-22 搬上頂樓
//   右邊、電廠與油槽前方的空地：分公司（ssh 伺服器；11-01 從城外搬進來）——沿電廠那條路往正門方向排一列（x 16.4，z −4.4 起每 2.8 公尺一棟，最多 4 棟），
//     門朝路、小路接上去；在線亮燈開門、離線熄燈關門
//   天上：飛艇（iCloud Drive、~/Library/CloudStorage 每個資料夾一艘）
//   城牆圍住整個街區（防火牆關＝缺口）；前牆上的城門＝對外在聽的埠（敞開的紅門＝已知沒認證的）；後牆內側一排關著的門＝只給本機的埠
//   城外（11-01 照 Windows 版）：前牆外一條馬路（z 14、寬 5：深色柏油＋白色中央虛線＋路緣白線、兩側墊高的人行道、路燈在近側人行道），
//     正門（mainGateX）出去一道斑馬線直通對街；港口（GitHub）在正門正對面——棧橋＋龍門吊對準正門，貨船往右開出港（只在水面上，不碰馬路）
//   最外圈：周邊高樓（灰色素面方塊、高低錯落；夜晚窗戶亮暖黃／冷藍）。鏡頭那側（港口右邊、預設視角鏡頭所在的右前方）留空，對街左邊只有矮樓
// 風格照大樓（規範 §1.1 色票、素色、低彩度）。省電：整個城市合併成一個 VoxelMesh（一種材質一個 draw call），
// 內容鍵（不含時間）變了才重建；周邊高樓跟資料無關、只建一次（本體 3 種灰＋亮燈的窗 2 色＝5 個 draw call；窗戶白天藏起來，日夜切換時才動）。
// 只有兩種會動：狀態剛變時的旋轉警示燈（4 秒）、出港的船（4 秒），都用 playFor，沒有常駐動畫。
//
// JS 對照：SCNVector3（point／hitCenter）→ THREE.Vector3；SIMD3 → [x, y, z]；SCNAction → actions.js 的 Act＋runAction。
// Swift 的 Float 是 32 位元：會影響「方塊有幾個」的地方（stride 的終點、周邊高樓的亂數與比較）用 Math.fround 照算，其餘用 double（差在 1e-6 以下）。

import * as THREE from "three";
import { VoxelMesh, Kit, Xf, VoxMat, TP, TD, TM, scnNode, setCategory } from "../kit.js";
import { OfficeBuilder } from "./builder.js";
import { Act, runAction, removeAction, actionForKey, setNodeOpacity } from "./actions.js";
import { CityState, CityRules, CityText, CityGrid, CityBox } from "./city-model.js";

const F = Math.fround;
/** Swift 的 stride(from:to:by:)／stride(from:through:by:)（Float：第 i 個＝start + Float(i)×step，32 位元） */
function strideF(from, end, by, through = false) {
  const out = [], a = F(from), e = F(end), s = F(by);
  for (let i = 0; i < 100000; i++) {
    const v = F(a + F(i * s));
    if (s > 0 ? (through ? v > e : v >= e) : (through ? v < e : v <= e)) break;
    out.push(v);
  }
  return out;
}
/** Swift ProcessInfo.environment：Windows 沒有 ⇒ globalThis.ShoWorkEnv 或網址參數 */
function env(k) {
  const g = globalThis.ShoWorkEnv?.[k];
  if (g !== undefined && g !== null) return String(g);
  try { return new URLSearchParams(globalThis.location?.search ?? "").get(k); } catch { return null; }
}
/** Look.reduceMotion（系統「減少動態效果」） */
const reduceMotion = () => !!globalThis.matchMedia?.("(prefers-reduced-motion: reduce)").matches;

export class CityBuilder {
  // 街區範圍（世界座標，大樓 x ±6、z ±2.8 在中間）
  static x0 = -27; static x1 = 21; static z0 = -13; static z1 = 10;
  static wallH = 1.4; static wallT = 0.5;
  /** 城外那條街（11-01 改成 Windows 版那種馬路）：中線 z、路面寬（雙向兩線道）、兩側人行道寬 */
  static streetZ = 14; static streetW = 5; static walkW = 1.2;
  /** 近側人行道（貼著前牆外側）、遠側人行道（對街、港口岸邊）的中線 */
  static get nearWalkZ() { return this.streetZ - this.streetW / 2 - this.walkW / 2; }
  static get farWalkZ() { return this.streetZ + this.streetW / 2 + this.walkW / 2; }
  static maxYards = 4; static maxGates = 8; static maxDoors = 10; static maxBranches = 4; static maxShips = 4;
  /** 大樓前那條路穿過的城門（正門）x、堆場匯流道 x（電梯井外側，看板柱再外面）、電廠中心 */
  static mainGateX = 2.0; static trunkX = -9.4;
  static powerX = 11.5; static powerZ = -7.5;
  static shipDuration = 4;
  /** 第 i 座堆場的中線 z（11-01：原本 z0＋3.5 起、每座 5.2 ⇒ 整排往馬路挪 2.1、間距縮成 4.8（圍籬之間留 0.4），後牆內側空出 3 公尺給飛艇停靠架；第 4 座前緣離前牆 0.5） */
  static yardZ(i) { return this.z0 + 5.6 + i * 4.8; }
  /** 第 i 艘飛艇停靠架的地面中心：前兩艘在後牆內側那條地（堆場後面），其餘在牆外後方 */
  static airshipDock(i) {
    return i < 2 ? [i === 0 ? -22.4 : -14.2, 0, this.z0 + this.wallT / 2 + 1.55] : [-1 + (i - 2) * 10, 0, -17];
  }
  /** 飛艇款式（11-01 Kang：原本那艘不喜歡，做幾款挑 ⇒ 選了 4 飛碟）：0 原版軟式飛艇、1 銀色硬式飛船、2 雲朵飛船、3 熱氣球、4 飛碟 */
  static airshipStyle = (() => { const v = parseInt(env("SHOWORK_CITY_AIRSHIP") ?? "", 10); return Number.isNaN(v) ? 4 : v; })();
  /** 城內地坪頂面、城內路面頂面 */
  static gy = 0.05; static ry = 0.09;
  /** BoardWindow.testMode（Mac bench／測試視窗：船定在第 1.5 秒）。Windows 沒有這個旗標 ⇒ globalThis.BoardWindow.testMode，或網頁是 bench/bench.html */
  static get testMode() {
    const t = globalThis.BoardWindow?.testMode;
    if (t !== undefined) return !!t;
    return /\/bench\/bench\.html$/.test(globalThis.location?.pathname ?? "");
  }

  constructor() {
    this.root = scnNode("city");
    this.key = "";
    this.built = false;
    this.alerting = new Set();
    this.beacons = new Map();
    this.ships = new Map();
    this.seenShips = new Set();
    /** 名牌：{ id, anchor（錨點）, text（字）, alert（是不是警示） } */
    this.labels = [];
    this.points = new Map();
    this.state = new CityState();
    this._stateSig = null;
    /** 城市外的點（頂樓冷卻水塔，OfficeBuilder 放） */
    this.extraPoints = new Map();
    this.tagged = new Map();
    this.tagFrom = null;
    this._skyline = null;
  }

  /** 城市的素色材質（10-21 主光改版，研究 R2-2-2）：原本夜晚整片自發光 0.3（像月光），把燈光算出來的明暗抹平、城市變成一塊灰板，
   *  水面還比大樓亮 ⇒ 改成日夜兩套底色、一律不發光；夜晚看得出量體靠月光＋光池＋霧。同一個白天色只對到一個材質（合併重複＝少 draw call） */
  static nightOf = new Map([
    [TP.ST2, 0x4A505A], [TP.ST1, 0x14171B], [TP.WL2, 0x59606B], [TP.FN5, 0x4A505A], [TP.POT, 0x5A606A],
    [0x8F8B85, 0x3A4250], [0x4A5A7A, 0x3A4250], [0xC98B3C, 0x5A4A30],
  ]);
  static m(h) { return VoxMat.dayNight(h, CityBuilder.nightOf.get(h) ?? h); }
  /** 路燈燈頭、起重機燈、門燈、亮著的窗：全部同一種暖光（原本 4 種強度＝4 個 draw call） */
  static get lamp() { return TM.glow(TP.LT1, 0.1, 1.3); }
  static get window() { return this.lamp; }
  /** 狀態紅（敞開的紅門、警示燈）：一種 */
  static get red() { return TM.glow(0xEF4444, 0.6, 1.8); }
  // 地面分區（研究 §4.2、R2-2-2）：城內地坪比城外亮一階（底座）、路比地坪暗一階、廣場＝大廳磨石延伸出來
  static get ground() { return VoxMat.dayNight(0xC4C0B8, 0x222A35); }
  static get road() { return VoxMat.dayNight(0x8F969D, 0x1B222C); }
  static get plaza() { return VoxMat.dayNight(TP.FL2, 0x2A323E); }
  static get walk() { return VoxMat.dayNight(0xD6D2CA, 0x2B323D); }      // 人行道
  static get pad() { return VoxMat.dayNight(TP.ST2, 0x2A3038); }         // 堆場水泥地
  static get water() { return VoxMat.dayNight(0x5E7A88, 0x0F1C26); }
  static get grass() { return VoxMat.dayNight(TP.PL2, 0x1E2A22); }
  static get leaf() { return VoxMat.dayNight(TP.PL1, 0x18241B); }
  static get trunk() { return VoxMat.dayNight(TP.FN1, 0x2A2420); }
  /** 靜態假影子（不透明的暗色扁塊；城內地坪上／城外大地面上各一種，因為底色不同） */
  static get shade() { return VoxMat.dayNight(0xA9A59D, 0x141920); }
  static get shadeOut() { return VoxMat.dayNight(0x8C9297, 0x080B10); }
  /** 夜景光池（兩層＝光暈漸層；白天跟路面同色看不出來）、水面倒影 */
  static get poolO() { return VoxMat.dayNight(0x8F969D, 0x4A4236, { glow: TP.LT1, emit: [0, 0.07] }); }
  static get poolI() { return VoxMat.dayNight(0x8F969D, 0x7A6548, { glow: TP.LT1, emit: [0, 0.16] }); }
  static get glint() { return VoxMat.dayNight(0x5E7A88, 0x6B5A44, { glow: TP.LT1, emit: [0, 0.12] }); }
  /** 疊在地坪上的扁塊的頂面高度（10-21：同一高度或只差 5 mm 遠看會閃斜條紋 ⇒ 每層至少差 1 cm）：
   *  大地面 0 → 城外街 0.04 → 城外影子 0.05 → 光池 0.05／0.06 → 城內地坪 0.05 → 路、廣場、堆場 0.09 → 城內影子 0.10 → 人行道 0.11 → 虛線 0.12 */
  static shadowIn = 0.10; static shadowOut = 0.05;

  /** 鏡頭飛過去的點 */
  point(id) { return this.points.get(id) ?? this.extraPoints.get(id) ?? null; }
  setPoint(id, p) { this.extraPoints.set(id, p); }
  /** 點擊盒中心（測試：模擬滑鼠停在建築本體上） */
  hitCenter(id) {
    const n = this.root.children.find(c => c.name === id);
    if (!n) return null;
    this.root.updateMatrixWorld(true);
    return n.getWorldPosition(new THREE.Vector3());
  }

  /** 有變才重建；回傳要播幾秒（旋轉警示燈、船）。s：mac-input.json 的 city（JSON）或 CityState */
  update(raw, animate) {
    const s = CityState.from(raw);
    const sig = JSON.stringify(s);
    if (this.built && sig === this._stateSig) return 0;          // SwiftUI 每次更新都會叫：資料沒變就什麼都不做
    this.state = s; this._stateSig = sig;
    let play = 0;
    const k = CityBuilder.key(s);
    if (k !== this.key) {
      this.key = k;
      this.rebuild(s);
      // 警示燈：只在狀態「變成」警示時轉 4 秒（第一次建好時不轉）
      const now = new Set(s.disks.filter(d => d.alert).map(d => d.id));
      if (this.built && animate && !reduceMotion()) {
        for (const id of now) if (!this.alerting.has(id)) { const b = this.beacons.get(id); if (b) { this.spin(b); play = Math.max(play, 4.2); } }
      }
      this.alerting = now;
      this.built = true;
    }
    play = Math.max(play, this.updateShips(s.ships, animate));
    return play;
  }

  /** 內容鍵：會改到幾何的才放（時間、檢查時間不放） */
  static key(s) {
    const d = s.disks.slice(0, this.maxYards).map(d => {
      const c = CityRules.containers(d.used);
      return `${d.name}|${d.mounted}|${c.count}|${c.overflow}|${d.alert}`;
    }).join(",");
    const c = s.clouds.map(c => `${c.name}|${c.known}|${c.alert}`).join(",");      // 剩多少不放（每 5 分鐘都在變，不重建）
    const v = s.servers.slice(0, this.maxBranches).map(x => `${x.alias}|${x.online === null ? "?" : x.online}`).join(",");
    const fw = s.firewall;
    const f = `${fw.enabled === null ? "?" : fw.enabled}|` + fw.gates.slice(0, this.maxGates).map(g => `${g.port}${g.openRed}`).join(",") + `|${Math.min(this.maxDoors, fw.doors.length)}`;
    const g = s.grid;
    const p = `${CityGrid.rank(g.stage)}|${g.known}|${CityRules.pct(g.fiveUsed) ?? -1}|${CityRules.pct(g.sevenUsed) ?? -1}|${g.fiveReset !== null ? Math.trunc(g.fiveReset / 60) : 0}`;
    return [d, c, v, f, p].join("#");
  }

  // MARK: 重建

  rebuild(s) {
    for (const c of [...this.root.children]) if (c.name !== "ship" && c.name !== "skyline") this.root.remove(c);
    if (!this.skyline.parent) this.root.add(this.skyline);
    this.beacons = new Map(); this.labels = []; this.points = new Map();
    const m = new VoxelMesh({ ao: 0 }), k = new Kit(m);
    if (CityBuilder.auditOn) { m.log = []; this.tagged = new Map(); }
    const C = CityBuilder;
    const road = C.road;
    const pad = C.pad;
    const lamp = C.lamp;
    const I = Xf.identity;

    // 街區地坪（城牆裡面一整片，比城外亮一階）
    const ground = C.ground;
    // 高度分層（10-21：只差 5 mm 時遠看會閃出斜條紋＝z-fighting）：大地面 0 → 城外的街 0.04 → 城內地坪 0.05 → 城內的路、堆場 0.09
    k.b(I, (C.x0 + C.x1) / 2, 0, (C.z0 + C.z1) / 2, C.x1 - C.x0, C.gy, C.z1 - C.z0, ground);
    // 大樓前廣場（10-21 主光改版：原本是一條路面；改成大廳磨石延伸出來的廣場，全城最亮的地坪＝視線落點）
    k.b(I, 0, C.gy, TD.zF + 2.2, TD.W + 8, 0.04, 4, C.plaza);
    // ── 城牆＋城門 ──
    this.buildWall(k, s.firewall);

    // ── 城外的馬路（11-01：照 Windows 版——深色路面、白色虛線分隔線、兩側墊高的人行道；正門前一道斑馬線通到對街港口）──
    this.buildStreet(k);
    // 大樓前面那條路接到城門，再穿過城門接到城外的街（10-21 稽核：原本停在牆前、城門也沒對準這條路）
    // 主路（廣場→城門）2.4 寬＋中央虛線＋兩側人行道（研究 R2-2-5 地坪分區）
    const mz0 = TD.zF + 4.2, mz1 = C.z1 - C.wallT / 2;
    k.b(I, C.mainGateX, C.gy, (mz0 + mz1) / 2, 2.4, 0.04, mz1 - mz0, road);
    for (const z of strideF(mz0 + 0.3, mz1 - 0.6, 2.4)) k.b(I, C.mainGateX, 0.10, z + 0.6, 0.06, 0.01, 1.2, C.m(TP.FN5));
    for (const sg of [-1, 1]) k.b(I, C.mainGateX + sg * 1.5, C.gy, (mz0 + mz1) / 2, 0.6, 0.06, mz1 - mz0, C.walk);
    // 堆場那幾條路的匯流道：沿電梯井外側（x −9.4）接到大樓前廣場（10-21 稽核：原本每條路停在大樓左後方的空地上，哪裡都沒接到）
    if (s.disks.length) {
      const zTop = C.yardZ(0) - 0.55, zEnd = TD.zF + 0.2;
      k.b(I, C.trunkX, C.gy, (zTop + zEnd) / 2, 1.1, 0.04, zEnd - zTop, road);
    }
    // 電廠的路：廣場右端 → 電廠正門（10-21 稽核：電廠原本沒有門也沒有路）
    k.b(I, C.powerX, C.gy, (C.powerZ + 1.5 + TD.zF + 1.3) / 2, 1.1, 0.04, TD.zF + 1.3 - C.powerZ - 1.5, road);
    const laneEnd = s.servers.length === 0 ? C.powerX + 0.55 : C.laneX1;     // 有分公司：這段支路往右延伸成巷子（分公司門口都接到這裡）
    k.b(I, (TD.W / 2 + 4 + laneEnd) / 2, C.gy, C.laneZ, laneEnd - TD.W / 2 - 4, 0.04, 1.1, road);

    // ── 貨櫃堆場（左邊，一個磁碟一個）──
    s.disks.slice(0, C.maxYards).forEach((d, i) => {
      const zc = C.yardZ(i);
      this.buildYard(k, d, zc, road, pad, lamp);
    });

    // ── 電廠（右後）──
    this.buildPower(k, s.grid);

    // ── 分公司（11-01 搬進圍牆內：電廠、油槽前方的空地，沿電廠那條路排一列，門朝路）──
    s.servers.slice(0, C.maxBranches).forEach((sv, i) => this.buildBranch(k, sv, C.branchPos(i), road));

    // ── 港口（11-01：正門出去、馬路正對面）──
    this.buildPort(k, s);

    // ── 飛艇（11-01 Kang：搬進圍牆內——堆場往馬路挪，後牆內側空出一條地，前兩艘連停靠架停在這裡；第 3 艘起仍在牆外後方）──
    s.clouds.slice(0, 4).forEach((c, i) => this.buildAirship(k, c, C.airshipDock(i)));

    // 路燈（夜晚的城市才看得到路）：10-21 稽核：原本固定每 6 公尺一支，剛好立在城門正前方擋住出入口 ⇒ 離任何開口 1 公尺內的往旁邊挪
    const gaps = C.openings(s.firewall);
    const lamps = [];
    for (const x0 of strideF(C.x0 + 3, C.x1 + 5, 6, true)) {
      // 往兩邊找最近一個「離開口 1 公尺以上、離上一支路燈 2 公尺以上」的位置；找不到就不放
      const ok = x => !gaps.some(g => x > F(g[0] - 1.0) && x < F(g[1] + 1.0)) && !lamps.some(l => Math.abs(F(l - x)) < 2);
      let x = null;
      for (const dd of strideF(0, 6, 0.2, true)) {
        const a = F(x0 + dd), b = F(x0 - dd);
        if (ok(a)) { x = a; break; }
        if (ok(b)) { x = b; break; }
      }
      if (x === null) continue;
      lamps.push(x);
      // 立在近側人行道上（人行道頂 0.12），燈頭伸到路面上方一點；光池落在近側車道
      const lz = C.nearWalkZ + 0.15;
      k.b(I, x, C.walkTop, lz, 0.08, 1.9, 0.08, C.m(TP.ST1));
      k.b(I, x, C.walkTop + 1.9, lz + 0.25, 0.26, 0.1, 0.6, lamp);
      this.pool(k, x, C.streetZ - C.streetW / 2 + 0.95, 0.056, 2.6, 1.8, true);
    }
    // 主路上一盞（城門內側）：夜景的視線路徑＝城外大街一串光點 → 城門 → 主路 → 廣場 → 大樓（研究 R2-4 光島）
    const mlz = C.z1 - C.wallT / 2 - 0.75;
    k.b(I, C.mainGateX + 1.5, C.gy, mlz, 0.08, 1.8, 0.08, C.m(TP.ST1));
    k.b(I, C.mainGateX + 1.5, C.gy + 1.8, mlz, 0.26, 0.1, 0.26, lamp);
    this.pool(k, C.mainGateX, mlz, 0.105, 2.3, 1.2);

    // ── 行道樹＋草地（研究 §4.3：群組、留白；只放秩序類裝飾）──
    this.buildGreen(k, gaps);
    // ── 靜態假影子（太陽不動 ⇒ 影子不動；往背光方向的扁平暗塊，不開即時陰影）──
    this.buildShadows(k, s);

    if (CityBuilder.auditOn && m.log) this.audit(m.log);
    const cn = m.node("city-static"); setCategory(cn, OfficeBuilder.outdoorMask);
    this.root.add(cn); this.root.children.unshift(this.root.children.pop());     // insertChildNode(cn, at: 0)
  }

  // MARK: 穿插稽核（10-21：堆場旁一坨歪斜貨櫃互相插進對方）

  /** SHOWORK_CITY_AUDIT=1：重建時把「轉了角度的方塊」和「貨櫃、警示燈、起重機」跟城市裡每個方塊比一次，插進去超過 1 公分就印出來 */
  static auditOn = env("SHOWORK_CITY_AUDIT") !== null;
  /** 從現在起加的方塊都標成 tag（稽核用；沒開稽核什麼都不做） */
  tag(k, name) {
    if (!CityBuilder.auditOn) return;
    if (this.tagFrom) { const [i0, t] = this.tagFrom; for (let i = i0; i < (k.m.log?.length ?? i0); i++) this.tagged.set(i, t); }
    this.tagFrom = name !== null ? [k.m.log?.length ?? 0, name] : null;
  }
  audit(log) {
    let hits = 0, checked = 0;
    const f2 = x => x.toFixed(2);
    log.forEach((a, i) => {
      if (!(CityBox.rotated(a) || this.tagged.has(i))) return;
      checked += 1;
      log.forEach((b, j) => {
        if (j === i) return;
        // 同一組零件（同一台起重機、同一個警示燈）彼此不比；兩個都要檢查的只印一次
        const ta = this.tagged.get(i), tb = this.tagged.get(j);
        if (ta !== undefined && tb !== undefined && ta === tb && !ta.startsWith("container")) return;
        if ((CityBox.rotated(b) || tb !== undefined) && j < i) return;
        // 扁平地坪（<3 cm 厚）是鋪在地上的，不算
        if (b.size[1] < 0.03 || a.size[1] < 0.03) return;
        const p = CityBox.penetration(a, b);
        if (p > 0.01) {
          hits += 1;
          console.log(`city audit 穿插 ${f2(p)}m  ${ta ?? "rotated"} @(${a.center.map(f2).join(",")}) ${a.size.map(f2).join("x")} a=${f2(a.yaw)}  ↔  ` +
                      `${tb ?? (CityBox.rotated(b) ? "rotated" : "box")} @(${b.center.map(f2).join(",")}) ${b.size.map(f2).join("x")} a=${f2(b.yaw)}`);
        }
      });
    });
    console.log(`city audit 檢查 ${checked} 個方塊（轉角度的 ${log.filter(b => CityBox.rotated(b)).length} 個）對全部 ${log.length} 個：穿插 ${hits} 處`);
  }

  // MARK: 光池、樹、影子（10-21 主光改版）

  /** 路燈底下的兩層光池（外層暗、內層亮＝體素風的光暈；白天跟路面同色） */
  pool(k, x, z, top, w, d, street = false) {
    const C = CityBuilder, I = Xf.identity;
    k.b(I, x, top - 0.006, z, w, 0.006, d, street ? C.streetPoolO : C.poolO);
    k.b(I, x, top + 0.004, z, w * 0.46, 0.006, d * 0.55, street ? C.streetPoolI : C.poolI);
  }

  tree(k, x, z, base, s = 1, out = false) {
    const C = CityBuilder, I = Xf.identity;
    k.b(I, x, base, z, 0.14, 0.9 * s, 0.14, C.trunk);
    k.b(I, x, base + 0.9 * s, z, 0.9 * s, 0.8 * s, 0.9 * s, C.leaf);
    k.b(I, x + 0.1 * s, base + 1.7 * s, z - 0.05, 0.55 * s, 0.4 * s, 0.55 * s, C.grass);
    this.shadow(k, x, z, 0.9 * s, 0.9 * s, base + 1.7 * s, out);
  }

  buildGreen(k, gaps) {
    const C = CityBuilder, I = Xf.identity;
    const gtop = 0.11;
    // 城門內側那一帶（廣場前、城牆前）：每 3 公尺一棵，避開主路、所有城門／缺口
    const fz = C.z1 - C.wallT / 2 - 1.3;
    for (const x of strideF(-10, 19, 3, true)) {
      if (!(Math.abs(x - C.mainGateX) > 2.7 && !gaps.some(g => x > F(g[0] - 1.1) && x < F(g[1] + 1.1)))) continue;
      k.b(I, x, C.gy, fz, 1.3, gtop - C.gy, 1.3, C.grass);
      this.tree(k, x, fz, gtop);
    }
    // 後牆內側兩條草地帶，樹三棵一組（中間留空）；避開堆場、後牆的門、電廠
    const bz = C.z0 + C.wallT / 2 + 0.7;
    // 11-01：左段讓給飛艇停靠架（原本從 −13 起）
    for (const [a, b, trees] of [[-9.0, -4.2, [-8.2, -6.6, -5.6]], [11.6, 20.3, [12.4, 13.4, 19.4]]]) {
      k.b(I, (a + b) / 2, C.gy, bz, b - a, gtop - C.gy, 1.2, C.grass);
      for (const x of trees) this.tree(k, x, bz, gtop, 0.9);
    }
    // 城外對街（港口左邊）：遠側人行道上一排行道樹（11-01：分公司搬進城內，這段只剩樹）
    for (const x of strideF(-24, C.harborX0 - 2, 5, true)) this.tree(k, x, C.farWalkZ + 0.1, C.walkTop, 0.9, true);
  }

  // MARK: 馬路（11-01，照 Windows 版 office.js buildCity：路面 #4A4F55、白色虛線 #E8E4D8、人行道 #B9B4AA）

  /** 人行道頂面（比路面高一階＝路緣石）；虛線、斑馬線的頂面 */
  static walkTop = 0.12; static markTop = 0.07;
  static get asphalt() { return VoxMat.dayNight(0x4A4F55, 0x14181E); }
  static get marking() { return VoxMat.dayNight(0xE8E4D8, 0x8C9096); }
  static get curbWalk() { return VoxMat.dayNight(0xB9B4AA, 0x2E353F); }
  /** 馬路上的光池：白天跟柏油同色（看不出來）、夜晚比柏油亮一點點的暖色（原本的光池底色是淺色路面，放在深色柏油上變成一塊塊地毯） */
  static get streetPoolO() { return VoxMat.dayNight(0x4A4F55, 0x1D1E1F, { glow: TP.LT1, emit: [0, 0.015] }); }
  static get streetPoolI() { return VoxMat.dayNight(0x4A4F55, 0x2B2822, { glow: TP.LT1, emit: [0, 0.04] }); }
  /** 馬路東西兩端：一路延伸到霧裡（11-01 Kang：原本 −64～68，拉遠看得到路的盡頭、短短一條很假；霧最遠 230 起跳，±420 一定看不到頭） */
  static streetX0 = -420; static streetX1 = 420;

  buildStreet(k) {
    const C = CityBuilder, I = Xf.identity;
    const len = C.streetX1 - C.streetX0, cx = (C.streetX0 + C.streetX1) / 2;
    const sz = C.streetZ, half = C.streetW / 2;
    // 路面
    k.b(I, cx, 0, sz, len, 0.04, C.streetW, C.asphalt);
    // 中央白色虛線（2.4 長、間隔 6；正門前的斑馬線那段不畫）
    const gx = C.mainGateX, zebra = 1.6;
    for (let i = Math.trunc((C.streetX0 - gx) / 6); i <= Math.trunc((C.streetX1 - gx) / 6); i++) {
      const x = gx + i * 6 + 3;
      if (!(Math.abs(x - gx) > zebra + 1.4 && x - 1.2 > C.streetX0 && x + 1.2 < C.streetX1)) continue;
      k.b(I, x, C.markTop - 0.01, sz, 2.4, 0.01, 0.15, C.marking);
    }
    // 兩側路緣的白色實線（離路緣 0.3）
    for (const sg of [-1, 1]) k.b(I, cx, C.markTop - 0.01, sz + sg * (half - 0.3), len, 0.01, 0.1, C.marking);
    // 斑馬線：正門出來直接過馬路到對街港口（條紋沿路的方向排、每條 0.45 寬）
    for (let i = 0; i < 6; i++) k.b(I, gx + (i - 2.5) * 0.6, C.markTop - 0.01, sz, 0.42, 0.01, C.streetW - 1.0, C.marking);
    // 兩側人行道（墊高 0.12）
    for (const z of [C.nearWalkZ, C.farWalkZ]) k.b(I, cx, 0, z, len, C.walkTop, C.walkW, C.curbWalk);
    // 正門出去的車道：穿過城門、壓過近側人行道接到路面（頂面比人行道高 5 mm＝斜坡口）
    const wz = C.z1 + C.wallT / 2;
    k.b(I, gx, C.gy, (C.z1 - C.wallT / 2 + wz) / 2, C.gateW, 0.04, C.wallT, C.road);
    k.b(I, gx, 0, C.nearWalkZ, 2.4, C.walkTop + 0.005, C.walkW, C.road);
  }

  /** 一塊影子：底面 w×d、高 h 的東西，往太陽光的水平方向延伸 h×(0.58, −0.48)（高度上限 4.5 m：大樓 20 m 不能蓋掉半個城）。
   *  城內的貼在城內地坪上方（只留在城牆內）；out＝城外大地面上。clip：{lo:[x,z], hi:[x,z]} */
  shadow(k, x, z, w, d, h, out = false, clip = null) {
    const C = CityBuilder;
    const st = OfficeBuilder.shadowStep, hh = Math.min(h, 4.5), o = [st[0] * hh, st[1] * hh];
    let lo = [Math.min(x - w / 2, x - w / 2 + o[0]), Math.min(z - d / 2, z - d / 2 + o[1])];
    let hi = [Math.max(x + w / 2, x + w / 2 + o[0]), Math.max(z + d / 2, z + d / 2 + o[1])];
    const c = clip ?? (out ? null : { lo: [C.x0 + C.wallT / 2, C.z0 + C.wallT / 2], hi: [C.x1 - C.wallT / 2, C.z1 - C.wallT / 2] });
    if (c) { lo = [Math.max(lo[0], c.lo[0]), Math.max(lo[1], c.lo[1])]; hi = [Math.min(hi[0], c.hi[0]), Math.min(hi[1], c.hi[1])]; }
    if (!(hi[0] - lo[0] > 0.05 && hi[1] - lo[1] > 0.05)) return;
    const top = out ? C.shadowOut : C.shadowIn;
    k.b(Xf.identity, (lo[0] + hi[0]) / 2, top - 0.006, (lo[1] + hi[1]) / 2, hi[0] - lo[0], 0.006, hi[1] - lo[1], out ? C.shadeOut : C.shade);
  }

  buildShadows(k, s) {
    const C = CityBuilder;
    // 大樓
    this.shadow(k, 0, TD.zC, TD.W, TD.D, 4.5);
    // 城牆：前牆（影子往城內）、左牆（往城內）；後牆、右牆的影子落在城外
    const h = C.wallH, t = C.wallT;
    let x = C.x0;
    for (const o of C.openings(s.firewall)) {
      if (o[0] > x) this.shadow(k, (x + o[0]) / 2, C.z1, o[0] - x, t, h);
      x = Math.max(x, o[1]);
    }
    if (C.x1 > x) this.shadow(k, (x + C.x1) / 2, C.z1, C.x1 - x, t, h);
    this.shadow(k, C.x0, (C.z0 + C.z1) / 2, t, C.z1 - C.z0, h);
    const far = 50;
    this.shadow(k, (C.x0 + C.x1) / 2, C.z0, C.x1 - C.x0, t, h, true, { lo: [-far, -far], hi: [far, C.z0 - t / 2] });
    this.shadow(k, C.x1, (C.z0 + C.z1) / 2, t, C.z1 - C.z0, h, true, { lo: [C.x1 + t / 2, -far], hi: [far, far] });
    // 堆場：倉庫＋整堆貨櫃（一塊）
    s.disks.slice(0, C.maxYards).forEach((d, i) => {
      const zc = C.yardZ(i);
      this.shadow(k, -22.6, zc, 2.8, 3.6, 2.78);
      const c = CityRules.containers(d.used);
      if (c.count > 0) {
        const rows = Math.min(4, Math.trunc((Math.min(c.count, CityRules.perLevel) + 2) / 3));
        this.shadow(k, -18.75, zc - 1.45 + (rows - 1) * 0.485, 4.8, rows * 0.97, C.ry + c.levels * 0.72);
      }
      const slots = C.overflowSlots(c.overflow, zc);
      for (const p of slots) {
        if (p[1] !== 0) continue;
        const stacked = slots.some(q => q[0] === p[0] && q[2] === p[2] && q[1] > 0);
        this.shadow(k, p[0], p[2], 1.5, 0.92, C.gy + (stacked ? 1.44 : 0.72));
      }
    });
    // 電廠、冷卻塔
    this.shadow(k, C.powerX, C.powerZ, 4.4, 3.2, 2.76);
    this.shadow(k, C.fuelX, C.fuelZ, 3.6, 3.6, 3.3);
    // 分公司（城內，電廠前）
    for (let i = 0; i < Math.min(C.maxBranches, s.servers.length); i++) { const p = C.branchPos(i); this.shadow(k, p.x, p.z, C.branchW + 0.2, C.branchD + 0.2, C.branchH + 0.16); }
  }

  /** 點擊盒的材質：SCNBox 預設材質（blinn、白色）；整個藏起來不畫 */
  static hitMat = (() => { const m = new THREE.MeshPhongMaterial({ color: 0xffffff }); m.userData.lm = "blinn"; return m; })();

  label(id, p, text, alert, hit = null) {
    const a = scnNode("anchor"); a.position.set(p[0], p[1], p[2]);
    this.root.add(a);
    this.labels.push({ id, anchor: a, text, alert });
    this.points.set(id, new THREE.Vector3(p[0], p[1] - 1.2, p[2]));
    // 點擊盒：不畫（visible＝false），raycast 照樣找得到（three 的 Raycaster 不看 visible）
    if (hit) {
      const [c, sz] = hit;
      const n = new THREE.Mesh(new THREE.BoxGeometry(sz[0], sz[1], sz[2]), CityBuilder.hitMat);
      n.name = id; n.position.set(c[0], c[1], c[2]); n.visible = false;
      setCategory(n, 1 | OfficeBuilder.pickMask);
      this.root.add(n);
    }
  }

  // MARK: 城牆

  static gateW = 1.6; static gateStep = 2.6;
  /** 第 i 個城門的 x：第 0 個是正門（對準大樓前那條路），之後左右交替往外排（10-21 稽核：原本整排置中，8 個門時路剛好撞在兩門之間的牆上） */
  static gateX(i) { return i === 0 ? F(this.mainGateX) : F(F(this.mainGateX) + F(F(Math.trunc((i + 1) / 2) * F(this.gateStep)) * (i % 2 === 1 ? -1 : 1))); }
  /** 前牆所有開口（城門＋防火牆關的缺口）；沒有對外的埠時正門還在（關著），一樣算開口位置。回傳 [[左, 右], …] */
  static openings(f) {
    const n = Math.max(1, Math.min(this.maxGates, f.gates.length));
    const hw = F(this.gateW / 2);
    const o = Array.from({ length: n }, (_, i) => [F(this.gateX(i) - hw), F(this.gateX(i) + hw)]);
    if (f.enabled === false) o.push([-20, -14.5]);
    return o.sort((a, b) => a[0] - b[0]);
  }

  buildWall(k, f) {
    const C = CityBuilder, I = Xf.identity;
    const wall = C.m(TP.ST2), cap = C.m(TP.ST1);
    const h = C.wallH, t = C.wallT;
    const gates = f.gates.slice(0, C.maxGates);
    const gw = C.gateW;
    // 10-22 Kang 截圖「一堆破圖」：牆段端面跟門柱內側在同一個平面（x＝門寬/2），兩面搶深度、斜看會出鋸齒 ⇒ 牆段縮進門柱裡 10 公分
    const openings = C.openings(f).map(o => [o[0] - 0.1, o[1] + 0.1]);
    const breach = f.enabled === false ? [-20, -14.5] : null;
    // 前牆分段
    let x = C.x0;
    for (const o of openings) {
      if (o[0] > x) { k.b(I, (x + o[0]) / 2, 0, C.z1, o[0] - x, h, t, wall); k.b(I, (x + o[0]) / 2, h, C.z1, o[0] - x, 0.08, t + 0.06, cap); }
      x = Math.max(x, o[1]);
    }
    if (C.x1 > x) { k.b(I, (x + C.x1) / 2, 0, C.z1, C.x1 - x, h, t, wall); k.b(I, (x + C.x1) / 2, h, C.z1, C.x1 - x, 0.08, t + 0.06, cap); }
    // 後牆、左右牆
    const W = C.x1 - C.x0, D = C.z1 - C.z0;
    k.b(I, (C.x0 + C.x1) / 2, 0, C.z0, W, h, t, wall); k.b(I, (C.x0 + C.x1) / 2, h, C.z0, W, 0.08, t + 0.06, cap);
    for (const xx of [C.x0, C.x1]) {
      k.b(I, xx, 0, (C.z0 + C.z1) / 2, t, h, D, wall); k.b(I, xx, h, (C.z0 + C.z1) / 2, t + 0.06, 0.08, D, cap);
    }
    // 角樓
    for (const xx of [C.x0, C.x1]) for (const zz of [C.z0, C.z1]) { k.b(I, xx, 0, zz, 1.1, h + 0.7, 1.1, wall); k.b(I, xx, h + 0.7, zz, 1.2, 0.1, 1.2, cap); }
    if (breach) {
      // 碎塊（10-21：原本 7 塊隨機角度、隨機大小，相鄰的會互相插進去 ⇒ 方正、對齊、彼此留縫，只是高低不一，看得出是倒掉的牆）
      const hs = [0.35, 0.22, 0.5, 0.28, 0.42, 0.2, 0.32];
      const step = (breach[1] - breach[0] - 0.8) / 6;
      for (let i = 0; i < 7; i++) {
        const xx = breach[0] + 0.4 + i * step;
        k.b(I, xx, 0, C.z1 + (i % 2 === 0 ? 0.12 : -0.12), Math.min(0.6, step - 0.1), hs[i], 0.45, wall);
      }
    }
    // 城門：門柱＋門楣；敞開的紅門＝紅色門框（夜晚發光）
    const red = C.red;
    if (gates.length === 0) {
      // 沒有對外在聽的埠：正門關著（門框＋兩扇關上的門板）
      const xc = C.mainGateX;
      for (const dx of [-gw / 2 - 0.15, gw / 2 + 0.15]) k.b(I, xc + dx, 0, C.z1, 0.3, h + 0.8, t + 0.2, cap);
      k.b(I, xc, h + 0.6, C.z1, gw + 0.6, 0.25, t + 0.2, cap);
      k.b(I, xc, 0, C.z1, gw, h, 0.1, TM.f(TP.FN3));
    }
    gates.forEach((g, i) => {
      const xc = C.gateX(i);
      const fm = g.openRed ? red : cap;
      for (const dx of [-gw / 2 - 0.15, gw / 2 + 0.15]) k.b(I, xc + dx, 0, C.z1, 0.3, h + 0.8, t + 0.2, fm);
      k.b(I, xc, h + 0.6, C.z1, gw + 0.6, 0.25, t + 0.2, fm);
      if (g.openRed) {
        // 兩扇門板往外敞開成 90°（10-21 第二輪稽核：原本轉 1.2 弧度，門板插進旁邊的牆 4 cm ⇒ 方正擺：貼著門柱內側、垂直牆面往外伸）
        for (const sg of [-1, 1]) k.b(I, xc + sg * (gw / 2 - 0.04), 0, C.z1 + 0.35 + gw / 4, 0.08, h, gw / 2, red);
        this.label(`city:gate:${g.port}`, [xc, h + 1.6, C.z1], CityText.gate(g), true, [[xc, 1, C.z1], [gw + 0.8, 2.4, 1.4]]);
      }
    });
    // 城內關著的門（只給本機的埠）：後牆內側一排
    for (let i = 0; i < Math.min(C.maxDoors, f.doors.length); i++) {
      const xx = -3 + i * 1.5;
      k.b(I, xx, 0, C.z0 + t / 2 + 0.05, 0.9, 1.15, 0.08, TM.f(TP.FN3));
      k.b(I, xx, 1.15, C.z0 + t / 2 + 0.05, 1.05, 0.1, 0.12, cap);
    }
    const wallAlert = f.enabled === false;
    const lx = breach ? (breach[0] + breach[1]) / 2 : -10;
    this.label("city:wall", [lx, h + 1.4, C.z1], CityText.wall(f), wallAlert, [[lx, h / 2, C.z1], [6, h + 1, 1.2]]);
  }

  // MARK: 貨櫃堆場

  /** 貨櫃 4 色（10-21 主光改版 R2-2-2／5-7：拿掉酒紅、帳綠、青綠——撞「警示紅／完成綠」；琥珀只佔 1/6 當唯一強調） */
  static containerColors = [TP.ST2, 0x8F8B85, 0x4A5A7A, 0x8F8B85, TP.ST2, 0xC98B3C];

  buildYard(k, d, zc, road, pad, lamp) {
    const C = CityBuilder, I = Xf.identity;
    const xL = -24, xR = -14;            // 堆場範圍
    const depth = 4.4;
    k.b(I, (xL + xR) / 2, C.gy, zc, xR - xL, 0.04, depth, pad);
    // 圍籬（細柱＋兩條橫桿；靠大樓那側留出入口）
    const post = C.m(TP.ST1);
    for (const x of strideF(xL, xR, 1.25, true)) {
      for (const z of [zc - depth / 2, zc + depth / 2]) k.b(I, x, 0, z, 0.06, 1.0, 0.06, post);
    }
    for (const z of [zc - depth / 2, zc + depth / 2]) for (const y of [0.45, 0.95]) k.b(I, (xL + xR) / 2, y, z, xR - xL, 0.04, 0.04, post);
    for (const z of strideF(F(zc) - F(depth / 2), F(zc) + F(depth / 2), 1.1, true)) k.b(I, xR, 0, z, 0.06, 1.0, 0.06, post);
    for (const y of [0.45, 0.95]) {
      k.b(I, xR, y, zc - depth / 2 + 0.6, 0.04, 0.04, 1.2, post); k.b(I, xR, y, zc + depth / 2 - 0.6, 0.04, 0.04, 1.2, post);
    }
    // 倉庫（左端；鐵捲門朝大樓）
    const wx = -22.6;
    k.b(I, wx, 0, zc, 2.6, 2.6, 3.4, C.m(TP.WL2));
    k.b(I, wx, 2.6, zc, 2.8, 0.18, 3.6, C.m(TP.ST2));
    const doorX = wx + 1.31;
    if (d.mounted) {
      k.b(I, doorX, 0, zc, 0.04, 1.9, 1.8, TM.f(TP.FN6));              // 開著：裡面暗
      k.b(I, doorX, 1.75, zc, 0.12, 0.2, 1.9, C.m(TP.ST2));           // 捲起來的門
      k.b(I, doorX + 0.06, 2.05, zc, 0.08, 0.08, 0.5, lamp);          // 門燈（10-21 稽核：原本凸出 0.1 插進第 3 層貨櫃 2 cm）
    } else {
      for (let i = 0; i < 9; i++) k.b(I, doorX, i * 0.21, zc, 0.06, 0.2, 1.9, C.m(i % 2 === 0 ? TP.ST2 : 0x8F8B85));   // 鐵捲門拉下
    }
    // 貨櫃：一層 3×4、最多 4 層；顏色依磁碟名固定
    const c = CityRules.containers(d.used);
    let seed = 5;
    for (const ch of d.name) seed = (Math.imul(seed, 31) + ch.codePointAt(0)) >>> 0;
    const cw = 1.5, ch = 0.72, cd = 0.92;
    this.tag(k, "container");
    for (let n = 0; n < c.count; n++) {
      const lv = Math.trunc(n / CityRules.perLevel), j = n % CityRules.perLevel;
      const col = j % 3, row = Math.trunc(j / 3);
      const x = -20.4 + col * 1.65, z = zc - 1.45 + row * 0.97;
      const h = C.containerColors[((seed + n * 7) >>> 0) % C.containerColors.length];
      k.b(I, x, C.ry + lv * ch, z, cw, ch - 0.04, cd, C.m(h));
    }
    // 圍籬外的貨櫃（≥90%，堆場放不下溢出來）：10-21 第二輪：原本歪斜亂放、互相插進去像破圖 ⇒
    // 整齊排在出口那條路兩側（貼著路、對齊格線、彼此留 0.1 縫），一側兩個、再多就疊第二層
    C.overflowSlots(c.overflow, zc).forEach((p, n) => {
      k.b(I, p[0], C.gy + p[1], p[2], cw, ch - 0.04, cd, C.m(C.containerColors[(n + 2) % C.containerColors.length]));
    });
    this.tag(k, null);
    // 路：堆場入口 → 大樓左邊（電梯井外）；拔掉＝中間斷一截
    const ra = -13.94, rb = C.trunkX + 0.55;
    if (d.mounted) {
      k.b(I, (ra + rb) / 2, C.gy, zc, rb - ra, 0.04, 1.1, road);
    } else {
      k.b(I, ra + 0.9, C.gy, zc, 1.8, 0.04, 1.1, road); k.b(I, rb - 1.0, C.gy, zc, 2.0, 0.04, 1.1, road);
      k.b(I, ra + 2.1, C.gy, zc - 0.2, 0.45, 0.1, 0.3, road);       // 斷口碎塊（10-21 第二輪：方正擺，不歪）
    }
    // 警示燈：倉庫頂；≥90% 紅燈（靜態發光），狀態剛變時轉 4 秒
    const top = Math.max(2.8, C.ry + c.levels * ch);
    if (d.alert) {
      // 警示燈（10-21 第二輪：原本紅方塊＋一根橫桿＝遠看像十字架 ⇒ 改成屋頂上的旋轉警示燈：深色底座＋紅燈罩＋深色燈帽，沒有任何伸出去的桿子）
      const b = scnNode(); b.position.set(wx, 2.78, zc);
      const mm = new VoxelMesh(), kk = new Kit(mm), red = C.red, dark = C.m(TP.ST1);
      kk.b(I, 0, 0, 0, 0.5, 0.08, 0.5, dark);            // 底座
      kk.b(I, 0, 0.08, 0, 0.34, 0.3, 0.34, red);         // 燈罩
      kk.b(I, 0, 0.38, 0, 0.4, 0.06, 0.4, dark);         // 燈帽
      const bn = mm.node("beacon"); setCategory(bn, OfficeBuilder.outdoorMask);
      b.add(bn);
      this.root.add(b);
      this.beacons.set(d.id, b);
      if (CityBuilder.auditOn && k.m.log) {      // 稽核：警示燈是另一個節點，外框記進城市的紀錄一起比（不畫）
        k.m.log.push({ center: [wx, 2.78 + 0.22, zc], size: [0.5, 0.44, 0.5], yaw: 0 }); this.tagged.set(k.m.log.length - 1, "beacon");
      }
    }
    this.label(d.id, [-19, top + 1.0, zc], CityText.disk(d), d.alert, [[-19, 1.4, zc], [xR - xL, 3.0, depth]]);
  }

  /** 圍籬外溢出貨櫃的位置（底面中心 [x, 離地高, z]）：出口那條路兩側各一排，每排兩個（x −13.05／−11.45，留 0.1 縫），超過 4 個疊第二層。
   *  路寬 1.1（zc±0.55）⇒ 貨櫃內緣離路 0.15；圍籬在 x −14、匯流道在 x −9.95 以東，都碰不到 */
  static overflowSlots(n, zc) {
    const xs = [-13.05, -11.45], dz = 0.55 + 0.15 + 0.46, ch = 0.72;
    return Array.from({ length: Math.max(0, Math.min(n, 8)) }, (_, i) => {
      const side = i % 2 === 0 ? -1 : 1, col = Math.trunc(i / 2) % 2, lv = Math.trunc(i / 4);
      return [xs[col], lv * ch, zc + side * dz];
    });
  }

  /** 狀態剛變成警示：燈罩閃 4 秒（10-21 第二輪：原本整個轉，燈改成方正的之後轉起來看不出來） */
  spin(b) {
    removeAction(b, "spin");
    const blink = Act.sequence([Act.fadeOpacity(0.25, 0.25), Act.fadeOpacity(1, 0.25)]);
    runAction(b, Act.repeat(blink, 8), "spin");
  }

  // MARK: 電廠

  /** 號誌燈（電廠屋頂、電表、逃生燈）：自己做的材質、不登記到 VoxMat 的發光清單 ⇒ 停電把燈全關時它照樣亮。
   *  SceneKit .constant＋emission 1.4 ⇒ MeshBasicMaterial，emission 記在 userData（dump 照抄） */
  static signals = new Map();
  static signal(h) {
    const hit = this.signals.get(h);
    if (hit) return hit;
    const m = new THREE.MeshBasicMaterial();
    VoxMat.color(h).toThree(m.color);
    m.userData.lm = "constant";
    m.userData.emission = { color: VoxMat.color(h), intensity: 1.4 };
    m.name = `signal:${h.toString(16)}`;
    this.signals.set(h, m);
    return m;
  }
  static stageColor(s) {
    switch (s) { case "normal": return 0x22C55E; case "dim": return 0xF59E0B; default: return 0xEF4444; }
  }
  /** 油槽中心（原本冷卻塔的位置；冷卻塔 10-22 搬上頂樓） */
  static fuelX = 16.8; static fuelZ = -7.8;
  /** 輸電線（10-22 Kang：走最短路徑）：電廠左牆 → 大樓右牆，一條直線（z −6.4、離地 1.6）；上面有光點一顆顆往大樓流＝電力輸入 */
  static wireZ = -6.4; static wireY = 1.6;
  static get wireX0() { return this.powerX - 2.1; }            // 電廠左牆
  static get wireX1() { return TD.W / 2; }                     // 大樓右牆

  // 10-22 Kang 拍板：電廠＝AI 額度。5 小時額度＝電力（電表＋屋頂號誌燈；用完＝停電），7 天額度＝油槽液位
  buildPower(k, g) {
    const C = CityBuilder, I = Xf.identity;
    const bx = C.powerX, bz = C.powerZ;
    const out = g.stage === "blackout";
    k.b(I, bx, 0, bz, 4.2, 2.6, 3.0, C.m(TP.WL2));
    k.b(I, bx, 0, bz + 1.51, 1.0, 1.7, 0.04, TM.f(TP.FN6));          // 正門（朝大樓，路接到這裡）
    k.b(I, bx, 2.6, bz, 4.4, 0.16, 3.2, C.m(TP.ST2));
    const win = g.known && !out ? C.window : TM.f(TP.FN6);
    for (let i = 0; i < 4; i++) k.b(I, bx - 1.5 + i, 1.9, bz + 1.51, 0.6, 0.45, 0.04, win);
    // 屋頂號誌燈：綠＝正常、黃＝80% 以上、紅＝95% 以上／停電
    const col = C.stageColor(g.stage);
    k.b(I, bx + 1.4, 2.76, bz - 0.6, 0.16, 0.5, 0.16, TM.f(TP.ST1));
    k.b(I, bx + 1.4, 3.26, bz - 0.6, 0.42, 0.42, 0.42, g.known ? C.signal(col) : TM.f(TP.FN6));
    // 電表（門右邊，朝大樓）：外框＋剩餘量的柱
    const mx = bx + 1.25, mz = bz + 1.75, mh = 1.9;
    k.b(I, mx, 0, mz, 0.62, mh + 0.2, 0.32, TM.f(TP.ST1));
    k.b(I, mx, 0.1, mz + 0.161, 0.42, mh, 0.02, TM.f(TP.FN6));
    const left = (g.fiveLeft ?? 0) / 100;
    if (left > 0) k.b(I, mx, 0.1, mz + 0.17, 0.36, Math.max(0.06, mh * left), 0.02, C.signal(col));
    // 油槽（7 天額度）：圓槽（方塊疊）＋正面液位窗
    const tx = C.fuelX, tz = C.fuelZ, th = 3.2;
    k.b(I, tx, 0, tz, 3.6, th, 2.4, C.m(TP.ST2));       // 兩塊交叉＝八角形的槽
    k.b(I, tx, 0, tz, 2.4, th, 3.6, C.m(TP.ST2));
    k.b(I, tx, th, tz, 2.2, 0.12, 2.2, C.m(TP.ST1));
    const wz = tz + 1.81, wh = 2.4;
    k.b(I, tx, 0.4, wz, 0.5, wh, 0.03, TM.f(TP.FN6));
    const fuel = (g.sevenLeft ?? 0) / 100;
    if (fuel > 0) k.b(I, tx, 0.4, wz + 0.01, 0.4, Math.max(0.06, wh * fuel), 0.03, TM.f(fuel <= 0.05 ? 0xEF4444 : 0xC98B3C));
    // 油管：油槽 → 電廠
    k.b(I, (bx + 2.1 + tx - 1.8) / 2, 0.5, tz + 0.2, tx - 1.8 - bx - 2.1, 0.3, 0.3, C.m(TP.ST1));
    // 輸電線（停電時線還在，只是大樓暗了）
    const post = TM.f(TP.ST1), x0 = C.wireX0, x1 = C.wireX1, cz = C.wireZ, cy = C.wireY;
    k.b(I, (x0 + x1) / 2, cy - 0.06, cz, x0 - x1, 0.12, 0.12, post);                 // 電纜管（深色）
    k.b(I, (x0 + x1) / 2, cy - 0.015, cz + 0.065, x0 - x1, 0.03, 0.01, out ? TM.f(TP.FN6) : C.signal(0x1E6FD9));   // 管側一條細藍燈
    for (const x of [x0 - 0.12, x1 + 0.12]) k.b(I, x, cy - 0.3, cz, 0.24, 0.6, 0.4, post);   // 兩端的接線箱（電廠牆上、大樓牆上）
    k.b(I, (x0 + x1) / 2, 0, cz, 0.1, cy - 0.06, 0.1, post);                         // 中間一根支架
    this.addPulses(g.stage);
    this.label("city:power", [bx, 4.6, bz], CityText.grid(g, Date.now() / 1000), g.alert, [[bx, 1.5, bz + 0.2], [4.6, 3.6, 3.6]]);
    this.label("city:fuel", [tx, th + 1.4, tz], CityText.fuel(g), (g.sevenLeft ?? 100) <= 5, [[tx, th / 2, tz], [3.8, th + 0.2, 3.8]]);
  }

  /** 電纜上的光點：一顆顆從電廠流向大樓（SCNAction，只在畫面有在畫時動；看板每 30 秒會播幾秒讓它流一下）；停電沒有光點、吃緊變紅 */
  addPulses(stage) {
    if (stage === "blackout") return;
    const C = CityBuilder;
    const x0 = C.wireX0, x1 = C.wireX1, n = 4, dur = 2.4;
    const col = stage === "normal" ? 0x7DD3FC : C.stageColor(stage);
    const mat = C.signal(col);
    const y = C.wireY + 0.02, z = C.wireZ + 0.075;
    for (let i = 0; i < n; i++) {
      // SCNBox(0.22, 0.08, 0.08, chamfer 0.02)：three 沒有導角方塊 ⇒ 直角（2 cm 導角在這個大小看不出來）；dump 照 Swift 記 chamfer
      const b = new THREE.Mesh(new THREE.BoxGeometry(0.22, 0.08, 0.08), mat);
      b.userData.scn = { type: "SCNBox", params: { chamfer: 0.02, h: 0.08, l: 0.08, w: 0.22 } };
      b.name = "power-pulse";
      b.position.set(x0, y, z);
      setNodeOpacity(b, 0);
      const go = Act.sequence([
        Act.wait(dur / n * i),
        Act.repeatForever(Act.sequence([
          Act.move([x0, y, z], 0),
          Act.fadeIn(0.2),
          Act.move([x1 + 0.1, y, z], dur - 0.4),
          Act.fadeOut(0.2),
        ])),
      ]);
      runAction(b, go, "pulse");
      this.root.add(b);
    }
  }

  // MARK: 分公司

  /** 分公司（11-01 從城外對街搬進城內）：電廠（powerX/powerZ）、油槽（fuelX/fuelZ）前方（朝正門那側）的空地。
   *  那塊地＝電廠那條路（x 10.95–12.05）和右牆（x 20.75）之間、油槽前緣（z −6.0）到大樓前那排樹（z 7.8）之間；
   *  一列沿著電廠那條路往前排（z −4.4、−1.6、1.2、4.0），門朝路、各有一條小路接上去。比原本城外那棟小一號（城內空地有限）
   *  11-01 第二版（Kang：別跟電廠油槽擠在一起）：搬到大樓右前方那塊大空地。廣場右端那段電廠支路往右延伸成一條巷子（z＝laneZ），
   *  前兩棟並排在巷子前面（門朝巷子＝−z、正面朝城門）；第 3、4 棟在巷子後面（門朝巷子＝＋z） */
  static branchW = 3.2; static branchD = 2.3; static branchH = 2.6;
  static laneZ = TD.zF + 0.75; static laneX1 = 20.0;
  static branchX = 14.0;
  static branchPos(i) {
    const x = i % 2 === 0 ? 14.0 : 18.4, front = i < 2;      // 電廠支路東緣 12.05、右牆內側 20.75，兩棟中間留 1.2
    return { x, z: front ? this.laneZ + 0.55 + 0.4 + 2.3 / 2 : this.laneZ - 0.55 - 0.4 - 2.3 / 2, front };
  }

  buildBranch(k, s, p, road) {
    const C = CityBuilder, I = Xf.identity;
    const x = p.x, z = p.z, w = C.branchW, d = C.branchD, h = C.branchH;
    const on = s.online === true;
    const base = C.gy;
    k.b(I, x, base, z, w, h, d, C.m(TP.WL2));
    k.b(I, x, base + h, z, w + 0.2, 0.16, d + 0.2, C.m(TP.ST2));
    const win = on ? C.window : TM.f(TP.FN6);
    // 窗：不朝巷子那面 2 扇（前排＝朝城門，預設視角看得到）、朝巷子那面門的兩側各 1 扇、左右兩側各 1 扇
    const lane = p.front ? -1 : 1, doorZ = z + lane * d / 2, backZ = z - lane * (d / 2 + 0.01);
    for (let i = 0; i < 2; i++) k.b(I, x - 0.7 + i * 1.4, base + 1.4, backZ, 0.8, 0.6, 0.04, win);
    for (const sx of [-1, 1]) {
      k.b(I, x + sx * 1.05, base + 1.4, doorZ + lane * 0.01, 0.6, 0.6, 0.04, win);
      k.b(I, x + sx * (w / 2 + 0.01), base + 1.4, z, 0.04, 0.6, 0.8, win);
    }
    // 門（朝巷子）：在線＝開著（暗的門洞）；離線＝關上
    if (on) k.b(I, x, base, doorZ + lane * 0.01, 0.9, 1.6, 0.04, TM.f(TP.FN6));
    else k.b(I, x, base, doorZ + lane * 0.03, 1.0, 1.65, 0.08, C.m(TP.ST2));
    // 屋頂招牌燈：綠＝在線、灰＝離線／還沒測
    k.b(I, x + 1.1, base + h + 0.16, z, 0.3, 0.3, 0.3, on ? TM.glow(0x22C55E, 0.6, 1.8) : TM.f(0x6B7280));
    // 門口接到巷子的小路（巷子邊緣 → 門）
    const r0 = C.laneZ + lane * -0.55, r1 = doorZ + lane * 0.06;
    k.b(I, x, C.gy, (r0 + r1) / 2, 1.0, 0.04, Math.abs(r1 - r0), road);
    this.label(s.id, [x, base + h + 1.3, z], CityText.server(s), s.alert, [[x, base + h / 2, z], [w + 0.2, h + 0.4, d + 0.2]]);
  }

  // MARK: 港口

  /** 11-01：港口搬到正門（mainGateX）出去、馬路正對面：棧橋＋龍門吊對準正門和斑馬線，水面從棧橋左邊 4 公尺往右延伸（船往右開出港）。
   *  水面從遠側人行道外緣開始；深 8 公尺（4 艘船錯開 1.6 公尺排得下） */
  static portX = CityBuilder.mainGateX;
  /** 港池（棧橋、船、右前方留空、微縮底座）＝原本那塊水面；河道本身沿著馬路一路延伸到霧裡（11-01：港池兩端原本是岸，看起來像一塊藍色地墊） */
  static harborX0 = CityBuilder.portX - 4; static harborX1 = CityBuilder.portX + 32;
  static waterX0 = CityBuilder.streetX0; static waterX1 = CityBuilder.streetX1;
  static waterZ0 = CityBuilder.streetZ + CityBuilder.streetW / 2 + CityBuilder.walkW; static waterZ1 = CityBuilder.waterZ0 + 8;
  /** 棧橋右邊沿岸的碼頭平台深度（龍門吊站在上面）；船席從平台外側排出去（船寬 1.2、間距 1.4，4 艘最外緣 waterZ0＋7.8 ＜ 對岸） */
  static apronD = 2.0;
  static berthZ(i) { return this.waterZ0 + this.apronD + 1.0 + i * 1.4; }

  buildPort(k, s) {
    const C = CityBuilder, I = Xf.identity;
    const water = C.water;
    k.b(I, (C.waterX0 + C.waterX1) / 2, 0, (C.waterZ0 + C.waterZ1) / 2, C.waterX1 - C.waterX0, 0.03, C.waterZ1 - C.waterZ0, water);   // 大地面頂在 y=0：水面高 3 cm（太近會閃）
    // 碼頭：沿街的岸壁＋伸出去的棧橋
    k.b(I, (C.waterX0 + C.waterX1) / 2, 0, C.waterZ0 + 0.3, C.waterX1 - C.waterX0, 0.14, 0.6, C.m(TP.ST2));
    k.b(I, C.portX, 0, C.waterZ0 + 3.4, 2.0, 0.14, 6.2, C.m(TP.ST2));
    // 對岸（10-21 稽核：水面直接貼著地面像一塊藍色地墊）；11-01 河道延伸到霧裡，兩端不再封岸
    k.b(I, (C.waterX0 + C.waterX1) / 2, 0, C.waterZ1 + 0.15, C.waterX1 - C.waterX0 + 0.3, 0.14, 0.3, C.m(TP.ST2));
    // 岸邊龍門吊（10-21 第二輪：不要「一根柱子穿過一條橫桿」的十字架造型；11-01 Kang：方向錯了，該在岸邊）
    // ⇒ 照真的岸邊貨櫃起重機：棧橋右邊沿岸一段碼頭平台（berth），門架四腳站在平台上、沿岸（x）的軌道走；
    //    吊臂垂直岸線往水面（＋z）伸出去、後端配重在陸側；台車＋吊索＋吊具停在第一個船席上方
    const apronZ1 = C.waterZ0 + C.apronD;
    k.b(I, C.portX + 1 + 5.5, 0, (C.waterZ0 + apronZ1) / 2, 11, 0.14, apronZ1 - C.waterZ0, C.m(TP.ST2));
    this.tag(k, "crane");
    const cx = C.portX + 5.5, cz = C.waterZ0 + C.apronD / 2;
    const steel = C.m(TP.ST1), hi = C.m(0xC98B3C);            // 吊臂、機房用琥珀（港口機具色，跟貨櫃強調色同一個材質）
    const legX = [cx - 0.8, cx + 0.8], legZ = [cz - 0.7, cz + 0.7], legTop = 0.14 + 3.4;
    for (const x of legX) for (const z of legZ) k.b(I, x, 0.14, z, 0.16, 3.4, 0.16, steel);        // 四隻腳
    for (const z of legZ) {
      k.b(I, cx, 0.14, z, 1.56, 0.16, 0.3, steel);                                       // 腳底的行走台車（沿岸的軌道）
      k.b(I, cx, 1.7, z, 1.24, 0.12, 0.12, steel);                                       // 中段繫桿
      k.b(I, cx, legTop, z, 1.56, 0.24, 0.24, steel);                                    // 頂部橫樑
    }
    for (const x of legX) k.b(I, x, legTop, cz, 0.2, 0.24, 1.16, steel);                       // 門架左右樑
    const by = legTop + 0.24;                                                                   // 吊臂底面
    const bz0 = cz - 1.6, bz1 = C.waterZ0 + 6.6;                                                // 吊臂：陸側（配重）→ 伸到船席外側
    k.b(I, cx, by, (bz0 + bz1) / 2, 0.5, 0.26, bz1 - bz0, hi);
    k.b(I, cx, by + 0.26, bz0 + 0.35, 0.6, 0.4, 0.7, steel);                              // 後端配重（陸側）
    k.b(I, cx, by + 0.26, cz, 0.8, 0.6, 1.0, hi);                                          // 機房
    k.b(I, cx, by + 0.4, cz + 0.51, 0.6, 0.3, 0.02, C.window);                             // 機房的窗（朝水面）
    k.b(I, cx, by + 0.86, cz, 0.18, 0.12, 0.18, C.lamp);                                   // 機房頂燈
    const tz = C.berthZ(0);                                                                     // 台車（吊臂下、第一個船席上方）
    k.b(I, cx, by - 0.18, tz, 0.6, 0.18, 0.6, steel);
    for (const dz of [-0.2, 0.2]) k.b(I, cx, 2.26, tz + dz, 0.03, by - 0.18 - 2.26, 0.03, steel);   // 兩條吊索
    k.b(I, cx, 2.12, tz, 1.5, 0.14, 0.5, hi);                                              // 吊具（跟貨櫃一樣長、沿船身）
    this.tag(k, null);
    // 夜晚水面：燈的倒影（幾條細長亮線，沿視線方向；水本身不發光）
    for (const [gx, len] of [[cx - 0.3, 2.6], [cx, 1.6], [cx + 0.3, 2.2]]) {
      k.b(I, gx, 0.03, apronZ1 + 0.2 + len / 2, 0.08, 0.012, len, C.glint);
    }
    // 停著的貨櫃：疊在棧橋末端（10-21 稽核：原本放在 x 4.8 的水面上，整疊浮在水上）
    this.tag(k, "container-port");
    for (let i = 0; i < 3; i++) k.b(I, C.portX, 0.14 + i * 0.7, C.waterZ0 + 5.6, 1.5, 0.66, 0.9, C.m(C.containerColors[i]));
    this.tag(k, null);
    this.label("city:port", [cx, 5.4, cz + 1.5], `港口・GitHub${s.repos > 0 ? ` ${s.repos} 個 repo` : ""}`, false,
               [[cx - 2, 2, cz + 2], [9, 4.5, 7]]);
  }

  /** 出港（push）：新的船從棧橋邊往右開出去 4 秒後消失；進港（fetch／pull，11-01）：船頭朝左從右邊開進來、靠到棧橋邊後消失（卸貨）。都是 playFor，不常駐。不能播（被蓋住、太熱）＝不開船；測試視窗定在第 1.5 秒 */
  updateShips(list, animate) {
    const C = CityBuilder;
    let play = 0;
    const live = new Set(list.map(s => s.id));
    for (const [id, n] of [...this.ships]) if (!live.has(id) && actionForKey(n, "sail") === null) { n.parent?.remove(n); this.ships.delete(id); }
    list.slice(-C.maxShips).forEach((s, i) => {
      if (this.seenShips.has(s.id)) return;
      this.seenShips.add(s.id);
      const posed = C.testMode;
      if (!(animate || posed)) return;
      const n = this.makeShip(s.repo);
      const pier = [C.portX + 3.4, 0, C.berthZ(i)];   // 棧橋右邊、碼頭平台外側的船席（10-21 稽核：太靠左船身插進棧橋與起重機腳）
      const dx = s.inbound ? -13 : 13;
      const start = s.inbound ? [pier[0] + 13, pier[1], pier[2]] : pier;
      if (s.inbound) n.rotation.y = Math.PI;                     // 船頭（+x）轉向左、朝棧橋
      n.position.set(start[0], start[1], start[2]);
      this.root.add(n);
      this.ships.set(s.id, n);
      if (posed) {
        n.position.set(start[0] + 1.5 / C.shipDuration * dx, start[1], start[2]);
      } else {
        runAction(n, Act.sequence([Act.moveBy(dx, 0, 0, C.shipDuration), Act.fadeOut(0.2), Act.removeFromParentNode()]), "sail");   // 終點 portX＋16.4（船頭再 2 公尺）＜水面右緣 portX＋32，船不會開上岸；只在水面上走、不碰馬路
        play = Math.max(play, C.shipDuration + 0.4);
      }
    });
    if (this.seenShips.size > 200) this.seenShips = new Set([...this.seenShips].slice(-50));
    return play;
  }

  makeShip(repo) {
    const C = CityBuilder, I = Xf.identity;
    const n = scnNode("ship");
    const m = new VoxelMesh(), k = new Kit(m);
    k.b(I, 0, -0.05, 0, 3.2, 0.55, 1.2, TM.f(TP.FN3));
    k.b(I, 1.75, -0.05, 0, 0.4, 0.4, 0.8, TM.f(TP.FN3));
    k.b(I, -1.2, 0.5, 0, 0.7, 0.8, 0.9, C.m(TP.FN5));
    k.b(I, -1.2, 0.95, 0.46, 0.5, 0.18, 0.02, C.lamp);
    const len = [...repo].length;
    for (let i = 0; i < 3; i++) k.b(I, -0.3 + i * 0.75, 0.5, 0, 0.7, 0.55, 0.85, C.m(C.containerColors[(i + len) % C.containerColors.length]));
    const sn = m.node(); setCategory(sn, OfficeBuilder.outdoorMask);
    n.add(sn);
    const a = scnNode("anchor"); a.position.set(0, 1.8, 0);
    n.add(a);
    return n;
  }

  /** 船的名牌（錨點跟著船走）：[{ id, anchor, text }] */
  get shipLabels() {
    const out = [];
    for (const [id, n] of this.ships) {
      const a = n.children.find(c => c.name === "anchor");
      if (a) out.push({ id: `ship:${id}`, anchor: a, text: (id.endsWith("<") ? "⛴ 進港 " : "⛴ 出港 ") + (id.split("@")[0] ?? "") });
    }
    return out;
  }

  // MARK: 周邊高樓（11-01，照 Windows 版 office.js buildCity）

  /** 城牆外一圈方塊高樓：灰色素面、高低錯落，夜晚窗戶亮暖黃／冷藍的燈。跟資料無關 ⇒ 只建一次（不跟著內容鍵重建）；
   *  大樓本體 3 種灰＝3 個 draw call，亮燈的窗另一個節點 2 種顏色＝2 個 draw call（白天整個藏起來、日夜切換時才動，沒有常駐動畫） */
  get skyline() { return this._skyline ??= CityBuilder.makeSkyline(); }
  get skylineWindows() { return this.skyline.children.find(c => c.name === "skyline-windows") ?? null; }

  /** 日夜（0＝白天、1＝夜晚；日出日落連續）：窗戶燈只在暗下來時出現。OfficeBuilder.applyLights 叫 */
  setDark(d) {
    const w = this.skylineWindows;
    if (!w) return;
    const o = Math.min(1, Math.max(0, (d - 0.3) / 0.4));
    w.visible = !(o <= 0.01);
    setNodeOpacity(w, o);
  }
  /** 微縮模型風格：整座城放在底座上，底座外的高樓會懸空 ⇒ 藏起來 */
  setSkylineHidden(h) { this.skyline.visible = !h; }

  /** 不能蓋高樓的範圍（含 1.5 公尺邊距）：城牆街區＋後面的飛艇、馬路兩側人行道（整條）、港口水面；
   *  鏡頭那側（遠側人行道以外、z > waterZ0）只准在港口左邊蓋矮樓，港口右邊（預設視角鏡頭所在的右前方）留空。
   *  回傳 [{ x, z, w, d, h, shade }]（SkyBlock）。Swift 全程 Float ⇒ 這裡每一步 fround（亂數序列、比較結果才會一樣） */
  static skylineSpots() {
    const C = CityBuilder;
    let seed = 42;
    const rnd = () => { seed = (seed * 16807) % 2147483647; return F(F(seed) / F(2147483647)); };
    const m = F(1.5);
    const nearWalkZ = F(F(F(C.streetZ) - F(C.streetW / 2)) - F(C.walkW / 2)), farWalkZ = F(F(F(C.streetZ) + F(C.streetW / 2)) + F(C.walkW / 2));
    const waterZ0 = F(F(F(C.streetZ) + F(C.streetW / 2)) + F(C.walkW)), waterZ1 = F(waterZ0 + 8);
    const harborX0 = F(F(C.portX) - 4);
    const keepOut = [
      [[F(F(C.x0 - m) - 4), F(-23 - m)], [F(F(C.x1 + m) + 4), F(C.z1 + m)]],                       // 街區＋飛艇（z −17）
      [[-Infinity, F(F(nearWalkZ - F(C.walkW / 2)) - m)], [Infinity, F(F(farWalkZ + F(C.walkW / 2)) + m)]],   // 馬路＋人行道
      [[-Infinity, F(waterZ0 - m)], [Infinity, F(waterZ1 + m)]],                                  // 河道（整條）
      [[F(harborX0 - m), F(waterZ0 - m)], [Infinity, Infinity]],                                  // 港口與右前方
    ];
    const out = [];
    for (let gx = -9; gx <= 9; gx++) for (let gz = -9; gz <= 4; gz++) {
      const x = F(F(gx * 9) + F(F(rnd() - 0.5) * 3)), z = F(F(F(gz * 9) - 6) + F(F(rnd() - 0.5) * 3));
      const w = F(4 + F(rnd() * 4)), d = F(4 + F(rnd() * 4)), skip = rnd() < 0.25;
      const r = F(Math.hypot(x, z)), hr = rnd(), shade = Math.trunc(F(rnd() * 3)) % 3;
      if (skip || !(r < 85)) continue;
      const lo = [F(x - F(w / 2)), F(z - F(d / 2))], hi = [F(x + F(w / 2)), F(z + F(d / 2))];
      if (keepOut.some(([a, b]) => lo[0] < b[0] && hi[0] > a[0] && lo[1] < b[1] && hi[1] > a[1])) continue;
      const front = z > waterZ0;
      const h = front ? F(2.5 + F(hr * 3.5)) : F(5 + F(hr * (r < 45 ? 12 : 26)));
      out.push({ x, z, w, d, h, shade });
    }
    return out;
  }

  /** 灰色三種（Windows 版 0x8E98A3／0x9DA6AE／0x7F8994）；夜晚壓暗成藍灰（看得出量體、不搶大樓） */
  static skylineShades = [[0x8E98A3, 0x2C323B], [0x9DA6AE, 0x333A44], [0x7F8994, 0x262C34]];
  /** 亮燈的窗：不吃燈光（constant）、不吃電力乘數（別人家的燈，我們停電它照亮） */
  static skylineLit = [0xE8C98F, 0xBFD8FF].map(h => {
    const m = new THREE.MeshBasicMaterial(); VoxMat.color(h).toThree(m.color); m.userData.lm = "constant"; m.name = `skylineLit:${h.toString(16)}`; return m;
  });

  static makeSkyline() {
    const C = CityBuilder, I = Xf.identity;
    const n = scnNode("skyline");
    const m = new VoxelMesh({ ao: 0 }), k = new Kit(m), wm = new VoxelMesh(), wk = new Kit(wm);
    const mats = C.skylineShades.map(([a, b]) => VoxMat.dayNight(a, b));
    let seed = 7;
    const rnd = () => { seed = (seed * 16807) % 2147483647; return F(F(seed) / F(2147483647)); };
    const waterZ0 = F(F(F(C.streetZ) + F(C.streetW / 2)) + F(C.walkW));
    for (const t of C.skylineSpots()) {
      k.b(I, t.x, 0, t.z, t.w, t.h, t.d, mats[t.shade]);
      // 窗（Windows 版：每 1.6 公尺一層、每 1.2 公尺一格、28% 亮、亮的 80% 暖黃）：朝 +z（鏡頭那邊）＋朝大樓那面
      const faces = [[[0, 1], t.w]];                                   // [法線, 那面寬]
      faces.push([[t.x > 0 ? -1 : 1, 0], t.d]);
      if (t.z > waterZ0) faces.push([[0, -1], t.w]);                    // 對街的矮樓：朝馬路那面也開窗
      for (const [nrm, fw] of faces) {
        for (const yy of strideF(1.5, F(t.h - 1), 1.6)) {
          for (const u of strideF(F(F(-fw / 2) + F(0.8)), F(F(fw / 2) - F(0.5)), 1.2)) {
            if (!(rnd() < F(0.28))) continue;
            const mat = C.skylineLit[rnd() < F(0.8) ? 0 : 1];
            if (nrm[1] !== 0) {
              wk.b(I, t.x + u, yy, t.z + nrm[1] * (t.d / 2 + 0.02), 0.6, 0.7, 0.04, mat);
            } else {
              wk.b(I, t.x + nrm[0] * (t.w / 2 + 0.02), yy, t.z + u, 0.04, 0.7, 0.6, mat);
            }
          }
        }
      }
    }
    const body = m.node("skyline-body"); setCategory(body, OfficeBuilder.outdoorMask);
    const win = wm.node("skyline-windows"); setCategory(win, OfficeBuilder.outdoorMask);
    win.visible = false;
    n.add(body); n.add(win);
    return n;
  }

  // MARK: 飛艇

  buildAirship(k, c, dock) {
    const C = CityBuilder, I = Xf.identity;
    // 座標都以停靠架地面中心為原點（船身沿 x）
    const f = new Xf(dock[0], 0, dock[2]);
    const st = c.alert ? C.red : c.known ? TM.glow(0x22C55E, 0.6, 1.8) : TM.f(0x9CA3AF);   // 狀態燈：同步正常＝綠、卡住／快滿＝紅、只知道連著＝灰
    const dark = C.m(TP.ST1), conc = C.m(TP.ST2);
    let top, hit;
    switch (C.airshipStyle) {
      case 1: {
        // 銀色硬式飛船：十字斷面疊出圓胖的船身、骨架環、四片尾翼、長吊艙＋兩側發動機；停在兩座 A 字托架上
        const hull = C.m(0xC9CED6), band = C.m(0x8E949C), acc = C.m(0x3B82F6);
        const cy = 4.4, hb = cy - 1.0;
        k.b(f, 0, cy - 0.8, 0, 6.0, 1.6, 1.6, hull);
        k.b(f, 0, cy - 1.0, 0, 5.4, 2.0, 1.2, hull);
        k.b(f, 0, cy - 0.6, 0, 5.4, 1.2, 2.0, hull);
        k.b(f, 3.25, cy - 0.5, 0, 0.5, 1.0, 1.0, hull); k.b(f, 3.6, cy - 0.25, 0, 0.2, 0.5, 0.5, dark);
        k.b(f, -3.25, cy - 0.5, 0, 0.5, 1.0, 1.0, hull);
        for (const x of [-1.6, 0.4, 2.0]) {
          k.b(f, x, cy - 1.03, 0, 0.1, 2.06, 1.26, band); k.b(f, x, cy - 0.63, 0, 0.1, 1.26, 2.06, band);
        }
        k.b(f, -2.9, cy + 0.5, 0, 1.2, 0.9, 0.08, acc); k.b(f, -2.9, cy - 1.4, 0, 1.2, 0.9, 0.08, acc);
        for (const z of [-1.0, 1.0]) k.b(f, -2.9, cy - 0.04, z, 1.2, 0.08, 0.9, acc);
        k.b(f, 0.4, hb - 0.45, 0, 2.2, 0.5, 0.7, dark);
        k.b(f, 0.4, hb - 0.3, 0, 1.8, 0.14, 0.72, C.lamp);
        for (const z of [-1, 1]) {
          k.b(f, -1.0, cy - 0.75, z * 0.95, 0.12, 0.1, 0.5, dark);
          k.b(f, -1.0, cy - 0.95, z * 1.4, 0.7, 0.4, 0.4, dark);
        }
        k.b(f, 1.55, hb - 0.35, 0.2, 0.08, 0.14, 0.14, st);
        for (const x of [-2.0, 2.0]) {
          k.b(f, x, 0, 0, 0.8, 0.1, 2.0, conc);
          for (const z of [-0.7, 0.7]) k.b(f, x, 0.1, z, 0.12, hb - 0.35, 0.12, dark);
          for (const y of [1.2, 2.4]) k.b(f, x, y, 0, 0.08, 0.08, 1.3, dark);
          k.b(f, x, hb - 0.25, 0, 0.5, 0.25, 1.6, conc);                   // 托座（頂到船底）
        }
        top = cy + 1.4; hit = [[0, cy - 0.4, 0], [7.4, 2.6, 2.4]];
        break;
      }
      case 2: {
        // 雲朵飛船（iCloud）：白色雲團、底下吊一個藍色吊艙＋尾槳；停在一座架高的起降台上方
        const cloud = C.m(0xF6F7F9), under = C.m(0xD4E4F4), blue = C.m(0x3B82F6);
        const cb = 5.0;
        k.b(f, 0, cb, 0, 5.6, 1.0, 2.2, cloud);
        for (const [x, y, w, h, d] of [[-1.7, 0.6, 1.8, 1.4, 1.9], [0.1, 0.7, 2.2, 1.9, 2.1], [1.9, 0.6, 1.6, 1.3, 1.8],
                                       [-2.9, 0.3, 1.0, 0.9, 1.5], [2.9, 0.3, 0.9, 0.8, 1.4], [0.5, 2.6, 1.0, 0.5, 1.2]]) {
          k.b(f, x, cb + y, 0, w, h, d, cloud);
        }
        k.b(f, 0, cb - 0.12, 0, 5.0, 0.12, 2.0, under);
        k.b(f, 0, 3.4, 0, 1.6, 0.7, 0.9, blue);
        k.b(f, 0, 3.75, 0, 1.2, 0.18, 0.92, C.lamp);
        k.b(f, 0, 4.1, 0, 1.8, 0.1, 1.0, dark);
        for (const [x, z] of [[-0.7, -0.35], [0.7, -0.35], [-0.7, 0.35], [0.7, 0.35]]) k.b(f, x, 4.2, z, 0.04, cb - 0.12 - 4.2, 0.04, dark);
        k.b(f, -0.9, 3.65, 0, 0.2, 0.15, 0.15, dark);
        k.b(f, -1.02, 3.3, 0, 0.04, 0.9, 0.12, dark); k.b(f, -1.02, 3.69, 0, 0.04, 0.12, 0.9, dark);
        k.b(f, 0.81, 3.55, 0.2, 0.04, 0.14, 0.14, st);
        // 起降台：四腳架高平台＋欄杆＋樓梯
        const dy = 2.6;
        k.b(f, 0, dy, 0, 3.0, 0.15, 2.6, conc);
        for (const [x, z] of [[-1.3, -1.1], [1.3, -1.1], [-1.3, 1.1], [1.3, 1.1]]) {
          k.b(f, x, 0, z, 0.15, dy, 0.15, dark);
          k.b(f, x, dy + 0.15, z, 0.08, 0.5, 0.08, dark);
          k.b(f, x, dy + 0.65, z, 0.14, 0.1, 0.14, C.lamp);
        }
        for (const z of [-1.27, 1.27]) k.b(f, 0, dy + 0.55, z, 2.6, 0.05, 0.05, dark);
        k.b(f, 1.47, dy + 0.55, 0, 0.05, 0.05, 2.2, dark);
        for (let i = 0; i < 6; i++) k.b(f, -1.7 - (5 - i) * 0.4, i * 0.43, 0.6, 0.4, 0.43, 0.9, conc);     // 樓梯（一階一塊，往 −x 下去）
        top = cb + 3.1; hit = [[0, 4.6, 0], [6.0, 4.0, 2.6]];
        break;
      }
      case 3: {
        // 熱氣球：直條紋球皮（一層三片）、吊籃＋燃燒器；地上一座木平台、繫留繩、沙包、風向袋
        const red = C.m(0xE4572E), cream = C.m(0xF3E9D2), basket = C.m(TP.FN1);
        let y = 3.9;
        k.b(f, 0, 3.5, 0, 0.8, 0.4, 0.8, cream);
        for (const [w, h] of [[1.6, 0.5], [2.2, 0.5], [2.6, 0.6], [2.8, 0.6], [2.8, 0.5], [2.6, 0.5], [2.2, 0.4], [1.4, 0.3]]) {
          for (let j = 0; j < 3; j++) k.b(f, (j - 1) * w / 3, y, 0, w / 3, h, w, j === 1 ? cream : red);
          y += h;
        }
        for (const [x, z] of [[-0.38, -0.38], [0.38, -0.38], [-0.38, 0.38], [0.38, 0.38]]) k.b(f, x, 2.95, z, 0.04, 0.55, 0.04, dark);
        k.b(f, 0, 2.3, 0, 0.9, 0.6, 0.9, basket);
        k.b(f, 0, 2.9, 0, 1.0, 0.08, 1.0, dark);
        k.b(f, 0, 3.15, 0, 0.22, 0.22, 0.22, C.lamp);
        k.b(f, 0.46, 2.55, 0.2, 0.04, 0.14, 0.14, st);
        k.b(f, 0, 0, 0, 2.6, 0.3, 2.4, C.m(TP.FN2));
        for (const x of [-0.35, 0.35]) k.b(f, x, 0.3, 0, 0.04, 2.0, 0.04, dark);
        for (const [x, z] of [[-1.1, -1.0], [1.1, -1.0], [-1.1, 1.0], [1.1, 1.0]]) k.b(f, x, 0.3, z, 0.3, 0.22, 0.3, C.m(0x8A7A5A));
        k.b(f, 1.6, 0, 0.9, 0.08, 2.4, 0.08, dark);
        k.b(f, 1.9, 2.1, 0.9, 0.5, 0.18, 0.18, C.m(0xF28C28));
        top = y + 0.4; hit = [[0, 4.0, 0], [3.0, 7.0, 3.0]];
        break;
      }
      case 4: {
        // 飛碟：一圈一圈的圓盤（三個方塊疊出圓）、發光圓頂、邊緣燈。11-01 Kang：浮在 2～3 層樓高之間（底面 6.0–7.6 公尺）緩緩上下飄、慢慢自轉；
        // 機身是自己的節點（SCNAction 動），起降坪留在城市靜態 mesh
        const silver = C.m(0xC9CED6), light = C.m(0xE4E7EC), glass = TM.glow(0x7DD3FC, 0.3, 1.2);
        const um = new VoxelMesh(), uk = new Kit(um);
        const disc = (y, h, r, mm) => {
          uk.b(I, 0, y, 0, 2 * r, h, 0.84 * r, mm); uk.b(I, 0, y, 0, 0.84 * r, h, 2 * r, mm);
          uk.b(I, 0, y, 0, 1.72 * r, h, 1.44 * r, mm); uk.b(I, 0, y, 0, 1.44 * r, h, 1.72 * r, mm);
        };
        disc(0, 0.25, 1.1, dark);
        disc(0.25, 0.35, 1.8, silver);
        disc(0.6, 0.2, 1.4, light);
        disc(0.8, 0.55, 0.7, glass);
        uk.b(I, 0, 1.35, 0, 0.6, 0.2, 0.6, light);
        for (const [x, z] of [[1.83, 0], [-1.83, 0], [0, 1.83], [0, -1.83], [1.56, 1.31], [-1.56, 1.31], [1.56, -1.31], [-1.56, -1.31]]) {
          uk.b(I, x, 0.36, z, 0.14, 0.12, 0.14, C.lamp);
        }
        uk.b(I, 1.0, 0.01, 0.2, 0.14, 0.14, 0.14, st);
        for (const [x, z] of [[0.85, 0.0], [-0.45, 0.75], [-0.45, -0.75]]) {      // 收起來的短腳
          uk.b(I, x, -0.3, z, 0.1, 0.32, 0.1, dark); uk.b(I, x, -0.34, z, 0.3, 0.05, 0.3, dark);
        }
        const lo = 6.0, swing = 1.6;
        const body = um.node("ufo-body"); setCategory(body, OfficeBuilder.outdoorMask);
        const ufo = scnNode("ufo"); ufo.position.set(dock[0], lo, dock[2]); ufo.add(body);
        const up = Act.moveBy(0, swing, 0, 3.6); up.timingMode = "easeInEaseOut";
        const down = Act.moveBy(0, -swing, 0, 3.6); down.timingMode = "easeInEaseOut";
        runAction(ufo, Act.repeatForever(Act.sequence([up, down])), "hover");
        runAction(body, Act.repeatForever(Act.rotateBy(0, Math.PI * 2, 0, 30)), "spin");
        this.root.add(ufo);
        k.b(f, 0, 0, 0, 3.4, 0.12, 3.0, C.m(0x4A4F55));
        const yel = C.m(0xF2C94C);
        for (const z of [-1.2, 1.2]) k.b(f, 0, 0.12, z, 2.6, 0.01, 0.1, yel);
        for (const x of [-1.3, 1.3]) k.b(f, x, 0.12, 0, 0.1, 0.01, 2.5, yel);
        k.b(f, 1.55, 0.12, -1.3, 0.08, 1.6, 0.08, dark); k.b(f, 1.45, 1.72, -1.2, 0.3, 0.12, 0.3, C.lamp);
        top = lo + swing + 1.9; hit = [[0, (lo + 0.6 + swing) / 2, 0], [3.8, lo + 1.6 + swing, 3.8]];
        break;
      }
      default: {
        // 原版：白色軟式飛艇，機頭頂在繫留塔頂的繫留臂上
        const body = C.m(TP.FN5), shade = C.m(TP.POT), y = 6.2;
        k.b(f, 0, y, 0, 5.2, 1.6, 1.6, body);
        k.b(f, 0, y + 0.2, 0, 4.0, 1.2, 2.0, body);
        k.b(f, 3.0, y + 0.35, 0, 0.8, 0.9, 1.0, shade);
        k.b(f, -3.0, y + 0.35, 0, 0.8, 0.9, 1.0, shade);
        k.b(f, -3.3, y + 1.0, 0, 0.9, 1.0, 0.08, conc);
        k.b(f, -3.3, y + 0.55, 0, 0.9, 0.08, 1.8, conc);
        k.b(f, 0.3, y - 0.45, 0, 1.6, 0.45, 0.7, dark);
        const mx = 3.75;
        k.b(f, mx, 0, 0, 1.2, 0.1, 1.2, conc);
        for (const [dx, dz] of [[-0.3, -0.3], [0.3, -0.3], [-0.3, 0.3], [0.3, 0.3]]) k.b(f, mx + dx, 0.1, dz, 0.1, y + 0.25, 0.1, dark);
        for (const yy of strideF(1.4, y, 1.4)) k.b(f, mx, yy, 0, 0.7, 0.06, 0.7, dark);
        k.b(f, mx, y + 0.35, 0, 0.8, 0.2, 0.8, dark);
        k.b(f, mx - 0.35, y + 0.3, 0, 0.3, 0.14, 0.14, dark);
        k.b(f, mx, y + 0.55, 0, 0.16, 0.16, 0.16, C.lamp);
        k.b(f, 1.2, y - 0.3, 0.36, 0.16, 0.16, 0.04, st);
        top = y + 2.0; hit = [[0, y + 0.3, 0], [7, 2.4, 2.2]];
      }
    }
    this.label(c.id, [dock[0], dock[1] + top, dock[2]], CityText.cloud(c), c.alert,
               [[dock[0] + hit[0][0], dock[1] + hit[0][1], dock[2] + hit[0][2]], hit[1]]);
  }

  /** 俯瞰取景要框的範圍 */
  static get bounds() {
    return { lo: [this.x0 - 1, 0, this.z0 - 5], hi: [this.x1 + 1, 9, this.waterZ1] };
  }
}
