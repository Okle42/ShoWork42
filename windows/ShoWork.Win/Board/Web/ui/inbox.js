// InboxPanel.swift＋ChatInput.swift 照搬（11-02 P8）：收件匣（等你回答）、權限對話框、選擇題、計畫確認、隊長對話／右側對話窗格、
// 名字下方的進度條（RunBar）、對話輸入框（ChatInput）。
// Mac 在 3D 視窗（OfficeView）裡：寬視窗（≥1300）固定在右邊；窄的點「等你」才在左邊浮出來（取代樓層清單）。
// 送出一律交給 office.js 的回呼（→ chrome.webview.postMessage({type:"action", …})，格式見 PROTOCOL.md）。
// 每列自己的狀態（打到一半的字、已送出、選擇題勾了什麼）放在 store（Map），重畫時接回去（SwiftUI 的 @State）。

import { h, Icon } from "./dom.js";
import { Inbox, Permit, RunProgress, CaptainTaskState, inboxAgo, timeShort, nowSec } from "./core.js";
import { KuboArt } from "../scene/builder.js";
import { fileDrop } from "./panels.js";

const tint = m => KuboArt.tint(m).css;
const firstName = t => String(t ?? "").split("-")[0] || String(t ?? "");

/** 每個元件自己的 @State：key → 物件 */
export class Store {
  constructor() { this.m = new Map(); }
  get(key, init) { if (!this.m.has(key)) this.m.set(key, init()); return this.m.get(key); }
}

