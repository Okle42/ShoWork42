using System.Globalization;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace ShoWork;

// Mac 版 Sources/ShoWorkCore/Office.swift 的逐行轉寫（11-02 P8）。
// 3D 辦公室的資料層（10-20 Kang 拍板）：
//   ① 房間規則＝「固定樓層＋活動區」：~/github-repos 底下最近 30 天有 commit 的 repo 都有固定部門（沒人時暗著），
//      30 天外的專案有 AI 開在那邊時臨時加一個部門。部門位置依名稱排序，不因誰在忙而換位置。
//   ② 入口「前台・保全」：資料來自 wifiwatch（~/.claude/scripts/wifiwatch.sh 採集、wifiwatch.py 分析），
//      名冊 ~/.claude/data/wifiwatch_devices.json、紀錄 ~/.claude/data/wifiwatch.log。
//      Windows：沒有 wifiwatch（Mac 的 arp 腳本），名冊檔不在 ⇒ 「還沒掃描過 Wi-Fi」；有人把名冊放在同一個位置就照樣讀。
//      「立即掃描」（GuardScanner）沒有轉寫：Windows 沒有掃描腳本可跑。
//   ③ 格局（棋盤分區／中庭環狀）與燈光（白天／夜晚／自動）可以切換。
// 這裡只有純邏輯（可測）。

// MARK: - 常駐專案名冊

/// 一個常駐部門的來源：~/github-repos/<name>，最後一次 commit 的時間
public sealed record ResidentProject(string Name, DateTime LastCommit);

public static class ResidentProjects
{
    /// 最近幾天內有 commit 才算常駐
    public static readonly TimeSpan window = TimeSpan.FromDays(30);
    /// 多久重算一次（10-20：不監看 ~/github-repos——底下 build／node_modules 的變動會產生大量無關事件，
    /// 只掛在看板保底 timer 上每 30 分鐘重算一次；啟動時算一次）
    public static readonly TimeSpan rescanInterval = TimeSpan.FromMinutes(30);

    /// 列出 root 底下（只看第一層）最近 `window` 內有 commit 的 git repo，依名稱排序。
    /// 名稱＝資料夾名，跟 `Board.ProjectName`（往上找 .git 的資料夾名）算出來的 BoardCard.project 一致。
    /// 不算：符號連結／目錄連接（冷資料搬到外接碟的專案）、`.git` 是檔案的 worktree（ProjectA-w1 這類分身，
    /// 有 AI 開在那邊時會變臨時部門）、從來沒 commit 過的（沒有 reflog 也沒有分支）。不開 git 子行程。
    public static List<ResidentProject> scan(string root, DateTime now, TimeSpan? window = null)
    {
        var w = window ?? ResidentProjects.window;
        var out_ = new List<ResidentProject>();
        IEnumerable<string> names;
        try { names = Directory.EnumerateDirectories(root).Select(Path.GetFileName).OfType<string>().ToList(); } catch { return out_; }
        foreach (var name in names)
        {
            if (name.StartsWith('.')) continue;
            var dir = Path.Combine(root, name);
            try
            {
                var di = new DirectoryInfo(dir);
                if (di.LinkTarget != null || di.Attributes.HasFlag(FileAttributes.ReparsePoint)) continue;
            }
            catch { continue; }
            var git = Path.Combine(dir, ".git");
            if (!Directory.Exists(git)) continue;
            if (lastCommit(git) is not { } t || now - t > w) continue;
            out_.Add(new ResidentProject(name, t));
        }
        out_.Sort((a, b) => compare(a.Name, b.Name));
        return out_;
    }

    /// localizedStandardCompare 用的語系（Mac 跟系統語系；10-02 實測 zh_TW 下中文照筆畫、中文排在英文前面）。
    /// Windows 的 ShoWorkAgent 是 InvariantGlobalization ⇒ 這裡只剩序數比較（中文照字碼）；測試可以換成 zh-TW
    public static CompareInfo Collation { get; set; } = CultureInfo.CurrentCulture.CompareInfo;

