// 介面層用到的 ShoWorkCore 純函式（11-02 P8，照 Swift 逐行轉寫；名稱照舊）：
//   Mood.of（Islands.swift）、AttentionSummary／FloorRailRow／TowerIndex／LabelKind／LabelBox／PlacedLabel／LabelLayout（TowerHUD.swift）、
//   Inbox（Inbox.swift）、Board.plain（Board.swift）、Permit 的計算屬性（Permit.swift）、RunProgress（RunProgress.swift）、
//   OfficeLighting／OfficeStyle／GuardLevel（Office.swift）、WeatherSite（Weather.swift）、CaptainTask.State（Captain.swift）、
//   TowerTheme.title（TowerTheme.swift）、CityState.alerts（City.swift）。
// 資料形狀照 C# 推的 office2 JSON（MacMirror：時間是 Unix 秒、enum 是字串）；不碰 DOM、不碰 three。

import { SkyLook, Solar } from "../scene/solar.js";

/** Unix 秒（Swift 的 Date）；null／undefined 原樣回 null */
export const sec = d => d === null || d === undefined ? null : d instanceof Date ? d.getTime() / 1000 : Number(d);
export const nowSec = () => Date.now() / 1000;

// MARK: - Mood（Islands.swift）

export const Mood = {
  /** 角色的樣子，跟看板欄位一對一 */
  of(c) {
    switch (c.column) {
      case "active": return "working";
      case "review": return c.reason === "等你回答" || String(c.reason ?? "").startsWith("要你決定") ? "waiting" : "finished";
      case "stuck": return "stuck";
      default: return c.unused ? "asleep" : "idle";       // done、todo
    }
  },
};

// MARK: - 頂部「需要你」列（TowerHUD.swift）

export const AttentionSummary = {
  isEmpty: s => !s.waiting.length && !s.stuck.length && !s.finished.length,
  /** 依時間先後（最後活動早的先輪到；一樣就照 id） */
  make(cards) {
    const s = { waiting: [], stuck: [], finished: [], working: 0, people: 0, floors: 0 };
    const real = cards.filter(c => !c.id.includes("#"));
    const ordered = real.slice().sort((a, b) => {
      const ta = sec(a.lastActivity) ?? -Infinity, tb = sec(b.lastActivity) ?? -Infinity;
      return ta !== tb ? ta - tb : a.id < b.id ? -1 : a.id > b.id ? 1 : 0;
    });
    for (const c of ordered) {
      switch (Mood.of(c)) {
        case "waiting": s.waiting.push(c.id); break;
        case "stuck": s.stuck.push(c.id); break;
        case "finished": s.finished.push(c.id); break;
        case "working": s.working += 1; break;
      }
    }
    s.people = real.length;
    s.floors = new Set(real.map(c => String(c.project).toLowerCase())).size;
    return s;
  },
  /** 點「N 等你」輪流：上一次是誰 → 下一個（沒有上一次或上一次不在了 ⇒ 第一個） */
  next(last, ids) {
    if (!ids.length) return null;
    const i = last == null ? -1 : ids.indexOf(last);
    if (i < 0) return ids[0];
    return ids[(i + 1) % ids.length];
  },
};

// MARK: - TowerTheme.title（TowerTheme.swift）

export const TowerThemeTitle = {
  monitor: "監控中心", app_studio: "App 開發室", library: "研究書房", print_shop: "3D 列印工坊", call_room: "秘書電話室",
  trading_desk: "交易室", media_studio: "攝影棚", design_studio: "設計工作室", legal_room: "法務室", ledger_room: "財務帳房",
  game_lab: "遊戲工作室", hw_lab: "硬體實驗室", marketing: "行銷室", dispatch_room: "調度中心", drafting_room: "建築製圖室", general: "通用辦公",
};

// MARK: - 左側樓層索引列（TowerHUD.swift）

