using System.Text.Json;
using System.Text.Json.Serialization;

namespace ShoWork;

// Mac 版 Sources/ShoWorkCore/Tower.swift 的逐行轉寫（11-02 P8）。函式名、常數名、註解照 Swift。
// 科技大樓剖面（10-20 Kang 拍板，規範 docs/design/office-tower/設計規範.md §3）：一層樓＝一個專案部門，樓層疊起來一起看。
//   一樓大廳（01，前台保全）→ 閒置薄層（多個沒人的專案壓成薄薄一層，只放門牌）→ 有 AI 的專案樓層（固定樓層號由下往上）→ 頂樓空中花園（RF）。
//   樓層號：第一次依最近 7 天用量排一次（第 1 名 02），之後寫進 board/tower.json 不再重排；新專案接在最後一號。
//   降樓：全部 AI 關掉後再 2 小時沒人，才降回閒置薄層（中間這 2 小時樓層留著、燈暗著）。
// 這裡只有純邏輯（可測）；讀檔、存檔、算用量在 Board/Source/TowerSource.cs（Mac：ShoWorkAgent/TowerSource.swift）。

/// 大樓尺寸（公尺）。10-20 第 2 棒 UI/UX 優化（docs/design/office-tower/UIUX優化規劃.md §3.1）：
/// 模組 16×7×3.6 → 12×5.6×2.9、角色放大到 1.6 倍（坐姿頭頂佔層高 ≥ 50%，ACCAI 那種比例）；閒置薄層只留 1 層 0.9。
public static class TowerSpec
{
    public const double lobbyHeight = 4.4;          // 一樓挑高（10-22 加深後段咖啡館：3.6 時預設 12° 俯角看後段的人頭會被上一層樓板切掉）
    public const double floorHeight = 2.9;          // 專案樓層（樓板 0.25＋淨高 2.65）
    public const double idleHeight = 0.9;           // 閒置薄層
    public const double roofHeight = 2.4;           // 頂樓（樓板＋棚架 2.1）
    public const double width = 12.0, depth = 9.8;  // 模組寬、深（10-22 Kang：5.6 太淺 ⇒ 8.4 ⇒ 再深一點 9.8；一樓後段做咖啡館休息區）
    public const double front = 2.8;                // 模組前緣（玻璃面）z：加深只往後長，前面的家具、城市座標不動
    public static double back => front - depth;     // 模組後緣 z
    public static double backInner => back + 0.15;  // 後牆內側
    public const double slab = 0.25;                // 樓板厚
    public const int platesPerIdle = 8;             // （舊）一層薄層幾塊門牌；10-20 起薄層只畫一塊大門牌，名字在左側索引列
    public const int maxIdleLayers = 1;             // 薄層只留 1 層（全部閒置專案收在同一層）
    public static readonly TimeSpan demoteAfter = TimeSpan.FromHours(2);   // 全部 AI 關掉後多久降樓
    public const int firstNumber = 2;               // 專案樓層從 02 開始（01 是大廳）

    // 角色比例（純數字，畫面 OfficeBuilder 用同一組；測試量「坐姿頭頂／層高」）
    public const double kuboScale = 1.6;            // 方塊 Kubo 放大倍數
    public const double seatTop = 0.56;             // 椅面頂（離地坪）
    public const double kuboSeatedHead = 0.62;      // 坐著時頭頂離椅面（縮放前）
    /// 坐姿頭頂離地坪幾公尺
    public static double seatedHead => seatTop + kuboSeatedHead * kuboScale;
    /// 坐姿頭頂／層高（≥ 0.5 才像 ACCAI；舊版 0.37）
    public static double seatedHeadRatio => seatedHead / floorHeight;

    /// 樓層號顯示：兩位數（02、11）
    public static string label(int n) => n.ToString("00");
}

public enum TowerFloorKind { lobby, idle, project, roof }

/// 閒置薄層上的一塊門牌
public sealed record IdlePlate
{
    public string Name { get; set; } = "";          // 專案名；溢出那塊是「+N」
    public string FloorNo { get; set; } = "";       // 固定樓層號（溢出那塊是空字串）
    public string? Accent { get; set; }             // 上次的識別色（沒有＝畫 FN-4 暖灰）
    public int Overflow { get; set; }               // >0 ＝這塊是「+N」
    public IdlePlate() { }
    public IdlePlate(string name, string floorNo, string? accent = null, int overflow = 0) { Name = name; FloorNo = floorNo; Accent = accent; Overflow = overflow; }
}

