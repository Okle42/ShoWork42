using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace ShoWork.Hooks;

// 權限允許搬到戰情中心（Mac 版 Sources/ShoWorkCore/Permit.swift 的移植，檔案格式一模一樣）：
// PermissionRequest hook（`showork permit`）把「要執行什麼」寫成一個檔，戰情中心收件匣顯示「允許／一律允許／拒絕」，
// 按下去寫回答檔，hook 讀到就回 decision 給 Claude Code。
// 10-21 實測（Mac 2.1.306，虛擬終端）：
//   • 終端機的允許對話框和 hook 同時出現；hook 等 15 秒才回 allow，Claude 照樣接受 ⇒ 兩邊都能按
//   • 終端機先按：hook 不會被砍，之後回的 decision 被忽略 ⇒ hook 自己看 transcript 出現這個 tool_use 的結果就收掉
// 檔案都在 board\permits\：<id>.json（請求）、<id>.answer.json（回答）。
// 10-25 選擇題與計畫確認也走這條：AskUserQuestion／ExitPlanMode 都會跳 PermissionRequest，
//   回 allow＋updatedInput（原輸入＋answers）⇒ AI 收到的 tool_result 跟真人在終端機選的一模一樣；ExitPlanMode 回 allow＝核准計畫。
//   從戰情中心替使用者回答的，每一筆記在 board\permits\answers.jsonl（欄位同 releases.jsonl）。
// 回答檔是戰情中心（Windows：ShoWork.Win 的 BoardActions.permit，另一個 agent 做）寫的：{"decision":"allow|always|deny","message":…,"answers":{題目:[選的]}}

/// AskUserQuestion 的一題
sealed class AskQuestion
{
    public sealed class Option
    {
        public string Label = "";
        public string? Description;
    }
    public string Question = "";
    public string? Header;
    public bool MultiSelect;
    public List<Option> Options = new();

    /// tool_input.questions → 題目（格式不對的題目略過）
    public static List<AskQuestion> Parse(JsonNode? input)
    {
        var out_ = new List<AskQuestion>();
        if (input?["questions"] is not JsonArray qs) return out_;
        foreach (var q in qs)
        {
            if (q.Str("question") is not { Length: > 0 } text) continue;
            var opts = new List<Option>();
            if (q?["options"] is JsonArray os)
                foreach (var o in os)
                    if (o.Str("label") is { } l) opts.Add(new Option { Label = l, Description = o.Str("description") is { Length: > 0 } d ? d : null });
            out_.Add(new AskQuestion { Question = text, Header = q.Str("header") is { Length: > 0 } h ? h : null, MultiSelect = q.Bool("multiSelect"), Options = opts });
        }
        return out_;
    }

    /// Swift synthesized Codable：非 Optional 的 multiSelect、options 一定要寫
    public JsonObject ToJson()
    {
        var o = new JsonObject { ["question"] = Question };
        o.Put("header", Header);
        o["multiSelect"] = MultiSelect;
        o["options"] = new JsonArray(Options.Select(x =>
        {
            var j = new JsonObject { ["label"] = x.Label };
            j.Put("description", x.Description);
            return (JsonNode?)j;
        }).ToArray());
        return o;
    }

    public static AskQuestion? From(JsonNode? o)
    {
        if (o.Str("question") is not { } q) return null;
        var opts = o?["options"] is JsonArray a
            ? a.Where(x => x.Str("label") != null).Select(x => new Option { Label = x.Str("label")!, Description = x.Str("description") }).ToList() : new();
        return new AskQuestion { Question = q, Header = o.Str("header"), MultiSelect = o.Bool("multiSelect"), Options = opts };
    }
}

