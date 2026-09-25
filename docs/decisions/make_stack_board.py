#!/usr/bin/env python3
"""stack_board.html — confirms Keng's 11-window stacking logic and picks row heights.
Keng 09-26: 300pt exposed per row; purple(top row) and green(bottom row) may overlap; clicking a green
window must make the yellow(middle) windows re-emerge ABOVE purple and BELOW green."""
import os

W, Y0, AH, D = 1920, 30, 964, 300
COL = {"p": "#8B5CF6", "y": "#F59E0B", "g": "#10B981"}
TITLE = 28

def frames(heights):
    hp, hy, hg = heights
    out = []
    for c in range(4): out.append(("p", c * 480, Y0, 480, hp, f"紫{c+1}"))
    for c in range(3): out.append(("y", 240 + c * 480, Y0 + D, 480, hy, f"黃{c+1}"))
    for c in range(4): out.append(("g", c * 480, Y0 + 2 * D, 480, hg, f"綠{c+1}"))
    return out

def svg(fr, order, focus=None, scale=0.2):
    """order: list of indices bottom→top. focus: index drawn with a white ring + cursor."""
    sw, sh = W * scale, (Y0 + AH) * scale
    p = [f'<svg viewBox="0 0 {sw:.0f} {sh+4:.0f}" class="shot">',
         f'<rect width="{sw:.0f}" height="{Y0*scale:.1f}" fill="var(--menubar)"/>',
         f'<rect y="{Y0*scale:.1f}" width="{sw:.0f}" height="{AH*scale:.1f}" fill="var(--desk)"/>']
    for i in order:
        k, x, y, w, h, name = fr[i]
        c = COL[k]
        ring = ' stroke="#fff" stroke-width="2.4"' if i == focus else f' stroke="{c}" stroke-width="1.2"'
        p.append(f'<rect x="{x*scale+.6:.1f}" y="{y*scale+.6:.1f}" width="{w*scale-1.2:.1f}" height="{h*scale-1.2:.1f}" rx="2.5" fill="var(--win)"{ring}/>')
        p.append(f'<rect x="{x*scale+.6:.1f}" y="{y*scale+.6:.1f}" width="{w*scale-1.2:.1f}" height="{TITLE*scale:.1f}" rx="2" fill="{c}"/>')
        p.append(f'<text x="{x*scale+6:.1f}" y="{y*scale+TITLE*scale+14:.1f}" class="lbl" fill="{c}">{name}</text>')
        # the terminal's newest line lives at the BOTTOM of the window
        p.append(f'<rect x="{x*scale+4:.1f}" y="{(y+h)*scale-9:.1f}" width="{w*scale*0.45:.1f}" height="4" rx="1" fill="{c}" opacity=".9"/>')
    if focus is not None:
        k, x, y, w, h, _ = fr[focus]
        cx, cy = (x + w * 0.55) * scale, (y + h * 0.5 if k == "g" else y + 150) * scale
        p.append(f'<path d="M{cx:.1f},{cy:.1f} l0,16 l4,-4 l4,8 l3,-1.5 l-4,-8 l6,0 z" fill="#fff" stroke="#000" stroke-width=".8"/>')
    p.append('</svg>')
    return "".join(p)

base = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10]            # purple < yellow < green
def to_top(i): return [j for j in base if j != i] + [i]

UNIFORM = (364, 364, 364)
TOBOTTOM = (964, 664, 364)
steps = [
    ("① 平常", "固定順序：紫在最下、黃在中間、綠在最上。每排都露出 300pt。", lambda f: svg(f, base)),
    ("② 你點了「紫2」", "紫2 浮到最上面給你用（黃1、黃2 被它蓋住一部分——這是你正在用它，沒關係）。", lambda f: svg(f, to_top(1), focus=1)),
    ("③ 接著你點「綠3」", "綠3 到最上面；其他視窗<b>自動回到「紫＜黃＜綠」</b>：黃色重新從紫、綠之間露出來。", lambda f: svg(f, to_top(9), focus=9)),
]

