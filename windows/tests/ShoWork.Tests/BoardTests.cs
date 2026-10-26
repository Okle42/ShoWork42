using System.Text;
using ShoWork;
using Xunit;

namespace ShoWork.Tests;

/// Tests/ShoWorkCoreTests/BoardTests.swift 的移植，加上 Windows 路徑（磁碟代號、反斜線、大小寫）的案例
public class BoardTests
{
    static readonly DateTime Now = DateTime.UnixEpoch.AddSeconds(1_791_440_000);
    static byte[] U(string s) => Encoding.UTF8.GetBytes(s);
    static byte[] Lines(params string[] l) => U(string.Join("\n", l));

    [Fact] // 分欄：紅＝待審、忙＝進行中、忙太久＝卡住、綠＝待審、閒＝完成
    public void Columns()
    {
        Assert.Equal(BoardColumn.Review, Board.Column("busy", WorkState.Input, Now, Now).Item1);
        Assert.Equal(BoardColumn.Active, Board.Column("busy", null, Now.AddSeconds(-60), Now).Item1);
        Assert.Equal(BoardColumn.Stuck, Board.Column("busy", null, Now.AddMinutes(-11), Now).Item1);
        Assert.Equal("11 分鐘沒有新動靜", Board.Column("busy", null, Now.AddMinutes(-11), Now).Item2);
        Assert.Equal(BoardColumn.Active, Board.Column("idle", WorkState.Working, Now, Now).Item1);     // hook 比 status 檔快
        Assert.Equal(BoardColumn.Review, Board.Column("idle", WorkState.Done, Now, Now).Item1);
        Assert.Equal(BoardColumn.Done, Board.Column("idle", null, Now, Now).Item1);
        Assert.Equal(BoardColumn.Done, Board.Column("shell", null, Now.AddHours(-1), Now).Item1);      // 只是背景指令還在
        Assert.Equal(BoardColumn.Active, Board.Column("busy", null, null, Now).Item1);                  // 沒紀錄不判卡住
    }

    [Fact] // session 檔（Mac 10-08 實際格式，多的欄位略過）＋ Windows 的資料夾命名
    public void SessionRecordAndSlug()
    {
        var j = """{"pid":7369,"sessionId":"264343ad-21db","cwd":"/Users/k","startedAt":1,"kind":"interactive","name":"k-b3","status":"busy","updatedAt":1791448526068,"peerFeatures":["notify_idle"]}""";
        var s = SessionRecord.Decode(j)!;
        Assert.True(s.Pid == 7369 && s.Status == "busy" && s.ProjectSlug == "-Users-k" && s.Name == "k-b3" && s.UpdatedAt == 1791448526068);
        Assert.Equal("-private-tmp-a-b", new SessionRecord { Pid = 1, SessionId = "x", Cwd = "/private/tmp/a.b" }.ProjectSlug);
        Assert.Equal("-t-accept-C----", new SessionRecord { Pid = 1, SessionId = "x", Cwd = "/t/accept/C-快做完" }.ProjectSlug);
        Assert.Equal("-t-claude-501-a-b", new SessionRecord { Pid = 1, SessionId = "x", Cwd = "/t/claude-501/a_b" }.ProjectSlug);
        // Surface 10-15 實測的資料夾名
        Assert.Equal("C--Users-Demo-User-ShoWork42", new SessionRecord { Cwd = @"C:\Users\Demo User\ShoWork42" }.ProjectSlug);
        Assert.Equal("C--Users-DEMOUS-1-AppData-Local-Temp-SW42-E-1-wt", new SessionRecord { Cwd = @"C:\Users\DEMOUS~1\AppData\Local\Temp\SW42-E~1-wt" }.ProjectSlug);
        Assert.Equal("C--Windows-System32", new SessionRecord { Cwd = @"C:\Windows\System32" }.ProjectSlug);
        // Windows 路徑在 JSON 裡是跳脫過的反斜線
        var w = SessionRecord.Decode("""{"pid":4242,"sessionId":"abc","cwd":"C:\\Users\\Demo User","entrypoint":"cli","pidDomain":"win32"}""")!;
        Assert.Equal(@"C:\Users\Demo User", w.Cwd);
        Assert.Null(SessionRecord.Decode("{壞掉"));
        Assert.Null(SessionRecord.Decode("""{"pid":1}"""));          // 沒有 sessionId 不算
    }

