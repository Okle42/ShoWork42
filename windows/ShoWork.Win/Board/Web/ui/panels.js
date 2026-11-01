// OfficeView.swift 的 SwiftUI 疊層照搬（11-02 P8）：需要你列（AttentionBar）、樓層索引列（FloorRail）、右上控制（燈光／風格／天氣／重新裝潢／重設視角／說明）、
// 天氣列（WeatherStrip）與地點面板（WeatherPlaces）、停在角色上的細節卡（HoverCard）、回答卡（AnswerCard）、保全（GuardHover／GuardCard／
// PushGuardSection／OnlineDeviceList）、Agent交流互動板（B1BoardCard）、城市細節卡與懸停卡（OfficeCity.swift 的 CityCard／CityHoverCard／CityDetail／UsageBar）、
// 操作說明（OfficeHelp）、右鍵選單（NSMenu）、下拉選單（SwiftUI.Menu）。
// 每個元件是一個函式：吃資料＋回呼，回傳 DOM（狀態在 office.js）。字級照 macOS 的 SwiftUI 字級：headline 13 粗、callout 12、caption 10。

import { h, Icon } from "./dom.js";
import { Mood, GuardLevel, GuardDeviceKind, OfficeLighting, OfficeStyle, WeatherSite, weatherSymbol, TowerThemeTitle,
         timeShort, dateTimeShort, relativeNamed, cityAgo, nowSec, sec } from "./core.js";
import { KuboArt, officeLine, tokenShort, ContextGuard } from "../scene/builder.js";
import { CityText, CityRules, CloudSync } from "../scene/city-model.js";
import { CityBuilder } from "../scene/city.js";
import { WeatherKind } from "../scene/weather.js";

const tint = m => KuboArt.tint(m).css;
const RED = "rgb(240,69,69)", ORANGE = "rgb(250,115,23)", GREEN = "rgb(33,196,94)", PURPLE = "rgb(166,140,250)";   // Color(red: 0.94, green: 0.27, blue: 0.27) 等

/** 卡片右上的關閉鈕（xmark.circle.fill、.secondary） */
const closeBtn = (onClose, label = "關閉") => h("button.plain.close", { title: label, "aria-label": label, on: { click: onClose } }, Icon("xmark.circle.fill", 16));

// MARK: - 需要你列（AttentionBar）

/** 頂部「需要你」列：● N 等你、● N 卡住、● N 設備警示、● N 做完、「M 人在 K 層」；右邊放控制。依寬度退到短字、再退到只剩數字（ViewThatFits） */
export function AttentionBar({ summary, alerts = 0, onAlerts, onWaiting, onStuck, onFinished, controls }) {
  const row = st => {
    const r = h("div.attn-row", { "data-style": st });
    const empty = !summary.waiting.length && !summary.stuck.length && !summary.finished.length;
    if (empty && alerts === 0) r.append(h("span.attn-none", Icon("checkmark.circle", 14), "沒有人在等你"));
    const chip = (n, title, c, action, help) => {
      if (!(n > 0)) return null;
      return h("button.chip", { title: help, style: { "--c": c }, on: { click: action } },
        h("i.dot"), h("span.n", st === "dots" ? `${n}` : `${n} ${title}`));
    };
    r.append(...[
      chip(summary.waiting.length, "等你", RED, onWaiting, "依時間先後輪流：鏡頭飛過去並打開回答卡"),
      chip(summary.stuck.length, "卡住", ORANGE, onStuck, "依時間先後輪流：鏡頭飛過去"),
      chip(alerts, st === "full" ? "設備警示" : "警示", RED, onAlerts, "設備警示（外部空間城市）：滿了的碟、離線的伺服器、防火牆、敞開的埠、電廠過熱；點一下輪流飛過去並打開細節"),
      chip(summary.finished.length, "做完", GREEN, onFinished, "依時間先後輪流：鏡頭飛過去、細節卡停 6 秒"),
      st === "full" ? h("span.attn-count", `${summary.people} 人在 ${summary.floors} 層`) : null,
    ].filter(Boolean));
    r.append(h("span.spacer"));
    r.append(controls());
    return r;
  };
  const bar = h("div#attnBar.material");
  // ViewThatFits：先試完整版，放不下換短字、再換只剩數字（office.js 排版後呼叫 fit）
  bar.fit = () => {
    for (const st of ["full", "short", "dots"]) {
      bar.replaceChildren(row(st));
      if (bar.firstChild.scrollWidth <= bar.firstChild.clientWidth + 1) return;
    }
  };
  bar.fit();
  return bar;
}

// MARK: - 樓層索引列（FloorRail）

