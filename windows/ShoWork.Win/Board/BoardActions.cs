using System.Diagnostics;
using System.Globalization;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using ShoWork.Hooks;

namespace ShoWork;

// 11-02 P8 第二輪：戰情中心的動作。Mac 版 Sources/ShoWorkAgent/BoardActions.swift（Reviewer、BoardActions、CtxGuard、TaskRouter、Tools）逐段轉寫。
// 派工單、權限回答檔、事先放行、收件匣直送的資料格式與讀寫用 hook 端已轉寫的 showork\Core（ShoWork.Hooks.*），不重複寫一份。
// 跟 Mac 不同的地方（照實記）：
//   • 打字進終端機：Mac 是 tmux send-keys（只有開在 tmux 裡的才送得到）；Windows 一律走 TermSend（AttachConsole＋WriteConsoleInputW，
//     不管 conhost 或 Windows Terminal 都送得到）。所以「退回」「回答」先 TermSend，失敗才 Peer（收件匣直送）、最後才拷貝到剪貼簿。
//   • 跨 session 收件匣直送用 showork\Core\Peer.cs（hook 端已轉寫；Windows 的 messagingSocketPath 還沒在真機驗證過）。
//   • 設定：Mac 存在 UserDefaults ai.okle42.showork；Windows 存在 %LOCALAPPDATA%\ShoWork42\board\prefs.json（同樣的 key）。
//   • 系統通知：Mac 用 osascript；Windows 交給 BoardActions.Notify（BoardForm 顯示在戰情中心底部＋記 log）。
//   • ctx 門檻：同 Mac 10-29 只看 token（工具列「ctx 250k ⌄」寫 board\prefs.json 的 board.ctxTokens）。卡片上 ctx 變紅仍用 settings.json 的 %（原本 Windows 的設定）。
// 這個檔不碰 WinForms：要碰畫面的（剪貼簿、跳到視窗）由 BoardForm 填進 BoardActions 的委派（測試換成假的）。

// MARK: - 設定（Mac：UserDefaults ai.okle42.showork）

public static class BoardPrefs
{
    static readonly object gate = new();
    static JsonObject? cache;
    static string? cachePath;
    /// 跟 hook 端（showork\Core\Prefs.cs）同一份檔、同一個環境變數（SHOWORK_PREFS 給測試換）
    public static string Path_ => Environment.GetEnvironmentVariable("SHOWORK_PREFS") is { Length: > 0 } p ? p : Path.Combine(Wire.SupportDir, "board", "prefs.json");

    static string cacheStamp = "";
    /// 檔案變了（別的行程寫的，例如 hook 端或另一個戰情中心視窗）就重讀
    static JsonObject Load()
    {
        var st = BoardText.Stamp(Path_);
        if (cachePath != Path_ || cacheStamp != st) { cache = null; cachePath = Path_; cacheStamp = st; }
        if (cache != null) return cache;
        try { cache = BoardText.Read(Path_) is { } j ? JsonNode.Parse(j) as JsonObject : null; } catch { cache = null; }
        return cache ??= new JsonObject();
    }

    public static bool Bool(string key, bool fallback)
    {
        lock (gate) return Load()[key] is JsonValue v && v.TryGetValue<bool>(out var b) ? b : fallback;
    }
    public static string? Str(string key)
    {
        lock (gate) return Load()[key] is JsonValue v && v.TryGetValue<string>(out var s) ? s : null;
    }
    public static JsonNode? Node(string key) { lock (gate) return Load()[key]?.DeepClone(); }

    public static void Set(string key, JsonNode? value)
    {
        lock (gate)
        {
            var o = Load();
            o[key] = value?.DeepClone();
            BoardText.WriteAtomic(Path_, o.ToJsonString(new JsonSerializerOptions { WriteIndented = true, Encoder = BoardText.Relaxed.Encoder }));
            cacheStamp = BoardText.Stamp(Path_);
        }
    }

    /// 測試用：丟掉快取
    public static void Reset() { lock (gate) cache = null; }
}

// MARK: - 跑外部指令（Mac Tools）

public static class Tools
{
    /// claude 在哪（同 DecorRunner.claude：原生 claude.exe、PATH、npm 全域包著的 claude.exe）
    public static (string exe, List<string> pre)? Claude() =>
        Environment.GetEnvironmentVariable("SHOWORK_CLAUDE_EXE") is { Length: > 0 } x ? (x, new()) : DecorRunner.claude();

    /// 跑一個指令，等它結束（呼叫端自己放在背景執行緒）
    public static (int code, string @out, string err) Run(string exe, IEnumerable<string> args, string? cwd = null, IReadOnlyDictionary<string, string>? env = null,
                                                         string? stdin = null, int timeoutMs = 60_000)
    {
        try
        {
            var psi = new ProcessStartInfo(exe)
            {
                RedirectStandardInput = true, RedirectStandardOutput = true, RedirectStandardError = true, UseShellExecute = false, CreateNoWindow = true,
                StandardOutputEncoding = Encoding.UTF8, StandardErrorEncoding = Encoding.UTF8,
            };
            if (cwd != null && Directory.Exists(cwd)) psi.WorkingDirectory = cwd;
            foreach (var a in args) psi.ArgumentList.Add(a);
            if (env != null) foreach (var (k, v) in env) psi.Environment[k] = v;
            using var p = Process.Start(psi)!;
            // stdout、stderr 同時讀（Mac 10-22：stderr 灌滿管道 64KB ⇒ 子行程卡住、這邊卡在讀 stdout ⇒ 互等到逾時）
            var o = p.StandardOutput.ReadToEndAsync(); var e = p.StandardError.ReadToEndAsync();
            using (var w = new StreamWriter(p.StandardInput.BaseStream, new UTF8Encoding(false))) { if (stdin != null) w.Write(stdin); }
            if (!p.WaitForExit(timeoutMs)) { try { p.Kill(true); } catch { } return (-2, o.IsCompleted ? o.Result : "", "逾時"); }
            p.WaitForExit();
            return (p.ExitCode, o.Result, e.Result);
        }
        catch (Exception x) { return (-1, "", x.Message); }
    }