/** **粗體**、`code` 這類行內語法；換行照原樣 */
export function markdown(s) {
  const esc = String(s ?? "").replace(/[&<>"]/g, c => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" })[c]);
  return esc.replace(/`([^`\n]+)`/g, "<code>$1</code>").replace(/\*\*([^*\n]+)\*\*/g, "<b>$1</b>").replace(/(^|[^*])\*([^*\n]+)\*/g, "$1<i>$2</i>");
}

// MARK: - ChatInput（ChatInput.swift）

/** 對話輸入框：Return 送出；Shift／Alt＋Return 換行；選字中（注音還沒確定）的 Return 只是確定選字。
 *  高度跟著內容長，到上限再捲動；resizable 時上緣有拖拉把手，拉的高度記在 localStorage（Mac：UserDefaults ChatInputHeight）。
 *  拖檔進來：路徑插在游標處（WebView2 的 File 沒有完整路徑 ⇒ 交給 C# 換成路徑，見 PROTOCOL.md 的 dropFiles）。 */
export function ChatInput({ st, key, placeholder = "", minLines = 1, maxLines = 4, resizable = false, maxHeight = 400, onSubmit, onChange, paths }) {
  const ta = h("textarea.chat", { rows: 1, placeholder, "data-k": key });
  ta.value = st.text ?? "";
  const line = 16, inset = 10;
  const lines = n => line * n + inset;
  const userH = () => +(localStorage.getItem("ChatInputHeight") ?? 0);
  const floor = () => resizable ? Math.max(lines(Math.max(minLines, 2)), userH()) : lines(minLines);
  const ceiling = () => resizable ? Math.max(floor(), maxHeight) : lines(maxLines);
  const fit = () => {
    ta.style.height = "0px";
    const want = ta.scrollHeight;
    ta.style.height = `${Math.min(Math.max(want, floor()), ceiling())}px`;
  };
  ta.addEventListener("input", () => { st.text = ta.value; onChange?.(ta.value); fit(); });
  ta.addEventListener("keydown", e => {
    if (e.key !== "Enter" || e.isComposing || e.keyCode === 229) return;
    if (e.shiftKey || e.altKey) return;           // 換行
    e.preventDefault();
    onSubmit();
  });
  // 拖檔：插在游標處（不在焦點：接在最後），前面不是空白就補一個，後面補一個空白，游標放在空白後
  ta.addEventListener("dragover", e => { if (e.dataTransfer?.types?.includes("Files")) { e.preventDefault(); ta.classList.add("drop"); } });
  ta.addEventListener("dragleave", () => ta.classList.remove("drop"));
  ta.addEventListener("drop", async e => {
    ta.classList.remove("drop");
    const files = [...(e.dataTransfer?.files ?? [])];
    if (!files.length) return;
    e.preventDefault(); e.stopPropagation();
    const at = document.activeElement === ta ? ta.selectionStart : ta.value.length;
    const ps = await paths(files);
    const joined = Inbox.withPaths("", ps);
    if (!joined) return;
    const before = at > 0 ? ta.value[at - 1] : "";
    const ins = (!before || before === " " || before === "\n" ? "" : " ") + joined;
    ta.value = ta.value.slice(0, at) + ins + ta.value.slice(at);
    st.text = ta.value; onChange?.(ta.value);
    ta.focus(); ta.selectionStart = ta.selectionEnd = at + ins.length;
    fit();
  });
  requestAnimationFrame(fit);
  if (!resizable) return h("div.chat-wrap", ta);
  // 上緣拖拉把手：往上拉變高。最小 2 行、最大 maxHeight；拉完記住
  const handle = h("div.chat-handle", { title: "往上拉可以把輸入框拉高", "aria-label": "調整輸入框高度" }, h("i"));
  handle.addEventListener("pointerdown", e => {
    handle.setPointerCapture(e.pointerId);
    const y0 = e.clientY, start = ta.getBoundingClientRect().height;
    const mv = ev => { localStorage.setItem("ChatInputHeight", String(Math.min(Math.max(start - (ev.clientY - y0), lines(2)), maxHeight))); fit(); };
    const end = () => { handle.removeEventListener("pointermove", mv); handle.removeEventListener("pointerup", end); };
    handle.addEventListener("pointermove", mv); handle.addEventListener("pointerup", end);
  });
  return h("div.chat-wrap", handle, ta);
}

// MARK: - RunBar（名字下方的細進度條）

/** 背景長工作在跑時卡片每輪才更新、看起來像停了：優先用即時的 run/progress，沒有就退回這一輪自報的 --progress，兩個都沒有不畫 */
export function RunBar(el, card, name, runs, thickness = 3) {
  const run = RunProgress.pick(runs, name);
  const f = run ? run.fraction : card.report?.progress != null ? card.report.progress / 100 : null;
  const tip = run ? `${RunProgress.caption(run, name)}（即時）` : card.report?.progress != null ? `這一輪自報完成度 ${card.report.progress}%` : "";
  if (f === null || f === undefined) return el;
  return h("div.runbar-wrap", { title: tip, "aria-valuetext": tip, style: { paddingBottom: `${thickness + 1}px` } }, el,
    h("div.runbar", { style: { height: `${thickness}px` } }, h("i", { class: run ? "live" : "", style: { width: `max(3px, ${f * 100}%)` } })));
}

// MARK: - InboxPanel

export function InboxPanel(p) {
  const { items, captain, store, onClose, captainBusy, thread, tasks, person, personThread, runs } = p;
  const open = items.filter(i => i.answered == null).length;
  const body = [
    h("div.inbox-head", Icon("tray.full", 15, "sec"), h("span.headline", "等你回答"),
      open > 0 ? h("span.count", { style: { background: KuboArt.tint("waiting").withAlpha(0.3).css } }, String(open)) : null,
      h("span.spacer"), onClose ? h("button.plain.close", { title: "收起", on: { click: onClose } }, Icon("xmark.circle.fill", 16)) : null),
  ];
  if (!items.length) body.push(h("div.callout.sec.labelrow", { style: { padding: "4px 0" } }, Icon("checkmark.circle", 14), "現在沒有 AI 在等你"));
  else body.push(h("div.scroll.inbox-list", { style: { maxHeight: "420px" } }, ...items.map(it => InboxRow({ ...p, item: it, st: store.get(`row:${it.id}`, () => ({ text: "", sentText: null, since: it.since, permitId: it.card.permit?.id ?? null })) }))));
  if (person) {
    body.push(CaptainPanel({ ...p, captain: person, busy: false, thread: personThread, tasks: [], onSend: p.onPersonSend, person: true,
                             st: store.get(`talk:${person.sessionId}`, () => ({ text: "", pending: null, showReports: true })) }));
  } else {
    body.push(CaptainPanel({ ...p, captain, busy: captainBusy, thread, tasks, onSend: p.onCaptain, person: false,
                             st: store.get("talk:captain", () => ({ text: "", pending: null, showReports: true })) }));
  }
  return h("div.inbox.cardbg", ...body);
}

function InboxRow({ item, st, onAnswer, onPermit, onJump, onFocus, runs, paths }) {
  // 它又問了新的：重新可答；下一個權限對話框：重新可按
  if (st.since !== item.since && item.answered == null) { st.sentText = null; st.since = item.since; }
  if (st.permitId !== (item.card.permit?.id ?? null)) { st.sentText = null; st.permitId = item.card.permit?.id ?? null; }
  const done = item.answered != null || st.sentText != null;
  const send = s => {
    const t = Inbox.message(s);
    if (!t || st.sentText != null) return;
    st.sentText = `已送出「${t}」，等它回應`; st.text = "";
    onAnswer(item, t);
  };
  const decide = a => {
    if (st.sentText != null) return;
    const pm = item.card.permit;
    if (pm && (Permit.isAsk(pm) || Permit.isPlan(pm))) { st.sentText = `已回答：${Permit.answerText(pm, a)}`; st.text = ""; onPermit(item, a); return; }
    st.sentText = a.decision === "allow" ? "已允許" : a.decision === "always" ? "已允許，以後同類不再問" : a.message ? `已拒絕：${a.message}` : "已拒絕";
    st.text = "";
    onPermit(item, a);
  };
  const body = [
    h("div.row",
      h("i.dot", { style: { background: tint(done ? "idle" : "waiting") } }),
      h("button.plain.subhead.semibold.trunc", { title: "在大樓裡找到它", on: { click: () => onFocus(item.id) } }, item.card.title),
      h("span.spacer"),
      item.since != null ? h("span.caption2.sec.num", inboxAgo(item.since)) : null),
    RunBar(h("div.caption.sec.trunc", item.card.project), item.card, firstName(item.card.title), runs, 2),
    h("div.callout.select.clamp6", item.question),
  ];
  if (item.context && (item.kind !== "reply" || item.generic)) body.push(h("div.caption.sec.clamp3.select", item.context));
  if (done) body.push(h("div.caption.sec.labelrow.clamp2", Icon("paperplane", 12), st.sentText ?? "已回答，等它回應"));
  else if (item.kind === "permit" && item.card.permit) body.push(PermitBox({ permit: item.card.permit, st, decide, paths }));
  else if (item.kind === "ask" && item.card.permit?.questions) body.push(AskBox({ questions: item.card.permit.questions, st, decide }));
  else if (item.kind === "plan" && item.card.permit) body.push(PlanBox({ plan: Permit.plan(item.card.permit) ?? item.card.permit.summary, st, decide }));
  else if (item.kind === "reply") {
    body.push(h("div.opts", ...item.options.map(o => h("button.opt", { on: { click: () => send(o) } }, o))));
    const btn = h("button.btn.small", { disabled: !(st.text ?? "").trim(), on: { click: () => send(st.text) } }, "送出");
    body.push(h("div.row.small", ChatInput({ st, key: `reply:${item.id}`, placeholder: "或直接打字回答⋯", onSubmit: () => send(st.text), onChange: v => { btn.disabled = !v.trim(); }, paths }), btn));
  } else {
    body.push(h("div.row", h("span.caption.sec", item.card.blockedReason === "permission" ? "這個對話框沒接到戰情中心（session 開在安裝前），要在終端機裡按" : "選單要在終端機裡選"),
      h("span.spacer"), h("button.btn.small", { on: { click: () => onJump(item.id) } }, "跳到視窗")));
  }
  const row = h("div.inbox-row", { class: done ? "done" : "" }, ...body);
  return row;
}

/** 收件匣的大按鈕：自己畫底色（電視上的戰情中心通常不是前景視窗，系統的 prominent 按鈕會變灰） */
const inboxChoice = (title, color, strong, action, help) =>
  h("button.choice", { class: strong ? "strong" : "", title: help, style: { "--c": color }, on: { click: action } }, title);

/** 權限對話框：要做什麼＋三個按鈕；打字＝拒絕並告訴它改怎麼做 */
function PermitBox({ permit, st, decide }) {
  const deny = () => { const t = Inbox.message(st.text); if (!t) return; decide({ decision: "deny", message: t }); };
  const rule = Permit.alwaysLabel(permit);
  const ta = h("textarea.field", { rows: 1, placeholder: "或拒絕並告訴它改怎麼做⋯", "data-k": `permit:${permit.id}` });
  ta.value = st.text ?? "";
  const btn = h("button.btn.small", { disabled: !(st.text ?? "").trim(), on: { click: deny } }, "送出");
  ta.addEventListener("input", () => { st.text = ta.value; btn.disabled = !ta.value.trim(); });
  ta.addEventListener("keydown", e => { if (e.key === "Enter" && !e.shiftKey && !e.isComposing) { e.preventDefault(); deny(); } });
  fileDrop(ta, () => ta.value, v => { ta.value = v; st.text = v; btn.disabled = !v.trim(); });
  return h("div.box",
    h("div.mono-box.select.clamp5", permit.summary),
    h("div.row",
      inboxChoice("允許", tint("finished"), true, () => decide({ decision: "allow" })),
      rule ? inboxChoice("一律允許", tint("finished"), false, () => decide({ decision: "always" }), `以後不再問：${rule}`) : null,
      inboxChoice("拒絕", tint("waiting"), false, () => decide({ decision: "deny" }))),
    h("div.row.small", ta, btn),
    h("div.caption2.sec", "終端機那邊也能按，先按的算"));
}

/** 選擇題（AskUserQuestion）：單選按一下、多選打勾、不在選項裡的打在「其他」。只有一題又是單選：按選項就送出 */
function AskBox({ questions, st, decide }) {
  st.picks ??= {}; st.other ??= {};
  const quick = questions.length === 1 && !questions[0].multiSelect;
  const typed = q => Inbox.message(st.other[q.question] ?? "");
  const answer = q => {
    const chosen = q.options.map(o => o.label).filter(l => (st.picks[q.question] ?? []).includes(l));
    const t = typed(q);
    if (q.multiSelect) return [...chosen, ...(t ? [t] : [])];
    return t ? [t] : chosen;
  };
  const complete = () => questions.every(q => answer(q).length > 0);
  const send = () => {
    if (!complete()) return;
    const answers = {};
    for (const q of questions) if (!(q.question in answers)) answers[q.question] = answer(q);
    decide({ decision: "allow", answers });
  };
  const wrap = h("div.box.ask");
  const refresh = () => { const n = AskBox({ questions, st, decide }); wrap.replaceWith(n); };
  const label = o => h("span.optlabel", h("span.callout", o.label), o.description ? h("span.caption.sec", o.description) : null);
  for (const q of questions) {
    const qel = h("div.askq",
      q.header ? h("span.chiphead", q.header) : null,
      h("div.callout.semibold.select", q.question),
      q.multiSelect ? h("div.caption2.sec", "可以選多個") : null);
    for (const o of q.options) {
      if (q.multiSelect) {
        const on = (st.picks[q.question] ?? []).includes(o.label);
        qel.append(h("label.checkrow", h("input", { type: "checkbox", checked: on, on: { change: e => {
          const s = new Set(st.picks[q.question] ?? []); if (e.target.checked) s.add(o.label); else s.delete(o.label);
          st.picks[q.question] = [...s]; refresh();
        } } }), label(o)));
      } else {
        const on = (st.picks[q.question] ?? []).includes(o.label);
        qel.append(h("button.askopt", { class: on ? "on" : "", "aria-label": o.label, on: { click: () => {
          st.picks[q.question] = [o.label]; delete st.other[q.question];
          if (quick) send(); else refresh();
        } } }, Icon(on ? "checkmark.circle.fill" : "circle", 14, on ? "acc" : "sec"), label(o)));
      }
    }
    const ta = h("textarea.field", { rows: 1, placeholder: "其他⋯（自己打）", "data-k": `ask:${q.question}` });
    ta.value = st.other[q.question] ?? "";
    const qb = quick ? h("button.btn.small", { disabled: !typed(q), on: { click: send } }, "送出") : null;
    ta.addEventListener("input", () => { st.other[q.question] = ta.value; if (qb) qb.disabled = !typed(q); if (!quick) sendBtn && (sendBtn.disabled = !complete()); });
    ta.addEventListener("keydown", e => { if (e.key === "Enter" && !e.shiftKey && !e.isComposing) { e.preventDefault(); if (quick) send(); } });
    qel.append(h("div.row.small", ta, qb));
    wrap.append(qel);
  }
  let sendBtn = null;
  if (!quick) { sendBtn = inboxChoice("送出", tint("finished"), true, send); sendBtn.disabled = !complete(); wrap.append(sendBtn); }
  wrap.append(h("div.caption2.sec", "終端機那邊也能答，先答的算"));
  return wrap;
}

/** 計畫確認（ExitPlanMode）：看計畫、核准，或退回並說要改什麼 */
function PlanBox({ plan, st, decide }) {
  const back = () => { const t = Inbox.message(st.text); if (!t) return; decide({ decision: "deny", message: t }); };
  const ta = h("textarea.field", { rows: 1, placeholder: "退回並告訴它要改什麼⋯", "data-k": "plan" });
  ta.value = st.text ?? "";
  const btn = h("button.btn.small", { disabled: !Inbox.message(st.text), on: { click: back } }, "送出");
  ta.addEventListener("input", () => { st.text = ta.value; btn.disabled = !Inbox.message(ta.value); });
  ta.addEventListener("keydown", e => { if (e.key === "Enter" && !e.shiftKey && !e.isComposing) { e.preventDefault(); back(); } });
  return h("div.box",
    h("div.scroll.plan.caption.select.pre", { style: { maxHeight: "220px" }, html: markdown(plan) }),
    h("div.row",
      inboxChoice("核准，開始做", tint("finished"), true, () => decide({ decision: "allow" })),
      inboxChoice("退回", tint("waiting"), false, () => { const m = Inbox.message(st.text); decide({ decision: "deny", message: m || undefined }); })),
    h("div.row.small", ta, btn),
    h("div.caption2.sec", "終端機那邊也能按，先按的算"));
}

// MARK: - 隊長對話／右側對話窗格

function CaptainPanel({ captain, busy, thread, tasks, onSend, onFocus, person, onBack, onJump, runs, st, captainModelTitle = "Opus 5.5", paths }) {
  const name = captain ? firstName(captain.title) || "隊長" : "隊長";
  const thinking = captain?.column === "active";
  const shown = st.showReports ? thread : thread.filter(l => l.role !== "report" && l.role !== "tool");
  // 隊長那邊出現了剛送的話：拿掉「送出中」
  if (st.pending && (thread.some(l => l.role === "kang" && l.text === st.pending.text) || nowSec() - st.pending.at > 180)) st.pending = null;
  const send = () => {
    const t = Inbox.message(st.text);
    if (!t || busy) return;
    st.text = ""; st.pending = { text: t, at: nowSec() };
    onSend(t);
  };
  const head = h("div.row.cp-head",
    person ? h("button.plain", { title: "回到隊長對話", "aria-label": "回到隊長對話", on: { click: onBack } }, Icon("chevron.backward", 14)) : null,
    Icon(person ? "person.crop.circle" : "person.crop.circle.badge.checkmark", 15, "sec"),
    h("span.subhead.semibold.trunc", person ? name : !captain ? "隊長" : `隊長 ${name}`),
    captain && thinking ? [h("span.spinner.mini"), h("span.caption.sec", "思考中⋯")] : null,
    h("span.spacer"),
    person ? [
      h("button.plain", { title: "跳到它的終端機視窗", "aria-label": "跳到終端機", on: { click: () => onJump(captain.id) } }, Icon("terminal", 15)),
      h("button.plain.sec", { title: st.showReports ? "只看你和它講的話（收起工具與回報）" : "顯示工具與回報", on: { click: () => { st.showReports = !st.showReports; rerender(); } } },
        Icon(st.showReports ? "list.bullet.rectangle" : "list.bullet.rectangle.fill", 15)),
    ] : !captain ? h("span.caption.sec.trunc", `不在：送出時開 ${captainModelTitle} 隊長`)
      : h("button.plain.sec", { title: st.showReports ? "隱藏其他 AI 的回報，只看你和隊長的對話" : "顯示其他 AI 的回報", on: { click: () => { st.showReports = !st.showReports; rerender(); } } },
        Icon(st.showReports ? "text.bubble" : "text.bubble.fill", 15)));
  const parts = [h("div.divider"), head];
  if (person && captain) {
    const r = RunProgress.pick(runs, name);
    parts.push(RunBar(h("div.row.caption.sec", h("span.trunc", `${captain.project}・${captain.reason}`), h("span.spacer"), r ? h("span.num.nowrap", RunProgress.caption(r, name)) : null), captain, name, runs));
  } else if (captain) parts.push(RunBar(h("div"), captain, name, runs));
  const sc = h("div.scroll.cp-thread");
  if (!shown.length && !st.pending) sc.append(h("div.caption.sec", { style: { padding: "8px 0" } },
    person ? "讀取對話中⋯（還沒有對話的話，在下面打一句話給它）" : !captain ? "還沒有隊長。在下面打一句話，戰情中心會開一個隊長來接。" : "還沒有對話。在下面打一句話交給隊長。"));
  for (const l of shown) sc.append(CaptainBubble(l, person ? name : "隊長"));
  if (st.pending) sc.append(CaptainBubble({ id: "pending", at: st.pending.at, role: "kang", text: st.pending.text, via: "送出中⋯" }, name));
  requestAnimationFrame(() => { sc.scrollTop = sc.scrollHeight; });
  parts.push(sc);
  if (tasks.length) {
    const col = s => s === "blocked" ? tint("waiting") : s === "review" ? "#ff9f0a" : s === "done" ? tint("finished") : tint("working");
    parts.push(h("div.cp-tasks",
      h("div.caption.semibold.sec", `派工中（${tasks.length}）`),
      ...tasks.slice(0, 4).map(t => h("button.plain.task", { title: `${t.id}：在大樓裡找到它`, on: { click: () => { if (t.toSession) onFocus(t.toSession); } } },
        h("i.dot.s6", { style: { background: col(t.state) } }),
        h("span.caption.semibold.nowrap", `→ ${firstName(t.to)}`),
        h("span.caption.sec.trunc", String(t.text ?? "").replaceAll("\n", " ")),
        h("span.spacer"),
        h("span.caption2.nowrap", { style: { color: col(t.state) } }, CaptainTaskState.title[t.state] ?? t.state ?? ""))),
      tasks.length > 4 ? h("div.caption2.ter", `還有 ${tasks.length - 4} 張（showork tasks）`) : null));
  }
  const btn = h("button.btn.small", { disabled: busy || !(st.text ?? "").trim(), on: { click: send } }, "送出");
  let panel = null;
  const paneH = () => panel?.getBoundingClientRect().height || 400;
  parts.push(h("div.row.bottom.small",
    ChatInput({ st, key: person ? `talk:${captain?.sessionId}` : "talk:captain",
                placeholder: person ? `跟 ${name} 說⋯` : !captain ? "要做什麼？會開一個隊長來決定給哪個 AI" : "跟隊長說⋯（交辦、追問、拍板都可以）",
                resizable: true, maxHeight: Math.max(80, paneH() / 2), onSubmit: send, onChange: v => { btn.disabled = busy || !v.trim(); }, paths }),
    busy ? h("span.spinner") : null, btn));
  panel = h("div.captain-panel", ...parts);
  // 檔案拖到對話區任何地方：路徑填進下面的輸入框
  panel.addEventListener("dragover", e => { if (e.dataTransfer?.types?.includes("Files")) e.preventDefault(); });
  panel.addEventListener("drop", async e => {
    const files = [...(e.dataTransfer?.files ?? [])];
    if (!files.length || e.defaultPrevented) return;
    e.preventDefault();
    st.text = Inbox.withPaths(st.text ?? "", await paths(files));
    rerender();
  });
  function rerender() { panel.replaceWith(CaptainPanel({ captain, busy, thread, tasks, onSend, onFocus, person, onBack, onJump, runs, st, captainModelTitle, paths })); }
  return panel;
}

function CaptainBubble(line, speaker = "隊長") {
  const time = line.at != null ? h("span.num", timeShort(line.at)) : null;
  switch (line.role) {
    case "tool":
      return h("div.bub-line.sec", { title: line.text }, Icon("wrench.and.screwdriver", 11), h("span.caption.trunc", line.text));
    case "report":
      return h("div.bub-line.sec", { title: line.text }, Icon("doc.text", 11), h("span.caption.trunc", line.text), h("span.spacer"), h("span.caption2", time));
    case "kang":
      return h("div.bub.kang",
        h("div.bub-body.callout.select.pre", line.text),
        h("div.caption2.sec.row", h("span", "你" + (line.via ? "・" + line.via : "")), time));
    default:
      return h("div.bub.captain",
        h("div.bub-body.callout.select.pre", { html: markdown(line.text) }),
        h("div.caption2.sec.row", h("span", speaker), time));
  }
}
