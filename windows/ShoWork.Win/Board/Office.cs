using System.Text.Json;
using System.Text.Json.Serialization;

namespace ShoWork;

// 3D 辦公大樓（W6）的資料：看板卡片 → 一棟科技大樓剖面（Mac 版 Sources/ShoWorkCore/Tower.swift、TowerTheme.swift 的精簡移植）。
//   一樓大廳（01）→ 閒置薄層（沒人的專案只剩門牌）→ 有 AI 的專案一層一樓（固定樓層號，由下往上）→ 頂樓空中花園（RF）。
//   畫面在 Board\Web\（WebView2＋three.js），這裡只組 JSON，用 PostWebMessageAsJson 推過去；頁面只畫、不讀檔。
// 跟 Mac 不同的地方（照實記）：
//   • 樓層號第一次不依 7 天用量排名，照「第一次看到」的順序發號（之後一樣固定、新專案接在最後）。
//   • 主題不問 AI：專案名關鍵字（同 Mac 的主題庫）命中就用，沒命中就照專案名雜湊穩定挑一個（Mac 會落在「通用辦公」）。
//     有 board\themes\<專案>.json（Mac 格式）就用它的 theme。
//   • 英文名：Windows 還沒有 board\names；session 名或標題是「Alex-任務」就用 Alex，否則照 sessionId 從同一個名字池穩定挑。
// 這個檔不碰 WinForms（測試專案直接連）。

/// 樓層主題（Mac TowerTheme 的主題庫：id、中文名、識別色、判斷關鍵字）
public sealed record OfficeTheme(string Id, string Title, string Accent, string[] Keywords);

public static class OfficeThemes
{
    public static readonly OfficeTheme[] All =
    {
        new("monitor", "監控中心", "#5B8DB8", new[] { "monitor", "dashboard", "daemon", "statusline", "fan", "wifi", "監控", "看板", "守門", "戰情", "terminal", "終端機" }),
        new("app_studio", "App 開發室", "#4E9C8F", new[] { "swiftui", "xcode", "ios", "iphone", "ipad", "android", "kotlin", "testflight", "app", "上架", "送審", "nfc" }),
        new("library", "研究書房", "#9C6B4E", new[] { "research", "survey", "paper", "docs", "研究", "報告", "調查", "文獻" }),
        new("print_shop", "3D 列印工坊", "#C98B3C", new[] { "stl", "3mf", "fusion", "blender", "cad", "bambu", "print", "列印", "切片", "公仔", "外殼", "模型", "cnc" }),
        new("call_room", "秘書電話室", "#8C7BB5", new[] { "tablet", "hotline", "gmail", "calendar", "secretary", "秘書", "平板", "電話", "訊息", "行事曆" }),
        new("trading_desk", "交易室", "#3F8F5A", new[] { "stock", "ticker", "backtest", "trade", "trading", "股票", "回測", "交易", "期貨", "投資" }),
        new("media_studio", "攝影棚", "#B5525A", new[] { "video", "ffmpeg", "film", "shot", "tts", "影片", "剪輯", "分鏡", "配音", "字幕" }),
        new("design_studio", "設計工作室", "#D08A6E", new[] { "design", "figma", "hig", "css", "font", "logo", "設計", "配色", "品牌", "名片", "排版" }),
        new("legal_room", "法務室", "#4A5A7A", new[] { "nda", "contract", "legal", "terms", "privacy", "合約", "條款", "授權", "簽署" }),
        new("ledger_room", "財務帳房", "#A88C3E", new[] { "invoice", "ledger", "budget", "accountant", "finance", "帳", "財務", "記帳", "報價", "發票", "預算" }),
        new("game_lab", "遊戲工作室", "#7A5FA8", new[] { "game", "unity", "godot", "sprite", "poker", "遊戲", "關卡", "撲克" }),
        new("hw_lab", "硬體實驗室", "#C2703A", new[] { "bluetooth", "ble", "usb", "esp32", "arduino", "firmware", "speaker", "audio", "藍牙", "音訊", "喇叭", "電路", "韌體" }),
        new("marketing", "行銷室", "#C56B86", new[] { "instagram", "ig", "seo", "landing", "campaign", "promo", "ads", "行銷", "貼文", "廣告", "文案", "官網" }),
        new("dispatch_room", "調度中心", "#3E8FA8", new[] { "dispatch", "ride", "flight", "route", "map", "派車", "派單", "航班", "行程", "車隊" }),
        new("drafting_room", "建築製圖室", "#6E8A6A", new[] { "dxf", "dwg", "floorplan", "room", "建築", "室內", "水電", "平面圖", "裝潢" }),
        new("general", "通用辦公", "#8F8B85", Array.Empty<string>()),
    };

