using System.Text;
using System.Text.Json.Nodes;
using ShoWork;
using ShoWork.Hooks;
using Xunit;

namespace ShoWork.Tests;

/// 11-02 P8 第二輪：戰情中心的動作（BoardActions、Reviewer、CtxGuard、TaskRouter、GuardScanner）與對話紀錄多算的四件事
/// （activity、blockedReason、subagents、tokens）、隊長對話、進度條。對照 Mac Tests/ShoWorkCoreTests 的 ActivityTests、CaptainThreadTests、
/// RunProgressTests、AnsweredTests 與 BoardActions 的行為。假名、假 session；資料一律寫在暫存資料夾（SHOWORK_HOME、SHOWORK_CLAUDE_DIR）。
/// 真的打字進終端機（TermSend）換成假的委派；Windows 桌面上的實測另外做。
public sealed class BoardActionTests : IDisposable
{
    readonly string root = Path.Combine(Path.GetTempPath(), "sw-act-" + Guid.NewGuid().ToString("N")[..8]);
    string Home => Path.Combine(root, "home");
    string Claude => Path.Combine(root, "claude");
    string BoardDir => Path.Combine(Home, "board");
    static readonly string[] Vars = { "SHOWORK_HOME", "SHOWORK_CLAUDE_DIR", "SHOWORK_PREFS", "SHOWORK_PREAPPROVAL_LOG", "SHOWORK_RELEASE_LOG",
                                      "SHOWORK_CAPTAIN_INBOX", "SHOWORK_PERMIT_DIR", "SHOWORK_RUN_PROGRESS", "SHOWORK_WIFIWATCH_SCRIPT" };
    readonly List<(string Sid, string Text, bool Enter)> typed = new();
    readonly List<(string To, string Text, string From)> peered = new();
    readonly List<string> copied = new();
    bool termOk = true, peerOk = true, focusOk = true;

    public BoardActionTests()
    {
        foreach (var v in Vars) Environment.SetEnvironmentVariable(v, null);
        Directory.CreateDirectory(Path.Combine(Claude, "sessions"));
        Directory.CreateDirectory(BoardDir);
        Environment.SetEnvironmentVariable("SHOWORK_HOME", Home);
        Environment.SetEnvironmentVariable("SHOWORK_CLAUDE_DIR", Claude);
        BoardActions.TypeInto = (sid, text, enter) =>
        {
            typed.Add((sid, text, enter));
            return termOk ? new TermSend.Result(TermSend.Outcome.Sent, 42, "ok") : new TermSend.Result(TermSend.Outcome.AccessDenied, 42, "掛不上");
        };
        BoardActions.FindPeer = who => peerOk && who.StartsWith("sid-", StringComparison.Ordinal) ? new PeerSession { SessionId = who, Pid = 7, Name = "Alex", MessagingSocketPath = "x" } : null;
        BoardActions.SendPeer = (r, text, from, _) => { peered.Add((r.SessionId, text, from)); return ("msg-1", null); };
        BoardActions.CopyToClipboard = t => { copied.Add(t); return true; };
        BoardActions.FocusWindow = _ => focusOk;
    }

    public void Dispose()
    {
        foreach (var v in Vars) Environment.SetEnvironmentVariable(v, null);
        BoardActions.TypeInto = (sid, text, enter) => TermSend.Send(sid, text, enter);
        BoardActions.FindPeer = who => Peer.Find(who);
        BoardActions.SendPeer = (r, text, from, replyTo) => Peer.Send(r, text, from, replyTo);
        BoardActions.CopyToClipboard = _ => false;
        BoardActions.FocusWindow = _ => false;
        try { Directory.Delete(root, true); } catch { }
    }

    static BoardCard Card(string sid = "sid-a", string title = "修登入頁", string? ask = null) => new()
    {
        Id = sid, SessionId = sid, Title = title, Project = "ProjectA", Pid = 4242, Column = BoardColumn.Review, Reason = "要你決定：" + (ask ?? "要不要合併？"),
        Report = new SelfReport { Status = ReportStatus.Review, Ask = ask ?? "要不要合併？", At = DateTime.UtcNow },
    };

    static byte[] Lines(params string[] ls) => Encoding.UTF8.GetBytes(string.Join("\n", ls) + "\n");

    // MARK: 退回、回答

    [Fact]
    public void SendBackTypesIntoTheTerminalAndPressesEnter()
    {
        var r = BoardActions.SendBack(Card(), "改成\n藍色");
        Assert.True(r.Typed);
        Assert.Equal("已送進「修登入頁」", r.Message);
        Assert.Equal(("sid-a", "改成 藍色", true), typed.Single());
        Assert.Empty(copied);
        Assert.Contains("\"ev\":\"sendback\"", File.ReadAllText(Path.Combine(BoardDir, "history.jsonl")));
    }