    /// claude 加前置參數（npm 舊版是 node cli.js）
    public static (int code, string @out, string err) RunClaude(IEnumerable<string> args, string? cwd = null, IReadOnlyDictionary<string, string>? env = null,
                                                               string? stdin = null, int timeoutMs = 60_000)
    {
        if (Claude() is not { } c) return (-1, "", "找不到 claude 指令");
        return Run(c.exe, c.pre.Concat(args), cwd, env, stdin, timeoutMs);
    }
}

/// board/history.jsonl：看到的、你做的都記一行（Mac BoardModel.append；Windows 只寫不讀）
public static class BoardHistory
{
    public static string File => Path.Combine(Wire.SupportDir, "board", "history.jsonl");
    public static void Append(IDictionary<string, string> o)
    {
        var d = new SortedDictionary<string, string>(o, StringComparer.Ordinal) { ["at"] = DateTime.UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", CultureInfo.InvariantCulture) };
        BoardText.AppendLine(File, JsonSerializer.Serialize(d, BoardText.Relaxed));
    }
}

/// board/ 底下每個 session 一個 JSON（Mac BoardStore.write）
public static class BoardStore
{
    public static string Dir(string kind) => Path.Combine(Wire.SupportDir, "board", kind);
    public static void Write<T>(string kind, string sid, T v) => BoardText.WriteAtomic(Path.Combine(Dir(kind), sid + ".json"), BoardJson.Encode(v));
}

// MARK: - 派工單（Captain.swift；讀寫與直送在 hook 端 showork\Core\CaptainTasks.cs：Hooks.CaptainTask／Dispatch／CaptainStore）

public static class CaptainTasks
{
    public static string Title(CaptainTaskInfo.TaskState s) => Hooks.CaptainTask.Title(s.ToString());
    /// 還沒結束（隊長要繼續追）
    public static bool Open(CaptainTaskInfo.TaskState s) => s is CaptainTaskInfo.TaskState.sent or CaptainTaskInfo.TaskState.working or CaptainTaskInfo.TaskState.blocked;

    /// board\tasks 全部（舊的在前）→ 卡片／網頁用的形狀
    public static List<CaptainTaskInfo> All() => Hooks.CaptainStore.Tasks().Select(Of).ToList();

    internal static CaptainTaskInfo Of(Hooks.CaptainTask t) => new()
    {
        Id = t.Id, From = t.From, To = t.To, ToSession = t.ToSession, Project = t.Project, Text = t.Text,
        State = Enum.TryParse<CaptainTaskInfo.TaskState>(t.State, out var st) ? st : CaptainTaskInfo.TaskState.sent,
        Summary = t.Summary, Ask = t.Ask, CreatedAt = t.CreatedAt, UpdatedAt = t.UpdatedAt, ThenTo = t.ThenTo, ThenText = t.ThenText,
        FollowUp = t.FollowUp, After = t.After, Notified = Enum.TryParse<CaptainTaskInfo.TaskState>(t.Notified ?? "", out var n) ? n : null, SendError = t.SendError,
    };
}

// MARK: - 你的動作（BoardActions）

static class BoardActions
{
    // ── 碰畫面／外部的部分（BoardForm 填；測試換成假的） ──
    /// 拷貝到剪貼簿
    public static Func<string, bool> CopyToClipboard = _ => false;
    /// 跳到那個 AI 的終端機視窗（找不到回 false）
    public static Func<BoardCard, bool> FocusWindow = _ => false;
    /// 打字進終端機（Mac：tmux send-keys）
    public static Func<string, string, bool, TermSend.Result> TypeInto = (sid, text, enter) => TermSend.Send(sid, text, enter);
    /// 找開著的 session（名字、英文名、sessionId）
    public static Func<string, PeerSession?> FindPeer = who => Peer.Find(who);
    /// 送進收件匣
    public static Func<PeerSession, string, string, string?, (string? Id, string? Error)> SendPeer = (r, text, from, replyTo) => Peer.Send(r, text, from, replyTo);
    /// 系統通知（Mac osascript display notification）
    public static Action<string, string> Notify = (title, body) => Log.Note($"NOTICE {title}：{body}");

    /// showork.exe 的位置（派工訊息裡給對方 AI 看的回報指令）。開發 build 在 exe 旁邊；安裝版在 %LOCALAPPDATA%\ShoWork42\bin
    public static string Showork
    {
        get
        {
            var dev = Path.Combine(AppContext.BaseDirectory, "showork.exe");
            var p = File.Exists(dev) ? dev : Path.Combine(Wire.SupportDir, "bin", "showork.exe");
            return p.Replace('\\', '/');
        }
    }

    public static void Approve(BoardCard c)
    {
        BoardStore.Write("decisions", c.SessionId, new Decision { Action = DecisionAction.Approve, At = DateTime.UtcNow });
        BoardHistory.Append(new Dictionary<string, string> { ["ev"] = "approve", ["id"] = c.SessionId, ["project"] = c.Project, ["title"] = c.Title });
    }

    public static void Park(BoardCard c, string? note)
    {
        BoardStore.Write("decisions", c.SessionId, new Decision { Action = DecisionAction.Park, Note = string.IsNullOrEmpty(note) ? null : note, At = DateTime.UtcNow });
        BoardHistory.Append(new Dictionary<string, string> { ["ev"] = "park", ["id"] = c.SessionId, ["project"] = c.Project, ["note"] = note ?? "" });
    }

    /// 退回的結果：打進去了（Typed）／拷貝了（Message＝給 toast 的一句話）
    public readonly record struct SendResult(bool Typed, string Message);

    /// 退回＋補一句指示：打進那個 session 按 Enter（TermSend）；打不進去就拷貝到剪貼簿並跳到那個視窗
    public static SendResult SendBack(BoardCard c, string text)
    {
        var line = TermSend.Normalize(text);
        BoardHistory.Append(new Dictionary<string, string> { ["ev"] = "sendback", ["id"] = c.SessionId, ["project"] = c.Project, ["text"] = line });
        var r = TypeInto(c.SessionId, line, true);
        Log.Note($"BOARD sendback {Short(c.SessionId)} → {r.Outcome} {r.Message}");
        if (r.Ok) return new(true, $"已送進「{c.Title}」");
        CopyToClipboard(line);
        return new(false, FocusWindow(c) ? "已拷貝，並跳到那個視窗；貼上後按 Enter。" : "已拷貝到剪貼簿；找不到那個視窗，請自己切過去貼上。");
    }

