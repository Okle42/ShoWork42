using ShoWork;
using Xunit;

namespace ShoWork.Tests;

/// 戰情中心畫面的尺寸規則（Mac IslandView.swift 的 IslandGeometry／BubbleFit／bubbleLine）與示範卡片
public class IslandLayoutTests
{
    static Islander P(string id, Mood m = Mood.Working) =>
        new(new BoardCard { Id = id, SessionId = id, Project = "P", Title = id, Column = BoardColumn.Active }, m, null);

    [Fact] // 座位排成 side×side：1 人 1×1、2–4 人 2×2、5–9 人 3×3；島的半寬跟著長
    public void GeometrySides()
    {
        Assert.Equal(1, new IslandGeometry(0).Side);
        Assert.Equal(1, new IslandGeometry(1).Side);
        Assert.Equal(2, new IslandGeometry(4).Side);
        Assert.Equal(3, new IslandGeometry(5).Side);
        Assert.Equal(80, new IslandGeometry(1).HalfW);
        Assert.Equal(80 + 58 * 2, new IslandGeometry(9).HalfW);
        var g = new IslandGeometry(1);
        Assert.Equal((172.0, 62 + 80 + 14 + 6.0), g.Size);
        Assert.Equal(g.Center, g.Spot(0));          // 一個人就坐正中間
    }

    [Fact] // 由後往前：第 0 個在最上面（y 最小），最後一個在最前面
    public void SpotsBackToFront()
    {
        var g = new IslandGeometry(4);
        Assert.True(g.Spot(0).Y < g.Spot(1).Y && g.Spot(0).Y < g.Spot(2).Y);
        Assert.True(g.Spot(3).Y > g.Spot(1).Y && g.Spot(3).Y > g.Spot(2).Y);
        Assert.Equal(g.Spot(1).Y, g.Spot(2).Y);     // 左右同一排
        Assert.Equal(g.Center.X, g.Spot(0).X);
    }

    [Fact] // 放得下就平分高度；放不下留一格寫「還有 N 個」，最急的排前面不被收掉
    public void BubbleFitSplitsOrCollapses()
    {
        var two = new BubbleFit(new[] { P("a"), P("b") }, 300);
        Assert.Equal(2, two.Slots);
        Assert.Empty(two.Hidden);
        Assert.Equal((300 - 10 - 8) / 2.0, two.Height);

        var five = Enumerable.Range(0, 5).Select(i => P($"p{i}")).ToList();
        var f = new BubbleFit(five, 140);           // (130+8)/(36+8)=3 格
        Assert.Equal(3, f.Slots);
        Assert.Equal(new[] { "p0", "p1" }, f.Visible.Select(x => x.Id));
        Assert.Equal(3, f.Hidden.Count);
        Assert.True(f.Height >= BubbleFit.MinHeight);

        var tiny = new BubbleFit(five, 30);         // 一格都塞不下也至少顯示一個
        Assert.Single(tiny.Visible);
        Assert.Equal(BubbleFit.MinHeight, tiny.Height);
        Assert.True(BubbleFit.Compact(40));
        Assert.False(BubbleFit.Compact(74));
    }

    [Fact] // 卡片：島佔 42% 寬、靠上；對話框欄在右邊不超出卡片；字的倍率 1–1.6
    public void CardLayout()
    {
        var isl = new Island { Project = "P", People = new() { P("a"), P("b") } };
        var L = IslandCardLayout.Of(isl, 400, 300);
        Assert.Equal(IslandCardLayout.Pad + IslandCardLayout.HeaderH + 4, L.IslandY);
        Assert.True(L.IslandX >= IslandCardLayout.Pad - 1e-9);
        Assert.True(L.BubbleX > IslandCardLayout.Pad + (400 - 20) * 0.42);
        Assert.True(L.BubbleX + L.BubbleW <= 400 - IslandCardLayout.Pad + 0.01);
        Assert.InRange(L.TextScale, 1, 1.6);
        var big = IslandCardLayout.Of(isl, 1400, 900);
        Assert.Equal(1.6, big.TextScale);
        // 超過 16 人只畫 16 個
        var crowd = new Island { Project = "P", People = Enumerable.Range(0, 20).Select(i => P($"x{i}")).ToList() };
        Assert.Equal(4, IslandCardLayout.Of(crowd, 600, 400).Geo.Side);
    }

    [Fact] // 一句話：要你決定 ＞ 自報摘要 ＞ 最後一句話 ＞ 理由
    public void BubbleLinePriority()
    {
        var c = new BoardCard { Reason = "閒置", Detail = "最後一句" };
        Assert.Equal("最後一句", BubbleText.Line(c));
        c.Report = new SelfReport { Summary = "摘要" };
        Assert.Equal("摘要", BubbleText.Line(c));
        c.Report = new SelfReport { Summary = "摘要", Ask = "要不要 push" };
        Assert.Equal("要你決定：要不要 push", BubbleText.Line(c));
        Assert.Equal("閒置", BubbleText.Line(new BoardCard { Reason = "閒置" }));
        // 數字：自報優先，沒有用審核的
        var r = new BoardCard { Review = new Review { Progress = 40, Confidence = 50 } };
        Assert.Equal(40, BubbleText.Progress(r));
        r.Report = new SelfReport { Progress = 90 };
        Assert.Equal(90, BubbleText.Progress(r));
        Assert.Equal(50, BubbleText.Confidence(r));
    }

