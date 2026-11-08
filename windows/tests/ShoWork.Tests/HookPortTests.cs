using System.Text.Json.Nodes;
using ShoWork.Hooks;
using Xunit;
using HPermit = ShoWork.Hooks.Permit;
using HPermitAnswer = ShoWork.Hooks.PermitAnswer;

namespace ShoWork.Tests;

/// 11-02 補齊的 hook 端：permit、自動交接（Handover＋HandoverClear）、派工／名冊、b1、tick、statusline、ctx-wrapup、使用者打字＝事先放行、安裝 statusLine。
/// 對照 Mac 的 Tests/ShoWorkCoreTests/HandoverTests.swift、AskTests.swift、CardRelayTests.swift、B1TalkTests.swift、CaptainTests.swift。假名、假路徑，全部寫在暫存資料夾。
public sealed class HookPortTests : IDisposable
{
    static readonly DateTime T0 = DateTime.UnixEpoch.AddSeconds(1_792_650_000);
    readonly string root = Path.Combine(Path.GetTempPath(), "sw-port-" + Guid.NewGuid().ToString("N")[..8]);
    string Home => Path.Combine(root, "home");
    string Board => Path.Combine(Home, "board");
    string Claude => Path.Combine(root, "claude");
    static readonly string[] Vars = { "SHOWORK_HOME", "SHOWORK_CLAUDE_DIR", "SHOWORK_LOCAL_CONFIG", "SHOWORK_CAPTAIN_INBOX", "SHOWORK_RELEASE_LOG", "SHOWORK_PREAPPROVAL_LOG",
                                      "SHOWORK_PREVIEW_RULES", "SHOWORK_REVIEWER", "CLAUDE_CODE_ENTRYPOINT", "SHOWORK_HANDOVER_DIR", "SHOWORK_PERMIT_DIR", "SHOWORK_PREFS", "SHOWORK_B1_BOARD" };

    public HookPortTests()
    {
        foreach (var v in Vars) Environment.SetEnvironmentVariable(v, null);
        Directory.CreateDirectory(Path.Combine(Claude, "sessions"));
        Environment.SetEnvironmentVariable("SHOWORK_HOME", Home);
        Environment.SetEnvironmentVariable("SHOWORK_CLAUDE_DIR", Claude);
        var local = Path.Combine(root, "local.json");
        File.WriteAllText(local, """{"owner":"Demo User"}""");
        Environment.SetEnvironmentVariable("SHOWORK_LOCAL_CONFIG", local);
        HookCli.ClaudePid = () => null;
        HookCli.Alive = _ => true;
    }

    public void Dispose()
    {
        foreach (var v in Vars) Environment.SetEnvironmentVariable(v, null);
        HookCli.ClaudePid = () => null;
        HookCli.Alive = PeerSession.Alive;
        try { Directory.Delete(root, true); } catch { }
    }

    static JsonObject Obj(string? s) => (JsonObject)JsonNode.Parse(s!)!;

    /// 一個「活著」的假 session（pid＝這個測試行程，PeerSession.Live 才算它活著）
    void LiveSession(string sid, string cwd = "/x/專案A", string? name = null)
    {
        var o = new JsonObject { ["pid"] = Environment.ProcessId, ["sessionId"] = sid, ["cwd"] = cwd, ["kind"] = "interactive", ["entrypoint"] = "cli" };
        if (name != null) o["name"] = name;
        File.WriteAllText(Path.Combine(Claude, "sessions", $"{Environment.ProcessId}.json"), o.ToJsonString());
    }

    // MARK: permit

    static string BashHook(string sid) => new JsonObject
    {
        ["session_id"] = sid, ["hook_event_name"] = "PermissionRequest", ["tool_name"] = "Bash", ["cwd"] = "/x",
        ["tool_input"] = new JsonObject { ["command"] = "mkdir -p /x/out", ["description"] = "建資料夾" },
        ["permission_suggestions"] = new JsonArray(
            new JsonObject { ["type"] = "addRules", ["rules"] = new JsonArray(new JsonObject { ["toolName"] = "Bash", ["ruleContent"] = "mkdir:*" }), ["behavior"] = "allow", ["destination"] = "localSettings" },
            new JsonObject { ["type"] = "setMode", ["mode"] = "acceptEdits" }),
    }.ToJsonString();

    static string AskHook(string sid) => new JsonObject
    {
        ["session_id"] = sid, ["tool_name"] = "AskUserQuestion",
        ["tool_input"] = new JsonObject
        {
            ["questions"] = new JsonArray(
                new JsonObject { ["question"] = "午餐吃什麼？", ["header"] = "午餐", ["multiSelect"] = false,
                                 ["options"] = new JsonArray(new JsonObject { ["label"] = "麵", ["description"] = "" }, new JsonObject { ["label"] = "飯" }) },
                new JsonObject { ["question"] = "要加什麼？", ["multiSelect"] = true,
                                 ["options"] = new JsonArray(new JsonObject { ["label"] = "蛋" }, new JsonObject { ["label"] = "菜" }) }),
        },
    }.ToJsonString();

