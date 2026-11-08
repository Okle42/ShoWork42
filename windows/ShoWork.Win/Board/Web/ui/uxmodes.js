// 3D 辦公室的介面模式（11-08 H5，使用者選「全部都做，可以切換」；模擬圖在 ~/Desktop/ShoWork42_3D參考/UIUX_優化方案.png）：
//   版面：標準（三欄）／專注（A：收起左右欄，收件匣按鈕滑出）／儀表板（B：3D 全幅，左上數據、右側即時動態、左下專案狀態）
//   名牌：完整／極簡（D：狀態色點＋名字，滑過去才顯示狀態）
//   人物資訊卡（C）：點人物在旁邊彈出卡片（狀態、在做什麼、最後一句、ctx），可回答、跳到視窗
//   區域聚焦（E）：點上方某一區，其他地方變暗、右邊列出這區的人
// 設定存在 localStorage「office.ux」。3D 區域左上分頁列最後面的「介面」按鈕打開設定。

import * as THREE from "three";
import { bubbleLine } from "../scene/builder.js";
import { OfficeLabels } from "./labels.js";

const KEY = "office.ux";
const DEF = { layout: "standard", labels: "full", infoCard: true, focus: true };
const MOOD = { working: ["工作中", "#a78bfa"], waiting: ["等你", "#ff6b6b"], stuck: ["卡住", "#ffa94d"], finished: ["做完", "#69db7c"], idle: ["閒著", "#adb5bd"], asleep: ["睡著", "#868e96"] };
const esc = s => String(s ?? "").replace(/[&<>"]/g, c => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" })[c]);
const ago = t => { if (!t) return ""; const s = Date.now() / 1000 - (t > 1e12 ? t / 1000 : t); return s < 60 ? "剛剛" : s < 3600 ? `${Math.floor(s / 60)} 分` : s < 86400 ? `${Math.floor(s / 3600)} 小時` : `${Math.floor(s / 86400)} 天`; };

export class UxModes {
  constructor(view, wrap) {
    this.view = view; this.wrap = wrap;
    try { this.s = { ...DEF, ...JSON.parse(localStorage.getItem(KEY) ?? "{}") }; } catch { this.s = { ...DEF }; }
    this.layer = document.createElement("div"); this.layer.id = "uxLayer"; wrap.appendChild(this.layer);
    this.card = null; this.focusId = null;
    this.apply();
  }
  save() { localStorage.setItem(KEY, JSON.stringify(this.s)); }
  get minimal() { return this.s.labels === "minimal"; }

  /** 套用版面（body class）＋重畫疊層 */
  apply() {
    const b = document.body.classList;
    b.toggle("ux-focus", this.s.layout === "focus");
    b.toggle("ux-hud", this.s.layout === "hud");
    if (this.s.layout === "standard") b.remove("ux-inbox-open");
    window.dispatchEvent(new Event("resize"));
    this.refresh();
  }

  people() {
    const out = [];
    for (const i of this.view.builder.lastIslands ?? []) for (const p of i.people) out.push({ ...p, project: i.project });
    return out;
  }

  /** 資料變了（每次 office2 更新）：重畫儀表板、收件匣按鈕、聚焦清單、開著的資訊卡 */
  refresh() {
    this.layer.innerHTML = "";
    const ps = this.people();
    if (this.s.layout === "focus" || this.s.layout === "hud") this.drawInboxButton(ps);
    if (this.s.layout === "hud") this.drawHud(ps);
    if (this.focusId) this.drawFocus(ps);
    if (this.card) this.showCard(this.card.id, true);
  }

  drawInboxButton(ps) {
    const n = ps.filter(p => p.mood === "waiting").length;
    const btn = document.createElement("button");
    btn.className = "ux-inbox-btn";
    btn.innerHTML = `☰ 收件匣${n ? ` <b>${n}</b>` : ""}`;
    btn.onclick = () => { document.body.classList.toggle("ux-inbox-open"); };
    this.layer.appendChild(btn);
  }

