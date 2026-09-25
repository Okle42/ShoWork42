#!/usr/bin/env python3
"""Generates exclusive_board.html — the "how big should each window's always-clickable area be" decision.
Geometry mirrors Sources/ShoWorkCore/LayoutPlan.swift (overlapRows) exactly."""
import math, os

W, AREA_Y, AREA_H = 1920, 30, 964          # Keng's main screen, visible area
LINE = 17                                   # ≈ one text line in Keng's Ghostty
TITLE = 28

def overlap_rows(rows, M, half_shift):
    R = len(rows)
    d = M if R <= 2 else max(M, math.ceil((AREA_H + M) / (R + 1)))
    h = AREA_H - (R - 1) * d
    out = []
    mx = max(rows)
    for r, count in enumerate(rows):
        w = W / mx if half_shift else W / count
        shift = w / 2 if (half_shift and count < mx) else 0
        for c in range(count):
            out.append((round(shift + c * w), AREA_Y + r * d, round(w), h, r))
    return out, d, h

def exclusive_rect(i, frames):
    """Largest horizontal band of window i not covered by any other frame (same-row neighbours never overlap)."""
    x, y, w, h, _ = frames[i]
    top, bot = y, y + h
    # cut away every other frame that overlaps horizontally
    free = [(top, bot)]
    for j, (x2, y2, w2, h2, _) in enumerate(frames):
        if j == i or x2 >= x + w or x2 + w2 <= x: continue
        nxt = []
        for a, b in free:
            if y2 + h2 <= a or y2 >= b: nxt.append((a, b)); continue
            if y2 > a: nxt.append((a, y2))
            if y2 + h2 < b: nxt.append((y2 + h2, b))
        free = nxt
    return max(free, key=lambda ab: ab[1] - ab[0], default=(0, 0))

ROW_COLORS = ["#8B5CF6", "#F59E0B", "#10B981"]

def svg(rows, M, half_shift, scale=0.19):
    frames, d, h = overlap_rows(rows, M, half_shift)
    sw, sh = W * scale, (AREA_Y + AREA_H) * scale
    p = [f'<svg viewBox="0 0 {sw:.0f} {sh + 4:.0f}" class="shot" role="img">',
         f'<rect x="0" y="0" width="{sw:.0f}" height="{AREA_Y*scale:.1f}" fill="var(--menubar)"/>',
         f'<rect x="0" y="{AREA_Y*scale:.1f}" width="{sw:.0f}" height="{AREA_H*scale:.1f}" fill="var(--desk)"/>']
    colors = ROW_COLORS if len(rows) == 3 else [ROW_COLORS[0], ROW_COLORS[2]]   # 2 rows: top purple, bottom green
    for i, (x, y, w, hh, r) in enumerate(frames):        # later frames on top (stacking order)
        c = colors[r]
        p.append(f'<rect x="{x*scale+0.6:.1f}" y="{y*scale+0.6:.1f}" width="{w*scale-1.2:.1f}" height="{hh*scale-1.2:.1f}" rx="2.5" fill="var(--win)" stroke="{c}" stroke-width="1.2"/>')
        p.append(f'<rect x="{x*scale+0.6:.1f}" y="{y*scale+0.6:.1f}" width="{w*scale-1.2:.1f}" height="{TITLE*scale:.1f}" rx="2" fill="{c}" opacity=".85"/>')
    for i, (x, y, w, hh, r) in enumerate(frames):        # exclusive bands on top of everything
        a, b = exclusive_rect(i, frames)
        p.append(f'<rect x="{x*scale+2:.1f}" y="{a*scale+1:.1f}" width="{w*scale-4:.1f}" height="{max(0,(b-a)*scale-2):.1f}" fill="{colors[r]}" opacity=".28"/>')
    p.append('</svg>')
    return "\n".join(p), h

OPTIONS = [
    ("120", "目前這版", "只露出標題列＋約 5 行"),
    ("180", "", "標題列＋約 9 行"),
    ("240", "", "標題列＋約 12 行"),
    ("300", "", "標題列＋約 16 行"),
]

