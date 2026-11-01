using System.Diagnostics;
using System.Text.Json.Nodes;
using ShoWork.Hooks;

namespace ShoWork;

// MARK: - ctx 自動交接 ②：收尾完自動 /clear、再叫新 context 接手（Mac 版 Sources/ShoWorkAgent/HandoverClear.swift 的移植，流程見 showork\Core\Handover.cs）
//
// 為什麼放在常駐的 ShoWorkAgent（桌面那一支）：TermSend 要 AttachConsole 到 claude.exe 的主控台，從 ssh／session 0 掛不上去。
// 每 3 秒看一遍 board\handover：
//   pending      ＋它閒下來 ⇒ 對它的終端機送 /clear（TermSend：斜線指令逐字打）
//   clearing     ＋sessions\<pid>.json 換了 sid ⇒ 再打一句「開始接手」；20 秒沒換 ⇒ failed
//   interrupted  ⇒ 轉隊長一則提醒：在 `showork tick` 做（要 Peer）
//   failed       ⇒ 卡片 blocked，請使用者手動 /clear
// 目標一定要閉環驗證（Mac 09-26 搬錯視窗的教訓）：TermSend 只打給「sessions\<pid>.json 的 pid、真的是 claude.exe、不是 pid 重用」的那一個；
// Mac 還多驗 Ghostty 分頁標題，Windows 主控台沒有每個 session 的標題可驗，TermSend 的 pid＋開始時間就是閉環。每筆紀錄只自動送一次。
//
// 同一個迴圈順便做 Mac 看板刷新時做的兩件「沒有畫面也要做」的事：
//   • 寫 board\roster.json（Mac BoardSource 每次刷新寫；`showork roster`／`task add` 讀，30 秒內的才算數）
//   • 每 5 秒叫一次 `showork tick`（工作卡片轉隊長、合併預告、交接提醒、巡檢；要 Peer 的都在 showork 那邊）
// 啟動：Program.cs 的 switch 在 agent 模式先叫 HandoverClear.Start()（背景執行緒，跟 UI 執行緒無關）。
static class HandoverClear
{
    public static readonly TimeSpan Interval = TimeSpan.FromSeconds(3);
    public static readonly TimeSpan TickEvery = TimeSpan.FromSeconds(5);

    static int started;
    static readonly Dictionary<string, DateTime> lastWhy = new();

    /// 正式 agent 開跑時叫一次（多叫也只跑一個迴圈）。回傳 true 讓 Program.cs 的 switch 接著走 RunAgent
    public static bool Start()
    {
        if (Environment.GetEnvironmentVariable("SHOWORK_NO_HANDOVER") is "1") return true;   // 測試／除錯時關掉
        if (Interlocked.Exchange(ref started, 1) == 0)
            new Thread(Loop) { IsBackground = true, Name = "HandoverClear", Priority = ThreadPriority.BelowNormal }.Start();
        return true;
    }

    static void Loop()
    {
        Thread.Sleep(5000);                    // 讓 agent 先把 pipe、光暈都開好；搶不到 pipe 的第二支 agent 這時早就結束了
        var reader = BoardReader.Default();
        bool fresh = true;
        var lastTick = DateTime.MinValue;
        HLog("start");
        while (true)
        {
            var now = DateTime.UtcNow;
            try { Step(reader, now, TermSender.Real); }
            catch (Exception e) { Log.Note("HANDOVER step failed: " + e.Message); }
            if (now - lastTick >= TickEvery)
            {
                lastTick = now;
                RunShoworkTick(fresh);
                fresh = false;
            }
            Thread.Sleep(Interval);
        }
    }

    /// 送字的介面（測試換成假的）
    public sealed record TermSender(Func<string, string, TermSend.Result> Send, Func<string, (bool Ok, string Why)> Idle)
    {
        public static readonly TermSender Real = new(
            (target, text) => TermSend.Send(target, text, enter: true),
            target => (TermSend.IsIdle(target, out var why), why));
    }

