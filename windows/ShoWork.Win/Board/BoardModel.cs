using System.Globalization;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using System.Text.RegularExpressions;

namespace ShoWork;

// 戰情中心（Board）：把本機每個 Claude Code session 排成卡片。Mac 版 Sources/ShoWorkCore/Board.swift 的移植，規則一樣。
// 這裡只有純邏輯（解析＋分欄＋住哪），讀檔在 BoardReader.cs，畫面另外做。資料來源（Windows，Claude Code 2.1.29x）：
//   %USERPROFILE%\.claude\sessions\<pid>.json            每個開著的 session（10-15 Surface 上是空的：沒有開著的 claude；
//                                                        欄位比照 Mac 的檔案，見 SessionRecord 的註解，Windows 版是推測）
//   %USERPROFILE%\.claude\projects\<slug>\<sid>.jsonl    對話紀錄（10-15 實測：每筆有 "cwd":"C:\\Users\\Demo User"、timestamp、ai-title、last-prompt）
//   %USERPROFILE%\.claude\teams\<team>\…                 agent team（Claude Code 的功能，格式同 Mac；Surface 上還沒出現過）
// Windows 的路徑：大小寫不敏感、反斜線、磁碟代號。比對一律不分大小寫（同一個 repo 從 Git Bash 進來可能是 c:\ 小寫）。

public enum BoardColumn { Todo, Active, Review, Done, Stuck }

public static class BoardColumns
{
    public static string Title(this BoardColumn c) => c switch
    {
        BoardColumn.Todo => "待辦", BoardColumn.Active => "進行中", BoardColumn.Review => "待審",
        BoardColumn.Done => "完成", _ => "卡住",
    };
}

/// `~/.claude/sessions/<pid>.json`。Mac 10-08 實測欄位：pid、sessionId、cwd、startedAt、kind、entrypoint、name、status、
/// updatedAt、statusUpdatedAt、messagingSocketPath、pidDomain（"darwin"）。Windows 版的檔案還沒親眼看過（Surface 上沒有開著的
/// session），假設欄位相同、cwd 是 C:\ 路徑；pid 假設是 claude.exe（跟 hook 送來的 pid 同一個，W1 實測 hook 的 pid 是 claude.exe）。
public sealed record SessionRecord
{
    public int Pid { get; init; }
    public string SessionId { get; init; } = "";
    public string Cwd { get; init; } = "";
    public string? Name { get; init; }
    public string? Status { get; init; }
    public string? Kind { get; init; }
    public string? Entrypoint { get; init; }       // "sdk-cli"＝`claude -p` 這類無頭呼叫，不上看板
    public double? UpdatedAt { get; init; }        // ms
    public double? StatusUpdatedAt { get; init; }  // ms
    public double? StartedAt { get; init; }        // ms；Windows 用來認 pid 有沒有被別的程式重用

    static readonly JsonSerializerOptions Opt = new() { PropertyNameCaseInsensitive = true, NumberHandling = JsonNumberHandling.AllowReadingFromString };

    public static SessionRecord? Decode(string json)
    {
        try
        {
            var r = JsonSerializer.Deserialize<SessionRecord>(json, Opt);
            return r == null || r.SessionId.Length == 0 ? null : r;
        }
        catch { return null; }
    }

    /// `~/.claude/projects/` 底下的資料夾名：英數字和 `-` 以外全換成 `-`（一個字元一個 `-`）。
    /// Surface 10-15 實測：`C:\Users\Demo User\ShoWork42` → `C--Users-Demo-User-ShoWork42`；8.3 短名 `DEMOUS~1` → `DEMOUS-1`。
    public string ProjectSlug
    {
        get
        {
            var sb = new StringBuilder();
            foreach (var r in Cwd.EnumerateRunes())
                sb.Append(r.IsAscii && (char.IsAsciiLetterOrDigit((char)r.Value) || r.Value == '-') ? (char)r.Value : '-');
            return sb.ToString();
        }
    }

