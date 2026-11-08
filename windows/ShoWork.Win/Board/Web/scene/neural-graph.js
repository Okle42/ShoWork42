// ShoWorkCore/NeuralGraph.swift＋NeuralGraphLayout.swift 照搬（11-02 P8）：地下室 B1 機房中間浮著的 3D 神經網路的資料與擺放。純函式、不碰 three。
//
// 地下室 B1 機房中間浮著的 3D 神經網路（10-22 Kang：參考 Graphify「整個專案變成一張知識圖譜」）。
// 資料：各專案用 Graphify（離線、只做程式碼 AST）抽出 graph.json → 精簡成每個專案最重要的幾十個節點 → 排成 3D 位置。
// 畫面只讀這個結構，不知道 Graphify 的存在；座標是「圖譜本地座標」，半徑約 1，畫面自己縮放擺到機房中間。
//
// ── Windows 的輸入格式（C# 資料端照這個給；欄位跟 Swift 的 NeuralGraph 一模一樣）──
//   {
//     "nodes": [{ "id": "專案#符號id", "label": "類別／函式名", "project": "專案（樓層名）", "file": "相對 repo 的原始檔" | null,
//                 "community": 0, "degree": 0, "x": 0.0, "y": 0.0, "z": 0.0 }, ...],
//     "edges": [{ "a": 0, "b": 1 }, ...],          // nodes 的索引（也接受 [a, b] 兩個數字的陣列）
//     "builtAt": "2026-11-02T00:00:00Z" | null     // ISO-8601（Swift 的 Date?）
//   }
//   x／y／z 已經是 NeuralGraphBuild.merge 排好的位置（半徑 ≤ 1）。C# 端可以只做「讀 graph.json」，
//   精簡＋排版直接用 neural-build.js 的 NeuralGraphBuild.slim／merge（同輸入一定同輸出，跟 Mac 一樣）。

const M64 = (1n << 64n) - 1n;

/** Swift 的 NeuralGraph.Node（init 的預設值照抄） */
export function neuralNode({ id, label, project, file = null, community = 0, degree = 0, x = 0, y = 0, z = 0 }) {
  return { id, label, project, file, community, degree, x, y, z };
}
/** Swift 的 NeuralGraph.Edge(a, b) */
export function neuralEdge(a, b) { return { a, b }; }

export class NeuralGraph {
  constructor({ nodes = [], edges = [], builtAt = null } = {}) {
    this.nodes = nodes; this.edges = edges; this.builtAt = builtAt;
  }
  get isEmpty() { return this.nodes.length === 0; }

  /** 上面那份 JSON 格式 → NeuralGraph（欄位缺的用 Swift init 的預設值；讀不懂回空圖） */
  static fromJSON(o) {
    if (typeof o === "string") { try { o = JSON.parse(o); } catch { return new NeuralGraph(); } }
    if (!o || !Array.isArray(o.nodes)) return new NeuralGraph();
    const nodes = o.nodes.map(n => neuralNode({
      id: String(n.id), label: String(n.label ?? n.id), project: String(n.project ?? ""), file: n.file ?? null,
      community: Math.trunc(n.community ?? 0), degree: Math.trunc(n.degree ?? 0), x: +(n.x ?? 0), y: +(n.y ?? 0), z: +(n.z ?? 0),
    }));
    const edges = (o.edges ?? []).map(e => Array.isArray(e) ? neuralEdge(e[0] | 0, e[1] | 0) : neuralEdge(e.a | 0, e.b | 0));
    const builtAt = o.builtAt ? new Date(o.builtAt) : null;
    return new NeuralGraph({ nodes, edges, builtAt: builtAt && !isNaN(builtAt) ? builtAt : null });
  }
  toJSON() { return { nodes: this.nodes, edges: this.edges, builtAt: this.builtAt ? this.builtAt.toISOString() : null }; }

