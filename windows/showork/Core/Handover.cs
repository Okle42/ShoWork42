using System.Globalization;
using System.Text.Json.Nodes;

namespace ShoWork.Hooks;

// ctx 自動交接閉環（Mac 版 Sources/ShoWorkCore/Handover.swift 的移植，檔案格式一模一樣）
//   ① Stop hook（Windows：`showork ctx-wrapup`，Mac 是 ~/.claude/scripts/hook_ctx_wrapup.py）請它收尾
//   ② 收尾完 AI 發 `showork card --kind wrapup --handoff <檔>` ⇒ 這裡記一筆 board\handover\<sid>.json（pending）
//      看板（ShoWork.Win\HandoverClear.cs）看到它閒下來（最後一張卡就是 wrapup、不在工作、沒開對話框）⇒ 對它的終端機送 /clear
//   ③ /clear 後的 SessionStart（showork brief）認領這筆：名字沿用、派工單轉到新 sid、注入接手提示；看板再打一句「開始接手」叫它動起來
// 收尾後、/clear 前使用者又下新指令 ⇒ interrupted（不自動 /clear，`showork tick` 轉隊長提醒）；之後 ctx 再多 150k Stop hook 會再收一次。

sealed class HandoverRecord
{
    // pending＝收尾完，等它閒下來送 /clear；interrupted＝收尾後使用者又派新工作：不自動 /clear；
    // clearing＝/clear 已送，等新 sid 出現；taken＝新 context 已認領；failed＝送不出去／送了沒換 sid：要使用者手動
    public static readonly string[] States = { "pending", "interrupted", "clearing", "taken", "failed" };

    public string Sid = "";
    public int Pid;
    public string Cwd = "";
    public string Name = "";
    public string Handoff = "";          // 交接文件絕對路徑
    public string? Summary;              // 一句接手重點
    public DateTime At;
    public string State = "pending";
    public string? NewSid;
    public DateTime? ClearAt;
    public string? Via;                  // Mac：tmux／ghostty；Windows：console
    public bool Kicked;                  // 已打「開始接手」
    public bool Notified;                // interrupted／failed 已通知
    public string? Note;                 // 失敗原因
    public List<string> Tasks = new();   // 轉到新 sid 的派工單

    /// 卡片／名冊上的標記
    public string? Label => State switch
    {
        "pending" => "已收尾待 /clear",
        "interrupted" => "已收尾、又接新工作",
        "clearing" => "/clear 中",
        "failed" => "自動 /clear 失敗",
        _ => null,
    };

    /// Swift synthesized Codable：有預設值但不是 Optional 的（kicked、notified、tasks）一定要寫，Mac 才讀得回去
    public JsonObject ToJson()
    {
        var o = new JsonObject { ["sid"] = Sid, ["pid"] = Pid, ["cwd"] = Cwd, ["name"] = Name, ["handoff"] = Handoff };
        o.Put("summary", Summary);
        o["at"] = HookJson.Iso(At); o["state"] = State;
        o.Put("newSid", NewSid); o.Put("clearAt", ClearAt); o.Put("via", Via);
        o["kicked"] = Kicked; o["notified"] = Notified;
        o.Put("note", Note);
        o["tasks"] = HookJson.Arr(Tasks);
        return o;
    }

    public static HandoverRecord? From(JsonNode? o)
    {
        if (o.Str("sid") is not { } sid || o.Int("pid") is not { } pid || o.Str("cwd") is not { } cwd || o.Str("name") is not { } name
            || o.Str("handoff") is not { } h || o.Date("at") is not { } at || o.Str("state") is not { } st || !States.Contains(st)) return null;
        return new HandoverRecord
        {
            Sid = sid, Pid = pid, Cwd = cwd, Name = name, Handoff = h, Summary = o.Str("summary"), At = at, State = st, NewSid = o.Str("newSid"),
            ClearAt = o.Date("clearAt"), Via = o.Str("via"), Kicked = o.Bool("kicked"), Notified = o.Bool("notified"), Note = o.Str("note"), Tasks = o.Strs("tasks"),
        };
    }
}

static class Handover
{
    /// 認領期限：收尾後這麼久內的新 session 才算接手（60 分鐘）
    public static readonly TimeSpan Window = TimeSpan.FromSeconds(3600);
    /// 鍵盤要靜這麼久才送 /clear（10-26 Kang：收尾完就直接 /clear，不等鍵盤）
    public static readonly TimeSpan KeyIdle = TimeSpan.Zero;
    /// 送 /clear 後這麼久沒換 sid ⇒ 失敗
    public static readonly TimeSpan ClearTimeout = TimeSpan.FromSeconds(20);

    public static string Dir => HookPaths.Env("SHOWORK_HANDOVER_DIR") ?? Path.Combine(HookPaths.Board, "handover");

    public static HandoverRecord? Load(string sid) => HandoverRecord.From(HookJson.ReadObject(Path.Combine(Dir, sid + ".json")));