    /// 行程還在，但 pid 可能已經被別的程式重用（Windows pid 回收得很快）：比 session 開始時間晚一分鐘以上才出生的就不是它
    public bool SameOwner(DateTime processStartUtc) =>
        StartedAt is not { } ms || processStartUtc <= DateTime.UnixEpoch.AddMilliseconds(ms).AddSeconds(60);
}

/// 某個時間點 session 在哪個資料夾
public readonly record struct CwdMark(string Cwd, DateTime? At);

/// 從對話紀錄尾端抽出看板要的東西
public sealed class TranscriptInfo
{
    public string? Title;
    public string? LastCwd;
    public string? LastWorkCwd;                         // 最後一個「做事的地方」：略過 ~/.claude、暫存資料夾
    public List<CwdMark> RecentWorkCwds = new();        // 最近幾筆做事的地方＋時間（住哪、影分身用）
    public string? LastPrompt;
    public DateTime? LastPromptAt;                      // 你最後一次送出訊息的時間（判斷自報是不是這一輪的）
    public string? LastAssistantText;
    public DateTime? LastActivity;
    public List<string> Queued = new();                 // 排隊中、AI 還沒拿去做的訊息

    public const int CwdWindow = 400;

    /// `tail` 是 jsonl 的尾端（可能從某行中間開始，第一行壞掉就略過）
    public static TranscriptInfo Parse(ReadOnlySpan<byte> tail)
    {
        var t = new TranscriptInfo();
        var queue = new List<string?>();                // null＝系統自動排的（task-notification），不算待辦
        foreach (var raw in Lines(tail))
        {
            // 一行壞掉（JSON 不合法、字串裡有孤立的代理字元 "\ud83d"、巢狀太深）整行略過、不留半套，同 Swift 的 JSONSerialization
            Line l;
            try { l = ParseLine(raw); } catch { continue; }
            if (l.Cwd is { } c)
            {
                t.LastCwd = c;
                if (!IsToolDir(c))
                {
                    t.LastWorkCwd = c;
                    t.RecentWorkCwds.Add(new CwdMark(c, l.At));
                    if (t.RecentWorkCwds.Count > CwdWindow) t.RecentWorkCwds.RemoveAt(0);
                }
            }
            if (l.At is { } d) t.LastActivity = t.LastActivity is { } a && a > d ? a : d;
            if (l.Title != null) t.Title = l.Title;
            if (l.LastPrompt != null) t.LastPrompt = l.LastPrompt;
            if (l.PromptAt) t.LastPromptAt = l.At;
            if (l.Assistant != null) t.LastAssistantText = l.Assistant;
            if (l.Enqueue) queue.Add(l.Queued);
            if (l.Dequeue && queue.Count > 0) queue.RemoveAt(0);
        }
        t.Queued = queue.Where(q => q != null).Select(q => q!).ToList();
        return t;
    }

    /// 一行的結果：先全部取完才套用，取到一半丟例外就整行不算
    record struct Line(string? Cwd, DateTime? At, string? Title, string? LastPrompt, bool PromptAt, string? Assistant, bool Enqueue, string? Queued, bool Dequeue);

    /// Foundation 的 JSONSerialization 巢狀上限 512；System.Text.Json 預設 64，太淺會把 Swift 讀得到的行丟掉
    static readonly JsonDocumentOptions LineOptions = new() { MaxDepth = 512 };