/** 左側樓層索引列（寬 196）：由上往下＝大樓由上往下；點樓層＝鏡頭對準，再點一次回預設；閒置那行可展開；大廳行點了開保全卡 */
export function FloorRail({ rows, selected, guardLevel, cityAlerts = 0, idleOpen, onIdleToggle, onFloor, onHover, onGuard }) {
  const list = h("div.rail-list");
  const badges = r => h("span.badges",
    r.kind === "lobby" ? [h("i.dot", { style: { background: GuardLevel.color[guardLevel] } }), h("span", { style: { color: GuardLevel.color[guardLevel] } }, GuardLevel.title[guardLevel])] : null,
    r.waiting > 0 ? h("span", { style: { color: RED } }, `●${r.waiting}`) : null,
    r.stuck > 0 ? h("span", { style: { color: ORANGE } }, `●${r.stuck}`) : null,
    r.finished > 0 ? h("span", { style: { color: GREEN } }, `✓${r.finished}`) : null,
    r.working > 0 ? h("span", { style: { color: PURPLE } }, `${r.working}`) : null);
  for (const r of rows) {
    const b = h("button.rail-row", {
      class: (selected === r.id ? "sel " : "") + (r.kind === "project" && !r.active ? "dim" : ""),
      title: r.kind === "idle" ? "展開閒置專案清單" : r.kind === "lobby" ? "打開保全面板" : "鏡頭對準這層；再點一次回到預設",
      on: {
        click: () => { if (r.kind === "idle") onIdleToggle(r.id); else if (r.kind === "lobby") onGuard(); else onFloor(r.id); },
        mouseenter: () => onHover(r.id), mouseleave: () => onHover(null),
      },
    },
      h("i.accent", { style: { background: r.accent ?? "rgba(142,142,147,.4)" } }),
      h("span.rail-text",
        h("span.rail-title", r.floorNo ? h("span.no", r.floorNo) : null, h("span.t", r.title),
          r.kind === "idle" ? Icon(idleOpen ? "chevron.down" : "chevron.right", 11, "chev") : null),
        h("span.rail-sub", h("span.s", r.subtitle), badges(r))));
    list.append(b);
    if (r.kind === "idle" && idleOpen) {
      for (const p of r.idleNames) {
        list.append(h("button.rail-idle", { on: { click: () => onFloor(r.id) } },
          h("i.accent", { style: { background: p.accent ?? "rgba(142,142,147,.5)" } }),
          h("span.no", p.floorNo ?? ""), h("span.t", p.name)));
      }
    }
  }
  // 最下面一行「城市」：點了鏡頭飛到俯瞰城市，再點一次回預設（10-21）
  list.append(h("button.rail-row", { class: selected === "city" ? "sel" : "", title: "鏡頭飛到俯瞰城市（這台電腦的外部資源）；再點一次回到預設", on: { click: () => onFloor("city") } },
    h("i.accent", { style: { background: "rgb(166,163,158)" } }),
    h("span.rail-text",
      h("span.rail-title", Icon("building.2", 14, "sec"), h("span.t", "城市")),
      h("span.rail-sub", h("span.s", "硬碟・雲端・伺服器・城牆"), cityAlerts > 0 ? h("span.badges", h("span", { style: { color: RED } }, `!${cityAlerts}`)) : null))));
  return h("div#rail.material", h("div.rail-head", "樓層"), list);
}

// MARK: - 下拉選單（SwiftUI.Menu）與右鍵選單（NSMenu）

let openMenu = null;
export function closeMenu() { openMenu?.remove(); openMenu = null; }
document.addEventListener("pointerdown", e => { if (openMenu && !openMenu.contains(e.target)) closeMenu(); }, true);
document.addEventListener("keydown", e => { if (e.key === "Escape") closeMenu(); });
/** items：{ label, action, checked, disabled, header, separator, note, toggle } */
export function showMenu(x, y, items) {
  closeMenu();
  const m = h("div.menu", { role: "menu" });
  for (const it of items) {
    if (it.separator) { m.append(h("div.sep")); continue; }
    if (it.header) { m.append(h("div.mhead", it.header)); continue; }
    if (it.note) { m.append(h("div.mnote", it.note)); continue; }
    m.append(h("button.mitem", { disabled: !!it.disabled, role: "menuitem", on: { click: () => { closeMenu(); it.action?.(); } } },
      h("span.check", it.checked ? "✓" : ""), h("span", it.label)));
  }
  document.body.append(m);
  const r = m.getBoundingClientRect();
  m.style.left = `${Math.max(4, Math.min(x, innerWidth - r.width - 4))}px`;
  m.style.top = `${Math.max(4, Math.min(y, innerHeight - r.height - 4))}px`;
  openMenu = m;
}
const menuButton = (content, help, items, extra = "") => {
  const b = h("button.mbtn" + extra, { title: help }, content, Icon("chevron.down", 10, "chev"));
  b.addEventListener("click", () => { const r = b.getBoundingClientRect(); showMenu(r.left, r.bottom + 4, items()); });
  return b;
};

// MARK: - 右上那組控制

export function Controls({ lighting, night, lightLabel, style, weather, weatherOpen, onWeatherOpen, onLighting, onStyle, onWeatherEnabled,
                           projectFloors, decor, onRedecorate, onReset, helpOpen, onHelp, weatherPlaces }) {
  const frag = h("span.controls");
  // 燈光＋風格＋真實天氣（一個選單）
  frag.append(menuButton(h("span.mlbl", Icon(lighting === "auto" ? "circle.lefthalf.filled" : night ? "moon.stars" : "sun.max", 15), lightLabel),
    "燈光：白天／夜晚（吊燈與螢幕發光）／自動（依這台電腦的時間）", () => [
      { header: "燈光" },
      ...OfficeLighting.allCases.map(l => ({ label: l === "auto" ? `自動（跟著${weather.main.title}日出日落）` : OfficeLighting.title[l], checked: l === lighting, action: () => onLighting(l) })),
      { separator: true },
      { header: "風格" },
      ...OfficeStyle.allCases.map(s => ({ label: OfficeStyle.title[s], checked: s === style, action: () => onStyle(s) })),
      { separator: true },
      { label: "真實天氣（點天氣列換地點）", checked: weather.enabled, action: () => onWeatherEnabled(!weather.enabled) },
      { note: weather.menuStatus },
    ]));
  frag.append(WeatherStrip({ weather, open: weatherOpen, onOpen: onWeatherOpen, places: weatherPlaces }));
  frag.append(menuButton(h("span.mlbl", Icon("paintbrush", 15), "重新裝潢"), "請 AI 依這層最近在做的事重新挑主題（有次數與成本上限：24 小時最多 8 次）", () => {
    const floors = projectFloors.map(f => f.project).filter(Boolean);
    if (!floors.length) return [{ note: "現在沒有專案樓層" }];
    return floors.map(p => ({ label: `${p}・${TowerThemeTitle[decor[p.toLowerCase()]?.theme] ?? "還沒決定"}`, action: () => onRedecorate(p) }));
  }));
  frag.append(h("button.tbtn", { title: "重設視角", on: { click: onReset } }, h("span.mlbl", Icon("scope", 15), "重設視角")));
  const help = h("button.tbtn.icon", { title: "操作說明", "aria-label": "操作說明", on: { click: onHelp } }, Icon("questionmark.circle", 16));
  frag.append(h("span.pop-anchor", help, helpOpen ? OfficeHelp() : null));
  return frag;
}

