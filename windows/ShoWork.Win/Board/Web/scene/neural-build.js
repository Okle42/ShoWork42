// ShoWorkCore/NeuralGraphBuild.swift 照搬（11-02 P8）。純函式、不碰 three，也不碰檔案（C# 資料端讀 graph.json 後交給這裡，或照抄成 C#）。
//
// 地下室神經網路的資料加工（10-22）：Graphify 的 graph.json → 每個專案精簡成一團 → 合成一張、排好 3D 座標。
// 全部是純函式（不碰檔案、不看時間），同輸入一定同輸出：畫面每次重排不會亂跳、測試可重現。
// graph.json 長相（Graphify 0.9.93，--code-only）：
//   nodes: [{id, label, community, source_file, type?("module"＝import 進來的框架)}]
//   links: [{source, target, relation}]
// 不準的地方：Graphify 把 String／Sendable 這類語言內建型別也當節點（source_file 是空的），框架 import 也是節點，這兩種都濾掉。

import { NeuralGraph, neuralNode, neuralEdge } from "./neural-graph.js";

const M64 = (1n << 64n) - 1n;
/** Swift 的 String < String（ASCII 範圍跟 JS 一樣；非 BMP 字元的順序可能不同，id 都是 ASCII） */
const lt = (a, b) => a < b;