    static Line ParseLine(ReadOnlySpan<byte> raw)
    {
        using var doc = JsonDocument.Parse(raw.ToArray(), LineOptions);
        var o = doc.RootElement;
        var l = new Line();
        if (o.ValueKind != JsonValueKind.Object) return l;
        l.Cwd = Str(o, "cwd");
        var ts = Str(o, "timestamp");
        l.At = Iso(ts);
        switch (Str(o, "type"))
        {
            case "ai-title": if (Str(o, "aiTitle") is { Length: > 0 } s1) l.Title = s1; break;
            case "custom-title": if (Str(o, "customTitle") is { Length: > 0 } s2) l.Title = s2; break;
            case "last-prompt": if (Str(o, "lastPrompt") is { } s3) l.LastPrompt = s3; break;
            case "queue-operation":
                switch (Str(o, "operation"))
                {
                    case "enqueue":
                        var q = Str(o, "content");
                        l.Enqueue = true;
                        l.Queued = q == null || IsSystemMessage(q) ? null : q;
                        break;
                    case "dequeue" or "remove" or "popAll":
                        l.Dequeue = true;
                        break;
                }
                break;
            case "user":
                // 剛開的 session 還沒有 ai-title／last-prompt，用你最後打的那句當標題
                if (o.TryGetProperty("message", out var m) && m.ValueKind == JsonValueKind.Object
                    && Str(m, "content") is { Length: > 0 } uc && !IsSystemMessage(uc))
                {
                    l.LastPrompt = uc;
                    l.PromptAt = ts != null;
                }
                break;
            case "assistant":
                if (o.TryGetProperty("message", out var am) && am.ValueKind == JsonValueKind.Object
                    && am.TryGetProperty("content", out var parts) && parts.ValueKind == JsonValueKind.Array)
                {
                    var text = string.Join("\n", parts.EnumerateArray()
                        .Where(p => p.ValueKind == JsonValueKind.Object && Str(p, "type") == "text" && Str(p, "text") != null)
                        .Select(p => Str(p, "text")!)).Trim();
                    if (text.Length > 0) l.Assistant = text;
                }
                break;
        }
        return l;
    }

    /// 系統自動排進來的（task-notification、跨 session 的閒置／送達通知），不是你交代的事
    public static bool IsSystemMessage(string s) => s.StartsWith('<') || s.StartsWith("[Cross-session", StringComparison.Ordinal);

    static readonly byte[] CwdKey = "\"cwd\":\""u8.ToArray(), TsKey = "\"timestamp\":\""u8.ToArray();

    /// 從對話紀錄抽出每一筆的 cwd＋時間（不解析整行 JSON：讀圖的那幾行一行幾百 KB）。
    /// 只認 `"cwd":"`——字串裡面的引號是跳脫過的（`\"cwd\":\"`），不會誤認。略過 ~/.claude、暫存資料夾。
    public static List<CwdMark> WorkCwds(ReadOnlySpan<byte> d)
    {
        var out_ = new List<CwdMark>();
        foreach (var line in Lines(d))
        {
            if (Value(line, CwdKey) is { } c && !IsToolDir(c)) out_.Add(new CwdMark(c, Iso(Value(line, TsKey))));
        }
        return out_;
    }

    /// 在一行裡找第一個 `"key":"值"`，回傳解開跳脫後的值
    static string? Value(ReadOnlySpan<byte> b, byte[] key)
    {
        int i = b.IndexOf(key);
        if (i < 0) return null;
        int j = i + key.Length;
        while (j < b.Length && b[j] != (byte)'"') { if (b[j] == (byte)'\\') j++; j++; }
        if (j >= b.Length) return null;
        try { return JsonSerializer.Deserialize<string>(b[(i + key.Length - 1)..(j + 1)]); } catch { return null; }
    }

    /// 不代表「在做哪個案子」的資料夾：~/.claude 底下、暫存資料夾（Mac 的 /tmp、Windows 的 AppData\Local\Temp 與 C:\Windows\Temp）
    public static bool IsToolDir(string p)
    {
        var q = p.Replace('\\', '/').ToLowerInvariant();
        return q.Contains("/.claude/") || q.EndsWith("/.claude") || q.StartsWith("/private/tmp/") || q.StartsWith("/tmp/")
            || q.StartsWith("/var/folders/") || q.Contains("/appdata/local/temp/") || q.EndsWith("/appdata/local/temp")
            || (q.Length > 2 && q[1] == ':' && q[2..].StartsWith("/windows/temp"));
    }