/** 操作說明（? 按鈕；第一次開 3D 檢視自動彈一次） */
export function OfficeHelp() {
  return h("div.popover.help",
    h("div.headline", "操作說明"),
    h("div.callout",
      h("div", "・拖曳：轉視角　捲動：放大縮小　按住滾輪拖曳：平移"),
      h("div", "・WASD／方向鍵：走動　Q／E：升降"),
      h("div", "・點角色（或它的名牌）：右邊看它的對話、直接跟它講話；等你回答的另外開回答卡；要開終端機按窗格上的終端機鈕或右鍵"),
      h("div", "・右鍵角色：放行、退回、派工、重新裝潢⋯"),
      h("div", "・左邊樓層列：點一下鏡頭對準那層，再點一次回到預設"),
      h("div", "・上面「需要你」：依時間先後輪流飛過去")));
}

// MARK: - 天氣列（WeatherStrip）＋地點面板（WeatherPlaces）

/** weather＝{ enabled, sites:[{ site, report:{ now, at }|null, failed }], main, menuStatus } */
export function WeatherStrip({ weather, open, onOpen, places }) {
  if (!weather.enabled) return h("span");
  const b = h("button.plain.weather", { "aria-label": "天氣地點", on: { click: () => onOpen(!open) } });
  for (const { site, report: r, failed } of weather.sites) {
    const bad = !r && failed;
    const kind = r ? WeatherKind.classify(r.now) : null;
    const tip = r ? `${site.title} ${WeatherKind.title[kind]} · 陣風 ${Math.round(r.now.gust * 3.6)} km/h\n${timeShort(r.at)} 更新（Open-Meteo 每 10 分鐘）` + (WeatherSite.same(site, weather.main) ? "\n3D 辦公室的雲、雨、颱風跟著這裡" : "") + "\n點一下換地點"
      : bad ? `${site.title}：抓不到天氣（離線或服務沒回應），10 分鐘後再試` : `${site.title}：讀取中`;
    b.append(h("span.wsite", { title: tip },
      Icon(r ? weatherSymbol(kind) : bad ? "cloud.slash" : "hourglass", 14),
      h("span", { class: WeatherSite.same(site, weather.main) && weather.sites.length > 1 ? "b" : "" }, site.title),
      h("span", r ? WeatherKind.title[kind] : bad ? "—" : "讀取中"),
      r ? h("span.ter.num", timeShort(r.at)) : null));
  }
  return h("span.pop-anchor", b, open ? places() : null);
}

/** 地點面板：目前的清單（第一個是主天氣，星號換主天氣、減號移除、至少留一個）＋搜尋任何城市加入（最多 5 個） */
export function WeatherPlaces({ weather, query, results, searchNote, onSites, onQuery }) {
  const sites = weather.sites.map(s => s.site);
  const list = h("div.wp-list");
  for (const site of sites) {
    const main = WeatherSite.same(site, weather.main);
    list.append(h("div.wp-row",
      h("button.plain", { title: main ? "主天氣：3D 辦公室的雲、雨、颱風跟著這裡" : "設成主天氣", "aria-label": main ? "主天氣" : "設成主天氣",
                          style: { color: main ? "#FFD60A" : "var(--secondary)" }, on: { click: () => onSites(WeatherSite.makingMain(site, sites)) } }, Icon(main ? "star.fill" : "star", 15)),
      h("span.wp-name", h("span", site.title), site.detail ? h("span.caption.sec", site.detail) : null),
      h("button.plain.sec", { disabled: sites.length <= 1, title: sites.length <= 1 ? "至少要留一個地點" : "移除", "aria-label": `移除 ${site.title}`,
                              on: { click: () => onSites(WeatherSite.removing(site, sites)) } }, Icon("minus.circle", 15))));
  }
  const body = [h("div.headline", "天氣地點"), list, h("div.divider")];
  if (sites.length >= WeatherSite.limit) body.push(h("div.caption.sec", `最多 ${WeatherSite.limit} 個地點，先移除一個才能再加`));
  else {
    const input = h("input.field", { placeholder: "搜尋城市或地區（例如 高雄、東京）", value: query, "data-k": "weather-query" });
    input.addEventListener("input", () => onQuery(input.value));
    body.push(input);
    if (searchNote) body.push(h("div.caption.sec", searchNote));
    for (const r of results) {
      const have = sites.some(s => WeatherSite.same(s, r));
      body.push(h("button.plain.wp-result", { disabled: have, on: { click: () => { onSites(WeatherSite.adding(r, sites)); onQuery(""); } } },
        h("span", WeatherSite.fullName(r)), Icon(have ? "checkmark" : "plus.circle", 14)));
    }
  }
  body.push(h("div.caption.ter", `每台電腦各自記住；最多 ${WeatherSite.limit} 個，星號那個是主天氣`));
  return h("div.popover.places", ...body);
}