    [Fact] // pid 被重用：行程比 session 晚一分鐘以上出生就不是它
    public void PidReuse()
    {
        var r = new SessionRecord { Pid = 1, SessionId = "x", StartedAt = 1_791_440_000_000 };
        var started = DateTime.UnixEpoch.AddMilliseconds(1_791_440_000_000);
        Assert.True(r.SameOwner(started.AddSeconds(-2)));            // claude.exe 先出生、session 檔後寫
        Assert.True(r.SameOwner(started.AddSeconds(30)));
        Assert.False(r.SameOwner(started.AddMinutes(5)));
        Assert.True(new SessionRecord { Pid = 1, SessionId = "x" }.SameOwner(DateTime.UtcNow));   // 沒有 startedAt 就不判
    }

    [Fact] // 對話紀錄：標題、最後 cwd、最後一句、排隊（系統通知不算）、第一行壞掉
    public void Transcript()
    {
        var t = TranscriptInfo.Parse(Lines(
            "cut-off garbage {",
            """{"type":"user","cwd":"/r/A","timestamp":"2026-10-08T05:29:00.000Z"}""",
            """{"type":"ai-title","aiTitle":"語音備忘錄整理"}""",
            """{"type":"assistant","cwd":"/r/B","timestamp":"2026-10-08T05:30:00.500Z","message":{"content":[{"type":"text","text":"做完了"},{"type":"tool_use"}]}}""",
            """{"type":"assistant","timestamp":"2026-10-08T05:30:01.000Z","message":{"content":[{"type":"tool_use"}]}}""",
            """{"type":"queue-operation","operation":"enqueue","content":"先做 A"}""",
            """{"type":"queue-operation","operation":"dequeue"}""",
            """{"type":"queue-operation","operation":"enqueue","content":"<task-notification>x"}""",
            """{"type":"queue-operation","operation":"enqueue","content":"再做 B"}""",
            """{"type":"last-prompt","lastPrompt":"好"}"""));
        Assert.Equal("語音備忘錄整理", t.Title);
        Assert.Equal("/r/B", t.LastCwd);
        var mem = TranscriptInfo.Parse(Lines("""{"cwd":"/h/github-repos/ProjectB"}""", """{"cwd":"/h/.claude/projects/-h/memory"}"""));
        Assert.True(mem.LastCwd == "/h/.claude/projects/-h/memory" && mem.LastWorkCwd == "/h/github-repos/ProjectB");
        Assert.Equal("做完了", t.LastAssistantText);
        Assert.Equal("好", t.LastPrompt);
        Assert.Equal("回答 1+1", TranscriptInfo.Parse(U("""{"type":"user","message":{"role":"user","content":"回答 1+1"}}""")).LastPrompt);
        Assert.Null(TranscriptInfo.Parse(U("""{"type":"user","message":{"content":[{"type":"tool_result"}]}}""")).LastPrompt);
        Assert.Equal(new[] { "再做 B" }, t.Queued);
        Assert.Equal(TranscriptInfo.Iso("2026-10-08T05:30:01.000Z"), t.LastActivity);
        Assert.Equal(new DateTime(2026, 10, 8, 5, 30, 1, DateTimeKind.Utc), t.LastActivity);
    }