    /// 跟 Swift 的 ISO8601DateFormatter（internetDateTime，小數秒可有可無）一樣嚴：一定要有 T 和時區（Z 或 ±hh:mm），
    /// 沒時區的、只有日期的、10/15/2026 這種都不收（以前 TryParse＋AssumeUniversal 會當成 UTC 收下，住哪／卡住判斷跟 Mac 不同）
    static readonly Regex IsoRx = new(@"^(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2})(?:\.(\d+))?(Z|[+-]\d{2}:?\d{2})$", RegexOptions.CultureInvariant);

    public static DateTime? Iso(string? s)
    {
        if (s == null || IsoRx.Match(s) is not { Success: true } m) return null;
        var frac = m.Groups[2].Success ? "." + (m.Groups[2].Value + "0000000")[..7] : "";    // .NET 最多 7 位小數
        var zone = m.Groups[3].Value == "Z" ? "+00:00" : m.Groups[3].Value.Length == 5 ? m.Groups[3].Value.Insert(3, ":") : m.Groups[3].Value;
        return DateTimeOffset.TryParseExact(m.Groups[1].Value + frac + zone, frac.Length > 0 ? "yyyy-MM-dd'T'HH:mm:ss.fffffffzzz" : "yyyy-MM-dd'T'HH:mm:sszzz",
                                            CultureInfo.InvariantCulture, DateTimeStyles.None, out var d) ? d.UtcDateTime : null;
    }

    static string? Str(JsonElement o, string k) => o.TryGetProperty(k, out var v) && v.ValueKind == JsonValueKind.String ? v.GetString() : null;

    /// 以 \n 切行（Windows 也是 \n；保險起見去掉行尾 \r），空行略過
    ref struct LineEnum
    {
        ReadOnlySpan<byte> rest;
        public ReadOnlySpan<byte> Current { get; private set; }
        public LineEnum(ReadOnlySpan<byte> d) { rest = d; Current = default; }
        public LineEnum GetEnumerator() => this;
        public bool MoveNext()
        {
            while (rest.Length > 0)
            {
                int n = rest.IndexOf((byte)'\n');
                var line = n < 0 ? rest : rest[..n];
                rest = n < 0 ? ReadOnlySpan<byte>.Empty : rest[(n + 1)..];
                if (line.Length > 0 && line[^1] == (byte)'\r') line = line[..^1];
                if (line.Length == 0) continue;
                Current = line;
                return true;
            }
            return false;
        }
    }
    static LineEnum Lines(ReadOnlySpan<byte> d) => new(d);
}

/// `~/.claude/teams/<team>/config.json` 裡的一個成員
public sealed record TeamMember
{
    public string AgentId { get; init; } = "";
    public string Name { get; init; } = "";
    public string? AgentType { get; init; }
    public string? Color { get; init; }
    public string? Model { get; init; }
}

public sealed record TeamConfig
{
    public string Name { get; init; } = "";
    public string? LeadSessionId { get; init; }
    public List<TeamMember> Members { get; init; } = new();

    static readonly JsonSerializerOptions Opt = new() { PropertyNameCaseInsensitive = true };
    public static TeamConfig? Decode(string json) { try { return JsonSerializer.Deserialize<TeamConfig>(json, Opt); } catch { return null; } }
    /// 隊長以外的人
    public IEnumerable<TeamMember> Teammates => Members.Where(m => m.AgentType != "team-lead");
}

/// 信箱裡的一則訊息（`inboxes/<to>.json` 是這種東西的陣列）
public sealed record TeamMessage
{
    public string From { get; init; } = "";
    public string Text { get; init; } = "";
    public string? Summary { get; init; }
    public string? Timestamp { get; init; }
    [JsonPropertyName("msg_id")] public string? MsgId { get; init; }
    public string? To { get; init; }                // 不在檔案裡，讀檔時補上信箱主人