export const NeuralGraphBuild = {
  /** 每個專案留幾個節點、幾條邊（畫面上一團 40 顆球剛好看得出形狀，再多就糊成一坨） */
  keepNodes: 40,
  keepEdges: 120,
  /** 團內半徑、各團中心排的圓半徑、上下錯開量 */
  clusterRadius: 0.35,
  ringRadius: 0.5,
  ringLift: 0.08,
  iterations: 200,

  /** 系統框架／套件的 import 名（小寫比對）：連線數很高但對「這個專案在做什麼」沒意義。
   *  String／Sendable 這類語言內建型別不用列：它們的 source_file 是空的，已經濾掉 */
  frameworks: new Set([
    "foundation", "swiftui", "scenekit", "appkit", "uikit", "testing", "xctest", "coregraphics", "coreimage",
    "corefoundation", "corevideo", "coremedia", "coreaudio", "avfoundation", "metal", "metalkit", "quartzcore",
    "combine", "dispatch", "darwin", "glibc", "simd", "os", "oslog", "observation", "cryptokit", "network",
    "webkit", "mapkit", "corelocation", "corebluetooth", "corenfc", "storekit", "spritekit", "gameplaykit",
    "realitykit", "arkit", "photos", "contacts", "eventkit", "usernotifications", "security", "localauthentication",
    "applicationservices", "carbon", "iokit", "screencapturekit", "vision", "naturallanguage", "speech",
    // 其他語言常見的
    "react", "react-dom", "next", "vue", "express", "lodash", "os.path", "sys", "json", "re", "typing",
    "pathlib", "subprocess", "collections", "datetime", "math", "numpy", "pandas",
  ]),

  // MARK: 精簡

  /**
   * graph.json（字串或已 parse 的物件）→ 連線數最多的前 `keep` 個節點＋它們之間的邊（最多 `maxEdges` 條）。讀不懂回 null。
   * 連線數算的是原圖的總度數（含連到被濾掉節點的線）；同分照 id 排，結果固定。
   * 回傳 Cluster：{ project, nodes: [Node], edges: [{a, b}]（團內索引） }
   */
  slim(json, project, keep = NeuralGraphBuild.keepNodes, maxEdges = NeuralGraphBuild.keepEdges) {
    let root = json;
    if (typeof json === "string") { try { root = JSON.parse(json); } catch { return null; } }
    if (!root || typeof root !== "object" || Array.isArray(root) || !Array.isArray(root.nodes)) return null;
    const rawNodes = root.nodes.filter(n => n && typeof n === "object" && !Array.isArray(n));
    const rawLinks = (Array.isArray(root.links) ? root.links : Array.isArray(root.edges) ? root.edges : []).filter(l => l && typeof l === "object");

    const degree = new Map();
    const pairs = [];
    for (const l of rawLinks) {
      const s = NeuralGraphBuild.endpoint(l.source), t = NeuralGraphBuild.endpoint(l.target);
      if (s === null || t === null) continue;
      degree.set(s, (degree.get(s) ?? 0) + 1); degree.set(t, (degree.get(t) ?? 0) + 1);
      pairs.push([s, t]);
    }

    const cands = [];
    const seen = new Set();
    for (const n of rawNodes) {
      const id = typeof n.id === "string" ? n.id : null;
      if (id === null || seen.has(id)) continue;
      const label = typeof n.label === "string" ? n.label : id;
      const file = typeof n.source_file === "string" ? n.source_file : "";
      if (!file) continue;                                                       // 語言內建型別、外部符號
      if (n.type === "module") continue;                                         // import 進來的模組
      if (NeuralGraphBuild.frameworks.has(label.toLowerCase())) continue;
      seen.add(id);
      const comm = typeof n.community === "number" ? Math.trunc(n.community) : 0;
      cands.push({ id, label, file, community: comm });
    }
    cands.sort((a, b) => {
      const da = degree.get(a.id) ?? 0, db = degree.get(b.id) ?? 0;
      if (da !== db) return db - da;
      return lt(a.id, b.id) ? -1 : lt(b.id, a.id) ? 1 : 0;
    });
    const kept = cands.slice(0, Math.max(0, keep));
    const index = new Map();
    kept.forEach((r, i) => index.set(r.id, i));
    const nodes = kept.map(r => neuralNode({ id: `${project}#${r.id}`, label: r.label, project, file: r.file,
                                             community: r.community, degree: degree.get(r.id) ?? 0 }));

    // 只留兩端都在裡面的邊；無向去重、不要自己連自己；兩端度數加總高的先留
    const edgeSet = new Set();
    let edges = [];
    for (const [s, t] of pairs) {
      const a = index.get(s), b = index.get(t);
      if (a === undefined || b === undefined || a === b) continue;
      const lo = Math.min(a, b), hi = Math.max(a, b);
      const k = lo * 100000 + hi;
      if (!edgeSet.has(k)) { edgeSet.add(k); edges.push(neuralEdge(lo, hi)); }
    }
    edges.sort((x, y) => {
      const wx = nodes[x.a].degree + nodes[x.b].degree, wy = nodes[y.a].degree + nodes[y.b].degree;
      if (wx !== wy) return wy - wx;
      return x.a !== y.a ? x.a - y.a : x.b - y.b;
    });
    if (edges.length > maxEdges) edges = edges.slice(0, Math.max(0, maxEdges));
    return { project, nodes, edges };
  },

  /** links 的端點：一般是字串 id；有些版本會是 {id: …} 物件 */
  endpoint(v) {
    if (typeof v === "string") return v;
    if (v && typeof v === "object" && typeof v.id === "string") return v.id;
    return null;
  },

  // MARK: 合併＋排版

  /** 多個專案合成一張：各團中心均勻排在半徑 0.5 的圓上（單數團稍微往上、雙數往下），團內力導向排成半徑約 0.35；
   *  專案之間用各團度數最高的節點依序串一條線。最後整張縮到半徑 ≤ 1。 */
  merge(clusters, builtAt = null, iterations = NeuralGraphBuild.iterations) {
    const cs = clusters.filter(c => c.nodes.length > 0);
    const g = new NeuralGraph({ builtAt });
    const hubs = [];
    cs.forEach((c, k) => {
      const base = g.nodes.length;
      const pos = NeuralGraphBuild.layout(c, NeuralGraphBuild.fnv(c.project), iterations);
      let center;
      if (cs.length === 1) {
        center = [0, 0, 0];
      } else {
        const ang = k / cs.length * 2 * Math.PI;
        center = [NeuralGraphBuild.ringRadius * Math.cos(ang), k % 2 === 0 ? NeuralGraphBuild.ringLift : -NeuralGraphBuild.ringLift,
                  NeuralGraphBuild.ringRadius * Math.sin(ang)];
      }
      c.nodes.forEach((n0, i) => {
        const n = { ...n0 };
        n.x = center[0] + pos[i][0]; n.y = center[1] + pos[i][1]; n.z = center[2] + pos[i][2];
        g.nodes.push(n);
      });
      for (const e of c.edges) g.edges.push(neuralEdge(base + e.a, base + e.b));
      // 度數最高（同分取前面的）＝這一團的代表
      let hub = 0;
      for (let i = 0; i < c.nodes.length; i++) if (c.nodes[i].degree > c.nodes[hub].degree) hub = i;
      hubs.push(base + hub);
    });
    for (let i = 1; i < hubs.length; i++) g.edges.push(neuralEdge(hubs[i - 1], hubs[i]));
    NeuralGraphBuild.normalize(g);
    return g;
  },

  /** 整張縮到半徑 ≤ 1（只縮不放；原點不動） */
  normalize(g, limit = 1) {
    const r = g.nodes.reduce((m, n) => Math.max(m, Math.sqrt(n.x * n.x + n.y * n.y + n.z * n.z)), 0);
    if (!(r > limit)) return;
    const s = limit / r;
    for (const n of g.nodes) { n.x *= s; n.y *= s; n.z *= s; }
  },

  /** 團內 3D 力導向（Fruchterman–Reingold 簡化版）：固定種子、固定迭代、逐步降溫；最後縮放到最遠的點＝clusterRadius */
  layout(c, seed, iterations) {
    const n = c.nodes.length;
    if (n <= 1) return Array.from({ length: n }, () => [0, 0, 0]);
    let s = BigInt.asUintN(64, BigInt(seed)) | 1n;
    const rnd = () => { s = (s * 6364136223846793005n + 1442695040888963407n) & M64; return Number(s >> 11n) / 9007199254740992; };
    let p = Array.from({ length: n }, () => { const a = rnd() * 2 - 1, b = rnd() * 2 - 1, cc = rnd() * 2 - 1; return [a, b, cc]; });
    const k = 1.0 / Math.sqrt(n);                 // 理想間距（單位立方體內）
    let temp = 0.1;
    const cool = temp / Math.max(iterations, 1);
    for (let it = 0; it < iterations; it++) {
      const d = Array.from({ length: n }, () => [0, 0, 0]);
      for (let i = 0; i < n; i++) {
        for (let j = i + 1; j < n; j++) {
          let dx = p[i][0] - p[j][0], dy = p[i][1] - p[j][1], dz = p[i][2] - p[j][2];
          let dist2 = dx * dx + dy * dy + dz * dz;
          if (dist2 < 1e-9) { dx = 0.01 * (i - j); dy = 0.01; dz = 0; dist2 = dx * dx + dy * dy; }
          const dist = Math.sqrt(dist2);
          const f = k * k / dist;                             // 斥力
          const ux = dx / dist * f, uy = dy / dist * f, uz = dz / dist * f;
          d[i][0] += ux; d[i][1] += uy; d[i][2] += uz;
          d[j][0] -= ux; d[j][1] -= uy; d[j][2] -= uz;
        }
      }
      for (const e of c.edges) {
        const dx = p[e.a][0] - p[e.b][0], dy = p[e.a][1] - p[e.b][1], dz = p[e.a][2] - p[e.b][2];
        const dist = Math.max(Math.sqrt(dx * dx + dy * dy + dz * dz), 1e-6);
        const f = dist * dist / k;                              // 引力
        const ux = dx / dist * f, uy = dy / dist * f, uz = dz / dist * f;
        d[e.a][0] -= ux; d[e.a][1] -= uy; d[e.a][2] -= uz;
        d[e.b][0] += ux; d[e.b][1] += uy; d[e.b][2] += uz;
      }
      for (let i = 0; i < n; i++) {
        // 往中心拉一點（沒有邊的孤點才不會飛走）
        d[i][0] -= p[i][0] * 0.5; d[i][1] -= p[i][1] * 0.5; d[i][2] -= p[i][2] * 0.5;
        const len = Math.sqrt(d[i][0] * d[i][0] + d[i][1] * d[i][1] + d[i][2] * d[i][2]);
        if (!(len > 1e-12)) continue;
        const step = Math.min(len, temp) / len;
        p[i][0] += d[i][0] * step; p[i][1] += d[i][1] * step; p[i][2] += d[i][2] * step;
      }
      temp = Math.max(temp - cool, 0.002);
    }
    // 置中＋縮放到半徑 clusterRadius
    const sum = j => p.reduce((acc, q) => acc + q[j], 0);
    const mx = sum(0) / n, my = sum(1) / n, mz = sum(2) / n;
    p = p.map(q => [q[0] - mx, q[1] - my, q[2] - mz]);
    const r = p.reduce((m, q) => Math.max(m, Math.sqrt(q[0] * q[0] + q[1] * q[1] + q[2] * q[2])), 0);
    const sc = r > 1e-9 ? NeuralGraphBuild.clusterRadius / r : 0;
    return p.map(q => [q[0] * sc, q[1] * sc, q[2] * sc]);
  },

  /** 固定的字串雜湊（FNV-1a 64 位元，照 UTF-8 位元組；Swift 的 hashValue 每次啟動不同，不能拿來當種子）。回 BigInt */
  fnv(s) {
    let h = 0xcbf29ce484222325n;
    for (const b of new TextEncoder().encode(s)) { h ^= BigInt(b); h = (h * 0x100000001b3n) & M64; }
    return h;
  },

  // MARK: 跑 Graphify 的規則

  /** 專案名 → 資料夾名（只留英數、-、_；其他換 _；空的給 "_"）。後面接雜湊尾巴避免「a.b」「a_b」撞名 */
  safeName(s) {
    // Swift：每個 unicode scalar 一個字元（ASCII 英數、-、_ 留下，其他換 _）
    const body = Array.from(s).map(ch => /^[A-Za-z0-9_-]$/.test(ch) ? ch : "_").join("");
    const tail = (NeuralGraphBuild.fnv(s) & 0xffffn).toString(16);
    return (body.length === 0 ? "_" : Array.from(body).slice(0, 60).join("")) + "-" + tail;
  },

  /** 上次跑的紀錄（graphs/<名>/stamp.json）：{ head, at: Date } */
  maxAge: 6 * 3600,

  /** 要不要重跑：沒跑過、沒產出、HEAD 變了、或超過 6 小時。last＝{head, at: Date}｜null；now＝Date */
  needsRun(head, last, hasGraph, now, maxAge = NeuralGraphBuild.maxAge) {
    if (!hasGraph || !last) return true;
    if (head != null && head !== last.head) return true;
    return (now.getTime() - last.at.getTime()) / 1000 > maxAge;
  },
};
