using System.Text.Json.Nodes;

namespace ShoWork.Hooks;

// 隊長收件匣、放行、事先放行（Mac 版 CaptainLink.swift 的 ④ 與 Preapproval；Captain.swift 的 CaptainStore 只搬 hook 端要的）。
//   board\captain-inbox\<id>.json   開工卡、預告、擋下（SHOWORK_CAPTAIN_INBOX 可改）
//   board\permits\releases.jsonl    放行紀錄（SHOWORK_RELEASE_LOG）
//   board\permits\preapprovals.json 戰情中心回答＝事先放行（SHOWORK_PREAPPROVAL_LOG）；Windows 看板還沒有回答的 UI，
//                                   這份檔目前只有 Mac 看板會寫，Windows 這邊照規則讀與「用掉」
//   board\captain.json              誰是隊長；board\roster.json 名冊（Windows 沒有人寫，讀不到就當沒有專案名）

sealed class InboxItem
{
    public string Id = "";
    public string Kind = "notice";        // start／notice／block
    public DateTime At;
    public string Sid = "";
    public string Name = "";
    public string? Project;
    public List<string> Kinds = new();    // 預告的類別（開工卡＝空）
    public string Text = "";              // 指令摘要／開工卡一句話
    public string? Fingerprint;           // 擋下的指令指紋
    public bool Delivered;                // 送到隊長了
    public DateTime? Released;            // 擋下的：放行時間
    public DateTime? Used;                // 放行後真的跑了
    public DateTime? Acked;               // 隊長處理過（showork captain ack）

    /// Swift 的 synthesized Codable：非 Optional 的欄位（kinds、delivered）一定要寫，Mac 才讀得回去
    public JsonObject ToJson()
    {
        var o = new JsonObject { ["id"] = Id, ["kind"] = Kind, ["at"] = HookJson.Iso(At), ["sid"] = Sid, ["name"] = Name };
        o.Put("project", Project);
        o["kinds"] = HookJson.Arr(Kinds);
        o["text"] = Text;
        o.Put("fingerprint", Fingerprint);
        o["delivered"] = Delivered;
        o.Put("released", Released); o.Put("used", Used); o.Put("acked", Acked);
        return o;
    }

    public static InboxItem? From(JsonNode? o)
    {
        if (o.Str("id") is not { } id || o.Str("kind") is not ("start" or "notice" or "block") || o.Date("at") is not { } at
            || o.Str("sid") is not { } sid || o.Str("name") is not { } name || o.Str("text") is not { } text) return null;
        return new InboxItem
        {
            Id = id, Kind = o.Str("kind")!, At = at, Sid = sid, Name = name, Project = o.Str("project"), Kinds = o.Strs("kinds"), Text = text,
            Fingerprint = o.Str("fingerprint"), Delivered = o.Bool("delivered"), Released = o.Date("released"), Used = o.Date("used"), Acked = o.Date("acked"),
        };
    }

    /// 一行（showork captain 印）
    public string Line
    {
        get
        {
            var tag = Kind == "start" ? "開工" : Kind == "notice" ? "預告" : (Released == null ? "擋下・等放行" : "已放行");
            return $"{Id} {At.ToLocalTime():MM-dd HH:mm} [{tag}] {CaptainLink.Label(Name, Project)}：" + (Kinds.Count == 0 ? "" : string.Join("、", Kinds) + "・") + Text;
        }
    }
}

/// 戰情中心回答＝事先放行：答案裡明說的對外動作，之後被「擋」規則攔下就直接算放行（同 session、30 分鐘內、每種動作一次）
sealed class Preapproval
{
    public DateTime At;
    public string Sid = "";
    public string Answer = "";
    public string? Question;
    public List<string> Used = new();     // 已經用掉的規則名