    /// 3D 辦公室直接回答：先打字送進輸入框（TermSend）；打不進去就走看板直送（Peer，跟派工同一條），兩條都不通才退回拷貝。
    /// 不先動剪貼簿（Mac 10-18：蓋掉他的剪貼簿）
    public static string Answer(BoardCard c, string text, DateTime? now = null)
    {
        var line = InboxText.Message(text);
        var t = now ?? DateTime.UtcNow;
        try
        {
            // Mac 10-31：戰情中心的回答本身就是使用者的決定 ⇒ 答「放行」直接放行這個 AI 等著的單；答案點名的對外動作記成事先放行
            if (line.StartsWith("放行", StringComparison.Ordinal))
                CaptainInbox.Release(null, c.SessionId, "戰情中心", "使用者（戰情中心回答）", "戰情中心回答", t);
            else
                CaptainInbox.RecordAnswer(c.SessionId, line, c.Report?.Ask, t);
            var r = TypeInto(c.SessionId, line, true);
            Log.Note($"BOARD answer {Short(c.SessionId)} term → {r.Outcome} {r.Message}");
            if (r.Ok)
            {
                BoardHistory.Append(new Dictionary<string, string> { ["ev"] = "sendback", ["id"] = c.SessionId, ["project"] = c.Project, ["text"] = line });
                return $"已送進「{c.Title}」";
            }
            if (FindPeer(c.SessionId) is { } peer)
            {
                BoardHistory.Append(new Dictionary<string, string> { ["ev"] = "answer", ["id"] = c.SessionId, ["project"] = c.Project, ["text"] = line });
                var (id, err) = SendPeer(peer, CaptainThread.AnswerPrefix + line, "AI工作戰情中心（使用者）", null);
                if (id != null) return $"已送給「{c.Title}」";
                Log.Note($"BOARD answer peer failed: {err}");
            }
            return SendBack(c, line).Message;
        }
        finally { TellCaptain(c, line); }
    }

    /// 使用者答了組員卡片的問題 ⇒ 轉隊長一則「【使用者已答】」、清掉隊長卡片上同一題（隊長 Penny 10-25：別再重複問使用者）。
    /// 答的是隊長自己的卡片就不用轉
    static void TellCaptain(BoardCard c, string answer)
    {
        if (ShoWork.Hooks.CaptainStore.Captain() is not { } cap || cap == c.SessionId) return;
        var q = c.Report?.Ask;
        Answered.ClearCaptainCard(cap, q);
        var name = NicknameStore.Get(c.SessionId)?.Name ?? c.Title;
        var text = Answered.Relay(name, q, answer);
        Task.Run(() =>
        {
            if (FindPeer(cap) is not { } to) return;
            var (_, err) = SendPeer(to, text, "AI工作戰情中心（使用者已答）", null);
            if (err != null) Log.Note($"BOARD answered relay failed: {err}");
        });
    }

    /// 權限對話框：在收件匣按了允許／一律允許／拒絕 ⇒ 寫回答檔，等著的 hook（showork permit）讀到就回給 Claude Code
    /// `decision`＝allow／always／deny；`answers`＝選擇題的 {題目: [選的]}
    public static string AnswerPermit(BoardCard c, string decision, string? message, Dictionary<string, List<string>>? answers, string? dir = null)
    {
        if (c.Permit is not { } shown || Hooks.PermitRequest.From(HookJson.ReadObject(Hooks.Permit.RequestPath(shown.Id, dir))) is not { } p) return $"「{c.Title}」的對話框已經關了";
        var a = new Hooks.PermitAnswer { Decision = decision is "always" or "deny" ? decision : "allow", Message = string.IsNullOrWhiteSpace(message) ? null : message, Answers = answers };
        if (!Hooks.Permit.Answer(p.Id, a, dir)) return $"「{c.Title}」已經在終端機答過了";
        BoardHistory.Append(new Dictionary<string, string> { ["ev"] = "permit", ["id"] = c.SessionId, ["project"] = c.Project, ["tool"] = p.Tool, ["decision"] = a.Decision });
        Hooks.Permit.LogAnswer(p, a, DateTime.UtcNow, dir);
        if (p.IsAsk || p.IsPlan) return $"已回答「{c.Title}」：{Hooks.Permit.AnswerText(p, a)}";
        return a.Decision switch
        {
            "allow" => $"已允許「{c.Title}」",
            "always" => $"已允許「{c.Title}」，以後同類不再問",
            _ => $"已拒絕「{c.Title}」",
        };
    }

    /// 跳到那個 AI 的終端機視窗；找不到回給 toast 的一句話（找到回 null）
    public static string? Focus(BoardCard c) =>
        FocusWindow(c) ? null : c.Kind == "bg" ? "這是背景 session，沒有視窗；用 claude attach 打開" : "找不到這個 session 的視窗";

    /// 新任務：在指定資料夾開官方背景 session（`claude --bg`）；回傳背景 id 或錯誤訊息
    public static (string? Id, string? Error) NewTask(string folder, string prompt, bool fullAuto)
    {
        if (Tools.Claude() == null) return (null, "找不到 claude 指令");
        var args = new List<string> { "--bg" };
        if (fullAuto) args.AddRange(new[] { "--permission-mode", "bypassPermissions" });
        args.Add(prompt);
        var r = Tools.RunClaude(args, folder, timeoutMs: 60_000);
        var all = r.@out + r.err;
        if (all.Split('\n').FirstOrDefault(l => l.Contains("backgrounded")) is { } line && line.Split('·').LastOrDefault()?.Trim() is { Length: > 0 } id) return (id, null);
        return (null, all.Trim().Length == 0 ? $"claude --bg 失敗（{r.code}）" : Board.Prefix(all, 300));
    }