def strip(heights):
    f = frames(heights)
    return "".join(f'<figure><figcaption class="st">{t}</figcaption>{fn(f)}<figcaption>{d}</figcaption></figure>' for t, d, fn in steps)

html = f'''<!doctype html>
<html lang="zh-Hant">
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>11 視窗疊放決策</title>
<style>
:root {{ --bg:#0f1115; --card:#171a21; --line:#2a2f3a; --text:#e8eaf0; --dim:#9aa3b2; --accent:#8B5CF6; --desk:#1d2330; --win:#262b36; --menubar:#11141a; }}
@media (prefers-color-scheme: light) {{ :root:not([data-theme="dark"]) {{ --bg:#f5f6f8; --card:#fff; --line:#dfe3ea; --text:#141821; --dim:#5b6475; --desk:#dfe6f1; --win:#fbfbfd; --menubar:#cfd6e2; }} }}
:root[data-theme="light"] {{ --bg:#f5f6f8; --card:#fff; --line:#dfe3ea; --text:#141821; --dim:#5b6475; --desk:#dfe6f1; --win:#fbfbfd; --menubar:#cfd6e2; }}
* {{ box-sizing:border-box }}
body {{ margin:0; background:var(--bg); color:var(--text); font:15px/1.6 -apple-system,"PingFang TC",sans-serif }}
main {{ max-width:1200px; margin:0 auto; padding:26px 16px 130px }}
h1 {{ font-size:23px; margin:0 0 6px }} h2 {{ font-size:18px; margin:26px 0 8px }}
.lead {{ color:var(--dim); margin:0 0 14px }}
.strip {{ display:grid; grid-template-columns:repeat(3,minmax(0,1fr)); gap:12px }}
figure {{ margin:0; background:var(--card); border:1px solid var(--line); border-radius:12px; padding:10px }}
.shot {{ width:100%; height:auto; display:block; border-radius:6px }}
figcaption {{ font-size:13px; color:var(--dim); margin-top:6px }}
figcaption.st {{ color:var(--text); font-weight:600; margin:0 0 6px }}
.lbl {{ font-size:9px; font-weight:700 }}
.q {{ background:var(--card); border:2px solid var(--line); border-radius:14px; padding:14px; margin-top:10px }}
.opts {{ display:grid; grid-template-columns:1fr 1fr; gap:12px }}
.opt {{ display:block; background:var(--card); border:2px solid var(--line); border-radius:14px; padding:14px; cursor:pointer }}
.opt.sel {{ border-color:var(--accent); box-shadow:0 0 0 4px color-mix(in srgb,var(--accent) 25%,transparent) }}
.opt input {{ position:absolute; opacity:0 }}
.opt b.t {{ font-size:17px }}
.pill {{ display:inline-block; font-size:12px; padding:1px 8px; border-radius:99px; background:#2b2440; color:#c9b8ff; margin-left:6px }}
.warn {{ border-left:3px solid #F59E0B; padding:6px 10px; background:color-mix(in srgb,#F59E0B 10%,transparent); border-radius:6px; margin:10px 0 }}
.bar {{ position:fixed; left:0; right:0; bottom:0; background:color-mix(in srgb,var(--bg) 92%,transparent); backdrop-filter:blur(8px); border-top:1px solid var(--line) }}
.bar .in {{ max-width:1200px; margin:0 auto; padding:12px 16px; display:flex; gap:10px; align-items:center; flex-wrap:wrap }}
textarea {{ flex:1; min-width:220px; height:42px; background:var(--card); color:var(--text); border:1px solid var(--line); border-radius:10px; padding:8px 10px; font:inherit }}
button {{ font:inherit; padding:10px 18px; border-radius:10px; border:0; background:var(--accent); color:#fff; font-weight:600; cursor:pointer }}
button.ghost {{ background:transparent; color:var(--text); border:1px solid var(--line) }}
#status {{ color:var(--dim); font-size:13px }}
@media (max-width:860px) {{ .strip,.opts {{ grid-template-columns:1fr }} }}
</style>
<main>
  <h1>11 個視窗：我理解的「疊放會自己整理」對嗎？</h1>
  <p class="lead">7 個視窗照你滿意的那版（300pt）。11 個視窗改成：位置固定，<b>疊放順序自動整理</b>——固定是「紫＜黃＜綠」，你點的那個浮到最上面；你一點別的，其他又回到「紫＜黃＜綠」，黃色就一定會從中間露出來。</p>

  <h2>問題 1：這個邏輯對嗎？（下面三格是依序發生的畫面）</h2>
  <div class="strip">{strip(UNIFORM)}</div>
  <div class="q">
    <div class="opts">
      <label class="opt" data-q="logic" data-v="yes"><input type="radio" name="logic"><b class="t">對，就是這個意思</b></label>
      <label class="opt" data-q="logic" data-v="no"><input type="radio" name="logic"><b class="t">不太對</b>（請在下方備註寫哪裡不同）</label>
    </div>
  </div>

  <h2>問題 2：視窗高度要怎麼給？</h2>
  <div class="warn">⚠ 終端機跟一般視窗不同：<b>最新的輸出和輸入列在視窗最下面</b>（圖中每個視窗底部的色條）。被蓋住的通常是下半部，露出來的是上面比較舊的內容。</div>
  <div class="opts">
    <label class="opt" data-q="height" data-v="uniform"><input type="radio" name="height">
      <b class="t">A. 三排一樣高（各 364）</b><span class="pill">建議</span>
      <p class="lead">每排剛好露出 300pt，<b>底部的最新一行幾乎都看得到</b>（只被下一排蓋 64pt）。點開也只有 364 高。</p>
      {svg(frames(UNIFORM), base)}
    </label>
    <label class="opt" data-q="height" data-v="tobottom"><input type="radio" name="height">
      <b class="t">B. 每排都延伸到螢幕底</b>
      <p class="lead">紫 964、黃 664、綠 364。<b>點開時變很高</b>，但平常紫、黃的最新一行被壓在下面看不到（要靠光暈知道狀態）。</p>
      {svg(frames(TOBOTTOM), base)}
    </label>
  </div>
</main>
<div class="bar"><div class="in">
  <textarea id="note" placeholder="備註（選填）"></textarea>
  <button id="send" disabled>送出</button>
  <button class="ghost" id="copy">拷貝答案</button>
  <span id="status">兩題都選好再送出</span>
</div></div>
<script>
const ans={{}};
document.querySelectorAll('.opt').forEach(o=>o.addEventListener('click',()=>{{
  document.querySelectorAll(`.opt[data-q="${{o.dataset.q}}"]`).forEach(x=>x.classList.remove('sel'));
  o.classList.add('sel'); ans[o.dataset.q]=o.dataset.v;
  const ok=ans.logic&&ans.height; document.getElementById('send').disabled=!ok;
  document.getElementById('status').textContent=ok?'可以送出了':'兩題都選好再送出';}}));
function payload(){{const n=document.getElementById('note').value.trim();
  return {{answers:ans,notes:n?{{note:n}}:{{}},summary:`邏輯=${{ans.logic}} 高度=${{ans.height}}`+(n?'；備註：'+n:'')}};}}
document.getElementById('send').onclick=async()=>{{const s=document.getElementById('status');
  try{{const r=await fetch('/__submit',{{method:'POST',headers:{{'Content-Type':'application/json'}},body:JSON.stringify(payload())}});
    s.textContent=r.ok?'✅ 已送出給 Claude，可以關掉這頁了':'送出失敗，請按「拷貝答案」貼回對話';}}
  catch(e){{s.textContent='送出失敗，請按「拷貝答案」貼回對話';}}}};
document.getElementById('copy').onclick=()=>{{navigator.clipboard.writeText(payload().summary);document.getElementById('status').textContent='已拷貝';}};
</script>
</html>
'''
out = os.path.join(os.path.dirname(os.path.abspath(__file__)), "stack_board.html")
open(out, "w", encoding="utf-8").write(html)
print(out)
