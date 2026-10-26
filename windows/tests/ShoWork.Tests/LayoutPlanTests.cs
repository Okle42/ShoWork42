using System.Drawing;
using ShoWork;
using Xunit;

namespace ShoWork.Tests;

/// Port of Tests/ShoWorkCoreTests/LayoutPlanTests.swift: same areas, same thresholds, same expectations.
public class LayoutPlanTests
{
    // Kang's Mac screen: 1920×1080, menu bar 30, Dock ≈ 80 → visible 1920×970 at y=30
    static readonly Rectangle Area = new(0, 30, 1920, 970);

    static Rectangle Inset(Rectangle r, int d) => Rectangle.FromLTRB(r.Left + d, r.Top + d, r.Right - d, r.Bottom - d);

    public static IEnumerable<object[]> Range(int lo, int hi) => Enumerable.Range(lo, hi - lo + 1).Select(n => new object[] { n });
    public static IEnumerable<object[]> OneTo14 => Range(1, 14);
    public static IEnumerable<object[]> OneTo5 => Range(1, 5);
    public static IEnumerable<object[]> SixTo11 => Range(6, 11);
    public static IEnumerable<object[]> NineTo11 => Range(9, 11);

    [Theory, MemberData(nameof(OneTo14))]
    public void EveryFrameStaysInsideTheVisibleArea(int n)
    {
        var f = LayoutPlan.Frames(n, Area);
        Assert.Equal(n, f.Count);
        foreach (var r in f) Assert.True(Inset(Area, -1).Contains(r), $"n={n} {r}");
    }

    [Theory, MemberData(nameof(OneTo5))]
    public void OneToFiveWindowsNeverOverlap(int n)
    {
        foreach (var style in new[] { LayoutPlan.FourStyle.Columns, LayoutPlan.FourStyle.Grid })
        {
            var f = LayoutPlan.Frames(n, Area, style);
            for (int i = 0; i < f.Count; i++)
                for (int j = i + 1; j < f.Count; j++)
                {
                    var x = Rectangle.Intersect(f[i], f[j]);
                    Assert.True(x.Width < 1 || x.Height < 1, $"n={n} {i}×{j}");
                }
        }
    }

    [Theory, MemberData(nameof(OneTo5))]
    public void OneToFiveWindowsFillTheArea(int n)
    {
        var f = LayoutPlan.Frames(n, Area);
        double total = f.Sum(r => (double)r.Width * r.Height), area = (double)Area.Width * Area.Height;
        Assert.True(Math.Abs(total - area) / area < 0.01, $"n={n}");
    }

    [Fact]
    public void FourWindowsColumnsVsTwoByTwo()
    {
        var c = LayoutPlan.Frames(4, Area, LayoutPlan.FourStyle.Columns);
        Assert.Equal(new[] { 480 }, c.Select(r => r.Width).Distinct());
        Assert.Equal(new[] { 970 }, c.Select(r => r.Height).Distinct());
        var g = LayoutPlan.Frames(4, Area, LayoutPlan.FourStyle.Grid);
        Assert.Equal(new[] { 960 }, g.Select(r => r.Width).Distinct());
        Assert.Equal(new[] { 485 }, g.Select(r => r.Height).Distinct());
    }

    [Fact]
    public void ThreeWindowsEqualThirdsFullHeight()
    {
        var f = LayoutPlan.Frames(3, Area);
        Assert.Equal(new[] { 640, 640, 640 }, f.Select(r => r.Width));
        Assert.All(f, r => Assert.True(r.Height == 970 && r.Top == 30));
    }

    /// Largest square (side) inside frame i that no OTHER frame touches — sampled on an 8 px grid.
    static double ExclusiveSquare(int i, List<Rectangle> f)
    {
        var r = f[i];
        const double step = 8;
        int cols = (int)(r.Width / step), rows = (int)(r.Height / step);
        if (cols <= 0 || rows <= 0) return 0;
        var best = new int[rows + 1, cols + 1];
        int side = 0;
        for (int y = 0; y < rows; y++)
            for (int x = 0; x < cols; x++)
            {
                double px = r.Left + (x + 0.5) * step, py = r.Top + (y + 0.5) * step;
                bool free = !f.Where((_, k) => k != i).Any(o => px >= o.Left && px < o.Right && py >= o.Top && py < o.Bottom);
                best[y + 1, x + 1] = free ? Math.Min(best[y, x], Math.Min(best[y + 1, x], best[y, x + 1])) + 1 : 0;
                side = Math.Max(side, best[y + 1, x + 1]);
            }
        return side * step;
    }

    [Theory, InlineData(1), InlineData(2), InlineData(3), InlineData(4), InlineData(5), InlineData(8)]
    public void EveryWindowKeepsAnExclusiveSquareInAnyStacking(int n)
    {
        var f = LayoutPlan.Frames(n, Area);
        for (int i = 0; i < f.Count; i++) Assert.True(ExclusiveSquare(i, f) >= 112, $"n={n} window {i}");
    }

    /// Visible band height of window i when windows are stacked by row (later rows on top).
    static int VisibleBand(int i, List<Rectangle> f, int[] rows)
    {
        var r = f[i];
        var covering = f.Where((o, k) => k != i && rows[k] > rows[i] && o.IntersectsWith(r)).Select(o => o.Top).DefaultIfEmpty(r.Bottom).Min();
        return covering - r.Top;
    }

