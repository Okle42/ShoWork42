using System.Diagnostics;
using System.Text;
using ShoWork;
using Xunit;

namespace ShoWork.Tests;

/// 讀檔層：在暫存資料夾假造一份 ~/.claude 與 ShoWork 資料夾，確認讀得到、殘留檔與無頭 session 不上板、而且什麼都沒寫
public class BoardReaderTests : IDisposable
{
    // 不放在 %TEMP%：暫存資料夾本來就被當成「不是做事的地方」，cwd 會被濾掉
    readonly string root = Path.Combine(AppContext.BaseDirectory, "board-test-" + Guid.NewGuid().ToString("N")[..8]);
    string Claude => Path.Combine(root, "claude");
    string Support => Path.Combine(root, "support");
    string Home => Path.Combine(root, "home");

    public void Dispose() { try { Directory.Delete(root, true); } catch { } }

    void Put(string path, string text) { Directory.CreateDirectory(Path.GetDirectoryName(path)!); File.WriteAllText(path, text, new UTF8Encoding(false)); }
    static string J(string s) => System.Text.Json.JsonSerializer.Serialize(s);

    [Fact]
    public void ReadsSessionsTranscriptsGlowsAndTeams()
    {
        var repo = Path.Combine(Home, "ShoWork42");
        Directory.CreateDirectory(Path.Combine(repo, ".git"));
        var live = new SessionRecord { Pid = 101, SessionId = "S1", Cwd = Home };
        Put(Path.Combine(Claude, "sessions", "101.json"), $$"""{"pid":101,"sessionId":"S1","cwd":{{J(Home)}},"status":"busy","updatedAt":5,"name":"k-s1","kind":"interactive"}""");
        Put(Path.Combine(Claude, "sessions", "102.json"), $$"""{"pid":102,"sessionId":"S2","cwd":{{J(Home)}},"status":"idle"}""");          // 行程已結束
        Put(Path.Combine(Claude, "sessions", "103.json"), $$"""{"pid":103,"sessionId":"S3","cwd":{{J(Home)}},"entrypoint":"sdk-cli"}""");   // 無頭
        Put(Path.Combine(Claude, "sessions", "104.json"), $$"""{"pid":104,"sessionId":"S4","cwd":{{J(Home)}},"kind":"background"}""");
        Put(Path.Combine(Claude, "sessions", "bad.json"), "{壞掉");
        var now = DateTime.UtcNow;
        string Ts(int s) => BoardJson.Format(now.AddSeconds(s));
        Put(Path.Combine(Claude, "projects", live.ProjectSlug, "S1.jsonl"), string.Join("\n",
            $$$"""{"type":"user","cwd":{{{J(repo)}}},"timestamp":"{{{Ts(-900)}}}","message":{"content":"修看板"}}""",
            $$"""{"type":"ai-title","aiTitle":"戰情中心 Windows 版"}""",
            $$$"""{"type":"assistant","cwd":{{{J(repo)}}},"timestamp":"{{{Ts(-5)}}}","message":{"content":[{"type":"text","text":"**好了**"}]}}""",
            """{"type":"queue-operation","operation":"enqueue","content":"再加測試"}""") + "\n");
        Put(Path.Combine(Support, "state.json"), """[{"Pid":101,"Created":1,"Agent":"claude","State":"Working"},{"Pid":101,"Created":1,"Agent":"claude","State":"Input"},{"Pid":9,"Created":1,"Agent":"x","State":"Bogus"}]""");
        Put(Path.Combine(Claude, "teams", "session-S1", "config.json"), """{"name":"session-S1","leadSessionId":"S1","members":[{"agentId":"l","name":"team-lead","agentType":"team-lead"},{"agentId":"c","name":"coder"}]}""");
        Put(Path.Combine(Claude, "teams", "session-S1", "inboxes", "team-lead.json"), """[{"from":"coder","text":"好了","msg_id":"m1"}]""");
        Put(Path.Combine(Claude, "cache", "ctx", "S1.json"), """{"used_percentage": 44}""");
        Put(Path.Combine(Support, "board", "captain.json"), """{"sessionId":"S1","at":"2026-10-08T10:16:42Z"}""");

        var before = Snapshot(root);
        var reader = new BoardReader(Claude, Support, Home) { Alive = r => r.Pid != 102 };
        var s = reader.Read();
        Assert.Equal(new[] { "S1", "S3" }, s.Sessions.Select(x => x.SessionId).OrderBy(x => x));     // 無頭的 Build 才濾
        Assert.Equal(WorkState.Input, s.Glows[101]);
        Assert.False(s.Glows.ContainsKey(9));
        Assert.Equal("coder", s.Inbox.Single().From);
        Assert.Equal("S1", s.Captain);
        var cards = reader.Cards(s, now);
        Assert.Equal(new[] { "S1", "S1#q0" }, cards.Select(c => c.Id));
        var c = cards[0];
        Assert.Equal("ShoWork42", c.Project);
        Assert.Equal("戰情中心 Windows 版", c.Title);
        Assert.Equal("好了", c.Detail);
        Assert.Equal(BoardColumn.Review, c.Column);                    // 光暈紅＝等你回答，蓋過 busy
        Assert.Equal(repo, c.Cwd);
        Assert.True(c.Captain && c.Teammates.SequenceEqual(new[] { "coder" }) && c.Ctx?.Percent == 44);
        Assert.Null(s.RateLimits);
        Assert.Equal(before, Snapshot(root));                          // 唯讀：一個檔都沒多、沒改
    }

