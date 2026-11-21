using System.Text.Json.Nodes;

namespace ShoWork;

/// 戰情中心第三個檢視「球體」的資料（Mac Sources/ShoWorkAgent/SphereWebScene.swift 的 payload()／info() 轉寫；純函式，不碰 WinForms，測試直接連原始檔）。
/// 網頁（Board\Web\sphere.html）收 window.karaUpdate(這份)；欄位跟 Mac 一樣：
///   sessions、five_hour、seven_day、five_reset、seven_reset、ctx、doneToday、team[{name,status,sessionId,progress,doing,summary,ask,options,permit}]、
///   runs[{label,name,fraction,eta}]、heat（Windows 沒有 cool42 ⇒ null）、paused（Windows 沒有過熱暫停 ⇒ false）、captain（隊長最後一句）。
/// 跟 Mac 不同：Mac 的「需要你」看排隊中還沒回答的 --ask（PendingAsk）；Windows 的卡片沒有那個佇列，用這一輪自報的 ask（Report.Ask＋Options）。
public static class SpherePayload
{
    /// Swift 的 .rounded()＝四捨五入（遠離零），不是 .NET 預設的銀行家捨入
    static double Round(double v) => Math.Round(v, MidpointRounding.AwayFromZero);

    public static bool NeedsYou(BoardCard c) => !string.IsNullOrEmpty(c.Report?.Ask) || c.Permit != null;

    public static string Status(BoardCard c) => NeedsYou(c) ? "需要你" : c.Column.Title();

    public static JsonObject Build(IReadOnlyList<BoardCard> cards, RateLimits? limits, IReadOnlyList<RunProgress>? runs = null,
                                   IReadOnlyList<CaptainLine>? captainThread = null, DateTime? nowUtc = null)
    {
        var now = nowUtc ?? DateTime.UtcNow;
        var people = cards.Where(c => !c.IsQueued).ToList();
        var l = limits?.Current(now);
        var o = new JsonObject { ["sessions"] = people.Count };
        o["five_hour"] = l?.FiveHour is { } f ? (JsonNode?)Round(f.Used) : null;
        o["seven_day"] = l?.SevenDay is { } s ? (JsonNode?)Round(s.Used) : null;
        // 重置倒數（分鐘；額度預警、早報用）
        JsonNode? Mins(DateTime? d) => d is { } t ? (JsonNode?)Math.Max(0, (int)Round((t - now).TotalMinutes)) : null;
        o["five_reset"] = Mins(l?.FiveHour?.ResetsAt);
        o["seven_reset"] = Mins(l?.SevenDay?.ResetsAt);
        // 記憶量：最近有動靜的那個 session
        var recent = people.Where(c => c.Ctx != null).OrderByDescending(c => c.LastActivity ?? DateTime.MinValue).FirstOrDefault();
        o["ctx"] = recent?.Ctx is { } x ? (JsonNode?)Round(x.Percent) : null;
        // 今天做完（待審＋完成、最後動靜在今天，本機時間）的件數：收工總結用
        var today = now.ToLocalTime().Date;
        o["doneToday"] = people.Count(c => c.Column is BoardColumn.Review or BoardColumn.Done && c.LastActivity is { } a && a.ToLocalTime().Date == today);
        // 需要你的排最前，再來進行中（穩定排序，同 Swift sorted 對同等元素的順序在這裡不重要）
        int Rank(BoardCard c) => NeedsYou(c) ? 0 : c.Column == BoardColumn.Active ? 1 : 2;
        var team = new JsonArray();
        foreach (var c in people.OrderBy(Rank)) team.Add(Member(c));
        o["team"] = team;
        // 外環：背景長工作進度（cool42 溫度 Windows 沒有）
        var rs = new JsonArray();
        foreach (var r in (runs ?? Array.Empty<RunProgress>()).Where(r => r.Fresh(now)).Take(3))
        {
            var j = new JsonObject { ["label"] = r.Label, ["fraction"] = Round(r.Fraction * 100) / 100 };
            if (r.Name != null) j["name"] = r.Name;
            if (r.Eta != null) j["eta"] = r.Eta;
            rs.Add(j);
        }
        o["runs"] = rs;
        o["heat"] = null;
        o["paused"] = false;
        // 隊長最後一句（網頁判斷是不是回覆剛交辦的事；Mac v4 A）
        if (captainThread?.LastOrDefault(t => t.Role == CaptainLine.RoleKind.captain) is { } cl)
            o["captain"] = new JsonObject { ["id"] = cl.Id, ["text"] = Board.Prefix(cl.Text, 400), ["at"] = cl.At is { } at ? Iso(at) : "" };
        return o;
    }

