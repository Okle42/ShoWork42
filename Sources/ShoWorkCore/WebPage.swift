import Foundation

// 網頁版戰情中心的頁面：一個檔、CSS／JS 全內嵌、不連任何 CDN。
// 要在 macOS 13 Safari 16、iPadOS／iOS Safari 跑：只用 fetch＋Promise，不用 ?. ?? 等較新語法；所有文字一律 textContent（不拼 HTML）。
// token 從網址 ?t= 讀（網址留著方便加書籤），之後每個請求放在 X-ShoWork-Token 標頭；每個動作前跳確認框（按下去＝本人決定）。
// 動作：按選項、傳話、開派工單、取消派工單、隊長收件匣一張張標已處理（伺服器端規則在 WebBoard.swift WebAction）。

public enum WebPage {
    public static let html = #"""
<!doctype html>
<html lang="zh-Hant">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="referrer" content="no-referrer">
<title>AI 工作戰情中心</title>
<style>
:root{--bg:#f4f2ec;--card:#fff;--ink:#1d1d1f;--mute:#6e6e73;--line:#e3e0d6;--work:#7a5cff;--review:#d9822b;--done:#2f9e5b;--stuck:#d64545;--todo:#8e8e93;--btn:#1d1d1f;--btnink:#fff}
@media (prefers-color-scheme: dark){:root{--bg:#141414;--card:#1f1f21;--ink:#f2f2f2;--mute:#9a9aa0;--line:#2e2e31;--btn:#f2f2f2;--btnink:#141414}}
*{box-sizing:border-box}
body{margin:0;background:var(--bg);color:var(--ink);font:15px/1.45 -apple-system,"PingFang TC","Heiti TC",sans-serif;-webkit-text-size-adjust:100%}
header{position:sticky;top:0;z-index:2;background:var(--bg);border-bottom:1px solid var(--line);padding:10px 16px;display:flex;align-items:center;gap:10px;flex-wrap:wrap}
h1{font-size:17px;margin:0;flex:1}
#stat{font-size:12px;color:var(--mute)}
#stat.err{color:var(--stuck)}
main{max-width:980px;margin:0 auto;padding:12px 16px 40px}
.counts{display:flex;gap:6px;flex-wrap:wrap;margin:4px 0 12px}
.pill{font-size:12px;padding:2px 9px;border-radius:99px;background:var(--card);border:1px solid var(--line)}
.grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(290px,1fr));gap:10px}
.c{background:var(--card);border:1px solid var(--line);border-left:5px solid var(--todo);border-radius:10px;padding:10px 12px;min-width:0}
.c.active{border-left-color:var(--work)}.c.review{border-left-color:var(--review)}.c.done{border-left-color:var(--done)}.c.stuck{border-left-color:var(--stuck)}
.c.ask{box-shadow:0 0 0 2px var(--stuck)}
.top{display:flex;align-items:baseline;gap:6px}
.nm{font-weight:600;font-size:16px;overflow-wrap:anywhere}
.pj{color:var(--mute);font-size:13px;overflow-wrap:anywhere;flex:1}
.col{font-size:12px;font-weight:600;white-space:nowrap}
.c.active .col{color:var(--work)}.c.review .col{color:var(--review)}.c.done .col{color:var(--done)}.c.stuck .col{color:var(--stuck)}.c.todo .col{color:var(--todo)}
.doing{margin-top:4px;font-size:14px;overflow-wrap:anywhere}
.sum{margin-top:4px;font-size:13px;color:var(--mute);overflow-wrap:anywhere;white-space:pre-wrap}
.meta{margin-top:6px;font-size:12px;color:var(--mute)}
.q{margin-top:8px;padding:8px;border-radius:8px;background:rgba(214,69,69,.08);font-size:14px;overflow-wrap:anywhere}
.opts{display:flex;flex-wrap:wrap;gap:6px;margin-top:8px}
button{font:inherit;font-size:14px;border:0;border-radius:8px;padding:9px 12px;background:var(--btn);color:var(--btnink);cursor:pointer;min-height:40px;max-width:100%;text-align:left;overflow-wrap:anywhere}
button:disabled{opacity:.45}
.note{font-size:12px;color:var(--mute);margin-top:6px}
h2{font-size:15px;margin:22px 0 8px}
.t{background:var(--card);border:1px solid var(--line);border-radius:10px;padding:8px 12px;margin-bottom:8px;overflow-wrap:anywhere}
.t .h{font-size:13px;color:var(--mute)}
.empty{color:var(--mute);font-size:14px}
details.say{margin-top:8px}
details.say summary{font-size:13px;color:var(--mute);cursor:pointer}
textarea{width:100%;min-height:64px;margin-top:6px;font:inherit;font-size:16px;padding:8px;border-radius:8px;border:1px solid var(--line);background:var(--bg);color:var(--ink);resize:vertical}
button.sec{background:transparent;color:var(--ink);border:1px solid var(--line)}
.row{display:flex;gap:6px;flex-wrap:wrap;margin-top:6px}
#toast{position:fixed;left:16px;right:16px;bottom:16px;max-width:520px;margin:0 auto;background:var(--btn);color:var(--btnink);padding:10px 14px;border-radius:10px;font-size:14px;display:none;z-index:3}
</style>
</head>
<body>
<header><h1>AI 工作戰情中心</h1><span id="stat">讀取中…</span></header>
<main>
<div class="counts" id="counts"></div>
<div class="grid" id="sessions"></div>
<h2>還沒結的派工單</h2>
<div id="tasks"></div>
<h2>隊長收件匣（還沒處理）</h2>
<div id="inbox"></div>
</main>
<div id="toast"></div>
<script>
(function(){
  var KEY = "showork.web.t";
  var token = "";
  var m = /[?&]t=([0-9a-f]{64})/.exec(location.search);
  if (m) { token = m[1]; try { sessionStorage.setItem(KEY, token); } catch (e) {} }
  else { try { token = sessionStorage.getItem(KEY) || ""; } catch (e) {} }
  var busy = {}, drafts = {}, opened = {};
  var timer = null;

  function el(tag, cls, text) { var e = document.createElement(tag); if (cls) e.className = cls; if (text != null) e.textContent = text; return e; }
  function idle(s) {
    if (s == null) return "";
    if (s < 60) return "剛剛";
    if (s < 3600) return Math.floor(s / 60) + " 分鐘沒動靜";
    if (s < 86400) return Math.floor(s / 3600) + " 小時沒動靜";
    return Math.floor(s / 86400) + " 天沒動靜";
  }
  function hhmm(iso) { var d = new Date(iso); if (isNaN(d)) return ""; function p(n){return (n<10?"0":"")+n;} return p(d.getHours()) + ":" + p(d.getMinutes()); }
  function toast(t) { var e = document.getElementById("toast"); e.textContent = t; e.style.display = "block"; clearTimeout(e._t); e._t = setTimeout(function(){ e.style.display = "none"; }, 4000); }
  function status(t, err) { var e = document.getElementById("stat"); e.textContent = t; e.className = err ? "err" : ""; }

  // 所有動作都走這裡：確認框（按下去＝你本人的決定）→ POST → 顯示結果 → 重讀
  function post(path, key, body, ask, btns, after) {
    if (busy[key]) return;
    if (!confirm(ask + "\n\n這等於你本人的決定。確定？")) return;
    busy[key] = true;
    for (var i = 0; i < btns.length; i++) btns[i].disabled = true;
    fetch(path, { method: "POST", headers: { "Content-Type": "application/json", "X-ShoWork-Token": token }, body: JSON.stringify(body), cache: "no-store" })
      .then(function(r){ return r.json().then(function(j){ return { ok: r.ok, j: j }; }); })
      .then(function(x){ toast(x.ok ? (x.j.message || "已送出") : ("沒成功：" + (x.j.error || "不明錯誤"))); if (x.ok && after) after(); })
      .catch(function(){ toast("沒成功：連不到 Mac mini"); })
      .then(function(){ busy[key] = false; for (var i = 0; i < btns.length; i++) btns[i].disabled = false; load(); });
  }
  function answer(s, text, btns) {
    post("/api/answer", s.id, { id: s.id, text: text }, "回答「" + s.name + "」：\n" + text, btns);
  }

  function card(s) {
    var c = el("div", "c " + s.column + (s.question ? " ask" : ""));
    var top = el("div", "top");
    top.appendChild(el("span", "nm", (s.captain ? "👑 " : "") + s.name));
    top.appendChild(el("span", "pj", s.project));
    top.appendChild(el("span", "col", s.columnTitle));
    c.appendChild(top);
    if (s.doing) c.appendChild(el("div", "doing", s.doing));
    if (s.summary) c.appendChild(el("div", "sum", s.summary));
    var meta = [s.reason, idle(s.idleSeconds)].filter(function(x){ return !!x; }).join(" · ");
    if (meta) c.appendChild(el("div", "meta", meta));
    if (s.question) {
      c.appendChild(el("div", "q", "❓ " + s.question));
      if (s.canAnswer && s.options.length) {
        var box = el("div", "opts"), btns = [];
        s.options.forEach(function(o){
          var b = el("button", null, o); btns.push(b);
          b.addEventListener("click", function(){ answer(s, o, btns); });
          box.appendChild(b);
        });
        if (busy[s.id]) btns.forEach(function(b){ b.disabled = true; });
        c.appendChild(box);
      } else {
        c.appendChild(el("div", "note", "這題要在 Mac mini 的戰情中心或終端機回答（權限／選擇題／選單網頁版還不能答）"));
      }
      if (s.answeredAt) c.appendChild(el("div", "note", "已送出 " + hhmm(s.answeredAt) + "，等它動作"));
    }
    // 傳話／派工（文字會加上【使用者從網頁戰情中心】前綴）
    var d = el("details", "say");
    if (opened[s.id]) d.open = true;
    d.addEventListener("toggle", function(){ opened[s.id] = d.open; });
    d.appendChild(el("summary", null, "傳話／派工給 " + s.name));
    var ta = el("textarea"); ta.maxLength = 2000; ta.placeholder = "要跟它說的話，或要派的工作";
    ta.value = drafts[s.id] || "";
    ta.addEventListener("input", function(){ drafts[s.id] = ta.value; });
    d.appendChild(ta);
    var row = el("div", "row");
    var bs = el("button", null, "直接傳話"), bt = el("button", "sec", "開派工單");
    function clear(){ drafts[s.id] = ""; ta.value = ""; }
    bs.addEventListener("click", function(){
      var t = ta.value.replace(/^\s+|\s+$/g, ""); if (!t) { toast("先打字"); return; }
      post("/api/send", "say:" + s.id, { id: s.id, text: t }, "傳話給「" + s.name + "」：\n" + t, [bs, bt], clear);
    });
    bt.addEventListener("click", function(){
      var t = ta.value.replace(/^\s+|\s+$/g, ""); if (!t) { toast("先打字"); return; }
      post("/api/task", "say:" + s.id, { id: s.id, text: t }, "開派工單給「" + s.name + "」：\n" + t, [bs, bt], clear);
    });
    row.appendChild(bs); row.appendChild(bt); d.appendChild(row);
    c.appendChild(d);
    return c;
  }

  function render(d) {
    var box = document.getElementById("sessions"); box.textContent = "";
    var n = {}; d.sessions.forEach(function(s){ n[s.columnTitle] = (n[s.columnTitle] || 0) + 1; });
    var asks = d.sessions.filter(function(s){ return !!s.question; }).length;
    var counts = document.getElementById("counts"); counts.textContent = "";
    if (asks) counts.appendChild(el("span", "pill", "等你回答 " + asks));
    ["工作中","待審","卡住","完成","待辦"].forEach(function(k){ if (n[k]) counts.appendChild(el("span", "pill", k + " " + n[k])); });
    if (!d.sessions.length) box.appendChild(el("div", "empty", "現在沒有開著的 session"));
    d.sessions.forEach(function(s){ box.appendChild(card(s)); });
    var tb = document.getElementById("tasks"); tb.textContent = "";
    if (!d.tasks.length) tb.appendChild(el("div", "empty", "沒有"));
    d.tasks.forEach(function(t){
      var e = el("div", "t");
      e.appendChild(el("div", "h", t.id + " → " + t.to + (t.project ? "（" + t.project + "）" : "") + " · " + t.stateTitle));
      e.appendChild(el("div", null, t.text));
      if (t.summary) e.appendChild(el("div", "sum", t.summary));
      var b = el("button", "sec", "取消這張單");
      b.addEventListener("click", function(){ post("/api/task/cancel", "task:" + t.id, { id: t.id }, "取消派工單 " + t.id + "（" + t.to + "）？", [b]); });
      var r = el("div", "row"); r.appendChild(b); e.appendChild(r);
      tb.appendChild(e);
    });
    var KIND = { start: "開工卡", notice: "動作預告", block: "擋下等放行" };
    var ib = document.getElementById("inbox"); ib.textContent = "";
    var items = d.inbox || [];
    if (!items.length) ib.appendChild(el("div", "empty", "沒有"));
    items.forEach(function(i){
      var e = el("div", "t");
      e.appendChild(el("div", "h", i.id + " · " + (KIND[i.kind] || i.kind) + " · " + i.name + (i.project ? "（" + i.project + "）" : "") + " · " + hhmm(i.at)));
      e.appendChild(el("div", null, i.text));
      var b = el("button", "sec", "標已處理");
      b.addEventListener("click", function(){ post("/api/inbox/ack", "ack:" + i.id, { id: i.id }, "把收件匣 " + i.id + " 標成已處理？", [b]); });
      var r = el("div", "row"); r.appendChild(b); e.appendChild(r);
      ib.appendChild(e);
    });
    status("更新於 " + hhmm(d.generatedAt), false);
  }

  function load() {
    if (!token) { status("缺 token：請用 showork web enable 印出的網址開", true); return; }
    fetch("/api/board", { headers: { "X-ShoWork-Token": token }, cache: "no-store" })
      .then(function(r){ if (r.status === 403) throw new Error("token 不對或已換新"); if (!r.ok) throw new Error("HTTP " + r.status); return r.json(); })
      .then(function(d){
        // 正在打字時不重畫（重畫會讓輸入框失焦）；打完、離開輸入框的下一輪再畫
        var a = document.activeElement;
        if (a && a.tagName === "TEXTAREA") { status("更新於 " + hhmm(d.generatedAt) + "（打字中，畫面暫停更新）", false); return; }
        render(d);
      })
      .catch(function(e){ status("連線失敗：" + e.message, true); });
  }
  function tick() { clearTimeout(timer); load(); timer = setTimeout(tick, 5000); }
  document.addEventListener("visibilitychange", function(){ if (!document.hidden) tick(); });
  tick();
})();
</script>
</body>
</html>
"""#
}
