// 工作視窗（11-08 H3，docs/OWN-SESSIONS.md「H3 規格」）：戰情中心自己持有的 session 的對話流、輸入框、權限卡。
// Mac（WorkWindow.swift，WKWebView）和 Windows（WebView2）共用；訊息格式見 PROTOCOL.md「工作視窗」。
// 原生端 → 網頁：Windows 用 PostWebMessageAsJson；Mac 呼叫 window.swRecv(obj)。
// 網頁 → 原生端：Windows chrome.webview.postMessage；Mac webkit.messageHandlers.sw.postMessage。
// 事件就是 claude -p --output-format stream-json 的每一行（board/sessions/<sid>.jsonl），自己送出的話帶 _sent。
"use strict";

const $ = s => document.querySelector(s);
const demoMode = new URLSearchParams(location.search).has("demo");

// ---- 原生端橋接 ----
const listeners = [];
const host = window.chrome?.webview ?? (window.webkit?.messageHandlers?.sw ? {
  postMessage: m => window.webkit.messageHandlers.sw.postMessage(m),
  addEventListener: (_, f) => listeners.push(f),
} : null);
window.swRecv = obj => listeners.forEach(f => f({ data: obj }));
function post(type, fields = {}) {
  if (demoMode || !host) { toast(`示範模式：不送出（${type}）`); return; }
  host.postMessage({ type, ...fields });
}

// ---- 狀態 ----
const S = { sid: "", cwd: "", name: "", model: "", mode: "default", state: "starting", tools: new Map(), ctx: 0, lastAssistantId: "", images: [] };
const STATE_TEXT = { starting: "啟動中", idle: "等你交代", busy: "工作中", exited: "已關掉（送話會接回）", terminal: "在終端機" };

function setState(st) {
  S.state = st;
  const el = $("#state");
  el.textContent = STATE_TEXT[st] ?? st;
  el.className = "pill " + (st === "busy" || st === "starting" ? "busy" : st === "idle" ? "idle" : "exited");
  $("#interrupt").disabled = st !== "busy";
  $("#close").disabled = st === "exited" || st === "terminal";
  $("#toTerminal").disabled = st === "terminal";
}

function setCtx(n) {
  S.ctx = n;
  $("#ctx").textContent = n ? `ctx ${n >= 1000 ? Math.round(n / 1000) + "k" : n}` : "";
}

function toast(text) {
  const t = $("#toast"); t.textContent = text; t.hidden = false;
  clearTimeout(toast.h); toast.h = setTimeout(() => { t.hidden = true; }, 3200);
}

// ---- 小工具 ----
function el(tag, cls, text) {
  const e = document.createElement(tag);
  if (cls) e.className = cls;
  if (text != null) e.textContent = text;
  return e;
}
const flow = $("#flow");
function nearBottom() { return flow.scrollHeight - flow.scrollTop - flow.clientHeight < 80; }
function add(node) {
  const stick = nearBottom();
  flow.appendChild(node);
  if (stick) flow.scrollTop = flow.scrollHeight;
  return node;
}
function rel(p) {
  if (typeof p !== "string") return "";
  if (S.cwd && p.startsWith(S.cwd + "/")) return p.slice(S.cwd.length + 1);
  return p.replace(/^\/Users\/[^/]+/, "~");
}
function textOf(content) {
  if (typeof content === "string") return content;
  if (!Array.isArray(content)) return "";
  return content.map(b => b.type === "text" ? b.text : b.type === "image" ? "[圖片]" : "").join("\n");
}