    [Fact] // 流量表剩餘時間的寫法同 Mac
    public void LeftFormat()
    {
        Assert.Equal("49 分", BubbleText.Left(TimeSpan.FromMinutes(49.9)));
        Assert.Equal("3:05", BubbleText.Left(TimeSpan.FromMinutes(185)));
        Assert.Equal("2天5時", BubbleText.Left(TimeSpan.FromHours(53.2)));
    }

    [Fact] // 三角波、雜湊：跟 Mac 同一個專案同一個島色（Swift 的 &* 31 &+ 溢位繞回）
    public void Math_()
    {
        Assert.Equal(0, KuboMath.Wave(0, 1));
        Assert.Equal(1, KuboMath.Wave(0.5, 1), 6);
        Assert.Equal(0.5, KuboMath.Wave(0.25, 1), 6);
        Assert.Equal(KuboMath.Wave(0.1, 1), KuboMath.Wave(-0.9, 1), 6);
        Assert.Equal((uint)(7 * 31 + 'A'), KuboMath.Hash("A", 7));
        // 中文字算一個 unicode scalar
        Assert.Equal(unchecked((uint)(7 * 31 + 0x5BB6)), KuboMath.Hash("家", 7));
        Assert.InRange(KuboMath.IslandColorIndex("ShoWork42"), 0, KuboMath.PaletteCount - 1);
        Assert.Equal(KuboMath.IslandColorIndex("ProjectA"), KuboMath.IslandColorIndex("ProjectA"));
        // 影分身 9 秒一圈
        Assert.Equal(KuboMath.GhostAngle("x", 1) + 2 * Math.PI, KuboMath.GhostAngle("x", 10), 6);
        // 打字週期 0.5 秒＝8 fps 剛好 4 格
        Assert.Equal(4, KuboMath.TypingPeriod * KuboMath.Fps);
    }

    [Fact] // 示範卡片：至少 3 座島、五種狀態、隊長、耳機、眼鏡、影分身、一座擠滿 5 人
    public void DemoCoversEverything()
    {
        var islands = Islands.Build(BoardDemo.Cards(new DateTime(2026, 10, 15, 0, 0, 0, DateTimeKind.Utc)));
        Assert.True(islands.Count >= 3);
        var all = islands.SelectMany(i => i.People).ToList();
        foreach (var m in Enum.GetValues<Mood>()) Assert.Contains(all, p => p.Mood == m);
        Assert.Contains(all, p => p.Accessory == Accessory.Crown);
        Assert.Contains(all, p => p.Accessory == Accessory.Headset);
        Assert.Contains(all, p => p.Accessory == Accessory.Glasses);
        Assert.Contains(islands, i => i.Ghosts.Count > 0);
        Assert.Contains(islands, i => i.People.Count >= 5);
        Assert.Contains(islands, i => i.Count(Mood.Waiting) > 0);
        Assert.NotNull(BoardDemo.Limits(DateTime.UtcNow).SevenDay);
    }
}

public class GridPixelsTests
{
    [Fact] // 審查 10-15：150% DPI、捲動區 613px 高、3 座島（2 排×198.35）⇒ 以前第 2 排 y=316、h=298，底邊 614 超出 1px
    public void ExactFitNeverOverflows()
    {
        var (cells, scroll, content) = GridPixels.Place(3, 1182, 613, 26, 1.5);
        Assert.False(scroll);
        Assert.Equal(0, content);
        Assert.All(cells, c => Assert.True(c.X + c.W <= 1182 && c.Y + c.H <= 613, $"{c}"));
        Assert.InRange(cells.Max(c => c.Y + c.H), 612, 613);                                      // 塞滿，最多差 1px（Floor）
    }

    [Fact] // 各種大小、DPI、張數：不捲時不超出；要捲時寬度扣掉捲軸、不會冒橫捲軸
    public void SweepStaysInside()
    {
        foreach (var s in new[] { 1.0, 1.25, 1.5, 1.75, 2.0 })
            for (int n = 1; n <= 9; n++)
                for (int w = 300; w <= 2400; w += 37)
                    for (int h = 200; h <= 1400; h += 41)
                    {
                        int sb = (int)Math.Round(17 * s);
                        var (cells, scroll, content) = GridPixels.Place(n, w, h, sb, s);
                        int availW = scroll ? w - sb : w;
                        foreach (var c in cells)
                        {
                            Assert.True(c.X >= 0 && c.X + c.W <= availW, $"s={s} n={n} {w}x{h} {c}");
                            if (!scroll) Assert.True(c.Y + c.H <= h, $"s={s} n={n} {w}x{h} {c}");
                        }
                        if (scroll) Assert.True(content > h);
                    }
    }
}