    [Theory, InlineData(6), InlineData(7), InlineData(9), InlineData(10), InlineData(11)]
    public void CanonicalStackingShowsEveryWindow(int n)
    {
        var f = LayoutPlan.Frames(n, Area);
        var rows = LayoutPlan.Rows(n);
        for (int i = 0; i < f.Count; i++) Assert.True(VisibleBand(i, f, rows) >= 110, $"n={n} window {i} shows {VisibleBand(i, f, rows)}");
    }

    [Theory, InlineData(6), InlineData(7)]
    public void BrickLayoutQuarterWidthRows120Apart(int n)
    {
        var f = LayoutPlan.Frames(n, Area);
        Assert.All(f, r => Assert.True(r.Width == 480 && r.Height == Area.Height - 240));
        Assert.Equal(new[] { 30, 150, 270 }, f.Select(r => r.Top).Distinct().OrderBy(y => y));
        Assert.Equal(new[] { 0, 960 }, f.Where(r => r.Top == 30).Select(r => r.Left));
        Assert.Equal(new[] { 480, 1440 }, f.Where(r => r.Top == 270).Select(r => r.Left));
        Assert.Equal(n - 4, f.Count(r => r.Top == 150));
    }

    [Theory, MemberData(nameof(SixTo11))]
    public void OverlappingWindowsAllHaveTheSameHeight(int n) =>
        Assert.Single(LayoutPlan.Frames(n, Area).Select(r => r.Height).Distinct());

    [Theory, MemberData(nameof(NineTo11))]
    public void NineToElevenStaggerFourThreeFour(int n)
    {
        var f = LayoutPlan.Frames(n, Area);
        Assert.All(f, r => Assert.Equal(480, r.Width));
        Assert.True(f[4].Left == 240 && f[4].Top > f[0].Top);
    }

    // Other screens (visible frame): 13" MacBook Air, 14" MacBook Pro, 1440p monitor, 27" 5K, a TV at 1080p
    // with the Dock hidden — plus two Windows work areas in physical pixels: a 150 % 3:2 laptop and 1080p at 100 %.
    public static IEnumerable<object[]> OtherScreens => new[]
    {
        new Rectangle(0, 33, 1470, 830),
        new Rectangle(0, 38, 1512, 862),
        new Rectangle(0, 25, 2560, 1330),
        new Rectangle(0, 25, 2560, 1350),
        new Rectangle(1920, 0, 1920, 1080),
        new Rectangle(0, 0, 2256, 1432),
        new Rectangle(-1920, 0, 1920, 1032),
    }.Select(r => new object[] { r });

    [Theory, MemberData(nameof(OtherScreens))]
    public void OtherScreensInsideClickableAndBanded(Rectangle a)
    {
        for (int n = 1; n <= 14; n++)
        {
            var f = LayoutPlan.Frames(n, a);
            Assert.Equal(n, f.Count);
            foreach (var r in f) Assert.True(Inset(a, -1).Contains(r), $"{a} n={n} {r}");
            if (new[] { 1, 2, 3, 4, 5, 8 }.Contains(n))
                for (int i = 0; i < f.Count; i++) Assert.True(ExclusiveSquare(i, f) >= 112, $"{a} n={n} window {i}");
            else if (n <= 11)
            {
                var rows = LayoutPlan.Rows(n);
                for (int i = 0; i < f.Count; i++) Assert.True(VisibleBand(i, f, rows) >= 110, $"{a} n={n} window {i}");
            }
        }
    }

    [Fact]
    public void TallerScreensKeepTheProportions()
    {
        var big = new Rectangle(0, 25, 2560, 1330);
        var f = LayoutPlan.Frames(8, big);
        Assert.True(Math.Abs((double)(big.Height - f[0].Height) / big.Height - 300.0 / 1000) < 0.01);
        Assert.Equal(Area.Height - 300, LayoutPlan.Frames(8, Area)[0].Height);
    }

    // Windows-only additions

    [Fact]
    public void RoundingMatchesSwift()
    {
        // 1470/4 = 367.5: CGRect.integral floors the origin and ceils the far edge
        var f = LayoutPlan.Frames(4, new Rectangle(0, 33, 1470, 830));
        Assert.Equal(new[] { 0, 367, 735, 1102 }, f.Select(r => r.Left));
        Assert.Equal(new[] { 368, 368, 368, 368 }, f.Select(r => r.Width));
        // 120 × 1.0325 = 123.9 → 124; 300 × 1.35 = 405 (a .5 would round away from zero, not to even)
        Assert.Equal(1032 - 248, LayoutPlan.Frames(6, new Rectangle(0, 0, 1920, 1032))[0].Height);
        Assert.Equal(1350 - 405, LayoutPlan.Frames(8, new Rectangle(0, 0, 2560, 1350))[0].Height);
    }

    [Fact]
    public void TwelvePlusCascadeScalesWithDpi()
    {
        var a = new Rectangle(0, 0, 2256, 1432);
        var f1 = LayoutPlan.Frames(12, a);
        var f15 = LayoutPlan.Frames(12, a, pt: 1.5);
        Assert.Equal(f1[4].Left + 28, f1[11].Left);
        Assert.Equal(f15[4].Left + 42, f15[11].Left);
        Assert.Equal(f1.Take(11), f15.Take(11));
    }

    [Fact]
    public void RowsMatchFrames()
    {
        for (int n = 0; n <= 14; n++) Assert.Equal(Math.Max(0, n), LayoutPlan.Rows(n).Length);
        Assert.Empty(LayoutPlan.Frames(0, Area));
        Assert.Empty(LayoutPlan.Frames(3, Rectangle.Empty));
    }
}