// 很簡單的 markdown：```區塊```、`行內`、# 標題、**粗體**。其餘照原樣（pre-wrap）
function md(text) {
  const box = el("div", "text");
  const parts = String(text).split(/```[^\n]*\n?/);
  parts.forEach((part, i) => {
    if (i % 2) { box.appendChild(el("pre", null, part.replace(/\n$/, ""))); return; }
    for (const line of part.split(/(\n)/)) {
      if (line === "\n") { box.appendChild(document.createTextNode("\n")); continue; }
      const h = line.match(/^(#{1,3})\s+(.*)/);
      const target = h ? box.appendChild(el("h" + h[1].length)) : box;
      inline(target, h ? h[2] : line);
    }
  });
  return box;
}
function inline(parent, s) {
  const re = /(`[^`]+`|\*\*[^*]+\*\*)/g;
  let last = 0, m;
  while ((m = re.exec(s))) {
    if (m.index > last) parent.appendChild(document.createTextNode(s.slice(last, m.index)));
    parent.appendChild(m[0][0] === "`" ? el("code", null, m[0].slice(1, -1)) : el("b", null, m[0].slice(2, -2)));
    last = re.lastIndex;
  }
  if (last < s.length) parent.appendChild(document.createTextNode(s.slice(last)));
}

// 行 diff（LCS；太大就退成整段刪＋整段加），前後只留 3 行上下文
function diffLines(a, b) {
  const A = a.split("\n"), B = b.split("\n");
  if (A.length * B.length > 250000) return [...A.map(t => ["d", t]), ...B.map(t => ["a", t])];
  const n = A.length, m = B.length, L = Array.from({ length: n + 1 }, () => new Uint32Array(m + 1));
  for (let i = n - 1; i >= 0; i--) for (let j = m - 1; j >= 0; j--) L[i][j] = A[i] === B[j] ? L[i + 1][j + 1] + 1 : Math.max(L[i + 1][j], L[i][j + 1]);
  const out = []; let i = 0, j = 0;
  while (i < n && j < m) {
    if (A[i] === B[j]) { out.push(["c", A[i]]); i++; j++; }
    else if (L[i + 1][j] >= L[i][j + 1]) out.push(["d", A[i++]]);
    else out.push(["a", B[j++]]);
  }
  while (i < n) out.push(["d", A[i++]]);
  while (j < m) out.push(["a", B[j++]]);
  return out;
}
function diffView(pairs) {
  const box = el("div", "diff");
  const keep = pairs.map((p, k) => p[0] !== "c" || pairs.slice(Math.max(0, k - 3), k + 4).some(q => q[0] !== "c"));
  let skipped = false;
  pairs.forEach((p, k) => {
    if (!keep[k]) { if (!skipped) box.appendChild(el("div", "gap", "⋯")); skipped = true; return; }
    skipped = false;
    box.appendChild(el("div", p[0], p[1]));
  });
  return box;
}

// ---- 工具呼叫 ----
function toolSummary(name, inp = {}) {
  switch (name) {
    case "Bash": return inp.description || inp.command || "";
    case "Read": case "Write": case "Edit": case "MultiEdit": case "NotebookEdit": return rel(inp.file_path || inp.notebook_path);
    case "Grep": return `${inp.pattern ?? ""}${inp.path ? "　" + rel(inp.path) : ""}`;
    case "Glob": return inp.pattern || "";
    case "WebFetch": return inp.url || "";
    case "WebSearch": return inp.query || "";
    case "Task": case "Agent": return inp.description || "";
    case "TodoWrite": return `待辦 ${(inp.todos || []).length} 項`;
    default: {
      const v = Object.values(inp).find(x => typeof x === "string");
      return v ? v.slice(0, 160) : "";
    }
  }
}
function toolBody(name, inp = {}) {
  const body = el("div", "body");
  const lbl = t => body.appendChild(el("div", "lbl", t));
  if (name === "Edit") { lbl("修改"); body.appendChild(diffView(diffLines(inp.old_string ?? "", inp.new_string ?? ""))); }
  else if (name === "MultiEdit") { for (const e of inp.edits || []) { lbl("修改"); body.appendChild(diffView(diffLines(e.old_string ?? "", e.new_string ?? ""))); } }
  else if (name === "Write") { lbl("寫入"); body.appendChild(diffView(String(inp.content ?? "").split("\n").map(t => ["a", t]))); }
  else if (name === "Bash") { lbl("指令"); body.appendChild(el("pre", null, inp.command ?? "")); }
  else if (name === "TodoWrite") {
    lbl("待辦");
    body.appendChild(el("pre", null, (inp.todos || []).map(t => `${t.status === "completed" ? "☑" : t.status === "in_progress" ? "▶" : "☐"} ${t.content}`).join("\n")));
  } else { lbl("輸入"); body.appendChild(el("pre", null, JSON.stringify(inp, null, 2))); }
  return body;
}
function addTool(block) {
  const d = el("details", "tool msg");
  const s = d.appendChild(el("summary"));
  s.appendChild(el("span", "name", block.name));
  s.appendChild(el("span", "sum", toolSummary(block.name, block.input)));
  const st = s.appendChild(el("span", "st run"));
  d.appendChild(toolBody(block.name, block.input));
  S.tools.set(block.id, { d, st });
  add(d);
}
function toolResult(block) {
  const t = S.tools.get(block.tool_use_id);
  if (!t) return;
  const text = textOf(block.content);
  t.st.classList.remove("run");
  t.st.classList.add(block.is_error ? "bad" : "ok");
  t.st.textContent = block.is_error ? "失敗" : "完成";
  if (block.is_error) t.d.open = true;
  const body = t.d.querySelector(".body");
  body.appendChild(el("div", "lbl", block.is_error ? "錯誤" : "結果"));
  const pre = body.appendChild(el("pre", block.is_error ? "bad" : null, text.length > 20000 ? text.slice(0, 20000) + "\n⋯（太長，只顯示前 20000 字）" : text));
  if (!text) pre.textContent = "（沒有輸出）";
}

// ---- 一行事件 ----
function onLine(o) {
  if (!o || typeof o !== "object") return;
  switch (o.type) {
    case "system":
      if (o.subtype === "init") {
        if (o.model) setModelShown(o.model);
        if (o.permissionMode) setModeShown(o.permissionMode);
        if (o.cwd && !S.cwd) { S.cwd = o.cwd; if (!S.name) setProject(); }
      } else if (o.subtype === "compact_boundary") add(el("div", "note msg", "—— 對話已壓縮 ——"));
      return;
    case "user": {
      const c = o.message?.content;
      if (o._sent) { addUser(c); return; }
      if (Array.isArray(c)) {
        for (const b of c) {
          if (b.type === "tool_result") toolResult(b);
          else if (b.type === "text" && b.text.trim()) addLocal(b.text);
        }
      } else if (typeof c === "string" && c.trim()) addLocal(c);
      return;
    }
    case "assistant": {
      const m = o.message || {};
      const u = m.usage;
      if (u && !o.parent_tool_use_id) setCtx((u.input_tokens || 0) + (u.cache_creation_input_tokens || 0) + (u.cache_read_input_tokens || 0));
      if (o.parent_tool_use_id) return;                         // 子代理的過程不攤開，只看它最後回的結果
      for (const b of m.content || []) {
        if (b.type === "text" && b.text.trim()) { const box = el("div", "ai msg"); box.appendChild(md(b.text)); add(box); }
        else if (b.type === "thinking" && b.thinking?.trim()) {
          const d = el("details", "think msg"); d.appendChild(el("summary", null, "思考"));
          d.appendChild(el("div", null, b.thinking)); add(d);
        } else if (b.type === "tool_use") addTool(b);
      }
      return;
    }
    case "result": {
      const sec = o.duration_ms ? Math.round(o.duration_ms / 1000) : null;
      const bits = [];
      if (o.subtype === "error_during_execution") bits.push("已中斷");
      else if (o.is_error) bits.push("出錯：" + (o.result || o.subtype || ""));
      else bits.push("完成");
      if (sec != null) bits.push(sec >= 60 ? `${Math.floor(sec / 60)} 分 ${sec % 60} 秒` : `${sec} 秒`);
      if (o.num_turns) bits.push(`${o.num_turns} 步`);
      if (o.total_cost_usd) bits.push(`US$${o.total_cost_usd.toFixed(2)}`);
      add(el("div", "result msg" + (o.is_error && o.subtype !== "error_during_execution" ? " err" : ""), "—— " + bits.join("・") + " ——"));
      for (const t of S.tools.values()) if (t.st.classList.contains("run")) { t.st.classList.remove("run"); t.st.textContent = "沒有結果"; }
      return;
    }
  }
}
function addUser(c) {
  const box = el("div", "user msg");
  const text = typeof c === "string" ? c : (c || []).filter(b => b.type === "text").map(b => b.text).join("\n");
  if (text) box.appendChild(el("div", "bubble", text));
  const imgs = Array.isArray(c) ? c.filter(b => b.type === "image" && b.source?.data) : [];
  if (imgs.length) {
    const row = box.appendChild(el("div", "imgs"));
    for (const b of imgs) { const i = row.appendChild(el("img")); i.src = `data:${b.source.media_type};base64,${b.source.data}`; }
  }
  add(box);
  flow.scrollTop = flow.scrollHeight;                         // 自己送的一律捲到底
}
// 斜線指令的輸出（<local-command-stdout>）等非工具的 user 訊息
function addLocal(text) {
  const t = text.replace(/<\/?local-command-std(out|err)>/g, "").replace(/<\/?command-[a-z]+>/g, " ").trim();
  if (t) add(el("div", "note msg", t.length > 400 ? t.slice(0, 400) + "⋯" : t));
}

// ---- 上方列 ----
function setProject() {
  $("#project").textContent = S.name || S.cwd.split("/").filter(Boolean).pop() || "—";
  document.title = `${$("#project").textContent}・工作視窗`;
}
function setModelShown(m) {
  S.model = m;
  const sel = $("#model");
  const short = /opus/i.test(m) ? "opus" : /sonnet/i.test(m) ? "sonnet" : /haiku/i.test(m) ? "haiku" : "";
  if (short) { sel.value = short; return; }
  if (![...sel.options].some(o => o.value === m)) sel.appendChild(new Option(m, m));
  sel.value = m;
}
function setModeShown(mode) {
  S.mode = mode;
  const sel = $("#mode");
  if (![...sel.options].some(o => o.value === mode)) sel.appendChild(new Option(mode, mode));
  sel.value = mode;
}
$("#model").onchange = e => { if (e.target.value) post("setModel", { model: e.target.value }); };
$("#mode").onchange = e => post("setPermissionMode", { mode: e.target.value });
$("#interrupt").onclick = () => post("interrupt");
$("#toTerminal").onclick = () => post("openInTerminal");
$("#close").onclick = () => post("close");

// ---- 權限卡 ----
function showPermit(req) {
  const box = $("#permit");
  box.innerHTML = "";
  if (!req) { box.hidden = true; return; }
  box.hidden = false;
  const answer = (decision, extra = {}) => { post("permit", { permitId: req.id, decision, ...extra }); box.hidden = true; };
  if (req.questions?.length) {                                   // AskUserQuestion
    box.appendChild(el("h4", null, "AI 在問你"));
    const picked = {};
    for (const q of req.questions) {
      box.appendChild(el("div", "q", q.question));
      const opts = box.appendChild(el("div", "opts"));
      picked[q.question] = [];
      for (const o of q.options || []) {
        const b = opts.appendChild(el("button", "btn opt", o.label));
        if (o.description) b.appendChild(el("small", null, o.description));
        b.onclick = () => {
          const arr = picked[q.question];
          if (q.multiSelect) { const k = arr.indexOf(o.label); k >= 0 ? arr.splice(k, 1) : arr.push(o.label); }
          else { arr.length = 0; arr.push(o.label); opts.querySelectorAll(".opt").forEach(x => x.classList.remove("on")); }
          b.classList.toggle("on", arr.includes(o.label));
        };
      }
    }
    const row = box.appendChild(el("div", "row"));
    const ok = row.appendChild(el("button", "btn primary", "送出回答"));
    ok.onclick = () => {
      if (req.questions.some(q => !picked[q.question].length)) { toast("每一題都要選"); return; }
      answer("allow", { answers: picked });
    };
    return;
  }
  if (req.plan != null) {                                        // ExitPlanMode
    box.appendChild(el("h4", null, "AI 的計畫，要照這樣做嗎？"));
    const p = box.appendChild(el("div")); p.appendChild(md(req.plan));
    const row = box.appendChild(el("div", "row"));
    row.appendChild(el("button", "btn primary", "核准，開始做")).onclick = () => answer("allow");
    row.appendChild(el("button", "btn", "不要，繼續規劃")).onclick = () => answer("deny", { message: "使用者還不核准這份計畫，請繼續規劃或問他要改什麼。" });
    return;
  }
  box.appendChild(el("h4", null, `要允許 ${req.tool} 嗎？`));
  if (req.detail) box.appendChild(el("div", "why", req.detail));
  box.appendChild(el("pre", null, req.summary || ""));
  const row = box.appendChild(el("div", "row"));
  row.appendChild(el("button", "btn primary", "允許")).onclick = () => answer("allow");
  if (req.alwaysLabel) row.appendChild(el("button", "btn", `一律允許（${req.alwaysLabel}）`)).onclick = () => answer("always");
  row.appendChild(el("button", "btn warn", "拒絕")).onclick = () => answer("deny");
}

// ---- 輸入框 ----
const input = $("#input");
function grow() { input.style.height = "auto"; input.style.height = Math.min(input.scrollHeight, innerHeight * .4) + "px"; }
input.addEventListener("input", grow);
input.addEventListener("keydown", e => {
  if (e.key === "Enter" && (e.metaKey || e.ctrlKey) && !e.isComposing) { e.preventDefault(); send(); }
});
$("#send").onclick = send;

function send() {
  const text = input.value.trim();
  if (!text && !S.images.length) return;
  const m = text.match(/^\/model\s+(\S+)$/);
  if (m) { post("setModel", { model: m[1] }); setModelShown(m[1]); }
  else post("send", { text, images: S.images.map(({ mediaType, data }) => ({ mediaType, data })) });
  input.value = ""; S.images = []; renderAttach(); grow();
}

function renderAttach() {
  const box = $("#attach"); box.innerHTML = "";
  S.images.forEach((im, k) => {
    const c = box.appendChild(el("div", "chip"));
    const i = c.appendChild(el("img")); i.src = `data:${im.mediaType};base64,${im.data}`;
    const x = c.appendChild(el("button", null, "×")); x.title = "拿掉";
    x.onclick = () => { S.images.splice(k, 1); renderAttach(); };
  });
}
function addImage(file) {
  if (!/^image\/(png|jpeg|gif|webp)$/.test(file.type)) return false;
  const r = new FileReader();
  r.onload = () => { S.images.push({ mediaType: file.type, data: String(r.result).split(",")[1] }); renderAttach(); };
  r.readAsDataURL(file);
  return true;
}
function insertText(t) {
  const a = input.selectionStart ?? input.value.length, b = input.selectionEnd ?? a;
  input.value = input.value.slice(0, a) + t + input.value.slice(b);
  input.selectionStart = input.selectionEnd = a + t.length;
  input.focus(); grow();
}
input.addEventListener("paste", e => {
  const files = [...(e.clipboardData?.files || [])].filter(f => f.type.startsWith("image/"));
  if (files.length) { e.preventDefault(); files.forEach(addImage); }
});
const compose = $("#compose");
for (const t of ["dragenter", "dragover"]) document.addEventListener(t, e => { e.preventDefault(); compose.classList.add("drag"); });
document.addEventListener("dragleave", e => { if (!e.relatedTarget) compose.classList.remove("drag"); });
document.addEventListener("drop", e => {
  e.preventDefault(); compose.classList.remove("drag");
  const files = [...(e.dataTransfer?.files || [])];
  const rest = files.filter(f => !addImage(f));
  if (!rest.length) return;
  // 圖片以外的檔：插路徑。WebView2 要交給 C# 換成完整路徑；Mac 的拖放由 WorkWindow.swift 自己接（推 dropPaths）
  if (host?.postMessageWithAdditionalObjects && !demoMode) {
    const key = String(Date.now());
    pendingDrop = { key, names: rest.map(f => f.name), t: setTimeout(() => { insertText(rest.map(f => f.name).join(" ") + " "); pendingDrop = null; }, 3000) };
    host.postMessageWithAdditionalObjects({ type: "dropFiles", key }, rest);
  } else if (!host || demoMode) insertText(rest.map(f => f.name).join(" ") + " ");
  // Mac：WorkWebView（Swift）自己接圖片以外的檔，推 dropPaths 過來，這裡不插
});
let pendingDrop = null;

// ---- 原生端來的訊息 ----
function onMessage(m) {
  if (!m || typeof m !== "object") return;
  switch (m.type) {
    case "session":
      S.sid = m.sid || S.sid; S.cwd = m.cwd || S.cwd; S.name = m.name || S.name;
      setProject();
      if (m.model) setModelShown(m.model);
      if (m.permissionMode) setModeShown(m.permissionMode);
      if (m.state) setState(m.state);
      return;
    case "lines": {
      const stick = nearBottom() || m.replay;
      (m.lines || []).forEach(onLine);
      if (stick) flow.scrollTop = flow.scrollHeight;
      return;
    }
    case "state": setState(m.state); return;
    case "permit": showPermit(m.req || null); return;
    case "toast": toast(m.text || ""); return;
    case "dropPaths":
      if (pendingDrop && m.key === pendingDrop.key) { clearTimeout(pendingDrop.t); pendingDrop = null; }
      insertText((m.paths || []).map(p => /\s/.test(p) ? `"${p}"` : p).join(" ") + " ");
      return;
  }
}
host?.addEventListener("message", e => onMessage(e.data));

setState("starting");
if (demoMode) {
  $("#demoNote").hidden = false;
  const s = document.createElement("script");
  s.src = "work-demo.js";
  s.onload = () => window.WORK_DEMO.forEach(onMessage);
  document.body.appendChild(s);
} else {
  post("ready");
}
input.focus();
