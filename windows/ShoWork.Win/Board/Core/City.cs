using System.Globalization;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;

namespace ShoWork;

// Mac 版 Sources/ShoWorkCore/City.swift 的逐行轉寫（11-02 P8）。
// 外部空間城市（10-21 Kang 拍板）：把這台電腦的外部資源畫成科技大樓四周的城市。
//   硬碟＝貨櫃堆場、雲端＝飛艇、ssh 伺服器＝對街分公司、防火牆＝城牆＋城門、cool42＝電廠、GitHub＝港口。
// 這裡只有純邏輯（可測）：資料結構、各種輸出的解析、容量→貨櫃、警示判定。
// 收集在 Board/Source/CitySource.cs（Windows：DriveInfo、雲端同步資料夾、~/.ssh/config、netsh、git refs）。
// 原則：只寫確定的事實（讀不到總額度就不寫總額度），不瞎掰數字、不寫「狀態未知」；帳號（雲端資料夾名裡的信箱）不顯示。
// Windows 多的解析（Mac 沒有）放在檔尾 CityParseWin：netsh 防火牆、netstat 埠、雲端資料夾名。

// MARK: - 資料

/// 一個磁碟（內建碟、外接碟；拔掉的外接碟只剩名字）
public sealed record CityDisk
{
    public string Name { get; set; } = "";
    public bool IsInternal { get; set; }
    public bool Mounted { get; set; } = true;
    public long Total { get; set; }             // bytes；拔掉的＝0
    public long Available { get; set; }         // 你能用的（Mac 內建碟＝「重要用途可用」；Windows＝使用者可用 AvailableFreeSpace）
    // 10-21 懸停卡用的細節（不影響 3D 造型）
    public long AvailablePlain { get; set; }    // 檔案系統回報的「現在空著的」（Windows＝TotalFreeSpace，不含配額）
    public string? Format { get; set; }         // 檔案系統（APFS、NTFS、FAT32⋯）
    public string? MountPath { get; set; }
    public DateTime? LastSeen { get; set; }     // 拔掉的外接碟：最後一次看到插著的時間
    public CityDisk() { }
    public CityDisk(string name, bool isInternal, bool mounted = true, long total = 0, long available = 0, long availablePlain = 0,
                    string? format = null, string? mountPath = null, DateTime? lastSeen = null)
    {
        Name = name; IsInternal = isInternal; Mounted = mounted; Total = total; Available = available;
        AvailablePlain = availablePlain; Format = format; MountPath = mountPath; LastSeen = lastSeen;
    }
    public string id => $"city:disk:{Name}";
    /// 已用比例（0…1）；拿不到容量＝nil
    public double? used => !Mounted || Total <= 0 ? null : Math.Min(1, Math.Max(0, (double)(Total - Available) / Total));
    public bool alert => (used ?? 0) >= CityRules.fullAt;
}

/// iCloud 同步狀態（10-21：`brctl quota`／`brctl status` 讀得到的事實；總額度讀不到就不寫）。
/// Windows：iCloud for Windows 沒有 brctl ⇒ 一律 nil（只知道資料夾在）
public sealed record CloudSync
{
    public long? Remaining { get; set; }        // 帳號剩餘額度（bytes）
    public string? DriveState { get; set; }     // 主容器的 client 狀態：idle／needs-sync／blocked-⋯
    public DateTime? LastSync { get; set; }     // 主容器上次同步
    public bool CaughtUp { get; set; }          // 主容器 caught-up（跟伺服器一致）
    public int Pending { get; set; }            // 其他還在用的 App 容器裡「待同步」的個數
    public int Blocked { get; set; }            // 其他還在用的容器裡被擋住的個數
    public bool? DesktopDocs { get; set; }      // 「桌面與文件」同步開著嗎
    /// 剩下多少算「額度快滿」：總額度讀不到 ⇒ 用絕對值 5 GB
    public const long lowQuota = 5_000_000_000;
    /// 主容器不是 idle 而且超過 1 小時沒同步成功＝卡住（剛存檔時短暫 needs-sync 是正常的）
    public bool stuck(DateTime now)
    {
        if (DriveState is not { } st || st == "idle") return false;
        if (LastSync is not { } t) return true;
        return (now - t).TotalSeconds > 3600;
    }
    public bool alert(DateTime now) => stuck(now) || Blocked > 0 || (Remaining is { } r && r < lowQuota);
}