    /// 一輪：讀看板 → 寫名冊 → 看交接紀錄
    public static void Step(BoardReader reader, DateTime now, TermSender term)
    {
        var snap = reader.Read();
        var cards = reader.Cards(snap, now);
        var records = Handover.All();
        var labels = new Dictionary<string, string?>();
        foreach (var r in records) labels[r.Sid] = r.Label;
        CaptainStore.SaveRoster(BuildRoster(cards, snap.Captain, labels, NicknameStore.All(), now));
        Check(cards, records, now, term, Path.Combine(reader.ClaudeDir, "sessions"));
    }

    // MARK: 名冊（Mac Captain.roster）

    public static Roster BuildRoster(List<BoardCard> cards, string? captain, IReadOnlyDictionary<string, string?> handover, IReadOnlyDictionary<string, Nickname> nick, DateTime now) => new()
    {
        At = now, Captain = captain,
        Entries = cards.Where(c => !c.IsQueued).Select(c => new RosterEntry
        {
            // Windows 的 session 名是「英文名-任務」（BoardReader 照 board\names 組的）；名冊的名字要是 SendMessage 認得的英文名
            Name = nick.GetValueOrDefault(c.SessionId)?.Name ?? c.Name ?? c.SessionId[..Math.Min(8, c.SessionId.Length)],
            SessionId = c.SessionId, Pid = c.Pid, Kind = c.Kind, Project = c.Project, Root = c.Cwd, Column = c.Column.ToString().ToLowerInvariant(),
            Reason = c.Reason, Title = c.Title, Summary = c.Report?.Summary ?? (c.Detail is { } d ? SwiftText.Prefix(d, 120) : null),
            Ctx = c.Ctx is { } x ? (int)x.Percent : null, CtxTokens = c.Ctx?.Tokens, LastActivity = c.LastActivity,
            Captain = c.Captain, SameProject = c.SameProject.ToList(), Handover = handover.GetValueOrDefault(c.SessionId),
        }).ToList(),
    };

    // MARK: 交接（Mac HandoverClear.check）

    public static void Check(List<BoardCard> cards, List<HandoverRecord> records, DateTime now, TermSender term, string sessionsDir)
    {
        foreach (var snap in records)
        {
            // 快照可能是舊的；動手前一律以磁碟上的為準，免得同一筆送兩次
            if (snap.State == "failed" || (snap.State == "taken" && snap.ClearAt == null)) continue;
            if (Handover.Load(snap.Sid) is not { } r) continue;
            switch (r.State)
            {
                case "pending":
                {
                    if (cards.FirstOrDefault(c => c.SessionId == r.Sid) is not { } c) continue;
                    bool dialog = c.Permit != null || c.Reason == "等你回答" || Hooks.Permit.Pending(now).ContainsKey(r.Sid);
                    // 鍵盤不等（Handover.KeyIdle＝0，10-26 Kang）：給一個一定夠的數
                    bool ready = Handover.ReadyToClear(r.State, c.Report?.Kind, c.Column == BoardColumn.Active, dialog, c.LastActivity, TimeSpan.FromDays(1), now);
                    var (idle, why) = ready ? term.Idle(Target(r)) : (false, "");
                    if (!ready || !idle)
                    {
                        if (now - lastWhy.GetValueOrDefault(r.Sid, DateTime.MinValue) > TimeSpan.FromSeconds(60))   // 等太久時查得到卡在哪個條件
                        {
                            lastWhy[r.Sid] = now;
                            HLog($"wait {r.Name} kind={c.Report?.Kind ?? "nil"} col={c.Column.ToString().ToLowerInvariant()} permit={dialog} reason={c.Reason}" + (ready ? $" term={why}" : ""));
                        }
                        continue;
                    }
                    // 先記「送出中」再按鍵：/clear 後的 SessionStart 會讀這筆、改成 taken 寫回，晚寫會把它蓋掉（Mac 10-24 實測撞到）
                    r.State = "clearing"; r.ClearAt = now;
                    Handover.Save(r);
                    var res = term.Send(Target(r), "/clear");
                    if (res.Ok)
                    {
                        Update(r.Sid, x => x.Via = "console");
                        HLog($"/clear → {r.Name} {Short(r.Sid)} via console（pid {res.Pid}）");
                    }
                    else Fail(r, res.Message, now);
                    break;
                }
                case "clearing" or "taken":
                {
                    if (r.Kicked || r.ClearAt is not { } at) continue;
                    var cur = CurrentSid(sessionsDir, r.Pid);
                    if (r.State == "taken" || (cur != null && cur != r.Sid))
                    {
                        var k = term.Send(r.Pid > 0 ? r.Pid.ToString() : r.NewSid ?? cur ?? r.Sid, Handover.Kickoff(r));
                        Update(r.Sid, x => x.Kicked = true);
                        HLog($"cleared {r.Name} {Short(r.Sid)} → {Short(r.NewSid ?? cur ?? "?")} kickoff={(k.Ok ? "sent" : k.Message)}");
                    }
                    else if (now - at > Handover.ClearTimeout)
                        Fail(r, $"送了 /clear 但 {(int)Handover.ClearTimeout.TotalSeconds} 秒內 session 沒換", now);
                    break;
                }
            }
        }
    }