export const TowerIndex = {
  /** 由上往下＝大樓由上往下：RF、每個專案樓層、閒置 N、01 大廳。moods＝專案（小寫）→ 每個人的狀態；accentOf＝主題 → 識別色 */
  rows(plan, decor, moods, accentOf) {
    const out = [];
    const row = (kind, id, floorNo, title, subtitle, accent = null) =>
      ({ kind, id, floorNo, title, subtitle, accent, waiting: 0, stuck: 0, finished: 0, working: 0, people: 0, active: true, idleNames: [] });
    for (const f of (plan?.floors ?? []).slice().reverse()) {
      switch (f.kind) {
        case "roof":
          out.push(row("roof", f.id, "RF", "空中花園", "休息區", "#5C7F55"));
          break;
        case "project": {
          const k = String(f.project ?? "").toLowerCase();
          const d = decor?.[k];
          const r = row("project", f.id, f.floorNo, f.project ?? f.id, d ? TowerThemeTitle[d.theme] ?? d.theme : "還沒決定主題", d ? accentOf(d.theme) : null);
          const m = moods[k] ?? [];
          r.waiting = m.filter(x => x === "waiting").length;
          r.stuck = m.filter(x => x === "stuck").length;
          r.finished = m.filter(x => x === "finished").length;
          r.working = m.filter(x => x === "working").length;
          r.people = m.length;
          r.active = !!f.active;
          if (!f.active) r.subtitle += "・燈暗（2 小時內有人）";
          out.push(r);
          break;
        }
        case "idle": {
          const r = row("idle", f.id, "", `閒置 ${(f.plates ?? []).length}`, "沒有 AI 的專案");
          r.idleNames = f.plates ?? [];
          out.push(r);
          break;
        }
        case "lobby":
          out.push(row("lobby", f.id, "01", "大廳・保全", "前台"));
          break;
      }
    }
    return out;
  },
};

// MARK: - 螢幕空間標籤的碰撞避讓（TowerHUD.swift）

/** 標籤種類＝優先序（等你 > 卡住 > 做完 > 工作中 > 休息；樓層名、保全、閒置名字另外排） */
export const LabelKind = {
  waiting: 0, stuck: 1, finished: 2, cityAlert: 3, guardian: 4, floor: 5, working: 6, rest: 7, city: 8, idleName: 9, more: 10,
  /** 6 個位置都撞到時：true＝在自己那層裡找空位（一定要看得到）；false＝不畫、算進樓層的「+N」 */
  mustShow: k => k <= 4,
  name: k => ["waiting", "stuck", "finished", "cityAlert", "guardian", "floor", "working", "rest", "city", "idleName", "more"][k],
};

/** 一個標籤：錨點（頭頂在畫面上的點，y 往上）＋大小（點） */
export function LabelBox({ id, kind, ax, ay, w, h, group = "", ceil = Infinity, floorY = -Infinity }) {
  return { id, kind, ax, ay, w, h, group, ceil, floorY };
}
/** 左下角＋大小（y 往上） */
export function PlacedLabel({ id, kind, x, y, w, h, leader, ax, ay }) {
  return { id, kind, x, y, w, h, leader, ax, ay };
}
export const overlapsP = (p, o, gap = 0) => p.x < o.x + o.w + gap && o.x < p.x + p.w + gap && p.y < o.y + o.h + gap && o.y < p.y + p.h + gap;