    public static OfficeTheme General => All[^1];
    public static OfficeTheme? ById(string? id) => All.FirstOrDefault(t => t.Id == id);

    /// 專案名拆詞：DemoLine42 → Demo Line 42、Demo_App2 → Demo App 2（同 Mac WorkSignature.splitName）
    public static string SplitName(string s)
    {
        var sb = new System.Text.StringBuilder();
        char? prev = null;
        foreach (var c in s)
        {
            if (c is '_' or '-' or '.') { sb.Append(' '); prev = null; continue; }
            if (prev is { } p && ((char.IsUpper(c) && char.IsLower(p)) || (char.IsDigit(c) && char.IsLetter(p)) || (char.IsLetter(c) && char.IsDigit(p)))) sb.Append(' ');
            sb.Append(c);
            prev = c;
        }
        return sb.ToString();
    }

    /// 一段文字命中某主題幾次：純英數字的關鍵字照「詞」比，其他（中文）照子字串比（同 Mac 規則）
    public static int Hits(OfficeTheme t, string text)
    {
        var lower = text.ToLowerInvariant();
        var words = System.Text.RegularExpressions.Regex.Split(lower, "[^a-z0-9]+");
        int n = 0;
        foreach (var k in t.Keywords)
        {
            if (k.All(char.IsAsciiLetterOrDigit)) n += words.Count(w => w == k);
            else for (int i = lower.IndexOf(k, StringComparison.Ordinal); i >= 0; i = lower.IndexOf(k, i + k.Length, StringComparison.Ordinal)) n++;
        }
        return n;
    }

    /// 挑主題：先看快取（decor，Mac 格式的 theme id），再看專案名關鍵字，最後照專案名雜湊（同一個名字永遠同一個主題）
    public static OfficeTheme Pick(string project, string? decor = null)
    {
        if (ById(decor) is { } d) return d;
        var name = SplitName(project);
        OfficeTheme? best = null;
        int bestScore = 0;
        foreach (var t in All)
        {
            int s = Hits(t, name);
            if (s > bestScore) { best = t; bestScore = s; }
        }
        if (best != null) return best;
        var pool = All.Length - 1;                                  // 不含「通用辦公」
        return All[(int)(Fnv(project.ToLowerInvariant()) % (uint)pool)];
    }

    /// FNV-1a 32 位元（.NET 的 string.GetHashCode 每次開程式都不一樣，不能拿來「穩定」挑）
    public static uint Fnv(string s)
    {
        uint h = 2166136261;
        foreach (var b in System.Text.Encoding.UTF8.GetBytes(s)) { h ^= b; h *= 16777619; }
        return h;
    }
}

/// 角色頭上的英文名＋任務（Mac Nickname.swift：卡片標題＝「英文名-任務」）
public static class OfficeNames
{
    public static readonly string[] Pool = { "Alex", "Bella", "Chris", "Dora", "Ethan", "Fiona", "Gavin", "Hana", "Ivan", "Jade", "Kyle", "Luna", "Milo",
                                             "Nina", "Oscar", "Penny", "Quinn", "Ruby", "Sam", "Tina", "Umar", "Vera", "Wade", "Xena", "Yuki", "Zack" };