    [Fact] // 請求檔：欄位跟 Mac 一樣，看板（Board\BoardData.cs 的 Permit.Pending）讀得懂；只留 addRules
    public void PermitRequestFileMatchesMac()
    {
        var r = HPermit.Request(JsonNode.Parse(BashHook("S1abcdefgh")), 4242, T0)!;
        Assert.Equal($"S1abcdef-{(long)(T0 - DateTime.UnixEpoch).TotalMilliseconds}", r.Id);
        Assert.True(HPermit.Write(r));
        var j = Obj(File.ReadAllText(HPermit.RequestPath(r.Id)));
        Assert.Equal(new[] { "alwaysRules", "at", "cwd", "detail", "id", "pid", "sessionId", "summary", "tool" }, j.Select(kv => kv.Key).OrderBy(k => k, StringComparer.Ordinal));
        Assert.Equal("mkdir -p /x/out", j["summary"]!.GetValue<string>());
        Assert.Equal("建資料夾", j["detail"]!.GetValue<string>());
        Assert.DoesNotContain("setMode", j["alwaysRules"]!.GetValue<string>());
        var card = BoardJson.Decode<ShoWork.PermitRequest>(File.ReadAllText(HPermit.RequestPath(r.Id)))!;   // 卡片／office2 用的形狀（Board\Core\Activity.cs）
        Assert.Equal((r.Id, 4242, "Bash", T0), (card.Id, card.Pid, card.Tool, card.At));
        Assert.Equal(r.Id, HPermit.Pending(T0)["S1abcdefgh"].Id);
        // 回答檔＝Mac JSONEncoder 的 PermitAnswer：{"decision":"always"}
        Assert.True(HPermit.Answer(r.Id, new HPermitAnswer { Decision = "always" }));
        Assert.Equal("""{"decision":"always"}""", File.ReadAllText(HPermit.AnswerPath(r.Id)));
        Assert.Empty(HPermit.Pending(T0));                                          // 答了就不算在等
        var a = HPermit.ReadAnswer(r.Id)!;
        Assert.Equal("always", a.Decision);
        var o = Obj(HPermit.HookOutput(a, r))["hookSpecificOutput"]!;
        Assert.Equal("PermissionRequest", o["hookEventName"]!.GetValue<string>());
        Assert.Equal("allow", o["decision"]!["behavior"]!.GetValue<string>());
        Assert.Equal("mkdir:*", o["decision"]!["updatedPermissions"]![0]!["rules"]![0]!["ruleContent"]!.GetValue<string>());
    }

    [Fact] // 選擇題：答案填進 updatedInput（單選字串、多選陣列）；拒絕的訊息照 Mac
    public void AskAnswersGoIntoUpdatedInput()
    {
        var r = HPermit.Request(JsonNode.Parse(AskHook("S2")), null, T0)!;
        Assert.Equal("午餐吃什麼？／要加什麼？", r.Summary);
        Assert.Null(r.AlwaysRules);
        Assert.Null(r.Questions![0].Options[0].Description);                     // 空字串說明當沒有
        var a = new HPermitAnswer { Decision = "allow", Answers = new() { ["午餐吃什麼？"] = new() { "麵" }, ["要加什麼？"] = new() { "蛋", "菜" } } };
        var d = Obj(HPermit.HookOutput(a, r))["hookSpecificOutput"]!["decision"]!;
        Assert.Equal("麵", d["updatedInput"]!["answers"]!["午餐吃什麼？"]!.GetValue<string>());
        Assert.Equal(new[] { "蛋", "菜" }, d["updatedInput"]!["answers"]!["要加什麼？"]!.AsArray().Select(x => x!.GetValue<string>()));
        Assert.Equal(2, d["updatedInput"]!["questions"]!.AsArray().Count);       // 原輸入留著
        var deny = Obj(HPermit.HookOutput(new HPermitAnswer { Decision = "deny", Message = " 都不要 " }, r))["hookSpecificOutput"]!["decision"]!;
        Assert.Equal("使用者沒有選選項，在戰情中心回你：都不要", deny["message"]!.GetValue<string>());
        var plan = HPermit.Request(new JsonObject { ["session_id"] = "S3", ["tool_name"] = "ExitPlanMode", ["tool_input"] = new JsonObject { ["plan"] = "先做 A" } }, null, T0)!;
        Assert.Equal("計畫寫好了，要照這個做嗎？", plan.Summary);
        Assert.Equal("使用者在戰情中心退回這份計畫，先不要動手。", Obj(HPermit.HookOutput(new HPermitAnswer { Decision = "deny" }, plan))["hookSpecificOutput"]!["decision"]!["message"]!.GetValue<string>());
        // 題目全空的選擇題不收
        Assert.Null(HPermit.Request(new JsonObject { ["session_id"] = "S4", ["tool_name"] = "AskUserQuestion", ["tool_input"] = new JsonObject() }, null, T0));
    }

    [Fact] // hook 本體：等到看板回答 ⇒ 印 decision、收掉檔；AI 結束 ⇒ 安靜離開；終端機先答了（transcript 有 tool_result）⇒ 安靜離開
    public void PermitHookWaitsForBoard()
    {
        var hook = BashHook("S5");
        int n = 0;
        var o = HookCli.PermitHook(hook, sleep: _ =>
        {
            if (++n == 2)
                foreach (var f in Directory.GetFiles(Path.Combine(Board, "permits"), "*.json"))
                    HPermit.Answer(Path.GetFileNameWithoutExtension(f), new HPermitAnswer { Decision = "deny", Message = "先不要" });
        });
        Assert.Equal("使用者在戰情中心按了拒絕，並說：先不要", Obj(o)["hookSpecificOutput"]!["decision"]!["message"]!.GetValue<string>());
        Assert.Empty(Directory.GetFiles(Path.Combine(Board, "permits"), "*.json"));

        HookCli.ClaudePid = () => 999_999;
        HookCli.Alive = _ => false;
        Assert.Null(HookCli.PermitHook(hook, sleep: _ => { }));
        Assert.Empty(Directory.GetFiles(Path.Combine(Board, "permits"), "*.json"));

        HookCli.Alive = _ => true;
        var tpath = Path.Combine(root, "t.jsonl");
        var use = new JsonObject { ["type"] = "assistant", ["message"] = new JsonObject { ["content"] = new JsonArray(new JsonObject
            { ["type"] = "tool_use", ["id"] = "toolu_1", ["name"] = "Bash", ["input"] = new JsonObject { ["command"] = "mkdir -p /x/out", ["description"] = "建資料夾" } }) } };
        File.WriteAllText(tpath, use.ToJsonString() + "\n");
        var h2 = Obj(hook); h2["transcript_path"] = tpath;
        int m = 0;
        Assert.Null(HookCli.PermitHook(h2.ToJsonString(), sleep: _ =>
        {
            if (++m == 2) File.AppendAllText(tpath, """{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"toolu_1","content":"ok"}]}}""" + "\n");
            if (m > 50) throw new Exception("沒收掉");
        }));
        Assert.Empty(Directory.GetFiles(Path.Combine(Board, "permits"), "*.json"));
    }

