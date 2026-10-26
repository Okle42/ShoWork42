using System.Text;
using ShoWork;
using Xunit;

namespace ShoWork.Tests;

/// Tests/ShoWorkCoreTests/IslandsTests.swift 的移植（Islands、IslandGrid、StickyProject、影分身）＋ Windows 案例
public class IslandsTests
{
    static BoardCard Card(string id, string project, BoardColumn col, string reason = "", string title = "t", bool captain = false) =>
        new() { Id = id, Column = col, Reason = reason, Project = project, Title = title, Pid = 1, SessionId = id, Captain = captain };

    [Fact] // 欄位對應角色：進行中＝打字、等你回答＝紅、做完沒看＝綠、卡住、閒置
    public void MoodsMatchColumns()
    {
        Assert.Equal(Mood.Working, Moods.Of(Card("a", "P", BoardColumn.Active)));
        Assert.Equal(Mood.Waiting, Moods.Of(Card("a", "P", BoardColumn.Review, reason: "等你回答")));
        Assert.Equal(Mood.Waiting, Moods.Of(Card("a", "P", BoardColumn.Review, reason: "要你決定：要不要 push")));
        Assert.Equal(Mood.Finished, Moods.Of(Card("a", "P", BoardColumn.Review, reason: "做完了，你還沒看")));
        Assert.Equal(Mood.Finished, Moods.Of(Card("a", "P", BoardColumn.Review, reason: "AI 請你看過")));
        Assert.Equal(Mood.Stuck, Moods.Of(Card("a", "P", BoardColumn.Stuck)));
        Assert.Equal(Mood.Idle, Moods.Of(Card("a", "P", BoardColumn.Done)));
        Assert.Equal(Mood.Idle, Moods.Of(Card("a", "P", BoardColumn.Todo)));
        var fresh = Card("a", "P", BoardColumn.Done); fresh.Unused = true;
        Assert.Equal(Mood.Asleep, Moods.Of(fresh));                 // 從來沒用過＝睡覺；做完已讀＝休息（喝咖啡）
    }

    [Fact] // 配件：隊長皇冠優先、秘書專案耳機、研究審核標題眼鏡
    public void Accessories()
    {
        var h = Islands.DefaultHeadsetProjects;
        Assert.Equal(Accessory.Crown, Islands.AccessoryOf(Card("a", "ProjectC", BoardColumn.Active, captain: true), h));
        Assert.Equal(Accessory.Headset, Islands.AccessoryOf(Card("a", "projectc", BoardColumn.Active), h));
        Assert.Equal(Accessory.Glasses, Islands.AccessoryOf(Card("a", "ProjectA", BoardColumn.Active, title: "給排水法規研究"), h));
        Assert.Equal(Accessory.Glasses, Islands.AccessoryOf(Card("a", "ProjectA", BoardColumn.Active, title: "Code Review 第二輪"), h));
        Assert.Null(Islands.AccessoryOf(Card("a", "ProjectA", BoardColumn.Active, title: "接電路"), h));
    }

    [Fact] // 分組：排隊訊息只算數不畫人、要你處理的島和人排前面
    public void Build()
    {
        var isl = Islands.Build(new[]
        {
            Card("1", "Idle", BoardColumn.Done),
            Card("2", "Busy", BoardColumn.Active),
            Card("3", "Ask", BoardColumn.Active),
            Card("4", "Ask", BoardColumn.Review, reason: "等你回答"),
            Card("3#q0", "Ask", BoardColumn.Todo),
            Card("5", "Busy", BoardColumn.Done),
        });
        Assert.Equal(new[] { "Ask", "Busy", "Idle" }, isl.Select(i => i.Project));
        Assert.Equal(new[] { "4", "3" }, isl[0].People.Select(p => p.Id));
        Assert.True(isl[0].Queued == 1 && isl[0].NeedsYou == 1);
        Assert.True(isl[1].Count(Mood.Working) == 1 && isl[1].Count(Mood.Idle) == 1);
    }

    [Fact] // 只有排隊卡的島也要出現（只算數）；沒人也沒排隊就不畫
    public void QueuedOnlyIsland()
    {
        var isl = Islands.Build(new[] { Card("9#q0", "Later", BoardColumn.Todo), Card("1", "Idle", BoardColumn.Done) });
        Assert.Equal(new[] { "Later", "Idle" }, isl.Select(i => i.Project));
        Assert.True(isl[0].People.Count == 0 && isl[0].Queued == 1);
    }

    [Fact] // Windows：同一個 repo 大小寫不同（C:\ 與 Git Bash 的 c:\）算同一座島，島名用第一次看到的寫法
    public void CaseInsensitiveIslands()
    {
        var isl = Islands.Build(new[] { Card("1", "ShoWork42", BoardColumn.Active), Card("2", "showork42", BoardColumn.Done), Card("2#q0", "SHOWORK42", BoardColumn.Todo) });
        Assert.Single(isl);
        Assert.True(isl[0].Project == "ShoWork42" && isl[0].People.Count == 2 && isl[0].Queued == 1);
    }