    /// 「Alex」或「Alex-任務」⇒ (Alex, 任務或 null)；不像英文名（大寫字母開頭、英數、≤12 字；you-88 這種自動名不算）就 null
    public static (string Name, string? Task)? Parse(string? s)
    {
        if (string.IsNullOrWhiteSpace(s)) return null;
        var parts = s.Trim().Split('-', 2);
        var n = parts[0];
        if (n.Length is 0 or > 12 || !char.IsAsciiLetterUpper(n[0]) || !n.All(char.IsAsciiLetterOrDigit)) return null;
        var task = parts.Length > 1 && parts[1].Trim().Length > 0 ? parts[1].Trim() : null;
        return (n, task);
    }

    /// 任務字串：一行、太長截斷（同 Mac Nicknames.cleanDoing，24 字）
    public static string Clean(string s)
    {
        var t = string.Join(" ", s.Split('\n', '\r')).Trim();
        return Board.Length(t) > 24 ? Board.Prefix(t, 24) + "⋯" : t;
    }

    /// 每張卡（排隊卡除外）→ (英文名, 任務)。有名字的先佔，沒有的照 sessionId 雜湊從名字池挑沒人用的（26 個用完加數字）
    public static Dictionary<string, (string Name, string Task)> Assign(IEnumerable<BoardCard> cards)
    {
        var list = cards.Where(c => !c.IsQueued).ToList();
        var out_ = new Dictionary<string, (string, string)>();
        var taken = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        var pending = new List<BoardCard>();
        foreach (var c in list)
        {
            // 標題只認「名字-任務」（只有一個英文字的標題，例如 README，不當名字）
            var named = Parse(c.Name) ?? (Parse(c.Title) is { Task: not null } t ? t : null);
            if (named is { } n && taken.Add(n.Name))
            {
                out_[c.Id] = (n.Name, Clean(n.Task ?? TaskOf(c)));
            }
            else pending.Add(c);
        }
        foreach (var c in pending)
        {
            int start = (int)(OfficeThemes.Fnv(c.SessionId.Length > 0 ? c.SessionId : c.Id) % (uint)Pool.Length);
            string name = Pool[start];
            for (int round = 1, i = 0; ; i++)
            {
                if (i == Pool.Length) { i = 0; round++; }
                var cand = Pool[(start + i) % Pool.Length] + (round == 1 ? "" : round.ToString());
                if (taken.Add(cand)) { name = cand; break; }
            }
            out_[c.Id] = (name, Clean(TaskOf(c)));
        }
        return out_;
    }

    /// 標題是「Alex-任務」取任務那段，否則整個標題
    static string TaskOf(BoardCard c) => Parse(c.Title) is { Task: { } t } ? t : c.Title;
}

/// 樓層號名冊（存 board\tower.json；鍵一律用專案名小寫）。同 Mac TowerRegistry，少了用量排名
public sealed class TowerRegistry
{
    public const int FirstNumber = 2;                             // 01 是大廳
    public static readonly TimeSpan DemoteAfter = TimeSpan.FromHours(2);

    public Dictionary<string, int> Numbers { get; set; } = new();
    public Dictionary<string, string> Names { get; set; } = new();
    public Dictionary<string, DateTime> LastSeen { get; set; } = new();
    public List<string> Active { get; set; } = new();

    public int NextNumber => Math.Max(FirstNumber, (Numbers.Count == 0 ? FirstNumber - 1 : Numbers.Values.Max()) + 1);
    public int? Number(string project) => Numbers.TryGetValue(project.ToLowerInvariant(), out var n) ? n : null;

    /// 沒號碼的專案依序發號（已經有號碼的不重排）；回傳有沒有變
    public bool Assign(IEnumerable<string> projects)
    {
        bool dirty = false;
        foreach (var p in projects)
        {
            var k = p.ToLowerInvariant();
            if (Numbers.ContainsKey(k)) continue;
            Numbers[k] = NextNumber;
            Names[k] = p;
            dirty = true;
        }
        return dirty;
    }

