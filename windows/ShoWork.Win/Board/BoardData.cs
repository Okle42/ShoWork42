using System.Globalization;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace ShoWork;

// 11-02 P8 第二輪：戰情中心收件匣／隊長對話／進度條／B1 留言板要讀的資料。Mac 版 ShoWorkCore 逐檔轉寫：
//   CaptainThread.swift（隊長對話）、RunProgress.swift（背景長工作進度）、Answered.swift（使用者已答）、Inbox.swift 的 message／CaptainLaunch。
//   Permit.swift、B1Talk.swift、Handover.swift、Captain.swift 的派工單在 hook 端已經轉寫（showork\Core，namespace ShoWork.Hooks），
//   這裡直接用，只做「轉成卡片／網頁要的形狀」。
// 這個檔不碰 WinForms（測試專案直接連）。檔案位置、欄位名、時間格式跟 Mac 一樣，只是根目錄在 %LOCALAPPDATA%\ShoWork42。

// MARK: - 權限允許／選擇題／計畫確認（Permit.swift）
// 讀寫請求檔與回答檔的邏輯在 hook 端（showork\Core\Permit.cs，ShoWork.Hooks.Permit）；這裡只把它轉成卡片上的 PermitRequest（office2 的 card.permit）

public static class PermitCards
{
    /// 還在等的請求（每個 session 最新的一個）→ 卡片用的形狀
    internal static Dictionary<string, PermitRequest> Pending(DateTime now, string? dir = null) =>
        Hooks.Permit.Pending(now, dir).ToDictionary(kv => kv.Key, kv => Of(kv.Value));

    internal static PermitRequest Of(Hooks.PermitRequest r) => new()
    {
        Id = r.Id, SessionId = r.SessionId, Pid = r.Pid, Tool = r.Tool, Summary = r.Summary, Detail = r.Detail, Cwd = r.Cwd, AlwaysRules = r.AlwaysRules,
        At = r.At, Input = r.Input,
        Questions = r.Questions?.Select(q => new AskQuestion
        {
            Question = q.Question, Header = q.Header, MultiSelect = q.MultiSelect,
            Options = q.Options.Select(o => new AskQuestion.Option(o.Label, o.Description)).ToList(),
        }).ToList(),
    };
}

// MARK: - 隊長對話（CaptainThread.swift）

public sealed record CaptainLine
{
    public enum RoleKind { kang, captain, report, tool }
    public string Id { get; set; } = "";       // 那一行的 uuid（沒有就用時間）
    public DateTime? At { get; set; }
    public RoleKind Role { get; set; }
    public string Text { get; set; } = "";
    public string? Via { get; set; }           // kang：「戰情中心」或「終端機」；report：誰送來的
    public CaptainLine() { }
    public CaptainLine(string id, DateTime? at, RoleKind role, string text, string? via = null) { Id = id; At = at; Role = role; Text = text; Via = via; }
}

public static class CaptainThread
{
    /// 看板送給隊長時包在外面的字（BoardActions.toCaptain）
    public const string BoardPrefix = "【使用者從看板交辦】";
    public const string BoardFromName = "AI工作戰情中心（使用者）";
    public const int Keep = 40;
    public const int KeepFull = 120;
    /// 戰情中心回答別的 AI 時包在外面的字（BoardActions.answer）
    public const string AnswerPrefix = "【使用者從戰情中心回答你的問題】";

    static readonly JsonDocumentOptions Deep = new() { MaxDepth = 512 };