    [Fact] // 審查 10-15：一行壞掉只略過那一行（Swift 的 JSONSerialization 同樣），不能整份對話紀錄跟著不見
    public void TranscriptSkipsOnlyTheBadLine()
    {
        // 截斷 emoji 留下的孤立代理字元：GetString() 會丟 InvalidOperationException
        var t = TranscriptInfo.Parse(Lines(
            """{"type":"ai-title","aiTitle":"好標題","timestamp":"2026-10-15T01:00:00Z"}""",
            """{"type":"user","cwd":"/h/bad","timestamp":"2026-10-15T01:00:01Z","message":{"content":"壞掉 \ud83d 了"}}""",
            """{"type":"assistant","timestamp":"2026-10-15T01:00:02Z","message":{"content":[{"type":"text","text":"後面的回覆"}]}}"""));
        Assert.Equal("好標題", t.Title);
        Assert.Equal("後面的回覆", t.LastAssistantText);
        Assert.Equal(new DateTime(2026, 10, 15, 1, 0, 2, DateTimeKind.Utc), t.LastActivity);
        Assert.Null(t.LastPrompt);
        Assert.Null(t.LastCwd);                             // 壞掉那行的 cwd 也不算（不留半套）
        var a = TranscriptInfo.Parse(Lines(
            """{"type":"assistant","message":{"content":[{"type":"text","text":"好的"}]}}""",
            """{"type":"assistant","message":{"content":[{"type":"text","text":"壞 \udc00"}]}}"""));
        Assert.Equal("好的", a.LastAssistantText);
        // 巢狀 70 層：System.Text.Json 預設上限 64 會整行丟掉，Swift 讀得到
        var deep = new string('[', 70) + new string(']', 70);
        var d = TranscriptInfo.Parse(Lines(
            """{"type":"ai-title","aiTitle":"T1","cwd":"/h/p"}""",
            "{\"type\":\"ai-title\",\"aiTitle\":\"T2\",\"cwd\":\"/h/q\",\"x\":" + deep + "}"));
        Assert.Equal("T2", d.Title);
        Assert.Equal("/h/q", d.LastCwd);
    }

    [Fact] // 審查 10-15：時間跟 Swift 的 ISO8601DateFormatter 一樣嚴，一定要有時區
    public void IsoNeedsTimeZone()
    {
        foreach (var bad in new[] { "2026-10-15T10:00:00", "2026-10-15 10:00:00", "2026-10-15", "10/15/2026", "", "2026-10-15T10:00Z" })
            Assert.Null(TranscriptInfo.Iso(bad));
        var want = new DateTime(2026, 10, 15, 10, 0, 0, DateTimeKind.Utc);
        Assert.Equal(want, TranscriptInfo.Iso("2026-10-15T10:00:00Z"));
        Assert.Equal(want, TranscriptInfo.Iso("2026-10-15T18:00:00+08:00"));
        Assert.Equal(want, TranscriptInfo.Iso("2026-10-15T18:00:00+0800"));
        Assert.Equal(want.AddTicks(1_234_560), TranscriptInfo.Iso("2026-10-15T10:00:00.123456Z"));
        Assert.Equal(want.AddMilliseconds(123), TranscriptInfo.Iso("2026-10-15T10:00:00.123Z"));
        Assert.Equal(want.AddTicks(1_234_567), TranscriptInfo.Iso("2026-10-15T10:00:00.123456789Z"));   // 超過 7 位截掉
        // 沒時區的時間不算 ⇒ 不當成最後活動
        Assert.Null(TranscriptInfo.Parse(Lines("""{"type":"user","timestamp":"2026-10-15T10:00:00"}""")).LastActivity);
    }

    [Fact] // Windows：Surface 上實際的行（cwd 是跳脫的反斜線、行尾 \r\n）、~/.claude 底下與 Temp 不算做事的地方
    public void TranscriptWindows()
    {
        var t = TranscriptInfo.Parse(U(string.Join("\r\n",
            """{"parentUuid":"4ec3","type":"system","subtype":"turn_duration","timestamp":"2026-10-14T08:18:39.568Z","entrypoint":"cli","cwd":"C:\\Users\\Demo User\\ShoWork42","sessionId":"7d80","version":"2.1.293"}""",
            """{"type":"attachment","cwd":"C:\\Users\\Demo User\\.claude\\projects\\C--Users-Demo-User\\memory","timestamp":"2026-10-14T08:19:00.000Z"}""",
            """{"type":"user","cwd":"C:\\Users\\DEMOUS~1\\AppData\\Local\\Temp\\sw42-e2e-a","timestamp":"2026-10-14T08:20:00.000Z"}""")));
        Assert.Equal(@"C:\Users\DEMOUS~1\AppData\Local\Temp\sw42-e2e-a", t.LastCwd);
        Assert.Equal(@"C:\Users\Demo User\ShoWork42", t.LastWorkCwd);
        Assert.Single(t.RecentWorkCwds);
        Assert.True(TranscriptInfo.IsToolDir(@"C:\Users\Demo User\.claude"));
        Assert.True(TranscriptInfo.IsToolDir(@"c:\users\demo user\.CLAUDE\skills"));
        Assert.True(TranscriptInfo.IsToolDir(@"C:\Windows\Temp\x"));
        Assert.False(TranscriptInfo.IsToolDir(@"C:\Users\Demo User\claude-notes"));
        Assert.False(TranscriptInfo.IsToolDir(@"D:\Temp\proj"));
    }