    static JsonObject Member(BoardCard c)
    {
        var t = new JsonObject { ["name"] = c.Name ?? c.Project, ["status"] = Status(c), ["sessionId"] = c.SessionId };
        if (c.Report?.Progress is { } p) t["progress"] = p;
        if (c.Report?.Doing is { } d) t["doing"] = d;
        if (c.Report?.Summary is { } s) t["summary"] = s;
        if (!string.IsNullOrEmpty(c.Report?.Ask))
        {
            t["ask"] = c.Report!.Ask;
            if (c.Report.Options is { Count: > 0 } opts) t["options"] = new JsonArray(opts.Select(x => (JsonNode?)x).ToArray());
        }
        else if (c.Permit is { } pm)
        {
            bool ask = pm.Tool == "AskUserQuestion", plan = pm.Tool == "ExitPlanMode";
            t["ask"] = ask ? (pm.Questions?.FirstOrDefault()?.Question ?? "有選擇題要你回答")
                     : plan ? "計畫要你核准" : $"要不要讓它執行 {pm.Tool}：{pm.Summary}";
            var j = new JsonObject { ["id"] = pm.Id, ["kind"] = ask ? "ask" : plan ? "plan" : "tool", ["tool"] = pm.Tool, ["summary"] = Board.Prefix(pm.Summary, 200) };
            if (pm.Detail != null) j["detail"] = Board.Prefix(pm.Detail, 200);
            if (pm.Questions != null)
                j["questions"] = new JsonArray(pm.Questions.Select(q => (JsonNode?)new JsonObject
                {
                    ["question"] = q.Question, ["multi"] = q.MultiSelect,
                    ["options"] = new JsonArray(q.Options.Select(x => (JsonNode?)x.Label).ToArray()),
                }).ToArray());
            t["permit"] = j;
        }
        return t;
    }

    /// 點衛星展開小卡（Mac SphereWebHost.info）：window.karaSessionInfo(這份)。多給 lastActivity（ISO 字串）
    public static JsonObject Info(BoardCard c, DateTime? nowUtc = null)
    {
        var now = nowUtc ?? DateTime.UtcNow;
        var o = new JsonObject
        {
            ["sessionId"] = c.SessionId, ["name"] = c.Name ?? c.Project, ["project"] = c.Project, ["status"] = Status(c), ["reason"] = c.Reason,
        };
        if (c.Report?.Doing is { } d) o["doing"] = d;
        if (c.Report?.Summary is { } s) o["summary"] = Board.Prefix(s, 240);
        if (c.Report?.Progress is { } p) o["progress"] = p;
        if (c.Ctx is { } x) o["ctx"] = Round(x.Percent);
        if (c.LastActivity is { } t)
        {
            o["ago"] = Math.Max(0, (int)((now - t).TotalMinutes));
            o["lastActivity"] = Iso(t);
        }
        if (c.Detail is { } dt) o["detail"] = Board.Prefix(dt.Trim(), 240);
        if (c.Subagents.Count > 0) o["subagents"] = c.Subagents.Count;
        if (c.Kind != null) o["kind"] = c.Kind;
        return o;
    }

    /// sessionId → 卡片（優先不是排隊卡的那張；Mac SphereWebHost.card）
    public static BoardCard? Find(IEnumerable<BoardCard> cards, string? sid)
    {
        if (string.IsNullOrEmpty(sid)) return null;
        var all = cards as IReadOnlyList<BoardCard> ?? cards.ToList();
        return all.FirstOrDefault(c => c.SessionId == sid && !c.IsQueued) ?? all.FirstOrDefault(c => c.SessionId == sid);
    }

    static string Iso(DateTime d) => d.ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", System.Globalization.CultureInfo.InvariantCulture);
}