export const LabelLayout = {
  gap: 4.0,
  /** 依優先序放（10-20 第 4 棒改：標籤一律留在自己那層裡）：
   *   1. 試 6 個位置：頭頂正上、往上一格（畫引線）、左上、右上、頭的左邊、頭的右邊；超過那層天花（ceil）或低於地坪（floorY）的不算
   *   2. 都撞到：在那層的範圍裡一列一列找（由頭頂往上、再往下；每列左右輪流挪），第一個空位
   *   3. 還是沒有：等你／卡住／做完／保全照樣找不到就算進那層的 +N（呼叫端把 +N 標成紅色）；工作中／休息直接收進 +N
   *   fixed＝先放好的（樓層名）：當障礙物，不回傳。width／height＝畫面寬高（標籤夾在畫面內） */
  place(boxes, width, height, fixed = []) {
    const gap = LabelLayout.gap;
    const placed = [];
    const taken = fixed.slice();
    const hidden = {};
    const order = boxes.map((b, i) => [b, i]).sort(([a, ia], [b, ib]) =>
      a.kind !== b.kind ? a.kind - b.kind : (a.ay !== b.ay ? b.ay - a.ay : ia - ib)).map(([b]) => b);
    const clampX = (x, w) => Math.min(Math.max(2, x), Math.max(2, width - w - 2));
    const clampY = (y, h) => Math.min(Math.max(2, y), Math.max(2, height - h - 2));     // 頭頂在畫面最上緣（頂樓的人）也不要被切掉
    const free = p => !taken.some(t => overlapsP(t, p, 1));
    for (const b of order) {
      const top = Math.min(b.ceil, height - 2), bottom = Math.max(b.floorY, 2);
      const inFloor = p => p.y + p.h <= top + 0.5 && p.y >= bottom - 0.5;
      const make = (x, y) => {
        const px = clampX(x, b.w), py = clampY(y, b.h);
        // 引線：標籤在頭頂正上方（水平蓋過錨點）而且離頭頂超過一格才畫
        const lead = px <= b.ax && b.ax <= px + b.w && py > b.ay + gap + b.h * 0.5;
        return PlacedLabel({ id: b.id, kind: b.kind, x: px, y: py, w: b.w, h: b.h, leader: lead, ax: b.ax, ay: b.ay });
      };
      const y0 = b.ay + gap;
      const side = b.ay - b.h * 0.85;
      const cands = [
        [b.ax - b.w / 2, y0],
        [b.ax - b.w / 2, y0 + b.h + gap],
        [b.ax - b.w - gap, y0],
        [b.ax + gap, y0],
        [b.ax - b.w - 14, side],
        [b.ax + 14, side],
      ];
      let got = null;
      for (const c of cands) {
        const p = make(c[0], c[1]);
        if (inFloor(p) && free(p)) { got = p; break; }
      }
      if (!got) {
        // 在自己那層裡找：等你／卡住／做完／保全找遍整層；工作中、休息只在頭附近（左右各 8 個半格）找，再擠不下就收進 +N
        const rows = [];
        let y = Math.max(bottom, 2);
        while (y + b.h <= top + 0.5) { rows.push(y); y += (b.h + gap) / 2; }
        // 每個候選位置按「離頭頂多近」排序，挑最近的空位（10-20 第 4 棒：原本一列一列找，名牌會跑到 80 pt 外）
        const step = b.w / 4 + gap;
        const reach = LabelKind.mustShow(b.kind) ? 24 : 8;
        const spots = [];
        for (const ry of rows) {
          for (let k = -reach; k <= reach; k++) {
            const p = make(b.ax - b.w / 2 + k * step, ry);
            if (!inFloor(p)) continue;
            const dx = Math.max(p.x - b.ax, 0, b.ax - (p.x + p.w)), dy = Math.max(p.y - b.ay, 0, b.ay - (p.y + p.h));
            spots.push([Math.hypot(dx, dy), p]);
          }
        }
        // Swift 的 sorted 不保證穩定；這裡用穩定排序（距離一樣時先列的先）
        spots.sort((a, b) => a[0] - b[0]);
        got = spots.find(s => free(s[1]))?.[1] ?? null;
      }
      if (got) { placed.push(got); taken.push(got); }
      else hidden[b.group] = (hidden[b.group] ?? 0) + 1;
    }
    return { placed, hidden };
  },
  /** 放好的標籤之間有沒有重疊（驗收印 overlaps=0） */
  overlaps(p) {
    let n = 0;
    for (let i = 0; i < p.length; i++) for (let j = i + 1; j < p.length; j++) if (overlapsP(p[i], p[j])) n += 1;
    return n;
  },
};

// MARK: - Board.plain（Board.swift）：markdown 拿掉語法、變一行

export const Board = {
  plain(s) {
    const lines = [];
    for (let l of String(s ?? "").split(/\r\n|\r|\n/)) {
      l = l.trim();
      while (l.startsWith("#") || l.startsWith(">")) l = l.slice(1);
      if (l.startsWith("- ") || l.startsWith("* ")) l = l.slice(2);
      if ([...l].every(ch => "|-: ".includes(ch))) continue;       // 表格分隔線（空字串也算：Swift allSatisfy 空集合＝true）
      l = l.replaceAll("**", "").replaceAll("`", "").replaceAll("|", " ").trim();
      if (l) lines.push(l);
    }
    return lines.join(" ");
  },
};

// MARK: - 權限對話框（Permit.swift）

