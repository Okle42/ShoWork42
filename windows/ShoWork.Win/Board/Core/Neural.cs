using System.Text.Json.Nodes;

namespace ShoWork;

// Mac 版 Sources/ShoWorkCore/NeuralGraph.swift、NeuralGraphBuild.swift 的轉寫（11-02 P8；GraphSource 的資料端要用）。
// 地下室 B1 機房中間浮著的 3D 神經網路（10-22 Kang：參考 Graphify「整個專案變成一張知識圖譜」）。
// 資料：各專案用 Graphify（離線、只做程式碼 AST）抽出 graph.json → 精簡成每個專案最重要的幾十個節點 → 排成 3D 位置。
// 畫面只讀這個結構，不知道 Graphify 的存在；座標是「圖譜本地座標」，半徑約 1。

public sealed record NeuralGraph
{
    public sealed record Node
    {
        public string Id { get; set; } = "";
        public string Label { get; set; } = "";          // 類別／函式名
        public string Project { get; set; } = "";        // 屬於哪個專案（樓層名）
        public string? File { get; set; }                // 原始檔（相對 repo）
        public int Community { get; set; }               // Graphify 分群
        public int Degree { get; set; }                  // 連線數（畫面決定大小）
        public double X { get; set; }
        public double Y { get; set; }
        public double Z { get; set; }
    }
    public sealed record Edge(int A, int B)
    {
        public int A { get; set; } = A;                  // nodes 的索引
        public int B { get; set; } = B;
    }
    public List<Node> Nodes { get; set; } = new();
    public List<Edge> Edges { get; set; } = new();
    public DateTime? BuiltAt { get; set; }
    public bool isEmpty => Nodes.Count == 0;

    /// 還沒有真資料時：固定種子的假圖，讓畫面有東西（Mac 測試視窗、還沒跑過 Graphify 時用；Windows 預設回空的，網頁自己決定要不要畫假圖）
    public static NeuralGraph demo(string[]? projects = null, int perProject = 40)
    {
        var ps = projects ?? new[] { "專案A", "專案B", "專案C" };
        var g = new NeuralGraph();
        ulong seed = 42;
        double rnd() { seed = unchecked(seed * 6364136223846793005 + 1442695040888963407); return (double)(seed >> 11) / (double)(1UL << 53); }
        for (int pi = 0; pi < ps.Length; pi++)
        {
            var p = ps[pi];
            int @base = g.Nodes.Count;
            double ang = (double)pi / Math.Max(ps.Length, 1) * 2 * Math.PI;
            double cx = 0.45 * Math.Cos(ang), cz = 0.45 * Math.Sin(ang);
            for (int i = 0; i < perProject; i++)
            {
                double u = rnd() * 2 * Math.PI, v = Math.Acos(2 * rnd() - 1), r = 0.15 + 0.4 * Math.Pow(rnd(), 0.6);
                int degree = i < 4 ? 12 : 1 + (int)(rnd() * 5);
                g.Nodes.Add(new Node { Id = $"{p}#{i}", Label = $"{p}-{i}", Project = p, Community = i % 5, Degree = degree,
                                       X = cx + r * Math.Sin(v) * Math.Cos(u), Y = r * Math.Cos(v), Z = cz + r * Math.Sin(v) * Math.Sin(u) });
                if (i > 0) g.Edges.Add(new Edge(@base + i, @base + (int)(rnd() * Math.Min(i, 4))));
                if (i > 6 && rnd() < 0.5) g.Edges.Add(new Edge(@base + i, @base + (int)(rnd() * i)));
            }
            if (pi > 0) g.Edges.Add(new Edge(@base, @base - perProject));
        }
        return g;
    }
}

/// 地下室神經網路的資料加工（10-22）：Graphify 的 graph.json → 每個專案精簡成一團 → 合成一張、排好 3D 座標。全部是純函式。
public static class NeuralGraphBuild
{
    public const int keepNodes = 40, keepEdges = 120;
    public const double clusterRadius = 0.35, ringRadius = 0.5, ringLift = 0.08;
    public const int iterations = 200;