    /// 看板上直接派工給某個 session（你按的）；有隊長就由隊長收回報，沒有就發系統通知給你
    public static (string? Id, string? Error) Dispatch(BoardCard c, string text, string? thenTo, string? thenText, string? captain)
    {
        var now = DateTime.UtcNow;
        var id = Hooks.Dispatch.NewId(now, Hooks.CaptainStore.Tasks().Select(t => t.Id).ToHashSet());
        var t = new Hooks.CaptainTask
        {
            Id = id, From = captain ?? "board", To = c.Name ?? c.SessionId, ToSession = c.SessionId, Project = c.Project, Text = text,
            CreatedAt = now, UpdatedAt = now, ThenTo = thenTo, ThenText = thenTo == null ? null : thenText,
        };
        var (_, err) = SendTask(t, "AI工作戰情中心（你從看板派的）");
        return err == null ? (id, null) : (null, err);
    }

    /// 建單＋直送（Mac Captain.dispatch；同 Hooks.Dispatch.Send，但找人、送訊息走 FindPeer／SendPeer，測試換得掉）。
    /// 送不出去時單子照樣留著（sendError），讓呼叫端改走 SendMessage
    internal static (Hooks.CaptainTask Task, string? Error) SendTask(Hooks.CaptainTask t, string fromName = "AI工作戰情中心")
    {
        var target = FindPeer(t.ToSession ?? t.To) ?? FindPeer(t.To);
        if (target != null) { t.ToSession = target.SessionId; t.To = target.Name ?? t.To; }
        var replyTo = FindPeer(t.From)?.MessagingSocketPath;
        var err = target == null ? $"找不到開著的 session「{t.To}」" : SendPeer(target, Hooks.Dispatch.Message(t, Showork), fromName, replyTo).Error;
        t.SendError = err;
        Hooks.CaptainStore.Save(t);
        return (t, err);
    }

    /// 把一件事交給隊長，由它決定給誰
    public static (string? Id, string? Error) ToCaptain(string sid, string text)
    {
        if (FindPeer(sid) is not { } cap) return (null, "隊長的 session 沒開著");
        var body = $"{CaptainThread.BoardPrefix}{text}\n請照隊長守則處理：先看名冊（showork roster），選人後用 showork task add 派工；小事自己做。";
        return SendPeer(cap, body, CaptainThread.BoardFromName, null);
    }

    // MARK: 收件匣：交給隊長（10-26 Kang：預設 Opus，需要判斷時再升 Fable）

    public static string CaptainModel => BoardPrefs.Str(CaptainLaunch.ModelKey) is { Length: > 0 } m ? m : CaptainLaunch.DefaultModel;
    /// 剛開的背景隊長（短 id、開的時間）：還沒登記好之前不要再開第二個
    static (string Id, DateTime At)? launching;
    static readonly object launchLock = new();

    /// 現在的隊長還開著嗎（行程在、有收件匣）
    public static PeerSession? LiveCaptain() => ShoWork.Hooks.CaptainStore.Captain() is { } sid ? FindPeer(sid) : null;

    /// 交給隊長：隊長在就直送；不在就開一個背景隊長（claude --bg --model <captainModel>），把這件事當它的第一句話。
    /// 會等（開 session 最多 30 秒），呼叫端放背景執行緒。
    public static string AskCaptain(string text)
    {
        var line = InboxText.Message(text);
        if (line.Length == 0) return "沒有內容";
        if (LiveCaptain() is { } cap)
        {
            var (_, err) = ToCaptain(cap.SessionId, line);
            return err == null ? $"已交給隊長「{cap.Name ?? "隊長"}」" : $"送不到隊長：{err}";
        }
        lock (launchLock)
        {
            if (launching is { } l && DateTime.UtcNow - l.At < TimeSpan.FromSeconds(120))
            {
                if (l.Id.Length > 0 && FindPeer(l.Id) is { } r)
                {
                    ShoWork.Hooks.CaptainStore.SetCaptain(r.SessionId, r.Name, DateTime.UtcNow);
                    return ToCaptain(r.SessionId, line).Error == null ? $"已交給隊長「{r.Name ?? "隊長"}」" : "送不到隊長";
                }
                return "隊長剛開，還在暖機；過半分鐘再送一次";
            }
            launching = ("", DateTime.UtcNow);
        }
        if (Tools.Claude() == null) { launching = null; return "找不到 claude 指令，開不了隊長"; }
        var prompt = CaptainLaunch.Bootstrap(Showork, line);
        var res = Tools.RunClaude(new[] { "--bg", "--model", CaptainModel, "-n", "隊長", "--permission-mode", "bypassPermissions", prompt }, BoardReader.DefaultHome, timeoutMs: 60_000);
        var all = res.@out + res.err;
        var bg = all.Split('\n').FirstOrDefault(x => x.Contains("backgrounded"));
        var id = bg?.Split('·').Skip(1).FirstOrDefault()?.Trim();
        if (id == null || id.Length < 6)
        {
            launching = null;
            return "開隊長失敗：" + Board.Prefix(all.Trim(), 200);
        }
        launching = (id, DateTime.UtcNow);
        Log.Note($"CAPTAIN launched {id} model={CaptainModel}");
        // 登記成隊長（它自己跑 showork captain 也會登記；先登記，下一句交辦才找得到它）
        for (int i = 0; i < 30; i++)
        {
            if (FindPeer(id) is { } rec)
            {
                ShoWork.Hooks.CaptainStore.SetCaptain(rec.SessionId, rec.Name, DateTime.UtcNow);
                return $"已開新隊長（{ModelTitle(CaptainModel)}），這件事是它的第一個任務";
            }
            Thread.Sleep(1000);
        }
        return $"已開新隊長（{ModelTitle(CaptainModel)}），正在暖機";
    }

    public static string ModelTitle(string m) => m switch
    {
        "claude-fable-5-1" => "Fable 5.1",
        "claude-opus-5-5" => "Opus 5.5",
        "claude-sonnet-5-5" => "Sonnet 5.5",
        _ => m,
    };