export const Permit = {
  isAsk: p => p?.tool === "AskUserQuestion",
  isPlan: p => p?.tool === "ExitPlanMode",
  /** ExitPlanMode 的計畫內容 */
  plan(p) {
    if (!Permit.isPlan(p) || !p.input) return null;
    try { const o = JSON.parse(p.input); return typeof o.plan === "string" && o.plan ? o.plan : null; } catch { return null; }
  },
  /** 「一律允許」會加的規則，給人看的樣子：Bash(mkdir:*) */
  alwaysLabel(p) {
    if (!p?.alwaysRules) return null;
    let a; try { a = JSON.parse(p.alwaysRules); } catch { return null; }
    if (!Array.isArray(a)) return null;
    const xs = a.flatMap(x => Array.isArray(x?.rules) ? x.rules : []).map(r => {
      if (typeof r?.toolName !== "string") return null;
      return typeof r.ruleContent === "string" ? `${r.toolName}(${r.ruleContent})` : r.toolName;
    }).filter(Boolean);
    return xs.length ? xs.join("、") : null;
  },
  /** 一行：哪題、答什麼 */
  answerText(r, a) {
    if (Permit.isPlan(r)) return a.decision === "deny" ? "退回計畫" + (a.message ? `：${a.message}` : "") : "核准計畫";
    if (a.decision === "deny") return "不選選項" + (a.message ? `，回：${a.message}` : "");
    return (r.questions ?? []).map(q => `${q.question} → ${(a.answers?.[q.question] ?? []).join("、")}`).join("；");
  },
};

// MARK: - 收件匣（Inbox.swift）

export const Inbox = {
  genericOptions: ["好，照你的建議做", "先不要，等我想一下"],

  /** answered：sessionId → 你從戰情中心回答的時間（秒） */
  items(cards, answered = {}) {
    const out = [];
    for (const c of cards) {
      const p = c.permit;
      if (p) {     // 對話框開著就列，不管看板顏色（Notification 比 hook 晚到）
        const t = answered[c.sessionId], a = t != null && t > sec(p.at) ? t : null;
        const kind = Permit.isAsk(p) ? "ask" : Permit.isPlan(p) ? "plan" : "permit";
        const q = Permit.isAsk(p) ? "它問你" : Permit.isPlan(p) ? "計畫寫好了，要照這個做嗎？" : `要${Inbox.toolVerb(p.tool)}，可以嗎？`;
        out.push({ id: c.id, card: c, kind, question: q, context: Permit.isAsk(p) || Permit.isPlan(p) ? null : p.detail ?? null,
                   options: [], generic: false, since: sec(p.at), answered: a });
        continue;
      }
      if (Mood.of(c) !== "waiting") continue;
      const reply = String(c.reason ?? "").startsWith("要你決定");
      const ask = c.report?.ask?.trim();
      let q;
      if (ask) q = ask;
      else if (reply) q = [...c.reason].slice("要你決定：".length).join("");
      else q = c.blockedReason === "permission" ? "它在等你按允許" : "它在終端機開了選單等你選";
      const opts = reply ? (c.report?.options ?? []) : [];
      const since = sec(c.report?.at) ?? sec(c.lastActivity);
      const t = answered[c.sessionId], a = t != null && t > (since ?? -Infinity) ? t : null;
      const ctx = c.detail && c.detail !== q ? c.detail : null;
      out.push({ id: c.id, card: c, kind: reply ? "reply" : "menu", question: q, context: ctx,
                 options: reply ? (opts.length ? opts : Inbox.genericOptions) : [], generic: reply && !opts.length, since, answered: a });
    }
    // 還沒回答的在前；同一組裡等最久的在前
    return out.sort((a, b) => {
      if ((a.answered == null) !== (b.answered == null)) return a.answered == null ? -1 : 1;
      return (a.since ?? Infinity) - (b.since ?? Infinity);
    });
  },

  /** 權限對話框標題用的動詞 */
  toolVerb(tool) {
    switch (tool) {
      case "Bash": return "執行指令";
      case "Edit": case "MultiEdit": return "修改檔案";
      case "Write": return "寫入檔案";
      case "Read": return "讀取檔案";
      case "NotebookEdit": return "修改筆記本";
      case "WebFetch": return "開網頁";
      case "WebSearch": return "上網搜尋";
      default: return tool.startsWith("mcp__") ? `用工具 ${tool.split("__").filter(Boolean).slice(1).join("・")}` : `用 ${tool}`;
    }
  },

  /** 送給 AI 的那句話（選項按鈕和打字同一條路） */
  message(text) { return String(text ?? "").replaceAll("\n", " ").trim(); },

  /** 拖檔案進輸入框（10-25）：把路徑接在已經打的字後面，跟拖進終端機一樣 */
  withPaths(text, paths) {
    const ps = paths.filter(Boolean).map(Inbox.quote).join(" ");
    if (!ps) return text;
    if (!text) return ps + " ";
    return text + (text.endsWith(" ") || text.endsWith("\n") ? "" : " ") + ps + " ";
  },
  quote(p) {
    const special = " \t\n'\"\\$`!&*()[]{};<>?|#~";
    if (![...p].some(ch => special.includes(ch))) return p;
    return "'" + p.replaceAll("'", "'\\''") + "'";
  },
};

