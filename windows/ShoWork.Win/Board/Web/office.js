// ShoWork42 Windows 戰情中心的 3D 辦公大樓（11-02 P8）：Mac OfficeView.swift（SwiftUI 疊層＋OfficeScene／OfficeSCNView）照搬。
//   場景：scene/builder.js（OfficeBuilder.swift 照搬）；渲染迴圈、鏡頭、點擊：ui/sceneview.js；名牌：ui/labels.js；
//   疊層：ui/panels.js（需要你列、樓層列、控制、細節卡、保全、城市、B1 留言板）、ui/inbox.js（收件匣、隊長對話）；純邏輯：ui/core.js。
// 資料：C# 用 PostWebMessageAsJson 推 {type:"office2", …}（形狀同 bench/mac-input.json，見 Board\Core\Office2.cs 與 Web/PROTOCOL.md）。
//   會改資料或觸發動作的按鈕一律 chrome.webview.postMessage({type:"action", action:<BoardActions 的名字>, …}) 交給 C#。
// 不靠 Windows 單獨看：python3 -m http.server 後開 office.html?demo=1（載入 bench/mac-input.json 當示範資料；示範資料不送任何動作）。
// 舊的 W6 簡化版留在 office-w6.js。

import { OfficeBuilder, KuboArt } from "./scene/builder.js";
import { TowerTheme } from "./scene/tower.js";
import { CityState } from "./scene/city-model.js";
import { WeatherLook, WeatherKind, weathered } from "./scene/weather.js";
import { h, replace } from "./ui/dom.js";
import { Mood, AttentionSummary, TowerIndex, Inbox, OfficeLighting, WeatherSite, TowerThemeTitle, cityAlerts, nowSec } from "./ui/core.js";
import { AttentionBar, FloorRail, Controls, WeatherPlaces, HoverCard, AnswerCard, GuardHover, GuardCard, B1BoardCard, CityCard, CityHoverCard, showMenu } from "./ui/panels.js";
import { InboxPanel, Store } from "./ui/inbox.js";
import { OfficeSCNView } from "./ui/sceneview.js";
import { OfficeDemo } from "./ui/demo.js";

// 10-24 Kang 選 C：關窗時畫面會拆掉，重開要回到原樣的東西記在這裡（WebView 重建後同一個 session 還在）
const OfficeMemory = (() => {
  let o = {};
  try { o = JSON.parse(sessionStorage.getItem("OfficeMemory") ?? "{}"); } catch { o = {}; }
  const m = { camera: o.camera ?? null, selectedFloor: o.selectedFloor ?? null, boardOpen: !!o.boardOpen, boardTop: o.boardTop ?? null, talkingTo: o.talkingTo ?? null };
  m.save = () => { try { sessionStorage.setItem("OfficeMemory", JSON.stringify({ camera: m.camera, selectedFloor: m.selectedFloor, boardOpen: m.boardOpen, boardTop: m.boardTop, talkingTo: m.talkingTo })); } catch { /* 存不了就算了 */ } };
  return m;
})();

const params = new URLSearchParams(location.search);
const host = window.chrome?.webview ?? null;
const demoMode = params.has("demo") ? "all" : null;      // OfficeDemo.mode
const prefs = {
  get: (k, d) => { const v = localStorage.getItem("office." + k); return v === null ? d : JSON.parse(v); },
  set: (k, v) => localStorage.setItem("office." + k, JSON.stringify(v)),
};

// MARK: - 狀態（OfficeView 的 @State／@AppStorage）

const S = {
  data: null, loaded: false,
  hovered: null, hoverPoint: { x: 0, y: 0 }, hoverCardSize: { width: 320, height: 200 },
  answeringId: null, guardOpen: false, resetTick: 0,
  camRequest: { tick: 0, target: null },
  lastAttention: null, selectedFloor: OfficeMemory.selectedFloor, railHover: null, idleOpen: false, pinned: null, helpOpen: false,
  cityOpen: null, boardOpen: OfficeMemory.boardOpen, lastCityAlert: null,
  answered: {}, inboxOpen: false, wide: true, captainBusy: false, talkingTo: OfficeMemory.talkingTo,
  lighting: prefs.get("lighting", "auto"), style: prefs.get("style", "voxel"), patrol: prefs.get("guardPatrol", false),
  weatherEnabled: prefs.get("weather", true), weatherSites: prefs.get("weatherPlaces", null),
  weatherOpen: false, weatherQuery: "", weatherResults: [], weatherNote: null,
  showOnline: false, pushAllowed: new Set(), b1Posts: [], answerText: {},
  toast: null,
};
const store = new Store();
let pinTimer = null, clockTimer = null, toastTimer = null;