    /// 系統框架／套件的 import 名（小寫比對）：連線數很高但對「這個專案在做什麼」沒意義
    public static readonly HashSet<string> frameworks = new()
    {
        "foundation", "swiftui", "scenekit", "appkit", "uikit", "testing", "xctest", "coregraphics", "coreimage",
        "corefoundation", "corevideo", "coremedia", "coreaudio", "avfoundation", "metal", "metalkit", "quartzcore",
        "combine", "dispatch", "darwin", "glibc", "simd", "os", "oslog", "observation", "cryptokit", "network",
        "webkit", "mapkit", "corelocation", "corebluetooth", "corenfc", "storekit", "spritekit", "gameplaykit",
        "realitykit", "arkit", "photos", "contacts", "eventkit", "usernotifications", "security", "localauthentication",
        "applicationservices", "carbon", "iokit", "screencapturekit", "vision", "naturallanguage", "speech",
        "react", "react-dom", "next", "vue", "express", "lodash", "os.path", "sys", "json", "re", "typing",
        "pathlib", "subprocess", "collections", "datetime", "math", "numpy", "pandas",
    };

    /// 精簡完的一團（還沒有座標）
    public sealed record Cluster(string Project, List<NeuralGraph.Node> Nodes, List<NeuralGraph.Edge> Edges);

    static string? endpoint(JsonNode? v) => v is JsonValue s && s.TryGetValue<string>(out var x) ? x : v is JsonObject o ? o["id"]?.ToString() : null;

    /// graph.json → 連線數最多的前 `keep` 個節點＋它們之間的邊（最多 `maxEdges` 條）。讀不懂回 nil
    public static Cluster? slim(string json, string project, int keep = keepNodes, int maxEdges = keepEdges)
    {
        JsonObject? root;
        try { root = JsonNode.Parse(json) as JsonObject; } catch { return null; }
        if (root?["nodes"] is not JsonArray rawNodes) return null;
        var rawLinks = (root["links"] as JsonArray) ?? (root["edges"] as JsonArray) ?? new JsonArray();
        var degree = new Dictionary<string, int>();
        var pairs = new List<(string, string)>();
        foreach (var l in rawLinks.OfType<JsonObject>())
        {
            if (endpoint(l["source"]) is not { } s || endpoint(l["target"]) is not { } t) continue;
            degree[s] = degree.GetValueOrDefault(s) + 1; degree[t] = degree.GetValueOrDefault(t) + 1;
            pairs.Add((s, t));
        }
        var cands = new List<(string id, string label, string file, int community)>();
        var seen = new HashSet<string>();
        foreach (var n in rawNodes.OfType<JsonObject>())
        {
            if (n["id"] is not JsonValue iv || !iv.TryGetValue<string>(out var id) || seen.Contains(id)) continue;
            var label = n["label"] is JsonValue lv && lv.TryGetValue<string>(out var ls) ? ls : id;
            var file = n["source_file"] is JsonValue fv && fv.TryGetValue<string>(out var fs) ? fs : "";
            if (file.Length == 0) continue;                                           // 語言內建型別、外部符號
            if (n["type"]?.ToString() == "module") continue;                          // import 進來的模組
            if (frameworks.Contains(label.ToLowerInvariant())) continue;
            seen.Add(id);
            int comm = n["community"] is JsonValue cv && cv.TryGetValue<double>(out var cd) ? (int)cd : 0;
            cands.Add((id, label, file, comm));
        }
        cands = cands.OrderByDescending(c => degree.GetValueOrDefault(c.id)).ThenBy(c => c.id, StringComparer.Ordinal).ToList();
        var kept = cands.Take(Math.Max(0, keep)).ToList();
        var index = new Dictionary<string, int>();
        for (int i = 0; i < kept.Count; i++) index[kept[i].id] = i;
        var nodes = kept.Select(r => new NeuralGraph.Node { Id = $"{project}#{r.id}", Label = r.label, Project = project, File = r.file,
                                                            Community = r.community, Degree = degree.GetValueOrDefault(r.id) }).ToList();
        // 只留兩端都在裡面的邊；無向去重、不要自己連自己；兩端度數加總高的先留
        var edgeSet = new HashSet<long>();
        var edges = new List<NeuralGraph.Edge>();
        foreach (var (s, t) in pairs)
        {
            if (!index.TryGetValue(s, out var a) || !index.TryGetValue(t, out var b) || a == b) continue;
            int lo = Math.Min(a, b), hi = Math.Max(a, b);
            if (edgeSet.Add(lo * 100_000L + hi)) edges.Add(new NeuralGraph.Edge(lo, hi));
        }
        edges = edges.OrderByDescending(e => nodes[e.A].Degree + nodes[e.B].Degree).ThenBy(e => e.A).ThenBy(e => e.B).ToList();
        if (edges.Count > maxEdges) edges = edges.Take(Math.Max(0, maxEdges)).ToList();
        return new Cluster(project, nodes, edges);
    }