    /// Foundation 的 localizedStandardCompare：不分大小寫、數字照大小（Finder 的排法）
    public static int localizedStandardCompare(string a, string b)
    {
        int i = 0, j = 0;
        while (i < a.Length && j < b.Length)
        {
            bool da = char.IsAsciiDigit(a[i]), db = char.IsAsciiDigit(b[j]);
            int i2 = i, j2 = j;
            while (i2 < a.Length && char.IsAsciiDigit(a[i2]) == da) i2++;
            while (j2 < b.Length && char.IsAsciiDigit(b[j2]) == db) j2++;
            string x = a[i..i2], y = b[j..j2];
            int c;
            if (da && db)
            {
                var xs = x.TrimStart('0'); var ys = y.TrimStart('0');
                c = xs.Length != ys.Length ? xs.Length.CompareTo(ys.Length) : string.CompareOrdinal(xs, ys);
            }
            else c = Collation.Compare(x, y, CompareOptions.IgnoreCase | CompareOptions.IgnoreWidth | CompareOptions.IgnoreKanaType);
            if (c != 0) return Math.Sign(c);
            i = i2; j = j2;
        }
        return (a.Length - i).CompareTo(b.Length - j);
    }

    /// 部門排序：不分大小寫、數字照大小（ProjectA 在 ProjectB 之後）；穩定，不看誰在忙
    public static bool order(string a, string b) => compare(a, b) < 0;
    /// order 的比較函式版（C# 的 Sort 要三態）
    public static int compare(string a, string b)
    {
        int r = localizedStandardCompare(a, b);
        return r == 0 ? string.CompareOrdinal(a, b) : r;
    }