    [Fact]
    public void SendBackFallsBackToClipboardAndJump()
    {
        termOk = false;
        var r = BoardActions.SendBack(Card(), "改成藍色");
        Assert.False(r.Typed);
        Assert.Equal("已拷貝，並跳到那個視窗；貼上後按 Enter。", r.Message);
        Assert.Equal("改成藍色", copied.Single());
        focusOk = false;
        Assert.Equal("已拷貝到剪貼簿；找不到那個視窗，請自己切過去貼上。", BoardActions.SendBack(Card(), "x").Message);
    }

    [Fact]
    public void AnswerTypesFirstThenPeerThenClipboard()
    {
        Assert.Equal("已送進「修登入頁」", BoardActions.Answer(Card(), "好，合併"));
        Assert.Single(typed);
        Assert.Empty(peered);
        termOk = false;
        Assert.Equal("已送給「修登入頁」", BoardActions.Answer(Card(), "先不要"));
        Assert.Equal(CaptainThread.AnswerPrefix + "先不要", peered.Single().Text);
        Assert.Equal("AI工作戰情中心（使用者）", peered.Single().From);
        peerOk = false;
        Assert.StartsWith("已拷貝", BoardActions.Answer(Card(), "再想想"));
        Assert.Equal("再想想", copied.Last());
    }

    [Fact]
    public void AnswerRecordsAPreapprovalAndTellsTheCaptain()
    {
        Hooks.CaptainStore.SetCaptain("sid-cap", "Penny", DateTime.UtcNow);
        // 隊長卡片掛著同一題 ⇒ 清掉
        Directory.CreateDirectory(Path.Combine(BoardDir, "cards"));
        File.WriteAllText(Path.Combine(BoardDir, "cards", "sid-cap.json"), """{"status":"review","ask":"要不要合併？","options":["好","不要"],"at":"2026-11-02T01:00:00.000Z","how":"留著"}""");
        BoardActions.Answer(Card(), "好，合併並 push");
        var pre = JsonNode.Parse(File.ReadAllText(Path.Combine(BoardDir, "permits", "preapprovals.json")))!.AsArray();
        Assert.Equal("好，合併並 push", pre[0]!["answer"]!.GetValue<string>());
        Assert.Equal("要不要合併？", pre[0]!["question"]!.GetValue<string>());
        var cap = JsonNode.Parse(File.ReadAllText(Path.Combine(BoardDir, "cards", "sid-cap.json")))!.AsObject();
        Assert.False(cap.ContainsKey("ask"));
        Assert.False(cap.ContainsKey("options"));
        Assert.Equal("留著", cap["how"]!.GetValue<string>());          // 其他欄位不動
        // 轉隊長是背景送的
        for (int i = 0; i < 50 && !peered.Any(p => p.To == "sid-cap"); i++) Thread.Sleep(20);
        var relay = peered.Single(p => p.To == "sid-cap");
        Assert.StartsWith(Answered.Prefix, relay.Text);
        Assert.Contains("要不要合併？→好，合併並 push", relay.Text);
    }

    [Fact]
    public void AnsweringReleaseReleasesTheWaitingBlock()
    {
        var item = new Hooks.InboxItem { Id = "BTEST", Kind = "block", At = DateTime.UtcNow, Sid = "sid-a", Name = "Alex", Text = "gh pr create", Fingerprint = "fp" };
        CaptainInbox.Save(item);
        BoardActions.Answer(Card(), "放行");
        Assert.NotNull(CaptainInbox.Item("BTEST")!.Released);
        Assert.Contains(CaptainInbox.Releases(), r => r["source"]!.GetValue<string>() == "戰情中心回答");
    }

    // MARK: 權限、選擇題、計畫

    [Fact]
    public void PermitAnswersWriteTheAnswerFileTheHookWaitsFor()
    {
        var req = new Hooks.PermitRequest { Id = "sid-a-1", SessionId = "sid-a", Tool = "Bash", Summary = "rm -rf build", At = DateTime.UtcNow };
        Assert.True(Hooks.Permit.Write(req));
        var c = Card();
        var pending = PermitCards.Pending(DateTime.UtcNow);
        c.Permit = pending["sid-a"];
        Assert.Equal("rm -rf build", c.Permit.Summary);
        Assert.Equal("已允許「修登入頁」", BoardActions.AnswerPermit(c, "allow", null, null));
        Assert.Equal("allow", Hooks.Permit.ReadAnswer("sid-a-1")!.Decision);
        Assert.Empty(PermitCards.Pending(DateTime.UtcNow));            // 答過的不再列
        Hooks.Permit.Remove("sid-a-1");
        Assert.Equal("「修登入頁」的對話框已經關了", BoardActions.AnswerPermit(c, "deny", "不要", null));
        c.Permit = null;
        Assert.Equal("「修登入頁」的對話框已經關了", BoardActions.AnswerPermit(c, "allow", null, null));
    }