    public JsonObject ToJson()
    {
        var o = new JsonObject { ["at"] = HookJson.Iso(At), ["sid"] = Sid, ["answer"] = Answer };
        o.Put("question", Question);
        o["used"] = HookJson.Arr(Used);
        return o;
    }

    public static Preapproval? From(JsonNode? o) =>
        o.Date("at") is { } at && o.Str("sid") is { } sid && o.Str("answer") is { } a
            ? new Preapproval { At = at, Sid = sid, Answer = a, Question = o.Str("question"), Used = o.Strs("used") } : null;
}

static class CaptainInbox
{
    public static string Dir => HookPaths.Env("SHOWORK_CAPTAIN_INBOX") ?? Path.Combine(HookPaths.Board, "captain-inbox");
    public static string ReleaseLog => HookPaths.Env("SHOWORK_RELEASE_LOG") ?? Path.Combine(HookPaths.Board, "permits", "releases.jsonl");
    public static string PreapprovalLog => HookPaths.Env("SHOWORK_PREAPPROVAL_LOG") ?? Path.Combine(HookPaths.Board, "permits", "preapprovals.json");
    /// 放行有效時間
    public static readonly TimeSpan ReleaseTTL = TimeSpan.FromMinutes(30);

    const string Alphabet = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789";
    public static string NewID(string kind) =>
        (kind == "block" ? "B" : kind == "notice" ? "N" : "S") + new string(Enumerable.Range(0, 4).Select(_ => Alphabet[Random.Shared.Next(Alphabet.Length)]).ToArray());

    public static bool Save(InboxItem i) => HookJson.WriteAtomic(Path.Combine(Dir, i.Id + ".json"), HookJson.Text(i.ToJson()));

    public static List<InboxItem> All() =>
        HookJson.Files(Dir, "*.json").Select(f => InboxItem.From(HookJson.ReadObject(f))).OfType<InboxItem>().OrderBy(i => i.At).ToList();

    public static InboxItem? Item(string id) => InboxItem.From(HookJson.ReadObject(Path.Combine(Dir, id.ToUpperInvariant() + ".json")));

    /// 未處理：隊長還沒 ack、而且沒送到隊長的或還在等放行的（24 小時內）
    public static List<InboxItem> Pending(DateTime now) =>
        All().Where(i => i.Acked == null && now - i.At < TimeSpan.FromDays(1) && (!i.Delivered || (i.Kind == "block" && i.Released == null))).ToList();

    /// 隊長標已處理：單號或 all；回傳標了幾筆
    public static int Ack(string id, DateTime now)
    {
        var xs = id.Equals("all", StringComparison.OrdinalIgnoreCase) ? Pending(now) : All().Where(i => i.Id == id.ToUpperInvariant() && i.Acked == null).ToList();
        foreach (var i in xs) { i.Acked = now; Save(i); }
        return xs.Count;
    }

    /// 這個 session 的這個指令有沒有有效的放行；有就用掉（回 true＝可以跑）
    public static bool Consume(string sid, string fp, DateTime now)
    {
        var i = All().LastOrDefault(i => i.Kind == "block" && i.Sid == sid && i.Fingerprint == fp && i.Used == null
                                         && i.Released is { } r && now - r < ReleaseTTL);
        if (i == null) return false;
        i.Used = now; Save(i);
        return true;
    }

    /// 還在等放行的同一個指令（重試時不再開新單）
    public static InboxItem? Waiting(string sid, string fp) =>
        All().LastOrDefault(i => i.Kind == "block" && i.Sid == sid && i.Fingerprint == fp && i.Released == null);