    /// jsonl 尾端（第一行可能不完整，壞的略過）→ 最後 keep 行
    /// `full`：也收每輪中途的話與工具摘要（右側對話窗格看一般 AI 用）
    public static List<CaptainLine> Parse(ReadOnlySpan<byte> tail, bool full = false)
    {
        var out_ = new List<CaptainLine>();
        foreach (var raw in BoardText.Lines(tail))
        {
            if (raw.Length >= 2 << 20) continue;
            JsonDocument doc;
            try { doc = JsonDocument.Parse(raw.ToArray(), Deep); } catch { continue; }
            using (doc)
            {
                var o = doc.RootElement;
                if (o.ValueKind != JsonValueKind.Object) continue;
                var type = S(o, "type");
                var id = S(o, "uuid") ?? Guid.NewGuid().ToString().ToUpperInvariant();
                var at = TranscriptInfo.Iso(S(o, "timestamp"));
                bool hasMsg = o.TryGetProperty("message", out var msg) && msg.ValueKind == JsonValueKind.Object;
                JsonElement content = default;
                if (hasMsg) msg.TryGetProperty("content", out content);
                if (type == "user" && !B(o, "isMeta") && o.TryGetProperty("origin", out var origin) && origin.ValueKind == JsonValueKind.Object)
                {
                    switch (S(origin, "kind"))
                    {
                        case "human":
                            if (UserText(content) is not { } t || t.StartsWith('<')) continue;
                            out_.Add(new CaptainLine(id, at, CaptainLine.RoleKind.kang, t, "終端機"));
                            break;
                        case "peer":
                            var name = S(origin, "name") ?? "";
                            var body = S(origin, "body") ?? PeerBody(UserText(content) ?? "");
                            if (name == BoardFromName || body.StartsWith(BoardPrefix, StringComparison.Ordinal))
                                out_.Add(new CaptainLine(id, at, CaptainLine.RoleKind.kang, BoardTextOf(body), "戰情中心"));
                            else
                            {
                                // 只留看板格式的摘要行（【工作回報】【派工回報】⋯）；AI 之間的自由訊息可能夾帳號、路徑，只說「誰傳來一則訊息」
                                var first = body.Split('\n', '\r').FirstOrDefault(x => x.Length > 0) ?? body;
                                var text = first.StartsWith('【') ? Board.Prefix(first, 160) : $"{(name.Length == 0 ? "其他 AI" : name)} 傳來一則訊息（內容不顯示）";
                                out_.Add(new CaptainLine(id, at, CaptainLine.RoleKind.report, text, name.Length == 0 ? null : name));
                            }
                            break;
                        default: continue;
                    }
                }
                else if (full && type == "assistant" && content.ValueKind == JsonValueKind.Array)
                {
                    int i = 0;
                    foreach (var c in content.EnumerateArray())
                    {
                        var lid = i == 0 ? id : $"{id}#{i}";
                        i++;
                        if (c.ValueKind != JsonValueKind.Object) continue;
                        if (S(c, "type") == "text" && S(c, "text")?.Trim() is { Length: > 0 } t)
                            out_.Add(new CaptainLine(lid, at, CaptainLine.RoleKind.captain, StripNag(t)));
                        else if (S(c, "type") == "tool_use" && S(c, "name") is { } n)
                            out_.Add(new CaptainLine(lid, at, CaptainLine.RoleKind.tool, ToolLine(n, c.TryGetProperty("input", out var inp) ? inp : default)));
                    }
                }
                else if (type == "assistant" && hasMsg && S(msg, "stop_reason") == "end_turn" && content.ValueKind == JsonValueKind.Array)
                {
                    var t = string.Join("\n", content.EnumerateArray().Where(c => c.ValueKind == JsonValueKind.Object && S(c, "type") == "text" && S(c, "text") != null)
                                                                       .Select(c => S(c, "text")!)).Trim();
                    if (t.Length > 0) out_.Add(new CaptainLine(id, at, CaptainLine.RoleKind.captain, StripNag(t)));
                }
            }
        }
        int keep = full ? KeepFull : Keep;
        return out_.Count > keep ? out_.Skip(out_.Count - keep).ToList() : out_;
    }