/// 雲端（飛艇）：只放誠實拿得到的狀態
public sealed record CityCloud
{
    public string Name { get; set; } = "";
    public bool IsICloud { get; set; }
    public CloudSync? Sync { get; set; }        // iCloud：brctl 讀到的；nil＝讀不到（只知道資料夾在）
    public DateTime? CheckedAt { get; set; }
    public CityCloud() { }
    public CityCloud(string name, bool isICloud = false, CloudSync? sync = null, DateTime? checkedAt = null) { Name = name; IsICloud = isICloud; Sync = sync; CheckedAt = checkedAt; }
    public string id => $"city:cloud:{Name}";
    public bool alert => Sync?.alert(CheckedAt ?? DateTime.UtcNow) ?? false;
    /// 狀態燈：拿得到同步資訊＝綠（警示＝紅）；只知道連著＝灰
    public bool known => Sync != null;
}

/// ssh 伺服器（對街分公司）
public sealed record CityServer
{
    public string Alias { get; set; } = "";
    public bool? Online { get; set; }           // nil＝還沒連過
    public DateTime? CheckedAt { get; set; }
    public DateTime? LastOnline { get; set; }   // 上次連上的時間
    public int? LatencyMs { get; set; }         // 上次連上花多久（TCP 握手）
    public string? HostName { get; set; }
    public int? Port { get; set; }
    public CityServer() { }
    public CityServer(string alias, bool? online = null, DateTime? checkedAt = null, DateTime? lastOnline = null, int? latencyMs = null, string? hostName = null, int? port = null)
    { Alias = alias; Online = online; CheckedAt = checkedAt; LastOnline = lastOnline; LatencyMs = latencyMs; HostName = hostName; Port = port; }
    public string id => $"city:server:{Alias}";
    public bool alert => Online == false;
}

/// 一個在聽 TCP 的埠
public sealed record ListenPort
{
    public int Port { get; set; }
    public string Process { get; set; } = "";
    public bool External { get; set; }          // 綁 *、0.0.0.0、:: 或區網位址（別台電腦連得到）
    public string? KnownOpen { get; set; }      // 已知沒有認證的（敞開的紅門）：名稱
    public ListenPort() { }
    public ListenPort(int port, string process, bool external, string? knownOpen = null) { Port = port; Process = process; External = external; KnownOpen = knownOpen; }
    public bool openRed => External && KnownOpen != null;
}

/// 防火牆（城牆＋城門）
public sealed record CityFirewall
{
    public bool? Enabled { get; set; }          // nil＝讀不到
    public List<ListenPort> Ports { get; set; } = new();
    public DateTime? CheckedAt { get; set; }
    public CityFirewall() { }
    public CityFirewall(bool? enabled, List<ListenPort>? ports = null, DateTime? checkedAt = null) { Enabled = enabled; Ports = ports ?? new(); CheckedAt = checkedAt; }
    public List<ListenPort> gates => Ports.Where(p => p.External).ToList();
    public List<ListenPort> doors => Ports.Where(p => !p.External).ToList();
    public List<ListenPort> openRed => Ports.Where(p => p.openRed).ToList();
    /// 保全卡片的一句城牆摘要
    public string summary
    {
        get
        {
            if (CheckedAt == null) return "城牆：還沒檢查";
            var s = Enabled == null ? "城牆：防火牆狀態讀不到" : Enabled.Value ? "城牆：防火牆開著" : "城牆：防火牆關閉（有缺口）";
            s += $"，對外城門 {gates.Count} 個、城內的門 {doors.Count} 扇";
            if (openRed.Count > 0) s += "，敞開的紅門 " + string.Join("、", openRed.Select(p => $"{p.Port}（{p.KnownOpen}）"));
            return s;
        }
    }
}

/// 電廠＝AI 額度（10-22 Kang 拍板：5 小時額度＝電力，用完公司停電；7 天額度＝油槽）。資料來自 statusLine 存的 rate_limits.json
public sealed record CityGrid
{
    public enum Stage { Normal, Dim, Flicker, Blackout }       // <80%、80–95%、95–100%、100%（重置前）
    public double? FiveUsed { get; set; }       // 0–100；nil＝讀不到
    public DateTime? FiveReset { get; set; }
    public double? SevenUsed { get; set; }
    public DateTime? SevenReset { get; set; }
    [MacName("stage")] public Stage StageValue { get; set; } = Stage.Normal;
    /// 7 天重置倒數（分鐘；算的那一刻）：油槽名牌寫「還有多久重置」用
    public int? SevenLeftMin { get; set; }
    public bool known => FiveUsed != null;
    /// 剩多少（0–100）
    public double? fiveLeft => FiveUsed is { } u ? Math.Max(0, Math.Min(100, 100 - u)) : null;
    public double? sevenLeft => SevenUsed is { } u ? Math.Max(0, Math.Min(100, 100 - u)) : null;
    public bool alert => StageValue >= Stage.Flicker;
    /// 燈光乘數（燈、補光、發光材質）
    public double lightScale => StageValue switch { Stage.Normal => 1, Stage.Dim => 0.6, Stage.Flicker => 0.35, _ => 0 };
}

