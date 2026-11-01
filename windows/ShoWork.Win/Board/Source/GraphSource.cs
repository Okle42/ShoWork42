namespace ShoWork;

// Mac 版 Sources/ShoWorkAgent/GraphSource.swift 的資料端（11-02 P8）：大樓上每個專案樓層 → Graphify 的 graph.json → 精簡合併成一張 NeuralGraph。
// 跟 Mac 不同（照實記）：
//   · 找不到 graphify（PATH 上的 graphify.exe、~/.local/bin/graphify.exe）就回空的圖（Mac 回 NeuralGraph.demo()；網頁自己決定空的時候畫什麼）。
//   · 有 graphify 也**不在 Windows 上跑它**：Mac 是包在「禁止網路」的 sandbox-exec 裡跑（10-22 隊長 Chris 審查：確保程式碼不會對外送），
//     Windows 沒有對應的一行沙盒 ⇒ 只讀已經產出的 %LOCALAPPDATA%\ShoWork42\graphs\<專案>\graphify-out\graph.json（例如自己手動跑過、或從 Mac 帶過來）。
//   · 互動圖譜 graph.html、3D 星雲頁、輸出大小上限（GraphPrune）都沒轉寫（跟產生圖譜綁在一起）。
public static class GraphPaths
{
    public static string dir => Path.Combine(Wire.SupportDir, "graphs");
    public static string @out(string project) => Path.Combine(dir, NeuralGraphBuild.safeName(project));
    public static string graph(string project) => Path.Combine(@out(project), "graphify-out", "graph.json");
}

public sealed class GraphSource
{
    /// 同一組專案多久內不重讀
    public static readonly TimeSpan throttle = TimeSpan.FromMinutes(10);
    string? lastKey;
    DateTime? lastAt;
    NeuralGraph graph = new();
    public NeuralGraph current => graph;

    /// graphify 在不在（只找，不裝、不跑）
    public static string? graphify()
    {
        var names = OperatingSystem.IsWindows() ? new[] { "graphify.exe", "graphify.cmd" } : new[] { "graphify" };
        var dirs = (Environment.GetEnvironmentVariable("PATH") ?? "").Split(Path.PathSeparator, StringSplitOptions.RemoveEmptyEntries)
                   .Append(Path.Combine(BoardReader.DefaultHome, ".local", "bin"));
        foreach (var d in dirs) foreach (var n in names) { var p = Path.Combine(d, n); if (File.Exists(p)) return p; }
        return null;
    }

    /// 看板每次刷新叫（便宜）：專案名單 10 分鐘內沒變就直接回上次的
    public NeuralGraph consider(TowerPlan tower, DateTime now)
    {
        var names = tower.projectFloors.Select(f => f.Project).OfType<string>().OrderBy(x => x, StringComparer.Ordinal).ToList();
        var key = string.Join("\n", names);
        if (key == lastKey && lastAt is { } t && now - t < throttle) return graph;
        lastKey = key; lastAt = now;
        graph = build(names) ?? new NeuralGraph();
        return graph;
    }

    /// 讀所有專案的 graph.json 合成一張；沒有 graphify、或一個能讀的都沒有就回 nil
    public static NeuralGraph? build(List<string> projects)
    {
        if (graphify() == null) return null;
        var clusters = new List<NeuralGraphBuild.Cluster>();
        DateTime? newest = null;
        foreach (var p in projects)
        {
            var path = GraphPaths.graph(p);
            try
            {
                if (!File.Exists(path)) continue;
                if (NeuralGraphBuild.slim(File.ReadAllText(path), p) is not { } c || c.Nodes.Count == 0) continue;
                clusters.Add(c);
                var m = File.GetLastWriteTimeUtc(path);
                if (newest == null || m > newest) newest = m;
            }
            catch { }
        }
        return clusters.Count == 0 ? null : NeuralGraphBuild.merge(clusters, newest);
    }
}