    [Fact] // 對話紀錄不在 slug 預期的資料夾（路徑太長被截短等）：到各專案資料夾找同名檔
    public void FindsTranscriptElsewhere()
    {
        Put(Path.Combine(Claude, "sessions", "7.json"), $$"""{"pid":7,"sessionId":"S7","cwd":{{J(Home)}},"status":"idle"}""");
        Put(Path.Combine(Claude, "projects", "something-else", "S7.jsonl"), """{"type":"ai-title","aiTitle":"找到了"}""" + "\n");
        var reader = new BoardReader(Claude, Support, Home) { Alive = _ => true };
        Assert.Equal("找到了", reader.Cards(reader.Read(), DateTime.UtcNow).Single().Title);
    }

    [Fact] // 增量讀 cwd：第二次只讀新增的行，沒寫完的半行等下次
    public void IncrementalCwds()
    {
        var repo = Path.Combine(Home, "ProjectB");
        Directory.CreateDirectory(Path.Combine(repo, ".git"));
        var rec = new SessionRecord { Pid = 8, SessionId = "S8", Cwd = Home };
        Put(Path.Combine(Claude, "sessions", "8.json"), $$"""{"pid":8,"sessionId":"S8","cwd":{{J(Home)}},"status":"busy"}""");
        var f = Path.Combine(Claude, "projects", rec.ProjectSlug, "S8.jsonl");
        var t0 = DateTime.UtcNow.AddMinutes(-30);
        var sb = new StringBuilder();
        for (int i = 0; i < 60; i++) sb.Append($$"""{"cwd":{{J(repo)}},"timestamp":"{{BoardJson.Format(t0.AddSeconds(i * 10))}}"}""").Append('\n');
        Put(f, sb.ToString() + """{"cwd":"C:\\half""");
        var reader = new BoardReader(Claude, Support, Home) { Alive = _ => true };
        Assert.Equal(60, reader.Read().Transcripts["S8"].RecentWorkCwds.Count);
        File.AppendAllText(f, "\"}\n");
        Assert.Equal(61, reader.Read().Transcripts["S8"].RecentWorkCwds.Count);
    }

    [Fact] // 真的行程：自己這個 pid 還在；不存在的 pid 不算
    public void ProcessAliveCheck()
    {
        Assert.True(BoardReader.ProcessAlive(new SessionRecord { Pid = Environment.ProcessId, SessionId = "me" }));
        var start = Process.GetCurrentProcess().StartTime.ToUniversalTime();
        var ms = (start - DateTime.UnixEpoch).TotalMilliseconds;
        Assert.True(BoardReader.ProcessAlive(new SessionRecord { Pid = Environment.ProcessId, SessionId = "me", StartedAt = ms + 1000 }));
        Assert.False(BoardReader.ProcessAlive(new SessionRecord { Pid = Environment.ProcessId, SessionId = "me", StartedAt = ms - 3_600_000 }));  // pid 被重用
        Assert.False(BoardReader.ProcessAlive(new SessionRecord { Pid = 0x7FFFFFF0, SessionId = "x" }));
        // System（pid 4）一定在；一般權限查不到它的細節也要算活著（以前 HasExited 丟存取被拒 ⇒ 判成死掉）
        if (OperatingSystem.IsWindows()) Assert.True(BoardReader.ProcessAlive(new SessionRecord { Pid = 4, SessionId = "sys", StartedAt = ms }));
    }