    // MARK: 使用者在 session 直接打的指令＝事先放行（Mac 2ce3a8a）

    [Fact]
    public void TypedPromptReleasesBlockedItem()
    {
        LiveSession("S6");
        // 先擋一個 LINE 傳訊
        var deny = HookCli.GuardPush(new JsonObject { ["session_id"] = "S6", ["cwd"] = "/x", ["tool_input"] = new JsonObject { ["command"] = "python3 ~/.claude/scripts/line_send.py 學弟 你好" } }.ToJsonString(),
                                     T0, (_, _) => (128, ""), _ => null);
        Assert.NotNull(deny);
        var item = CaptainInbox.All().Single(i => i.Kind == "block");
        // 否定句不算
        var t1 = HookCli.Title(new JsonObject { ["session_id"] = "S6", ["hook_event_name"] = "UserPromptSubmit", ["prompt"] = "先不要傳給學弟" }.ToJsonString(), null, T0.AddMinutes(1), "/sw");
        Assert.DoesNotContain("已點名放行", t1);
        Assert.Null(CaptainInbox.Item(item.Id)!.Released);
        // 點名「傳給」＝放行，回給 AI 一句話
        var t2 = HookCli.Title(new JsonObject { ["session_id"] = "S6", ["hook_event_name"] = "UserPromptSubmit", ["prompt"] = "好，傳給學弟" }.ToJsonString(), null, T0.AddMinutes(2), "/sw");
        Assert.Contains($"使用者這則指令已點名放行單號 {item.Id}", t2);
        Assert.NotNull(CaptainInbox.Item(item.Id)!.Released);
        Assert.Contains("下指令：好，傳給學弟", CaptainInbox.Releases().Last()["byName"]!.GetValue<string>());
        // 其他 session 的訊息不算
        var t3 = HookCli.Title(new JsonObject { ["session_id"] = "S6", ["hook_event_name"] = "UserPromptSubmit", ["prompt"] = "<cross-session-message from=\"uds:\" from-name=\"Bella\">傳給學弟</cross-session-message>" }.ToJsonString(), null, T0.AddMinutes(3), "/sw");
        Assert.DoesNotContain("已點名放行", t3);
    }

    // MARK: 自動交接

    HandoverRecord Rec(string sid, int pid = 100, string cwd = "/x/專案A", string state = "pending", double ago = 60) =>
        new() { Sid = sid, Pid = pid, Cwd = cwd, Name = "小明", Handoff = "/x/專案A/docs/HANDOFF.md", Summary = "下一步做按鈕", At = T0.AddSeconds(-ago), State = state };

    [Fact] // ③ 認領：compact 同 sid；clear 同行程；新開同資料夾且原 session 已不在（同 Mac HandoverTests.match）＋Windows 路徑大小寫
    public void HandoverMatch()
    {
        var a = Rec("舊A");
        var none = new HashSet<string>();
        Assert.Equal("舊A", Handover.Match(new() { a }, "舊A", 100, null, "compact", none, T0)?.Sid);
        Assert.Equal("舊A", Handover.Match(new() { a }, "新B", 100, null, "clear", none, T0)?.Sid);
        Assert.Equal("舊A", Handover.Match(new() { a }, "新B", 999, "/x/專案A/", "startup", none, T0)?.Sid);
        Assert.Null(Handover.Match(new() { a }, "新B", 999, "/x/專案A", "startup", new HashSet<string> { "舊A" }, T0));
        Assert.Null(Handover.Match(new() { a }, "新B", 999, "/x/專案B", "startup", none, T0));
        Assert.Null(Handover.Match(new() { Rec("舊A", ago: 3700) }, "新B", 100, null, "clear", none, T0));
        Assert.Null(Handover.Match(new() { Rec("舊A", state: "taken") }, "新B", 100, null, "clear", none, T0));
        Assert.Null(Handover.Match(new() { a }, "新B", 100, null, "compact", none, T0));
        Assert.Equal("舊W", Handover.Match(new() { Rec("舊W", cwd: @"C:\Users\Demo User\ProjectA") }, "新B", 999, "c:/users/demo user/projecta/", "startup", none, T0)?.Sid);
    }

    [Fact] // ② 送 /clear 的條件（同 Mac HandoverTests.ready）
    public void HandoverReady()
    {
        bool Ok(string s = "pending", string? kind = "wrapup", bool working = false, bool dialog = false, double last = 30) =>
            Handover.ReadyToClear(s, kind, working, dialog, T0.AddSeconds(-last), TimeSpan.Zero, T0);
        Assert.True(Ok());
        Assert.False(Ok("interrupted"));
        Assert.False(Ok("clearing"));
        Assert.True(Ok(kind: null));
        Assert.False(Ok(kind: "start"));
        Assert.False(Ok(working: true));
        Assert.False(Ok(dialog: true));
        Assert.False(Ok(last: 2));
    }