sealed class PermitRequest
{
    public string Id = "";
    public string SessionId = "";
    public int? Pid;                 // AI 行程（死了就收掉）
    public string Tool = "";
    public string Summary = "";      // 要執行的東西：指令、檔案路徑、網址⋯
    public string? Detail;           // AI 自己寫的說明（Bash 的 description）
    public string? Cwd;
    public string? AlwaysRules;      // 「一律允許」要套的 permission_suggestions（addRules，JSON 陣列原文）
    public DateTime At;
    public List<AskQuestion>? Questions;   // AskUserQuestion 的題目（10-25）
    public string? Input;                  // AskUserQuestion／ExitPlanMode 的 tool_input 原文：回答時改好當 updatedInput

    public bool IsAsk => Tool == "AskUserQuestion";
    public bool IsPlan => Tool == "ExitPlanMode";

    /// 欄位順序同 Swift 的宣告順序（Mac 看板、Windows 看板都按名字讀）
    public JsonObject ToJson()
    {
        var o = new JsonObject { ["id"] = Id, ["sessionId"] = SessionId };
        o.Put("pid", Pid);
        o["tool"] = Tool; o["summary"] = Summary;
        o.Put("detail", Detail); o.Put("cwd", Cwd); o.Put("alwaysRules", AlwaysRules);
        o["at"] = HookJson.Iso(At);
        if (Questions != null) o["questions"] = new JsonArray(Questions.Select(q => (JsonNode?)q.ToJson()).ToArray());
        o.Put("input", Input);
        return o;
    }

    public static PermitRequest? From(JsonNode? o)
    {
        if (o.Str("id") is not { } id || o.Str("sessionId") is not { } sid || o.Str("tool") is not { } tool || o.Str("summary") is not { } s || o.Date("at") is not { } at) return null;
        return new PermitRequest
        {
            Id = id, SessionId = sid, Pid = o.Int("pid"), Tool = tool, Summary = s, Detail = o.Str("detail"), Cwd = o.Str("cwd"),
            AlwaysRules = o.Str("alwaysRules"), At = at, Input = o.Str("input"),
            Questions = o?["questions"] is JsonArray qs ? qs.Select(AskQuestion.From).OfType<AskQuestion>().ToList() : null,
        };
    }
}

sealed class PermitAnswer
{
    public string Decision = "allow";                     // allow／always／deny
    public string? Message;
    public Dictionary<string, List<string>>? Answers;     // 選擇題：題目 → 選的（單選一個、多選多個、「其他」是自己打的字）

    public JsonObject ToJson()
    {
        var o = new JsonObject { ["decision"] = Decision };
        o.Put("message", Message);
        if (Answers != null) o["answers"] = new JsonObject(Answers.Select(kv => KeyValuePair.Create(kv.Key, (JsonNode?)HookJson.Arr(kv.Value))));
        return o;
    }

    public static PermitAnswer? From(JsonNode? o)
    {
        if (o.Str("decision") is not ("allow" or "always" or "deny")) return null;
        Dictionary<string, List<string>>? ans = null;
        if (o?["answers"] is JsonObject a) ans = a.ToDictionary(kv => kv.Key, kv => kv.Value is JsonArray xs ? xs.Select(x => x?.GetValue<string>() ?? "").ToList() : new List<string>());
        return new PermitAnswer { Decision = o.Str("decision")!, Message = o.Str("message"), Answers = ans };
    }
}

static class Permit
{
    /// hook 最久等多久（之後終端機對話框還在，只是戰情中心不能按了）
    public static readonly TimeSpan MaxWait = TimeSpan.FromSeconds(3600);
    /// 超過這麼久的請求檔當成殘留（hook 當掉沒收；Windows 上 Claude Code 砍 hook 是 TerminateProcess，收不了尾）
    public static readonly TimeSpan StaleAfter = MaxWait + TimeSpan.FromSeconds(60);

    public static string Dir => HookPaths.Env("SHOWORK_PERMIT_DIR") ?? Path.Combine(HookPaths.Board, "permits");
    public static string RequestPath(string id, string? dir = null) => Path.Combine(dir ?? Dir, id + ".json");
    public static string AnswerPath(string id, string? dir = null) => Path.Combine(dir ?? Dir, id + ".answer.json");

