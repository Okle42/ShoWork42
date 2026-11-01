// ShoWorkCore/NebulaPage.swift 照搬（11-02 P8）。純函式：graph.json → 星雲頁要的精簡資料 → 套範本。
//
// 3D 知識星雲頁（10-22 Kang：「這個圖片可以變成 3D 一點的星雲圖嗎？」——Graphify 原本的 graph.html 是 2D）。
// 頁面範本＋繪圖函式庫（three.js 0.180、3d-force-graph 1.80.1）打包在 assets/nebula/，安裝時放到 App Support/ShoWork42/nebula/，
// 不走 CDN（10-22 隊長 Chris：斷網或 CDN 改版就開不了、也少一條對外連線）。這裡只做純函式：graph.json → 頁面要的精簡資料 → 套範本。
// Swift 回傳 Data（JSONSerialization .sortedKeys）；這裡回傳同樣排過 key 的 JSON 字串（讀不懂回 null）。

/** JSONSerialization(.sortedKeys) 的樣子：物件的 key 照字典序（Swift 對 String 排序；key 都是 ASCII，跟 JS 一樣） */
function sortedStringify(v) {
  if (Array.isArray(v)) return "[" + v.map(sortedStringify).join(",") + "]";
  if (v && typeof v === "object") return "{" + Object.keys(v).sort().map(k => JSON.stringify(k) + ":" + sortedStringify(v[k])).join(",") + "}";
  return JSON.stringify(v);
}
const parse = j => { if (typeof j !== "string") return j; try { return JSON.parse(j); } catch { return null; } };
const isObj = v => v && typeof v === "object" && !Array.isArray(v);

export const NebulaPage = {
  /** 一頁最多幾顆星（再多瀏覽器會卡） */
  limit: 2000,

  /** Graphify 的 graph.json → 星雲頁資料：依連線數取前 limit 顆（孤點不要）、只留這些星之間的邊、去重複與自己連自己 */
  data(json, limit = NebulaPage.limit) {
    const g = parse(json);
    if (!isObj(g) || !Array.isArray(g.nodes)) return null;
    const nodes = g.nodes.filter(isObj);
    const links = (Array.isArray(g.links) ? g.links : Array.isArray(g.edges) ? g.edges : []).filter(isObj);
    const id = v => typeof v === "string" ? v : (isObj(v) && typeof v.id === "string" ? v.id : null);
    const deg = new Map();
    for (const l of links) {
      const a = id(l.source), b = id(l.target);
      if (a === null || b === null || a === b) continue;
      deg.set(a, (deg.get(a) ?? 0) + 1); deg.set(b, (deg.get(b) ?? 0) + 1);
    }
    const kept = nodes.filter(n => typeof n.id === "string" && (deg.get(n.id) ?? 0) > 0)
      // 連線數多的在前；同分照 id（結果固定）。Swift：(deg_a, id_b) > (deg_b, id_a)
      .sort((x, y) => { const dx = deg.get(x.id) ?? 0, dy = deg.get(y.id) ?? 0; return dx !== dy ? dy - dx : (x.id < y.id ? -1 : x.id > y.id ? 1 : 0); })
      .slice(0, Math.max(0, limit));
    const keep = new Set(kept.map(n => n.id));
    const seen = new Set(), outLinks = [];
    for (const l of links) {
      const a = id(l.source), b = id(l.target);
      if (a === null || b === null || a === b || !keep.has(a) || !keep.has(b)) continue;
      const k = a < b ? `${a}\u001F${b}` : `${b}\u001F${a}`;
      if (seen.has(k)) continue;
      seen.add(k);
      outLinks.push({ source: a, target: b });
    }
    const outNodes = kept.map(n => ({
      id: n.id, label: typeof n.label === "string" ? n.label : n.id, file: typeof n.source_file === "string" ? n.source_file : "",
      loc: typeof n.source_location === "string" ? n.source_location : "", c: Number.isInteger(n.community) ? n.community : 0,
      cn: typeof n.community_name === "string" ? n.community_name : "", deg: deg.get(n.id) ?? 0,
    }));
    return sortedStringify({ nodes: outNodes, links: outLinks });
  },

  /** 整棟大樓的星雲（10-22 Kang：「點地下室只有 ProjectB，不是應該這棟大樓相關的都要顯示嗎？」）：
   *  每個專案平分 limit 顆星（各自取連線數最多的），id 加專案前綴避免撞名；顏色＝專案（c＝專案序號），p＝專案名。專案之間沒有連線，力導向會自然分成一團團
   *  projects：[{ name, json }] */
  merge(projects, limit = NebulaPage.limit) {
    const ps = projects.slice().sort((a, b) => a.name < b.name ? -1 : a.name > b.name ? 1 : 0);
    if (!ps.length) return null;
    const share = Math.max(1, Math.trunc(limit / ps.length));
    const nodes = [], links = [];
    ps.forEach((p, i) => {
      const d = NebulaPage.data(p.json, share);
      const g = d && parse(d);
      if (!isObj(g) || !Array.isArray(g.nodes) || !g.nodes.length) return;
      const pre = p.name + "\u001F";
      for (const n0 of g.nodes) { const n = { ...n0 }; n.id = pre + n.id; n.c = i; n.p = p.name; nodes.push(n); }
      for (const l of g.links ?? []) links.push({ source: pre + l.source, target: pre + l.target });
    });
    if (!nodes.length) return null;
    return sortedStringify({ nodes, links, projects: ps.map(p => p.name) });
  },

  /** 套範本：__TITLE__ 換成（跳脫過的）專案名、__DATA__ 換成資料（"</" 跳脫，不會提早結束 <script>） */
  html(template, title, data) {
    const t = title.replaceAll("&", "&amp;").replaceAll("<", "&lt;").replaceAll(">", "&gt;").replaceAll("\"", "&quot;");
    const d = String(data).replaceAll("</", "<\\/");
    return template.replaceAll("__TITLE__", t).replaceAll("__DATA__", d);
  },
};