/// 大樓的一層（由下往上排）
public sealed record TowerFloor
{
    public TowerFloorKind Kind { get; set; }
    public string Id { get; set; } = "";            // lobby、idle-0、idle-1…、p:<專案名小寫>、roof（搬家動畫用 id 對樓層）
    public string FloorNo { get; set; } = "";       // 01、05、RF；薄層是空字串
    public string? Project { get; set; }            // 專案樓層的專案名（顯示用寫法）
    public int? Number { get; set; }                // 專案樓層的固定號碼
    public bool Active { get; set; }                // 現在有 AI（false＝2 小時緩衝中，燈暗著）
    public int Seats { get; set; }                  // 桌子數＝實際 AI 數（排隊中的訊息不算）
    public List<IdlePlate> Plates { get; set; } = new();   // 薄層的門牌
    public double Y { get; set; }                   // 樓板底面高度
    public double Height { get; set; }

    public TowerFloor() { }
    public TowerFloor(TowerFloorKind kind, string id, string floorNo, string? project = null, int? number = null,
                      bool active = false, int seats = 0, List<IdlePlate>? plates = null, double y = 0, double height = 0)
    {
        Kind = kind; Id = id; FloorNo = floorNo; Project = project; Number = number;
        Active = active; Seats = seats; Plates = plates ?? new(); Y = y; Height = height;
    }

    public static string projectId(string name) => "p:" + name.ToLowerInvariant();
}

/// 樓層號名冊（存 board/tower.json）。鍵一律用專案名小寫（APFS 不分大小寫，跟 OfficeDepartments 同規則）
public sealed class TowerRegistry
{
    public Dictionary<string, int> Numbers { get; set; } = new();      // 專案 → 固定樓層號（2 起）
    public Dictionary<string, string> Names { get; set; } = new();     // 專案 → 顯示寫法
    public Dictionary<string, DateTime> LastSeen { get; set; } = new();   // 專案 → 最後一次「有 AI」的時間（只在有人進出時更新，不是每次刷新）
    public List<string> Active { get; set; } = new();                  // 上次看到有 AI 的專案（排序過，判斷進出用）
    public DateTime? RankedAt { get; set; }                            // 第一次排名的時間
    public Dictionary<string, double> RankedBy { get; set; } = new();  // 第一次排名用的 7 天用量（MB；除錯用）

    [JsonIgnore] public int nextNumber => Math.Max(TowerSpec.firstNumber, (Numbers.Count == 0 ? TowerSpec.firstNumber - 1 : Numbers.Values.Max()) + 1);
    public int? number(string project) => Numbers.TryGetValue(project.ToLowerInvariant(), out var n) ? n : null;

    /// 沒有號碼的專案發號碼。名冊是空的（第一次）＝全部依 7 天用量排名（多的在前、一樣多照名稱）；
    /// 之後只把新專案接在最後（新的之間也照用量排），**不重排已經有號碼的**。`usage` 只在有新專案時才叫（鍵＝小寫）。
    /// 回傳有沒有發新號碼
    public bool assign(IEnumerable<string> projects, Func<Dictionary<string, double>> usage, DateTime now)
    {
        var seen = new HashSet<string>();
        var fresh = projects.Where(p =>
        {
            var k = p.ToLowerInvariant();
            return !Numbers.ContainsKey(k) && seen.Add(k);
        }).ToList();
        if (fresh.Count == 0) return false;
        var u = usage();
        bool first = Numbers.Count == 0;
        var ordered = fresh.ToList();
        ordered.Sort((a, b) =>
        {
            double ua = u.GetValueOrDefault(a.ToLowerInvariant()), ub = u.GetValueOrDefault(b.ToLowerInvariant());
            if (ua != ub) return ua > ub ? -1 : 1;
            return ResidentProjects.compare(a, b);
        });
        int n = nextNumber;
        foreach (var p in ordered)
        {
            var k = p.ToLowerInvariant();
            Numbers[k] = n; Names[k] = p; n += 1;
            if (first && u.TryGetValue(k, out var x)) RankedBy[k] = Math.Round(x * 10, MidpointRounding.AwayFromZero) / 10;
        }
        if (first) RankedAt = now;
        return true;
    }