    /// hook 的 stdin JSON → 請求（缺 session 或 tool 就 null）
    public static PermitRequest? Request(JsonNode? o, int? pid, DateTime now)
    {
        if (o.Str("session_id") is not { Length: > 0 } sid || o.Str("tool_name") is not { } tool) return null;
        var input = o?["tool_input"] as JsonObject ?? new JsonObject();
        var rules = (o?["permission_suggestions"] as JsonArray ?? new JsonArray()).Where(x => x.Str("type") == "addRules").Select(x => x!.DeepClone()).ToArray();
        long ms = (long)(now - DateTime.UnixEpoch).TotalMilliseconds;
        var r = new PermitRequest
        {
            Id = $"{sid[..Math.Min(8, sid.Length)]}-{ms}", SessionId = sid, Pid = pid, Tool = tool,
            Summary = Summary(tool, input), Detail = input.Str("description") is { Length: > 0 } d ? d : null,
            Cwd = o.Str("cwd"), AlwaysRules = rules.Length == 0 ? null : HookJson.Text(new JsonArray(rules)), At = now,
        };
        if (tool is "AskUserQuestion" or "ExitPlanMode")
        {
            r.Input = HookJson.Text(input);
            r.AlwaysRules = null;
            if (tool == "AskUserQuestion")
            {
                var qs = AskQuestion.Parse(input);
                if (qs.Count == 0) return null;
                r.Questions = qs;
                r.Summary = string.Join("／", qs.Select(q => q.Question));
            }
            else r.Summary = "計畫寫好了，要照這個做嗎？";
        }
        return r;
    }

    static readonly string[] SummaryKeys = { "command", "file_path", "notebook_path", "url", "query", "pattern", "path", "prompt" };

    /// 要執行的東西，一行（太長截斷）
    public static string Summary(string tool, JsonObject input)
    {
        var s = SummaryKeys.Select(k => input.Str(k)).FirstOrDefault(v => !string.IsNullOrEmpty(v)) ?? HookJson.Text(Sorted(input));
        return SwiftText.Count(s) > 600 ? SwiftText.Prefix(s, 600) + "⋯" : s;
    }

    /// JSONSerialization 的 .sortedKeys
    static JsonNode? Sorted(JsonNode? n) => n switch
    {
        JsonObject o => new JsonObject(o.OrderBy(kv => kv.Key, StringComparer.Ordinal).Select(kv => KeyValuePair.Create(kv.Key, Sorted(kv.Value)))),
        JsonArray a => new JsonArray(a.Select(Sorted).ToArray()),
        _ => n?.DeepClone(),
    };

    /// 回給 Claude Code 的 hook 輸出
    public static string HookOutput(PermitAnswer a, PermitRequest r)
    {
        JsonObject d;
        var m = a.Message?.Trim() is { Length: > 0 } t ? t : null;
        switch (a.Decision)
        {
            case "allow" when r.IsAsk || r.IsPlan:
                // 選擇題：把答案填進原輸入（多選給陣列、單選給字串）；計畫確認：原輸入照樣放行＝核准
                var input = HookJson.Parse(r.Input) as JsonObject ?? new JsonObject();
                if (r.IsAsk)
                {
                    var multi = new Dictionary<string, bool>();
                    foreach (var q in r.Questions ?? new()) multi.TryAdd(q.Question, q.MultiSelect);
                    var ans = new JsonObject();
                    foreach (var (q, v) in a.Answers ?? new())
                        if (v.Count > 0) ans[q] = multi.GetValueOrDefault(q) ? HookJson.Arr(v) : JsonValue.Create(string.Join(", ", v));
                    input["answers"] = ans;
                }
                d = new JsonObject { ["behavior"] = "allow", ["updatedInput"] = input };
                break;
            case "allow":
                d = new JsonObject { ["behavior"] = "allow" };
                break;
            case "always":
                d = new JsonObject { ["behavior"] = "allow" };
                if (HookJson.Parse(r.AlwaysRules) is { } rules) d["updatedPermissions"] = rules;
                break;
            default:
                var msg = r.IsPlan ? (m != null ? $"使用者在戰情中心退回這份計畫，要你照這句修改後再提：{m}" : "使用者在戰情中心退回這份計畫，先不要動手。")
                    : r.IsAsk ? (m != null ? $"使用者沒有選選項，在戰情中心回你：{m}" : "使用者在戰情中心選擇不回答這題。")
                    : (m != null ? $"使用者在戰情中心按了拒絕，並說：{m}" : "使用者在戰情中心按了拒絕。");
                d = new JsonObject { ["behavior"] = "deny", ["message"] = msg };
                break;
        }
        return HookJson.Text(new JsonObject { ["hookSpecificOutput"] = new JsonObject { ["hookEventName"] = "PermissionRequest", ["decision"] = d } });
    }