/// cool42（頂樓冷卻水塔；10-22 起電廠改代表額度）。Windows 沒有 cool42 ⇒ 一律空的（溫度讀不到）
public sealed record CityPower
{
    public double? Temp { get; set; }
    public double? CpuAvg { get; set; }
    public string? Level { get; set; }          // ok／warm／hot／critical
    public bool Stale { get; set; }             // 狀態檔超過 2 分鐘沒更新
    public CityPower() { }
    public CityPower(double? temp, double? cpuAvg = null, string? level = null, bool stale = false) { Temp = temp; CpuAvg = cpuAvg; Level = level; Stale = stale; }
    public bool known => Temp != null && !Stale;
    public bool alert => known && (Level == "hot" || Level == "critical");
}

/// GitHub 港口：剛 push（出港的貨船）或 fetch／pull（進港的貨船，11-01 Kang：pull 也該有船進來）的 repo
public sealed record CityShip
{
    public string Repo { get; set; } = "";
    public DateTime At { get; set; }
    public bool Inbound { get; set; }
    public CityShip() { }
    public CityShip(string repo, DateTime at, bool inbound = false) { Repo = repo; At = at; Inbound = inbound; }
    public string id => $"{Repo}@{(long)MacMirror.Seconds(At)}{(Inbound ? "<" : "")}";
}

public sealed record CityState
{
    public List<CityDisk> Disks { get; set; } = new();
    public List<CityCloud> Clouds { get; set; } = new();
    public List<CityServer> Servers { get; set; } = new();
    public CityFirewall Firewall { get; set; } = new();
    public CityPower Power { get; set; } = new();
    public CityGrid Grid { get; set; } = new();
    public List<CityShip> Ships { get; set; } = new();
    public int Repos { get; set; }                         // 港口看著幾個 repo
    public List<CityShip> Recent { get; set; } = new();    // 最近有新遠端 ref 的 repo（新到舊，最多 5 個；時間＝ref 檔的 mtime）
    public bool Demo { get; set; }

    /// 深拷貝（Swift 是值型別，C# 要自己拷）
    public CityState Copy() => this with
    {
        Disks = Disks.Select(d => d with { }).ToList(), Clouds = Clouds.Select(c => c with { Sync = c.Sync == null ? null : c.Sync with { } }).ToList(),
        Servers = Servers.Select(s => s with { }).ToList(), Firewall = Firewall with { Ports = Firewall.Ports.Select(p => p with { }).ToList() },
        Power = Power with { }, Grid = Grid with { }, Ships = Ships.Select(s => s with { }).ToList(), Recent = Recent.Select(s => s with { }).ToList(),
    };

    /// 內容一樣（Swift 的 ==）：比 Mirror JSON
    public bool Same(CityState o) => MacMirror.Json(MacMirror.Encode(this)) == MacMirror.Json(MacMirror.Encode(o));

    /// 設備警示（頂部「需要你」列的一類）：≥90% 的碟、離線的伺服器、防火牆關、敞開的紅門、cool42 hot 以上
    public List<CityAlert> alerts
    {
        get
        {
            var a = new List<CityAlert>();
            foreach (var d in Disks.Where(d => d.alert)) a.Add(new CityAlert(d.id, $"{CityText.diskName(d)} 已用 {(int)Math.Round((d.used ?? 0) * 100, MidpointRounding.AwayFromZero)}%"));
            foreach (var s in Servers.Where(s => s.alert)) a.Add(new CityAlert(s.id, $"{s.Alias} 離線"));
            if (Firewall.Enabled == false) a.Add(new CityAlert("city:wall", "防火牆關閉"));
            foreach (var p in Firewall.openRed) a.Add(new CityAlert($"city:gate:{p.Port}", $"{p.Port} {p.KnownOpen} 對外敞開"));
            if (Power.alert) a.Add(new CityAlert("city:cooler", $"cool42 {Power.Level ?? ""}"));
            if (Grid.alert) a.Add(new CityAlert("city:power", CityText.gridAlert(Grid)));
            foreach (var c in Clouds.Where(c => c.alert)) a.Add(new CityAlert(c.id, CityText.cloud(c)));
            return a;
        }
    }
}

public sealed record CityAlert(string Id, string Text);

// MARK: - 規則

public static class CityRules
{
    /// 用到幾 % 算滿（貨櫃堆到圍籬外、紅色警示燈）
    public const double fullAt = 0.9;
    /// 一個堆場：一層 12 格、最多 4 層
    public const int perLevel = 12, maxLevels = 4;

