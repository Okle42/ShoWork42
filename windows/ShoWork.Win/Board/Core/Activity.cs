using System.Text.Json.Nodes;

namespace ShoWork;

// Mac 版 Sources/ShoWorkCore/Activity.swift 的轉寫（11-02 P8）：卡片上的四件事——AI 現在在做哪一類動作、卡住／等你的原因、
// 進行中的子 agent、累計 token。另外放卡片上 Mac 有、Windows 原本沒有的欄位型別（PermitRequest、AskQuestion、CaptainTask），
// 讓 office2 的 card 跟 Mac 同形狀。
// 11-02 P8 第二輪：BoardReader 照 Mac 從對話紀錄算這四件事（TranscriptInfo 的 pending／asyncAgents＋TokenTally 增量）。

/// AI「現在」在做的工具動作（只有進行中的卡片有意義，其餘一律 none）
public enum AIActivity { None, Reading, Editing, Running, Searching, Thinking, Delegating }

public static class AIActivities
{
    /// 工具名 → 動作分類；不認得的（Bash、MCP 工具、Monitor⋯）都算「執行」
    public static AIActivity of(string tool, string? subagentType = null) => tool switch
    {
        "Read" or "Grep" or "Glob" or "NotebookRead" or "WebFetch" or "LS" or "ListMcpResourcesTool" or "ReadMcpResourceTool" => AIActivity.Reading,
        "Edit" or "Write" or "MultiEdit" or "NotebookEdit" => AIActivity.Editing,
        "WebSearch" or "ToolSearch" => AIActivity.Searching,
        "Agent" or "Task" => subagentType == "Explore" ? AIActivity.Searching : AIActivity.Delegating,
        "Workflow" => AIActivity.Delegating,
        "AskUserQuestion" or "ExitPlanMode" => AIActivity.Thinking,     // 在問你；正常會被光暈判成「等你回答」，不會落到進行中
        _ => tool.ToLowerInvariant().Contains("search") ? AIActivity.Searching : AIActivity.Running,
    };
}

/// 卡住／等你的原因（判不出就是 nil，不硬編；unknown 留給畫面相容，解析不會產生）
public enum BlockedReason { Permission, RateLimit, ApiError, TestRun, Build, Install, Unknown }

public static class BlockedReasons
{
    /// Swift 的 rawValue（＝case 名稱）
    public static string rawValue(this BlockedReason r) => MacMirror.Camel(r.ToString());
    public static readonly BlockedReason[] allCases = Enum.GetValues<BlockedReason>();

    /// 跑很久的 Bash 指令看關鍵字分類（測試 → 建置 → 安裝的順序；`swift build && swift test` 算測試）
    public static BlockedReason? of(string command)
    {
        var words = System.Text.RegularExpressions.Regex.Split(command.ToLowerInvariant(), @"[^\p{L}\p{N}_]+").Where(w => w.Length > 0).ToHashSet();
        if (words.Overlaps(new[] { "test", "tests", "pytest", "jest", "vitest", "xctest", "unittest", "rspec" })) return BlockedReason.TestRun;
        if (words.Overlaps(new[] { "build", "xcodebuild", "make", "cmake", "ninja", "gradle", "gradlew", "bazel", "compile", "archive" })) return BlockedReason.Build;
        if (words.Overlaps(new[] { "install", "pip", "pip3", "brew", "npm", "pnpm", "yarn", "bun", "pod", "apt", "uv" })
            && (words.Contains("install") || words.Contains("add") || words.Contains("i") || words.Contains("ci") || words.Contains("sync"))) return BlockedReason.Install;
        return null;
    }

    /// API 錯誤那一行 → 額度（429／rate_limit／usage limit）或其他 API 錯誤
    public static BlockedReason ofApiError(JsonObject o, string? text)
    {
        var err = (o["error"] is JsonValue e && e.TryGetValue<string>(out var es) ? es : "").ToLowerInvariant();
        var status = o["apiErrorStatus"]?.ToString();
        var t = (text ?? "").ToLowerInvariant();
        if (err.Contains("rate_limit") || status == "429" || o["quotaLimits"] != null
            || t.Contains("rate limit") || t.Contains("usage limit") || t.Contains("session limit") || t.Contains("429"))
            return BlockedReason.RateLimit;
        return BlockedReason.ApiError;
    }
}