// MARK: - 細節卡（停在角色上）

/** Gauges（IslandView.swift）：完成度、信心度、ctx、自動交接 */
export function Gauges(card) {
  const prog = card.report?.progress ?? card.review?.progress ?? null;
  const conf = card.report?.confidence ?? card.review?.confidence ?? null;
  const item = (e, v, name) => h("span", { title: `${name} ${v !== null ? `${v}%` : "還沒有"}` }, `${e} ${v !== null ? `${v}%` : "—"}`);
  let ctx;
  const x = card.ctx;
  if (x) {
    const near = (x.tokens ?? 0) * 10 >= ContextGuard.tokenLimit * 8;     // 到門檻的 8 成先轉橘
    ctx = h("span", { style: { color: ContextGuard.over(x) ? "#ff453a" : near ? "#ff9f0a" : "", fontWeight: near ? 600 : "" },
                      title: "ctx（context 用量）" + (x.tokens != null ? `${Math.trunc(x.tokens / 1000)}k／門檻 ${ContextGuard.tokenLimit / 1000}k，` : "") + `${Math.trunc(x.percent)}%` },
      "🧠 " + (x.tokens != null ? `${Math.trunc(x.tokens / 1000)}k` : `${Math.trunc(x.percent)}%`));
  } else ctx = item("🧠", null, "ctx");
  return h("div.gauges", item("📈", prog, "完成度"), item("🎯", conf, "信心度"), ctx,
    card.handover ? h("span", { style: { color: "#ff9f0a", fontWeight: 600 }, title: `ctx 自動交接：${card.handover}` }, `🔁 ${card.handover}`) : null);
}

const activityLabel = a => ({ reading: "📖 讀檔中", editing: "⌨️ 改檔中", running: "▶️ 執行指令中", searching: "🔍 搜尋中", thinking: "💭 思考中", delegating: "🧑‍🤝‍🧑 交辦子 agent 中" })[a] ?? null;
const tokTotal = t => t.total ?? ((t.input ?? 0) + (t.output ?? 0) + (t.cacheCreation ?? 0) + (t.cacheRead ?? 0));

/** 停在角色上：左下角浮出的細節卡 */
export function HoverCard({ card, theme }) {
  const m = Mood.of(card);
  const t = card.tokens;
  return h("div.card.hover-card",
    h("div.card-head", h("i.dot", { style: { background: tint(m) } }), h("span.headline.trunc", card.title), h("span.caption.sec.trunc", card.project)),
    Gauges(card),
    activityLabel(card.activity) ? h("div.callout.medium", activityLabel(card.activity)) : null,
    h("div.callout.clamp3", officeLine(card)),
    (card.subagents ?? []).length ? h("div.caption.clamp2", "子 agent：" + card.subagents.map(s => s.description || (s.subagentType ?? "未命名")).join("、")) : null,
    t ? h("div.caption.sec.num", { title: `這個 session 累計的 token（不含子 agent）；這一輪輸出 ${t.lastTurnOutput ?? 0}` },
      `🔤 ${tokenShort(tokTotal(t))}　輸入 ${tokenShort(t.input ?? 0)}・輸出 ${tokenShort(t.output ?? 0)}・快取寫 ${tokenShort(t.cacheCreation ?? 0)}・快取讀 ${tokenShort(t.cacheRead ?? 0)}`) : null,
    theme ? h("div.caption.sec.trunc", { title: theme.source === "ai" ? "這層的主題是 AI 依最近的工作挑的" : "這層的主題是本地關鍵字判斷的（還沒問過 AI）" },
      `🏢 ${TowerThemeTitle[theme.theme] ?? theme.theme}・${theme.reason ?? ""}`) : null,
    h("div.caption.sec", `${card.reason}・${m === "waiting" ? "點一下回答" : "點一下跳到視窗"}，右鍵更多`));
}

/** 點了等你回答的角色：問題全文＋直接回答（10-20）。只有「要你決定」才給文字框；終端機選單只給「跳到視窗」 */
export function AnswerCard({ card, text, onText, onJump, onClose, onSend }) {
  const canType = String(card.reason ?? "").startsWith("要你決定");
  const body = [
    h("div.card-head", h("i.dot", { style: { background: tint("waiting") } }), h("span.headline.trunc", card.title), h("span.caption.sec.trunc", card.project),
      h("span.spacer"), closeBtn(onClose)),
    h("div.scroll.callout.select", { style: { maxHeight: "140px" } }, officeLine(card)),
  ];
  if (canType) {
    let sent = false;      // Return 可能同時觸發 onSubmit 和預設按鈕：只送一次（10-20 審查）
    const send = () => { const t = ta.value.trim(); if (!t || sent) return; sent = true; onSend(t); };
    const ta = h("textarea.field", { rows: 1, placeholder: "直接回答⋯", "data-k": `answer:${card.id}`, autofocus: true });
    ta.value = text;
    const btn = h("button.btn.default", { disabled: !text.trim(), on: { click: send } }, "送出");
    ta.addEventListener("input", () => { onText(ta.value); btn.disabled = !ta.value.trim(); autoGrow(ta, 4); });
    ta.addEventListener("keydown", e => { if (e.key === "Enter" && !e.shiftKey && !e.isComposing) { e.preventDefault(); send(); } });
    fileDrop(ta, () => ta.value, v => { ta.value = v; onText(v); btn.disabled = !v.trim(); });
    body.push(h("div.row", ta, btn));
    body.push(h("div.row", h("span.caption.sec", "在 tmux 裡會直接打進去送出；不在 tmux 的會拷貝並跳過去"), h("span.spacer"), h("button.btn.small", { on: { click: onJump } }, "跳到視窗")));
  } else {
    body.push(h("div.row", h("span.caption.sec", card.blockedReason === "permission" ? "它在等你按允許：要在終端機裡選" : "它開了選單在等你：要在終端機裡選"),
      h("span.spacer"), h("button.btn.default", { on: { click: onJump } }, "跳到視窗")));
  }
  return h("div.card.answer-card", { "data-esc": "close" }, ...body);
}