    /// 已用比例 → (貨櫃數, 層數, 圍籬外的貨櫃數)。層數＝已用比例×4 無條件進位；有用到就至少 1 個
    public static (int count, int levels, int overflow) containers(double? used)
    {
        if (used is not { } u || u <= 0) return (0, 0, 0);
        int levels = Math.Min(maxLevels, Math.Max(1, (int)Math.Ceiling(u * maxLevels - 1e-9)));
        // 貨櫃數照比例，但至少要堆到第 levels 層（最上層至少 1 個）
        int c = Math.Min(perLevel * maxLevels, Math.Max((levels - 1) * perLevel + 1, (int)Math.Round(u * perLevel * maxLevels, MidpointRounding.AwayFromZero)));
        int over = u >= fullAt ? Math.Min(6, 2 + (int)Math.Floor((u - fullAt) * 40 + 1e-9)) : 0;
        return (c, levels, over);
    }

    /// 冷卻塔的煙：0…5 團（50°C 以下沒煙）；拿不到溫度＝0
    public static int smoke(CityPower p)
    {
        if (!p.known || p.Temp is not { } t) return 0;
        return Math.Min(5, Math.Max(0, (tempStep(t) - 40) / 10));      // 50°C 一團、每 10°C 多一團（跟名牌同一格）
    }

    /// 溫度變化要不要重畫：等級變了、或顯示的溫度（10°C 一格）換格、而且跟上次差 6°C 以上才算
    public static bool powerChanged(CityPower a, CityPower b)
    {
        if (a.Level != b.Level || a.Stale != b.Stale || (a.Temp == null) != (b.Temp == null)) return true;
        if (a.Temp is { } x && b.Temp is { } y && tempStep(x) != tempStep(y) && Math.Abs(x - y) >= 6) return true;
        return false;
    }

    /// 溫度顯示到 10°C 一格
    public static int tempStep(double t) => (int)Math.Round(t / 10, MidpointRounding.AwayFromZero) * 10;

    /// 額度 → 電網（重置時間已過＝新的一輪，當成 0%）
    public static CityGrid grid(RateLimits? r0, DateTime now)
    {
        if (r0?.Current(now) is not { } r) return new CityGrid();
        var g = new CityGrid { FiveUsed = r.FiveHour?.Used, FiveReset = r.FiveHour?.ResetsAt, SevenUsed = r.SevenDay?.Used, SevenReset = r.SevenDay?.ResetsAt };
        double u = Math.Max(r.FiveHour?.Used ?? 0, r.SevenDay?.Used ?? 0);      // 7 天用完也一樣停電
        g.StageValue = u >= 100 ? CityGrid.Stage.Blackout : u >= 95 ? CityGrid.Stage.Flicker : u >= 80 ? CityGrid.Stage.Dim : CityGrid.Stage.Normal;
        g.SevenLeftMin = g.SevenReset is { } sr ? Math.Max(0, (int)((sr - now).TotalSeconds / 60)) : null;
        return g;
    }
    /// 名牌上的「已用 %」：跟視窗右上角同一個算法——四捨五入到整數
    public static int? pct(double? used) => used is { } u ? (int)Math.Round(u, MidpointRounding.AwayFromZero) : null;
    /// 要不要換：階段變了、已用 % 變了（1% 一格）、重置時間（分鐘）變了才算
    public static bool gridChanged(CityGrid a, CityGrid b)
    {
        static long? m(DateTime? d) => d is { } x ? (long)(MacMirror.Seconds(x) / 60) : null;
        return a.StageValue != b.StageValue || pct(a.FiveUsed) != pct(b.FiveUsed) || pct(a.SevenUsed) != pct(b.SevenUsed)
               || m(a.FiveReset) != m(b.FiveReset) || m(a.SevenReset) != m(b.SevenReset)
               || CityText.countdown(a.SevenLeftMin) != CityText.countdown(b.SevenLeftMin);
    }

    /// 已知沒有認證的埠（敞開的紅門）
    public static readonly Dictionary<int, string> knownOpen = new() { [9888] = "audio-bridge" };
}

// MARK: - 文字

public static class CityText
{
    static string F1(double x) => x.ToString("0.0", CultureInfo.InvariantCulture);
    public static string bytes(long b)
    {
        double g = b / 1e9;
        if (g >= 1000) return F1(g / 1000) + "T";
        if (g >= 10) return (long)Math.Round(g, MidpointRounding.AwayFromZero) + "G";
        return F1(g) + "G";
    }
    public static string diskName(CityDisk d) => d.IsInternal ? "內建碟" : d.Name;