  drawHud(ps) {
    const count = m => ps.filter(p => p.mood === m).length;
    const stats = document.createElement("div"); stats.className = "ux-card ux-stats";
    stats.innerHTML = ["working", "waiting", "stuck", "finished", "idle"].map(m => `<div><small>${MOOD[m][0]}</small><b style="color:${MOOD[m][1]}">${count(m)}</b></div>`).join("")
      + `<div><small>全部</small><b>${ps.length}</b></div>`;
    const feed = document.createElement("div"); feed.className = "ux-card ux-feed";
    const recent = ps.slice().sort((a, b) => (b.card.lastActivity ?? 0) - (a.card.lastActivity ?? 0)).slice(0, 7);
    feed.innerHTML = `<h4>即時動態</h4>` + recent.map(p => `<div class="it" data-id="${esc(p.card.id)}"><i style="background:${MOOD[p.mood]?.[1] ?? "#adb5bd"}"></i><div><p><b>${esc(OfficeLabels.shortName(p.card))}</b> ${esc(bubbleLine(p.card)).slice(0, 60)}</p><small>${esc(p.project)}・${ago(p.card.lastActivity)}</small></div></div>`).join("");
    feed.onclick = e => { const id = e.target.closest(".it")?.dataset.id; if (id) this.view.onClick?.(id); };
    const proj = document.createElement("div"); proj.className = "ux-card ux-proj";
    const byP = new Map(); for (const p of ps) { if (!byP.has(p.project)) byP.set(p.project, []); byP.get(p.project).push(p); }
    proj.innerHTML = `<h4>專案狀態</h4>` + [...byP].slice(0, 6).map(([n, list]) => `<div class="row"><span>${esc(n)}</span><div class="bar">${["working", "waiting", "stuck", "finished", "idle", "asleep"].map(m => { const k = list.filter(p => p.mood === m).length; return k ? `<i style="flex:${k};background:${MOOD[m][1]}" title="${MOOD[m][0]} ${k}"></i>` : ""; }).join("")}</div><small>${list.length}</small></div>`).join("");
    this.layer.append(stats, feed, proj);
  }

  // MARK: 人物資訊卡（C）

  /** 3D 裡點到人物：卡片開在那個人旁邊（回傳 true＝已處理，不用再開舊的回答卡以外的東西） */
  clicked(id) {
    if (!this.s.infoCard || !id || id === "guard" || id.includes(":")) { this.closeCard(); return; }
    this.showCard(id);
  }
  closeCard() { this.card?.el?.remove(); this.card = null; }
  showCard(id, keepPos = false) {
    const p = this.people().find(x => x.card.id === id);
    if (!p) { this.closeCard(); return; }
    const c = p.card, [mt, mc] = MOOD[p.mood] ?? ["", "#adb5bd"];
    const el = this.card?.el ?? document.createElement("div");
    el.className = "ux-pcard";
    const ask = c.permit?.summary ?? c.report?.ask ?? null;
    el.innerHTML = `<div class="hd"><div class="av" style="background:${mc}">${esc(OfficeLabels.shortName(c).slice(0, 1))}</div><div class="nm"><b>${esc(OfficeLabels.shortName(c))}</b><small>${esc(p.project)}${c.ctx?.tokens ? `・ctx ${Math.round(c.ctx.tokens / 1000)}k` : ""}</small></div><span class="st" style="color:${mc};background:${mc}22">● ${mt}</span><button class="x" title="關閉">✕</button></div>
      <div class="bd">${ask ? `<div class="k">${c.permit ? "要執行" : "要你決定"}</div><pre>${esc(ask)}</pre>` : ""}<div class="k">在做什麼</div><div>${esc(bubbleLine(c)) || "（沒有回報）"}</div>${c.lastActivity ? `<div class="k">最後動作</div><div>${ago(c.lastActivity)}前</div>` : ""}</div>
      <div class="bar">${p.mood === "waiting" ? `<button class="p" data-a="answer">回答</button>` : ""}<button data-a="jump">${c.kind === "board" ? "打開工作視窗" : "跳到它的視窗"}</button><button data-a="talk">看對話</button></div>`;
    el.querySelector(".x").onclick = () => this.closeCard();
    el.querySelectorAll("[data-a]").forEach(b => { b.onclick = () => { this.view.onInfoAction?.(id, b.dataset.a); if (b.dataset.a !== "talk") this.closeCard(); }; });
    if (!el.parentElement) this.wrap.appendChild(el);
    this.card = { id, el };
    if (!keepPos) this.placeCard();
  }
  placeCard() {
    const n = this.card && this.view.builder.personNode(this.card.id);
    if (!n) return;
    const v = n.getWorldPosition(new THREE.Vector3()).project(this.view.cam);
    const W = this.wrap.clientWidth, H = this.wrap.clientHeight;
    let x = (v.x + 1) / 2 * W + 30, y = (1 - v.y) / 2 * H - 120;
    const w = 320, h = this.card.el.offsetHeight || 260;
    if (x + w > W - 10) x = (v.x + 1) / 2 * W - w - 30;
    this.card.el.style.left = `${Math.max(10, x)}px`; this.card.el.style.top = `${Math.min(Math.max(50, y), H - h - 10)}px`;
  }

  // MARK: 區域聚焦（E）