    static readonly JsonSerializerOptions Opt = new() { PropertyNameCaseInsensitive = true };
    public static List<TeamMessage> DecodeInbox(string json, string owner)
    {
        try { return (JsonSerializer.Deserialize<List<TeamMessage>>(json, Opt) ?? new()).Select(m => m with { To = owner }).ToList(); }
        catch { return new(); }
    }
    [JsonIgnore] public string Key => MsgId ?? $"{From}>{To ?? ""}@{Timestamp ?? ""}";
}

/// 看板上的一張卡（欄位名與 Mac 的 BoardCard 相同，--board-dump 的 JSON 可以直接比）
public sealed record BoardCard
{
    public string Id { get; set; } = "";
    public BoardColumn Column { get; set; }
    public string Reason { get; set; } = "";       // 為什麼在這欄（一行白話）
    public string Project { get; set; } = "";
    public string Title { get; set; } = "";
    public string? Detail { get; set; }            // 最後一句 AI 說的話、或排隊中的訊息
    public DateTime? LastActivity { get; set; }
    public int Pid { get; set; }
    public string SessionId { get; set; } = "";
    public List<string> Teammates { get; set; } = new();
    public List<TeamMessage> Messages { get; set; } = new();
    public string? Cwd { get; set; }
    public string? Kind { get; set; }
    public SelfReport? Report { get; set; }        // 這一輪的自報（舊的不放）
    public Review? Review { get; set; }            // 這一輪的審核
    public ContextUse? Ctx { get; set; }           // context 用量
    public string? Name { get; set; }              // session 名（SendMessage 的地址）
    public bool Captain { get; set; }              // 是不是隊長
    public List<string> SameProject { get; set; } = new();   // 同專案的其他 session（重工警告）
    public string? Visiting { get; set; }          // 人還住在 project，但最近 cd 去逛的另一個專案（島上畫影分身）
    public bool Unused { get; set; }               // 開了 claude 但從來沒交代過事（島上畫睡覺）

    [JsonIgnore] public bool IsQueued => Id.Contains('#');
}

/// Windows／Mac 兩種路徑都吃（測試沿用 Mac 的 /h 路徑），Windows 路徑一律不分大小寫
public static class BoardPath
{
    // 8.3 短路徑（C:\Users\DEMOUS~1\SLEEPY~1）展開成真的資料夾名：Claude 記的 cwd 是開它時給的寫法，
    // 從捷徑或舊程式用短路徑開的，島名會變「SLEEPY~1」、家目錄也比對不到（10-15 Surface 真 session 實測）。
    // 會碰磁碟，結果記住；資料夾不存在（舊紀錄、Mac 路徑）就原樣
    static readonly System.Collections.Concurrent.ConcurrentDictionary<string, string> longNames = new();
    [System.Runtime.InteropServices.DllImport("kernel32.dll", CharSet = System.Runtime.InteropServices.CharSet.Unicode)]
    static extern uint GetLongPathName(string shortPath, System.Text.StringBuilder longPath, uint size);
    static string LongName(string p) => !OperatingSystem.IsWindows() ? p : longNames.GetOrAdd(p, k =>
    {
        var sb = new System.Text.StringBuilder(1024);
        uint n = GetLongPathName(k, sb, (uint)sb.Capacity);
        return n > 0 && n < sb.Capacity ? sb.ToString() : k;
    });

    static bool IsDrive(string p) => p.Length >= 2 && p[1] == ':' && char.IsAsciiLetter(p[0]);
    static bool IsWin(string p) => IsDrive(p) || p.Contains('\\');

    /// 磁碟代號大寫、斜線統一成反斜線、去掉結尾的分隔符號（根目錄除外）
    public static string Norm(string p)
    {
        p = p.Trim();
        if (IsWin(p))
        {
            p = p.Replace('/', '\\');
            if (IsDrive(p)) p = char.ToUpperInvariant(p[0]) + p[1..];
            if (IsDrive(p) && p.Length == 2) p += "\\";
            while (p.Length > 3 && p.EndsWith('\\') && !(p.StartsWith(@"\\") && p.Count(c => c == '\\') <= 3)) p = p[..^1];
            if (p.Contains('~')) p = LongName(p);
        }
        else while (p.Length > 1 && p.EndsWith('/')) p = p[..^1];
        return p;
    }