    [Fact] // 一樣大、塞滿：寬視窗排橫的、高視窗排直的、太小就可捲
    public void GridFit()
    {
        var one = IslandGrid.Fit(1, 1000, 600);
        Assert.True(one.Cols == 1 && one.Width == 1000 && one.Height == 600);
        var wide = IslandGrid.Fit(4, 1600, 500);
        Assert.True(wide.Cols >= 2);
        Assert.Equal(1600, wide.Cols * wide.Width + (wide.Cols - 1) * 12, 6);
        var tall = IslandGrid.Fit(4, 700, 1000);
        Assert.True(tall.Cols == 1 && tall.Rows == 4);
        var five = IslandGrid.Fit(5, 1200, 900);
        Assert.True(five.Cols * five.Rows >= 5 && (five.Rows - 1) * five.Cols < 5);
        var tiny = IslandGrid.Fit(9, 600, 400);
        Assert.Equal(170, tiny.Height);                                   // 不壓扁，改捲動
        var narrow = IslandGrid.Fit(8, 518, 900);
        Assert.True(narrow.Cols == 1 && narrow.Width == 518);             // 兩欄只剩 253 寬 ⇒ 排一欄往下捲
        var zero = IslandGrid.Fit(0, 800, 600);
        Assert.True(zero.Cols == 1 && zero.Rows == 1);                   // 沒有卡：當一張排
    }

    // MARK: StickyProject（住哪）

    const string Home = "/Users/k";
    static bool Repo(string p) => p is "/Users/k/repos/ProjectB" or "/Users/k/repos/ShoWork42";
    /// 依序在每個地方待幾秒（每 10 秒一筆）
    static List<CwdMark> Marks(params (string Cwd, int Secs)[] stays)
    {
        var t = DateTime.UnixEpoch; var out_ = new List<CwdMark>();
        foreach (var (c, secs) in stays) for (int i = 0; i < Math.Max(1, secs / 10); i++) { out_.Add(new CwdMark(c, t)); t = t.AddSeconds(10); }
        return out_;
    }
    static (string, string?) W(params (string, int)[] stays) => Board.Whereabouts(Marks(stays), null, Home, Repo);
    const string Ride = "/Users/k/repos/ProjectB/app", Show = "/Users/k/repos/ShoWork42";

    [Fact] // cd 出去一下不搬家、待滿 5 分鐘才搬、子資料夾算同一個專案
    public void Sticky()
    {
        Assert.Equal(("ProjectB", "（家目錄）"), W((Ride, 1200), (Home, 70)));          // 回家目錄 70 秒
        Assert.Equal(("ProjectB", "ShoWork42"), W((Ride, 1200), (Show, 200)));         // 去別的 repo 逛 200 秒（很多筆也不算）
        Assert.Equal(("ProjectB", (string?)null), W((Ride, 1200), (Show, 200), (Ride, 30)));   // 回來了
        Assert.Equal(("ShoWork42", (string?)null), W((Ride, 1200), (Show, 320)));    // 待滿 5 分鐘＝搬家
        Assert.Equal(("ShoWork42", "（家目錄）"), W((Ride, 1200), (Show, 900), (Home, 60)));
        Assert.Equal(("（家目錄）", (string?)null), W((Home, 30)));                   // 只待過家目錄
        Assert.Equal("ProjectB", W((Home, 100), (Ride, 20)).Item1);                      // 剛 cd 進專案：家目錄不搶
        Assert.Equal("ProjectB", Board.StickyProject(new List<CwdMark>(), "/Users/k/repos/ProjectB", Home, Repo));
    }

    [Fact] // 沒有時間戳：一筆當 15 秒（20 筆＝300 秒就算住下）
    public void StickyWithoutTimestamps()
    {
        var m = Enumerable.Repeat(new CwdMark(Ride, null), 30).Concat(Enumerable.Repeat(new CwdMark(Show, null), 5)).ToList();
        Assert.Equal(("ProjectB", "ShoWork42"), Board.Whereabouts(m, null, Home, Repo));
        var m2 = Enumerable.Repeat(new CwdMark(Ride, null), 30).Concat(Enumerable.Repeat(new CwdMark(Show, null), 20)).ToList();
        Assert.Equal(("ShoWork42", (string?)null), Board.Whereabouts(m2, null, Home, Repo));
    }