    /// 名牌：內建碟寫剩多少、外接碟寫已用 %、拔掉的寫已拔除；≥90% 加 ⚠
    public static string disk(CityDisk d)
    {
        if (!d.Mounted) return $"{diskName(d)}・已拔除";
        if (d.used is not { } u) return $"{diskName(d)}・容量讀不到";
        // 10-21：有用到但不到 0.5%（空隨身碟）原本寫「0%」卻有一個貨櫃 ⇒ 寫「<1%」
        var p = u > 0 && u < 0.005 ? "<1%" : $"{(int)Math.Round(u * 100, MidpointRounding.AwayFromZero)}%";
        var body = d.IsInternal ? $"{diskName(d)}・剩 {bytes(d.Available)}" : $"{diskName(d)}・{p}";
        return d.alert ? body + (d.IsInternal ? $"（{(int)Math.Round(u * 100, MidpointRounding.AwayFromZero)}%）" : "") + " ⚠" : body;
    }
    /// 雲端名牌：iCloud 讀得到＝剩多少（卡住／快滿加 ⚠）；其他雲端只寫確定的事實「已連線」（資料夾掛著）
    public static string cloud(CityCloud c)
    {
        if (!c.IsICloud || c.Sync is not { } s) return $"{(c.IsICloud ? "iCloud" : c.Name)}・已連線";
        var now = c.CheckedAt ?? DateTime.UtcNow;
        if (s.stuck(now)) return "iCloud・同步卡住 ⚠";
        if (s.Blocked > 0) return $"iCloud・{s.Blocked} 項被擋 ⚠";
        if (s.Remaining is not { } r) return "iCloud・已連線";
        return $"iCloud・剩 {bytes(r)}" + (r < CloudSync.lowQuota ? " ⚠" : "");
    }
    public static string server(CityServer s) => $"{s.Alias}・" + (s.Online == null ? "檢查中" : s.Online.Value ? "在線" : "離線 ⚠");
    public static string wall(CityFirewall f)
    {
        if (f.CheckedAt == null) return "城牆・還沒檢查";
        if (f.Enabled is not { } e) return "城牆・防火牆狀態未知";
        return e ? "城牆・防火牆開啟" : "城牆・防火牆關閉 ⚠";
    }
    public static string gate(ListenPort p) => $"{p.Port} {p.KnownOpen ?? p.Process}・敞開 ⚠";
    public static string power(CityPower p)
    {
        if (p.Temp is not { } t) return "冷卻水塔・cool42 狀態未知";
        if (p.Stale) return "冷卻水塔・cool42 沒在更新";
        var s = $"冷卻水塔・約 {CityRules.tempStep(t)}°C";
        return p.alert ? s + $" {p.Level ?? ""} ⚠" : s;
    }
    /// 時間：今天＝HH:mm、不是今天＝M/d HH:mm
    public static string clock(DateTime d, DateTime now, TimeZoneInfo? tz = null)
    {
        var z = tz ?? TimeZoneInfo.Local;
        var ld = TimeZoneInfo.ConvertTimeFromUtc(DateTime.SpecifyKind(d, DateTimeKind.Utc), z);
        var ln = TimeZoneInfo.ConvertTimeFromUtc(DateTime.SpecifyKind(now, DateTimeKind.Utc), z);
        return ld.Date == ln.Date ? ld.ToString("HH:mm", CultureInfo.InvariantCulture) : ld.ToString("M/d HH:mm", CultureInfo.InvariantCulture);
    }
    /// 電廠名牌：5 小時已用多少（跟右上角同一個數字）＋幾點重置；停電＝幾點復電
    public static string grid(CityGrid g, DateTime now, TimeZoneInfo? tz = null)
    {
        if (CityRules.pct(g.FiveUsed) is not { } used) return "電廠・額度讀不到";
        var at = g.FiveReset is { } fr ? clock(fr, now, tz) : null;
        if (g.StageValue == CityGrid.Stage.Blackout)
        {
            bool fiveOut = (g.FiveUsed ?? 0) >= 100;
            var back = fiveOut ? at : g.SevenReset is { } sr ? clock(sr, now, tz) : null;
            return "停電・額度用完" + (back != null ? $"，{back} 復電" : "") + " ⚠";
        }
        var s = $"電廠・5 小時已用 {used}%" + (at != null ? $"（{at} 重置）" : "");
        return g.alert ? s + " ⚠" : s;
    }
    /// 倒數字：超過 1 天「N 天 H 小時」、1 天內「H 小時 M 分」（10 分鐘一格）、1 小時內「M 分」
    public static string? countdown(int? min)
    {
        if (min is not { } m) return null;
        if (m >= 1440) return $"{m / 1440} 天 {m % 1440 / 60} 小時";
        if (m >= 60) return $"{m / 60} 小時 {m % 60 / 10 * 10} 分";
        return $"{Math.Max(m, 0)} 分";
    }
    /// 油槽名牌：7 天已用多少（跟右上角同一個數字）＋還有多久重置（10-22 Kang：旁邊要寫倒數）
    public static string fuel(CityGrid g)
    {
        if (g.sevenLeft is not { } l || CityRules.pct(g.SevenUsed) is not { } used) return "油槽・7 天額度讀不到";
        return $"油槽・7 天已用 {used}%" + (countdown(g.SevenLeftMin) is { } cd ? $"（{cd}後重置）" : "") + (l <= 5 ? " ⚠" : "");
    }
    /// 頂部「需要你」列的一句
    public static string gridAlert(CityGrid g) => g.StageValue == CityGrid.Stage.Blackout ? "停電：AI 額度用完" : "電力吃緊：額度剩不到 5%";
}