  zone(id) {
    if (!this.s.focus) { this.focusId = null; return; }
    this.focusId = id;
    this.refresh();
    setTimeout(() => this.refresh(), 1100);           // 鏡頭飛完再算一次亮區位置
  }
  clearZone() { if (!this.focusId) return; this.focusId = null; this.refresh(); }
  drawFocus(ps) {
    const b = this.view.builder, r = b.zoneRect?.(this.focusId);
    if (!r) return;
    const os = 0.5, cz = b.root?.position.z ?? 0, y = b.root?.position.y ?? 0;
    const pts = [[r.x0, r.z0], [r.x1, r.z0], [r.x0, r.z1], [r.x1, r.z1]].map(([x, z]) => new THREE.Vector3(x * os, y + 0.6, cz + z * os).project(this.view.cam));
    const W = this.wrap.clientWidth, H = this.wrap.clientHeight;
    const xs = pts.map(p => (p.x + 1) / 2 * W), ys = pts.map(p => (1 - p.y) / 2 * H);
    const cx = (Math.min(...xs) + Math.max(...xs)) / 2, cy = (Math.min(...ys) + Math.max(...ys)) / 2;
    const rx = (Math.max(...xs) - Math.min(...xs)) / 2 + 40, ry = (Math.max(...ys) - Math.min(...ys)) / 2 + 40;
    const dim = document.createElement("div"); dim.className = "ux-dim";
    dim.style.background = `radial-gradient(ellipse ${rx}px ${ry}px at ${cx}px ${cy}px, rgba(0,0,0,0) 72%, rgba(5,6,10,.6) 100%)`;
    const title = b.zones?.().find(z => z.id === this.focusId)?.title ?? "";
    const inZone = ps.filter(p => {
      const n = b.personNode(p.card.id); if (!n) return false;
      const q = n.getWorldPosition(new THREE.Vector3()); const lx = q.x / os, lz = (q.z - cz) / os;
      return lx >= r.x0 - 0.2 && lx <= r.x1 + 0.2 && lz >= r.z0 - 0.2 && lz <= r.z1 + 0.2;
    });
    const list = document.createElement("div"); list.className = "ux-card ux-zone";
    list.innerHTML = `<div class="zh"><b>${esc(title)}</b><button class="x" title="結束聚焦">✕</button><small>${inZone.length} 個人${inZone.filter(p => p.mood === "waiting").length ? `・${inZone.filter(p => p.mood === "waiting").length} 個等你` : ""}</small></div>`
      + (inZone.length ? inZone.map(p => `<div class="it" data-id="${esc(p.card.id)}"><i style="background:${MOOD[p.mood]?.[1] ?? "#adb5bd"}"></i><div><b>${esc(OfficeLabels.shortName(p.card))}</b><small>${esc(bubbleLine(p.card)).slice(0, 34)}</small></div>${p.mood === "waiting" ? `<button data-a="answer">回答</button>` : `<button data-a="talk">看</button>`}</div>`).join("") : `<div class="none">這區現在沒有人</div>`);
    list.querySelector(".x").onclick = () => this.clearZone();
    list.querySelectorAll(".it").forEach(it => { it.onclick = e => { const a = e.target.dataset.a ?? "talk"; this.view.onInfoAction?.(it.dataset.id, a); }; });
    this.layer.append(dim, list);
  }

  // MARK: 設定面板

  toggleSettings(anchor) {
    if (this.panel) { this.panel.remove(); this.panel = null; return; }
    const p = document.createElement("div"); p.className = "ux-card ux-settings";
    const seg = (key, opts) => `<div class="seg" data-k="${key}">${opts.map(([v, t]) => `<button data-v="${v}" class="${String(this.s[key]) === String(v) ? "on" : ""}">${t}</button>`).join("")}</div>`;
    p.innerHTML = `<h4>介面</h4><div class="ux-lbl">版面</div>${seg("layout", [["standard", "標準"], ["focus", "專注"], ["hud", "儀表板"]])}
      <div class="ux-lbl">名牌</div>${seg("labels", [["full", "完整"], ["minimal", "極簡"]])}
      <div class="ux-lbl">點人物</div>${seg("infoCard", [[true, "彈出資訊卡"], [false, "不彈"]])}
      <div class="ux-lbl">點區域分頁</div>${seg("focus", [[true, "聚焦這區"], [false, "只移鏡頭"]])}`;
    p.querySelectorAll(".seg").forEach(sg => sg.querySelectorAll("button").forEach(bt => {
      bt.onclick = () => {
        const k = sg.dataset.k, v = bt.dataset.v;
        this.s[k] = v === "true" ? true : v === "false" ? false : v;
        this.save();
        sg.querySelectorAll("button").forEach(x => x.classList.toggle("on", x === bt));
        if (k === "infoCard" && !this.s.infoCard) this.closeCard();
        if (k === "focus" && !this.s.focus) this.focusId = null;
        if (k === "labels") this.view.labelSig = "", this.view.lastGuard && this.view.refreshLabels(...this.view.lastGuard);
        this.apply();
      };
    }));
    const r = anchor.getBoundingClientRect(), w = this.wrap.getBoundingClientRect();
    p.style.left = `${Math.max(10, r.right - w.left - 250)}px`; p.style.top = `${r.bottom - w.top + 8}px`;
    this.wrap.appendChild(p); this.panel = p;
  }
}