    /// 放行：寫紀錄（releases.jsonl）。id＝null ⇒ 這個 session 最近一張等放行的
    public static InboxItem? Release(string? id, string? target, string by, string byName, string source, DateTime now)
    {
        var waiting = All().Where(i => i.Kind == "block" && i.Released == null && now - i.At < TimeSpan.FromDays(1)).ToList();
        var it = id != null ? waiting.FirstOrDefault(i => i.Id == id.ToUpperInvariant()) : waiting.LastOrDefault(i => i.Sid == target);
        if (it == null) return null;
        if (target != null && it.Sid != target) return null;
        it.Released = now; Save(it);
        HookJson.AppendLine(ReleaseLog, HookJson.Text(new JsonObject
        {
            ["at"] = HookJson.Iso(now), ["id"] = it.Id, ["by"] = by, ["byName"] = byName, ["target"] = it.Sid, ["summary"] = it.Text, ["source"] = source,
        }));
        return it;
    }

    /// 放行紀錄（測試、稽核用）
    public static List<JsonObject> Releases() =>
        (HookJson.ReadText(ReleaseLog) ?? "").Split('\n', StringSplitOptions.RemoveEmptyEntries).Select(l => HookJson.Parse(l) as JsonObject).OfType<JsonObject>().ToList();

    // MARK: 戰情中心回答＝事先放行

    /// 擋規則 → 答案裡要出現的字（點名這個動作）。rm 不在內（刪檔一律要明確放行）
    static readonly (string Rule, string[] Words)[] PreapprovalWords =
    {
        ("GitHub 公開發言", new[] { "PR", "pull request", "issue", "留言", "GitHub", "發 release", "發布" }),
        ("LINE 對外傳訊", new[] { "LINE", "傳訊", "私訊", "通知" }),
        ("firebase 部署", new[] { "部署", "deploy", "firebase", "上線" }),
        ("App 上傳", new[] { "上傳", "送審", "TestFlight", "上架" }),
    };
    static readonly string[] Negations = { "不要", "先不", "別", "不用", "暫緩", "取消", "不准", "禁止", "等一下", "等等", "先等" };
    const string ClauseBreaks = "，,、；;。！!？?\n";

    /// 這則答案有沒有點名放行這條擋規則：按逗號、分號、句號切成小句，有小句點名、而且點名它的小句都沒有否定字才算
    public static bool Authorizes(string answer, string rule)
    {
        var ws = PreapprovalWords.FirstOrDefault(p => rule.StartsWith(p.Rule, StringComparison.Ordinal)).Words;
        if (ws == null) return false;
        var clauses = answer.ToLowerInvariant().Split(ClauseBreaks.ToCharArray(), StringSplitOptions.RemoveEmptyEntries);
        var named = clauses.Where(c => ws.Any(w => c.Contains(w.ToLowerInvariant(), StringComparison.Ordinal))).ToList();
        return named.Count > 0 && named.All(c => !Negations.Any(n => c.Contains(n, StringComparison.Ordinal)) && !c.Contains('不'));
    }

    static List<Preapproval> LoadPreapprovals() =>
        HookJson.Parse(HookJson.ReadText(PreapprovalLog)) is JsonArray a ? a.Select(Preapproval.From).OfType<Preapproval>().ToList() : new();

    static void SavePreapprovals(List<Preapproval> xs) =>
        HookJson.WriteAtomic(PreapprovalLog, HookJson.Text(new JsonArray(xs.Select(x => (JsonNode?)x.ToJson()).ToArray())));

    /// 戰情中心送出回答時記下（只留 24 小時內）。Windows 看板還沒有回答 UI；給測試與之後的看板用
    public static void RecordAnswer(string sid, string answer, string? question, DateTime now)
    {
        var xs = LoadPreapprovals().Where(p => now - p.At < TimeSpan.FromDays(1)).ToList();
        xs.Add(new Preapproval { At = now, Sid = sid, Answer = answer, Question = question });
        SavePreapprovals(xs);
    }