    public static bool Same(string? a, string? b) =>
        a != null && b != null && string.Equals(Norm(a), Norm(b), StringComparison.OrdinalIgnoreCase);

    /// 上一層；已經是根目錄（`/`、`C:\`、`\\server\share`）就回 null
    public static string? Parent(string p)
    {
        p = Norm(p);
        if (IsDrive(p) && p.Length <= 3) return null;
        if (p == "/" || p.Length == 0) return null;
        if (p.StartsWith(@"\\") && p.Count(c => c == '\\') <= 3) return null;
        int i = p.LastIndexOfAny(new[] { '\\', '/' });
        if (i < 0) return null;
        if (IsDrive(p) && i == 2) return p[..3];
        if (i == 0) return p[..1];
        return p[..i];
    }

    public static string LastComponent(string p)
    {
        p = Norm(p);
        int i = p.LastIndexOfAny(new[] { '\\', '/' });
        return i < 0 || i == p.Length - 1 ? p : p[(i + 1)..];
    }
}

public static class Board
{
    /// 進行中卻這麼久沒新紀錄 ⇒ 卡住
    public static readonly TimeSpan StuckAfter = TimeSpan.FromMinutes(10);
    public const string HomeName = "（家目錄）";

    /// 一個 session 放哪一欄。`glow` 是 ShoWork 自己的發光狀態（hook 事件，比 status 檔即時）。
    public static (BoardColumn, string) Column(string? status, WorkState? glow, DateTime? lastActivity, DateTime now)
    {
        if (glow == WorkState.Input) return (BoardColumn.Review, "等你回答");
        // status "shell"＝這一輪做完了、但還有背景指令在跑，不算忙
        if (status == "busy" || glow == WorkState.Working)
        {
            if (lastActivity is { } t && now - t > StuckAfter) return (BoardColumn.Stuck, $"{(int)((now - t).TotalSeconds / 60)} 分鐘沒有新動靜");
            return (BoardColumn.Active, "工作中");
        }
        if (glow == WorkState.Done) return (BoardColumn.Review, "做完了，你還沒看");
        return (BoardColumn.Done, status == "shell" ? "閒置（背景指令還在跑）" : "閒置");
    }

    /// 卡片上的摘要：拿掉 Markdown 記號（標題 #、粗體 **、程式碼 `、清單 -、表格 |），換行併成一行
    public static string Plain(string s)
    {
        var lines = new List<string>();
        foreach (var raw in s.Split('\n', '\r', '\u2028', '\u2029', '\u0085', '\v', '\f'))
        {
            if (raw.Length == 0) continue;
            var l = raw.Trim();
            while (l.StartsWith('#') || l.StartsWith('>')) l = l[1..];
            if (l.StartsWith("- ") || l.StartsWith("* ")) l = l[2..];
            if (l.All(c => "|-: ".Contains(c))) continue;           // 表格分隔線（也吃掉空行）
            l = l.Replace("**", "").Replace("`", "").Replace("|", " ").Trim();
            if (l.Length > 0) lines.Add(l);
        }
        return string.Join(" ", lines);
    }

    /// 前 n 個「字」（emoji、組合字不切半，等同 Swift 的 String.prefix）
    public static string Prefix(string s, int n)
    {
        var e = StringInfo.GetTextElementEnumerator(s);
        int k = 0, end = 0;
        while (k < n && e.MoveNext()) { k++; end = e.ElementIndex + ((string)e.Current).Length; }
        return s[..end];
    }
    public static int Length(string s) => new StringInfo(s).LengthInTextElements;