    [Fact]
    public void AskQuestionAnswersAreLoggedWithTheChoices()
    {
        var req = new Hooks.PermitRequest
        {
            Id = "sid-a-2", SessionId = "sid-a", Tool = "AskUserQuestion", Summary = "要用哪個色？", At = DateTime.UtcNow,
            Questions = new() { new Hooks.AskQuestion { Question = "要用哪個色？", Options = new() { new() { Label = "藍" }, new() { Label = "綠" } } } },
            Input = """{"questions":[{"question":"要用哪個色？","options":[{"label":"藍"},{"label":"綠"}]}]}""",
        };
        Hooks.Permit.Write(req);
        var c = Card();
        c.Permit = PermitCards.Pending(DateTime.UtcNow)["sid-a"];
        Assert.True(c.Permit.Questions![0].Options.Count == 2);
        var msg = BoardActions.AnswerPermit(c, "allow", null, new() { ["要用哪個色？"] = new() { "藍" } });
        Assert.Equal("已回答「修登入頁」：要用哪個色？ → 藍", msg);
        Assert.Contains("戰情中心選擇題", File.ReadAllText(Path.Combine(BoardDir, "permits", "answers.jsonl")));
        Assert.Equal(new[] { "藍" }, Hooks.Permit.ReadAnswer("sid-a-2")!.Answers!["要用哪個色？"]);
    }

    // MARK: 放行、丟待辦、派工、交給隊長

    [Fact]
    public void ApproveAndParkWriteDecisions()
    {
        BoardActions.Approve(Card());
        var d = BoardJson.Decode<Decision>(File.ReadAllText(Path.Combine(BoardDir, "decisions", "sid-a.json")))!;
        Assert.Equal(DecisionAction.Approve, d.Action);
        BoardActions.Park(Card(), "下週再看");
        d = BoardJson.Decode<Decision>(File.ReadAllText(Path.Combine(BoardDir, "decisions", "sid-a.json")))!;
        Assert.Equal(DecisionAction.Park, d.Action);
        Assert.Equal("下週再看", d.Note);
        // 看板的規則讀得懂：決定晚於最後活動 ⇒ 丟回待辦
        var col = CardRules.Column((BoardColumn.Review, "做完了，你還沒看"), WorkState.Done, null, d, null, DateTime.UtcNow.AddMinutes(-1));
        Assert.Equal((BoardColumn.Todo, "你丟回待辦：下週再看"), col);
    }

    [Fact]
    public void DispatchCreatesATaskAndSendsIt()
    {
        var c = Card("sid-b", "做報表");
        c.Name = "Bella";
        var (id, err) = BoardActions.Dispatch(c, "整理十月報表\n交 CSV", "sid-c", "檢查報表", captain: null);
        Assert.Null(err);
        Assert.StartsWith("T", id);
        var t = Hooks.CaptainStore.Task(id!)!;
        Assert.Equal("board", t.From);
        Assert.Equal("sid-b", t.ToSession);
        Assert.Equal("Alex", t.To);                                      // 照 Peer 找到的名字
        Assert.Equal("sid-c", t.ThenTo);
        Assert.Equal("檢查報表", t.ThenText);
        Assert.StartsWith($"【隊長派工 {id}】整理十月報表\n交 CSV\n", peered.Single().Text);
        Assert.Equal("AI工作戰情中心（你從看板派的）", peered.Single().From);
        // 卡片上看得到（Captain.Annotate 帶派工單）
        var cards = Captain.Annotate(new[] { c }, null, CaptainTasks.All());
        Assert.Equal(id, cards[0].Tasks.Single().Id);
        Assert.Equal(CaptainTaskInfo.TaskState.sent, cards[0].Tasks[0].State);
    }

    [Fact]
    public void TaskRouterReportsDoneTasksToTheCaptainAndStartsTheNextLeg()
    {
        var now = DateTime.UtcNow;
        var t = new Hooks.CaptainTask { Id = "T1102010101", From = "sid-cap", To = "Bella", ToSession = "sid-b", Text = "做報表", State = "done", Summary = "做完了",
                                        CreatedAt = now, UpdatedAt = now, ThenTo = "sid-c", ThenText = "檢查報表" };
        Hooks.CaptainStore.Save(t);
        TaskRouter.Route(t.Id);
        var fresh = Hooks.CaptainStore.Task(t.Id)!;
        Assert.Equal("done", fresh.Notified);
        Assert.NotNull(fresh.FollowUp);
        var next = Hooks.CaptainStore.Task(fresh.FollowUp!)!;
        Assert.Equal(t.Id, next.After);
        Assert.Contains("前一棒 Bella 已完成「做報表」，回報：做完了", next.Text);
        var report = peered.Single(p => p.To == "sid-cap");
        Assert.StartsWith($"【派工回報 {t.Id}】Bella：完成——做完了", report.Text);
        Assert.Contains($"已自動接力：{next.Id}", report.Text);
        // 同一個狀態只通知一次
        peered.Clear();
        TaskRouter.Route(t.Id);
        Assert.Empty(peered);
    }