    /// 請那個 session 收尾（commit、規則允許才 push、更新交接）；回傳 "typed" 或說明
    public static string WrapUp(BoardCard c)
    {
        var text = CtxGuard.WrapUpPrompt(c.Ctx);
        BoardHistory.Append(new Dictionary<string, string> { ["ev"] = "wrapup", ["id"] = c.SessionId, ["project"] = c.Project, ["ctx"] = c.Ctx?.Tokens is { } k ? $"{k / 1000}k" : "" });
        CtxGuard.Shared.MarkSent(c.SessionId);
        var r = SendBack(c, text);
        return r.Typed ? "typed" : r.Message;
    }

    /// 保全面板「放行一次」（Mac PushGuard.allow）：同資料夾、同 HEAD 的下一次 push 放行，30 分鐘內有效
    public static readonly TimeSpan AllowFor = TimeSpan.FromMinutes(30);
    public static void PushAllow(string dir, string? head, DateTime? now = null, string? path = null)
    {
        if (string.IsNullOrEmpty(head)) return;
        var t = now ?? DateTime.UtcNow;
        var xs = PushGuard.Allows(path).Where(x => x.Until > t && !(x.Dir == dir && x.Head == head)).ToList();
        xs.Add(new PushGuard.Allow(dir, head, t + AllowFor));
        PushGuard.SaveAllows(xs, path);
    }

    static string Short(string sid) => sid[..Math.Min(8, sid.Length)];
}

// MARK: - 審核員（Reviewer）

public sealed class Reviewer
{
    public static readonly Reviewer Shared = new();
    public const string Model = "sonnet";
    readonly object gate = new();
    readonly HashSet<string> running = new();             // sessionId
    const int Limit = 2;                                  // 同時最多審幾個
    readonly Dictionary<string, List<DateTime>> started = new();   // 保險絲：同一個 session 一小時最多自動審 3 次

    /// 對話紀錄的位置（BoardForm 填：BoardReader.TranscriptPathOf）
    public Func<BoardCard, string?> TranscriptOf = _ => null;
    /// 跑審核員（測試換成假的）：prompt、cwd → (結束碼, stdout, stderr)
    public Func<string, string, (int code, string @out, string err)> Runner = (prompt, cwd) =>
        Tools.RunClaude(new[] { "-p", "--model", Model, "--output-format", "json", "--max-turns", "12",
                                "--allowedTools", "Read,Grep,Glob,Bash(git status:*),Bash(git diff:*),Bash(git log:*),Bash(git show:*)",
                                "--permission-mode", "default" },
                        cwd, new Dictionary<string, string> { ["SHOWORK_REVIEWER"] = "1" }, prompt, 300_000);
    /// 開審／審完（BoardForm 收到就重讀一次）
    public event Action? Changed;

    public bool Enabled
    {
        get => BoardPrefs.Bool("board.review", true);
        set => BoardPrefs.Set("board.review", value);
    }
    public bool IsRunning(string sid) { lock (gate) return running.Contains(sid); }
    public HashSet<string> Running { get { lock (gate) return running.ToHashSet(); } }

    /// 看板每次刷新都會叫；只有「在待審、這一輪還沒審」的才真的開審
    public void Consider(IEnumerable<BoardCard> cards, IReadOnlyDictionary<string, Review> reviews)
    {
        if (!Enabled) return;
        foreach (var c in cards)
        {
            lock (gate) if (c.IsQueued || running.Contains(c.SessionId) || running.Count >= Limit) continue;
            if (!CardRules.NeedsReview(c.Column, reviews.GetValueOrDefault(c.SessionId), c.LastActivity) || c.Reason == "等你回答") continue;   // 正在問你問題的不用審
            lock (gate)
            {
                var recent = (started.GetValueOrDefault(c.SessionId) ?? new()).Where(x => DateTime.UtcNow - x < TimeSpan.FromHours(1)).ToList();
                started[c.SessionId] = recent;
                if (recent.Count >= 3) continue;
            }
            Start(c, force: false);
        }
    }