/** 文字框跟著內容長高（最多 n 行） */
export function autoGrow(ta, maxLines) {
  ta.style.height = "auto";
  const lh = parseFloat(getComputedStyle(ta).lineHeight) || 16;
  ta.style.height = `${Math.min(ta.scrollHeight, lh * maxLines + 10)}px`;
}

/** 拖檔案進來（10-25）：路徑接在這個輸入框的字後面（Inbox.withPaths）；WebView2 拖進來的 File 沒有完整路徑 ⇒ 用 C# 給的 path（見 PROTOCOL.md） */
export function fileDrop(el, get, set) {
  el.addEventListener("dragover", e => { if (e.dataTransfer?.types?.includes("Files")) { e.preventDefault(); el.classList.add("drop"); } });
  el.addEventListener("dragleave", () => el.classList.remove("drop"));
  el.addEventListener("drop", e => {
    el.classList.remove("drop");
    const files = [...(e.dataTransfer?.files ?? [])];
    if (!files.length) return;
    e.preventDefault();
    const paths = files.map(f => f.path || f.webkitRelativePath || f.name).filter(Boolean);
    import("./core.js").then(({ Inbox }) => set(Inbox.withPaths(get(), paths)));
  });
}

// MARK: - 前台・保全

const GuardBadge = level => h("span.gbadge", { style: { "--c": GuardLevel.color[level] } }, GuardLevel.title[level]);

/** 停在保全上：一句話摘要 */
export function GuardHover({ status, scanning }) {
  return h("div.card.guard-hover",
    h("div.card-head", h("span.headline", "🛡️ Security"), GuardBadge(status.level), scanning ? [h("span.spinner"), h("span.caption", "掃描中")] : null),
    h("div.callout", status.summary ?? ""),
    h("div.caption.sec", "點一下打開保全面板，右鍵可立即掃描"));
}

/** 保全面板裡的 push 守門：最近 24 小時檢查／擋下幾次＋最近幾筆 */
function PushGuardSection({ status, allowed, onAllow }) {
  const rows = (status.pushRecent ?? []).map(e => {
    const k = e.dir + (e.head ?? "");
    const canAllow = e.verdict === "block" && e.head && nowSec() - sec(e.at) < 3600;
    return h("div.pg-row",
      h("span.caption.semibold", { style: { color: e.verdict === "block" ? "#ff453a" : e.verdict === "warn" ? "#ff9f0a" : "#32d74b" } },
        e.verdict === "block" ? "擋下" : e.verdict === "warn" ? "提醒" : "放行"),
      h("span.pg-text",
        h("span.callout.trunc", `${e.repo}${(e.refs ?? []).length ? "・" + e.refs.join(",") : ""}・${e.commits} 個 commit` + (e.name ? `・${e.name}` : "")),
        (e.reasons ?? []).length ? h("span.caption.sec.clamp2.select", e.reasons.join("；")) : null),
      canAllow ? h("button.btn.small", { disabled: allowed.has(k), title: "這個 repo、這個 HEAD，30 分鐘內 AI 再推一次就不擋（用掉就失效）",
                                         on: { click: () => onAllow(e, k) } }, allowed.has(k) ? "已放行" : "放行一次") : null,
      h("span.caption2.sec.num", timeShort(e.at)));
  });
  return h("div.pg",
    h("div.row", h("span.caption.semibold.sec", "Push 守門"), h("span.spacer"),
      h("span.caption.num", { style: { color: (status.pushBlocked ?? 0) > 0 ? "#ff9f0a" : "var(--secondary)" } },
        !(status.pushChecked > 0) ? "24 小時內沒有 push" : `24 小時內 ${status.pushChecked} 次・擋下 ${status.pushBlocked} 次`)),
    ...rows,
    h("div.caption2.ter", "AI 跑 git push 前保全會先檢查：ghosts、old-history、force push main、金鑰、私人資料直接擋；關鍵字在 board/guard/keywords.txt。誤擋就按「放行一次」"));
}