    /// 最後一次 commit 的時間：讀 .git/logs/HEAD 尾端（不開 git）。沒有 reflog 就看 refs/heads 底下分支檔的 mtime。
    public static DateTime? lastCommit(string gitDir)
    {
        var log = Path.Combine(gitDir, "logs", "HEAD");
        if (File.Exists(log))
        {
            try
            {
                using var h = new FileStream(log, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
                long size = h.Length;
                // 先讀尾端 64KB；最後幾筆都是 checkout／reset 時往前讀整個檔（上限 4MB）
                foreach (long back in new long[] { 64 << 10, 4 << 20 })
                {
                    h.Seek(size > back ? size - back : 0, SeekOrigin.Begin);
                    var buf = new byte[size > back ? back : size];
                    int n = 0; while (n < buf.Length) { int r = h.Read(buf, n, buf.Length - n); if (r <= 0) break; n += r; }
                    if (reflogLastCommit(buf.AsSpan(0, n)) is { } t) return t;
                    if (size <= back) break;
                }
            }
            catch { }
            return null;
        }
        return newestRef(Path.Combine(gitDir, "refs", "heads"));
    }

    /// reflog 裡算「有 commit」的動作：本機 commit、合併、pull、rebase、cherry-pick、revert、am。
    /// 不算 checkout／reset／branch／clone（只是移動 HEAD，不是有人在這個專案做事）。
    static readonly string[] commitActions = { "commit", "merge", "pull", "rebase", "cherry-pick", "revert", "am" };

    /// 一行 reflog：`<舊> <新> 名字 <信箱> <時間戳> <時區>\t<動作>: <訊息>`（名字可以有空白）
    public static DateTime? reflogLastCommit(ReadOnlySpan<byte> d)
    {
        var lines = Encoding.UTF8.GetString(d).Split('\n');
        for (int k = lines.Length - 1; k >= 0; k--)
        {
            var line = lines[k];
            int tab = line.IndexOf('\t');
            if (tab < 0) continue;
            string head = line[..tab], msg = line[(tab + 1)..];
            var pre = msg.Split(':')[0];
            var action = pre.Split(' ', StringSplitOptions.RemoveEmptyEntries).FirstOrDefault() ?? "";
            int gt = head.LastIndexOf("> ", StringComparison.Ordinal);
            if (!commitActions.Contains(action) || gt < 0) continue;
            var parts = head[(gt + 2)..].Split(' ', StringSplitOptions.RemoveEmptyEntries);
            if (parts.Length > 0 && double.TryParse(parts[0], NumberStyles.Float, CultureInfo.InvariantCulture, out var ts)) return MacMirror.FromSeconds(ts);
        }
        return null;
    }

    static DateTime? newestRef(string dir)
    {
        if (!Directory.Exists(dir)) return null;
        DateTime? best = null;
        try
        {
            foreach (var f in Directory.EnumerateFiles(dir, "*", SearchOption.AllDirectories))
            {
                var m = File.GetLastWriteTimeUtc(f);
                best = best is { } b && b > m ? b : m;
            }
        }
        catch { }
        return best;
    }
}

/// 辦公室裡的一個部門
public sealed record OfficeDepartment
{
    public string Name { get; set; }          // ＝BoardCard.project
    public bool IsResident { get; set; }      // 常駐（30 天內有 commit）；false＝臨時（有 AI 開在那邊才出現）
    public bool IsActive { get; set; }        // 現在有 AI 在（含排隊中的訊息）；沒人時暗著
    public string id => Name;
    public OfficeDepartment(string name, bool isResident, bool isActive) { Name = name; IsResident = isResident; IsActive = isActive; }
}

public static class OfficeDepartments
{
    /// 有序的部門清單：常駐部門照名稱排在前面，臨時部門照名稱接在後面。
    /// 名稱比對不分大小寫（cwd 偶爾跟資料夾名大小寫不同）；顯示用常駐名冊的寫法。
    /// 影分身（visiting）不開部門——只是 cd 過去逛一下（跟部門島同一條規則）。
    public static List<OfficeDepartment> build(IEnumerable<string> residents, IEnumerable<BoardCard> cards)
    {
        var res = residents.ToList();
        var present = new HashSet<string>();
        var tempNames = new Dictionary<string, string>();           // 小寫 → 第一次看到的寫法
        var known = res.Select(r => r.ToLowerInvariant()).ToHashSet();
        foreach (var c in cards)
        {
            var k = c.Project.ToLowerInvariant();
            present.Add(k);
            if (!known.Contains(k) && !tempNames.ContainsKey(k)) tempNames[k] = c.Project;
        }
        var fixed_ = res.Select(r => new OfficeDepartment(r, isResident: true, isActive: present.Contains(r.ToLowerInvariant())));
        var temps = tempNames.Values.ToList();
        temps.Sort(ResidentProjects.compare);
        return fixed_.Concat(temps.Select(t => new OfficeDepartment(t, isResident: false, isActive: true))).ToList();
    }
}

// MARK: - 前台・保全（wifiwatch）

public enum GuardLevel { normal, notice, alert }

public static class GuardLevels
{
    public static string title(this GuardLevel l) => l switch { GuardLevel.normal => "正常", GuardLevel.notice => "注意", _ => "警示" };
}

/// 要保全注意的一台裝置
public sealed record GuardDevice
{
    public enum DeviceKind
    {
        @new,         // 紀錄裡有 NEW、名冊裡還沒命名
        unnamed,      // 名冊裡沒命名
        unconfirmed,  // 名字以 ★ 開頭（wifiwatch 標的「不在你清單上」，你還沒確認）
        named,        // 已命名（只出現在 onlineDevices 清單）
    }
    public string Mac { get; set; } = "";
    public string? Ip { get; set; }
    public string? Vendor { get; set; }
    public string? Label { get; set; }
    public DeviceKind Kind { get; set; }
    public bool Online { get; set; }          // 最近一次掃描有看到
    public DateTime? FirstSeen { get; set; }
    public string? Hostname { get; set; }
    /// 只看到 IPv6、MAC 又是隨機的（本機管理位元）：多半是家裡手機／平板的隱私位址。
    /// 陌生人連上 Wi-Fi 會拿 DHCP 的 IPv4，所以這種只算「注意」不算「警示」
    public bool privacyOnly => Ip == null && WifiWatch.isLocallyAdministered(Mac);
    public GuardDevice() { }
    public GuardDevice(string mac, string? ip = null, string? vendor = null, string? label = null, DeviceKind kind = DeviceKind.unnamed, bool online = false, DateTime? firstSeen = null)
    { Mac = mac; Ip = ip; Vendor = vendor; Label = label; Kind = kind; Online = online; FirstSeen = firstSeen; }
}

/// push 守門的一筆紀錄（Mac PushGuard.swift 的 PushEvent；Windows 的 hook 端寫在 board\guard\pushes.jsonl，欄位相同）
public sealed record GuardPushEvent
{
    public enum PushVerdict { ok, warn, block }
    public DateTime At { get; set; }
    public string? Session { get; set; }
    public string? Name { get; set; }         // 英文名
    public string Repo { get; set; } = "";    // owner/name（看不出來就資料夾名）
    public string Dir { get; set; } = "";
    public List<string> Refs { get; set; } = new();
    public int Commits { get; set; }
    public PushVerdict Verdict { get; set; }
    public List<string> Reasons { get; set; } = new();
    public bool Secret { get; set; }          // 擋下的原因裡有金鑰（保全亮紅燈）
    public string? Head { get; set; }         // 檢查時的 HEAD（保全面板「放行一次」認這個）