    [Fact] // agent team 設定與信箱（Mac 10-08 實測格式）
    public void Team()
    {
        var c = """{"name":"session-16b861fc","createdAt":1,"leadAgentId":"team-lead@s","leadSessionId":"16b861fc-16dc","members":[{"agentId":"team-lead@s","name":"team-lead","agentType":"team-lead","joinedAt":1,"tmuxPaneId":"leader","subscriptions":[],"backendType":"in-process"},{"agentId":"coder@s","name":"coder","color":"blue","joinedAt":2,"agentType":"general-purpose","model":"sonnet","prompt":"…"}]}""";
        var cfg = TeamConfig.Decode(c)!;
        Assert.Equal(new[] { "coder" }, cfg.Teammates.Select(m => m.Name));
        var ib = """[{"from":"tester","text":"5 個測試全過","summary":"回報","timestamp":"2026-10-08T05:31:13.333Z","color":"green","msgV":1,"msg_id":"5266","type":"message","read":false}]""";
        var m = TeamMessage.DecodeInbox(ib, "team-lead");
        Assert.True(m.Count == 1 && m[0].To == "team-lead" && m[0].Key == "5266");
        Assert.Empty(TeamMessage.DecodeInbox("[]", "x"));
    }

    [Fact] // 摘要去掉 Markdown、空行併成一行
    public void Plain()
    {
        Assert.Equal("ProjectC 檢查報告 commit 有，push 還沒有。 第一點 a b",
                     Board.Plain("# ProjectC 檢查報告\n\n**commit 有**，`push` 還沒有。\n- 第一點\n|a|b|\n|---|---|"));
        Assert.Equal("第一行 第二行", Board.Plain("第一行\r\n\r\n第二行"));     // Windows 換行
    }

    [Fact] // 截字不切壞 emoji
    public void PrefixKeepsEmoji()
    {
        Assert.Equal("ab😀", Board.Prefix("ab😀cd", 3));
        Assert.Equal(5, Board.Length("ab😀cd"));
        Assert.Equal("短", Board.Prefix("短", 40));
    }

    [Fact] // 組看板：無頭 session 不上板、自報與審核掛上、舊審核不放
    public void BuildP2()
    {
        var s1 = new SessionRecord { Pid = 1, SessionId = "A", Cwd = "/h", Status = "idle", UpdatedAt = 2 };
        var head = new SessionRecord { Pid = 2, SessionId = "H", Cwd = "/h", Status = "busy", UpdatedAt = 1, Entrypoint = "sdk-cli" };
        var t = new TranscriptInfo { LastPromptAt = Now.AddSeconds(-100), LastActivity = Now.AddSeconds(-10) };
        var rep = new SelfReport { Status = ReportStatus.Review, Progress = 90, Confidence = 60, Ask = "要 push 嗎", At = Now.AddSeconds(-20) };
        var old = new Review { Progress = 1, Confidence = 1, Verdict = "fail", Turn = Now.AddSeconds(-500), Model = "sonnet" };
        var cards = Board.Build(new[] { s1, head }, new Dictionary<string, TranscriptInfo> { ["A"] = t },
                                new Dictionary<int, WorkState> { [1] = WorkState.Done }, Array.Empty<TeamConfig>(), Array.Empty<TeamMessage>(),
                                Now, "/h", _ => false, reports: new Dictionary<string, SelfReport> { ["A"] = rep },
                                reviews: new Dictionary<string, Review> { ["A"] = old });
        Assert.Equal(new[] { "A" }, cards.Select(c => c.Id));
        Assert.True(cards[0].Column == BoardColumn.Review && cards[0].Reason == "要你決定：要 push 嗎" && cards[0].Report == rep && cards[0].Review == null);
    }

    [Fact] // 專案名：git 根目錄、家目錄、非 repo
    public void Project()
    {
        var repos = new HashSet<string> { "/h/github-repos/ProjectA" };
        Func<string, bool> f = repos.Contains;
        Assert.Equal("ProjectA", Board.ProjectName("/h/github-repos/ProjectA/docs/x", "/h", f));
        Assert.Equal("（家目錄）", Board.ProjectName("/h", "/h", f));
        Assert.Equal("tmp", Board.ProjectName("/h/Desktop/tmp", "/h", f));
        Assert.Equal("（不明）", Board.ProjectName(null, "/h", f));
    }