    [Fact]
    public void ToCaptainWrapsTheTextLikeMac()
    {
        var (_, err) = BoardActions.ToCaptain("sid-cap", "把十月報表做完");
        Assert.Null(err);
        Assert.StartsWith(CaptainThread.BoardPrefix + "把十月報表做完\n請照隊長守則處理", peered.Single().Text);
        Assert.Equal(CaptainThread.BoardFromName, peered.Single().From);
        // 隊長的對話紀錄裡讀回來是你說的那句（戰情中心）
        var line = $$$"""{"type":"user","uuid":"u1","timestamp":"2026-11-02T01:00:00.000Z","origin":{"kind":"peer","name":"{{{CaptainThread.BoardFromName}}}"},"message":{"role":"user","content":"<cross-session-message from=\"uds:\" from-name=\"x\">\n{{{peered.Single().Text.Replace("\n", "\\n")}}}\n</cross-session-message>"}}""";
        var th = CaptainThread.Parse(Lines(line));
        Assert.Equal(CaptainLine.RoleKind.kang, th.Single().Role);
        Assert.Equal("把十月報表做完", th.Single().Text);
        Assert.Equal("戰情中心", th.Single().Via);
    }

    [Fact]
    public void AskCaptainWithALiveCaptainSendsDirectly()
    {
        Hooks.CaptainStore.SetCaptain("sid-cap", "Penny", DateTime.UtcNow);
        Assert.Equal("已交給隊長「Alex」", BoardActions.AskCaptain("  幫我\n看一下  "));
        Assert.StartsWith(CaptainThread.BoardPrefix + "幫我 看一下", peered.Single().Text);
        Assert.Equal("沒有內容", BoardActions.AskCaptain("   "));
    }

    [Fact]
    public void PushAllowWritesAOneShotAllowance()
    {
        var now = DateTime.UtcNow;
        BoardActions.PushAllow(@"C:\repo", "abc123", now);
        BoardActions.PushAllow(@"C:\repo", "abc123", now);              // 同一筆不重複
        var xs = PushGuard.Allows();
        Assert.Single(xs);
        Assert.Equal(now + TimeSpan.FromMinutes(30), xs[0].Until, TimeSpan.FromSeconds(1));
        BoardActions.PushAllow(@"C:\repo", null, now);                   // 沒有 HEAD 不收
        Assert.Single(PushGuard.Allows());
    }

    [Fact]
    public void ModelTitlesAndDefaultCaptainModel()
    {
        Assert.Equal("Opus 5.5", BoardActions.ModelTitle(BoardActions.CaptainModel));
        Environment.SetEnvironmentVariable("SHOWORK_PREFS", Path.Combine(root, "prefs.json"));
        BoardPrefs.Set(CaptainLaunch.ModelKey, "claude-fable-5-1");
        Assert.Equal("Fable 5.1", BoardActions.ModelTitle(BoardActions.CaptainModel));
        Assert.Contains("使用者交辦的第一件事：做報表", CaptainLaunch.Bootstrap("C:/x/showork.exe", "做報表"));
    }

    // MARK: 設定、ctx 收尾、保全巡邏

    [Fact]
    public void PrefsAreSharedWithTheHookSide()
    {
        Environment.SetEnvironmentVariable("SHOWORK_PREFS", Path.Combine(root, "prefs.json"));
        Assert.True(Reviewer.Shared.Enabled);
        Assert.True(CtxGuard.Shared.AutoWrapUp);
        Reviewer.Shared.Enabled = false;
        CtxGuard.Shared.AutoWrapUp = false;
        CtxGuard.SetTokenLimit(404_000);
        Assert.False(Reviewer.Shared.Enabled);
        Assert.False(Hooks.ContextGuard.AutoWrapUp);                   // hook 端的 Stop hook 讀同一份
        Assert.Equal(400_000, Hooks.ContextGuard.TokenLimit);           // 對齊 10k
        Assert.Equal(400_000, CtxGuard.TokenLimit);
    }

    [Fact]
    public void WrapUpOnlyWhenOverTheTokenLimitAndStopped()
    {
        var c = Card();
        c.Column = BoardColumn.Review; c.Reason = "做完了，你還沒看";
        var over = new ContextUse { Percent = 40, Tokens = 260_000 };
        var under = new ContextUse { Percent = 90, Tokens = 100_000 };
        Assert.True(CtxGuard.ShouldWrapUp(c, over, alreadySent: false));
        Assert.False(CtxGuard.ShouldWrapUp(c, under, alreadySent: false));   // 只看 token（Mac 10-29）
        Assert.False(CtxGuard.ShouldWrapUp(c, over, alreadySent: true));
        c.Column = BoardColumn.Active;
        Assert.False(CtxGuard.ShouldWrapUp(c, over, alreadySent: false));
        c.Column = BoardColumn.Review; c.Reason = "等你回答";
        Assert.False(CtxGuard.ShouldWrapUp(c, over, alreadySent: false));
        Assert.Contains("context 已用 260k，請收尾", CtxGuard.WrapUpPrompt(over));
    }