    /// pushes.jsonl 的一行（Mac BoardJSON：日期是 ISO 8601）；看不懂回 null
    public static GuardPushEvent? decode(string line)
    {
        try
        {
            if (JsonNode.Parse(line) is not JsonObject o) return null;
            string? S(string k) => o[k] is JsonValue v && v.TryGetValue<string>(out var s) ? s : null;
            var at = S("at") is { } a && DateTime.TryParse(a, CultureInfo.InvariantCulture, DateTimeStyles.AdjustToUniversal | DateTimeStyles.AssumeUniversal, out var d) ? d : (DateTime?)null;
            if (at == null) return null;
            return new GuardPushEvent
            {
                At = at.Value, Session = S("session"), Name = S("name"), Repo = S("repo") ?? "", Dir = S("dir") ?? "",
                Refs = (o["refs"] as JsonArray)?.Select(x => x?.ToString() ?? "").ToList() ?? new(),
                Commits = o["commits"] is JsonValue c && c.TryGetValue<int>(out var n) ? n : 0,
                Verdict = S("verdict") switch { "block" => PushVerdict.block, "warn" => PushVerdict.warn, _ => PushVerdict.ok },
                Reasons = (o["reasons"] as JsonArray)?.Select(x => x?.ToString() ?? "").ToList() ?? new(),
                Secret = o["secret"] is JsonValue sv && sv.TryGetValue<bool>(out var sb) && sb,
                Head = S("head"),
            };
        }
        catch { return null; }
    }
}

/// 保全看到的 Wi-Fi 狀態。不含「現在幾點」以外會一直變的東西，內容沒變就不重新發布。
public sealed record GuardStatus
{
    public bool HasData { get; set; }                         // 名冊檔存在、讀得懂
    public DateTime? LastScan { get; set; }                   // 上次掃描（名冊裡最新的 last_seen：每次掃描會把在線裝置都蓋成同一個時間）
    public int KnownCount { get; set; }                       // 名冊裝置數
    public int OnlineCount { get; set; }                      // 上次掃描在線的
    public List<GuardDevice> Flagged { get; set; } = new();   // 未命名／新裝置／★未確認（在線的排前面）
    public List<GuardDevice> OnlineDevices { get; set; } = new();   // 上次掃描在線的全部裝置（10-24 Kang：要看在線的是哪些）；依 IP 排
    public bool Stale { get; set; }                           // 超過 24 小時沒掃描
    public GuardLevel Level { get; set; } = GuardLevel.notice;
    public string Summary { get; set; } = "";                 // 一句話（給櫃台螢幕）
    // push 守門（10-22，PushGuard）：最近 24 小時
    public int PushChecked { get; set; }
    public int PushBlocked { get; set; }
    public List<GuardPushEvent> PushRecent { get; set; } = new();   // 新的在前，最多 5 筆