// MARK: - 解析

public static class CityParse
{
    /// `socketfilterfw --getglobalstate`：「Firewall is enabled. (State = 1)」／「disabled. (State = 0)」／State = 2（擋全部）
    public static bool? firewall(string s)
    {
        var m = Regex.Match(s, @"State\s*=\s*(\d)");
        if (m.Success) return m.Groups[1].Value != "0";
        var l = s.ToLowerInvariant();
        if (l.Contains("disabled")) return false;
        if (l.Contains("enabled")) return true;
        return null;
    }

    static bool loopback(string host) => host == "localhost" || host.StartsWith("127.") || host == "::1" || host == "::ffff:127.0.0.1";

    /// `lsof -nP -iTCP -sTCP:LISTEN` → 每個埠一筆（同一埠 IPv4／IPv6 合併；只要有一個綁在非本機位址就算對外）
    public static List<ListenPort> listen(string s, IReadOnlyDictionary<int, string>? knownOpen = null)
    {
        var ko = knownOpen ?? CityRules.knownOpen;
        var byPort = new Dictionary<int, ListenPort>();
        foreach (var line in s.Split('\n'))
        {
            var cols = line.Split(' ', StringSplitOptions.RemoveEmptyEntries);
            int li = Array.LastIndexOf(cols, "(LISTEN)");
            if (cols.Length < 9 || cols[0] == "COMMAND" || li <= 0) continue;
            var name = cols[li - 1];
            int colon = name.LastIndexOf(':');
            if (colon < 0 || !int.TryParse(name[(colon + 1)..], out var port)) continue;
            var host = name[..colon];
            if (host.StartsWith('[') && host.EndsWith(']')) host = host[1..^1];
            var proc = cols[0].Replace("\\x20", " ");
            if (byPort.TryGetValue(port, out var p)) { if (!loopback(host)) p.External = true; }
            else byPort[port] = new ListenPort(port, proc, !loopback(host), ko.GetValueOrDefault(port));
        }
        return byPort.Values.OrderBy(p => p.Port).ToList();
    }

    /// ~/.ssh/config 的 Host（不含萬用字元 *、?、!）＋各自的 HostName／Port（同名重複只留第一個）
    public sealed record SSHHost(string Alias, string HostName, int Port)
    {
        public string HostName { get; set; } = HostName;
        public int Port { get; set; } = Port;
    }
    public static List<SSHHost> sshHosts(string s)
    {
        var out_ = new List<SSHHost>();
        var current = new List<int>();          // 目前這個 Host 區塊對到 out 裡的哪幾筆
        var seen = new HashSet<string>();
        foreach (var raw in s.Split('\n', '\r'))
        {
            var line = raw.Trim(' ', '\t');
            if (line.Length == 0 || line.StartsWith('#')) continue;
            // 「Key Value」或「Key=Value」
            int sep = line.IndexOfAny(new[] { ' ', '\t', '=' });
            if (sep <= 0) continue;
            var key = line[..sep].ToLowerInvariant();
            var value = line[(sep + 1)..].Trim(' ', '\t', '=', '"');
            switch (key)
            {
                case "host":
                    current = new();
                    foreach (var a in value.Split(new[] { ' ', '\t' }, StringSplitOptions.RemoveEmptyEntries))
                    {
                        if (a.Contains('*') || a.Contains('?') || a.StartsWith('!') || !seen.Add(a)) continue;
                        out_.Add(new SSHHost(a, a, 22)); current.Add(out_.Count - 1);
                    }
                    break;
                case "match":
                    current = new();
                    break;
                case "hostname":
                    foreach (var i in current) out_[i].HostName = value;
                    break;
                case "port":
                    if (int.TryParse(value, out var p)) foreach (var i in current) out_[i].Port = p;
                    break;
            }
        }
        return out_;
    }

