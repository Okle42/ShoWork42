using System.Globalization;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace ShoWork;

// 戰情中心 P2 的資料：AI 自報（showork card）、審核、你的決定。Mac 版 Sources/ShoWorkCore/Card.swift 的移植（只搬看板要讀的部分）。
// 三種東西都以 sessionId 為鍵存在 %LOCALAPPDATA%\ShoWork42\board\{cards,reviews,decisions}\<sid>.json（Mac 是 Application Support）。
// Windows 目前沒有 `showork card`、沒有審核員、看板沒有放行／丟待辦按鈕 ⇒ 這三個資料夾通常不存在，讀到空的就照 P1 規則分欄。
// 「這一輪」的判準：記錄時間晚於該 session 最後一次你送出訊息的時間才算數，舊的一律不用。

public enum ReportStatus { Working, Review, Done, Blocked }

/// AI 每輪結束時用 `showork card` 回報的東西
public sealed record SelfReport
{
    public ReportStatus Status { get; init; }
    public int? Progress { get; init; }          // 0–100
    public int? Confidence { get; init; }        // 0–100
    public string? Summary { get; init; }
    public string? Ask { get; init; }            // 要你決定／回答的事
    public string? Report { get; init; }         // 報告檔路徑
    public string? Task { get; init; }           // 隊長派工單號（--task）
    public DateTime At { get; init; }

    public static int Clamp(int v) => Math.Clamp(v, 0, 100);

    /// `showork card` 的參數 → 回報；格式錯回傳錯誤訊息（給 AI 看得懂的中文）。Windows 還沒有 card 子指令，先跟 Mac 對齊規則。
    public static (SelfReport? Ok, string? Error) Parse(IReadOnlyList<string> args, DateTime now)
    {
        ReportStatus? status = null; int? p = null, c = null; string? s = null, ask = null, r = null, task = null;
        for (int i = 0; i < args.Count; i += 2)
        {
            var k = args[i];
            if (i + 1 >= args.Count) return (null, $"{k} 後面少了值");
            var v = args[i + 1];
            switch (k)
            {
                case "--status":
                    if (v is not ("working" or "review" or "done" or "blocked")) return (null, "--status 只能是 working／review／done／blocked");
                    status = Enum.Parse<ReportStatus>(v, ignoreCase: true); break;
                case "--progress":
                    if (!int.TryParse(v.Trim('%', ' '), out var px)) return (null, "--progress 要是 0–100 的數字");
                    p = px; break;
                case "--confidence":
                    if (!int.TryParse(v.Trim('%', ' '), out var cx)) return (null, "--confidence 要是 0–100 的數字");
                    c = cx; break;
                case "--summary": s = v; break;
                case "--ask": ask = v.Length == 0 ? null : v; break;
                case "--report": r = v.Length == 0 ? null : v; break;
                case "--task": task = v.Length == 0 ? null : v; break;
                default: return (null, $"不認得的參數 {k}");
            }
        }
        if (status == null) return (null, "缺 --status");
        return (new SelfReport { Status = status.Value, Progress = p.HasValue ? Clamp(p.Value) : null, Confidence = c.HasValue ? Clamp(c.Value) : null,
                                 Summary = s, Ask = ask, Report = r, Task = task, At = now }, null);
    }
}

/// 審核員（另一個 AI）的意見。Windows 沒有審核員，只讀（Mac 那邊同步過來的檔案也讀得懂）。
public sealed record Review
{
    public int? Progress { get; init; }
    public int? Confidence { get; init; }
    public string Verdict { get; init; } = "concern";   // pass／concern／fail
    public List<string> Issues { get; init; } = new();
    public DateTime Turn { get; init; }                  // 審的是哪一輪（那輪最後活動時間）
    public DateTime At { get; init; }
    public string Model { get; init; } = "";
    public double? CostUSD { get; init; }
    public string? Error { get; init; }
}

public enum DecisionAction { Approve, Park }

/// 你在看板上的決定（session 一有新動靜就失效）
public sealed record Decision
{
    public DecisionAction Action { get; init; }
    public string? Note { get; init; }
    public DateTime At { get; init; }
}