// MARK: - 背景長工作的進度（RunProgress.swift）

export const RunProgress = {
  staleAfter: 600,
  fresh: (r, now = nowSec()) => now - sec(r.updatedAt) <= RunProgress.staleAfter,
  belongs(r, who) {
    if (!who) return false;
    if (r.name) return r.name.toLowerCase() === who.toLowerCase();
    const l = r.label ?? "";
    return l.startsWith(who + " ") || l.startsWith(who + "：") || l.startsWith(who + "-");
  },
  /** 某個 AI 現在的進度：沒過期的裡面 updatedAt 最新的一個 */
  pick(all, who, now = nowSec()) {
    let best = null;
    for (const r of all ?? []) if (RunProgress.belongs(r, who) && RunProgress.fresh(r, now) && (!best || sec(r.updatedAt) > sec(best.updatedAt))) best = r;
    return best;
  },
  /** 進度條旁的字：label 拿掉開頭的名字，接 12/37 或 32%，有 eta 再接「還要 4 分」 */
  caption(r, who) {
    let l = r.label ?? "";
    if (!r.name && l.startsWith(who)) l = l.slice(who.length).replace(/^[ ：-]+|[ ：-]+$/g, "");
    const n = r.done != null && r.total != null ? `${r.done}/${r.total}` : `${Math.round((r.fraction ?? 0) * 100)}%`;
    const parts = [l, l.includes(n) ? null : n, r.eta ? `還要 ${r.eta}` : null].filter(x => x);
    return parts.join(" ");
  },
};

// MARK: - 燈光、風格、保全等級（Office.swift）

export const OfficeStyle = {
  allCases: ["voxel", "diorama", "blueprint"],
  title: { voxel: "體素（原本）", diorama: "微縮模型（等角＋移軸）", blueprint: "藍圖（深藍底、發光線條）" },
};

/** SkyLook.phaseTitle（Solar.swift） */
export function phaseTitle(s) {
  const e = s.elevation;
  if (e <= -12) return "夜晚";
  if (e < -4) return s.rising ? "清晨" : "黃昏";
  if (s.rising) return e < 6 ? "日出" : "白天";
  if (e < 1) return "日落";
  if (e < 15) return "傍晚";
  return "白天";
}

export const OfficeLighting = {
  allCases: ["day", "night", "auto"],
  title: { day: "白天", night: "夜晚", auto: "自動" },
  /** 自動：跟真實太陽；地點＝天氣設定的主地點（沒給＝台北） */
  sun(date, site = Solar.taipei) { return Solar.position(date, site.lat, site.lon); },
  /** 這個時間點的天色與燈光 */
  look(l, date, site) {
    switch (l) {
      case "day": return SkyLook.day;
      case "night": return SkyLook.night;
      default: return SkyLook.at(OfficeLighting.sun(date, site));
    }
  },
  /** 標籤文字：自動＝「自動・清晨／日出／白天／傍晚／日落／黃昏／夜晚」 */
  label(l, date, site) { return l === "auto" ? `自動・${phaseTitle(OfficeLighting.sun(date, site))}` : OfficeLighting.title[l]; },
  changingBand: [-13.0, 23.0],
  /** 自動模式下一次要重算燈光的時間（一次性的 setTimeout，不輪詢）：晨昏每 60 秒、白天每 5 分鐘、夜晚睡到天快亮。白天／夜晚固定回 null */
  nextChange(l, date, site) {
    if (l !== "auto") return null;
    const [lo, hi] = OfficeLighting.changingBand;
    const e = OfficeLighting.sun(date, site).elevation;
    if (e >= lo && e <= hi) return new Date(date.getTime() + 60_000);
    if (e > hi) return new Date(date.getTime() + 300_000);
    let t = date.getTime();
    for (let i = 0; i < 720; i++) {
      t += 120_000;
      if (OfficeLighting.sun(new Date(t), site).elevation >= lo) return new Date(t);
    }
    return new Date(date.getTime() + 3_600_000);
  },
};