cards = []
for m, tag, lines in OPTIONS:
    M = int(m)
    s7, h7 = svg([4, 3], M, False)
    s11, h11 = svg([4, 3, 4], M, True)
    cards.append(f'''
<label class="card" data-v="{m}">
  <input type="radio" name="excl" value="{m}">
  <div class="head"><span class="big">{m}pt</span>{f'<span class="tag">{tag}</span>' if tag else ''}<span class="lines">{lines}</span></div>
  <div class="pair">
    <figure>{s7}<figcaption>7 個視窗 · 每個高 <b>{h7}</b></figcaption></figure>
    <figure>{s11}<figcaption>11 個視窗 · 每個高 <b>{h11}</b></figcaption></figure>
  </div>
</label>''')

html = f'''<!doctype html>
<html lang="zh-Hant">
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>專屬區域決策</title>
<style>
:root {{ --bg:#0f1115; --card:#171a21; --line:#2a2f3a; --text:#e8eaf0; --dim:#9aa3b2; --accent:#8B5CF6;
        --desk:#1d2330; --win:#262b36; --menubar:#11141a; }}
:root[data-theme="light"] {{ --bg:#f5f6f8; --card:#fff; --line:#dfe3ea; --text:#141821; --dim:#5b6475; --desk:#dfe6f1; --win:#fbfbfd; --menubar:#cfd6e2; }}
@media (prefers-color-scheme: light) {{ :root:not([data-theme="dark"]) {{ --bg:#f5f6f8; --card:#fff; --line:#dfe3ea; --text:#141821; --dim:#5b6475; --desk:#dfe6f1; --win:#fbfbfd; --menubar:#cfd6e2; }} }}
* {{ box-sizing:border-box }}
body {{ margin:0; background:var(--bg); color:var(--text); font:15px/1.6 -apple-system, "PingFang TC", sans-serif; }}
main {{ max-width:1180px; margin:0 auto; padding:28px 16px 120px; }}
h1 {{ font-size:24px; margin:0 0 6px }}
p.lead {{ color:var(--dim); margin:0 0 18px }}
.explain {{ display:grid; grid-template-columns: 1.1fr 1fr; gap:16px; background:var(--card); border:1px solid var(--line); border-radius:14px; padding:16px; margin-bottom:22px }}
.explain img {{ width:100%; border-radius:8px; border:1px solid var(--line) }}
.legend span {{ display:inline-block; width:12px; height:12px; border-radius:3px; vertical-align:-1px; margin:0 4px 0 10px }}
.cards {{ display:grid; grid-template-columns: repeat(2, minmax(0,1fr)); gap:14px }}
.card {{ display:block; background:var(--card); border:2px solid var(--line); border-radius:14px; padding:14px; cursor:pointer; transition:border-color .15s }}
.card:hover {{ border-color:#5b4a9a }}
.card input {{ position:absolute; opacity:0 }}
.card.sel {{ border-color:var(--accent); box-shadow:0 0 0 4px color-mix(in srgb, var(--accent) 25%, transparent) }}
.head {{ display:flex; align-items:baseline; gap:10px; margin-bottom:8px }}
.big {{ font-size:22px; font-weight:700 }}
.tag {{ font-size:12px; padding:2px 8px; border-radius:99px; background:#2b2440; color:#c9b8ff }}
.lines {{ color:var(--dim) }}
.pair {{ display:grid; grid-template-columns:1fr 1fr; gap:10px }}
figure {{ margin:0 }}
.shot {{ width:100%; height:auto; display:block; border-radius:6px }}
figcaption {{ font-size:13px; color:var(--dim); margin-top:4px }}
.bar {{ position:fixed; left:0; right:0; bottom:0; background:color-mix(in srgb, var(--bg) 92%, transparent); backdrop-filter:blur(8px); border-top:1px solid var(--line) }}
.bar .in {{ max-width:1180px; margin:0 auto; padding:12px 16px; display:flex; gap:10px; align-items:center; flex-wrap:wrap }}
.bar textarea {{ flex:1; min-width:220px; height:42px; background:var(--card); color:var(--text); border:1px solid var(--line); border-radius:10px; padding:8px 10px; font:inherit }}
button {{ font:inherit; padding:10px 18px; border-radius:10px; border:0; background:var(--accent); color:#fff; font-weight:600; cursor:pointer }}
button.ghost {{ background:transparent; color:var(--text); border:1px solid var(--line) }}
#status {{ color:var(--dim); font-size:13px }}
@media (max-width: 820px) {{ .cards, .explain {{ grid-template-columns:1fr }} }}
</style>
<main>
  <h1>每個視窗要留多大的「一定點得到」的區域？</h1>
  <p class="lead">6 個以上的視窗會互相重疊。規則：每個視窗都保留一塊<b>不跟任何其他視窗重疊</b>的專屬區域——不管誰疊在上面，這塊永遠露在外面、點得到。<br>
  專屬區域越大 → 每個視窗露出越多 → 但視窗本身越矮。下面每張圖都是照程式真正的公式、等比例畫的。</p>

  <div class="explain">
    <div><img src="img/real120_7.png" alt="目前 120pt，7 個視窗實拍"><figcaption>實拍：目前 120pt、7 個視窗（上排只露出標題列＋幾行字）</figcaption></div>
    <div><img src="img/real120_11.png" alt="目前 120pt，11 個視窗實拍"><figcaption>實拍：目前 120pt、11 個視窗</figcaption>
      <p class="legend">圖例：<span style="background:#8B5CF6"></span>上排<span style="background:#F59E0B"></span>中排<span style="background:#10B981"></span>下排　粗色條＝標題列，淡色塊＝這個視窗的專屬區域</p></div>
  </div>

  <div class="cards">{''.join(cards)}
    <label class="card" data-v="adjustable">
      <input type="radio" name="excl" value="adjustable">
      <div class="head"><span class="big">做成可調</span><span class="lines">選單列放滑桿，預設用你在下面備註寫的值（沒寫就 180）</span></div>
      <p class="lines">適合想先用用看、再慢慢調到順手的情況。</p>
    </label>
  </div>
</main>
<div class="bar"><div class="in">
  <textarea id="note" placeholder="備註（選填）：例如「9 個以上用 180、6～8 個用 240」"></textarea>
  <button id="send" disabled>送出</button>
  <button class="ghost" id="copy">拷貝答案</button>
  <span id="status">先點一張卡片選擇</span>
</div></div>
<script>
const cards=[...document.querySelectorAll('.card')];
let choice=null;
cards.forEach(c=>c.addEventListener('click',()=>{{cards.forEach(x=>x.classList.remove('sel'));c.classList.add('sel');choice=c.dataset.v;
  document.getElementById('send').disabled=false;document.getElementById('status').textContent='已選：'+(choice==='adjustable'?'做成可調':choice+'pt');}}));
function payload(){{const note=document.getElementById('note').value.trim();
  return {{answers:{{exclusive:choice}},notes:note?{{exclusive:note}}:{{}},summary:'專屬區域 '+(choice==='adjustable'?'可調':choice+'pt')+(note?'；備註：'+note:'')}};}}
document.getElementById('send').onclick=async()=>{{const s=document.getElementById('status');
  try{{const r=await fetch('/__submit',{{method:'POST',headers:{{'Content-Type':'application/json'}},body:JSON.stringify(payload())}});
    s.textContent=r.ok?'✅ 已送出給 Claude，可以關掉這頁了':'送出失敗，請按「拷貝答案」貼回對話';}}
  catch(e){{s.textContent='送出失敗（可能是用檔案直接開的），請按「拷貝答案」貼回對話';}}}};
document.getElementById('copy').onclick=()=>{{navigator.clipboard.writeText(payload().summary);document.getElementById('status').textContent='已拷貝';}};
</script>
</html>
'''
out = os.path.join(os.path.dirname(os.path.abspath(__file__)), "exclusive_board.html")
open(out, "w", encoding="utf-8").write(html)
print(out)