/// 看板存檔的 JSON：時間一律 ISO 8601 帶毫秒（Mac 10-08：只存到秒時，「這一輪」永遠比實際早一點）
public static class BoardJson
{
    public static readonly JsonSerializerOptions Options = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        PropertyNameCaseInsensitive = true,
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
        Converters = { new JsonStringEnumConverter(JsonNamingPolicy.CamelCase), new IsoDate() },
    };

    public static T? Decode<T>(string json) where T : class { try { return JsonSerializer.Deserialize<T>(json, Options); } catch { return null; } }
    public static string Encode<T>(T v) => JsonSerializer.Serialize(v, Options);

    public static string Format(DateTime d) => d.ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss.fff'Z'", CultureInfo.InvariantCulture);

    /// `2026-10-08T10:16:42Z`、`…42.056Z` 都吃；Swift 的 Date 是秒，這裡一律轉 UTC
    sealed class IsoDate : JsonConverter<DateTime>
    {
        public override DateTime Read(ref Utf8JsonReader r, Type t, JsonSerializerOptions o) =>
            TranscriptInfo.Iso(r.GetString()) ?? throw new JsonException("bad date");
        public override void Write(Utf8JsonWriter w, DateTime v, JsonSerializerOptions o) => w.WriteStringValue(Format(v));
    }
}

public static class CardRules
{
    /// 自報＋決定＋光暈 → 欄位。P1 的規則（Board.Column）是底，這裡疊上這一輪的新資訊。
    public static (BoardColumn, string) Column((BoardColumn, string) b, WorkState? glow, SelfReport? report, Decision? decision,
                                               DateTime? lastPrompt, DateTime? lastActivity)
    {
        if (glow == WorkState.Input) return b;                                   // 等你回答永遠最優先
        if (b.Item1 is BoardColumn.Active or BoardColumn.Stuck)
        {
            if (Fresh(report, lastPrompt) is { Status: ReportStatus.Blocked } r0) return (BoardColumn.Stuck, $"AI 自報卡住：{r0.Summary ?? ""}");
            return b;
        }
        if (decision != null && decision.At >= (lastActivity ?? DateTime.MinValue))
            return decision.Action == DecisionAction.Approve
                ? (BoardColumn.Done, "你已放行")
                : (BoardColumn.Todo, "你丟回待辦" + (decision.Note != null ? $"：{decision.Note}" : ""));
        if (Fresh(report, lastPrompt) is not { } r) return b;
        return r.Status switch
        {
            ReportStatus.Review => (BoardColumn.Review, r.Ask != null ? $"要你決定：{r.Ask}" : "AI 請你看過"),
            ReportStatus.Blocked => (BoardColumn.Stuck, $"AI 自報卡住：{r.Summary ?? ""}"),
            ReportStatus.Done => r.Ask != null ? (BoardColumn.Review, $"要你決定：{r.Ask}") : (BoardColumn.Done, "AI 自報完成"),
            _ => b,
        };
    }

    public static SelfReport? Fresh(SelfReport? r, DateTime? lastPrompt) =>
        r == null || (lastPrompt is { } p && r.At < p) ? null : r;

    /// 需不需要（再）審：在待審、還沒審過這一輪（Windows 沒有審核員，留著給之後用，規則跟 Mac 一樣）
    public static bool NeedsReview(BoardColumn column, Review? review, DateTime? turn)
    {
        if (column != BoardColumn.Review || turn == null) return false;
        if (review == null) return true;
        return review.Turn.AddSeconds(1) < turn.Value;          // 舊檔只存到秒：差不到 1 秒算同一輪
    }
}

/// 帳號流量（訂閱額度）。Claude Code 只把它交給 statusLine，要由 statusLine 腳本存成快照檔
/// `~/.claude/cache/rate_limits.json`：`{"rate_limits":{"five_hour":{"used_percentage":27,"resets_at":1791457200},…},"at":"2026-10-08 18:12:08"}`。
/// Surface 10-15：沒有這個檔（Windows 的 statusLine 沒在存），流量表就不顯示。
public sealed record RateLimits
{
    public sealed record Window(double Used, DateTime? ResetsAt);
    public Window? FiveHour { get; init; }
    public Window? SevenDay { get; init; }
    public DateTime? SnapshotAt { get; init; }