    [Fact] // 收尾卡登記交接 → SessionStart 認領：名字沿用、派工單轉手、暫存訊息補交；記錄檔欄位 Mac 讀得回去
    public void WrapupCardThenClaim()
    {
        LiveSession("舊S");
        NicknameStore.Save("舊S", new Nickname { Name = "Quinn", Doing = "整理名片", At = T0 });
        CaptainStore.Save(new CaptainTask { Id = "T1", From = "CAP", To = "Quinn", ToSession = "舊S", Text = "整理名片", CreatedAt = T0, UpdatedAt = T0 });
        var handoff = Path.Combine(root, "HANDOFF.md"); File.WriteAllText(handoff, "x");
        HookCli.ClaudePid = () => 4321;
        var (code, out_, _) = HookCli.Card(new() { "--kind", "wrapup", "--handoff", handoff, "--summary", "下一步做按鈕", "--doing", "整理名片" }, "舊S", T0);
        Assert.Equal(0, code);
        Assert.Contains("已登記交接", out_);
        var j = Obj(File.ReadAllText(Path.Combine(Board, "handover", "舊S.json")));
        Assert.Equal(new[] { "at", "cwd", "handoff", "kicked", "name", "notified", "pid", "sid", "state", "summary", "tasks" }, j.Select(kv => kv.Key).OrderBy(k => k, StringComparer.Ordinal));
        Assert.Equal(4321, j["pid"]!.GetValue<int>());
        Assert.Equal("pending", j["state"]!.GetValue<string>());
        Assert.Equal("/x/專案A", j["cwd"]!.GetValue<string>());
        Assert.Equal("已收尾待 /clear", Handover.Load("舊S")!.Label);
        // 收尾中：看板的訊息先暫存；使用者的不暫存
        Assert.True(Handover.ShouldHold("舊S", "AI工作戰情中心（巡檢）"));
        Assert.False(Handover.ShouldHold("舊S", "AI工作戰情中心（使用者）"));
        Handover.Hold("舊S", "【工作回報】小華做完了", "AI工作戰情中心", T0);
        // /clear 後同一個 claude 行程、新 sid 的 SessionStart
        var brief = HookCli.Brief(new JsonObject { ["session_id"] = "新S", ["source"] = "clear", ["cwd"] = "/x/專案A" }.ToJsonString(), null, "/sw", T0.AddMinutes(1));
        Assert.StartsWith("【自動接手】你是 Quinn 的接手", brief);
        Assert.Contains(handoff, brief);
        Assert.Contains("派工單沿用：T1", brief);
        Assert.Contains("小華做完了", brief);
        Assert.Contains("你在戰情中心的名字是 Quinn", brief);
        Assert.Equal("Quinn", NicknameStore.Get("新S")!.Name);
        Assert.Equal("舊S", NicknameStore.Get("新S")!.HandoverFrom);
        Assert.Equal("新S", CaptainStore.Task("T1")!.ToSession);
        var r = Handover.Load("舊S")!;
        Assert.Equal("taken", r.State); Assert.Equal("新S", r.NewSid); Assert.Equal(new[] { "T1" }, r.Tasks);
        // 再一次 SessionStart 不會再認領
        Assert.DoesNotContain("自動接手", HookCli.Brief(new JsonObject { ["session_id"] = "新S2", ["source"] = "clear" }.ToJsonString(), null, "/sw", T0.AddMinutes(2)));
    }

    [Fact] // 收尾後：巡檢／組員訊息不算打斷（回「交接中」）；使用者打字才 interrupted；tick 轉隊長提醒一次
    public void HandoverInterruptedByUserOnly()
    {
        Assert.True(Handover.Save(Rec("假A")));
        var t = HookCli.Title(new JsonObject { ["session_id"] = "假A", ["hook_event_name"] = "UserPromptSubmit",
            ["prompt"] = "<cross-session-message from=\"uds:/x\" from-name=\"AI工作戰情中心（巡檢）\">巡檢</cross-session-message>" }.ToJsonString(), null, T0, "/sw");
        Assert.Contains("【交接中】", t);
        Assert.Equal("pending", Handover.Load("假A")!.State);
        HookCli.Title(new JsonObject { ["session_id"] = "假A", ["hook_event_name"] = "UserPromptSubmit", ["prompt"] = "再幫我改一個地方" }.ToJsonString(), null, T0, "/sw");
        Assert.Equal("interrupted", Handover.Load("假A")!.State);
        HookCli.Tick(false, T0, "/sw");
        Assert.True(Handover.Load("假A")!.Notified);
        var log = File.ReadAllText(Path.Combine(Board, "handover.log"));
        Assert.Contains("keep 小明", log); Assert.Contains("interrupted 小明", log);
    }

    static BoardCard Card(string sid, BoardColumn col = BoardColumn.Done, string? kind = "wrapup", double ago = 30, string reason = "做完了") => new()
    {
        Id = sid, SessionId = sid, Pid = 100, Column = col, Reason = reason, Project = "專案A", Title = "小明-整理", LastActivity = T0.AddSeconds(-ago),
        Report = new SelfReport { Status = ReportStatus.Done, Kind = kind, At = T0.AddSeconds(-ago) },
    };