    /// 多個專案合成一張：各團中心均勻排在半徑 0.5 的圓上（單數團稍微往上、雙數往下），團內力導向排成半徑約 0.35；
    /// 專案之間用各團度數最高的節點依序串一條線。最後整張縮到半徑 ≤ 1。
    public static NeuralGraph merge(List<Cluster> clusters, DateTime? builtAt = null, int iters = iterations)
    {
        var cs = clusters.Where(c => c.Nodes.Count > 0).ToList();
        var g = new NeuralGraph { BuiltAt = builtAt };
        var hubs = new List<int>();
        for (int k = 0; k < cs.Count; k++)
        {
            var c = cs[k];
            int @base = g.Nodes.Count;
            var pos = layout(c, fnv(c.Project), iters);
            (double, double, double) center;
            if (cs.Count == 1) center = (0, 0, 0);
            else
            {
                double ang = (double)k / cs.Count * 2 * Math.PI;
                center = (ringRadius * Math.Cos(ang), k % 2 == 0 ? ringLift : -ringLift, ringRadius * Math.Sin(ang));
            }
            for (int i = 0; i < c.Nodes.Count; i++)
                g.Nodes.Add(c.Nodes[i] with { X = center.Item1 + pos[i].Item1, Y = center.Item2 + pos[i].Item2, Z = center.Item3 + pos[i].Item3 });
            foreach (var e in c.Edges) g.Edges.Add(new NeuralGraph.Edge(@base + e.A, @base + e.B));
            // 度數最高（同分取前面的）＝這一團的代表
            int hub = 0;
            for (int i = 0; i < c.Nodes.Count; i++) if (c.Nodes[i].Degree > c.Nodes[hub].Degree) hub = i;
            hubs.Add(@base + hub);
        }
        for (int i = 1; i < hubs.Count; i++) g.Edges.Add(new NeuralGraph.Edge(hubs[i - 1], hubs[i]));
        normalize(g);
        return g;
    }

    /// 整張縮到半徑 ≤ 1（只縮不放；原點不動）
    public static void normalize(NeuralGraph g, double limit = 1)
    {
        double r = g.Nodes.Count == 0 ? 0 : g.Nodes.Max(n => Math.Sqrt(n.X * n.X + n.Y * n.Y + n.Z * n.Z));
        if (!(r > limit)) return;
        double s = limit / r;
        foreach (var n in g.Nodes) { n.X *= s; n.Y *= s; n.Z *= s; }
    }