    [Fact]
    public void ProcessAliveAccessDeniedCountsAsAlive()
    {
        var r = new SessionRecord { Pid = 42, SessionId = "x", StartedAt = 1_000_000 };
        // 比自己權限高的行程（以系統管理員開的終端機）：查得到 pid、查不到細節 ⇒ 同 Mac 的 EPERM，當它還在
        Assert.True(BoardReader.ProcessAlive(r, _ => (BoardReader.ProbeResult.Denied, null)));
        Assert.False(BoardReader.ProcessAlive(r, _ => (BoardReader.ProbeResult.Gone, null)));
        Assert.True(BoardReader.ProcessAlive(r, _ => (BoardReader.ProbeResult.Alive, null)));                                     // 開始時間讀不到
        Assert.True(BoardReader.ProcessAlive(r, _ => (BoardReader.ProbeResult.Alive, DateTime.UnixEpoch.AddMilliseconds(1_000_000))));
        Assert.False(BoardReader.ProcessAlive(r, _ => (BoardReader.ProbeResult.Alive, DateTime.UnixEpoch.AddMilliseconds(1_000_000).AddMinutes(5))));  // pid 被重用
    }

    [Fact] // 本機每個還在的行程都要判成活著——一般權限跑時，System、lsass、提權的終端機都查不到細節（以前全部判死）
    public void EveryRunningProcessIsAlive()
    {
        if (!OperatingSystem.IsWindows()) return;
        int denied = 0, checkedN = 0, oldWrong = 0;
        var wrong = new List<string>();
        foreach (var p in Process.GetProcesses())
        {
            using (p)
            {
                var (res, _) = BoardReader.Probe(p.Id);
                if (res == BoardReader.ProbeResult.Denied) denied++;
                bool alive = BoardReader.ProcessAlive(new SessionRecord { Pid = p.Id, SessionId = "p" });
                if (!alive && StillThere(p.Id)) wrong.Add($"{p.Id} {p.ProcessName} {res}");
                if (!OldAlive(p.Id) && StillThere(p.Id)) oldWrong++;                // 對照：舊寫法判錯幾個
                checkedN++;
            }
        }
        // SHOWORK_PROBE_LOG：在一般權限（互動式排程工作）跑的時候把數字寫出來看
        if (Environment.GetEnvironmentVariable("SHOWORK_PROBE_LOG") is { Length: > 0 } log)
            File.WriteAllText(log, $"checked={checkedN} denied={denied} wrong={wrong.Count} old_wrong={oldWrong}\n{string.Join("\n", wrong)}\n");
        Assert.Empty(wrong);
    }

    /// 舊的 ProcessAlive（Process.HasExited，丟例外就當死掉）
    static bool OldAlive(int pid) { try { using var p = Process.GetProcessById(pid); return !p.HasExited; } catch { return false; } }

    static bool StillThere(int pid) { try { using var p = Process.GetProcessById(pid); return !p.HasExited; } catch (ArgumentException) { return false; } catch { return true; } }

    [Fact]
    public void CachesForgetEndedSessions()
    {
        var alive = new HashSet<int> { 201, 202 };
        foreach (var (pid, sid) in new[] { (201, "A"), (202, "B") })
        {
            var rec = new SessionRecord { Pid = pid, SessionId = sid, Cwd = Home };
            Put(Path.Combine(Claude, "sessions", $"{pid}.json"), $$"""{"pid":{{pid}},"sessionId":"{{sid}}","cwd":{{J(Home)}},"status":"idle"}""");
            Put(Path.Combine(Claude, "projects", rec.ProjectSlug, sid + ".jsonl"), $$"""{"type":"ai-title","aiTitle":"{{sid}}","cwd":{{J(Home)}},"timestamp":"2026-10-15T01:00:00Z"}""" + "\n");
        }
        var reader = new BoardReader(Claude, Support, Home) { Alive = r => alive.Contains(r.Pid) };
        reader.Read();
        Assert.Equal(2, reader.CachedSessions);
        alive.Remove(202);                                  // B 結束了
        var s = reader.Read();
        Assert.Equal(new[] { "A" }, s.Sessions.Select(x => x.SessionId));
        Assert.Equal(1, reader.CachedSessions);
        alive.Clear();
        reader.Read();
        Assert.Equal(0, reader.CachedSessions);
    }

    static string Snapshot(string dir) => string.Join("\n", Directory.GetFiles(dir, "*", SearchOption.AllDirectories).OrderBy(x => x)
        .Select(f => $"{f}|{new FileInfo(f).Length}|{File.GetLastWriteTimeUtc(f).Ticks}"));
}