    /// 工具一行：工具名＋AI 自己寫的說明或檔名（不放指令原文、網址參數、檔案內容）
    public static string ToolLine(string name, JsonElement input)
    {
        string? Str(string k) => input.ValueKind == JsonValueKind.Object && S(input, k) is { Length: > 0 } v ? v : null;
        string? File(string k) => Str(k) is { } p ? p.Replace('\\', '/').Split('/').Last() : null;
        string Tail(string? x) => x != null ? $"：{x}" : "";
        string s = name switch
        {
            "Bash" => "執行指令" + Tail(Str("description")),
            "Read" => "讀檔" + Tail(File("file_path")),
            "Edit" or "MultiEdit" => "修改" + Tail(File("file_path")),
            "Write" => "寫檔" + Tail(File("file_path")),
            "Grep" or "Glob" => "搜尋檔案",
            "WebSearch" => "上網搜尋",
            "WebFetch" => "開網頁" + Tail(Str("url") is { } u && Uri.TryCreate(u, UriKind.Absolute, out var uri) ? uri.Host : null),
            "Agent" or "Task" => "派子代理" + Tail(Str("description")),
            "SendMessage" => "傳訊息給 " + (Str("to") ?? "其他 AI"),
            "AskUserQuestion" => "問你選擇題",
            "ExitPlanMode" => "交計畫給你確認",
            "TodoWrite" or "TaskCreate" or "TaskUpdate" => "更新待辦",
            _ => name.StartsWith("mcp__", StringComparison.Ordinal) ? "用工具 " + string.Join("・", name.Split("__").Skip(1)) : name,
        };
        return Board.Length(s) > 120 ? Board.Prefix(s, 120) + "⋯" : s;
    }

    static string? UserText(JsonElement c)
    {
        if (c.ValueKind == JsonValueKind.String) return c.GetString()!.Trim();
        if (c.ValueKind != JsonValueKind.Array) return null;
        var t = string.Join("\n", c.EnumerateArray().Where(p => p.ValueKind == JsonValueKind.Object && S(p, "type") == "text" && S(p, "text") != null).Select(p => S(p, "text")!));
        return t.Length == 0 ? null : t.Trim();
    }

    /// <cross-session-message …>內文</cross-session-message> 的內文
    public static string PeerBody(string s)
    {
        int a = s.IndexOf("<cross-session-message", StringComparison.Ordinal);
        if (a < 0) return s;
        int gt = s.IndexOf('>', a);
        if (gt < 0) return s;
        var rest = s[(gt + 1)..];
        int end = rest.IndexOf("</cross-session-message>", StringComparison.Ordinal);
        return (end < 0 ? rest : rest[..end]).Trim();
    }

    /// 看板交辦的原話：去掉前綴與後面的守則提醒
    public static string BoardTextOf(string body)
    {
        var t = body.StartsWith(BoardPrefix, StringComparison.Ordinal) ? body[BoardPrefix.Length..]
              : body.StartsWith(AnswerPrefix, StringComparison.Ordinal) ? body[AnswerPrefix.Length..] : body;
        int r = t.IndexOf("\n請照隊長守則", StringComparison.Ordinal);
        if (r >= 0) t = t[..r];
        return t.Trim();
    }

    /// 隊長回答開頭的 miniKang 提醒（hook 要它加的，給使用者看沒意義）：第一段是「🧢 miniKang：」就拿掉
    public static string StripNag(string t)
    {
        if (!t.StartsWith("🧢", StringComparison.Ordinal)) return t;
        var parts = t.Split("\n\n");
        return parts.Length > 1 ? string.Join("\n\n", parts.Skip(1)) : t;
    }

    static string? S(JsonElement o, string k) => o.ValueKind == JsonValueKind.Object && o.TryGetProperty(k, out var v) && v.ValueKind == JsonValueKind.String ? v.GetString() : null;
    static bool B(JsonElement o, string k) => o.TryGetProperty(k, out var v) && v.ValueKind == JsonValueKind.True;
}

// MARK: - 背景長工作的即時進度（RunProgress.swift）

/// AI 自己每隔幾秒寫 `~/.claude/run/progress/<任意檔名>.json`，一個工作一個檔：
/// `{"name":"小明","label":"稽核（畫面）","done":12,"total":37,"updatedAt":1792955900,"pct":32,"eta":"4 分","updated":1792955900}`
/// 超過 10 分鐘沒更新就不算（跟狀態列一致）。網頁自己挑人、組字（ui/core.js 的 RunProgress），這裡只讀檔
public sealed record RunProgress
{
    public string? Name { get; set; }
    public string Label { get; set; } = "";
    public int? Done { get; set; }
    public int? Total { get; set; }
    public string? Eta { get; set; }
    public DateTime UpdatedAt { get; set; }
    /// 0–1
    public double Fraction { get; set; }

    public static readonly TimeSpan StaleAfter = TimeSpan.FromSeconds(600);

