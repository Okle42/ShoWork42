using System.Text.Json.Nodes;

namespace ShoWork.Hooks;

// 工作卡片自動轉送隊長（Mac 版 Sources/ShoWorkCore/CardRelay.swift 的移植）。
// 任何 session 跑 showork card，看板就把卡片內容以【工作回報】送給現任隊長（走派工回報同一條 Peer 路）。
//   • 隊長自己的卡不轉（迴圈）；隊長不在線就不送、也不堆積（那段期間的卡記成已看過）
//   • 節流：同一 session 60 秒內只送一次（期間的新卡等時間到送最後一張）；內容沒變不重送
//   • 看板剛啟動時現有的卡當成已看過，不一次灌給隊長
//   • 設定 captain.relayCards（預設開；Windows 在 board\prefs.json）
// Mac 的狀態放在看板行程的記憶體裡；Windows 由 `showork tick` 每次跑一輪，狀態存在 board\relay-state.json（agent 啟動時 --fresh 重來）。

static class CardRelay
{
    public const string SettingKey = "captain.relayCards";
    public static readonly TimeSpan MinInterval = TimeSpan.FromSeconds(60);
    /// 太舊的卡不轉（看板重開、隊長剛回來時不翻舊帳）
    public static readonly TimeSpan MaxAge = TimeSpan.FromMinutes(10);

    public sealed class State
    {
        public Dictionary<string, string> SentKey = new();     // sessionId → 上次送出（或看過）的內容
        public Dictionary<string, DateTime> SentAt = new();
        public bool Seeded;
        public Dictionary<string, (string Doing, DateTime At)> LastStart = new();   // 開工卡：同一個任務 10 分鐘內不重送

        public JsonObject ToJson() => new()
        {
            ["seeded"] = Seeded,
            ["sentKey"] = new JsonObject(SentKey.Select(kv => KeyValuePair.Create(kv.Key, (JsonNode?)kv.Value))),
            ["sentAt"] = new JsonObject(SentAt.Select(kv => KeyValuePair.Create(kv.Key, (JsonNode?)HookJson.Iso(kv.Value)))),
            ["lastStart"] = new JsonObject(LastStart.Select(kv => KeyValuePair.Create(kv.Key, (JsonNode?)new JsonObject { ["doing"] = kv.Value.Doing, ["at"] = HookJson.Iso(kv.Value.At) }))),
        };

        public static State From(JsonNode? o)
        {
            var s = new State { Seeded = o.Bool("seeded") };
            if (o?["sentKey"] is JsonObject k) foreach (var kv in k) if (kv.Value.Str0() is { } v) s.SentKey[kv.Key] = v;
            if (o?["sentAt"] is JsonObject a) foreach (var kv in a) if (HookJson.ParseIso(kv.Value.Str0()) is { } d) s.SentAt[kv.Key] = d;
            if (o?["lastStart"] is JsonObject l) foreach (var kv in l) if (kv.Value.Str("doing") is { } dg && kv.Value.Date("at") is { } at) s.LastStart[kv.Key] = (dg, at);
            return s;
        }
    }

    static string? Str0(this JsonNode? n) => n is JsonValue v && v.GetValueKind() == System.Text.Json.JsonValueKind.String ? v.GetValue<string>() : null;

    public sealed record Outgoing(string SessionId, string Text);

    /// 內容指紋：這些都沒變就不重送（時間不算）
    public static string Key(CardReport r)
    {
        var nums = new[] { r.Status, r.Progress?.ToString() ?? "", r.Confidence?.ToString() ?? "" };
        var texts = new[] { r.Summary ?? "", r.Ask ?? "", string.Join("|", r.Options ?? new()), r.Report ?? "", r.Doing ?? "", r.How ?? "", r.Kind ?? "", r.Touch ?? "", r.Outward ?? "" };
        return string.Join("\u001F", nums.Concat(texts));
    }