    public void Start(BoardCard c, bool force)
    {
        if (c.LastActivity is not { } turn) return;
        lock (gate)
        {
            if (running.Contains(c.SessionId)) return;
            running.Add(c.SessionId);
            (started.TryGetValue(c.SessionId, out var l) ? l : started[c.SessionId] = new()).Add(DateTime.UtcNow);
        }
        Log.Note($"REVIEW start {c.SessionId} force={force}");
        Changed?.Invoke();
        var sid = c.SessionId;
        Task.Run(() =>
        {
            Review review;
            try
            {
                var path = TranscriptOf(c);
                var tail = path != null ? BoardText.Tail(path, 200_000) : Array.Empty<byte>();
                // 待命輪（沒動手）不開無頭審核員：一週約省幾百次 sonnet 呼叫；手動「重新審核」照審
                if (!force && !ReviewRules.LastTurnDidWork(tail))
                {
                    BoardStore.Write("reviews", sid, new Review { Verdict = "skip", Turn = turn, At = DateTime.UtcNow, Model = "-", CostUSD = 0 });
                    Log.Note($"REVIEW skip {sid} 這輪沒動手");
                    lock (gate)
                    {
                        running.Remove(sid);
                        if (started.TryGetValue(sid, out var l) && l.Count > 0) l.RemoveAt(l.Count - 1);   // 略過不算保險絲次數
                    }
                    Changed?.Invoke();
                    return;
                }
                var prompt = ReviewRules.ReviewPrompt(c.Project, c.Title, c.Report, ReviewRules.Excerpt(tail));
                var cwd = c.Cwd is { } d && Directory.Exists(d) ? d : BoardReader.DefaultHome;
                var r = Runner(prompt, cwd);
                string text = r.@out; double? cost = null;
                try
                {
                    if (JsonNode.Parse(r.@out) is JsonObject o)
                    {
                        if (o["result"] is JsonValue rv && rv.TryGetValue<string>(out var rs)) text = rs;
                        if (o["total_cost_usd"] is JsonValue cv && cv.TryGetValue<double>(out var cd)) cost = cd;
                    }
                }
                catch { }
                review = ReviewRules.ParseReview(text, turn, Model, cost)
                    ?? new Review { Verdict = "error", Turn = turn, At = DateTime.UtcNow, Model = Model, CostUSD = cost,
                                    Error = r.code == 0 ? "審核員沒有給出看得懂的結果" : $"審核員執行失敗（{r.code}）：{Board.Prefix(r.err, 120)}" };
                BoardStore.Write("reviews", sid, review);
                Log.Note($"REVIEW done {sid} code={r.code} verdict={review.Verdict}");
                BoardHistory.Append(new Dictionary<string, string>
                {
                    ["ev"] = "review", ["id"] = sid, ["verdict"] = review.Verdict, ["progress"] = review.Progress?.ToString() ?? "",
                    ["confidence"] = review.Confidence?.ToString() ?? "", ["cost"] = cost is { } x ? x.ToString("0.0000", CultureInfo.InvariantCulture) : "",
                });
            }
            catch (Exception x) { Log.Note($"REVIEW failed {sid}: {x.Message}"); }
            lock (gate) running.Remove(sid);
            Changed?.Invoke();
        });
    }
}

/// 審核員的規則（Mac Card.swift 的 CardRules.reviewPrompt／parseReview／lastTurnDidWork／excerpt）
public static class ReviewRules
{
    /// 給審核員的指示（對話摘錄另外附上）
    public static string ReviewPrompt(string project, string title, SelfReport? report, string excerpt)
    {
        var self_ = report != null
            ? $"AI 自報：status={MacMirror.Camel(report.Status.ToString())} 完成度={report.Progress?.ToString() ?? "?"} 信心={report.Confidence?.ToString() ?? "?"}\n摘要：{report.Summary ?? ""}\n"
              + (report.Ask != null ? $"要使用者決定：{report.Ask}\n" : "") + (report.Report != null ? $"報告檔：{report.Report}\n" : "")
            : "AI 沒有自報。\n";
        return $$"""
            你是審核員。另一個 AI 在專案「{{project}}」做「{{title}}」，剛結束一輪，請獨立判斷它做得怎樣。
            可以用 Read／Grep／Glob 和 git status／diff／log 查證它說做到的事；不要修改任何檔案。
            {{self_}}
            ===== 最近的對話摘錄 =====
            {{excerpt}}
            ===== 摘錄結束 =====
            最後只輸出一個 JSON（不要 markdown 圍欄、不要其他字）：
            {"progress": 0-100, "confidence": 0-100, "verdict": "pass|concern|fail", "issues": ["最多 3 條、每條一句繁體中文；沒問題就空陣列"]}
            progress＝你認為真正完成多少；confidence＝你多相信它做對了；只看到宣稱、沒有證據就壓低。
            """;
    }

    /// 審核員的輸出 → Review（容許前後夾雜文字或 ```json 圍欄）
    public static Review? ParseReview(string text, DateTime turn, string model, double? cost, DateTime? now = null)
    {
        int s = text.IndexOf('{'), e = text.LastIndexOf('}');
        if (s < 0 || e <= s) return null;
        try
        {
            if (JsonNode.Parse(text[s..(e + 1)]) is not JsonObject o) return null;
            int? Int(string k) => o[k] is JsonValue v && v.TryGetValue<double>(out var d) ? SelfReport.Clamp((int)d) : null;
            var v = o["verdict"] is JsonValue vv && vv.TryGetValue<string>(out var vs) && vs is "pass" or "concern" or "fail" ? vs : "concern";
            var issues = o["issues"] is JsonArray a ? a.Select(x => x is JsonValue xv && xv.TryGetValue<string>(out var t) ? t : null).OfType<string>().Take(3).ToList() : new();
            return new Review { Progress = Int("progress"), Confidence = Int("confidence"), Verdict = v, Issues = issues, Turn = turn, At = now ?? DateTime.UtcNow, Model = model, CostUSD = cost };
        }
        catch { return null; }
    }

    /// 最後一輪（最後一句使用者的話之後）有沒有真的動手：只回話、只發卡片／查名冊／讀通知的「待命」輪不用開審核員。
    /// 尾端找不到使用者那句話（輪太長被截掉）時當作有動手。
    public static bool LastTurnDidWork(ReadOnlySpan<byte> tail)
    {
        bool worked = true;
        foreach (var raw in BoardText.Lines(tail))
        {
            JsonNode? n;
            try { n = JsonNode.Parse(raw); } catch { continue; }
            if (n is not JsonObject o || o["message"] is not JsonObject m) continue;
            switch (o["type"]?.ToString())
            {
                case "user":
                    if (m["content"] is JsonValue) worked = false;
                    else if (m["content"] is JsonArray ps && !ps.Any(p => p?["type"]?.ToString() == "tool_result")) worked = false;
                    break;
                case "assistant":
                    foreach (var p in m["content"] as JsonArray ?? new JsonArray())
                    {
                        if (p?["type"]?.ToString() != "tool_use") continue;
                        var name = p["name"]?.ToString() ?? "";
                        var cmd = p["input"]?["command"]?.ToString() ?? "";
                        if (name is "ListAgents" or "ReadNotifications" or "ToolSearch") continue;
                        if (name == "Bash" && (cmd.Contains("/showork\"") || cmd.Contains("/showork.exe\"")) && (cmd.Contains(" card ") || cmd.Contains(" names"))) continue;
                        worked = true;
                    }
                    break;
            }
        }
        return worked;
    }