    public static RateLimits? Parse(string json)
    {
        try
        {
            using var doc = JsonDocument.Parse(json);
            if (!doc.RootElement.TryGetProperty("rate_limits", out var rl) || rl.ValueKind != JsonValueKind.Object) return null;
            Window? W(string k)
            {
                if (!rl.TryGetProperty(k, out var x) || x.ValueKind != JsonValueKind.Object
                    || !x.TryGetProperty("used_percentage", out var u) || u.ValueKind != JsonValueKind.Number) return null;
                DateTime? reset = x.TryGetProperty("resets_at", out var ra) && ra.ValueKind == JsonValueKind.Number
                    ? DateTime.UnixEpoch.AddSeconds(ra.GetDouble()) : null;
                return new Window(u.GetDouble(), reset);
            }
            DateTime? at = null;
            // statusLine 腳本寫的是本機時間、不帶時區
            if (doc.RootElement.TryGetProperty("at", out var a) && a.ValueKind == JsonValueKind.String
                && DateTime.TryParseExact(a.GetString(), "yyyy-MM-dd HH:mm:ss", CultureInfo.InvariantCulture, DateTimeStyles.AssumeLocal, out var ad))
                at = ad.ToUniversalTime();
            var r = new RateLimits { FiveHour = W("five_hour"), SevenDay = W("seven_day"), SnapshotAt = at };
            return r.FiveHour == null && r.SevenDay == null ? null : r;
        }
        catch { return null; }
    }

    /// 重置時間已過的視窗，數字已不準，當成 0%（下一次 statusLine 更新就會補正）
    public RateLimits Current(DateTime now) => this with
    {
        FiveHour = FiveHour?.ResetsAt is { } t5 && t5 <= now ? new Window(0, null) : FiveHour,
        SevenDay = SevenDay?.ResetsAt is { } t7 && t7 <= now ? new Window(0, null) : SevenDay,
    };
}

/// 每個 session 的 context 用量。Claude Code 只交給 statusLine，由狀態列腳本存成
/// `~/.claude/cache/ctx/<sessionId>.json`：`{"used_percentage": 44, "total_input_tokens": 439517, "at": 1791475515.98}`。
/// Surface 10-15：沒有 cache\ctx（同上），🧠 就不顯示。
public sealed record ContextUse
{
    public double Percent { get; init; }
    public int? Tokens { get; init; }
    public DateTime? At { get; init; }

    public static ContextUse? Parse(string json)
    {
        try
        {
            using var doc = JsonDocument.Parse(json);
            var o = doc.RootElement;
            if (!o.TryGetProperty("used_percentage", out var p) || p.ValueKind != JsonValueKind.Number) return null;
            return new ContextUse
            {
                Percent = p.GetDouble(),
                Tokens = o.TryGetProperty("total_input_tokens", out var t) && t.ValueKind == JsonValueKind.Number ? (int)t.GetDouble() : null,
                At = o.TryGetProperty("at", out var a) && a.ValueKind == JsonValueKind.Number ? DateTime.UnixEpoch.AddSeconds(a.GetDouble()) : null,
            };
        }
        catch { return null; }
    }
}

/// 隊長旗標與同專案重工警告（Mac 版 Captain.swift 的 annotate；派工單不搬，Windows 唯讀看板沒有派工）。
/// 誰是隊長存在 board\captain.json（Mac 由 `showork captain` 寫）；Windows 還沒有這個子指令 ⇒ 通常沒有隊長。
public static class Captain
{
    /// 不算「專案」的歸屬（家目錄、看不出來的），不做重工比對
    public static bool IsRealProject(string p) => !p.StartsWith('（');

    /// 同專案多開：sessionId → 同專案的其他 session 名。隊長自己不算（它本來就會到處看）。
    public static Dictionary<string, List<string>> SameProject(IEnumerable<BoardCard> cards, string? captain)
    {
        var live = cards.Where(c => !c.IsQueued && c.SessionId != captain && IsRealProject(c.Project)).ToList();
        var out_ = new Dictionary<string, List<string>>();
        foreach (var c in live)
        {
            var others = live.Where(o => o.SessionId != c.SessionId && string.Equals(o.Project, c.Project, StringComparison.OrdinalIgnoreCase))
                             .Select(o => o.Name ?? o.SessionId[..Math.Min(8, o.SessionId.Length)]).OrderBy(x => x, StringComparer.Ordinal).ToList();
            if (others.Count > 0) out_[c.SessionId] = others;
        }
        return out_;
    }

    public static List<BoardCard> Annotate(IEnumerable<BoardCard> cards, string? captain)
    {
        var list = cards.ToList();
        var dup = SameProject(list, captain);
        foreach (var c in list.Where(c => !c.IsQueued))
        {
            c.Captain = c.SessionId == captain;
            c.SameProject = dup.GetValueOrDefault(c.SessionId) ?? new();
        }
        return list;
    }
}
