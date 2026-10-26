using System.Drawing;

namespace ShoWork;

/// Pure window-layout geometry, a line-by-line port of the Mac LayoutPlan (ShoWorkCore/LayoutPlan.swift).
/// Works in physical pixels (top-left origin, like the Mac's AX points); no windows are touched here.
/// Rounding matches Swift exactly: `integral` (floor the origin, ceil the far edge) and `rounded()` (half away from zero).
public static class LayoutPlan
{
    public enum FourStyle { Columns, Grid }

    /// Kang 09-26 (decision boards): from 6 windows up windows overlap. All overlapping windows are the SAME
    /// height = area − rowReveal (each row of the 2-row layout reveals 300); with 3 rows the rows spread evenly.
    public const double RowReveal = 300;

    /// RowReveal / BrickStep were tuned on a 1080p-class screen (visible height 960–970). Taller areas scale them up
    /// so the layout keeps its proportions; 1080p-class and smaller keep the tuned values (every window keeps a band).
    /// On Windows the area is in physical pixels, so a 150 % laptop (1432 px tall) scales like a 1440p Mac screen.
    public const double ReferenceHeight = 1000;
    static double Scale(Rectangle a) => Math.Max(1, a.Height / ReferenceHeight);

    /// Kang 09-26 arranged 7 windows by hand like bricks (quarter width, rows stepping down by this much).
    public const double BrickStep = 120;

    /// Frames for `n` windows inside `area` (the monitor's work area). `pt` = pixels per point (DPI / 96); it only
    /// scales the 12+ cascade offsets, which are title-bar sized, so the tested layouts are identical to the Mac.
    public static List<Rectangle> Frames(int n, Rectangle area, FourStyle four = FourStyle.Columns, double pt = 1)
    {
        if (n <= 0 || area.Width <= 0 || area.Height <= 0) return new();
        return n switch
        {
            1 => new() { area },
            2 or 3 => Columns(n, area),
            4 => four == FourStyle.Columns ? Columns(4, area) : Grid(new[] { 2, 2 }, area),
            5 => Grid(new[] { 3, 2 }, area),
            6 or 7 => Brick(n, area),                                         // Kang's own hand-made layout, squared up
            8 => OverlapRows(new[] { 4, 4 }, area, halfShiftMiddle: false),
            _ => OverlapRows(new[] { 4, 3, 4 }, area, halfShiftMiddle: true, extra: Math.Max(0, n - 11), pt: pt).Take(n).ToList(),
        };
    }

    /// Row of each frame for the canonical stacking (0 = top row, lowest in z-order).
    public static int[] Rows(int n) => n switch
    {
        6 => new[] { 0, 0, 1, 1, 2, 2 },
        7 => new[] { 0, 0, 1, 1, 1, 2, 2 },
        8 => new[] { 0, 0, 0, 0, 1, 1, 1, 1 },
        >= 9 => new[] { 0, 0, 0, 0, 1, 1, 1, 2, 2, 2, 2 }.Concat(Enumerable.Repeat(1, Math.Max(0, n - 11))).Take(n).ToArray(),
        _ => new int[Math.Max(0, n)],
    };

    /// CGRect.integral: the smallest integer rectangle containing the exact one.
    static Rectangle Integral(double x, double y, double w, double h)
    {
        int x0 = (int)Math.Floor(x), y0 = (int)Math.Floor(y);
        return new Rectangle(x0, y0, (int)Math.Ceiling(x + w) - x0, (int)Math.Ceiling(y + h) - y0);
    }

    /// Swift's `rounded()`: to nearest, half away from zero (C#'s default would be banker's rounding).
    static double Round(double v) => Math.Round(v, MidpointRounding.AwayFromZero);

    static List<Rectangle> Columns(int n, Rectangle a)
    {
        double w = (double)a.Width / n;
        return Enumerable.Range(0, n).Select(i => Integral(a.X + i * w, a.Y, w, a.Height)).ToList();
    }

    static List<Rectangle> Grid(int[] rows, Rectangle a)
    {
        double h = (double)a.Height / rows.Length;
        return rows.SelectMany((count, r) =>
        {
            double w = (double)a.Width / count;
            return Enumerable.Range(0, count).Select(c => Integral(a.X + c * w, a.Y + r * h, w, h));
        }).ToList();
    }

    /// Rows that overlap vertically; every window has the same height H = area − reveal, rows step down evenly
    /// by d = reveal / (R − 1). In canonical stacking (later rows on top) each row keeps a band of d at its top.
    static List<Rectangle> OverlapRows(int[] rows, Rectangle a, bool halfShiftMiddle, int extra = 0, double pt = 1)
    {
        int R = rows.Length;
        double reveal = Round(RowReveal * Scale(a));
        double h = a.Height - reveal;
        double d = R > 1 ? reveal / (R - 1) : 0;
        int mx = rows.Max();
        var list = new List<Rectangle>();
        for (int r = 0; r < R; r++)
        {
            int count = rows[r];
            double w = halfShiftMiddle ? (double)a.Width / mx : (double)a.Width / count;
            double shift = halfShiftMiddle && count < mx ? w / 2 : 0;
            for (int c = 0; c < count; c++) list.Add(Integral(a.X + shift + c * w, a.Y + r * d, w, h));
        }
        // 12+: extra windows cascade along the middle row so their title bars stay visible
        if (extra > 0 && R >= 3)
        {
            var mid = list.GetRange(rows[0], rows[1]);
            for (int k = 0; k < extra; k++)
            {
                double step = (k / mid.Count + 1) * 28 * pt;
                var m = mid[k % mid.Count];
                list.Add(Integral(m.X + Math.Min(step, 120 * pt), m.Y + Math.Min(step, d - 28 * pt), m.Width, m.Height));
            }
        }
        return list;
    }

    /// Quarter-width windows: top row in columns 1 & 3, middle row half-shifted, bottom row in columns 2 & 4.
    /// Besides its top edge every window keeps a vertical strip no neighbour covers. 6 = drop the middle-centre one.
    static List<Rectangle> Brick(int n, Rectangle a)
    {
        double step = Round(BrickStep * Scale(a));
        double w = a.Width / 4.0, h = a.Height - 2 * step;
        double[][] xs = n == 7
            ? new[] { new[] { 0, 2 * w }, new[] { w / 2, 1.5 * w, 2.5 * w }, new[] { w, 3 * w } }
            : new[] { new[] { 0, 2 * w }, new[] { w / 2, 2.5 * w }, new[] { w, 3 * w } };
        return xs.SelectMany((row, r) => row.Select(x => Integral(a.X + x, a.Y + r * step, w, h))).ToList();
    }
}
