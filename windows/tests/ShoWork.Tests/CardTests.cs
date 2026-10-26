using ShoWork;
using Xunit;

namespace ShoWork.Tests;

/// Tests/ShoWorkCoreTests/CardTests.swift 中看板會用到的部分（自報、分欄、新鮮度、存檔格式、流量、ctx、隊長旗標）
public class CardTests
{
    static readonly DateTime T0 = DateTime.UnixEpoch.AddSeconds(1_791_440_000);

    [Fact] // showork card 參數解析與錯誤訊息
    public void Parse()
    {
        var (r, err) = SelfReport.Parse(new[] { "--status", "review", "--progress", "80%", "--confidence", "130", "--summary", "做完 A", "--ask", "要 push 嗎" }, T0);
        Assert.Null(err);
        Assert.True(r!.Status == ReportStatus.Review && r.Progress == 80 && r.Confidence == 100 && r.Ask == "要 push 嗎" && r.At == T0);
        Assert.Equal("缺 --status", SelfReport.Parse(new[] { "--progress", "5" }, T0).Error);
        Assert.Equal("--status 只能是 working／review／done／blocked", SelfReport.Parse(new[] { "--status", "ok" }, T0).Error);
        Assert.Equal("--status 後面少了值", SelfReport.Parse(new[] { "--status" }, T0).Error);
        Assert.Equal("不認得的參數 --x", SelfReport.Parse(new[] { "--status", "done", "--x", "1" }, T0).Error);
    }

    [Fact] // 欄位：自報、決定、新鮮度、等你回答優先
    public void Column()
    {
        var idle = (BoardColumn.Review, "做完了，你還沒看");
        var prompt = T0; var later = T0.AddSeconds(60);
        var rev = new SelfReport { Status = ReportStatus.Review, Ask = "選 A 還是 B", At = later };
        Assert.Equal((BoardColumn.Review, "要你決定：選 A 還是 B"), CardRules.Column(idle, WorkState.Done, rev, null, prompt, later));
        var done = new SelfReport { Status = ReportStatus.Done, At = later };
        Assert.Equal(BoardColumn.Done, CardRules.Column(idle, WorkState.Done, done, null, prompt, later).Item1);
        var stale = new SelfReport { Status = ReportStatus.Done, At = T0.AddSeconds(-1) };          // 上一輪的
        Assert.Equal(idle, CardRules.Column(idle, WorkState.Done, stale, null, prompt, later));
        var blocked = new SelfReport { Status = ReportStatus.Blocked, Summary = "缺金鑰", At = later };
        Assert.Equal((BoardColumn.Stuck, "AI 自報卡住：缺金鑰"), CardRules.Column(idle, null, blocked, null, prompt, later));
        Assert.Equal(BoardColumn.Stuck, CardRules.Column((BoardColumn.Active, "工作中"), WorkState.Working, blocked, null, prompt, later).Item1);
        // 放行／丟待辦：決定之後沒有新動靜才有效
        var ok = new Decision { Action = DecisionAction.Approve, At = later.AddSeconds(5) };
        Assert.Equal((BoardColumn.Done, "你已放行"), CardRules.Column(idle, WorkState.Done, rev, ok, prompt, later));
        Assert.Equal(BoardColumn.Review, CardRules.Column(idle, WorkState.Done, rev, ok, prompt, later.AddSeconds(9)).Item1);
        var park = new Decision { Action = DecisionAction.Park, Note = "下週再說", At = later.AddSeconds(5) };
        Assert.Equal((BoardColumn.Todo, "你丟回待辦：下週再說"), CardRules.Column(idle, null, null, park, prompt, later));
        // 等你回答：自報與決定都不能蓋掉
        var input = (BoardColumn.Review, "等你回答");
        Assert.Equal(input, CardRules.Column(input, WorkState.Input, done, ok, prompt, later));
    }