    /// 團內 3D 力導向（Fruchterman–Reingold 簡化版）：固定種子、固定迭代、逐步降溫；最後縮放到最遠的點＝clusterRadius
    static (double, double, double)[] layout(Cluster c, ulong seed, int iterations)
    {
        int n = c.Nodes.Count;
        if (n <= 1) return Enumerable.Repeat((0.0, 0.0, 0.0), n).ToArray();
        ulong s = seed | 1;
        double rnd() { s = unchecked(s * 6364136223846793005 + 1442695040888963407); return (double)(s >> 11) / (double)(1UL << 53); }
        var p = Enumerable.Range(0, n).Select(_ => { double a = rnd() * 2 - 1, b = rnd() * 2 - 1, cc = rnd() * 2 - 1; return (a, b, cc); }).ToArray();
        double k = 1.0 / Math.Sqrt(n);                 // 理想間距（單位立方體內）
        double temp = 0.1;
        double cool = temp / Math.Max(iterations, 1);
        for (int it = 0; it < iterations; it++)
        {
            var d = new (double, double, double)[n];
            for (int i = 0; i < n; i++)
                for (int j = i + 1; j < n; j++)
                {
                    double dx = p[i].Item1 - p[j].Item1, dy = p[i].Item2 - p[j].Item2, dz = p[i].Item3 - p[j].Item3;
                    double dist2 = dx * dx + dy * dy + dz * dz;
                    if (dist2 < 1e-9) { dx = 0.01 * (i - j); dy = 0.01; dz = 0; dist2 = dx * dx + dy * dy; }
                    double dist = Math.Sqrt(dist2);
                    double f = k * k / dist;                             // 斥力
                    double ux = dx / dist * f, uy = dy / dist * f, uz = dz / dist * f;
                    d[i].Item1 += ux; d[i].Item2 += uy; d[i].Item3 += uz;
                    d[j].Item1 -= ux; d[j].Item2 -= uy; d[j].Item3 -= uz;
                }
            foreach (var e in c.Edges)
            {
                double dx = p[e.A].Item1 - p[e.B].Item1, dy = p[e.A].Item2 - p[e.B].Item2, dz = p[e.A].Item3 - p[e.B].Item3;
                double dist = Math.Max(Math.Sqrt(dx * dx + dy * dy + dz * dz), 1e-6);
                double f = dist * dist / k;                              // 引力
                double ux = dx / dist * f, uy = dy / dist * f, uz = dz / dist * f;
                d[e.A].Item1 -= ux; d[e.A].Item2 -= uy; d[e.A].Item3 -= uz;
                d[e.B].Item1 += ux; d[e.B].Item2 += uy; d[e.B].Item3 += uz;
            }
            for (int i = 0; i < n; i++)
            {
                // 往中心拉一點（沒有邊的孤點才不會飛走）
                d[i].Item1 -= p[i].Item1 * 0.5; d[i].Item2 -= p[i].Item2 * 0.5; d[i].Item3 -= p[i].Item3 * 0.5;
                double len = Math.Sqrt(d[i].Item1 * d[i].Item1 + d[i].Item2 * d[i].Item2 + d[i].Item3 * d[i].Item3);
                if (!(len > 1e-12)) continue;
                double step = Math.Min(len, temp) / len;
                p[i].Item1 += d[i].Item1 * step; p[i].Item2 += d[i].Item2 * step; p[i].Item3 += d[i].Item3 * step;
            }
            temp = Math.Max(temp - cool, 0.002);
        }
        // 置中＋縮放到半徑 clusterRadius
        double mx = p.Average(q => q.Item1), my = p.Average(q => q.Item2), mz = p.Average(q => q.Item3);
        p = p.Select(q => (q.Item1 - mx, q.Item2 - my, q.Item3 - mz)).ToArray();
        double rr = p.Max(q => Math.Sqrt(q.Item1 * q.Item1 + q.Item2 * q.Item2 + q.Item3 * q.Item3));
        double sc = rr > 1e-9 ? clusterRadius / rr : 0;
        return p.Select(q => (q.Item1 * sc, q.Item2 * sc, q.Item3 * sc)).ToArray();
    }

    /// 固定的字串雜湊（hashValue 每次啟動不同，不能拿來當種子）
    public static ulong fnv(string s)
    {
        ulong h = 0xcbf29ce484222325;
        foreach (var b in System.Text.Encoding.UTF8.GetBytes(s)) { h ^= b; h = unchecked(h * 0x100000001b3); }
        return h;
    }

    /// 專案名 → 資料夾名（只留英數、-、_；其他換 _；空的給 "_"）。後面接雜湊尾巴避免「a.b」「a_b」撞名
    public static string safeName(string s)
    {
        // Swift 是逐個 Unicode scalar 換：一個中文字一個 _
        var body = string.Concat(s.EnumerateRunes().Select(r => r.IsAscii && (char.IsLetterOrDigit((char)r.Value) || r.Value == '-' || r.Value == '_') ? ((char)r.Value).ToString() : "_"));
        var tail = (fnv(s) & 0xffff).ToString("x");
        return (body.Length == 0 ? "_" : body[..Math.Min(60, body.Length)]) + "-" + tail;
    }
}