/// 進行中的子 agent
public sealed record SubagentInfo
{
    public string Description { get; set; } = "";     // tool input 的 description（截 30 字）
    public string? SubagentType { get; set; }         // general-purpose、Explore⋯
    public bool Background { get; set; }              // run_in_background：主 session 停了它還在跑
    public SubagentInfo() { }
    public SubagentInfo(string description, string? subagentType = null, bool background = false)
    {
        Description = Board.Prefix(description, 30); SubagentType = subagentType; Background = background;
    }
}

/// 這個 session 累計的 token（不算錢：訂閱制）
public sealed record TokenUsage
{
    public int Input { get; set; }
    public int Output { get; set; }
    public int CacheCreation { get; set; }
    public int CacheRead { get; set; }
    public int LastTurnOutput { get; set; }        // 你最後一次送出訊息之後，AI 產出的 output token
    public int total => Input + Output + CacheCreation + CacheRead;
    public TokenUsage() { }
    public TokenUsage(int input = 0, int output = 0, int cacheCreation = 0, int cacheRead = 0, int lastTurnOutput = 0)
    { Input = input; Output = output; CacheCreation = cacheCreation; CacheRead = cacheRead; LastTurnOutput = lastTurnOutput; }
}

/// token 增量累加（Mac TokenTally 的轉寫）：整個檔案從頭掃一次，之後只餵新增的完整行。
/// 先用字串找 `"role":"assistant"`，讀圖的 user 行一行幾百 KB，直接跳過。
/// 11-02 P8：背景 agent／workflow 也照 Mac 整個檔案一起追（只看尾端 512KB 會漏掉啟動那行）
public sealed class TokenTally
{
    public TokenUsage usage { get; } = new();
    readonly HashSet<string> seen = new();
    public List<TranscriptInfo.AsyncAgent> asyncAgents { get; } = new();

    /// `lines` 必須是完整的行（最後一行沒寫完的不要傳進來）
    public void consume(IEnumerable<string> lines)
    {
        foreach (var l in lines) if (l.Length > 0) line(l);
    }

    void line(string l)
    {
        if (l.Contains("\"status\":\"async_launched\"")) { launched(l); return; }
        if (l.Contains("<task-id>") && !l.Contains("\"role\":\"assistant\"")) notified(l);
        if (l.Contains("\"role\":\"assistant\"") && l.Contains("\"usage\""))
        {
            try
            {
                if (JsonNode.Parse(l) is not JsonObject o || o["isSidechain"]?.ToString() == "true" || o["message"] is not JsonObject m || m["usage"] is not JsonObject u) return;
                if (m["id"] is JsonValue idv && idv.TryGetValue<string>(out var id) && !seen.Add(id)) return;
                int i(string k) => u[k] is JsonValue v && v.TryGetValue<double>(out var d) ? (int)d : 0;
                usage.Input += i("input_tokens"); usage.Output += i("output_tokens");
                usage.CacheCreation += i("cache_creation_input_tokens"); usage.CacheRead += i("cache_read_input_tokens");
                usage.LastTurnOutput += i("output_tokens");
            }
            catch { }
        }
        else if (l.Length < 256 * 1024 && l.Contains("\"type\":\"user\"") && !l.Contains("\"tool_use_id\""))
        {
            try
            {
                if (JsonNode.Parse(l) is not JsonObject o || o["type"]?.ToString() != "user" || o["isMeta"]?.ToString() == "true"
                    || o["isSidechain"]?.ToString() == "true" || o["isCompactSummary"]?.ToString() == "true" || o["message"] is not JsonObject m) return;
                if (isPrompt(m["content"])) usage.LastTurnOutput = 0;
            }
            catch { }
        }
    }

    /// tool_result 的 toolUseResult.status＝async_launched：記住 agentId／taskId（description／workflowName 都在這一行）
    void launched(string l)
    {
        try
        {
            if (JsonNode.Parse(l) is not JsonObject o || o["type"]?.ToString() != "user" || o["isSidechain"]?.ToString() == "true"
                || o["toolUseResult"] is not JsonObject r || r["status"]?.ToString() != "async_launched") return;
            var id = (r["agentId"] ?? r["taskId"]) is JsonValue iv && iv.TryGetValue<string>(out var x) ? x : null;
            if (id == null || asyncAgents.Any(a => a.Id == id)) return;
            string? S(JsonNode? n) => n is JsonValue v && v.TryGetValue<string>(out var t) ? t : null;
            var desc = S(r["description"] ?? r["workflowName"] ?? r["summary"]) ?? "";
            var at = TranscriptInfo.Iso(S(o["timestamp"]));
            asyncAgents.Add(new TranscriptInfo.AsyncAgent(id, new SubagentInfo(desc, S(r["taskType"]), background: true), at));
        }
        catch { }
    }