    [Fact] // Windows：同一個 repo 寫法不同（大小寫、正反斜線）是同一段，不會被當成「逛」
    public void StickyWindows()
    {
        const string home = @"C:\Users\Demo User";
        Func<string, bool> repo = p => p.Equals(@"C:\Users\Demo User\ProjectB", StringComparison.OrdinalIgnoreCase)
                                       || p.Equals(@"C:\Users\Demo User\ShoWork42", StringComparison.OrdinalIgnoreCase);
        var t = DateTime.UnixEpoch; var m = new List<CwdMark>();
        void Stay(string c, int secs) { for (int i = 0; i < secs / 10; i++) { m.Add(new CwdMark(c, t)); t = t.AddSeconds(10); } }
        Stay(@"C:\Users\Demo User\ProjectB\app", 600);
        Stay(@"c:\users\demo user\projectb", 100);
        Stay("C:/Users/Demo User/ProjectB/docs", 100);
        Assert.Equal(("ProjectB", (string?)null), Board.Whereabouts(m, null, home, repo));
        Stay(@"C:\Users\Demo User", 60);                                    // 回家目錄一下
        Assert.Equal(("ProjectB", "（家目錄）"), Board.Whereabouts(m, null, home, repo));
        Stay(@"C:\Users\Demo User\ShoWork42\windows", 400);                 // 搬家
        Assert.Equal(("ShoWork42", (string?)null), Board.Whereabouts(m, null, home, repo));
    }

    [Fact] // 抽 cwd＋時間：只認最外層、字串裡跳脫的不算、略過 ~/.claude
    public void Cwds()
    {
        var lines = string.Join("\n",
            """{"type":"user","cwd":"/Users/k/repos/ProjectB","timestamp":"2026-10-13T05:00:00.000Z","message":{"content":"{\"cwd\":\"/fake\"}"}}""",
            """{"type":"attachment","cwd":"/Users/k/.claude/projects/x/memory"}""",
            """{"type":"assistant","cwd":"/Users/k/中文 專案"}""");
        var m = TranscriptInfo.WorkCwds(Encoding.UTF8.GetBytes(lines));
        Assert.Equal(new[] { "/Users/k/repos/ProjectB", "/Users/k/中文 專案" }, m.Select(x => x.Cwd));
        Assert.True(m[0].At != null && m[1].At == null);
    }

    [Fact] // Windows：cwd 裡的反斜線是跳脫過的，要解開；跳脫的引號不會讓值提早結束；最後一行沒寫完不算
    public void CwdsWindows()
    {
        var lines = string.Join("\r\n",
            """{"type":"user","message":{"content":"看 {\"cwd\":\"C:\\\\fake\"}"},"cwd":"C:\\Users\\Demo User\\ShoWork42","timestamp":"2026-10-14T08:18:39.568Z"}""",
            """{"type":"x","cwd":"C:\\Users\\Demo User\\.claude\\skills","timestamp":"2026-10-14T08:18:40.000Z"}""",
            """{"type":"x","cwd":"D:\\案子\\a \"b\"","timestamp":"2026-10-14T08:18:41.000Z"}""",
            """{"type":"x","cwd":"C:\\Users\\An K""");
        var m = TranscriptInfo.WorkCwds(Encoding.UTF8.GetBytes(lines));
        Assert.Equal(new[] { @"C:\Users\Demo User\ShoWork42", "D:\\案子\\a \"b\"" }, m.Select(x => x.Cwd));
        Assert.Equal(new DateTime(2026, 10, 14, 8, 18, 39, 568, DateTimeKind.Utc), m[0].At);
    }

    [Fact] // 影分身只出現在已經有的島上，本尊留在家
    public void Ghosts()
    {
        var a = Card("a", "ProjectB", BoardColumn.Active); a.Visiting = "ShoWork42";
        var b = Card("b", "ShoWork42", BoardColumn.Active);
        var c = Card("c", "ProjectB", BoardColumn.Active); c.Visiting = "Nowhere";
        var isl = Islands.Build(new[] { a, b, c });
        Assert.Equal(2, isl.Count);
        Assert.Equal(new[] { "a" }, isl.First(i => i.Project == "ShoWork42").Ghosts.Select(g => g.Id));
        Assert.Equal(new[] { "a", "c" }, isl.First(i => i.Project == "ProjectB").People.Select(p => p.Id));
        Assert.Empty(isl.First(i => i.Project == "ProjectB").Ghosts);
    }

    [Fact] // Windows：影分身去的島大小寫不同也找得到
    public void GhostsCaseInsensitive()
    {
        var a = Card("a", "ProjectB", BoardColumn.Active); a.Visiting = "showork42";
        var b = Card("b", "ShoWork42", BoardColumn.Done);
        var isl = Islands.Build(new[] { a, b });
        Assert.Equal(new[] { "a" }, isl.First(i => i.Project == "ShoWork42").Ghosts.Select(g => g.Id));
    }
}