// MARK: - 3D

const view = new OfficeSCNView(document.getElementById("stage"), document.getElementById("labels"), { memory: OfficeMemory, testMode: params.has("test") });
window.__office = { view, S };          // 驗證用（headless 量名牌位置、console 看狀態）
view.applyStyle(S.style);
view.onHover = id => { S.hovered = id; renderOverlay(); };
view.onHoverPoint = p => { S.hoverPoint = p; };
view.onClick = id => click(id);
view.menuFor = (id, x, y) => { const m = menu(id); if (m) showMenu(x, y, m); };
view.onVisible = v => send("wanderVisible", { visible: v }, true);

// MARK: - 資料

const cards = () => {
  const d = S.data;
  if (!d) return [];
  if (Array.isArray(d.cards)) return d.cards;
  return (d.islands ?? []).flatMap(i => i.people.map(p => p.card));
};
const cityState = () => S.data?.city ? CityState.from(S.data.city) : null;
const weatherInfo = () => {
  const d = S.data ?? {};
  const main = d.site ?? WeatherSite.taipei;
  const sites = d.weatherSites ?? (S.weatherSites ?? [main]).map(s => ({ site: s, report: WeatherSite.same(s, main) && d.weather?.now ? { now: d.weather.now, at: d.weather.at ?? d.now ?? nowSec() } : null, failed: false }));
  const r = sites.find(x => WeatherSite.same(x.site, main))?.report;
  const menuStatus = d.weatherMenuStatus ?? (!S.weatherEnabled ? "真實天氣：關" : r ? `${main.title} ${WeatherKind.title[WeatherKind.classify(r.now)]} · 陣風 ${Math.round(r.now.gust * 3.6)} km/h` : `${main.title}天氣：讀取中（先當晴天）`);
  return { enabled: S.weatherEnabled, sites, main, menuStatus };
};
const weatherLook = () => S.weatherEnabled && S.data?.weather?.now ? WeatherLook.of(S.data.weather.now) : WeatherLook.clear;
function sky() {
  const now = new Date(), site = weatherInfo().main;
  const look = weathered(OfficeLighting.look(S.lighting, now, site), weatherLook());
  return { look, night: look.dark >= 0.5, label: OfficeLighting.label(S.lighting, now, site), now, site };
}