    [Fact] // Windows：磁碟代號、反斜線、大小寫、結尾斜線、正斜線寫法都認得同一個 repo 與家目錄
    public void ProjectWindows()
    {
        const string home = @"C:\Users\Demo User";
        Func<string, bool> f = p => string.Equals(p, @"C:\Users\Demo User\ShoWork42", StringComparison.OrdinalIgnoreCase);
        Assert.Equal("ShoWork42", Board.ProjectName(@"C:\Users\Demo User\ShoWork42\windows\ShoWork.Win", home, f));
        Assert.Equal("showork42", Board.ProjectName(@"c:\users\demo user\showork42", home, f));          // 島名分組時不分大小寫
        Assert.Equal("ShoWork42", Board.ProjectName("C:/Users/Demo User/ShoWork42/docs", home, f));
        Assert.Equal("（家目錄）", Board.ProjectName(@"C:\Users\Demo User", home, f));
        Assert.Equal("（家目錄）", Board.ProjectName(@"c:\USERS\demo user\", home, f));
        Assert.Equal("Desktop", Board.ProjectName(@"C:\Users\Demo User\Desktop", home, f));
        Assert.Equal("Windows", Board.ProjectName(@"C:\Windows", home, f));
        Assert.Equal(@"C:\", Board.ProjectName(@"C:\", home, f));                                     // 根目錄：照原樣
        Assert.Equal("work", Board.ProjectName(@"D:\work", home, _ => false));
        // 家目錄本身有 .git 也不算專案（同 Mac）
        Assert.Equal("（家目錄）", Board.ProjectName(home, home, _ => true));
        Assert.Equal(@"C:\Users", BoardPath.Parent(@"C:\Users\Demo User\"));
        Assert.Equal(@"C:\", BoardPath.Parent(@"C:\Users"));
        Assert.Null(BoardPath.Parent(@"c:\"));
        Assert.Null(BoardPath.Parent(@"\\nas\share"));
        Assert.Equal(@"\\nas\share", BoardPath.Parent(@"\\nas\share\proj"));
    }

    [Fact] // 組看板：每個 session 一張卡＋排隊訊息成待辦，隊員與訊息掛在隊長卡上
    public void Build()
    {
        var s1 = new SessionRecord { Pid = 1, SessionId = "A", Cwd = "/h", Status = "busy", UpdatedAt = 2 };
        var s2 = new SessionRecord { Pid = 2, SessionId = "B", Cwd = "/h", Status = "idle", UpdatedAt = 1 };
        var t1 = new TranscriptInfo { Title = "做 ProjectA", LastCwd = "/h/r/ProjectA", LastActivity = Now, Queued = new() { "下一件" } };
        var team = new TeamConfig { Name = "session-A", LeadSessionId = "A", Members = new() {
            new TeamMember { AgentId = "team-lead@A", Name = "team-lead", AgentType = "team-lead" },
            new TeamMember { AgentId = "coder@A", Name = "coder", AgentType = "general-purpose" } } };
        var msg = new TeamMessage { From = "coder", Text = "好了", To = "team-lead" };
        var cards = Board.Build(new[] { s2, s1 }, new Dictionary<string, TranscriptInfo> { ["A"] = t1 },
                                new Dictionary<int, WorkState> { [2] = WorkState.Done }, new[] { team }, new[] { msg },
                                Now, "/h", p => p == "/h/r/ProjectA");
        Assert.Equal(new[] { "A", "A#q0", "B" }, cards.Select(c => c.Id));
        Assert.True(cards[0].Column == BoardColumn.Active && cards[0].Project == "ProjectA");
        Assert.Equal(new[] { "coder" }, cards[0].Teammates);
        Assert.Equal(new[] { msg }, cards[0].Messages);
        Assert.True(cards[1].Column == BoardColumn.Todo && cards[1].Title == "下一件");
        Assert.True(cards[2].Column == BoardColumn.Review && cards[2].Project == "（家目錄）");
    }

    [Fact] // 組看板（Windows）：沒有對話紀錄時用 session 的 cwd；標題退回 session 名；只有進行中才帶影分身
    public void BuildWindows()
    {
        const string home = @"C:\Users\Demo User";
        Func<string, bool> repo = p => p.EndsWith(@"\ShoWork42", StringComparison.OrdinalIgnoreCase) || p.EndsWith(@"\ProjectB", StringComparison.OrdinalIgnoreCase);
        var s = new SessionRecord { Pid = 10, SessionId = "W", Cwd = @"C:\Users\Demo User\ShoWork42", Status = "idle", Name = "demouser-w1" };
        var busy = new SessionRecord { Pid = 11, SessionId = "V", Cwd = home, Status = "busy", UpdatedAt = 5 };
        var t0 = DateTime.UnixEpoch.AddSeconds(1_791_000_000);
        var marks = new List<CwdMark>();
        for (int i = 0; i < 120; i++) marks.Add(new CwdMark(@"C:\Users\Demo User\ProjectB\app", t0.AddSeconds(i * 10)));
        for (int i = 0; i < 10; i++) marks.Add(new CwdMark(@"c:\users\demo user\showork42", t0.AddSeconds(1200 + i * 10)));
        var tv = new TranscriptInfo { RecentWorkCwds = marks, LastActivity = Now };
        var idleCopy = new TranscriptInfo { RecentWorkCwds = marks, LastActivity = Now };
        var cards = Board.Build(new[] { s, busy }, new Dictionary<string, TranscriptInfo> { ["V"] = tv },
                                new Dictionary<int, WorkState>(), Array.Empty<TeamConfig>(), Array.Empty<TeamMessage>(), Now, home, repo);
        Assert.Equal(new[] { "V", "W" }, cards.Select(c => c.Id));
        Assert.True(cards[0].Project == "ProjectB" && cards[0].Visiting == "showork42");
        Assert.True(cards[1].Project == "ShoWork42" && cards[1].Title == "demouser-w1" && cards[1].Visiting == null && cards[1].Cwd == s.Cwd);
        var idle = Board.Build(new[] { busy with { Status = "idle" } }, new Dictionary<string, TranscriptInfo> { ["V"] = idleCopy },
                               new Dictionary<int, WorkState>(), Array.Empty<TeamConfig>(), Array.Empty<TeamMessage>(), Now, home, repo);
        Assert.Null(idle[0].Visiting);                                   // 閒著不留幽靈
    }

    [Fact] // --board-dump 的 JSON：欄位名跟 Mac 一樣、中文不跳脫
    public void DumpJson()
    {
        var c = new BoardCard { Id = "A", Column = BoardColumn.Active, Reason = "工作中", Project = "ShoWork42", Title = "戰情中心", SessionId = "A", Pid = 3 };
        var j = System.Text.Json.JsonSerializer.Serialize(c, Board.DumpJson);
        Assert.Contains("\"column\": \"active\"", j);
        Assert.Contains("\"sessionId\": \"A\"", j);
        Assert.Contains("戰情中心", j);
        Assert.DoesNotContain("\"detail\"", j);                         // 沒有值的不印
        Assert.DoesNotContain("isQueued", j);
    }

    [System.Runtime.InteropServices.DllImport("kernel32.dll", CharSet = System.Runtime.InteropServices.CharSet.Unicode)]
    static extern uint GetShortPathName(string longPath, StringBuilder shortPath, uint size);

    [Fact] // 8.3 短路徑開的 Claude：島名用真的資料夾名，不是 SLEEPY~1（10-15 Surface 真 session）
    public void ShortPathProjectName()
    {
        if (!OperatingSystem.IsWindows()) return;
        var dir = Path.Combine(Path.GetTempPath(), "sw42-短路徑-" + Guid.NewGuid().ToString("N")[..6], "SleepyTestFolder");
        Directory.CreateDirectory(dir);
        try
        {
            var sb = new StringBuilder(1024);
            GetShortPathName(dir, sb, 1024);
            var shortDir = sb.ToString();
            if (!shortDir.Contains('~')) return;                           // 這顆磁碟關了 8.3 短檔名：沒得測
            Assert.Equal("SleepyTestFolder", Board.ProjectName(shortDir, @"C:\nowhere", _ => false));
            Assert.True(BoardPath.Same(shortDir, dir));
        }
        finally { Directory.Delete(Path.GetDirectoryName(dir)!, true); }
    }
}