    /// 專案名：往上找 .git 的資料夾名；家目錄本身不算專案
    public static string ProjectName(string? cwd, string home, Func<string, bool> isRepo)
    {
        if (string.IsNullOrEmpty(cwd)) return "（不明）";
        var start = BoardPath.Norm(cwd);
        for (string? p = start; p != null; p = BoardPath.Parent(p))
        {
            if (BoardPath.Parent(p) == null) break;                   // 根目錄不算（同 Mac 的 `/`）
            if (BoardPath.Same(p, home)) break;
            if (isRepo(p)) return BoardPath.LastComponent(p);
        }
        if (BoardPath.Same(start, home)) return HomeName;
        return BoardPath.LastComponent(start);
    }

    public static string StickyProject(IReadOnlyList<CwdMark> marks, string? fallback, string home, Func<string, bool> isRepo, double settle = 300) =>
        Whereabouts(marks, fallback, home, isRepo, settle).Home;

    /// 這個 session「住」哪個專案：在一個地方連續待滿 `settle` 秒才算搬家；cd 出去一下（回家目錄、看別的 repo）
    /// 不算——那是「逛」（visiting，島上畫影分身）。往回找最近一段待夠久的就是住的地方；都沒有就取待最多筆的，家目錄最後才算。
    public static (string Home, string? Visiting) Whereabouts(IReadOnlyList<CwdMark> marks, string? fallback, string home,
                                                              Func<string, bool> isRepo, double settle = 300)
    {
        if (marks.Count == 0) return (ProjectName(fallback, home, isRepo), null);
        var cache = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        var names = marks.Select(m => cache.TryGetValue(m.Cwd, out var n) ? n : cache[m.Cwd] = ProjectName(m.Cwd, home, isRepo)).ToList();
        static bool Eq(string a, string b) => string.Equals(a, b, StringComparison.OrdinalIgnoreCase);
        // 切成一段一段（同一個專案連在一起），每段待多久＝到下一段開始（最後一段到最後一筆）
        var runs = new List<(string Name, int From, int To)>();
        for (int i = 0; i < names.Count; i++)
        {
            if (runs.Count > 0 && Eq(runs[^1].Name, names[i])) runs[^1] = (runs[^1].Name, runs[^1].From, i);
            else runs.Add((names[i], i, i));
        }
        double Lasted(int k)
        {
            var r = runs[k];
            var a = marks[r.From].At;
            var b = k + 1 < runs.Count ? marks[runs[k + 1].From].At : marks[r.To].At;
            if (a == null || b == null) return (r.To - r.From + 1) * 15.0;   // 沒時間戳：一筆當 15 秒
            return (b.Value - a.Value).TotalSeconds;
        }
        var last = runs[^1].Name;
        if (runs.Count == 1) return (last, null);
        for (int k = runs.Count - 1; k >= 0; k--)
        {
            if (Lasted(k) < settle) continue;
            var stay = runs[k].Name;
            return (stay, Eq(last, stay) ? null : last);
        }
        var count = new Dictionary<string, int>(StringComparer.OrdinalIgnoreCase);
        var lastIndex = new Dictionary<string, int>(StringComparer.OrdinalIgnoreCase);
        for (int i = 0; i < names.Count; i++) { count[names[i]] = count.GetValueOrDefault(names[i]) + 1; lastIndex[names[i]] = i; }
        var others = count.Where(kv => kv.Key != HomeName).ToList();
        var pool = others.Count > 0 ? others : count.ToList();
        var best = pool.OrderByDescending(kv => kv.Value).ThenByDescending(kv => lastIndex[kv.Key]).First().Key;
        return (best, Eq(last, best) ? null : last);
    }