    [Fact] // 看板端：閒下來送 /clear → sid 換了再打「開始接手」；送不出去 ⇒ failed＋卡片 blocked；20 秒沒換 ⇒ failed
    public void HandoverClearLoop()
    {
        var sent = new List<(string Target, string Text)>();
        bool idle = true, ok = true;
        var term = new HandoverClear.TermSender(
            (target, text) => { sent.Add((target, text)); return new TermSend.Result(ok ? TermSend.Outcome.Sent : TermSend.Outcome.AccessDenied, 100, ok ? "ok" : "不讓掛"); },
            _ => (idle, idle ? "idle" : "busy"));
        var sessions = Path.Combine(Claude, "sessions");
        void Sid(string s) => File.WriteAllText(Path.Combine(sessions, "100.json"), new JsonObject { ["pid"] = 100, ["sessionId"] = s }.ToJsonString());
        Sid("舊A");
        Handover.Save(Rec("舊A"));
        // 還在工作：不送
        HandoverClear.Check(new() { Card("舊A", BoardColumn.Active) }, Handover.All(), T0, term, sessions);
        Assert.Empty(sent);
        // 終端機那邊說忙：不送
        idle = false;
        HandoverClear.Check(new() { Card("舊A") }, Handover.All(), T0, term, sessions);
        Assert.Empty(sent);
        idle = true;
        HandoverClear.Check(new() { Card("舊A") }, Handover.All(), T0, term, sessions);
        Assert.Equal(new[] { ("100", "/clear") }, sent);
        Assert.Equal("clearing", Handover.Load("舊A")!.State);
        Assert.Equal("console", Handover.Load("舊A")!.Via);
        // sid 還沒換：不打接手；換了 ⇒ 打一次
        HandoverClear.Check(new() { Card("舊A") }, Handover.All(), T0.AddSeconds(3), term, sessions);
        Assert.Single(sent);
        Sid("新B");
        HandoverClear.Check(new(), Handover.All(), T0.AddSeconds(6), term, sessions);
        Assert.Equal(2, sent.Count);
        Assert.Equal("【自動接手】請接手 小明 的工作：先讀 /x/專案A/docs/HANDOFF.md，照裡面的下一步繼續。", sent[1].Text);
        Assert.True(Handover.Load("舊A")!.Kicked);
        HandoverClear.Check(new(), Handover.All(), T0.AddSeconds(9), term, sessions);
        Assert.Equal(2, sent.Count);                                        // 只打一次

        // 送不出去
        sent.Clear(); ok = false;
        Handover.Save(Rec("舊C", pid: 0));
        HandoverClear.Check(new() { Card("舊C") }, Handover.All(), T0, term, sessions);
        Assert.Equal("舊C", sent.Single().Target);                          // 沒記到 pid 就用 sid
        Assert.Equal("failed", Handover.Load("舊C")!.State);
        Assert.Equal("blocked", Obj(File.ReadAllText(Path.Combine(Board, "cards", "舊C.json")))["status"]!.GetValue<string>());

        // 送了 /clear、20 秒沒換 sid
        ok = true; sent.Clear();
        Sid("舊D");
        Handover.Save(Rec("舊D"));
        HandoverClear.Check(new() { Card("舊D") }, Handover.All(), T0, term, sessions);
        HandoverClear.Check(new() { Card("舊D") }, Handover.All(), T0.AddSeconds(21), term, sessions);
        Assert.Equal("failed", Handover.Load("舊D")!.State);
    }

    [Fact] // 名冊：英文名用 board\names 的、欄位跟 Mac roster.json 一樣；showork roster 讀得回來
    public void RosterRoundTrip()
    {
        var c = Card("S7", BoardColumn.Active);
        c.Name = "Ivy-整理"; c.Detail = "最後一句"; c.Ctx = new ContextUse { Percent = 42.6, Tokens = 300_000 }; c.Kind = "interactive"; c.Cwd = "/x/專案A";
        var roster = HandoverClear.BuildRoster(new() { c }, null, new Dictionary<string, string?> { ["S7"] = "已收尾待 /clear" },
                                               new Dictionary<string, Nickname> { ["S7"] = new() { Name = "Ivy" } }, T0);
        CaptainStore.SaveRoster(roster);
        var j = Obj(File.ReadAllText(Path.Combine(Board, "roster.json")));
        var e = (JsonObject)j["entries"]![0]!;
        Assert.Equal(new[] { "captain", "column", "ctx", "ctxTokens", "handover", "kind", "lastActivity", "name", "pid", "project", "reason", "root", "sameProject", "sessionId", "summary", "title" },
                     e.Select(kv => kv.Key).OrderBy(k => k, StringComparer.Ordinal));
        Assert.Equal("Ivy", e["name"]!.GetValue<string>());
        Assert.Equal("active", e["column"]!.GetValue<string>());
        Assert.Equal(42, e["ctx"]!.GetValue<int>());
        CaptainStore.Save(new CaptainTask { Id = "T9", From = "CAP", To = "Ivy", ToSession = "S7", Text = "做按鈕", CreatedAt = T0, UpdatedAt = T0 });
        var (code, out_, _) = HookCli.RosterCli(false, T0.AddSeconds(5));
        Assert.Equal(0, code);
        Assert.Contains("■ Ivy｜專案A｜進行中：做完了｜ctx 300k｜35 秒前", out_);
        Assert.Contains("  🔁 已收尾待 /clear（自動交接；/clear 前不要派新工作給它）", out_);
        Assert.Contains("  派工 T9［已派出］做按鈕", out_);
        Assert.Equal(1, HookCli.RosterCli(false, T0.AddSeconds(40)).Code);          // 30 秒前的名冊不算
    }