    /// 誰有 AI：剛進來、剛離開的都把 LastSeen 設成現在（離開那一刻＝最後一次有人）
    public bool MarkActive(IEnumerable<string> projects, DateTime now)
    {
        var cur = projects.Select(p => p.ToLowerInvariant()).ToHashSet();
        var was = Active.ToHashSet();
        if (cur.SetEquals(was)) return false;
        foreach (var k in cur.Union(was).Where(k => !(cur.Contains(k) && was.Contains(k)))) LastSeen[k] = now;
        Active = cur.OrderBy(x => x, StringComparer.Ordinal).ToList();
        return true;
    }

    /// 還在樓上：現在有 AI，或最後一次有人在 2 小時內（燈暗著的緩衝）
    public bool IsUp(string project, DateTime now)
    {
        var k = project.ToLowerInvariant();
        if (Active.Contains(k)) return true;
        return LastSeen.TryGetValue(k, out var t) && now - t < DemoteAfter;
    }

    static readonly JsonSerializerOptions Opt = new() { PropertyNamingPolicy = JsonNamingPolicy.CamelCase, WriteIndented = true };
    public static TowerRegistry Decode(string? json)
    {
        if (string.IsNullOrWhiteSpace(json)) return new();
        try { return JsonSerializer.Deserialize<TowerRegistry>(json, Opt) ?? new(); } catch { return new(); }
    }
    public string Encode() => JsonSerializer.Serialize(this, Opt);
}

// MARK: 推給頁面的 JSON（欄位 camelCase；頁面 Board\Web\office.js 照這個格式畫）

public sealed record OfficePerson(string Id, string Name, string Task, string Mood, string? Accessory, bool Captain, string Reason, string Title);

public sealed record OfficePlate(string Name, string FloorNo);

public sealed record OfficeFloor
{
    public string Kind { get; init; } = "";                 // lobby｜idle｜project｜roof
    public string Id { get; init; } = "";                   // lobby、idle-0、p:<專案小寫>、roof
    public string FloorNo { get; init; } = "";              // 01、05、RF；薄層空字串
    public string? Project { get; init; }
    public int? Number { get; init; }
    public bool Active { get; init; }                       // 現在有 AI（false＝2 小時緩衝，燈暗著）
    public int Seats { get; init; }                         // 桌子數＝實際 AI 數（排隊中的訊息不算）
    public int Queued { get; init; }
    public string? Theme { get; init; }
    public string? ThemeTitle { get; init; }
    public string? Accent { get; init; }
    public List<OfficePerson> People { get; init; } = new();
    public List<OfficePlate> Plates { get; init; } = new();
}

public sealed record OfficeCounts(int Working, int Waiting, int Finished, int Stuck);

public sealed record OfficeSnapshot
{
    public string Type { get; init; } = "office";
    public int Version { get; init; } = 1;
    public List<OfficeFloor> Floors { get; init; } = new();
    public OfficeCounts Counts { get; init; } = new(0, 0, 0, 0);
    public Dictionary<string, string> Colors { get; init; } = new();    // mood → #RRGGBB（光暈設定的顏色）
    public bool ReduceMotion { get; init; }
}

public static class OfficeScene
{
    public static string MoodId(Mood m) => m switch
    {
        Mood.Working => "working", Mood.Waiting => "waiting", Mood.Finished => "finished",
        Mood.Stuck => "stuck", Mood.Idle => "idle", _ => "asleep",
    };

    static string? AccessoryId(Accessory? a) => a switch { Accessory.Crown => "crown", Accessory.Headset => "headset", Accessory.Glasses => "glasses", _ => null };

