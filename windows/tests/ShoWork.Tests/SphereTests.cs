using System.Text.Json.Nodes;
using ShoWork;
using Xunit;

namespace ShoWork.Tests;

/// 11-21 球體檢視的資料（SpherePayload）：欄位對照 Mac SphereWebHost.payload()／info()。假名、假 session
public sealed class SphereTests
{
    static readonly DateTime Now = new(2026, 11, 21, 4, 0, 0, DateTimeKind.Utc);

    static BoardCard Card(string sid, BoardColumn col, string? name = null, SelfReport? report = null, double agoMin = 5, double? ctx = null, PermitRequest? permit = null) => new()
    {
        Id = sid, SessionId = sid, Project = "DemoProj", Title = "t", Column = col, Reason = "r", Name = name, Report = report,
        LastActivity = Now.AddMinutes(-agoMin), Ctx = ctx is { } c ? new ContextUse { Percent = c } : null, Permit = permit, Detail = "  最後一句  ",
    };

    [Fact]
    public void PayloadFieldsMatchMac()
    {
        var cards = new List<BoardCard>
        {
            Card("sid-a", BoardColumn.Done, "Alex", agoMin: 30, ctx: 40.4),
            Card("sid-b", BoardColumn.Active, "Bella", new SelfReport { Status = ReportStatus.Working, Progress = 60, Doing = "寫測試", Summary = "一半" }, agoMin: 1, ctx: 72.5),
            Card("sid-c", BoardColumn.Review, null, new SelfReport { Status = ReportStatus.Review, Ask = "要用哪個？", Options = new() { "A", "B" } }, agoMin: 10),
            new() { Id = "sid-b#q0", SessionId = "sid-b", Project = "DemoProj", Column = BoardColumn.Todo },
        };
        var limits = new RateLimits { FiveHour = new(27.5, Now.AddMinutes(90)), SevenDay = new(81, Now.AddDays(2)) };
        var runs = new List<RunProgress> { new() { Label = "稽核", Name = "Alex", Fraction = 0.3333, Eta = "4 分", UpdatedAt = Now.AddMinutes(-1) },
                                           new() { Label = "舊的", Fraction = 0.5, UpdatedAt = Now.AddHours(-1) } };
        var o = SpherePayload.Build(cards, limits, runs, null, Now);
        Assert.Equal(3, (int)o["sessions"]!);
        Assert.Equal(28d, (double)o["five_hour"]!);              // Swift .rounded()：27.5 → 28
        Assert.Equal(81d, (double)o["seven_day"]!);
        Assert.Equal(90, (int)o["five_reset"]!);
        Assert.Equal(2880, (int)o["seven_reset"]!);
        Assert.Equal(73d, (double)o["ctx"]!);                    // 最近有動靜的是 Bella
        Assert.Null(o["heat"]);
        Assert.False((bool)o["paused"]!);
        var team = o["team"]!.AsArray();
        Assert.Equal(new[] { "sid-c", "sid-b", "sid-a" }, team.Select(t => (string)t!["sessionId"]!).ToArray());
        Assert.Equal("需要你", (string)team[0]!["status"]!);
        Assert.Equal("DemoProj", (string)team[0]!["name"]!);
        Assert.Equal(new[] { "A", "B" }, team[0]!["options"]!.AsArray().Select(x => (string)x!).ToArray());
        Assert.Equal("進行中", (string)team[1]!["status"]!);
        Assert.Equal(60, (int)team[1]!["progress"]!);
        Assert.Equal("完成", (string)team[2]!["status"]!);
        var rs = o["runs"]!.AsArray();
        Assert.Single(rs);
        Assert.Equal(0.33, (double)rs[0]!["fraction"]!);
        Assert.True(o.ContainsKey("five_hour") && o.ContainsKey("doneToday"));
    }

    [Fact]
    public void NoLimitsGivesNulls()
    {
        var o = SpherePayload.Build(new List<BoardCard>(), null, nowUtc: Now);
        Assert.True(o.ContainsKey("five_hour"));
        Assert.Null(o["five_hour"]);
        Assert.Null(o["seven_reset"]);
        Assert.Null(o["ctx"]);
        Assert.Equal(0, (int)o["sessions"]!);
        // 內容一樣 ⇒ JSON 字串一樣（SphereHost 靠這個不重推）
        Assert.Equal(o.ToJsonString(), SpherePayload.Build(new List<BoardCard>(), null, nowUtc: Now).ToJsonString());
    }

    [Fact]
    public void PermitBecomesAsk()
    {
        var p = new PermitRequest { Id = "p1", SessionId = "sid-p", Tool = "Bash", Summary = "rm -rf build", Detail = "清掉" };
        var o = SpherePayload.Build(new List<BoardCard> { Card("sid-p", BoardColumn.Active, "Alex", permit: p) }, null, nowUtc: Now);
        var t = o["team"]![0]!;
        Assert.Equal("需要你", (string)t["status"]!);
        Assert.Equal("要不要讓它執行 Bash：rm -rf build", (string)t["ask"]!);
        Assert.Equal("tool", (string)t["permit"]!["kind"]!);
        Assert.Equal("p1", (string)t["permit"]!["id"]!);
    }

    [Fact]
    public void InfoAndFind()
    {
        var c = Card("sid-a", BoardColumn.Active, "Alex", new SelfReport { Progress = 10, Doing = "查 bug", Summary = "找到了" }, agoMin: 12, ctx: 33.3);
        var q = new BoardCard { Id = "sid-a#q0", SessionId = "sid-a", Project = "DemoProj" };
        Assert.Same(c, SpherePayload.Find(new[] { q, c }, "sid-a"));
        Assert.Null(SpherePayload.Find(new[] { c }, "nope"));
        var o = SpherePayload.Info(c, Now);
        Assert.Equal("Alex", (string)o["name"]!);
        Assert.Equal("進行中", (string)o["status"]!);
        Assert.Equal("查 bug", (string)o["doing"]!);
        Assert.Equal(12, (int)o["ago"]!);
        Assert.Equal("2026-11-21T03:48:00Z", (string)o["lastActivity"]!);
        Assert.Equal("最後一句", (string)o["detail"]!);
        Assert.Equal(33d, (double)o["ctx"]!);
    }
}