    [Fact]
    public void PatrolIsDueOnlyAfterTheInterval()
    {
        var now = DateTime.UtcNow;
        Assert.False(GuardScanner.PatrolDue(false, false, null, null, now));
        Assert.True(GuardScanner.PatrolDue(true, false, null, null, now));
        Assert.False(GuardScanner.PatrolDue(true, true, null, null, now));
        Assert.False(GuardScanner.PatrolDue(true, false, now.AddMinutes(-10), null, now));
        Assert.False(GuardScanner.PatrolDue(true, false, now.AddHours(-2), now.AddMinutes(-5), now));
        Assert.True(GuardScanner.PatrolDue(true, false, now.AddHours(-2), now.AddHours(-1), now));
    }

    [Fact]
    public void ScannerRunsOnceAtATime()
    {
        var sc = new GuardScanner();
        var gate = new ManualResetEventSlim();
        var done = new ManualResetEventSlim();
        Assert.True(sc.Scan(_ => done.Set(), _ => { gate.Wait(); return 0; }));
        Assert.True(sc.IsRunning);
        Assert.False(sc.Scan(null, _ => 0));
        gate.Set();
        Assert.True(done.Wait(2000));
        Assert.False(sc.IsRunning);
    }

    // MARK: 審核員

    [Fact]
    public void ReviewerParsesTheVerdictAndSkipsIdleTurns()
    {
        var turn = DateTime.UtcNow.AddMinutes(-1);
        var r = ReviewRules.ParseReview("好的\n```json\n{\"progress\": 80, \"confidence\": 140, \"verdict\": \"pass\", \"issues\": [\"a\",\"b\",\"c\",\"d\"]}\n```", turn, "sonnet", 0.01)!;
        Assert.Equal(80, r.Progress);
        Assert.Equal(100, r.Confidence);
        Assert.Equal("pass", r.Verdict);
        Assert.Equal(3, r.Issues.Count);
        Assert.Equal("concern", ReviewRules.ParseReview("{\"verdict\":\"meh\"}", turn, "sonnet", null)!.Verdict);
        Assert.Null(ReviewRules.ParseReview("沒有 JSON", turn, "sonnet", null));
        // 最後一輪只回話 ⇒ 沒動手；有用工具 ⇒ 動手
        var idle = Lines("""{"type":"user","message":{"role":"user","content":"在嗎"}}""",
                         """{"type":"assistant","message":{"content":[{"type":"text","text":"在"}]}}""");
        Assert.False(ReviewRules.LastTurnDidWork(idle));
        var work = Lines("""{"type":"user","message":{"role":"user","content":"改一下"}}""",
                         """{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t1","name":"Edit","input":{"file_path":"a.cs"}}]}}""");
        Assert.True(ReviewRules.LastTurnDidWork(work));
        var cardOnly = Lines("""{"type":"user","message":{"role":"user","content":"報告"}}""",
                             """{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"\"C:/x/showork.exe\" card --status done"}}]}}""");
        Assert.False(ReviewRules.LastTurnDidWork(cardOnly));
        var ex = ReviewRules.Excerpt(work);
        Assert.Contains("【使用者】改一下", ex);
        Assert.Contains("【工具 Edit】a.cs", ex);
    }

    [Fact]
    public void ReviewerWritesTheReviewFile()
    {
        var path = Path.Combine(root, "t.jsonl");
        File.WriteAllBytes(path, Lines("""{"type":"user","message":{"role":"user","content":"改一下"}}""",
                                       """{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t1","name":"Edit","input":{"file_path":"a.cs"}}]}}"""));
        var rv = new Reviewer
        {
            TranscriptOf = _ => path,
            Runner = (prompt, cwd) => (0, """{"result":"{\"progress\":70,\"confidence\":60,\"verdict\":\"concern\",\"issues\":[\"沒有測試\"]}","total_cost_usd":0.02}""", ""),
        };
        var done = new ManualResetEventSlim();
        int n = 0;
        rv.Changed += () => { if (++n == 2) done.Set(); };
        var c = Card();
        c.LastActivity = DateTime.UtcNow.AddMinutes(-1);
        rv.Start(c, force: false);
        Assert.True(done.Wait(3000));
        var r = BoardJson.Decode<Review>(File.ReadAllText(Path.Combine(BoardDir, "reviews", "sid-a.json")))!;
        Assert.Equal("concern", r.Verdict);
        Assert.Equal(70, r.Progress);
        Assert.Equal("沒有測試", r.Issues.Single());
        Assert.Equal(0.02, r.CostUSD);
        Assert.False(rv.IsRunning("sid-a"));
    }

    // MARK: 對話紀錄多算的四件事（Mac Activity.swift／Board.swift）