    /// 被擋的這些規則是不是都已經被這個 session 30 分鐘內的戰情中心回答點名放行；是就記用掉、回那則答案
    public static Preapproval? UsePreapproval(string sid, List<string> rules, DateTime now)
    {
        if (rules.Count == 0) return null;
        var xs = LoadPreapprovals();
        int k = -1;
        for (int i = xs.Count - 1; i >= 0; i--)
        {
            var p = xs[i];
            if (p.Sid == sid && now - p.At < ReleaseTTL && now >= p.At && rules.All(r => !p.Used.Contains(r) && Authorizes(p.Answer, r))) { k = i; break; }
        }
        if (k < 0) return null;
        xs[k].Used.AddRange(rules);
        SavePreapprovals(xs);
        return xs[k];
    }

    /// 事先放行的擋單：直接記成已放行＋已用，寫稽核紀錄
    public static InboxItem ReleaseByAnswer(InboxItem item, Preapproval answer, DateTime now)
    {
        Save(item);
        Release(item.Id, item.Sid, "戰情中心", $"使用者（戰情中心回答：{answer.Answer}）", "戰情中心回答", now);
        var i = Item(item.Id) ?? item;
        i.Used = now; Save(i);
        return i;
    }
}

/// 隊長、名冊、派工單（Mac 的 CaptainStore；hook 端只要讀隊長、設隊長、讀專案名、更新派工單）
static class CaptainStore
{
    public static string CaptainFile => Path.Combine(HookPaths.Board, "captain.json");
    public static string RosterFile => Path.Combine(HookPaths.Board, "roster.json");
    public static string TasksDir => Path.Combine(HookPaths.Board, "tasks");

    /// 隊長的 sessionId（沒有＝null）
    public static string? Captain() => HookJson.ReadObject(CaptainFile).Str("sessionId");

    public static bool SetCaptain(string sid, string? name, DateTime now)
    {
        var o = new JsonObject { ["sessionId"] = sid };
        o.Put("name", name);
        o["at"] = HookJson.Iso(now);
        return HookJson.WriteAtomic(CaptainFile, HookJson.Text(o));
    }

    /// 名冊裡這個 session 的專案名（Windows 目前沒有人寫 roster.json ⇒ 多半是 null）
    public static string? Project(string sid) =>
        HookJson.ReadObject(RosterFile)?["entries"] is JsonArray es
            ? es.FirstOrDefault(e => e.Str("sessionId") == sid).Str("project") : null;

    /// 對方用 `showork card --task <id>` 回報 → 更新這張派工單（Mac 的 CaptainTask.apply）；找不到回 false
    public static bool ApplyTask(string id, CardReport r)
    {
        var path = Path.Combine(TasksDir, id + ".json");
        if (HookJson.ReadObject(path) is not { } o || o.Str("id") == null) return false;
        if (o.Str("state") == "cancelled") return true;
        o["state"] = r.Status switch { "done" => r.Ask == null ? "done" : "review", var s => s };
        if (r.Summary != null) o["summary"] = r.Summary;
        if (r.Ask != null) o["ask"] = r.Ask; else o.Remove("ask");
        o["updatedAt"] = HookJson.Iso(r.At);
        HookJson.WriteAtomic(path, HookJson.Text(o));
        return true;
    }

    /// ~/.claude/sessions 裡找這個 session 的名字
    public static string? SessionName(string sid) => PeerSession.All().FirstOrDefault(r => r.SessionId == sid)?.Name;