    public static List<HandoverRecord> All() =>
        HookJson.Files(Dir, "*.json").Select(f => HandoverRecord.From(HookJson.ReadObject(f))).OfType<HandoverRecord>().OrderBy(r => r.At).ToList();

    public static bool Save(HandoverRecord r) => HookJson.WriteAtomic(Path.Combine(Dir, r.Sid + ".json"), HookJson.Text(r.ToJson()));

    /// 新 context 要認領哪一筆（SessionStart）：
    ///   compact＝同一個 sid；其他（clear／startup／resume）先找同一個 claude 行程，再找同資料夾而且原 session 已經不在的
    /// live＝現在活著的 sessionId（不含自己）
    public static HandoverRecord? Match(List<HandoverRecord> rs, string sid, int? pid, string? cwd, string? source, ISet<string> live, DateTime now)
    {
        var fresh = rs.Where(r => r.State != "taken" && now - r.At < Window && r.Sid != "").ToList();
        if (source == "compact") return fresh.LastOrDefault(r => r.Sid == sid);
        if (pid is { } p && fresh.LastOrDefault(r => r.Pid == p && r.Sid != sid) is { } hit) return hit;
        if (cwd == null) return null;
        var c = Normal(cwd);
        return fresh.LastOrDefault(r => Normal(r.Cwd) == c && r.Sid != sid && !live.Contains(r.Sid));
    }

    /// 同一個資料夾的寫法統一：Windows 路徑不分大小寫、斜線一律反斜線、去掉結尾分隔符號（Mac：URL.standardizedFileURL）
    public static string Normal(string p)
    {
        p = p.Trim();
        bool win = p.Length >= 2 && p[1] == ':' || p.Contains('\\');
        if (win) p = p.Replace('/', '\\').ToLowerInvariant();
        var sep = win ? '\\' : '/';
        while (p.Length > 1 && p[^1] == sep && !(win && p.Length == 3)) p = p[..^1];
        return p;
    }

    /// 注入給新 context 的接手提示（SessionStart additionalContext）
    public static string ResumeContext(HandoverRecord r, List<string> tasks)
    {
        var t = $"【自動接手】你是 {r.Name} 的接手（上一段 context 在 {Clock(r.At)} 收尾）。先完整讀交接文件 {r.Handoff}（和它指定要讀的文件），"
            + "照裡面的「下一步」直接接著做，不用等使用者重新交代；遇到交接裡寫明要等使用者決定的事就跳過、做下一件。"
            + $"名字沿用 {r.Name}（自報 showork card 照常）";
        t += tasks.Count == 0 ? "。" : $"，派工單沿用：{string.Join("、", tasks)}（回報照樣帶 --task）。";
        if (r.Summary is { Length: > 0 } s) t += $"上一段留的接手重點：{s}";
        return t;
    }

    /// /clear 後看板打進去的那一句（真的讓它動起來；SessionStart 的提示萬一沒進去，這句也帶著交接路徑）
    public static string Kickoff(HandoverRecord r) => $"【自動接手】請接手 {r.Name} 的工作：先讀 {r.Handoff}，照裡面的下一步繼續。";

    static string Clock(DateTime d) => d.ToLocalTime().ToString("HH:mm", CultureInfo.InvariantCulture);

    /// 看板能不能送 /clear 了：還在 pending（使用者沒打斷）、不在工作、沒開對話框、最後一張不是開工卡、停了 5 秒
    public static bool ReadyToClear(string state, string? lastKind, bool working, bool dialog, DateTime? lastActivity, TimeSpan keyIdle, DateTime now)
    {
        // T1026230337：收尾後被訊息叫醒、回完又發一般卡片，不再讓收尾作廢；使用者本人打斷由 NoteNewPrompt 改成 interrupted 處理
        if (state != "pending" || lastKind == "start" || working || dialog || keyIdle < KeyIdle) return false;
        return lastActivity is not { } t || now - t >= TimeSpan.FromSeconds(5);
    }

    // MARK: 認領：名字沿用、派工單轉手

    /// SessionStart 用：認領、沿用名字、轉派工單，回傳要注入的提示；沒得認領＝null
    public static string? Claim(string sid, int? pid, string? cwd, string? source, DateTime now)
    {
        var live = PeerSession.Live().Select(r => r.SessionId).Where(s => s != sid).ToHashSet();
        if (Match(All(), sid, pid, cwd, source, live, now) is not { } r) return null;
        var moved = new List<string>();
        if (r.Sid != sid)
        {
            NicknameStore.Save(sid, new Nickname { Name = r.Name, Doing = NicknameStore.Get(r.Sid)?.Doing, At = now, HandoverFrom = r.Sid });
            foreach (var t in CaptainStore.Tasks().Where(t => t.IsOpen && (t.ToSession == r.Sid || (t.ToSession == null && t.To == r.Name))))
            {
                t.ToSession = sid; t.To = r.Name;
                if (CaptainStore.Save(t)) moved.Add(t.Id);
            }
        }
        else moved = CaptainStore.Tasks().Where(t => t.IsOpen && t.ToSession == sid).Select(t => t.Id).ToList();
        r.State = "taken"; r.NewSid = sid; r.Tasks = moved;
        Save(r);
        return ResumeWithHeld(r, moved);
    }