    /// 記錄誰有 AI：剛進來、剛離開的都把 lastSeen 設成現在（離開那一刻就是「最後一次有人」）。
    /// 上次存檔時還有人、這次沒人（例如 app 關掉重開）也算剛離開。回傳有沒有變
    public bool markActive(IEnumerable<string> projects, DateTime now)
    {
        var now0 = projects.Select(p => p.ToLowerInvariant()).ToHashSet();
        var was = Active.ToHashSet();
        if (now0.SetEquals(was)) return false;
        var diff = new HashSet<string>(now0); diff.SymmetricExceptWith(was);
        foreach (var k in diff) LastSeen[k] = now;
        Active = now0.OrderBy(x => x, StringComparer.Ordinal).ToList();
        return true;
    }

    /// 這個專案還在樓上嗎：現在有 AI，或最後一次有人在 `demoteAfter` 之內
    public bool isUp(string project, DateTime now, TimeSpan? demoteAfter = null)
    {
        var k = project.ToLowerInvariant();
        if (Active.Contains(k)) return true;
        if (!LastSeen.TryGetValue(k, out var t)) return false;
        return now - t < (demoteAfter ?? TowerSpec.demoteAfter);
    }

    /// 什麼時候會降樓（給畫面排一次性的重算；沒有在緩衝中的就 nil）
    public DateTime? nextDemotion(DateTime now, TimeSpan? demoteAfter = null)
    {
        var d = demoteAfter ?? TowerSpec.demoteAfter;
        var xs = LastSeen.Where(kv => !Active.Contains(kv.Key) && now - kv.Value < d).Select(kv => kv.Value + d).ToList();
        return xs.Count == 0 ? null : xs.Min();
    }

    static readonly JsonSerializerOptions Opt = new() { PropertyNamingPolicy = JsonNamingPolicy.CamelCase, WriteIndented = true };
    /// 讀 board/tower.json（Mac 格式：日期是 ISO 8601 字串）；壞掉當空的
    public static TowerRegistry decode(string? json)
    {
        if (string.IsNullOrWhiteSpace(json)) return new();
        try { return JsonSerializer.Deserialize<TowerRegistry>(json, Opt) ?? new(); } catch { return new(); }
    }
    public string encoded() => JsonSerializer.Serialize(this, Opt);
}

/// 一次搬家：某個專案樓層出現、離開、或換了位置（第 3 棒播「飄出→升降→插回」用）
public sealed record TowerMove(string Project, string FloorId, int? FromIndex, int? ToIndex, double? FromY, double? ToY);

public sealed class TowerPlan
{
    public List<TowerFloor> Floors { get; set; } = new();          // 由下往上
    public TowerPlan() { }
    public TowerPlan(List<TowerFloor> floors) { Floors = floors; }

    public double totalHeight => Floors.Count == 0 ? 0 : Floors[^1].Y + Floors[^1].Height;
    public List<TowerFloor> projectFloors => Floors.Where(f => f.Kind == TowerFloorKind.project).ToList();
    public List<IdlePlate> idlePlates => Floors.Where(f => f.Kind == TowerFloorKind.idle).SelectMany(f => f.Plates).ToList();
    public TowerFloor? floor(string id) => Floors.FirstOrDefault(f => f.Id == id);
    public TowerFloor? floorOfProject(string project) => floor(TowerFloor.projectId(project));