  /** 還沒有真資料時（第一次跑 Graphify 之前、測試視窗）：固定種子的假圖，讓畫面有東西 */
  static demo(projects = ["專案A", "專案B", "專案C"], perProject = 40) {
    const g = new NeuralGraph();
    let seed = 42n;
    const rnd = () => { seed = (seed * 6364136223846793005n + 1442695040888963407n) & M64; return Number(seed >> 11n) / 9007199254740992; };
    projects.forEach((p, pi) => {
      const base = g.nodes.length;
      const ang = pi / Math.max(projects.length, 1) * 2 * Math.PI;
      const cx = 0.45 * Math.cos(ang), cz = 0.45 * Math.sin(ang);
      for (let i = 0; i < perProject; i++) {
        // Swift：let u = rnd()…, v = acos(…), r = …（同一行由左到右求值）
        const u = rnd() * 2 * Math.PI, v = Math.acos(2 * rnd() - 1), r = 0.15 + 0.4 * Math.pow(rnd(), 0.6);
        const degree = i < 4 ? 12 : 1 + Math.trunc(rnd() * 5);
        g.nodes.push(neuralNode({ id: `${p}#${i}`, label: `${p}-${i}`, project: p, community: i % 5, degree,
                                  x: cx + r * Math.sin(v) * Math.cos(u), y: r * Math.cos(v), z: cz + r * Math.sin(v) * Math.sin(u) }));
        if (i > 0) g.edges.push(neuralEdge(base + i, base + Math.trunc(rnd() * Math.min(i, 4))));
        if (i > 6 && rnd() < 0.5) g.edges.push(neuralEdge(base + i, base + Math.trunc(rnd() * i)));
      }
      if (pi > 0) g.edges.push(neuralEdge(base, base - perProject));
    });
    return g;
  }

  // MARK: 擺放（NeuralGraphLayout.swift）
  // 地下室 B1 神經網路的擺放（純數字，可測）：圖譜本地座標 → 機房裡的位置（以圖譜中心為原點、縮到指定半徑），
  // 節點大小依 degree、顏色依專案（同專案同色、照第一次出現的順序循環調色盤）。畫面（basement.js）只拿這份結果畫。

  /**
   * 擺到半徑 `radius` 的球裡（包圍盒中心當原點；最遠的節點剛好在半徑上）。
   * 節點大小：`minSize` 起跳、依 √degree 長大、最大 `maxSize`；`maxNodes` 以上只留 degree 高的（畫面上限）
   * 回傳 NeuralPlacement：{ dots: [{x, y, z, size, color, project}], edges: [{a, b}], projects: [String] }
   */
  placement({ radius = 1.6, minSize = 0.05, maxSize = 0.16, palette = 8, maxNodes = 1500 } = {}) {
    const nodes = this.nodes;
    if (!nodes.length) return { dots: [], edges: [], projects: [] };
    // 太多就留 degree 高的（原順序不變，邊的索引跟著重編）
    let keep = nodes.map((_, i) => i);
    if (nodes.length > maxNodes) {
      keep = keep.slice().sort((a, b) => nodes[a].degree !== nodes[b].degree ? nodes[b].degree - nodes[a].degree : a - b)
        .slice(0, maxNodes).sort((a, b) => a - b);
    }
    const remap = new Map();
    keep.forEach((k, i) => remap.set(k, i));
    const ns = keep.map(i => nodes[i]);
    const mn = f => ns.reduce((m, n) => Math.min(m, n[f]), Infinity), mx = f => ns.reduce((m, n) => Math.max(m, n[f]), -Infinity);
    const lo = [mn("x"), mn("y"), mn("z")], hi = [mx("x"), mx("y"), mx("z")];
    const c = [(lo[0] + hi[0]) / 2, (lo[1] + hi[1]) / 2, (lo[2] + hi[2]) / 2];
    const far = ns.reduce((m, n) => Math.max(m, Math.sqrt(Math.pow(n.x - c[0], 2) + Math.pow(n.y - c[1], 2) + Math.pow(n.z - c[2], 2))), 0);
    const k = far > 1e-9 ? radius / far : 0;
    const maxDeg = Math.max(1, ns.reduce((m, n) => Math.max(m, n.degree), -Infinity));
    const projects = [];
    const color = new Map();
    const dots = ns.map(n => {
      let pj;
      if (color.has(n.project)) pj = color.get(n.project);
      else { pj = projects.length; color.set(n.project, pj); projects.push(n.project); }
      const ci = pj % Math.max(1, palette);
      const t = Math.sqrt(Math.max(0, n.degree) / maxDeg);
      return { x: (n.x - c[0]) * k, y: (n.y - c[1]) * k, z: (n.z - c[2]) * k, size: minSize + (maxSize - minSize) * t, color: ci, project: pj };
    });
    const seen = new Set();
    const es = [];
    for (const e of this.edges) {
      const a = remap.get(e.a), b = remap.get(e.b);
      if (a === undefined || b === undefined || a === b) continue;
      const key = Math.min(a, b) * ns.length + Math.max(a, b);
      if (!seen.has(key)) { seen.add(key); es.push(neuralEdge(Math.min(a, b), Math.max(a, b))); }
    }
    return { dots, edges: es, projects };
  }
}