    /// 接手提示＋收尾期間暫存的訊息（取出後清掉）
    public static string ResumeWithHeld(HandoverRecord r, List<string> tasks)
    {
        var held = TakeHeld(r.Sid);
        if (held.Count == 0) return ResumeContext(r, tasks);
        return ResumeContext(r, tasks) + $"\n【收尾期間暫存、現在補交給你的 {held.Count} 則訊息】（讀完交接後照常處理；隊長另跑 showork captain 看未 ack 收件匣）\n"
            + string.Join("\n", held.Select(h => $"— 來自 {h.From}：{h.Text}"));
    }

    /// UserPromptSubmit 用：收尾後、/clear 前「使用者本人」又下指令 ⇒ interrupted（看板轉隊長提醒）。
    /// 其他 session 的訊息、巡檢、工作回報／派工回報轉送都不算打斷；沒打斷但還在等 /clear ⇒ 回一段提醒
    public static string? NoteNewPrompt(string sid, string? prompt, DateTime now)
    {
        if (Load(sid) is not { State: "pending" } r) return null;
        if (IsUserPrompt(prompt))
        {
            r.State = "interrupted"; r.Note = "使用者又下指令";
            Save(r);
            Log($"interrupted {r.Name} {Short(r.Sid)}：使用者又下指令", now);
            return null;
        }
        Log($"keep {r.Name} {Short(r.Sid)}：{Sender(prompt)} 的訊息不算打斷，收尾照舊", now);
        return "【交接中】你已收尾、在等戰情中心自動 /clear。這則是其他 session／看板的訊息，不算打斷：簡短處理或回覆後就停下；"
            + $"有新進度就補進交接文件 {r.Handoff}，不用再發收尾卡（發一般卡片也不影響自動 /clear）。";
    }

    /// 使用者本人：在那個視窗直接打的字，或戰情中心轉來的「使用者回答／使用者交辦」
    public static bool IsUserPrompt(string? prompt)
    {
        var p = prompt?.Trim();
        if (string.IsNullOrEmpty(p)) return false;
        if (p.StartsWith("<cross-session-message", StringComparison.Ordinal))
        {
            var head = p.Split('>')[0];
            return head.Contains("from-name=\"AI工作戰情中心（使用者", StringComparison.Ordinal);
        }
        return CaptainLink.NeedsStart(p);
    }

    static string Sender(string? prompt)
    {
        const string k = "from-name=\"";
        int i = prompt?.IndexOf(k, StringComparison.Ordinal) ?? -1;
        if (i < 0) return "非使用者";
        var rest = prompt![(i + k.Length)..];
        int j = rest.IndexOf('"');
        return j < 0 ? rest : rest[..j];
    }

    static string Short(string sid) => sid[..Math.Min(8, sid.Length)];

    // MARK: 收尾期間暫存：看板／隊長流程要送給「已收尾等 /clear」的 session 的訊息先存著，新 context 接手時一起交給它

    /// 收尾中（pending／clearing）而且不是使用者本人的訊息 ⇒ 暫存不送
    public static bool ShouldHold(string sid, string fromName)
    {
        if (Load(sid) is not { State: "pending" or "clearing" }) return false;
        return !fromName.Contains("（使用者", StringComparison.Ordinal) && !fromName.Contains("（交接）", StringComparison.Ordinal);
    }

    static string HeldPath(string sid) => Path.Combine(Dir, "held", sid + ".jsonl");

    public static void Hold(string sid, string text, string fromName, DateTime now)
    {
        HookJson.AppendLine(HeldPath(sid), HookJson.Text(new JsonObject { ["at"] = HookJson.Iso(now), ["from"] = fromName, ["text"] = text }));
        Log($"hold → {Load(sid)?.Name ?? Short(sid)}（{fromName}）：{SwiftText.Prefix(text, 40)}", now);
    }

    /// 取出並清掉暫存（接手時用）
    public static List<(string From, string Text)> TakeHeld(string sid)
    {
        var text = HookJson.ReadText(HeldPath(sid));
        if (text == null) return new();
        try { File.Delete(HeldPath(sid)); } catch { }
        return text.Split('\n', StringSplitOptions.RemoveEmptyEntries).Select(HookJson.Parse)
                   .Where(o => o.Str("text") != null).Select(o => (o.Str("from") ?? "", o.Str("text")!)).ToList();
    }

    /// 寫 board\handover.log（看板 HandoverClear 也寫同一份）
    public static void Log(string msg, DateTime now)
    {
        var path = Path.Combine(Path.GetDirectoryName(Dir.TrimEnd('/', '\\'))!, "handover.log");
        HookJson.AppendLine(path, $"{now.ToLocalTime():yyyy-MM-dd HH:mm:ss} {msg}");
    }
}