    /// 這次要送哪些。captain＝現任隊長 sessionId（null 或不在線 ⇒ 不送，全部記成看過）
    public static List<Outgoing> Plan(Dictionary<string, CardReport> reports, string? captain, bool captainLive, State state, DateTime now, Func<string, CardReport, string> text)
    {
        if (!state.Seeded)
        {
            foreach (var (sid, r) in reports) state.SentKey[sid] = Key(r);
            state.Seeded = true;
            return new();
        }
        var out_ = new List<Outgoing>();
        foreach (var sid in reports.Keys.OrderBy(k => k, StringComparer.Ordinal))
        {
            var r = reports[sid];
            var k = Key(r);
            if (state.SentKey.GetValueOrDefault(sid) == k) continue;
            // 派工單的做完／要你決定／卡住已經有【派工回報】（TaskRouter），不重複送
            bool routed = r.Task != null && r.Status != "working";
            if (captain == null || !captainLive || sid == captain || routed || now - r.At >= MaxAge)
            {
                state.SentKey[sid] = k;                    // 不送也不堆積
                continue;
            }
            // 等時間到再送最後一張；開工卡不等（隊長 1 分鐘內要收到）
            if (!r.IsStart && state.SentAt.TryGetValue(sid, out var t) && now - t < MinInterval) continue;
            if (r.IsStart)
            {
                var d = r.Doing ?? "";
                if (state.LastStart.TryGetValue(sid, out var l) && l.Doing == d && now - l.At < CaptainLink.NewTaskGap) { state.SentKey[sid] = k; continue; }
                state.LastStart[sid] = (d, now);
            }
            state.SentKey[sid] = k;
            state.SentAt[sid] = now;
            out_.Add(new Outgoing(sid, text(sid, r)));
        }
        return out_;
    }

    static string Cut(string s, int n = 300) => SwiftText.Count(s) > n ? SwiftText.Prefix(s, n) + "⋯" : s;

    /// 【工作回報】全文（開工卡＝【開工】：打算怎麼做、會動到什麼、有沒有對外動作）
    public static string Text(string name, string? project, CardReport r)
    {
        if (r.IsStart)
        {
            var head = $"【開工】{name}";
            if (!string.IsNullOrEmpty(project)) head += $"（{project}）";
            if (r.Doing != null) head += $"：{r.Doing}";
            var lines = new List<string> { head };
            if (r.Summary is { Length: > 0 } s) lines.Add($"要做什麼：{Cut(s)}");
            lines.Add("打算怎麼做：" + (r.How != null ? Cut(r.How) : "（沒寫 --how）"));
            lines.Add("會動到：" + (r.Touch != null ? Cut(r.Touch) : "（沒寫 --touch）"));
            lines.Add("對外動作：" + (r.Outward != null ? Cut(r.Outward) : "（沒寫 --outward）"));
            if (r.Task != null) lines.Add($"派工單：{r.Task}");
            lines.Add("（對方不等你回覆、已經開始做；要修正就 SendMessage 給它，下一輪會收到）");
            return string.Join("\n", lines);
        }
        var h = $"【工作回報】{name}";
        if (!string.IsNullOrEmpty(project)) h += $"（{project}）";
        if (r.Doing != null) h += $"：{r.Doing}";
        var ls = new List<string> { h };
        var st = $"狀態 {r.Status}";
        if (r.Progress is { } p) st += $"・完成度 {p}%";
        if (r.Confidence is { } c) st += $"・信心 {c}%";
        ls.Add(st);
        if (r.Summary is { Length: > 0 } sm) ls.Add($"摘要：{Cut(sm)}");
        ls.Add("方法與工具：" + (r.How != null ? Cut(r.How) : "（沒寫 --how）"));
        if (r.Ask != null)
            ls.Add($"問使用者：{Cut(r.Ask)}" + ((r.Options ?? new()).Count == 0 ? "" : $"（選項：{string.Join("／", r.Options!)}）"));
        if (r.Report != null) ls.Add($"報告：{r.Report}");
        if (r.Task != null) ls.Add($"派工單：{r.Task}");
        ls.Add("（看板自動轉送，對方不等你回覆；有疑慮再 SendMessage 給它）");
        return string.Join("\n", ls);
    }
}