    public static RunProgress? Parse(string d)
    {
        try
        {
            if (JsonNode.Parse(d) is not JsonObject o) return null;
            double? Num(string k) => o[k] is JsonValue v && v.TryGetValue<double>(out var x) ? x : null;
            if ((Num("updatedAt") ?? Num("updated")) is not { } t) return null;
            int? done = Num("done") is { } dn ? (int)dn : null, total = Num("total") is { } tn ? (int)tn : null;
            double f;
            if (done is { } a && total is { } b && b > 0) f = (double)a / b;
            else if (Num("pct") is { } p) f = p / 100;
            else return null;
            string? Str(string k) => o[k] is JsonValue v && v.TryGetValue<string>(out var s) && s.Length > 0 ? s : null;
            return new RunProgress
            {
                Name = Str("name"), Label = o["label"] is JsonValue lv && lv.TryGetValue<string>(out var l) ? l : "", Done = done, Total = total, Eta = Str("eta"),
                UpdatedAt = MacMirror.FromSeconds(t), Fraction = Math.Clamp(f, 0, 1),
            };
        }
        catch { return null; }
    }

    public bool Fresh(DateTime now) => now - UpdatedAt <= StaleAfter;

    public static string Dir => Environment.GetEnvironmentVariable("SHOWORK_RUN_PROGRESS") is { Length: > 0 } d ? d : Path.Combine(BoardReader.DefaultClaudeDir, "run", "progress");

    public static List<RunProgress> Load(string? dir = null)
    {
        var d = dir ?? Dir;
        try { return Directory.Exists(d) ? Directory.GetFiles(d, "*.json").Select(f => BoardText.Read(f) is { } j ? Parse(j) : null).OfType<RunProgress>().ToList() : new(); }
        catch { return new(); }
    }
}

// MARK: - Agent交流互動板（B1Talk.swift；讀寫在 hook 端 showork\Core\B1.cs）

public static class B1Json
{
    /// 給網頁的 b1Posts（舊的在前；網頁要的是 {id, at, name, project, text, re}，不送 sid）
    public static JsonArray All() => new(Hooks.B1Board.All().Select(p => (JsonNode?)new JsonObject
    {
        ["id"] = p.Id, ["at"] = MacMirror.Encode(p.At), ["name"] = p.Name, ["project"] = p.Project, ["text"] = p.Text, ["re"] = p.Re,
    }).ToArray());
}

// MARK: - 使用者已答（Answered.swift）

public static class Answered
{
    public const string Prefix = "【使用者已答】";

    /// 「【使用者已答】Ruby：要 push 嗎？→好，push」
    public static string Relay(string name, string? question, string answer)
    {
        var q = question?.Trim() is { Length: > 0 } x ? x : "（卡片上沒有問題文字）";
        return $"{Prefix}{name}：{q}→{answer}。這題不用再問使用者；隊長卡片上同一題已自動清掉。";
    }

    /// 比對用：去空白、全形半形問號與句尾標點、不分大小寫
    static string Normal(string s) => new(s.ToLowerInvariant().Where(c => !char.IsWhiteSpace(c) && !"？?。.！!：:「」\"'".Contains(c)).ToArray());

    public static bool Same(string? a, string? b)
    {
        if (a == null || b == null) return false;
        var x = Normal(a);
        return x.Length > 0 && x == Normal(b);
    }

    /// 改寫隊長的卡片檔（board/cards/<sid>.json）：掛著同一題就拿掉 ask／options；有清掉回 true。
    /// 用 JsonNode 改，其他欄位（Windows 的 SelfReport 沒有的）原樣留著
    public static bool ClearCaptainCard(string sid, string? question, string? dir = null)
    {
        var path = Path.Combine(dir ?? Path.Combine(Wire.SupportDir, "board", "cards"), sid + ".json");
        if (BoardText.Read(path) is not { } j) return false;
        try
        {
            if (JsonNode.Parse(j) is not JsonObject o || !Same(o["ask"]?.GetValue<string>(), question)) return false;
            o.Remove("ask"); o.Remove("options");
            return BoardText.WriteAtomic(path, o.ToJsonString(BoardText.Relaxed));
        }
        catch { return false; }
    }
}