    /// queue-operation 或 user 行的 <task-notification><task-id>X</task-id>：X 做完了
    void notified(string l)
    {
        if (asyncAgents.Count == 0) return;
        try
        {
            if (JsonNode.Parse(l) is not JsonObject o || o["isSidechain"]?.ToString() == "true") return;
            var c = (o["content"] is JsonValue cv && cv.TryGetValue<string>(out var cs) ? cs : null)
                    ?? (o["message"]?["content"] is JsonValue mv && mv.TryGetValue<string>(out var ms) ? ms : null) ?? "";
            if (TranscriptInfo.TaskId(c) is { } id) asyncAgents.RemoveAll(a => a.Id == id);
        }
        catch { }
    }

    /// 你親手送出的訊息（不是工具結果、不是系統通知）
    static bool isPrompt(JsonNode? content)
    {
        if (content is JsonValue v && v.TryGetValue<string>(out var s)) return s.Length > 0 && !TranscriptInfo.IsSystemMessage(s);
        if (content is not JsonArray parts) return false;
        if (parts.Any(p => p?["type"]?.ToString() == "tool_result")) return false;
        return parts.Any(p => p?["type"]?.ToString() == "text" && p["text"] is JsonValue t && t.TryGetValue<string>(out var ts) && !TranscriptInfo.IsSystemMessage(ts));
    }
}

/// 終端機開著的權限對話框（Mac Permit.swift 的 PermitRequest；Windows 還沒做 permit，示範卡片才有）
public sealed record PermitRequest
{
    public string Id { get; set; } = "";
    public string SessionId { get; set; } = "";
    public int? Pid { get; set; }              // AI 行程（死了就收掉）
    public string Tool { get; set; } = "";
    public string Summary { get; set; } = "";  // 要執行的東西：指令、檔案路徑、網址⋯
    public string? Detail { get; set; }        // AI 自己寫的說明（Bash 的 description）
    public string? Cwd { get; set; }
    public string? AlwaysRules { get; set; }   // 「一律允許」要套的 permission_suggestions（addRules，JSON 陣列原文）
    public DateTime At { get; set; }
    public List<AskQuestion>? Questions { get; set; }   // AskUserQuestion 的題目（10-25）
    public string? Input { get; set; }                  // AskUserQuestion／ExitPlanMode 的 tool_input 原文
}

/// AskUserQuestion 的一題
public sealed record AskQuestion
{
    public sealed record Option
    {
        public string Label { get; set; } = "";
        public string? Description { get; set; }
        public Option() { }
        public Option(string label, string? description = null) { Label = label; Description = description; }
    }
    public string Question { get; set; } = "";
    public string? Header { get; set; }
    public bool MultiSelect { get; set; }
    public List<Option> Options { get; set; } = new();
}

/// 隊長派工單（Mac Captain.swift 的 CaptainTask；卡片上的 tasks。Windows 的看板還不派工，一律空的）
public sealed record CaptainTaskInfo
{
    public enum TaskState { sent, working, review, done, blocked, cancelled }
    public string Id { get; set; } = "";
    public string From { get; set; } = "";             // 隊長的 sessionId
    public string To { get; set; } = "";               // 對方的 session 名（SendMessage 的地址）
    public string? ToSession { get; set; }             // 派出當下對方的 sessionId
    public string? Project { get; set; }
    public string Text { get; set; } = "";
    public TaskState State { get; set; }
    public string? Summary { get; set; }               // 對方最後一次回報的一句話
    public string? Ask { get; set; }
    public DateTime CreatedAt { get; set; }
    public DateTime UpdatedAt { get; set; }
    public string? ThenTo { get; set; }                // 做完（done）後自動交給誰（接力）
    public string? ThenText { get; set; }              // 交給下一棒的任務
    public string? FollowUp { get; set; }              // 已經開出的下一棒單號
    public string? After { get; set; }                 // 這張是哪張單的下一棒
    public TaskState? Notified { get; set; }           // 已經通知隊長到哪個狀態（同一個狀態只通知一次）
    public string? SendError { get; set; }             // 直送失敗的原因
}