    [Fact] // 要不要審：只在待審、每輪一次；存檔來回保留毫秒；Mac 存的格式讀得懂
    public void NeedsReviewAndJson()
    {
        var r = new Review { Progress = 50, Confidence = 50, Verdict = "pass", Turn = T0, Model = "sonnet" };
        Assert.True(CardRules.NeedsReview(BoardColumn.Review, null, T0));
        Assert.False(CardRules.NeedsReview(BoardColumn.Review, r, T0));
        Assert.True(CardRules.NeedsReview(BoardColumn.Review, r, T0.AddSeconds(2)));
        Assert.False(CardRules.NeedsReview(BoardColumn.Done, null, T0));
        Assert.False(CardRules.NeedsReview(BoardColumn.Review, null, null));
        Assert.False(CardRules.NeedsReview(BoardColumn.Review, r, T0.AddSeconds(0.056)));
        var ms = DateTime.UnixEpoch.AddMilliseconds(1_791_440_000_056);
        var back = BoardJson.Decode<Review>(BoardJson.Encode(new Review { Progress = 1, Confidence = 1, Verdict = "pass", Turn = ms, At = ms, Model = "m" }))!;
        Assert.True(Math.Abs((back.Turn - ms).TotalMilliseconds) < 1);
        Assert.Equal(DecisionAction.Approve, BoardJson.Decode<Decision>("""{"action":"approve","at":"2026-10-08T10:16:42Z"}""")!.Action);
        // Mac `showork card` 寫的自報檔
        var rep = BoardJson.Decode<SelfReport>("""{"status":"blocked","progress":40,"confidence":70,"summary":"缺金鑰","at":"2026-10-08T10:16:42.123Z"}""")!;
        Assert.True(rep.Status == ReportStatus.Blocked && rep.Progress == 40 && rep.At == new DateTime(2026, 10, 8, 10, 16, 42, 123, DateTimeKind.Utc));
        Assert.Null(BoardJson.Decode<SelfReport>("""{"status":"nope","at":"x"}"""));
    }

    [Fact] // 帳號流量快照（statusline 存的格式）
    public void RateLimitsSnapshot()
    {
        var j = """{"rate_limits": {"five_hour": {"used_percentage": 27, "resets_at": 1791457200}, "seven_day": {"used_percentage": 59.5, "resets_at": 1791774000}}, "at": "2026-10-08 18:12:08"}""";
        var r = RateLimits.Parse(j)!;
        Assert.True(r.FiveHour?.Used == 27 && r.SevenDay?.Used == 59.5 && r.SnapshotAt != null);
        var after = r.Current(DateTime.UnixEpoch.AddSeconds(1_791_457_201));
        Assert.True(after.FiveHour?.Used == 0 && after.SevenDay?.Used == 59.5);
        Assert.Null(RateLimits.Parse("""{"rate_limits":{}}"""));
        Assert.Null(RateLimits.Parse("壞掉"));
    }

    [Fact] // ctx 快照解析
    public void Context()
    {
        var c = ContextUse.Parse("""{"used_percentage": 86, "total_input_tokens": 172000, "at": 1791475515.9}""")!;
        Assert.True(c.Percent == 86 && c.Tokens == 172000 && c.At != null);
        Assert.Null(ContextUse.Parse("""{"x":1}"""));
    }

    [Fact] // 隊長旗標與同專案重工（隊長自己、家目錄、排隊卡都不算）
    public void CaptainAnnotate()
    {
        BoardCard C(string id, string project, string? name = null) => new() { Id = id, SessionId = id.Split('#')[0], Project = project, Name = name, Title = "t" };
        var cards = Captain.Annotate(new[] { C("A", "ProjectB", "a-1"), C("B", "projectb", "b-2"), C("K", "ProjectB", "boss"), C("H", "（家目錄）"), C("H2", "（家目錄）"), C("A#q0", "ProjectB") }, "K");
        Assert.Equal(new[] { "b-2" }, cards[0].SameProject);
        Assert.Equal(new[] { "a-1" }, cards[1].SameProject);
        Assert.True(cards[2].Captain && cards[2].SameProject.Count == 0);
        Assert.Empty(cards[3].SameProject);
        Assert.False(cards[0].Captain);
    }
}