/** C# 推來的一份 office2 */
function apply(d) {
  if (!d || d.type !== "office2") return;
  S.data = d;
  if (!S.loaded) {
    S.loaded = true;
    if (d.lighting && !localStorage.getItem("office.lighting")) S.lighting = d.lighting;
    if (S.talkingTo) talk(S.talkingTo);       // 重開視窗：接回去讀它的對話
  }
  if (Array.isArray(d.b1Posts)) S.b1Posts = d.b1Posts;
  if (d.colors) for (const [k, v] of Object.entries(d.colors)) if (k in KuboArt.looks && /^#?[0-9a-f]{6}$/i.test(v)) KuboArt.looks[k] = parseInt(v.replace("#", ""), 16);
  if (d.graph && (d.graph.nodes ?? []).length) view.builder.setNeuralGraph(d.graph);   // 還沒跑過 Graphify：留著示範圖譜（Mac：NeuralGraph.demo()）
  if (typeof d.reduceMotion === "boolean") window.__reduceMotion = d.reduceMotion;
  updateScene();
  render();
}

// MARK: - 動作（BoardActions；格式見 PROTOCOL.md）

/** 送一個動作給 C#。示範資料一律不送（Mac：OfficeDemo.mode != nil ⇒ 只顯示 toast） */
function send(action, fields = {}, quiet = false) {
  if (demoMode || !host) { if (!quiet) toast(`示範資料：不送出（${action}）`); return false; }
  host.postMessage({ type: "action", action, ...fields });
  return true;
}
function toast(text) {
  S.toast = text; renderToast();
  clearTimeout(toastTimer); toastTimer = setTimeout(() => { S.toast = null; renderToast(); }, 3200);
}

// MARK: - OfficeView 的函式

/** 右側對話窗格換人（null＝回到隊長）：資料層改讀那個人的對話紀錄。
 *  clicked＝點的那個角色的卡片 id（C# 用它開細節卡；隊長也是 watch null，所以另外帶；返回鈕不帶） */
function talk(id, clicked = null) {
  S.talkingTo = id; OfficeMemory.talkingTo = id; OfficeMemory.save();
  const sid = id ? id.split("#")[0] : null;      // 卡片 id＝sessionId（排隊卡多 #q…）
  send("watch", clicked ? { sessionId: sid, id: clicked } : { sessionId: sid }, true);
  if (id && !S.wide) S.inboxOpen = true;
}

function redecorate(project) {
  if (demoMode) { toast("示範資料：不重新裝潢"); return; }
  send("redecorate", { project });
}

/** 索引列點樓層：鏡頭對準整層；同一層再點一次回到預設鏡頭 */
function focusFloor(id) {
  if (S.selectedFloor === id) { S.selectedFloor = null; S.resetTick += 1; }
  else { S.selectedFloor = id; S.camRequest = { tick: S.camRequest.tick + 1, target: { kind: "floor", id } }; }
  OfficeMemory.selectedFloor = S.selectedFloor; OfficeMemory.save();
  updateScene(); render();
}

/** 設備警示：輪流飛到下一個有問題的建築並打開它的細節卡 */
function focusCityAlert(ids) {
  const id = AttentionSummary.next(ids.includes(S.lastCityAlert) ? S.lastCityAlert : null, ids);
  if (!id) return;
  S.lastCityAlert = id; S.selectedFloor = null; S.answeringId = null; S.guardOpen = false;
  S.cityOpen = id;
  S.camRequest = { tick: S.camRequest.tick + 1, target: { kind: "city", id } };
  updateScene(); render();
}

/** 需要你列：依時間先後輪流飛到下一個人；等你回答的直接開回答卡，做完的把細節卡釘 6 秒 */
function focusAttention(ids, answer) {
  const id = AttentionSummary.next(ids.includes(S.lastAttention) ? S.lastAttention : null, ids);
  if (!id) return;
  S.lastAttention = id; S.selectedFloor = null;
  S.camRequest = { tick: S.camRequest.tick + 1, target: { kind: "person", id } };
  S.guardOpen = false;
  if (answer) S.answeringId = id;
  else {
    S.answeringId = null; S.pinned = id;
    clearTimeout(pinTimer); pinTimer = setTimeout(() => { if (S.pinned === id) { S.pinned = null; renderOverlay(); } }, 6000);
  }
  updateScene(); render();
}

/** 點角色：右邊窗格換成它的對話（隊長＝隊長對話）；等你回答的另外開回答卡。點保全開保全面板 */
function click(id) {
  if (id.startsWith("neural:")) { openGraph(id.slice(7)); return; }
  if (id === "b1-board") { S.answeringId = null; S.guardOpen = false; S.cityOpen = null; S.boardOpen = true; boardChanged(); send("b1Refresh", {}, true); render(); return; }
  S.boardOpen = false; boardChanged();
  if (id.startsWith("city:")) { S.answeringId = null; S.guardOpen = false; S.cityOpen = id; render(); return; }
  S.cityOpen = null;
  if (id === "guard") { S.answeringId = null; S.guardOpen = true; render(); return; }
  const c = cards().find(x => x.id === id);
  if (!c) { render(); return; }
  S.guardOpen = false;
  S.answeringId = Mood.of(c) === "waiting" ? id : null;
  talk(c.captain ? null : id, id);
  render();
}
const boardChanged = () => { OfficeMemory.boardOpen = S.boardOpen; OfficeMemory.save(); };

function jump(id) {
  const c = cards().find(x => x.id === id);
  if (!c) return;
  if (demoMode || !host) { toast("示範資料：不跳到視窗"); return; }
  send("focus", { id: c.id, sessionId: c.sessionId, pid: c.pid ?? null, kind: c.kind ?? null });
}

/** 點地下室神經網路（10-22）：開整棟大樓的知識星雲 */
function openGraph(project) {
  if (demoMode || !host) { toast("示範資料：開啟整棟大樓知識星雲"); return; }
  toast("正在整理整棟大樓的知識星雲…");
  send("openGraph", { project });
}

/** 「立即掃描」：示範資料不掃真的網路 */
function guardScan() {
  if (demoMode) { toast("示範資料：不掃描"); return; }
  send("guardScan");
}

/** 右鍵選單（跟部門島同一組動作）；保全：打開面板／立即掃描 */
function menu(id) {
  const scanning = !!S.data?.scanning;
  if (id === "guard") return [
    { label: "打開保全面板", action: () => { S.guardOpen = true; render(); } },
    { label: scanning ? "掃描中⋯" : "立即掃描 Wi-Fi", disabled: scanning, action: guardScan },
  ];
  const c = cards().find(x => x.id === id);
  if (!c) return null;
  const reviewing = new Set(S.data?.reviewing ?? []);
  const m = [{ label: "跳到這個視窗", action: () => jump(id) }];
  if (c.column === "review") m.push({ label: "放行", action: () => { if (send("approve", { id: c.id, sessionId: c.sessionId })) toast(`已放行「${c.title}」`); } });
  if (!c.captain) m.push({ label: "派工給它⋯", action: () => send("dispatch", { id: c.id, sessionId: c.sessionId }) });
  m.push({ label: "退回並補指示⋯", action: () => send("sendBack", { id: c.id, sessionId: c.sessionId }) });
  m.push({ label: "丟回待辦⋯", action: () => send("park", { id: c.id, sessionId: c.sessionId }) });
  m.push({ label: "重新審核", disabled: reviewing.has(c.sessionId) || c.lastActivity == null, action: () => send("review", { id: c.id, sessionId: c.sessionId, force: true }) });
  m.push({ separator: true });
  m.push({ label: `重新裝潢「${c.project}」這層`, action: () => redecorate(c.project) });
  m.push({ label: "拷貝 Session ID", action: () => { navigator.clipboard?.writeText(c.sessionId).catch(() => {}); } });
  return m;
}

/** WebView2 拖進來的 File 沒有完整路徑：交給 C#（postMessageWithAdditionalObjects）換成路徑；瀏覽器裡只有檔名 */
let dropSeq = 0;
const dropWaiters = new Map();
function paths(files) {
  if (!host?.postMessageWithAdditionalObjects || demoMode) return Promise.resolve(files.map(f => f.name));
  const key = `drop${++dropSeq}`;
  return new Promise(res => {
    dropWaiters.set(key, res);
    host.postMessageWithAdditionalObjects({ type: "dropFiles", key }, files);
    setTimeout(() => { if (dropWaiters.has(key)) { dropWaiters.delete(key); res(files.map(f => f.name)); } }, 3000);
  });
}

// MARK: - 3D 更新（OfficeScene.updateNSView）

function updateScene() {
  const d = S.data;
  const b = view.builder;
  const { look } = sky();
  b.setWeather(weatherLook());
  if (view.style !== S.style) view.applyStyle(S.style);
  const nightChanged = b.setLook(look);
  if (!d) { view.frameIfNeeded(); view.requestRender(); return; }
  const answering = answeringCard();
  const reframe = b.update(d.tower, d.decor, d.wander, d.islands, d.guardStatus, !!d.scanning, view.canAnimate, new Date((d.now ?? nowSec()) * 1000));
  // 第一次（有大小之後）、按「重設視角」⇒ 重新取景；大樓高度變了（樓層進出）只在你沒動過視角時重新取景（不搶走你的視角）
  if (view.lastReset !== S.resetTick || reframe === "layout" || (reframe === "size" && !view.userMoved)) {
    if (view.lastReset !== S.resetTick || reframe === "layout") view.userMoved = false;
    if (view.lastReset !== S.resetTick) { OfficeMemory.camera = null; OfficeMemory.save(); }
    view.lastReset = S.resetTick;
    view.framed = false;
  }
  if (d.city) b.updateCity(d.city, view.canAnimate && !view.hot);
  view.frameIfNeeded();
  view.refreshLabels(d.guardStatus ?? {}, !!d.scanning);
  if (view.lastCam !== S.camRequest.tick) { view.lastCam = S.camRequest.tick; view.perform(S.camRequest.target); }
  if (b.highlightFloor(S.railHover)) view.playFor(0.15);
  const personHover = S.hovered && !isCity(S.hovered) ? S.hovered : null;
  const cs = answering ? [464, 290] : S.guardOpen ? [484, 640] : S.cityOpen ? [464, 300] : S.boardOpen ? [484, 560] : (personHover ?? S.pinned) ? [444, 240] : null;
  view.labels.setOccluder(cs ? { x: 0, y: 0, w: cs[0] + 12, h: cs[1] + 12 } : null);
  if (JSON.stringify(cs) !== JSON.stringify(view.lastCard)) { view.lastCard = cs; view.playFor(0.15); }
  view.noticeWaiting(new Set((d.islands ?? []).flatMap(i => i.people).filter(p => p.mood === "waiting").map(p => p.card.id)), S.loaded);
  view.playFor(Math.max(b.takeTransient(), nightChanged ? 0.3 : 0));
  view.updateLOD();
}
const isCity = id => id.startsWith("city:") || id.startsWith("ship:");
const answeringCard = () => S.answeringId ? cards().find(c => c.id === S.answeringId && Mood.of(c) === "waiting") ?? null : null;

/** 自動燈光：晨昏每 60 秒、白天每 5 分鐘、夜晚睡到天快亮再重算一次（一次性 setTimeout，不輪詢） */
function scheduleClock() {
  clearTimeout(clockTimer);
  const now = new Date();
  const next = OfficeLighting.nextChange(S.lighting, now, weatherInfo().main);
  if (!next) return;
  clockTimer = setTimeout(() => { updateScene(); renderBar(); scheduleClock(); }, Math.max(1000, next - now + 500));
}

// MARK: - 畫疊層（OfficeView.body）

const $ = id => document.getElementById(id);

/** 重畫一塊時保住輸入框的焦點、游標（SwiftUI 的 @FocusState） */
function keepFocus(f) {
  const a = document.activeElement, k = a?.dataset?.k, s = a?.selectionStart, e = a?.selectionEnd;
  f();
  if (!k) return;
  const n = document.querySelector(`[data-k="${CSS.escape(k)}"]`);
  if (n && n !== document.activeElement) { n.focus({ preventScroll: true }); try { n.selectionStart = s; n.selectionEnd = e; } catch { /* 不是文字框 */ } }
}

function render() {
  S.wide = innerWidth >= 1300;      // OfficeView.inboxWidth
  keepFocus(() => { renderLeft(); renderBar(); renderInbox(); renderOverlay(); });
}

function renderLeft() {
  const left = $("left");
  if (!S.wide && S.inboxOpen) { left.className = "col inbox-col"; replace(left, inbox(() => { S.inboxOpen = false; render(); })); return; }
  left.className = "col rail-col";
  const d = S.data ?? {};
  const moods = {};
  for (const i of d.islands ?? []) for (const p of i.people) (moods[String(i.project).toLowerCase()] ??= []).push(p.mood);
  const rows = TowerIndex.rows(d.tower ?? OfficeBuilder.fallback, d.decor ?? {}, moods, t => TowerTheme.accent[t] ?? null);
  const city = cityState();
  replace(left, FloorRail({
    rows, selected: S.selectedFloor, guardLevel: d.guardStatus?.level ?? "normal", cityAlerts: cityAlerts(city).length, idleOpen: S.idleOpen,
    onIdleToggle: id => { S.idleOpen = !S.idleOpen; if (S.idleOpen) focusFloor(id); else render(); },
    onFloor: focusFloor,
    onHover: id => { S.railHover = id; if (view.builder.highlightFloor(id)) view.playFor(0.15); },
    onGuard: () => { focusFloor("lobby"); S.answeringId = null; S.guardOpen = true; render(); },
  }));
}

function renderBar() {
  const c = cards(), city = cityState(), alerts = cityAlerts(city);
  const attention = AttentionSummary.make(c);
  const { night, label } = sky();
  const w = weatherInfo();
  const bar = AttentionBar({
    summary: attention, alerts: alerts.length,
    onAlerts: () => focusCityAlert(alerts.map(a => a.id)),
    onWaiting: () => { if (!S.wide) S.inboxOpen = true; focusAttention(attention.waiting, true); },
    onStuck: () => focusAttention(attention.stuck, false),
    onFinished: () => focusAttention(attention.finished, false),
    controls: () => Controls({
      lighting: S.lighting, night, lightLabel: label, style: S.style, weather: w, weatherOpen: S.weatherOpen,
      onWeatherOpen: v => { S.weatherOpen = v; renderBar(); },
      onLighting: l => { S.lighting = l; prefs.set("lighting", l); send("setPref", { key: "lighting", value: l }, true); updateScene(); renderBar(); scheduleClock(); },
      onStyle: s => { S.style = s; prefs.set("style", s); send("setPref", { key: "style", value: s }, true); updateScene(); renderBar(); },
      onWeatherEnabled: v => { S.weatherEnabled = v; prefs.set("weather", v); send("setPref", { key: "weather", value: v }, true); updateScene(); renderBar(); },
      projectFloors: (S.data?.tower?.floors ?? []).filter(f => f.kind === "project"), decor: S.data?.decor ?? {},
      onRedecorate: redecorate,
      onReset: () => { S.selectedFloor = null; OfficeMemory.selectedFloor = null; OfficeMemory.camera = null; OfficeMemory.save(); S.resetTick += 1; updateScene(); render(); },
      helpOpen: S.helpOpen, onHelp: () => { S.helpOpen = !S.helpOpen; renderBar(); },
      weatherPlaces: () => WeatherPlaces({
        weather: w, query: S.weatherQuery, results: S.weatherResults, searchNote: S.weatherNote,
        onSites: xs => { S.weatherSites = xs; prefs.set("weatherPlaces", xs); send("setPref", { key: "weatherPlaces", value: xs }, true); renderBar(); },
        onQuery: q => { S.weatherQuery = q; if (q.trim()) send("weatherSearch", { query: q }, true); else { S.weatherResults = []; S.weatherNote = null; } },
      }),
    }),
  });
  const old = $("attnBar");
  old.replaceWith(bar);
  bar.fit();
}

function inbox(close) {
  const c = cards(), d = S.data ?? {};
  const demo = demoMode ? OfficeDemo : null;
  return InboxPanel({
    items: Inbox.items(c, S.answered), captain: c.find(x => x.captain && !x.id.includes("#")) ?? null, store,
    onAnswer: (it, text) => {
      if (demoMode || !host) { toast(`測試：不送出「${text}」`); return; }
      S.answered[it.card.sessionId] = nowSec();
      if (S.answeringId === it.id) S.answeringId = null;
      send("answer", { id: it.card.id, sessionId: it.card.sessionId, text });
      render();
    },
    onPermit: (it, a) => {
      if (demoMode || !host) { toast(`測試：不回答權限（${a.decision}）`); return; }
      S.answered[it.card.sessionId] = nowSec();
      send("permit", { id: it.card.id, sessionId: it.card.sessionId, permitId: it.card.permit?.id ?? null, decision: a.decision, message: a.message ?? null, answers: a.answers ?? null });
      render();
    },
    onJump: jump, onFocus: id => focusAttention([id], false),
    onCaptain: text => {
      if (demoMode || !host) { toast(`測試：不交給隊長「${text}」`); return; }
      S.captainBusy = true; send("askCaptain", { text }); renderInbox();
    },
    onClose: close, captainBusy: S.captainBusy || !!d.captainBusy,
    thread: demo ? demo.captainThread() : d.captainThread ?? [],
    tasks: demo ? demo.captainTasks : d.captainTasks ?? [],
    person: S.talkingTo ? c.find(x => x.id === S.talkingTo) ?? null : null,
    personThread: demo ? demo.personThread() : d.sessionThread ?? [],
    onPersonSend: text => {
      const p = S.talkingTo ? c.find(x => x.id === S.talkingTo) : null;
      if (!p) return;
      if (demoMode || !host) { toast(`測試：不送出「${text}」`); return; }
      S.answered[p.sessionId] = nowSec();
      send("answer", { id: p.id, sessionId: p.sessionId, text });
    },
    onBack: () => { talk(null); render(); }, runs: d.runs ?? [], captainModelTitle: d.captainModelTitle ?? "Opus 5.5", paths,
  });
}

function renderInbox() {
  const right = $("right");
  if (!S.wide) { right.hidden = true; right.replaceChildren(); return; }
  right.hidden = false;
  keepFocus(() => replace(right, inbox(null)));
}

/** 3D 區域上的卡片：左下角（回答卡／城市卡／留言板／保全卡／懸停）＋城市懸停卡（跟著滑鼠） */
function renderOverlay() {
  const bl = $("overlayBL"), d = S.data ?? {}, c = cards();
  const answering = answeringCard();
  const city = cityState();
  let card = null;
  if (answering) {
    card = AnswerCard({ card: answering, text: S.answerText[answering.id] ?? "", onText: v => { S.answerText[answering.id] = v; },
      onJump: () => jump(answering.id), onClose: () => { S.answeringId = null; render(); updateScene(); },
      onSend: text => {
        // 示範資料的卡片借用真 session 的 pid：絕不能真的打字進去（10-20 審查）
        if (demoMode || !host) { toast(`示範資料：不送出（${[...text].length} 字）`); S.answeringId = null; render(); return; }
        send("answer", { id: answering.id, sessionId: answering.sessionId, text });
        S.answerText[answering.id] = ""; S.answeringId = null; render();
      } });
  } else if (S.cityOpen && city) card = CityCard({ id: S.cityOpen, city, onClose: () => { S.cityOpen = null; render(); updateScene(); } });
  else if (S.boardOpen) card = B1BoardCard({ posts: S.b1Posts, top: OfficeMemory.boardTop, onScroll: id => { OfficeMemory.boardTop = id; OfficeMemory.save(); },
    onRefresh: () => send("b1Refresh", {}, true), onClose: () => { S.boardOpen = false; boardChanged(); render(); updateScene(); } });
  else if (S.guardOpen) card = GuardCard({ status: d.guardStatus ?? {}, scanning: !!d.scanning, wall: wallSummary(city ?? new CityState()), patrol: S.patrol,
    showOnline: S.showOnline, onToggleOnline: () => { S.showOnline = !S.showOnline; renderOverlay(); },
    onPatrol: v => { S.patrol = v; prefs.set("guardPatrol", v); send("setPref", { key: "guardPatrol", value: v }, true); renderOverlay(); },
    onScan: guardScan, onClose: () => { S.guardOpen = false; render(); updateScene(); },
    allowed: S.pushAllowed, onAllow: (e, k) => { if (!demoMode) send("pushAllow", { dir: e.dir, head: e.head, repo: e.repo }); S.pushAllowed.add(k); renderOverlay(); } });
  else if (S.hovered === "guard") card = GuardHover({ status: d.guardStatus ?? {}, scanning: !!d.scanning });
  else {
    const id = (S.hovered && !isCity(S.hovered) ? S.hovered : null) ?? S.pinned;
    const hc = id ? c.find(x => x.id === id) : null;
    if (hc) card = HoverCard({ card: hc, theme: d.decor?.[String(hc.project).toLowerCase()] ?? null });
  }
  const passive = card && !(answering || S.cityOpen || S.boardOpen || S.guardOpen);
  bl.classList.toggle("passive", !!passive);
  replace(bl, card);
  // 城市懸停卡：浮在滑鼠右下（放不下就換到左邊／上面），夾在 3D 區域裡、不吃滑鼠；已經點開同一棟的細節卡就不重複
  const ch = $("cityHover");
  if (S.hovered && isCity(S.hovered) && S.hovered !== S.cityOpen && city) {
    const el = CityHoverCard({ id: S.hovered.startsWith("ship:") ? "city:port" : S.hovered, city });
    replace(ch, el);
    const r = el.getBoundingClientRect();
    S.hoverCardSize = { width: r.width, height: r.height };
    const o = hoverOrigin(S.hoverPoint, S.hoverCardSize, { width: view.bounds.width, height: view.bounds.height });
    el.style.transform = `translate(${o.x}px, ${o.y}px)`;
  } else ch.replaceChildren();
}
/** 城牆一句話（CityFirewall.summary）：保全卡的那行 */
function wallSummary(city) {
  const f = city.firewall;
  if (f.checkedAt === null) return "城牆：還沒檢查";
  let s = f.enabled === null ? "城牆：防火牆狀態讀不到" : f.enabled ? "城牆：防火牆開著" : "城牆：防火牆關閉（有缺口）";
  s += `，對外城門 ${f.gates.length} 個、城內的門 ${f.doors.length} 扇`;
  if (f.openRed.length) s += "，敞開的紅門 " + f.openRed.map(p => `${p.port}（${p.knownOpen}）`).join("、");
  return s;
}
/** 懸停卡左上角：先放滑鼠右下 16 點；右邊放不下換到左邊、下面放不下換到上面；最後夾在畫面內（留 8 點） */
function hoverOrigin(p, c, v) {
  let x = p.x + 16, y = p.y + 16;
  if (x + c.width > v.width - 8) x = p.x - 16 - c.width;
  if (y + c.height > v.height - 8) y = p.y - 16 - c.height;
  x = Math.min(Math.max(8, x), Math.max(8, v.width - c.width - 8));
  y = Math.min(Math.max(8, y), Math.max(8, v.height - c.height - 8));
  return { x, y };
}
function renderToast() {
  const t = $("toast");
  t.hidden = !S.toast; t.textContent = S.toast ?? "";
}

// Esc：關掉開著的卡片（.keyboardShortcut(.cancelAction)）
addEventListener("keydown", e => {
  if (e.key !== "Escape") return;
  if (S.answeringId || S.cityOpen || S.boardOpen || S.guardOpen) { S.answeringId = null; S.cityOpen = null; S.boardOpen = false; S.guardOpen = false; boardChanged(); render(); updateScene(); }
  else if (S.helpOpen || S.weatherOpen) { S.helpOpen = false; S.weatherOpen = false; renderBar(); }
});
addEventListener("resize", () => { const w = innerWidth >= 1300; if (w !== S.wide) render(); else $("attnBar").fit?.(); });

// MARK: - C# 的訊息

function onMessage(m) {
  if (!m || typeof m !== "object") return;
  switch (m.type) {
    case "office2": apply(m); break;
    case "heat": view.heatChanged(!!m.paused); break;                       // HeatGate：機器熱 ⇒ 持續動畫停
    case "visible": view.setHostVisible(m.visible !== false); break;       // 視窗被蓋住／縮小（C# 另外通知）
    case "toast": toast(String(m.text ?? "")); if (m.captainDone) { S.captainBusy = false; renderInbox(); } break;
    case "captainBusy": S.captainBusy = !!m.busy; renderInbox(); break;
    case "b1Posts": S.b1Posts = m.posts ?? []; renderOverlay(); break;
    case "weatherResults": S.weatherResults = m.results ?? []; S.weatherNote = m.note ?? null; renderBar(); break;
    case "dropPaths": { const r = dropWaiters.get(m.key); if (r) { dropWaiters.delete(m.key); r(m.paths ?? []); } break; }
    case "deselect": S.answeringId = null; render(); break;
  }
}

// MARK: - 開始

render();
updateScene();
scheduleClock();
// 第一次開 3D 檢視：自動彈一次操作說明（記在設定）
if (!prefs.get("helpShown", false) && !demoMode) { setTimeout(() => { S.helpOpen = true; prefs.set("helpShown", true); renderBar(); }, 1000); }
if (host) {
  host.addEventListener("message", e => onMessage(e.data));
  host.postMessage({ type: "ready" });
} else if (demoMode) {
  // 示範：bench 的 Mac 輸入（同一份 Mac dump）；保全 ?guard=alert|notice|normal 換成 OfficeDemo 的假狀態
  const input = await (await fetch(params.get("input") ?? "./bench/mac-input.json")).json();
  if (params.get("guard")) input.guardStatus = OfficeDemo.guardStatus(params.get("guard"));
  if (params.get("lighting")) S.lighting = params.get("lighting");
  if (params.get("style")) S.style = params.get("style");          // 測試：SHOWORK_OFFICE_STYLE（不寫回設定）
  apply({ ...input, type: "office2", site: WeatherSite.taipei, weather: null, b1Posts: OfficeDemo.b1Posts() });
  if (params.get("answer")) { S.answeringId = params.get("answer"); render(); updateScene(); }
  if (params.has("guardcard")) { S.guardOpen = true; render(); updateScene(); }
  if (params.get("citycard")) { S.cityOpen = params.get("citycard"); render(); updateScene(); }
  if (params.has("b1board")) { S.boardOpen = true; render(); updateScene(); }
  if (params.get("talk")) { talk(params.get("talk")); render(); }
  if (params.get("focus")) { focusFloor(params.get("focus")); }
} else {
  $("empty").textContent = "沒有資料：在 ShoWork42 戰情中心裡開，或加 ?demo=1 看示範";
  $("empty").hidden = false;
}
window.__ready = true;