    /// `showork captain` 印給隊長 AI 的工作守則（同 Mac 的 Captain.manual，最後加一行 Windows 版還沒有的指令）
    public static string Manual(string showork)
    {
        var owner = LocalConfig.Current.OwnerName;
        return $"""
            [AI工作戰情中心] 你現在是隊長。使用者把任務丟給你，你決定交給哪個 session 做，自己不下去做細節（保持 context 乾淨，才能一直當隊長）。
            1. 先看名冊："{showork}" roster（每個 session 的名字、專案、在做什麼、閒置或忙、ctx、同專案重工警告）。
            2. 選人：同一個專案只交給一個 session（有人在做那個專案就交給它，不要再開）；名冊上 ctx 已到 token 門檻（showork roster 會標 ctx Nk）的不要再派；沒有合適的就請使用者開新的或用看板「新任務⋯」。
            3. 派工："{showork}" task add --to <英文名，例如 Chris> --text "<任務：目標、判準、交什麼>" —— 會建單並直接送進對方收件匣。
               接力（A 做完自動交給 B）：再加 --then-to <B 的名字> --then "<B 要做的事>"，A 回報完成時看板會把 A 的回報附上、自動派給 B。
               直送失敗時它會印出全文，改用 SendMessage（to＝英文名，例如 Chris；名字固定，不會跟著對方在做的事變）送。
            4. 對方回報完成、要使用者決定、或卡住時，看板會自動傳一則「【派工回報】」給你；也可以隨時 "{showork}" tasks 查。
            5. 收到回報後整理給使用者；要使用者決定的事轉問使用者，不要自己替他決定。
            6. 小事（問個問題、改一行）自己做比較快，不用派。派工會讓對方動手改東西；使用者沒授權的事、你自己權限會被擋的事，不要叫別人做。
            7. 流程優化：Agent交流互動板是大家休息時留的工作心得（方法、踩過的坑、流程哪裡可以改），新留言會以「【交流板】」轉給你；
               全部看 "{showork}" b1 read。把重複出現的坑、好方法整理進派工（任務裡直接附上該注意的事），值得改成規則的提給使用者。
            8. 開工卡：組員收到使用者直接下的新任務時，動手前會發「【開工】」卡給你（打算怎麼做、會動到什麼、有沒有對外動作）；組員不等你，有問題就 SendMessage 修正，下一輪送達。
            9. 動作預告：組員要跑高風險指令前會送「【動作預告】」。rm 到暫存區以外、firebase deploy、App 上傳（-exportArchive／altool 等）、line_send.py、gh 對外發言（issue／PR 留言或開單、PR review、release、gh api 寫入；Okle42 私有 repo 除外）會先擋下等放行；
               只有{owner}已經明說同意的動作（例如他說「push」「部署」「傳給學弟」）你才能 "{showork}" release <單號>，對外動作不能自己決定放行。每次放行都會記在 board/permits/releases.jsonl。
               其他（mv 到暫存區以外、xcodebuild archive 本機打包、defaults write、寫 ~/.claude/scripts|data、ssh 遠端 Windows 寫入）只預告不擋，同一個組員一小段時間內的會合成一則。
               開工卡、預告、擋下都會留在收件匣；處理過的用 "{showork}" captain ack <單號｜all> 標掉，鬧鐘的「未處理」只算沒 ack 的。
            10. 巡檢：看板每 30 分鐘送一則「【巡檢時間】」（人數、ctx、閒置太久的人；跟上次一樣就只寫「無變化」），趁這時候看看有沒有人卡住、ctx 快滿、閒太久。
            11. ctx 自動交接：組員 ctx 到 token 門檻（board.ctxTokens，250k–1000k）會被 Stop hook 請去收尾，收尾完發 wrapup 卡、看板等它停下自動 /clear，新 context 沿用英文名、派工單自動轉給它，你不用重派。
                名冊／巡檢標「已收尾待 /clear」的人不要派新工作（派了就不會自動 /clear，看板會傳「【交接提醒】」給你）；「自動 /clear 失敗」的請{owner}手動 /clear。
            12. 組員卡片已問使用者的事，隊長卡片不再問；隊長只審問題與選項。使用者在組員卡片答了，看板會傳「【使用者已答】名字：問題→答案」給你，你卡片上同一題會自動清掉。
            取消："{showork}" task cancel <單號>。
            （Windows 版目前只有 card、names、captain、release 與 hook 端的開工卡／動作預告；roster、task、tasks、b1、巡檢、自動交接還沒有，派工改用 SendMessage。）
            """;
    }
}