    /// 打給誰：收尾卡記下的 claude.exe pid（/clear 換 sid 不換行程）；沒記到 pid 才用 sid
    static string Target(HandoverRecord r) => r.Pid > 0 ? r.Pid.ToString() : r.Sid;

    /// 讀最新的、只改自己要改的欄位再寫回（SessionStart 的 Claim 可能剛好同時寫 taken）
    static void Update(string sid, Action<HandoverRecord> f)
    {
        if (Handover.Load(sid) is not { } r) return;
        f(r);
        Handover.Save(r);
    }

    static void Fail(HandoverRecord r, string why, DateTime now)
    {
        Update(r.Sid, x => { x.State = "failed"; x.Note = why; x.Notified = true; });
        HLog($"failed {r.Name} {Short(r.Sid)}: {why}");
        // 卡片標卡住（之後這張卡不再是 wrapup ⇒ 不會再自動送）
        var card = new JsonObject
        {
            ["status"] = "blocked", ["summary"] = $"自動 /clear 失敗：{why}。請手動 /clear，新 context 會自動讀交接 {r.Handoff}",
        };
        card.Put("doing", NicknameStore.Get(r.Sid)?.Doing);
        card["at"] = HookJson.Iso(now);
        HookJson.WriteAtomic(CardReport.CardPath(r.Sid), HookJson.Text(card));
        Log.Note($"HANDOVER {r.Name} 自動 /clear 失敗，請到它的終端機手動 /clear（{why}）");
    }

    static string? CurrentSid(string sessionsDir, int pid) =>
        pid > 0 ? HookJson.ReadObject(Path.Combine(sessionsDir, $"{pid}.json")).Str("sessionId") : null;

    static string Short(string sid) => sid[..Math.Min(8, sid.Length)];

    /// 一律寫 board\handover.log（同 Mac；Log.Note 只在除錯時看）
    static void HLog(string s)
    {
        Log.Note("HANDOVER " + s);
        Handover.Log(s, DateTime.UtcNow);
    }

    // MARK: showork tick

    static string? Showork()
    {
        foreach (var p in new[] { Path.Combine(AppContext.BaseDirectory, "showork.exe"), Path.Combine(Installer.InstallDir, "showork.exe") })
            if (File.Exists(p)) return p;
        return null;
    }

    static void RunShoworkTick(bool fresh)
    {
        if (Showork() is not { } exe) return;
        try
        {
            var psi = new ProcessStartInfo(exe) { UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true, RedirectStandardError = true };
            psi.ArgumentList.Add("tick");
            if (fresh) psi.ArgumentList.Add("--fresh");
            psi.Environment.Remove("CLAUDE_CODE_SESSION_ID");
            using var p = Process.Start(psi)!;
            p.OutputDataReceived += (_, _) => { }; p.ErrorDataReceived += (_, _) => { };
            p.BeginOutputReadLine(); p.BeginErrorReadLine();
            if (!p.WaitForExit(30_000)) { try { p.Kill(true); } catch { } Log.Note("HANDOVER showork tick 30 秒沒結束"); }
        }
        catch (Exception e) { Log.Note("HANDOVER showork tick: " + e.Message); }
    }
}