/** 點了保全：Wi-Fi 狀態、要注意的裝置、立即掃描、定時巡邏（資料來自 wifiwatch） */
export function GuardCard({ status, scanning, wall = "", patrol, showOnline, onToggleOnline, onPatrol, onScan, onClose, allowed, onAllow }) {
  const flagged = status.flagged ?? [];
  const last = status.lastScan;
  const devRow = d => h("div.dev-row",
    h("i.dot.s7", { style: { background: d.online ? "#32d74b" : "rgba(142,142,147,.5)" }, title: d.online ? "上次掃描時在線" : "上次掃描時不在" }),
    h("span.caption.semibold", { style: { color: d.kind === "unconfirmed" ? "#ff9f0a" : "#ff453a" } }, GuardDeviceKind.title[d.kind] ?? d.kind),
    h("span.dev-text",
      h("span.callout.trunc", [d.ip ?? (d.privacyOnly ? "只有 IPv6（多半是家裡手機的隱私位址）" : null), d.vendor, d.label].filter(x => x).join("・")),
      h("span.caption.sec.mono.trunc.select", d.mac + (d.firstSeen ? `・第一次看到 ${dateTimeShort(d.firstSeen)}` : ""))));
  return h("div.card.guard-card", { "data-esc": "close" },
    h("div.card-head", h("span.headline", "🛡️ Security"), GuardBadge(status.level), h("span.spacer"), closeBtn(onClose)),
    h("div.callout", status.summary ?? ""),
    wall ? h("div.callout.labelrow", { style: { color: wall.includes("關閉") || wall.includes("紅門") ? "#ff453a" : "" } }, Icon("shield.lefthalf.filled", 14), wall) : null,
    h("div.grid.callout",
      h("span.sec", "上次掃描"),
      last ? h("span", { style: { color: status.stale ? "#ff9f0a" : "" } }, `${dateTimeShort(last)}（${relativeNamed(last)}）`) : h("span", { style: { color: "#ff9f0a" } }, "還沒掃描過"),
      h("span.sec", "在線裝置"),
      h("span.row", h("span.num", `${status.onlineCount ?? 0} 台（名冊共 ${status.knownCount ?? 0} 台）`),
        (status.onlineDevices ?? []).length ? h("button.link", { title: "列出上次掃描在線的每一台裝置", on: { click: onToggleOnline } }, showOnline ? "收起" : "列出全部") : null)),
    showOnline ? OnlineDeviceList(status.onlineDevices ?? []) : null,
    !flagged.length
      ? h("div.callout.sec.labelrow", Icon(status.hasData ? "checkmark.shield" : "questionmark.circle", 14), status.hasData ? "沒有陌生或沒命名的裝置" : "還沒有名冊（wifiwatch 沒跑過）")
      : [h("div.caption.semibold.sec", `要注意的裝置（${flagged.length}）`), h("div.scroll", { style: { maxHeight: "150px" } }, ...flagged.map(devRow))],
    h("div.divider"),
    PushGuardSection({ status, allowed, onAllow }),
    h("div.divider"),
    h("div.row",
      h("label.switch", { title: "開著時，常駐程式每 30 分鐘最多掃一次（只在 ShoWork42 常駐程式裡有效）" },
        h("input", { type: "checkbox", checked: !!patrol, on: { change: e => onPatrol(e.target.checked) } }), h("i"), h("span.callout", "定時巡邏")),
      h("span.spacer"),
      scanning ? h("span.spinner") : null,
      h("button.btn", { disabled: !!scanning, title: "跑 wifiwatch：ping 整個網段、讀 ARP，約數十秒；有新裝置會記進名冊", on: { click: onScan } }, scanning ? "掃描中⋯" : "立即掃描")),
    h("div.caption.ter", "命名裝置：wifiwatch.sh --label <MAC> <名字>"));
}

/** 保全面板「列出全部」：上次掃描在線的每一台 */
function OnlineDeviceList(devices) {
  return h("div.scroll", { style: { maxHeight: "220px" } }, ...devices.map(d => h("div.dev-row",
    h("i.dot.s7", { style: { background: d.kind === "named" ? "#32d74b" : d.kind === "unconfirmed" ? "#ff9f0a" : "#ff453a" }, title: GuardDeviceKind.title[d.kind] ?? "" }),
    h("span.dev-text",
      h("span.callout.trunc", { class: d.label ? "" : "sec" }, d.label ?? d.hostname ?? "（沒命名）"),
      h("span.caption.sec.trunc.select", [d.ip ?? "只有 IPv6", d.vendor, d.mac].filter(x => x).join("・"))))));
}

// MARK: - Agent交流互動板（點牆上的螢幕打開）：全部留言、最新在上

export function B1BoardCard({ posts, onRefresh, onClose, onScroll, top }) {
  const shown = posts.slice().reverse();
  const body = [
    h("div.card-head", h("span.headline", "Agent交流互動板"), h("span.caption.sec.num", `共 ${shown.length} 則`), h("span.spacer"),
      h("button.plain.sec", { title: "重新整理", "aria-label": "重新整理", on: { click: onRefresh } }, Icon("arrow.clockwise", 15)), closeBtn(onClose)),
    h("div.caption.sec", "AI 在 B1 休息時留下的工作心得；每則也會轉給隊長當流程優化的參考"),
  ];
  if (!shown.length) body.push(h("div.callout.sec", { style: { padding: "8px 0" } }, "還沒有留言。"));
  else {
    const sc = h("div.scroll.b1-list", { style: { maxHeight: "440px" } });
    shown.forEach((p, i) => {
      sc.append(h("div.b1-post", { "data-id": p.id },
        h("div.row",
          h("span.caption.semibold.sec.num", `#${p.id}`),
          h("span.callout.semibold", (p.name ?? "") + (p.project ? `（${p.project}）` : "")),
          p.re != null ? h("span.caption.sec", `↪#${p.re}`) : null,
          h("span.spacer"),
          h("span.caption2.sec.num", dateTimeShort(p.at))),
        h("div.callout.select.pre", p.text)));
      if (i < shown.length - 1) sc.append(h("div.divider"));
    });
    // 交流互動板捲到哪一則（最上面那則的編號）：關掉重開回到原位
    sc.addEventListener("scroll", () => {
      const first = [...sc.querySelectorAll(".b1-post")].find(e => e.offsetTop + e.offsetHeight > sc.scrollTop);
      if (first) onScroll(first.dataset.id);
    });
    requestAnimationFrame(() => { if (top != null) { const e = sc.querySelector(`.b1-post[data-id="${CSS.escape(String(top))}"]`); if (e) sc.scrollTop = e.offsetTop; } });
    body.push(sc);
  }
  return h("div.card.b1-card", { "data-esc": "close" }, ...body);
}