    /// 把 push 守門的紀錄併進來：擋過金鑰 ⇒ 警示；擋過別的 ⇒ 至少注意
    public void merge(List<GuardPushEvent> evs)
    {
        PushChecked = evs.Count;
        PushBlocked = evs.Count(e => e.Verdict == GuardPushEvent.PushVerdict.block);
        PushRecent = evs.Take(5).ToList();
        if (evs.Any(e => e.Secret)) Level = GuardLevel.alert;
        else if (PushBlocked > 0 && Level < GuardLevel.notice) Level = GuardLevel.notice;
        if (PushChecked > 0)
        {
            var p = $"24 小時內檢查 {PushChecked} 次 push" + (PushBlocked > 0 ? $"，擋下 {PushBlocked} 次" : "，都沒問題");
            Summary = Summary.Length == 0 ? p : Summary + "；" + p;
        }
    }
}

public static class WifiWatch
{
    /// 多久沒掃描算「很久沒掃描」
    public static readonly TimeSpan staleAfter = TimeSpan.FromHours(24);
    /// last_seen 跟上次掃描差多少以內算「那次在線」（同一次掃描寫的是同一個時間，留一點餘裕）
    public static readonly TimeSpan onlineSlack = TimeSpan.FromSeconds(120);

    /// 解析名冊（JSON：MAC → {first_seen, label, vendor, last_seen, last_ip, hostname?}，時間是本機時間、沒有時區）
    /// 與紀錄（`YYYY-MM-DD HH:MM:SS  NEW  <ip 或 (僅 IPv6)>  <MAC>  <廠商>`；# 開頭是人工註記）。
    /// 紀錄裡 NEW、名冊卻已經沒有的 MAC 不算（被 --forget 掉的，例如 09-22 IPv6 測試假警報）。
    public static GuardStatus parse(string? devices, string? log, DateTime now, TimeZoneInfo? timeZone = null)
    {
        var tz = timeZone ?? TimeZoneInfo.Local;
        var s = new GuardStatus();
        JsonObject? db = null;
        try { db = devices == null ? null : JsonNode.Parse(devices) as JsonObject; } catch { }
        if (db == null || db.Any(kv => kv.Value is not JsonObject))
        {
            s.Level = GuardLevel.notice; s.Summary = "還沒掃描過 Wi-Fi";
            return s;
        }
        DateTime? f(string? x)
        {
            if (x == null || !DateTime.TryParseExact(x, "yyyy-MM-dd'T'HH:mm:ss", CultureInfo.InvariantCulture, DateTimeStyles.None, out var d)) return null;
            return TimeZoneInfo.ConvertTimeToUtc(DateTime.SpecifyKind(d, DateTimeKind.Unspecified), tz);
        }
        string? str(JsonObject o, string k) => o[k] is JsonValue v && v.TryGetValue<string>(out var x) ? x : null;
        s.HasData = true;
        s.KnownCount = db.Count;
        var seen = db.ToDictionary(kv => kv.Key, kv => f(str((JsonObject)kv.Value!, "last_seen")));
        var times = seen.Values.Where(v => v != null).Select(v => v!.Value).ToList();
        s.LastScan = times.Count == 0 ? null : times.Max();
        bool online(string mac)
        {
            if (seen.GetValueOrDefault(mac) is not { } t || s.LastScan is not { } last) return false;
            return last - t <= onlineSlack;
        }
        s.OnlineCount = db.Select(kv => kv.Key).Count(online);

        // 紀錄的 NEW 行：MAC → 第一次被報的時間
        var newAt = new Dictionary<string, DateTime>();
        foreach (var line in (log ?? "").Split('\n'))
        {
            if (line.StartsWith('#') || line.Length <= 19) continue;
            if (!DateTime.TryParseExact(line[..19], "yyyy-MM-dd HH:mm:ss", CultureInfo.InvariantCulture, DateTimeStyles.None, out var lt)) continue;
            var t = TimeZoneInfo.ConvertTimeToUtc(DateTime.SpecifyKind(lt, DateTimeKind.Unspecified), tz);
            var rest = line[19..].Split(' ', StringSplitOptions.RemoveEmptyEntries);
            if (rest.Length == 0 || rest[0] != "NEW" || rest.FirstOrDefault(isMAC) is not { } m) continue;
            var mac = m.ToLowerInvariant();
            if (!newAt.ContainsKey(mac)) newAt[mac] = t;
        }

        foreach (var (mac, node) in db)
        {
            var r = (JsonObject)node!;
            var label = str(r, "label")?.Trim() ?? "";
            GuardDevice.DeviceKind kind;
            if (label.Length == 0) kind = newAt.ContainsKey(mac) ? GuardDevice.DeviceKind.@new : GuardDevice.DeviceKind.unnamed;
            else if (label.StartsWith('★')) kind = GuardDevice.DeviceKind.unconfirmed;
            else kind = GuardDevice.DeviceKind.named;
            var d = new GuardDevice(mac, str(r, "last_ip"), str(r, "vendor"), label.Length == 0 ? null : label, kind, online(mac),
                                    f(str(r, "first_seen")) ?? (newAt.TryGetValue(mac, out var na) ? na : null));
            d.Hostname = str(r, "hostname");
            if (d.Online) s.OnlineDevices.Add(d);
            if (kind != GuardDevice.DeviceKind.named) s.Flagged.Add(d);
        }
        // IP 依數字排（.9 在 .10 前）；只有 IPv6 的排最後
        int[] ipKey(GuardDevice d) => d.Ip is { } ip ? ip.Split('.').Select(x => int.TryParse(x, out var n) ? (int?)n : null).Where(x => x != null).Select(x => x!.Value).ToArray() : new[] { 999 };
        int lex(int[] a, int[] b) { for (int i = 0; i < Math.Min(a.Length, b.Length); i++) if (a[i] != b[i]) return a[i].CompareTo(b[i]); return a.Length.CompareTo(b.Length); }
        s.OnlineDevices.Sort((a, b) => { int c = lex(ipKey(a), ipKey(b)); return c != 0 ? c : string.CompareOrdinal(a.Mac, b.Mac); });
        s.Flagged.Sort((a, b) =>
        {
            int c = (a.Online ? 0 : 1).CompareTo(b.Online ? 0 : 1); if (c != 0) return c;
            c = string.CompareOrdinal(a.Ip ?? "~", b.Ip ?? "~"); if (c != 0) return c;
            return string.CompareOrdinal(a.Mac, b.Mac);
        });

        s.Stale = s.LastScan is { } ls ? now - ls > staleAfter : true;
        // 警示：沒命名的裝置上次掃描還在線上（有陌生人連著你的 Wi-Fi）。注意：很久沒掃描、或有待確認的裝置。
        if (s.Flagged.Any(d => d.Online && d.Kind != GuardDevice.DeviceKind.unconfirmed && !d.privacyOnly)) s.Level = GuardLevel.alert;
        else if (s.Stale || s.Flagged.Count > 0) s.Level = GuardLevel.notice;
        else s.Level = GuardLevel.normal;

        var parts = new List<string>();
        if (s.LastScan == null) parts.Add("還沒掃描過 Wi-Fi");
        else if (s.Stale) parts.Add("很久沒掃描了");
        parts.Add($"上次在線 {s.OnlineCount} 台／名冊 {s.KnownCount} 台");
        int strangers = s.Flagged.Count(d => d.Kind != GuardDevice.DeviceKind.unconfirmed);
        int pending = s.Flagged.Count - strangers;
        int privacy = s.Flagged.Count(d => d.Kind != GuardDevice.DeviceKind.unconfirmed && d.privacyOnly);
        if (strangers > 0) parts.Add($"{strangers} 台沒命名" + (privacy > 0 ? $"（{privacy} 台只有 IPv6 隨機位址）" : ""));
        if (pending > 0) parts.Add($"{pending} 台待確認");
        s.Summary = string.Join("，", parts);
        return s;
    }