    [Fact]
    public void PendingToolsGiveTheActivity()
    {
        var t = TranscriptInfo.Parse(Lines(
            """{"type":"user","timestamp":"2026-11-02T01:00:00Z","message":{"role":"user","content":"看一下"}}""",
            """{"type":"assistant","timestamp":"2026-11-02T01:00:01Z","message":{"content":[{"type":"tool_use","id":"r1","name":"Read","input":{"file_path":"a"}}]}}"""));
        Assert.Equal(AIActivity.Reading, t.CurrentActivity);
        t = TranscriptInfo.Parse(Lines(
            """{"type":"assistant","message":{"content":[{"type":"tool_use","id":"r1","name":"Read","input":{}}]}}""",
            """{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"r1"}]}}""",
            """{"type":"assistant","message":{"content":[{"type":"tool_use","id":"e1","name":"Edit","input":{}}]}}"""));
        Assert.Equal(AIActivity.Editing, t.CurrentActivity);
        Assert.Single(t.Pending);
        t = TranscriptInfo.Parse(Lines("""{"type":"user","message":{"role":"user","content":"嗨"}}"""));
        Assert.Equal(AIActivity.Thinking, t.CurrentActivity);
        Assert.True(t.AwaitingReply);
    }

    [Fact]
    public void BlockedReasonsFromTheTranscript()
    {
        var bash = TranscriptInfo.Parse(Lines("""{"type":"assistant","message":{"content":[{"type":"tool_use","id":"b1","name":"Bash","input":{"command":"dotnet test"}}]}}"""));
        Assert.Equal(BlockedReason.TestRun, bash.BlockedReasonFor(waiting: false, stuck: true));
        Assert.Equal(BlockedReason.Permission, bash.BlockedReasonFor(waiting: true, stuck: false));    // 工具在等你按允許
        Assert.Null(bash.BlockedReasonFor(waiting: false, stuck: false));
        var limit = TranscriptInfo.Parse(Lines("""{"type":"assistant","isApiErrorMessage":true,"error":"rate_limit","message":{"content":[{"type":"text","text":"You've hit your session limit"}]}}"""));
        Assert.Equal(BlockedReason.RateLimit, limit.BlockedReasonFor(waiting: false, stuck: true));
        var denied = TranscriptInfo.Parse(Lines(
            """{"type":"assistant","message":{"content":[{"type":"tool_use","id":"w1","name":"Write","input":{}}]}}""",
            """{"type":"user","toolDenialKind":"user-rejected","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"w1"}]}}"""));
        Assert.Equal(BlockedReason.Permission, denied.BlockedReasonFor(waiting: true, stuck: false));
        // 之後 AI 又講話 ⇒ 清掉
        var cleared = TranscriptInfo.Parse(Lines(
            """{"type":"user","toolDenialKind":"interrupted","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"w1"}]}}""",
            """{"type":"assistant","message":{"content":[{"type":"text","text":"好"}]}}"""));
        Assert.Null(cleared.LastSignal);
    }

    [Fact]
    public void BackgroundAgentsAreTrackedUntilTheNotification()
    {
        var launch = Lines(
            """{"type":"assistant","message":{"content":[{"type":"tool_use","id":"a1","name":"Agent","input":{"description":"查城市資料","subagent_type":"Explore"}}]}}""",
            """{"type":"user","timestamp":"2026-11-02T01:00:00Z","toolUseResult":{"status":"async_launched","agentId":"ag-1","description":"查城市資料"},"message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"a1"}]}}""",
            """{"type":"assistant","message":{"content":[{"type":"text","text":"背景跑了"}]}}""");
        var t = TranscriptInfo.Parse(launch);
        Assert.Equal("查城市資料", t.Subagents(includeSync: false).Single().Description);
        Assert.True(t.Subagents(false)[0].Background);
        Assert.Equal("Explore", t.Subagents(false)[0].SubagentType);
        Assert.Equal(AIActivity.Delegating, t.CurrentActivity);
        Assert.True(t.IsDelegating);
        var done = launch.Concat(Lines("""{"type":"queue-operation","operation":"enqueue","content":"<task-notification><task-id>ag-1</task-id>done</task-notification>"}""")).ToArray();
        Assert.Empty(TranscriptInfo.Parse(done).AsyncAgents);
        Assert.Empty(TranscriptInfo.Parse(done).Queued);                  // 系統通知不算待辦
        // 全檔追蹤（TokenTally）也一樣
        var tally = new TokenTally();
        tally.consume(Encoding.UTF8.GetString(launch).Split('\n'));
        Assert.Equal("ag-1", tally.asyncAgents.Single().Id);
        tally.consume(Encoding.UTF8.GetString(done).Split('\n').Skip(3));
        Assert.Empty(tally.asyncAgents);
    }