    // MARK: 終端機先答了沒（看 transcript）

    /// transcript 尾端裡，這次要求權限的 tool_use id（從後往前找同名、同輸入的那一個）
    public static string? ToolUseId(string tail, string tool, JsonNode? input)
    {
        foreach (var line in tail.Split('\n').Reverse())
        {
            if (line.Length == 0 || line.Length >= 4 << 20 || !line.Contains("\"tool_use\"")) continue;
            if (HookJson.Parse(line) is not JsonObject o || o.Str("type") != "assistant" || o["message"]?["content"] is not JsonArray content) continue;
            foreach (var c in content.Reverse())
                if (c.Str("type") == "tool_use" && c.Str("name") == tool && JsonNode.DeepEquals(c?["input"], input) && c.Str("id") is { } id) return id;
        }
        return null;
    }

    /// 新增的 transcript 內容裡有沒有這個 tool_use 的結果（允許後跑完、被拒絕、被中斷都會寫 tool_result）
    /// 找不到 id 時退而求其次：出現任何 tool_result 就算
    public static bool Resolved(string appended, string? toolUseId) =>
        toolUseId != null ? appended.Contains($"\"tool_use_id\":\"{toolUseId}\"", StringComparison.Ordinal)
                          : appended.Contains("\"type\":\"tool_result\"", StringComparison.Ordinal);

    // MARK: 讀寫（hook 和戰情中心共用）

    /// 還在等的請求（每個 session 最新的一個）
    public static Dictionary<string, PermitRequest> Pending(DateTime now, string? dir = null)
    {
        var out_ = new Dictionary<string, PermitRequest>();
        foreach (var f in HookJson.Files(dir ?? Dir, "*.json"))
        {
            if (f.EndsWith(".answer.json", StringComparison.Ordinal)) continue;
            if (PermitRequest.From(HookJson.ReadObject(f)) is not { } r || now - r.At >= StaleAfter || File.Exists(AnswerPath(r.Id, dir))) continue;
            if (out_.TryGetValue(r.SessionId, out var o) && o.At > r.At) continue;
            out_[r.SessionId] = r;
        }
        return out_;
    }

    public static bool Write(PermitRequest r, string? dir = null) => HookJson.WriteAtomic(RequestPath(r.Id, dir), HookJson.Text(r.ToJson()));

    /// 戰情中心按下去：寫回答檔（請求已經收掉就不寫，回 false）
    public static bool Answer(string id, PermitAnswer a, string? dir = null) =>
        File.Exists(RequestPath(id, dir)) && HookJson.WriteAtomic(AnswerPath(id, dir), HookJson.Text(a.ToJson()));

    /// 選擇題／計畫確認從戰情中心回答的紀錄（board\permits\answers.jsonl，欄位同 releases.jsonl）
    public static void LogAnswer(PermitRequest r, PermitAnswer a, DateTime now, string? dir = null)
    {
        if (!(r.IsAsk || r.IsPlan)) return;
        HookJson.AppendLine(Path.Combine(dir ?? Dir, "answers.jsonl"), HookJson.Text(new JsonObject
        {
            ["at"] = HookJson.Iso(now), ["id"] = r.Id, ["by"] = "board", ["byName"] = "使用者（戰情中心）", ["target"] = r.SessionId,
            ["summary"] = AnswerText(r, a), ["source"] = r.IsAsk ? "戰情中心選擇題" : "戰情中心計畫確認",
        }));
    }