    [Fact] // 派工：名冊找人、建單（同 Mac 欄位）、送不出去印全文；接力的下一棒；取消
    public void TaskAddAndCancel()
    {
        LiveSession("CAP", name: "Penny");
        CaptainStore.SaveRoster(new Roster { At = T0, Entries = new() {
            new RosterEntry { Name = "Ivy", SessionId = "S8", Project = "專案A", Column = "done" },
            new RosterEntry { Name = "Jade", SessionId = "S9", Project = "專案B", Column = "done", CtxTokens = 900_000 } } });
        var (c1, o1, e1) = HookCli.TaskCli(new() { "add", "--to", "Ivy", "--text", "做按鈕\n判準：能按", "--then-to", "Jade", "--then", "寫測試" }, "CAP", T0, "/sw");
        Assert.Equal(0, c1);
        Assert.Contains("已建，但直送失敗", o1);                                    // 對方沒開著：印全文給隊長改用 SendMessage
        Assert.Contains("回報方式：這件事每一輪的 showork card 都加上 --task", o1);
        var t = CaptainStore.Tasks().Single();
        Assert.Equal(("Ivy", "S8", "專案A", "Jade", "sent"), (t.To, t.ToSession, t.Project, t.ThenTo, t.State));
        Assert.Matches(@"^T\d{10}$", t.Id);
        Assert.Equal("CAP", CaptainStore.Captain());                              // 派工的人自動成為隊長
        var j = Obj(File.ReadAllText(Path.Combine(Board, "tasks", t.Id + ".json")));
        Assert.Equal(new[] { "createdAt", "from", "id", "project", "sendError", "state", "text", "thenText", "thenTo", "to", "toSession", "updatedAt" }, j.Select(kv => kv.Key).OrderBy(k => k, StringComparer.Ordinal));
        Assert.Contains("context 已用 900k", HookCli.TaskCli(new() { "add", "--to", "Jade", "--text", "x" }, "CAP", T0, "/sw").Err);
        Assert.Contains("名冊裡沒有「Zed」", HookCli.TaskCli(new() { "add", "--to", "Zed", "--text", "x" }, "CAP", T0, "/sw").Err);
        Assert.Contains("--then-to 和 --then 要一起給", HookCli.TaskCli(new() { "add", "--to", "Ivy", "--text", "x", "--then-to", "Jade" }, "CAP", T0, "/sw").Err);
        // 回報（card --task）→ 單子變 done；接力的下一棒
        Assert.True(CaptainStore.ApplyTask(t.Id, new CardReport { Status = "done", Summary = "做好了", At = T0.AddMinutes(5) }));
        var done = CaptainStore.Task(t.Id)!;
        Assert.Equal("done", done.State);
        Assert.True(Dispatch.ShouldNotify(done));
        var next = Dispatch.NextLeg(done, "T2", T0)!;
        Assert.Equal("Jade", next.To); Assert.Contains("前一棒 Ivy 已完成「做按鈕 判準：能按」，回報：做好了", next.Text);
        Assert.Contains("【派工回報 " + t.Id + "】Ivy：完成——做好了", Dispatch.ReportText(done));
        var (c2, o2, _) = HookCli.TaskCli(new() { "cancel", t.Id }, "CAP", T0, "/sw");
        Assert.Equal(0, c2); Assert.Contains($"已取消 {t.Id}", o2);
        Assert.Equal("cancelled", CaptainStore.Task(t.Id)!.State);
        Assert.Contains($"{t.Id}［已取消］→ Ivy（專案A）", HookCli.TasksCli(true, T0).Out);
    }

    [Fact] // b1：留言（同 Mac 一行一則）、讀、收尾提示附最近 5 則
    public void B1Board_()
    {
        LiveSession("S10");
        var (c, o, _) = HookCli.B1Cli(new() { "post", "--text", "  git ls-tree 要加 quotepath=off\n不然中文檔名被跳脫  ", "--re", "#3" }, "S10", T0, "/sw");
        Assert.Equal(0, c); Assert.StartsWith("已留言 #1", o);
        var line = File.ReadAllLines(Path.Combine(Board, "b1-board.jsonl")).Single();
        var j = Obj(line);
        Assert.Equal("git ls-tree 要加 quotepath=off 不然中文檔名被跳脫", j["text"]!.GetValue<string>());
        Assert.Equal(3, j["re"]!.GetValue<int>());
        Assert.Contains("↪#3：git ls-tree", HookCli.B1Cli(new() { "read" }, null, T0, "/sw").Out);
        var hint = HookCli.B1Cli(new() { "hint" }, null, T0, "/sw").Out;
        Assert.StartsWith("④交流板檢討", hint);
        Assert.Contains("板上最近 1 則", hint);
        Assert.Contains("\"/sw\" b1 post", hint);
        Assert.Equal(1, HookCli.B1Cli(new() { "post" }, "S10", T0, "/sw").Code);
    }

    // MARK: tick（卡片轉送、合併預告、巡檢）

    [Fact]
    public void CardRelayPlan()
    {
        var st = new CardRelay.State();
        var reports = new Dictionary<string, CardReport> { ["A"] = new() { Status = "working", Summary = "一", At = T0 } };
        string Text(string sid, CardReport r) => CardRelay.Text(sid, "專案A", r);
        Assert.Empty(CardRelay.Plan(reports, "CAP", true, st, T0, Text));                     // 第一次只播種
        reports["A"] = new() { Status = "working", Summary = "二", How = "讀檔", At = T0 };
        var o = CardRelay.Plan(reports, "CAP", true, st, T0, Text);
        Assert.Equal("【工作回報】A（專案A）\n狀態 working\n摘要：二\n方法與工具：讀檔\n（看板自動轉送，對方不等你回覆；有疑慮再 SendMessage 給它）", o.Single().Text);
        reports["A"] = new() { Status = "working", Summary = "三", At = T0 };
        Assert.Empty(CardRelay.Plan(reports, "CAP", true, st, T0.AddSeconds(10), Text));    // 60 秒內不再送
        Assert.Single(CardRelay.Plan(reports, "CAP", true, st, T0.AddSeconds(61), Text));
        reports["CAP"] = new() { Status = "done", Summary = "隊長的", At = T0 };
        Assert.Empty(CardRelay.Plan(reports, "CAP", true, st, T0.AddSeconds(200), Text));   // 隊長自己的不轉
        reports["B"] = new() { Status = "working", Kind = "start", Doing = "修 bug", At = T0.AddSeconds(200) };
        Assert.StartsWith("【開工】B（專案A）：修 bug", CardRelay.Plan(reports, "CAP", true, st, T0.AddSeconds(201), Text).Single().Text);
        // 狀態存檔讀回
        var back = CardRelay.State.From(JsonNode.Parse(HookJson.Text(st.ToJson())));
        Assert.True(back.Seeded); Assert.Equal(st.SentKey, back.SentKey); Assert.Equal("修 bug", back.LastStart["B"].Doing);
    }