    /// cool42 /var/run/cool42/state.json：controlTemp、cpuAvg、level、time（超過 2 分鐘沒更新＝stale）
    public static CityPower cool42(string? d, DateTime now)
    {
        try
        {
            if (d == null || JsonNode.Parse(d) is not JsonObject o) return new CityPower();
            double? D(string k) => o[k] is JsonValue v && v.TryGetValue<double>(out var x) ? x : null;
            var p = new CityPower(D("controlTemp"), D("cpuAvg"), o["level"] is JsonValue lv && lv.TryGetValue<string>(out var ls) ? ls : null);
            if (o["time"] is JsonValue tv && tv.TryGetValue<string>(out var ts) && DateTime.TryParse(ts, CultureInfo.InvariantCulture, DateTimeStyles.AdjustToUniversal, out var at))
                p.Stale = (now - at).TotalSeconds > 120;
            return p;
        }
        catch { return new CityPower(); }
    }

    /// ~/Library/CloudStorage 底下的資料夾名 → 顯示名（拿掉「-帳號」：GoogleDrive-a@b.com → Google Drive）
    public static string cloudName(string folder)
    {
        var @base = folder.Split('-', 2)[0];
        switch (@base.ToLowerInvariant())
        {
            case "googledrive": return "Google Drive";
            case "onedrive": return "OneDrive";
            case "dropbox": return "Dropbox";
            case "box": return "Box";
            default:
                // 駝峰拆字：SynologyDrive → Synology Drive
                var s = new System.Text.StringBuilder();
                foreach (var ch in @base) { if (char.IsUpper(ch) && s.Length > 0 && s[^1] != ' ') s.Append(' '); s.Append(ch); }
                return s.ToString();
        }
    }

    /// 外接碟的可用空間（10-21 實測：FAT32 隨身碟的「重要用途可用」回 0）：重要用途可用讀不到或是 0、但一般可用 > 0 ⇒ 用一般可用
    public static long available(long? important, long? plain)
    {
        if (important is { } i && i > 0) return i;
        return Math.Max(plain ?? 0, important ?? 0);
    }

    /// 曾經看過的外接碟名稱：現在插著的接在後面（不重複、不改舊順序）
    public static List<string> rememberDisks(List<string> known, IEnumerable<string> mounted)
    {
        var out_ = known.ToList();
        foreach (var m in mounted) if (!out_.Contains(m)) out_.Add(m);
        return out_;
    }

    /// 港口：遠端 ref 變了是 push 還是 fetch／pull：fetch 一定會改寫 .git/FETCH_HEAD，push 不會。
    /// FETCH_HEAD 跟遠端 ref 在幾秒內一起變＝進港；FETCH_HEAD 比較舊（或沒有）＝出港
    public static bool isInbound(DateTime refAt, DateTime? fetchHeadAt) => fetchHeadAt is { } f && f >= refAt.AddSeconds(-5);

    /// repo → 最新的遠端 ref 時間；跟上次比變新的 ⇒ 出港。第一次（上次是空的）只當基準，不出港
    public static List<string> departures(IReadOnlyDictionary<string, DateTime> old, IReadOnlyDictionary<string, DateTime> @new)
    {
        if (old.Count == 0) return new();
        return @new.Where(kv => old.TryGetValue(kv.Key, out var o) && kv.Value > o).Select(kv => kv.Key).OrderBy(x => x, StringComparer.Ordinal).ToList();
    }
}

// MARK: - Windows 才有的解析（Mac 用 socketfilterfw／lsof／~/Library/CloudStorage）

public static class CityParseWin
{
    /// `netsh advfirewall show allprofiles state`：每個設定檔一段「網域設定檔設定:／Domain Profile Settings:」＋「狀態  開啟／State  ON」。
    /// 回傳 (設定檔名, 開著嗎)；語系不同（中文／英文）都認。讀不到回空的
    public static List<(string profile, bool on)> netshProfiles(string s)
    {
        var out_ = new List<(string, bool)>();
        string? cur = null;
        foreach (var raw in s.Split('\n'))
        {
            var line = raw.Trim();
            if (line.Length == 0 || line.StartsWith("---")) continue;
            if (line.EndsWith(':') || line.EndsWith('：')) { cur = line.TrimEnd(':', '：').Trim(); continue; }
            var cols = Regex.Split(line, @"\s{2,}|\t+");
            if (cols.Length < 2 || cur == null) continue;
            var k = cols[0].Trim().ToLowerInvariant();
            if (k is not ("state" or "狀態" or "状态")) continue;
            var v = cols[^1].Trim().ToLowerInvariant();
            bool? on = v is "on" or "開啟" or "开启" or "啟用" ? true : v is "off" or "關閉" or "关闭" or "停用" ? false : null;
            if (on != null) out_.Add((cur, on.Value));
            cur = null;
        }
        return out_;
    }