    /// 一行：哪題、答什麼
    public static string AnswerText(PermitRequest r, PermitAnswer a)
    {
        if (r.IsPlan) return a.Decision == "deny" ? "退回計畫" + (a.Message != null ? $"：{a.Message}" : "") : "核准計畫";
        if (a.Decision == "deny") return "不選選項" + (a.Message != null ? $"，回：{a.Message}" : "");
        return string.Join("；", (r.Questions ?? new()).Select(q => $"{q.Question} → {string.Join("、", a.Answers?.GetValueOrDefault(q.Question) ?? new())}"));
    }

    public static PermitAnswer? ReadAnswer(string id, string? dir = null) => PermitAnswer.From(HookJson.ReadObject(AnswerPath(id, dir)));

    public static void Remove(string id, string? dir = null)
    {
        try { File.Delete(RequestPath(id, dir)); } catch { }
        try { File.Delete(AnswerPath(id, dir)); } catch { }
    }

    // MARK: hook 本體（`showork permit`）

    /// 等戰情中心的回答。回傳要印的 hook JSON；null＝安靜離開（交還給終端機）。
    /// alive＝AI 行程還在不在；sleep＝每輪等多久（測試換掉）
    public static string? Wait(PermitRequest req, JsonNode? hook, Func<int, bool> alive, Action<int> sleep, Func<DateTime> clock)
    {
        if (!Write(req)) return null;
        var input = hook?["tool_input"];
        // 終端機先答了沒：看 transcript 出現這個 tool_use 的 tool_result。新 session 第一次跳權限時檔案可能還沒寫出來，每輪重試開檔；
        // 開得到時就在的內容只用來找 tool_use id，「任何 tool_result 都算」的退路只看 hook 開始之後新增的
        var tpath = hook.Str("transcript_path");
        FileStream? transcript = null;
        var seen = new StringBuilder(); var fresh = new StringBuilder();
        long offset = 0;
        string? useId = null;
        var start = clock();
        try
        {
            while (clock() - start < MaxWait)
            {
                if (ReadAnswer(req.Id) is { } a) { Remove(req.Id); return HookOutput(a, req); }
                if (!File.Exists(RequestPath(req.Id))) return null;
                if (req.Pid is { } p && !alive(p)) break;
                if (transcript == null && tpath != null && File.Exists(tpath))
                {
                    try
                    {
                        transcript = new FileStream(tpath, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
                        long end = transcript.Length, from = end > 2 << 20 ? end - (2 << 20) : 0;
                        seen.Append(ReadRange(transcript, from, end)); offset = end;
                    }
                    catch { transcript = null; }
                }
                if (transcript != null)
                {
                    long end = transcript.Length;
                    if (end > offset)
                    {
                        var d = ReadRange(transcript, offset, end);
                        offset = end; seen.Append(d); fresh.Append(d);
                        if (seen.Length > 4 << 20) seen.Remove(0, seen.Length - (2 << 20));
                    }
                    var all = seen.ToString();
                    useId ??= ToolUseId(all, req.Tool, input);
                    if (useId != null && Resolved(all, useId)) break;                              // 終端機那邊答了
                    if (useId == null && clock() - start > TimeSpan.FromSeconds(5) && Resolved(fresh.ToString(), null)) break;
                }
                sleep(400);
            }
        }
        finally { transcript?.Dispose(); }
        Remove(req.Id);
        return null;
    }

    static string ReadRange(FileStream fs, long from, long to)
    {
        var buf = new byte[to - from];
        fs.Seek(from, SeekOrigin.Begin);
        int n = fs.ReadAtLeast(buf, buf.Length, throwOnEndOfStream: false);
        return Encoding.UTF8.GetString(buf, 0, n);
    }
}