    /// 對話紀錄尾端 → 給審核員看的摘錄（你說的話、AI 說的話、用了哪些工具），最多 `limit` 字
    public static string Excerpt(ReadOnlySpan<byte> tail, int limit = 12_000)
    {
        var out_ = new List<string>();
        foreach (var raw in BoardText.Lines(tail))
        {
            JsonNode? n;
            try { n = JsonNode.Parse(raw); } catch { continue; }
            if (n is not JsonObject o || o["message"] is not JsonObject m) continue;
            switch (o["type"]?.ToString())
            {
                case "user":
                    if (m["content"] is JsonValue cv && cv.TryGetValue<string>(out var c) && !c.StartsWith('<')) out_.Add($"【使用者】{c}");
                    break;
                case "assistant":
                    foreach (var p in m["content"] as JsonArray ?? new JsonArray())
                    {
                        if (p?["type"]?.ToString() == "text" && p["text"] is JsonValue tv && tv.TryGetValue<string>(out var t)) out_.Add($"【AI】{t}");
                        if (p?["type"]?.ToString() == "tool_use" && p["name"]?.ToString() is { } nm)
                        {
                            var inp = p["input"] as JsonObject;
                            var x = (inp?["command"] ?? inp?["file_path"] ?? inp?["pattern"] ?? inp?["description"]) is JsonValue iv && iv.TryGetValue<string>(out var s) ? s : "";
                            out_.Add($"【工具 {nm}】{Board.Prefix(x, 200)}");
                        }
                    }
                    break;
            }
        }
        var str = string.Join("\n", out_);
        if (str.Length > limit) str = "⋯（前面省略）\n" + str[^limit..];
        return str;
    }
}

// MARK: - ctx 快滿：提醒＋自動收尾（Kang 10-09）

public sealed class CtxGuard
{
    public static readonly CtxGuard Shared = new();
    static string StatePath => Path.Combine(Wire.SupportDir, "board", "ctxguard.json");
    readonly Dictionary<string, DateTime> notified = new(), sent = new();
    bool loaded;

    public bool AutoWrapUp
    {
        get => BoardPrefs.Bool("board.autoWrapUp", true);
        set => BoardPrefs.Set("board.autoWrapUp", value);
    }

    void Load()
    {
        if (loaded) return;
        loaded = true;
        try
        {
            if (BoardText.Read(StatePath) is not { } j || JsonNode.Parse(j) is not JsonObject o) return;
            foreach (var (k, dict) in new[] { ("notified", notified), ("sent", sent) })
                if (o[k] is JsonObject x)
                    foreach (var (sid, v) in x) if (TranscriptInfo.Iso(v?.ToString()) is { } d) dict[sid] = d;
        }
        catch { }
    }

    void Save()
    {
        JsonObject D(Dictionary<string, DateTime> x) { var o = new JsonObject(); foreach (var (k, v) in x) o[k] = BoardJson.Format(v); return o; }
        BoardText.WriteAtomic(StatePath, new JsonObject { ["notified"] = D(notified), ["sent"] = D(sent) }.ToJsonString());
    }

    /// Stop hook（~/.claude/scripts/hook_ctx_wrapup.py）請它收尾過就會留這個檔
    static bool HookHandled(string sid) => File.Exists(Path.Combine(BoardReader.DefaultClaudeDir, "cache", "ctx_wrapup", sid));
    public bool WasSent(string sid) { Load(); return sent.ContainsKey(sid) || HookHandled(sid); }

    /// 門檻只有一條：context 用到幾 token 就交接（Mac 10-29；board\prefs.json 的 board.ctxTokens，hook 端的 Stop hook 讀同一份）
    public static int TokenLimit => Hooks.ContextGuard.TokenLimit;
    public static readonly int[] TokenPresets = { 250_000, 300_000, 400_000, 500_000, 600_000, 800_000, 1_000_000 };
    public static void SetTokenLimit(int v) => BoardPrefs.Set("board.ctxTokens", Hooks.ContextGuard.Clamp(v));
    public static bool Over(ContextUse c, int? limit = null) => (c.Tokens ?? 0) >= (limit ?? TokenLimit);

    /// 打進那個 session 的收尾指令。push 與否交給那個 session 的 AI 依該 repo 的規則判斷
    public static string WrapUpPrompt(ContextUse? ctx)
    {
        var used = $"{(ctx?.Tokens ?? TokenLimit) / 1000}k";
        return $"【AI工作戰情中心】context 已用 {used}，請收尾：①把目前該存的進度 commit；②這個 repo 的規則允許才 push（規定不准 push、要先審或有客戶資料的就不要推，回報原因）；③更新交接文件（寫清楚未完成工作與下一步）與記憶；④最後發收尾卡 `showork card --kind wrapup --handoff <交接文件絕對路徑> --doing <任務> --summary \"<一句接手重點>\"`，發完就停下。看板會自動 /clear，新 context 自動讀交接接手（名字、派工單沿用）。";
    }

    /// 現在要不要對這張卡送收尾：超過門檻、還沒送過、它停下來了（不在工作中、也不是在問你問題）
    public static bool ShouldWrapUp(BoardCard card, ContextUse? ctx, bool alreadySent) =>
        ctx != null && Over(ctx) && !alreadySent && !card.IsQueued && card.Column != BoardColumn.Active && card.Reason != "等你回答";

    /// 只有正式 agent 會提醒、會打字（official）；測試視窗不動手
    public void Check(IEnumerable<BoardCard> cards, bool official, DateTime? now = null)
    {
        if (!official) return;
        Load();
        var t = now ?? DateTime.UtcNow;
        bool changed = false;
        foreach (var c in cards)
        {
            if (c.IsQueued || c.Ctx is not { } x || !Over(x)) continue;
            if (!notified.ContainsKey(c.SessionId))
            {
                notified[c.SessionId] = t; changed = true;
                var used = $"{(x.Tokens ?? 0) / 1000}k";
                BoardActions.Notify($"{c.Project}：context {used}", AutoWrapUp ? "停下來後會自動請它 commit 並收尾" : "該收尾了：在AI工作戰情中心按「收尾」");
                BoardHistory.Append(new Dictionary<string, string> { ["ev"] = "ctx85", ["id"] = c.SessionId, ["project"] = c.Project, ["ctx"] = used });
            }
            // 後備：hook 沒接手、停了 60 秒以上、Claude Code 自己說閒著才打字；打不進去就不記已送、不動剪貼簿，等下次停下來
            if (AutoWrapUp && ShouldWrapUp(c, x, WasSent(c.SessionId)) && c.LastActivity is { } la && t - la >= TimeSpan.FromSeconds(60)
                && TermSend.IsIdle(c.SessionId, out _))
            {
                var text = WrapUpPrompt(c.Ctx);
                var r = BoardActions.TypeInto(c.SessionId, text, true);
                Log.Note($"CTX wrapup {c.SessionId[..Math.Min(8, c.SessionId.Length)]} → {r.Outcome}");
                if (r.Ok)
                {
                    BoardHistory.Append(new Dictionary<string, string> { ["ev"] = "wrapup", ["id"] = c.SessionId, ["project"] = c.Project, ["ctx"] = c.Ctx?.Tokens is { } k2 ? $"{k2 / 1000}k" : "" });
                    sent[c.SessionId] = t; changed = true;
                }
            }
        }
        if (changed) Save();
    }