    /// MAC 第一個位元組的「本機管理」位元（0x02）：手機 Wi-Fi 隱私位址、虛擬網卡都會設
    public static bool isLocallyAdministered(string mac)
    {
        if (mac.Length < 2 || !byte.TryParse(mac[..2], NumberStyles.HexNumber, CultureInfo.InvariantCulture, out var b)) return false;
        return (b & 0x02) != 0;
    }

    static bool isMAC(string s)
    {
        var p = s.Split(':');
        return p.Length == 6 && p.All(x => x.Length is >= 1 and <= 2 && x.All(char.IsAsciiHexDigit));
    }
}

// MARK: - 格局與燈光設定

/// 辦公室格局（10-20：兩種都要、可切換）
public enum OfficeLayout
{
    grid,   // A 棋盤分區：部門排兩區，中央走道放咖啡吧／會議桌／隊長台
    ring,   // C 中庭環狀：部門圍一圈朝中央公共區
}

/// 畫面風格（10-22 Kang：等角微縮模型、藍圖線框兩種都要試）：只換鏡頭與後製，模型不變
public enum OfficeStyle { voxel, diorama, blueprint }

/// 燈光
public enum OfficeLighting { day, night, auto }

public static class OfficeSettings
{
    public static string title(this OfficeLayout l) => l == OfficeLayout.grid ? "棋盤分區" : "中庭環狀";
    public static string title(this OfficeStyle s) => s switch
    {
        OfficeStyle.voxel => "體素（原本）", OfficeStyle.diorama => "微縮模型（等角＋移軸）", _ => "藍圖（深藍底、發光線條）",
    };
    public static string title(this OfficeLighting l) => l switch { OfficeLighting.day => "白天", OfficeLighting.night => "夜晚", _ => "自動" };