    /// 組大樓。`registry` 會被更新（發號碼、記進出），回傳的 Dirty＝要不要存檔；`decor`＝專案小寫 → 主題 id（可省略）
    public static (OfficeSnapshot Snapshot, bool Dirty) Build(IEnumerable<BoardCard> cards, TowerRegistry registry, DateTime now,
                                                             IReadOnlyDictionary<string, string>? decor = null,
                                                             IReadOnlyDictionary<string, string>? colors = null, bool reduceMotion = false)
    {
        var list = cards.ToList();
        var islands = Islands.Build(list);
        var cmp = StringComparer.OrdinalIgnoreCase;
        // 專案依「第一次看到」的順序（看板順序）發號；有 AI＝島上有人
        var projects = new List<string>();
        foreach (var c in list) if (!projects.Contains(c.Project, cmp)) projects.Add(c.Project);
        bool dirty = registry.Assign(projects);
        var active = islands.Where(i => i.People.Count > 0).Select(i => i.Project).ToList();
        dirty = registry.MarkActive(active, now) || dirty;
        var names = OfficeNames.Assign(list);

        var byKey = islands.ToDictionary(i => i.Project, cmp);
        var known = registry.Numbers.Keys.Select(k => registry.Names.GetValueOrDefault(k, k)).ToList();
        var ordered = known.OrderBy(p => registry.Number(p) ?? int.MaxValue).ThenBy(p => p, StringComparer.Ordinal).ToList();
        var up = ordered.Where(p => registry.IsUp(p, now)).ToList();       // MarkActive 已經把有 AI 的記進 Active
        var idle = ordered.Where(p => !up.Contains(p, cmp)).ToList();

        var floors = new List<OfficeFloor> { new() { Kind = "lobby", Id = "lobby", FloorNo = "01" } };
        if (idle.Count > 0)
            floors.Add(new OfficeFloor
            {
                Kind = "idle", Id = "idle-0",
                Plates = idle.Select(p => new OfficePlate(p, registry.Number(p) is { } n ? Label(n) : "")).ToList(),
            });
        foreach (var p in up)
        {
            byKey.TryGetValue(p, out var isl);
            var people = isl?.People ?? new();
            var theme = OfficeThemes.Pick(p, decor?.GetValueOrDefault(p.ToLowerInvariant()));
            var n = registry.Number(p);
            floors.Add(new OfficeFloor
            {
                Kind = "project", Id = "p:" + p.ToLowerInvariant(), FloorNo = n is { } x ? Label(x) : "", Project = isl?.Project ?? p, Number = n,
                Active = people.Count > 0, Seats = people.Count, Queued = isl?.Queued ?? 0,
                Theme = theme.Id, ThemeTitle = theme.Title, Accent = theme.Accent,
                People = people.Select(i =>
                {
                    var (nm, task) = names.GetValueOrDefault(i.Id, ("AI", i.Card.Title));
                    return new OfficePerson(i.Id, nm, task, MoodId(i.Mood), AccessoryId(i.Accessory), i.Card.Captain, i.Card.Reason, i.Card.Title);
                }).ToList(),
            });
        }
        floors.Add(new OfficeFloor { Kind = "roof", Id = "roof", FloorNo = "RF" });

        var all = islands.SelectMany(i => i.People).ToList();
        var counts = new OfficeCounts(all.Count(p => p.Mood == Mood.Working), all.Count(p => p.Mood == Mood.Waiting),
                                      all.Count(p => p.Mood == Mood.Finished), all.Count(p => p.Mood == Mood.Stuck));
        var snap = new OfficeSnapshot
        {
            Floors = floors, Counts = counts, ReduceMotion = reduceMotion,
            Colors = colors?.ToDictionary(kv => kv.Key, kv => kv.Value) ?? new(),
        };
        return (snap, dirty);
    }

    /// 樓層號顯示：兩位數
    public static string Label(int n) => n.ToString("00");

    static readonly JsonSerializerOptions Opt = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
        Encoder = System.Text.Encodings.Web.JavaScriptEncoder.UnsafeRelaxedJsonEscaping,
    };

    /// PostWebMessageAsJson 的內容（也拿來比對「資料有沒有變」）
    public static string Json(OfficeSnapshot s) => JsonSerializer.Serialize(s, Opt);
}