    [Fact]
    public void NoticesAndAlarm()
    {
        InboxItem N(string sid, double ago) => new() { Id = CaptainInbox.NewID("notice"), Kind = "notice", At = T0.AddSeconds(-ago), Sid = sid, Name = sid, Kinds = new() { "mv" }, Text = "mv a b" };
        var due = CaptainLink.DueNotices(new() { N("A", 10), N("A", 6), N("B", 2), N("C", 700) }, T0);
        Assert.Equal("A", due.Single()[0].Sid);                                    // B 還沒安靜 5 秒、C 太舊
        Assert.Equal(2, due[0].Count);
        Assert.StartsWith("【動作預告】A：2 個動作（不擋，已在跑）\n・mv：mv a b", CaptainLink.NoticeText(due[0]));
        var r = new Roster { At = T0, Entries = new() { new() { Name = "小明", SessionId = "a", Project = "專案A", Column = "done", Ctx = 72, LastActivity = T0 } } };
        var plain = CaptainLink.Alarm(r, 0, T0);
        Assert.StartsWith("【巡檢時間】在線 1 人（不含隊長）；ctx：小明 72%；閒置超過 30 分鐘：沒有", plain.Text);
        r.Entries[0].Handover = "已收尾待 /clear";
        var a = CaptainLink.Alarm(r, 2, T0);
        Assert.Contains("已收尾、還沒 /clear：小明（已收尾待 /clear）", a.Text);
        Assert.Contains("收件匣未處理 2 則", a.Text);
        Assert.NotEqual(plain.Sig, a.Sig);
    }

    // MARK: statusline／ctx-wrapup

    [Fact] // 狀態列：寫 ctx 與 rate_limits（跟 Mac statusline.py 同格式、同合併規則），沒串接就印自己的一行
    public void StatusLineWritesUsage()
    {
        double now = (T0 - DateTime.UnixEpoch).TotalSeconds;
        var stdin = new JsonObject
        {
            ["session_id"] = "S11", ["model"] = new JsonObject { ["display_name"] = "Opus" },
            ["context_window"] = new JsonObject { ["used_percentage"] = 23.4, ["total_input_tokens"] = 46_000 },
            ["rate_limits"] = new JsonObject
            {
                ["five_hour"] = new JsonObject { ["used_percentage"] = 15, ["resets_at"] = now + 7500 },
                ["seven_day"] = new JsonObject { ["used_percentage"] = 40, ["resets_at"] = now + 3 * 86400 },
            },
        }.ToJsonString();
        var line = StatusLine.Run(stdin, T0);
        Assert.Contains("Opus", line); Assert.Contains("23%", line); Assert.Contains("↻2h05m", line);
        var ctx = Obj(File.ReadAllText(Path.Combine(Claude, "cache", "ctx", "S11.json")));
        Assert.Equal(46_000, ctx["total_input_tokens"]!.GetValue<double>());
        Assert.Equal(now, ctx["at"]!.GetValue<double>(), 3);
        var rl = Obj(File.ReadAllText(Path.Combine(Claude, "cache", "rate_limits.json")));
        Assert.Equal(15, rl["rate_limits"]!["five_hour"]!["used_percentage"]!.GetValue<double>());
        Assert.Matches(@"^\d{4}-\d\d-\d\d \d\d:\d\d:\d\d$", rl["at"]!.GetValue<string>());
        Assert.NotNull(ShoWork.RateLimits.Parse(File.ReadAllText(Path.Combine(Claude, "cache", "rate_limits.json"))));   // 看板讀得懂
        // 另一個閒著的 session 帶舊數字（同一時段、比較小）⇒ 不倒退；過期的舊值不留
        var stale = Obj(stdin); stale["session_id"] = "S12"; stale["rate_limits"]!["five_hour"]!["used_percentage"] = 9;
        StatusLine.Run(stale.ToJsonString(), T0.AddSeconds(10));
        Assert.Equal(15, Obj(File.ReadAllText(Path.Combine(Claude, "cache", "rate_limits.json")))["rate_limits"]!["five_hour"]!["used_percentage"]!.GetValue<double>());
        var merged = StatusLine.Merge(new JsonObject { ["five_hour"] = new JsonObject { ["used_percentage"] = 99, ["resets_at"] = now - 1 } },
                                      new JsonObject { ["five_hour"] = new JsonObject { ["used_percentage"] = 1, ["resets_at"] = now + 100 } }, now);
        Assert.Equal(1, merged["five_hour"]!["used_percentage"]!.GetValue<int>());
        Assert.Equal("", StatusLine.Run("不是 JSON", T0));
    }

    [Fact] // 串接：使用者原本的 statusLine 拿到同一份 stdin、輸出原樣印
    public void StatusLineChainsUserCommand()
    {
        if (OperatingSystem.IsWindows()) return;                                  // /bin/sh 版本；Windows 走 Git Bash，Surface 實測
        Directory.CreateDirectory(Home);
        File.WriteAllText(StatusLine.ChainPath, new JsonObject { ["statusLine"] = new JsonObject { ["type"] = "command", ["command"] = "cat | wc -c | tr -d ' '" } }.ToJsonString());
        var stdin = """{"session_id":"S13","context_window":{"used_percentage":5}}""";
        Assert.Equal(stdin.Length.ToString(), StatusLine.Run(stdin, T0).Trim());
        Assert.True(File.Exists(Path.Combine(Claude, "cache", "ctx", "S13.json")));
    }