    public void MarkSent(string sid) { Load(); sent[sid] = DateTime.UtcNow; Save(); }
}

// MARK: - P3 派工：自動回報隊長、自動接力（Kang 10-09）

/// 每次刷新看一遍派工單：做完／要你決定／卡住 ⇒ 傳一則【派工回報】給隊長；做完又有下一棒 ⇒ 自動派給下一棒。
/// 只有正式 agent 會送（測試視窗不動手）；送訊息會等一下，所以放背景，同一張單同時只處理一次。
/// （hook 端的 `showork tick` 刻意不做這段，見 showork\HookCli.cs 的 Tick）
public sealed class TaskRouter
{
    public static readonly TaskRouter Shared = new();
    readonly HashSet<string> inflight = new();
    public event Action? Changed;

    public void Check(IEnumerable<CaptainTaskInfo> tasks, bool official)
    {
        if (!official) return;
        foreach (var t in tasks)
        {
            bool notify = t.State is CaptainTaskInfo.TaskState.done or CaptainTaskInfo.TaskState.review or CaptainTaskInfo.TaskState.blocked && t.Notified != t.State;
            if (!(notify || (t.State == CaptainTaskInfo.TaskState.done && t.ThenTo != null && t.FollowUp == null))) continue;
            lock (inflight) if (!inflight.Add(t.Id)) continue;
            var id = t.Id;
            Task.Run(() =>
            {
                try { Route(id); } catch (Exception x) { Log.Note($"ROUTER {id} failed: {x.Message}"); }
                lock (inflight) inflight.Remove(id);
                Changed?.Invoke();
            });
        }
    }

    internal static void Route(string id)
    {
        if (Hooks.CaptainStore.Task(id) is not { } t) return;
        Hooks.CaptainTask? follow = null;
        if (Hooks.Dispatch.NextLeg(t, Hooks.Dispatch.NewId(DateTime.UtcNow, Hooks.CaptainStore.Tasks().Select(x => x.Id).ToHashSet()), DateTime.UtcNow) is { } next)
        {
            var (saved, err) = BoardActions.SendTask(next);
            follow = saved;
            Log.Note($"ROUTER followup {id} → {saved.Id} {saved.To} {err ?? "ok"}");
        }
        string? notified = null;
        if (Hooks.Dispatch.ShouldNotify(t))
        {
            var text = Hooks.Dispatch.ReportText(t, follow);
            if (BoardActions.FindPeer(t.From) is { } cap && cap.SessionId != t.ToSession)
            {
                var (_, err) = BoardActions.SendPeer(cap, text, "AI工作戰情中心", null);
                Log.Note($"ROUTER notify {id} {t.State} → {cap.Name ?? cap.SessionId} {err ?? "ok"}");
                if (err != null) SystemNotice(t);
            }
            else SystemNotice(t);                // 隊長不在（或從看板直接派的），改發系統通知給你
            notified = t.State;
        }
        // 寫回前再讀一次：對方可能剛好又回報了，只動我們自己的欄位
        if (Hooks.CaptainStore.Task(id) is not { } fresh) return;
        if (follow != null) fresh.FollowUp = follow.Id;
        if (notified != null) fresh.Notified = notified;
        Hooks.CaptainStore.Save(fresh);
        BoardHistory.Append(new Dictionary<string, string> { ["ev"] = "task", ["id"] = id, ["state"] = t.State, ["followUp"] = follow?.Id ?? "" });
    }

    static void SystemNotice(Hooks.CaptainTask t) => BoardActions.Notify($"派工 {t.Id}：{t.To} {Hooks.CaptainTask.Title(t.State)}", t.Summary ?? t.Text);
}

// MARK: - 前台・保全的「立即掃描」（Office.swift 的 GuardScanner）

/// Windows：Mac 的 wifiwatch.sh 是 zsh＋arp 腳本，Windows 沒有。這裡照 Mac 的介面轉寫：找得到掃描腳本
/// （SHOWORK_WIFIWATCH_SCRIPT，或 ~/.claude/scripts/wifiwatch.ps1）才跑（PowerShell，最多 10 分鐘），找不到就回原因。
public sealed class GuardScanner
{
    public static readonly TimeSpan PatrolInterval = TimeSpan.FromMinutes(30);
    public static readonly GuardScanner Shared = new();
    readonly object gate = new();
    bool running;
    DateTime? lastStart;

    public static string Script => Environment.GetEnvironmentVariable("SHOWORK_WIFIWATCH_SCRIPT") is { Length: > 0 } s ? s
        : Path.Combine(BoardReader.DefaultClaudeDir, "scripts", "wifiwatch.ps1");
    public bool IsRunning { get { lock (gate) return running; } }
    public DateTime? LastStarted { get { lock (gate) return lastStart; } }

    /// 開始掃一次；已經在跑就不重複開（回傳 false）。done 在背景執行緒上被叫，帶回結束碼
    public bool Scan(Action<int>? done = null, Func<string, int>? runner = null)
    {
        lock (gate)
        {
            if (running) return false;
            running = true; lastStart = DateTime.UtcNow;
        }
        var script = Script;
        runner ??= s => Tools.Run("powershell.exe", new[] { "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", s }, timeoutMs: 600_000).code;
        Task.Run(() =>
        {
            int code;
            try { code = runner(script); } catch { code = -1; }
            lock (gate) running = false;
            done?.Invoke(code);
        });
        return true;
    }

    /// 巡邏到時間了沒：開著、沒在跑、上次掃描（名冊時間）和上次自己開始的時間都超過間隔
    public static bool PatrolDue(bool enabled, bool running, DateTime? lastScan, DateTime? lastStarted, DateTime now, TimeSpan? interval = null)
    {
        var iv = interval ?? PatrolInterval;
        if (!enabled || running) return false;
        if (lastScan is { } t && now - t < iv) return false;
        if (lastStarted is { } s && now - s < iv) return false;
        return true;
    }
}