    /// 防火牆開著嗎：三個設定檔（網域／私人／公用）都開＝開；任一關＝關（有缺口，同 Mac「防火牆關閉」）；讀不到＝nil
    public static bool? firewall(string s)
    {
        var p = netshProfiles(s);
        if (p.Count == 0) return null;
        return p.All(x => x.on);
    }

    /// `netstat -ano -p TCP`＋`-p TCPv6`：LISTENING 的列 → 埠（同一埠合併；只要有一個綁在非本機位址就算對外）。
    /// `names`＝pid → 程式名（Process.GetProcessById 拿得到的；拿不到寫 pid）
    public static List<ListenPort> netstat(string s, Func<int, string?> names, IReadOnlyDictionary<int, string>? knownOpen = null)
    {
        var ko = knownOpen ?? CityRules.knownOpen;
        var byPort = new Dictionary<int, ListenPort>();
        foreach (var raw in s.Split('\n'))
        {
            var cols = raw.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries);
            // TCP    0.0.0.0:135    0.0.0.0:0    LISTENING    1234（中文版 Windows 的狀態欄也是 LISTENING）
            if (cols.Length < 5 || !cols[0].StartsWith("TCP", StringComparison.OrdinalIgnoreCase) || !cols[3].Equals("LISTENING", StringComparison.OrdinalIgnoreCase)) continue;
            var local = cols[1];
            int colon = local.LastIndexOf(':');
            if (colon < 0 || !int.TryParse(local[(colon + 1)..], out var port)) continue;
            var host = local[..colon];
            if (host.StartsWith('[') && host.EndsWith(']')) host = host[1..^1];
            int pct = host.IndexOf('%'); if (pct >= 0) host = host[..pct];
            bool lb = host == "localhost" || host.StartsWith("127.") || host == "::1" || host == "::ffff:127.0.0.1";
            int.TryParse(cols[4], out var pid);
            if (byPort.TryGetValue(port, out var p)) { if (!lb) p.External = true; }
            else byPort[port] = new ListenPort(port, names(pid) ?? $"pid {pid}", !lb, ko.GetValueOrDefault(port));
        }
        return byPort.Values.OrderBy(p => p.Port).ToList();
    }
}

// MARK: - 穿插檢查（10-21：堆場旁一坨歪斜貨櫃互相插進對方 ⇒ 城市每個方塊都可以拿來互相比）

/// 一個方塊：中心、長寬高、繞 Y 軸轉的角度（弧度，跟 3D 的 Xf.a 同一個方向）
public sealed record CityBox(Vec3 Center, Vec3 Size, double Yaw = 0)
{
    public bool rotated => Math.Abs(Math.IEEERemainder(Yaw, Math.PI / 2)) > 1e-4;
    /// 水平面上的兩個軸（x、z）：Xf.apply：local x → (c, -s)、local z → (s, c)
    ((double, double), (double, double)) axes { get { double c = Math.Cos(Yaw), s = Math.Sin(Yaw); return ((c, -s), (s, c)); } }

    /// 兩個方塊互相插進去多深（公尺；≤0＝沒碰到或只是貼著）。分離軸：上下＋水平面 4 條軸，取最小的重疊量
    public static double penetration(CityBox a, CityBox b)
    {
        double dy = Math.Min(a.Center.Y + a.Size.Y / 2, b.Center.Y + b.Size.Y / 2) - Math.Max(a.Center.Y - a.Size.Y / 2, b.Center.Y - b.Size.Y / 2);
        if (dy <= 0) return dy;
        var (ax, az) = a.axes; var (bx, bz) = b.axes;
        (double, double) d = (b.Center.X - a.Center.X, b.Center.Z - a.Center.Z);
        static double dot((double, double) u, (double, double) v) => u.Item1 * v.Item1 + u.Item2 * v.Item2;
        double best = dy;
        foreach (var n in new[] { ax, az, bx, bz })
        {
            double r(CityBox box, (double, double) u, (double, double) w) => Math.Abs(dot(u, n)) * box.Size.X / 2 + Math.Abs(dot(w, n)) * box.Size.Z / 2;
            double overlap = r(a, ax, az) + r(b, bx, bz) - Math.Abs(dot(d, n));
            if (overlap <= 0) return overlap;
            best = Math.Min(best, overlap);
        }
        return best;
    }
}