    [Fact] // Stop hook：門檻以上請它收尾（block＋理由含 showork 路徑與交流板段）；同一段只收一次；多 150k 再收；掉回門檻下重新上膛
    public void CtxWrapupFlow()
    {
        double now = (T0 - DateTime.UnixEpoch).TotalSeconds;
        void Ctx(int tok, double at) => HookJson.WriteAtomic(Path.Combine(Claude, "cache", "ctx", "S14.json"), new JsonObject { ["used_percentage"] = 30, ["total_input_tokens"] = tok, ["at"] = at }.ToJsonString());
        var stop = """{"session_id":"S14","cwd":"/x","hook_event_name":"Stop"}""";
        Ctx(200_000, now);
        Assert.Null(CtxWrapup.Run(stop, "/sw", null, T0));
        Ctx(260_000, now);
        var o = Obj(CtxWrapup.Run(stop, "C:/Users/Demo User/AppData/Local/ShoWork42/bin/showork.exe", null, T0));
        Assert.Equal("block", o["decision"]!.GetValue<string>());
        var reason = o["reason"]!.GetValue<string>();
        Assert.StartsWith("【AI工作戰情中心】context 已用 260k（30%），請收尾", reason);
        Assert.Contains("④交流板檢討", reason);
        Assert.Contains("⑤最後發收尾卡：`\"C:/Users/Demo User/AppData/Local/ShoWork42/bin/showork.exe\" card --kind wrapup", reason);
        Assert.Null(CtxWrapup.Run(stop, "/sw", null, T0));                          // 收過了
        Ctx(420_000, now);
        Assert.Contains("上次收尾在 260k", CtxWrapup.Run(stop, "/sw", null, T0));
        Ctx(100_000, now);
        Assert.Null(CtxWrapup.Run(stop, "/sw", null, T0));
        Assert.False(File.Exists(Path.Combine(Claude, "cache", "ctx_wrapup", "S14")));   // 重新上膛
        Assert.Null(CtxWrapup.Run("""{"session_id":"S14","stop_hook_active":true}""", "/sw", "300k", T0));
        Ctx(300_000, now - 3600);
        Assert.Null(CtxWrapup.Run(stop, "/sw", null, T0));                          // 狀態列太久沒更新
        Assert.NotNull(CtxWrapup.Run("""{"session_id":"S15"}""", "/sw", "300k", T0));   // 測試用假 ctx
        // 門檻可調；關掉自動收尾
        Directory.CreateDirectory(Board);
        File.WriteAllText(Path.Combine(Board, "prefs.json"), """{"board.ctxTokens": 500000}""");
        Assert.Equal(500_000, Hooks.ContextGuard.TokenLimit);
        Assert.Null(CtxWrapup.Run("""{"session_id":"S16"}""", "/sw", "300k", T0));
        File.WriteAllText(Path.Combine(Board, "prefs.json"), """{"board.autoWrapUp": false}""");
        Assert.Null(CtxWrapup.Run("""{"session_id":"S17"}""", "/sw", "300k", T0));
        Assert.Equal(300_000, CtxWrapup.ParseTestCtx("300k"));
        Assert.Equal(1_200_000, CtxWrapup.ParseTestCtx("1.2m"));
    }

    // MARK: 安裝：hooks 多了 permit／ctx-wrapup；statusLine 串接、解除安裝還原

    [Fact]
    public void InstallerChainsStatusLine()
    {
        var settings = Path.Combine(root, "settings.json");
        var exe = @"C:\Users\Demo User\AppData\Local\ShoWork42\bin\showork.exe";
        var orig = """{"statusLine":{"type":"command","command":"bash ~/.claude/my-line.sh","padding":1},"hooks":{"Stop":[{"hooks":[{"type":"command","command":"echo bye"}]}]}}""" + "\n";
        File.WriteAllText(settings, orig);
        Assert.Equal("merged", Installer.InstallHooks(settings, exe));
        var j = Obj(File.ReadAllText(settings));
        Assert.Equal("\"C:/Users/Demo User/AppData/Local/ShoWork42/bin/showork.exe\" statusline", j["statusLine"]!["command"]!.GetValue<string>());
        Assert.Equal(1, j["statusLine"]!["padding"]!.GetValue<int>());
        Assert.Equal("bash ~/.claude/my-line.sh", StatusLine.ChainedCommand());
        var stop = j["hooks"]!["Stop"]!.AsArray().Select(g => g!["hooks"]![0]!["command"]!.GetValue<string>()).ToList();
        Assert.Equal("echo bye", stop[0]);                                         // 使用者的留在前面
        Assert.Contains(stop, c => c.EndsWith("ctx-wrapup"));
        Assert.Contains(j["hooks"]!["PermissionRequest"]!.AsArray(), g => g!["hooks"]![0]!["command"]!.GetValue<string>().EndsWith(" permit") && g["hooks"]![0]!["timeout"]!.GetValue<int>() == 3660);
        Assert.NotEmpty(Directory.GetFiles(root, "settings.json.bak-*"));          // 改之前先備份
        Assert.Equal("already installed", Installer.InstallHooks(settings, exe));
        Assert.Equal("removed", Installer.UninstallHooks(settings));
        Assert.Equal(orig, File.ReadAllText(settings));                            // 一字不差還原
        Assert.False(File.Exists(Installer.StatusChain));

        // 原本沒有 statusLine：裝上去、拆掉時拿掉
        File.WriteAllText(settings, """{"theme":"dark"}""");
        Installer.InstallHooks(settings, exe);
        Assert.NotNull(Obj(File.ReadAllText(settings))["statusLine"]);
        Assert.Null(StatusLine.ChainedCommand());
        Installer.UninstallHooks(settings);
        Assert.Null(Obj(File.ReadAllText(settings))["statusLine"]);
    }
}