    [Fact]
    public void BoardCardsCarryActivityAndTokens()
    {
        var now = DateTime.Parse("2026-11-02T01:05:00Z").ToUniversalTime();
        var s = new SessionRecord { Pid = 11, SessionId = "sid-x", Cwd = "/h/ProjectA", Status = "busy" };
        var t = TranscriptInfo.Parse(Lines(
            """{"type":"user","timestamp":"2026-11-02T01:04:00Z","cwd":"/h/ProjectA","message":{"role":"user","content":"跑測試"}}""",
            """{"type":"assistant","timestamp":"2026-11-02T01:04:30Z","cwd":"/h/ProjectA","message":{"content":[{"type":"tool_use","id":"b1","name":"Bash","input":{"command":"swift test"}},{"type":"tool_use","id":"g1","name":"Agent","input":{"description":"看文件"}}]}}"""));
        t.Tokens = new TokenUsage(input: 10, output: 5);
        var c = Board.Build(new[] { s }, new Dictionary<string, TranscriptInfo> { ["sid-x"] = t }, new Dictionary<int, WorkState>(), Array.Empty<TeamConfig>(),
                            Array.Empty<TeamMessage>(), now, "/h", _ => false).Single();
        Assert.Equal(BoardColumn.Active, c.Column);
        Assert.Equal(AIActivity.Delegating, c.Activity);                 // 最後一個還沒回的是 Agent
        Assert.Equal("看文件", c.Subagents.Single().Description);
        Assert.Equal(15, c.Tokens!.total);
        // 卡住了，但在等子 agent ⇒ 不算卡住
        var late = now.AddMinutes(30);
        var c2 = Board.Build(new[] { s }, new Dictionary<string, TranscriptInfo> { ["sid-x"] = t }, new Dictionary<int, WorkState>(), Array.Empty<TeamConfig>(),
                             Array.Empty<TeamMessage>(), late, "/h", _ => false).Single();
        Assert.Equal((BoardColumn.Active, "交辦中，等子 agent 回來"), (c2.Column, c2.Reason));
        // office2 的 card 跟 Mac 同形狀
        var j = CardMirror.Of(c);
        Assert.Equal("delegating", j["activity"]!.GetValue<string>());
        Assert.Equal(15, j["tokens"]!["input"]!.GetValue<long>() + j["tokens"]!["output"]!.GetValue<long>());
    }

    [Fact]
    public void ReaderTalliesTokensAcrossTheWholeFileAndAttachesPermits()
    {
        var proj = Path.Combine(Claude, "projects", "-h-ProjectA");
        Directory.CreateDirectory(proj);
        var sb = new StringBuilder();
        sb.Append("""{"type":"user","timestamp":"2026-11-02T01:00:00Z","cwd":"/h/ProjectA","message":{"role":"user","content":"開始"}}""").Append('\n');
        for (int i = 0; i < 3; i++)
            sb.Append("{\"type\":\"assistant\",\"timestamp\":\"2026-11-02T01:00:0" + (i + 1) + "Z\",\"message\":{\"id\":\"m" + i + "\",\"role\":\"assistant\",\"content\":[{\"type\":\"text\",\"text\":\"x\"}],\"usage\":{\"input_tokens\":100,\"output_tokens\":10}}}").Append('\n');
        File.WriteAllText(Path.Combine(proj, "sid-x.jsonl"), sb.ToString());
        File.WriteAllText(Path.Combine(Claude, "sessions", "11.json"), """{"pid":11,"sessionId":"sid-x","cwd":"/h/ProjectA","status":"idle"}""");
        Hooks.Permit.Write(new Hooks.PermitRequest { Id = "sid-x-1", SessionId = "sid-x", Tool = "Bash", Summary = "ls", At = DateTime.UtcNow });
        var reader = new BoardReader(Claude, Home, "/h") { Alive = _ => true };
        var snap = reader.Read();
        var card = reader.Cards(snap, DateTime.UtcNow).Single();
        Assert.Equal(330, card.Tokens!.total);
        Assert.Equal("ls", card.Permit!.Summary);
        // 檔案長了：只讀新增的
        File.AppendAllText(Path.Combine(proj, "sid-x.jsonl"), """{"type":"assistant","timestamp":"2026-11-02T01:00:09Z","message":{"id":"m9","role":"assistant","content":[{"type":"text","text":"y"}],"usage":{"input_tokens":1,"output_tokens":1}}}""" + "\n");
        File.SetLastWriteTimeUtc(Path.Combine(proj, "sid-x.jsonl"), DateTime.UtcNow.AddSeconds(5));
        Assert.Equal(332, reader.Cards(reader.Read(), DateTime.UtcNow).Single().Tokens!.total);
        // 右側對話窗格：watch 誰就讀誰
        reader.Watching = "sid-x";
        Assert.Equal(new[] { "x", "x", "x", "y" }, reader.Read().SessionThread.Select(l => l.Text).ToArray());   // full：每一則 AI 的話都收
    }

    // MARK: 隊長對話、進度條