export const GuardLevel = {
  title: { normal: "正常", notice: "注意", alert: "警示" },
  /** OfficeBuilder.guardColor */
  color: { normal: "#22c55e", notice: "#facc15", alert: "#ef4444" },
};

export const GuardDeviceKind = { title: { new: "新裝置", unnamed: "沒命名", unconfirmed: "待確認", named: "已命名" } };

export const CaptainTaskState = {
  title: { sent: "已派出", working: "做事中", review: "要你看", done: "完成", blocked: "卡住", cancelled: "已取消" },
};

// MARK: - 天氣地點（Weather.swift）

export const WeatherSite = {
  limit: 5,
  taipei: { title: "台北", lat: 25.03, lon: 121.56 },
  same: (a, b) => a.lat === b.lat && a.lon === b.lon,
  fullName: s => [s.title, s.detail].filter(x => x).join(", "),
  adding: (x, xs) => xs.some(s => WeatherSite.same(s, x)) || xs.length >= WeatherSite.limit ? xs : [...xs, x],
  removing: (x, xs) => xs.length <= 1 ? xs : xs.filter(s => !WeatherSite.same(s, x)),
  makingMain: (x, xs) => [...xs.filter(s => WeatherSite.same(s, x)), ...xs.filter(s => !WeatherSite.same(s, x))],
};

/** OfficeWeather.symbol（SF Symbol 名稱 → 介面圖示鍵，見 ui/dom.js 的 Icon） */
export const weatherSymbol = k => ({ clear: "sun.max", cloudy: "cloud.sun", overcast: "cloud", lightRain: "cloud.drizzle",
  heavyRain: "cloud.heavyrain", thunder: "cloud.bolt.rain", typhoon: "wind" })[k] ?? "sun.max";

// MARK: - 城市警示（City.swift CityState.alerts；只要 id）

export function cityAlerts(c) {
  if (!c) return [];
  const a = [];
  for (const d of c.disks) if (d.alert) a.push({ id: d.id });
  for (const s of c.servers) if (s.alert) a.push({ id: s.id });
  if (c.firewall.enabled === false) a.push({ id: "city:wall" });
  for (const p of c.firewall.openRed) a.push({ id: `city:gate:${p.port}` });
  if (c.power.alert) a.push({ id: "city:cooler" });
  if (c.grid.alert) a.push({ id: "city:power" });
  for (const cl of c.clouds) if (cl.alert) a.push({ id: cl.id });
  return a;
}

// MARK: - 文字小工具

const p2 = n => String(n).padStart(2, "0");
/** Date.formatted(date: .omitted, time: .shortened)：台灣的 24 小時「HH:mm」 */
export const timeShort = t => { const d = new Date(sec(t) * 1000); return `${p2(d.getHours())}:${p2(d.getMinutes())}`; };
/** Date.formatted(date: .abbreviated, time: .shortened)：「2026年11月2日 00:23」 */
export const dateTimeShort = t => { const d = new Date(sec(t) * 1000); return `${d.getFullYear()}年${d.getMonth() + 1}月${d.getDate()}日 ${timeShort(t)}`; };
/** .relative(presentation: .named)：「3 分鐘前」「昨天」 */
export function relativeNamed(t, now = nowSec()) {
  const s = now - sec(t);
  if (s < 60) return "剛剛";
  if (s < 3600) return `${Math.floor(s / 60)} 分鐘前`;
  if (s < 86400) return `${Math.floor(s / 3600)} 小時前`;
  const d = Math.floor(s / 86400);
  return d === 1 ? "昨天" : d === 2 ? "前天" : `${d} 天前`;
}
/** InboxRow.ago */
export function inboxAgo(t, now = nowSec()) {
  const m = Math.trunc((now - sec(t)) / 60);
  if (m < 1) return "剛剛";
  if (m < 60) return `${m} 分鐘前`;
  return m < 24 * 60 ? `${Math.trunc(m / 60)} 小時前` : `${Math.trunc(m / 1440)} 天前`;
}
/** CityDetail.ago */
export function cityAgo(t, now = nowSec()) {
  const s = now - sec(t);
  if (s < 60) return "剛剛";
  if (s < 3600) return `${Math.trunc(s / 60)} 分鐘前`;
  if (s < 86400) return `${Math.trunc(s / 3600)} 小時前（${timeShort(t)}）`;
  const d = new Date(sec(t) * 1000);
  return `${d.getMonth() + 1}月${d.getDate()}日 ${timeShort(t)}`;
}