    /// 組出整個看板：每個 session 一張卡，再加上排隊中的訊息各一張待辦卡
    public static List<BoardCard> Build(IEnumerable<SessionRecord> sessions, IReadOnlyDictionary<string, TranscriptInfo> transcripts,
                                        IReadOnlyDictionary<int, WorkState> glows, IEnumerable<TeamConfig> teams, IEnumerable<TeamMessage> inbox,
                                        DateTime now, string home, Func<string, bool> isRepo,
                                        IReadOnlyDictionary<string, SelfReport>? reports = null, IReadOnlyDictionary<string, Review>? reviews = null,
                                        IReadOnlyDictionary<string, Decision>? decisions = null, IReadOnlyDictionary<string, ContextUse>? contexts = null)
    {
        var out_ = new List<BoardCard>();
        var teamList = teams.ToList();
        var inboxList = inbox.ToList();
        foreach (var s in sessions.OrderByDescending(x => x.UpdatedAt ?? 0))
        {
            if (s.Entrypoint == "sdk-cli") continue;
            var t = transcripts.GetValueOrDefault(s.SessionId) ?? new TranscriptInfo();
            WorkState? glow = glows.TryGetValue(s.Pid, out var g) ? g : null;
            var b = Column(s.Status, glow, t.LastActivity, now);
            var report = CardRules.Fresh(reports?.GetValueOrDefault(s.SessionId), t.LastPromptAt);
            var (col, why) = CardRules.Column(b, glow, report, decisions?.GetValueOrDefault(s.SessionId), t.LastPromptAt, t.LastActivity);
            var review = reviews?.GetValueOrDefault(s.SessionId) is { } r && (t.LastPromptAt is not { } lp || r.Turn >= lp) ? r : null;
            var (project, visiting) = Whereabouts(t.RecentWorkCwds, t.LastCwd ?? s.Cwd, home, isRepo);
            var team = teamList.FirstOrDefault(x => x.LeadSessionId == s.SessionId);
            var names = team?.Teammates.Select(m => m.Name).ToList() ?? new();
            var msgs = team == null ? new() : inboxList.Where(m => names.Contains(m.From) || names.Contains(m.To ?? "")).ToList();
            out_.Add(new BoardCard
            {
                Id = s.SessionId, Column = col, Reason = why, Project = project,
                Title = t.Title ?? (t.LastPrompt != null ? Prefix(t.LastPrompt, 40) : s.Name ?? "未命名"),
                Detail = t.LastAssistantText != null ? Prefix(Plain(t.LastAssistantText), 240) : null,
                LastActivity = t.LastActivity, Pid = s.Pid, SessionId = s.SessionId,
                Teammates = names, Messages = msgs.TakeLast(5).ToList(),
                Cwd = t.LastWorkCwd ?? t.LastCwd ?? s.Cwd, Kind = s.Kind, Report = report, Review = review,
                Ctx = contexts?.GetValueOrDefault(s.SessionId), Name = s.Name,
                Visiting = col == BoardColumn.Active ? visiting : null,     // 只有正在做事才有影分身，閒著不留幽靈
                Unused = t.LastActivity == null && t.LastPrompt == null,
            });
            for (int i = 0; i < t.Queued.Count; i++)
            {
                var q = t.Queued[i];
                out_.Add(new BoardCard
                {
                    Id = $"{s.SessionId}#q{i}", Column = BoardColumn.Todo, Reason = "排隊中，等這個 AI 有空", Project = project,
                    Title = Prefix(q, 60), Detail = Length(q) > 60 ? q : null, Pid = s.Pid, SessionId = s.SessionId,
                    Cwd = t.LastCwd ?? s.Cwd, Kind = s.Kind,
                });
            }
        }
        return out_;
    }

    /// --board-dump 的 JSON：欄位名跟 Mac 一樣（camelCase、沒有值的不印、中文不跳脫）
    public static readonly JsonSerializerOptions DumpJson = new()
    {
        WriteIndented = true,
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
        Encoder = System.Text.Encodings.Web.JavaScriptEncoder.UnsafeRelaxedJsonEscaping,
        Converters = { new JsonStringEnumConverter(JsonNamingPolicy.CamelCase) },
    };
}

/// showork 名冊（board\names\<sid>.json）：{"name":"Alex","doing":"…","at":"…"}，寫的人是 showork\Core\Nickname.cs
public sealed record NameEntry
{
    public string Name { get; init; } = "";
    public string? Doing { get; init; }
}