    /// 組大樓。`departments`＝OfficeDepartments.build 的結果（常駐＋臨時，isActive＝有 AI）；`cards` 只拿來算桌子數；
    /// `registry` 會被更新（發新號碼、記錄進出），呼叫端看回傳的 `dirty` 決定要不要存檔；
    /// `accents`＝專案（小寫）→ 上次的識別色（薄層門牌色條用）。
    public static (TowerPlan plan, bool dirty) build(List<OfficeDepartment> departments, IEnumerable<BoardCard> cards, TowerRegistry registry,
                                                    Func<Dictionary<string, double>> usage, IReadOnlyDictionary<string, string>? accents, DateTime now)
    {
        accents ??= new Dictionary<string, string>();
        bool dirty = registry.assign(departments.Select(d => d.Name), usage, now);
        dirty = registry.markActive(departments.Where(d => d.IsActive).Select(d => d.Name), now) || dirty;
        // 10-20 第 4 棒：臨時部門（不在常駐名冊、只因為有 AI 才出現）AI 一關就從 departments 消失，原本樓層會立刻不見、
        // 沒有 2 小時緩衝 ⇒ 名冊裡還在緩衝中的補回來（燈暗著）；滿 2 小時就自然消失（臨時部門不進薄層）
        var deps = departments.ToList();
        var listed = deps.Select(d => d.Name.ToLowerInvariant()).ToHashSet();
        foreach (var k in registry.LastSeen.Keys.OrderBy(x => x, StringComparer.Ordinal))
            if (!listed.Contains(k) && registry.isUp(k, now))
                deps.Add(new OfficeDepartment(registry.Names.GetValueOrDefault(k) ?? k, isResident: false, isActive: false));
        var seats = new Dictionary<string, int>();
        foreach (var c in cards) if (!c.Id.Contains('#')) { var k = c.Project.ToLowerInvariant(); seats[k] = seats.GetValueOrDefault(k) + 1; }

        var byNumber = deps.ToList();
        StableSort(byNumber, (a, b) =>
        {
            int na = registry.number(a.Name) ?? int.MaxValue, nb = registry.number(b.Name) ?? int.MaxValue;
            return na != nb ? na.CompareTo(nb) : ResidentProjects.compare(a.Name, b.Name);
        });
        var up = byNumber.Where(d => d.IsActive || registry.isUp(d.Name, now)).ToList();
        var idle = byNumber.Where(d => !up.Any(u => u.Name == d.Name)).ToList();

        var floors = new List<TowerFloor>();
        double y = 0.0;
        void push(TowerFloor f, double h) { f.Y = y; f.Height = h; floors.Add(f); y += h; }
        push(new TowerFloor(TowerFloorKind.lobby, "lobby", "01"), TowerSpec.lobbyHeight);
        // 10-20 UI/UX 優化：閒置薄層只留 1 層、全部閒置專案都放在這層（3D 只畫一塊大門牌，名字在左側索引列）
        var idlePlates = idle.Select(d => new IdlePlate(d.Name, registry.number(d.Name) is { } n ? TowerSpec.label(n) : "", accents.GetValueOrDefault(d.Name.ToLowerInvariant()))).ToList();
        if (idlePlates.Count > 0)
            push(new TowerFloor(TowerFloorKind.idle, "idle-0", "", plates: idlePlates), TowerSpec.idleHeight);
        foreach (var d in up)
        {
            var n = registry.number(d.Name);
            push(new TowerFloor(TowerFloorKind.project, TowerFloor.projectId(d.Name), n is { } x ? TowerSpec.label(x) : "",
                                project: d.Name, number: n, active: d.IsActive, seats: seats.GetValueOrDefault(d.Name.ToLowerInvariant())),
                 TowerSpec.floorHeight);
        }
        push(new TowerFloor(TowerFloorKind.roof, "roof", "RF"), TowerSpec.roofHeight);
        return (new TowerPlan(floors), dirty);
    }

    /// 門牌分層：一層 perLayer 塊、最多 maxLayers 層；超過時最後一塊改成「+N」（N＝沒畫出來的數量）。
    /// 10-20 起大樓只用 1 層薄層（build 不再呼叫這個）；留著給舊版門牌條排版用
    public static List<List<IdlePlate>> idleLayers(List<IdlePlate> plates, int perLayer = TowerSpec.platesPerIdle, int maxLayers = 3)
    {
        if (plates.Count == 0) return new();
        int cap = perLayer * maxLayers;
        var list = plates.ToList();
        if (list.Count > cap)
        {
            int hidden = list.Count - (cap - 1);
            list = list.Take(cap - 1).Append(new IdlePlate("+" + hidden, "", overflow: hidden)).ToList();
        }
        var out_ = new List<List<IdlePlate>>();
        for (int i = 0; i < list.Count; i += perLayer) out_.Add(list.Skip(i).Take(perLayer).ToList());
        return out_;
    }