// MARK: - 城市細節卡＋懸停卡（OfficeCity.swift）

export const CityDetail = {
  title(id, city) {
    const d = city.disks.find(x => x.id === id); if (d) return `📦 貨櫃堆場・${CityText.diskName(d)}`;
    const c = city.clouds.find(x => x.id === id); if (c) return (CityBuilder.airshipStyle === 4 ? "🛸 飛碟・" : "🎈 飛艇・") + c.name;
    const s = city.servers.find(x => x.id === id); if (s) return `🏢 分公司・${s.alias}`;
    if (id === "city:wall" || id.startsWith("city:gate:")) return "🧱 城牆・防火牆";
    if (id === "city:power") return "🏭 電廠・AI 額度（5 小時）";
    if (id === "city:fuel") return "🛢 油槽・AI 額度（7 天）";
    if (id === "city:cooler") return "🌫 冷卻水塔・cool42";
    if (id === "city:port") return "⚓ 港口・GitHub";
    if (id.startsWith("ship:")) return `⛴ 出港・${id.slice(5).split("@")[0] ?? ""}`;
    return "城市";
  },

  body(id, city, compact = false) {
    const out = [];
    const grid = rows => h("div.grid", ...rows.flatMap(([k, v, warn]) => [h("span.sec", k), h("span", { style: { color: warn ? "#ff453a" : "" } }, v)]));
    const note = t => t ? h("div.caption.sec", t) : null;
    const d = city.disks.find(x => x.id === id);
    if (d) {
      const rows = [["種類", d.isInternal ? "內建碟（資料卷）" : "外接碟"]];
      const u = d.used;
      if (!d.mounted) { rows.push(["狀態", "已拔除"]); rows.push(["最後看到", d.lastSeen != null ? cityAgo(d.lastSeen) : "不知道（這版之前就拔掉了）"]); }
      else if (u !== null) {
        rows.push(["總容量", CityText.bytes(d.total)]);
        rows.push(["已用", `${CityText.bytes(d.total - d.available)}（${Math.round(u * 100)}%）`, d.alert]);
        if (d.isInternal) { rows.push(["可用", `${CityText.bytes(d.availablePlain)}（現在空著的）`]); rows.push(["重要用途可用", `${CityText.bytes(d.available)}（含系統可清出的快取）`]); }
        else rows.push(["可用", CityText.bytes(d.available)]);
        if (d.format) rows.push(["檔案系統", d.format]);
        if (d.mountPath) rows.push(["掛載點", d.mountPath]);
      } else rows.push(["容量", "讀不到"]);
      out.push(grid(rows));
      if (d.mounted && u !== null) out.push(UsageBar(u, d.alert));
      if (!compact) out.push(note(d.alert ? "90% 以上：貨櫃堆到圍籬外、倉庫頂亮紅燈" : "貨櫃層數＝已用比例（滿 4 層＝100%）"));
      return out;
    }
    const c = city.clouds.find(x => x.id === id);
    if (c) {
      const s = c.sync;
      if (c.isICloud && s) {
        const now = c.checkedAt ?? nowSec();
        const rows = [
          ["剩餘額度", s.remaining !== null ? CityText.bytes(s.remaining) : "讀不到", (s.remaining ?? Infinity) < CloudSync.lowQuota],
          ["iCloud Drive", s.stuck(now) ? `同步卡住（${s.driveState ?? ""}）` : s.driveState === "idle" ? (s.caughtUp ? "已同步" : "閒置") : `同步中（${s.driveState ?? ""}）`, s.stuck(now)],
          ["上次同步", s.lastSync !== null ? cityAgo(s.lastSync, now) : "沒有紀錄"],
          ["待同步", s.pending === 0 ? "沒有" : `${s.pending} 個 App 的資料`],
          ["被擋住", s.blocked === 0 ? "沒有" : `${s.blocked} 個 App 的資料`, s.blocked > 0],
        ];
        if (s.desktopDocs !== null) rows.push(["桌面與文件", s.desktopDocs ? "有同步到 iCloud" : "沒有同步"]);
        out.push(grid(rows));
        out.push(note("總額度 macOS 沒給讀，所以只寫剩多少；剩不到 5 GB 才警示。已刪除 App 的資料停止同步是正常的，不算。本機佔用不讀（掃 iCloud 資料夾會跳隱私權限視窗）。每 5 分鐘讀一次"));
      } else {
        out.push(h("div", c.isICloud ? "已連線（iCloud Drive 資料夾在這台 Mac 上；brctl 讀不到同步狀態）" : "已連線（資料夾掛在 ~/Library/CloudStorage）"));
        out.push(note(c.isICloud ? "" : `同步進度由 ${c.name} 自己的程式管，macOS 沒開放給其他程式讀`));
      }
      return out;
    }
    const sv = city.servers.find(x => x.id === id);
    if (sv) {
      const rows = [
        ["狀態", sv.online === null ? "檢查中" : sv.online ? "在線" : "離線", sv.alert],
        ["上次連上", sv.lastOnline !== null ? cityAgo(sv.lastOnline) : "這次開程式後還沒連上過", sv.alert],
        ["延遲", sv.latencyMs !== null ? `${sv.latencyMs} ms（TCP 連線）` : "—"],
      ];
      if (sv.hostName) rows.push(["位址", `${sv.hostName}:${sv.port ?? 22}`]);
      rows.push(["上次檢查", sv.checkedAt !== null ? cityAgo(sv.checkedAt) : "還沒"]);
      out.push(grid(rows));
      if (!compact) out.push(note("來自 ~/.ssh/config；每 60 秒對 ssh 埠連一次（2 秒逾時，只連這一個埠）"));
      return out;
    }
    if (id === "city:wall" || id.startsWith("city:gate:")) {
      const f = city.firewall;
      out.push(grid([
        ["防火牆", f.enabled === null ? "讀不到" : f.enabled ? "開著" : "關閉（城牆有缺口）", f.enabled === false],
        ["對外開放", `${f.gates.length} 個埠` + (f.openRed.length ? `，${f.openRed.length} 個沒有認證` : ""), f.openRed.length > 0],
        ["只給本機", `${f.doors.length} 個埠`],
      ]));
      if (f.gates.length) {
        const n = compact ? 8 : 20;
        out.push(h("div.caption.semibold.sec", "對外城門（別台電腦連得到）"));
        out.push(h("div.gates", ...f.gates.slice(0, n).map(g => h("div.caption.row",
          h("span.num.port", String(g.port)), h("span.trunc", g.knownOpen ?? g.process), g.openRed ? h("span", { style: { color: "#ff453a" } }, "⚠ 沒有認證") : null)),
          f.gates.length > n ? h("div.caption.sec", `⋯還有 ${f.gates.length - n} 個`) : null));
      }
      if (f.checkedAt !== null) out.push(note(`每 5 分鐘檢查；上次 ${cityAgo(f.checkedAt)}`));
      return out;
    }
    if (id === "city:power" || id === "city:fuel") {
      const g = city.grid, now = nowSec();
      out.push(grid([
        ["5 小時", CityRules.pct(g.fiveUsed) !== null ? `已用 ${CityRules.pct(g.fiveUsed)}%・剩 ${100 - CityRules.pct(g.fiveUsed)}%` : "讀不到", g.alert],
        ["重置", g.fiveReset !== null ? CityText.clock(g.fiveReset, now) : "—"],
        ["7 天", CityRules.pct(g.sevenUsed) !== null ? `已用 ${CityRules.pct(g.sevenUsed)}%・剩 ${100 - CityRules.pct(g.sevenUsed)}%` : "讀不到", (g.sevenLeft ?? 100) <= 5],
        ["重置", g.sevenReset !== null ? CityText.clock(g.sevenReset, now) : "—"],
        ["電力", ["正常", "節電（80% 以上，燈調暗）", "吃緊（95% 以上）", "停電（用完，AI 定格）"][["normal", "dim", "flicker", "blackout"].indexOf(g.stage)] ?? "正常", g.alert],
      ]));
      if (g.fiveLeft !== null) out.push(UsageBar(1 - g.fiveLeft / 100, g.alert));
      if (!compact) out.push(note("資料來自狀態列存的 rate_limits.json（有 session 在跑才會更新）；數字跟視窗右上角同一份"));
      return out;
    }
    if (id === "city:cooler") {
      const p = city.power;
      out.push(grid([
        ["溫度", p.temp !== null ? `約 ${CityRules.tempStep(p.temp)}°C（控制溫度，10°C 一格）` : "cool42 沒在跑", p.alert],
        ["CPU 平均", p.cpuAvg !== null ? `${Math.round(p.cpuAvg)}°C` : "—"],
        ["cool42 等級", (p.level ?? "—") + (p.stale ? "（超過 2 分鐘沒更新）" : ""), p.alert],
      ]));
      if (!compact) out.push(note("在大樓頂樓；煙越多越熱，hot 以上亮紅燈"));
      return out;
    }
    if (id === "city:port" || id.startsWith("ship:")) {
      out.push(h("div", `看著 ${city.repos} 個 repo 的遠端分支`));
      if (city.recent.length) {
        out.push(h("div.caption.semibold.sec", "最近 push／fetch"));
        out.push(h("div", ...city.recent.map(r => h("div.caption.row", h("span.trunc", r.repo), h("span.spacer"), h("span.sec", cityAgo(r.at))))));
      }
      if (city.ships.length) out.push(h("div.caption", "剛出港：" + city.ships.map(s => s.repo).join("、")));
      if (!compact) out.push(note("剛 push／fetch 有新東西，就有一艘貨船出港（時間＝遠端 ref 檔的修改時間）"));
    }
    return out;
  },
};

/** 使用率長條（≥90% 紅） */
export function UsageBar(value, alert = false) {
  const c = alert ? "#ff453a" : value >= 0.75 ? "#ff9f0a" : "var(--accent)";
  return h("div.usage", h("i", { style: { width: `max(4px, ${Math.min(1, Math.max(0, value)) * 100}%)`, background: c } }));
}

export function CityCard({ id, city, onClose }) {
  return h("div.card.city-card", { "data-esc": "close" },
    h("div.card-head", h("span.headline.trunc", CityDetail.title(id, city)), city.demo ? h("span.caption.sec", "示範資料") : null, h("span.spacer"), closeBtn(onClose)),
    h("div.callout.city-detail", ...CityDetail.body(id, city)));
}

/** 懸停卡：跟著滑鼠位置浮出來（不吃滑鼠、不擋點擊）；位置由 office.js 夾在畫面內 */
export function CityHoverCard({ id, city }) {
  return h("div.card.city-hover",
    h("div.card-head", h("span.t13.trunc", CityDetail.title(id, city)), city.demo ? h("span.caption2.sec", "示範資料") : null),
    h("div.t12.city-detail", ...CityDetail.body(id, city, true)),
    h("div.caption2.ter", "點一下釘住"));
}