    [Fact]
    public void CaptainThreadKeepsWhatTheUserShouldSee()
    {
        var th = CaptainThread.Parse(Lines(
            """{"type":"user","uuid":"a","timestamp":"2026-11-02T01:00:00Z","origin":{"kind":"human"},"message":{"role":"user","content":"幫我派工"}}""",
            """{"type":"user","uuid":"b","origin":{"kind":"human"},"message":{"role":"user","content":"<command-name>/clear</command-name>"}}""",
            """{"type":"user","uuid":"c","origin":{"kind":"peer","name":"Bella"},"message":{"role":"user","content":"<cross-session-message from=\"uds:\" from-name=\"Bella\">\n【工作回報】做完了\n細節⋯\n</cross-session-message>"}}""",
            """{"type":"user","uuid":"d","origin":{"kind":"peer","name":"Chris"},"message":{"role":"user","content":"<cross-session-message from=\"uds:\" from-name=\"Chris\">\n密碼在 C:\\secret\n</cross-session-message>"}}""",
            """{"type":"assistant","uuid":"e","message":{"stop_reason":"tool_use","content":[{"type":"text","text":"中途的話"},{"type":"tool_use","id":"t","name":"Read","input":{"file_path":"C:\\a\\b.txt"}}]}}""",
            """{"type":"assistant","uuid":"f","message":{"stop_reason":"end_turn","content":[{"type":"text","text":"🧢 miniKang：提醒\n\n派給 Bella 了"}]}}"""));
        Assert.Equal(new[] { "幫我派工", "【工作回報】做完了", "Chris 傳來一則訊息（內容不顯示）", "派給 Bella 了" }, th.Select(l => l.Text).ToArray());
        Assert.Equal("終端機", th[0].Via);
        Assert.Equal(CaptainLine.RoleKind.report, th[1].Role);
        var full = CaptainThread.Parse(Lines(
            """{"type":"assistant","uuid":"e","message":{"stop_reason":"tool_use","content":[{"type":"text","text":"中途的話"},{"type":"tool_use","id":"t","name":"Read","input":{"file_path":"C:\\a\\b.txt"}},{"type":"tool_use","id":"u","name":"mcp__cool42__cool42_check","input":{}}]}}"""), full: true);
        Assert.Equal(new[] { "中途的話", "讀檔：b.txt", "用工具 cool42・cool42_check" }, full.Select(l => l.Text).ToArray());
        Assert.Equal(new[] { "e", "e#1", "e#2" }, full.Select(l => l.Id).ToArray());
        // office2 的形狀：role 是字串、at 是秒
        var j = MacMirror.Encode(th)!.AsArray();
        Assert.Equal("kang", j[0]!["role"]!.GetValue<string>());
        Assert.True(j[0]!["at"]!.GetValue<double>() > 1_700_000_000);
    }

    [Fact]
    public void RunProgressParsesBothFormats()
    {
        var a = RunProgress.Parse("""{"name":"Alex","label":"稽核（畫面）","done":12,"total":37,"updatedAt":1792955900,"eta":"4 分"}""")!;
        Assert.Equal(12.0 / 37, a.Fraction, 6);
        Assert.Equal("Alex", a.Name);
        var b = RunProgress.Parse("""{"label":"Alex 跑測試","pct":32,"updated":1792955900,"eta":""}""")!;
        Assert.Equal(0.32, b.Fraction, 6);
        Assert.Null(b.Eta);
        Assert.Null(RunProgress.Parse("""{"label":"x"}"""));
        Assert.True(RunProgress.Parse("""{"label":"x","pct":250,"updated":1}""")!.Fraction == 1);
        Assert.False(a.Fresh(a.UpdatedAt.AddMinutes(11)));
        var j = MacMirror.Encode(a)!;
        Assert.Equal(1792955900, j["updatedAt"]!.GetValue<double>());
    }

    [Fact]
    public void AnsweredMatchesQuestionsLoosely()
    {
        Assert.True(Answered.Same("要 push 嗎？", "要push嗎?"));
        Assert.False(Answered.Same("要 push 嗎？", "要部署嗎？"));
        Assert.False(Answered.Same(null, "x"));
        Assert.Equal("【使用者已答】Ruby：（卡片上沒有問題文字）→好。這題不用再問使用者；隊長卡片上同一題已自動清掉。", Answered.Relay("Ruby", " ", "好"));
    }

    [Fact]
    public void B1PostsForTheWeb()
    {
        Hooks.B1Board.Post("sid-a", "Alex", "ProjectA", "把 TermSend 的 150 ms 留著", null, DateTime.Parse("2026-11-02T01:00:00Z").ToUniversalTime());
        var j = B1Json.All();
        Assert.Equal("Alex", j[0]!["name"]!.GetValue<string>());
        Assert.Equal(1, j[0]!["id"]!.GetValue<int>());
        Assert.False(j[0]!.AsObject().ContainsKey("sid"));
    }
}