    /// 兩個版本之間的搬家：專案樓層出現／離開／換位置（index 是 floors 裡的位置）。
    /// 只因為下面多一層或少一層而被推上推下的（相對順序沒變）不算搬家，那是「讓位」
    public static List<TowerMove> moves(TowerPlan old, TowerPlan @new)
    {
        var a = old.projectFloors.Select(f => f.Id).ToList();
        var b = @new.projectFloors.Select(f => f.Id).ToList();
        var common = a.Where(b.Contains).ToList();
        var commonNew = b.Where(a.Contains).ToList();
        var out_ = new List<TowerMove>();
        foreach (var f in @new.projectFloors)
        {
            int oi = old.Floors.FindIndex(x => x.Id == f.Id), ni = @new.Floors.FindIndex(x => x.Id == f.Id);
            bool reordered = oi >= 0 && common.IndexOf(f.Id) != commonNew.IndexOf(f.Id);
            if (oi < 0 || reordered)
                out_.Add(new TowerMove(f.Project ?? f.Id, f.Id, oi < 0 ? null : oi, ni < 0 ? null : ni, oi < 0 ? null : old.Floors[oi].Y, f.Y));
        }
        foreach (var f in old.projectFloors)
            if (@new.floor(f.Id) == null)
            {
                int oi = old.Floors.FindIndex(x => x.Id == f.Id);
                out_.Add(new TowerMove(f.Project ?? f.Id, f.Id, oi < 0 ? null : oi, null, f.Y, null));
            }
        return out_;
    }

    /// Swift 的 sorted(by:) 對同分的元素不保證順序；這裡用穩定排序（同分保持原本順序），比較函式都有最後的名稱比對，實際不會同分
    internal static void StableSort<T>(List<T> list, Comparison<T> cmp)
    {
        var idx = list.Select((x, i) => (x, i)).ToList();
        idx.Sort((p, q) => { int c = cmp(p.x, q.x); return c != 0 ? c : p.i.CompareTo(q.i); });
        for (int i = 0; i < list.Count; i++) list[i] = idx[i].x;
    }
}

// MARK: - 最近 7 天用量（排樓層號用）

/// 便宜的估法（10-20 取捨）：`~/.claude/projects/<slug>/*.jsonl` 裡**最近 7 天內有改過**的對話紀錄，加總檔案大小（MB）。
/// slug＝啟動 cwd 換字元（`SessionRecord.ProjectSlug`）；一個資料夾歸給「slug 前綴最長」的專案（ProjectA-w1 有自己的部門就歸它，
/// 沒有就歸 ProjectA）。不讀檔內容、不開 git，只 stat。
/// 不準的地方：①檔案大小是整個對話累計，不是 7 天內的量（長壽 session 會偏高）；②在家目錄啟動再 cd 進專案的 session 算不到；
/// ③讀圖的行很大，圖多的專案偏高。只用來排一次樓層號，夠用；要精準得掃 token（TokenTally 要讀整個檔，太貴）。
public static class ProjectUsage
{
    public static readonly TimeSpan window = TimeSpan.FromDays(7);

    /// `projects`：專案名 → 它的資料夾路徑（可以多個，例如常駐的 ~/github-repos/X 與臨時部門卡片的 cwd）
    public static Dictionary<string, double> scan(string projectsDir, IReadOnlyDictionary<string, List<string>> projects, DateTime now, TimeSpan? window = null)
    {
        var w = window ?? ProjectUsage.window;
        // slug → 專案（小寫）；比對時取最長前綴
        var slugs = new List<(string slug, string key)>();
        foreach (var (name, paths) in projects)
            foreach (var p in paths) slugs.Add((new SessionRecord { Cwd = p }.ProjectSlug, name.ToLowerInvariant()));
        slugs = slugs.OrderByDescending(s => s.slug.Length).ToList();
        var out_ = new Dictionary<string, double>();
        IEnumerable<string> dirs;
        try { dirs = Directory.EnumerateDirectories(projectsDir).Select(Path.GetFileName).OfType<string>().ToList(); } catch { return out_; }
        foreach (var dir in dirs)
        {
            // Windows 的資料夾名不分大小寫（C--Users-… 從 Git Bash 進來可能是 c--）
            var hit = slugs.FirstOrDefault(s => string.Equals(dir, s.slug, StringComparison.OrdinalIgnoreCase)
                                                || dir.StartsWith(s.slug + "-", StringComparison.OrdinalIgnoreCase));
            if (hit.slug == null) continue;
            var path = Path.Combine(projectsDir, dir);
            IEnumerable<string> files;
            try { files = Directory.EnumerateFiles(path, "*.jsonl").ToList(); } catch { continue; }
            foreach (var f in files)
            {
                try
                {
                    var fi = new FileInfo(f);
                    if (now - fi.LastWriteTimeUtc > w) continue;
                    out_[hit.key] = out_.GetValueOrDefault(hit.key) + fi.Length / 1_048_576.0;
                }
                catch { }
            }
        }
        return out_;
    }
}