// MARK: - 收件匣送出的字、隊長開機（Inbox.swift）

public static class InboxText
{
    /// 送給 AI 的那句話（選項按鈕和打字同一條路）
    public static string Message(string text) => text.Replace("\r\n", " ").Replace('\n', ' ').Replace('\r', ' ').Trim();
}

/// 隊長：戰情中心「交給隊長」找不到隊長時，自己開一個背景隊長。
/// 10-26 Kang：值班用 Opus（Fable 隊長一週佔 24% 用量），要做重大判斷時再手動 /model 升 Fable；設定的 captain.model 仍可覆寫
public static class CaptainLaunch
{
    public const string DefaultModel = "claude-opus-5-5";
    public const string ModelKey = "captain.model";

    /// 背景隊長的第一句話：登記、守則，以及它看不到終端機 ⇒ 所有要跟使用者講的都走 showork card
    public static string Bootstrap(string showork, string task) => $"""
        你是 AI 工作戰情中心的隊長（背景 session，使用者看不到你的終端機）。
        1. 先跑："{showork}" captain（登記成隊長並印出守則），照守則做事：先看 "{showork}" roster，選人後用 "{showork}" task add 派工；同專案只派一個；小事自己做。
        2. 你要跟使用者講的話，一律用 "{showork}" card 回報（--summary 寫結果；要他決定就 --status review --ask "<問題>" --options "<選項1>|<選項2>"）。他在戰情中心看卡片、按選項回答你。
        3. 之後使用者從戰情中心交辦的事，會以【使用者從看板交辦】的訊息送進來，一樣照守則處理。
        使用者交辦的第一件事：{task}
        """;
}

// MARK: - 小工具（讀寫文字檔）

public static class BoardText
{
    public static readonly JsonSerializerOptions Relaxed = new() { Encoder = System.Text.Encodings.Web.JavaScriptEncoder.UnsafeRelaxedJsonEscaping };

    /// 別人可能正在寫（Claude Code、hook）：允許同時寫／換名
    public static string? Read(string path)
    {
        try
        {
            if (!System.IO.File.Exists(path)) return null;
            using var fs = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
            using var sr = new StreamReader(fs);
            return sr.ReadToEnd();
        }
        catch { return null; }
    }

    /// 先寫暫存檔再換名（同 Swift 的 .atomic）
    public static bool WriteAtomic(string path, string text)
    {
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(path)!);
            var tmp = path + $".{Environment.ProcessId}.tmp";
            System.IO.File.WriteAllText(tmp, text, new UTF8Encoding(false));
            System.IO.File.Move(tmp, path, overwrite: true);
            return true;
        }
        catch { return false; }
    }

    public static void AppendLine(string path, string line)
    {
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(path)!);
            System.IO.File.AppendAllText(path, line + "\n", new UTF8Encoding(false));
        }
        catch { }
    }

    /// 以 \n 切行（去掉行尾 \r），空行略過
    public static List<byte[]> Lines(ReadOnlySpan<byte> d)
    {
        var out_ = new List<byte[]>();
        while (d.Length > 0)
        {
            int n = d.IndexOf((byte)'\n');
            var line = n < 0 ? d : d[..n];
            d = n < 0 ? ReadOnlySpan<byte>.Empty : d[(n + 1)..];
            if (line.Length > 0 && line[^1] == (byte)'\r') line = line[..^1];
            if (line.Length > 0) out_.Add(line.ToArray());
        }
        return out_;
    }

    /// 檔案尾端最多 n 位元組（從某行中間開始也沒關係：第一行壞掉會被略過）
    public static byte[] Tail(string path, long n)
    {
        try
        {
            using var fs = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
            fs.Seek(Math.Max(0, fs.Length - n), SeekOrigin.Begin);
            using var ms = new MemoryStream();
            fs.CopyTo(ms);
            return ms.ToArray();
        }
        catch { return Array.Empty<byte>(); }
    }

    /// 檔案的戳記（mtime＋大小），沒變就用快取
    public static string Stamp(string path)
    {
        try { var f = new FileInfo(path); return f.Exists ? $"{f.LastWriteTimeUtc.Ticks}:{f.Length}" : "-"; } catch { return "-"; }
    }
}