    /// 自動：跟真實太陽（10-21 日出日落，Solar）；白天／夜晚固定＝改版前的兩組燈光。
    /// 地點（11-01 Kang）：天氣設定的主地點（OfficeWeather.main）；沒給＝台北
    public static SunSample sun(this OfficeLighting l, DateTime date, (double lat, double lon)? site = null)
    {
        var s = site ?? Solar.taipei;
        return Solar.position(date, s.lat, s.lon);
    }

    /// 這個時間點的天色與燈光
    public static SkyLook look(this OfficeLighting l, DateTime date, (double lat, double lon)? site = null) => l switch
    {
        OfficeLighting.day => SkyLook.day,
        OfficeLighting.night => SkyLook.night,
        _ => SkyLook.at(l.sun(date, site)),
    };

    /// 自動：太陽在地平線下夠深（暗度過半，約仰角 −1.5° 以下）算夜晚
    public static bool isNight(this OfficeLighting l, DateTime date) => l.look(date).isNight;

    /// 標籤文字：自動＝「自動・清晨／日出／白天／傍晚／日落／黃昏／夜晚」
    public static string label(this OfficeLighting l, DateTime date, (double lat, double lon)? site = null) =>
        l == OfficeLighting.auto ? "自動・" + SkyLook.phaseTitle(l.sun(date, site)) : l.title();

    /// 天色會變的仰角範圍（這段每分鐘更新一次）；白天只有太陽方向在動（每 5 分鐘）；夜晚整段不變
    public const double changingLo = -13.0, changingHi = 23.0;

    /// 自動模式下一次要重算燈光的時間（畫面排一次性的 sleep，不輪詢）：
    /// 晨昏那段每 60 秒、白天每 5 分鐘（主光東升西落）、夜晚睡到天快亮（仰角回到 −13°）。白天／夜晚固定就回 nil
    public static DateTime? nextChange(this OfficeLighting l, DateTime date, (double lat, double lon)? site = null)
    {
        if (l != OfficeLighting.auto) return null;
        var e = l.sun(date, site).Elevation;
        if (e >= changingLo && e <= changingHi) return date.AddSeconds(60);
        if (e > changingHi) return date.AddSeconds(300);
        // 夜晚：每 2 分鐘往後找第一個進入晨昏帶的時間（最多 24 小時）
        var t = date;
        for (int i = 0; i < 720; i++)
        {
            t = t.AddSeconds(120);
            if (l.sun(t, site).Elevation >= changingLo) return t;
        }
        return date.AddSeconds(3600);
    }
}
