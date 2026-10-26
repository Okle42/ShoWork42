using System.Drawing.Drawing2D;
using System.Numerics;

namespace ShoWork;

// 島與 Kubo 的畫法：Mac 版 IslandView.swift 的 Pen／KuboArt 逐行翻成 GDI+。
// 座標跟決策板的 SVG 一樣：地板中心 (0,0)，腳底在 (0,14)，y 往下。顏色、尺寸都照 Mac，不要自己改。

/// 值語意的畫筆：複製一份再平移／縮放不影響原本的（同 Mac 的 Pen）。底下畫在 GDI+ Graphics 上。
struct Pen2
{
    public readonly Graphics G;
    Matrix3x2 m;
    public double Opacity;
    float blur;

    public Pen2(Graphics g, Matrix3x2 baseTransform) { G = g; m = baseTransform; Opacity = 1; blur = 0; }

    // Swift 的 translatedBy／scaledBy／rotated 是「先套新的、再套原本的」⇒ 新矩陣乘在左邊
    public void Translate(double x, double y) => m = Matrix3x2.CreateTranslation((float)x, (float)y) * m;
    public void Scale(double x, double y) => m = Matrix3x2.CreateScale((float)x, (float)y) * m;
    public void Rotate(double degrees) => m = Matrix3x2.CreateRotation((float)(degrees * Math.PI / 180)) * m;
    public void Blur(double r) => blur = (float)r;

    Color A(Color c) => Color.FromArgb((int)Math.Clamp(c.A * Opacity, 0, 255), c);

    public void Fill(GraphicsPath p, Color c)
    {
        G.TransformElements = m;
        using var b = new SolidBrush(A(c));
        G.FillPath(b, p);
    }

    public void Stroke(GraphicsPath p, Color c, double width, LineCap cap = LineCap.Flat, LineJoin join = LineJoin.Miter)
    {
        G.TransformElements = m;
        if (blur > 0)
        {
            // GDI+ 沒有模糊：一層一層加寬、變淡的線疊出光暈（只拿來畫影分身的紫光）
            for (int i = 3; i >= 1; i--)
            {
                using var glow = new Pen(Color.FromArgb((int)Math.Clamp(c.A * Opacity * 0.22, 0, 255), c), (float)width + blur * i * 0.8f)
                    { LineJoin = LineJoin.Round };
                G.DrawPath(glow, p);
            }
            return;
        }
        using var pen = new Pen(A(c), (float)width) { StartCap = cap, EndCap = cap, LineJoin = join };
        G.DrawPath(pen, p);
    }

    static readonly Dictionary<double, Font> fonts = new();
    static readonly StringFormat Centered = new(StringFormat.GenericTypographic) { Alignment = StringAlignment.Center, LineAlignment = StringAlignment.Center };

    /// 置中畫一個字（泡泡裡的「!」「?」）
    public void Text(string s, double size, Color c, double x, double y)
    {
        G.TransformElements = m;
        // 字型每格新開很貴（Surface 上一個 0.2 ms 上下）：每種大小開一次重用（!?＝15、Zzz＝11／15／20）
        if (!fonts.TryGetValue(size, out var bang)) fonts[size] = bang = new Font("Segoe UI Black", (float)size, FontStyle.Bold, GraphicsUnit.Pixel);
        using var b = new SolidBrush(A(c));
        // ClearType 畫在透明底的快取圖上（睡覺的 Zzz）邊緣會發黑：一律用灰階反鋸齒
        G.TextRenderingHint = System.Drawing.Text.TextRenderingHint.AntiAlias;
        G.DrawString(s, bang, b, new RectangleF((float)x - 20, (float)y - 20, 40, 40), Centered);
    }
}

static class KuboArt
{
    static Color Rgb(int rgb, double a = 1) => Color.FromArgb((int)(a * 255), (rgb >> 16) & 0xFF, (rgb >> 8) & 0xFF, rgb & 0xFF);
    static Color F(double r, double g, double b, double a = 1) => Color.FromArgb((int)(a * 255), (int)(r * 255), (int)(g * 255), (int)(b * 255));
    static Color Op(Color c, double a) => Color.FromArgb((int)Math.Clamp(c.A * a, 0, 255), c);
    static Color Black(double a) => Color.FromArgb((int)(a * 255), 0, 0, 0);
    static Color White(double a) => Color.FromArgb((int)(a * 255), 255, 255, 255);
    /// NSColor.blended(withFraction:of:)
    public static Color Blend(Color a, double f, Color b) =>
        Color.FromArgb((int)(a.A + (b.A - a.A) * f), (int)(a.R + (b.R - a.R) * f), (int)(a.G + (b.G - a.G) * f), (int)(a.B + (b.B - a.B) * f));

    public static readonly Color Clay = Rgb(0xD97757), ClayDark = Rgb(0xB35C3F), ClayLight = Rgb(0xF2A07F);
    static readonly Color Ink = Rgb(0x2A1D18);

    /// 角色狀態色：紫／紅／綠跟光暈設定走（同 Mac 的 Look.color），卡住橘、閒置灰用系統色
    public static Color Tint(Mood m) => m switch
    {
        Mood.Working => GlowWindow.ColorOf(WorkState.Working),
        Mood.Waiting => GlowWindow.ColorOf(WorkState.Input),
        Mood.Finished => GlowWindow.ColorOf(WorkState.Done),
        Mood.Stuck => Rgb(0xFF9F0A),
        _ => Rgb(0x8E8E93),
    };

    static readonly Color[] IslandPalette = new[] { 0x5c3a33, 0x2b5a54, 0x30477a, 0x5a4a2a, 0x4a3266, 0x3a5a33, 0x5a3350 }.Select(x => Rgb(x)).ToArray();
    /// 專案名固定配一個島色（跟 Mac 同一個雜湊，同專案兩邊同色）
    public static Color IslandColor(string project) => IslandPalette[KuboMath.IslandColorIndex(project)];

    static GraphicsPath Poly(params (double X, double Y)[] pts)
    {
        var p = new GraphicsPath();
        p.AddPolygon(pts.Select(q => new PointF((float)q.X, (float)q.Y)).ToArray());
        return p;
    }
    static GraphicsPath Rect(double x, double y, double w, double h, double r = 0)
    {
        var p = new GraphicsPath();
        if (r <= 0) { p.AddRectangle(new RectangleF((float)x, (float)y, (float)w, (float)h)); return p; }
        float d = (float)Math.Min(r * 2, Math.Min(w, h));
        float X = (float)x, Y = (float)y, W = (float)w, H = (float)h;
        p.AddArc(X, Y, d, d, 180, 90); p.AddArc(X + W - d, Y, d, d, 270, 90);
        p.AddArc(X + W - d, Y + H - d, d, d, 0, 90); p.AddArc(X, Y + H - d, d, d, 90, 90);
        p.CloseFigure();
        return p;
    }
    static GraphicsPath Ellipse(double x, double y, double w, double h)
    {
        var p = new GraphicsPath();
        p.AddEllipse((float)x, (float)y, (float)w, (float)h);
        return p;
    }
    static PointF P(double x, double y) => new((float)x, (float)y);
    /// 二次貝茲（SwiftUI addQuadCurve）→ GDI+ 只有三次的
    static void Quad(GraphicsPath p, PointF from, PointF ctl, PointF to) =>
        p.AddBezier(from, P(from.X + 2.0 / 3 * (ctl.X - from.X), from.Y + 2.0 / 3 * (ctl.Y - from.Y)),
                          P(to.X + 2.0 / 3 * (ctl.X - to.X), to.Y + 2.0 / 3 * (ctl.Y - to.Y)), to);

    static void Fill(Pen2 c, GraphicsPath p, Color col) { using (p) c.Fill(p, col); }
    static void Stroke(Pen2 c, GraphicsPath p, Color col, double w, LineCap cap = LineCap.Flat, LineJoin join = LineJoin.Miter) { using (p) c.Stroke(p, col, w, cap, join); }

    public static void Island(Pen2 ctx, IslandGeometry geo, Color color)
    {
        var (cx, cy) = geo.Center;
        double w = geo.HalfW, h = geo.HalfH, d = IslandGeometry.Depth;
        Fill(ctx, Poly((cx - w, cy), (cx, cy + h), (cx, cy + h + d), (cx - w, cy + d)), Op(color, 0.75));
        Fill(ctx, Poly((cx + w, cy), (cx, cy + h), (cx, cy + h + d), (cx + w, cy + d)), Op(color, 0.55));
        Fill(ctx, Poly((cx - w, cy), (cx, cy + h), (cx, cy + h + d), (cx - w, cy + d)), Black(0.3));
        Fill(ctx, Poly((cx + w, cy), (cx, cy + h), (cx, cy + h + d), (cx + w, cy + d)), Black(0.45));
        Fill(ctx, Poly((cx - w, cy), (cx, cy - h), (cx + w, cy), (cx, cy + h)), color);
    }

    /// 一格（地板＋光圈＋桌子＋角色）。拆成四層是為了快取：地板、桌子不會動，先畫成點陣圖，每格只畫會動的（IslandArt）
    public static void Tile(Pen2 ctx, Mood mood, Accessory? accessory, double t, Color floor, bool highlight = false)
    {
        TileFloor(ctx, floor);
        TileRing(ctx, mood, t, highlight);
        TileDesk(ctx, mood);
        TileBody(ctx, mood, accessory, t);
    }

    public static void TileFloor(Pen2 ctx, Color floor)
    {
        Fill(ctx, Poly((-70, 0), (0, -35), (70, 0), (0, 35)), floor);
        Fill(ctx, Poly((-70, 0), (0, 35), (0, 41), (-70, 6)), Black(0.28));
        Fill(ctx, Poly((70, 0), (0, 35), (0, 41), (70, 6)), Black(0.4));
    }
    /// 地板那一層的範圍（tile 座標）
    public static readonly RectangleF FloorBox = new(-71, -36, 142, 78);

    public static void TileRing(Pen2 ctx, Mood mood, double t, bool highlight)
    {
        var sc = Tint(mood);
        if (highlight) Stroke(ctx, Ellipse(-44, -7, 88, 34), White(0.85), 2.5);
        if (mood is not (Mood.Idle or Mood.Asleep))
        {
            Fill(ctx, Ellipse(-34, -3, 68, 26), Op(sc, 0.12));
            double pulse = mood == Mood.Stuck ? 0.7 : 0.35 + 0.55 * KuboMath.Wave(t, 1.6);
            Stroke(ctx, Ellipse(-34, -3, 68, 26), Op(sc, pulse), 3);
        }
    }

    /// 桌子、螢幕、盆栽
    public static void TileDesk(Pen2 ctx, Mood mood)
    {
        var sc = Tint(mood);
        var desk = ctx;
        desk.Translate(0, -14);
        Fill(desk, Poly((-38, 0), (0, -19), (38, 0), (0, 19)), F(0.81, 0.65, 0.50));
        Fill(desk, Poly((-38, 0), (0, 19), (0, 23), (-38, 4)), F(0.66, 0.52, 0.37));
        Fill(desk, Poly((38, 0), (0, 19), (0, 23), (38, 4)), F(0.56, 0.42, 0.29));
        Fill(desk, Poly((-24, -6), (-4, -16), (-4, -34), (-24, -24)), F(0.17, 0.15, 0.20));
        Fill(desk, Poly((-22, -8), (-6, -16), (-6, -31), (-22, -23)), mood is Mood.Idle or Mood.Asleep ? F(0.23, 0.20, 0.27) : Op(sc, 0.85));
        Fill(desk, Ellipse(19, -11, 10, 10), F(0.36, 0.64, 0.36));
        Fill(desk, Rect(21, -3, 6, 5), F(0.55, 0.35, 0.23));
    }
    /// 桌子＋（閒置／睡覺的）角色那一層的範圍：桌子 y −48…9、手 ±27、腳到 14、咖啡杯把手到 x 36、
    /// 最大的 z 中心 (42, −65)、20px 字 ⇒ 右到 ~53、頂到 ~−77
    public static readonly RectangleF DeskBox = new(-40, -80, 96, 98);

    /// 角色（身體、配件、頭上的泡泡）
    public static void TileBody(Pen2 ctx, Mood mood, Accessory? accessory, double t)
    {
        var me = ctx;
        me.Translate(0, 14);
        var body = me;
        switch (mood)
        {
            case Mood.Waiting: body.Translate(0, -7 * Math.Max(0, Math.Sin(t / 0.7 * 2 * Math.PI))); break;
            case Mood.Finished: body.Rotate(3 * Math.Sin(t / 2.4 * 2 * Math.PI)); break;
        }
        if (mood == Mood.Asleep) body.Opacity = 0.8;
        Kubo(body, mood, t);
        if (accessory is { } a) Accessory(body, a);
        Bubble(me, mood, t, Tint(mood));
    }

    static void Kubo(Pen2 ctx, Mood mood, double t)
    {
        foreach (var x in new[] { -16.0, -7, 2, 11 }) Fill(ctx, Rect(x, -12, 5, 12), ClayDark);
        Fill(ctx, Rect(-20, -40, 40, 29), Clay);
        Fill(ctx, Rect(-20, -40, 40, 4), Op(ClayLight, 0.55));
        double typing = mood == Mood.Working ? -3 * KuboMath.Wave(t, KuboMath.TypingPeriod) : 0;
        Fill(ctx, Rect(-27, -27 + typing, 7, 7), Clay);
        Fill(ctx, Rect(20, -27 + (mood == Mood.Working ? -3 - typing : 0), 7, 7), Clay);
        switch (mood)
        {
            case Mood.Finished:
                var p = new GraphicsPath();
                p.AddLines(new[] { P(-12, -28), P(-9, -32), P(-6, -28) });
                p.StartFigure();
                p.AddLines(new[] { P(6, -28), P(9, -32), P(12, -28) });
                Stroke(ctx, p, Ink, 2.5, LineCap.Square);
                break;
            case Mood.Asleep:
                Fill(ctx, Rect(-12, -30, 6, 2.5), Ink); Fill(ctx, Rect(6, -30, 6, 2.5), Ink);
                break;
            case Mood.Idle:     // 休息：眼睛睜開、右手拿一杯冒熱氣的咖啡
                Fill(ctx, Rect(-11, -35, 4, 9), Ink); Fill(ctx, Rect(7, -35, 4, 9), Ink);
                var cup = F(0.96, 0.94, 0.90);
                Fill(ctx, Rect(22, -36, 10, 11, 1.5), cup);
                Fill(ctx, Rect(22, -36, 10, 2.5), F(0.42, 0.27, 0.18));              // 咖啡面
                Stroke(ctx, Rect(31, -33, 5, 5, 2), cup, 2);
                double[] steam = { 25, 29 };
                for (int i = 0; i < steam.Length; i++)
                {
                    double x = steam[i];
                    var sp = new GraphicsPath();
                    Quad(sp, P(x, -39), P(x + 3, -43), P(x, -47));
                    Quad(sp, P(x, -47), P(x - 3, -51), P(x, -54));
                    Stroke(ctx, sp, F(0.62, 0.66, 0.76, 0.45 + 0.4 * KuboMath.Wave(t + i * 0.6, 1.8)), 1.6, LineCap.Round);
                }
                break;
            default:
                Fill(ctx, Rect(-11, -35, 4, 9), Ink); Fill(ctx, Rect(7, -35, 4, 9), Ink);
                break;
        }
    }

    /// 影分身：半透明、沒有腳（下襬波浪）、飄著繞島走；本尊照樣坐在自己島上打字
    public static void Ghost(Pen2 baseCtx, IslandGeometry geo, Islander who, double t, double age, double fade)
    {
        double a = KuboMath.GhostAngle(who.Id, t);
        var (cx, cy) = geo.Center;
        double x = cx + geo.HalfW * 0.72 * Math.Cos(a);                    // 沿著島的外圈飄
        double y = cy + geo.HalfH * 0.72 * Math.Sin(a) + 4;
        double lift = 10 + 5 * KuboMath.Wave(t, 1.8);                      // 飄在半空
        double alpha = Math.Min(1, Math.Max(0, age / 0.5)) * fade;
        var shadow = baseCtx;
        shadow.Opacity = alpha;
        Fill(shadow, Ellipse(x - 14, y - 3, 28, 8), Black(0.3));
        var ctx = baseCtx;
        ctx.Translate(x, y - lift);
        ctx.Scale(IslandGeometry.K * 0.85, IslandGeometry.K * 0.85);
        ctx.Opacity = 0.8 * alpha;
        var tintC = Tint(Mood.Working);
        var pale = Blend(ClayLight, 0.55, Color.White);
        if (-Math.Sin(a) < 0) ctx.Scale(-1, 1);                            // 往哪飄就面向哪（逆時針繞）
        var body = new GraphicsPath();
        body.AddLine(P(-20, -40), P(20, -40));
        body.AddLine(P(20, -40), P(20, -6));
        double sway = 2 * Math.Sin(t * 5);
        var at = P(20, -6);
        for (int i = 0; i < 4; i++)                                       // 波浪下襬
        {
            double x0 = 20 - i * 10;
            var to = P(x0 - 10, -6);
            Quad(body, at, P(x0 - 5, (i % 2 == 0 ? 2 : -10) + sway), to);
            at = to;
        }
        body.CloseFigure();
        using (body)
        {
            var glow = ctx;                                                // 一圈紫光（影分身的查克拉）
            glow.Blur(5);
            glow.Stroke(body, tintC, 6);
            ctx.Fill(body, pale);
            ctx.Stroke(body, Op(tintC, 0.9), 1.5);
        }
        Fill(ctx, Rect(-27, -24, 7, 7), pale);                             // 手往前伸，飄的樣子
        Fill(ctx, Rect(20, -24, 7, 7), pale);
        Fill(ctx, Rect(-11, -35, 4, 9), Ink); Fill(ctx, Rect(7, -35, 4, 9), Ink);
        if (who.Accessory is { } acc) Accessory(ctx, acc);
        // 出現時「噗」一團煙
        if (age < KuboMath.PuffSeconds)
        {
            double k = age / KuboMath.PuffSeconds;
            var puff = baseCtx;
            puff.Translate(x, y - 18);
            puff.Opacity = (1 - k) * 0.8;
            for (int i = 0; i < 6; i++)
            {
                double r = 10 + 26 * k, ang = i / 6.0 * 2 * Math.PI;
                Fill(puff, Ellipse(r * Math.Cos(ang) - 7, r * Math.Sin(ang) * 0.6 - 7, 14, 14), Color.White);
            }
        }
    }

    public static void Accessory(Pen2 ctx, Accessory a)
    {
        var dark = F(0.23, 0.20, 0.27);
        switch (a)
        {
            case ShoWork.Accessory.Crown:
                Fill(ctx, Crown(), F(1, 0.78, 0.24));
                Stroke(ctx, Crown(), F(0.79, 0.57, 0.10), 1, LineCap.Round, LineJoin.Round);
                break;
            case ShoWork.Accessory.Headset:
                var band = new GraphicsPath();
                Quad(band, P(-20, -30), P(-20, -48), P(0, -48));
                Quad(band, P(0, -48), P(20, -48), P(20, -30));
                Stroke(ctx, band, dark, 3);
                Fill(ctx, Rect(-24, -35, 7, 11, 3), dark); Fill(ctx, Rect(17, -35, 7, 11, 3), dark);
                var mic = new GraphicsPath();
                Quad(mic, P(-21, -25), P(-19, -16), P(-7, -15));
                Stroke(ctx, mic, dark, 1.6);
                Fill(ctx, Ellipse(-9, -17, 4, 4), dark);
                break;
            case ShoWork.Accessory.Glasses:
                var g = new GraphicsPath();
                g.AddEllipse(-14.5f, -36, 11, 11);
                g.AddEllipse(3.5f, -36, 11, 11);
                g.StartFigure();
                g.AddLine(-3.5f, -30.5f, 3.5f, -30.5f);
                Stroke(ctx, g, F(0.16, 0.13, 0.20), 1.8);
                break;
        }
    }

    public static GraphicsPath Crown() => Poly((-9, -41), (-11, -51), (-5, -46), (0, -54), (5, -46), (11, -51), (9, -41));

    static void Bubble(Pen2 ctx, Mood mood, double t, Color color)
    {
        var b = ctx;
        b.Translate(0, -3 * KuboMath.Wave(t, 1.4));
        switch (mood)
        {
            case Mood.Working:
                Fill(b, Rect(12, -68, 30, 16, 8), color);
                double[] xs = { 20, 27, 34 };
                for (int i = 0; i < 3; i++)
                {
                    double o = 0.25 + 0.75 * KuboMath.Wave(t + i * 0.2, 1.0);
                    Fill(b, Ellipse(xs[i] - 2.2, -62.2, 4.4, 4.4), White(o));
                }
                break;
            case Mood.Finished:
                Fill(b, Ellipse(16, -70, 20, 20), color);
                var p = new GraphicsPath();
                p.AddLines(new[] { P(21, -60), P(24.5, -56.5), P(31, -63.5) });
                Stroke(b, p, Color.White, 2.6, LineCap.Round, LineJoin.Round);
                break;
            case Mood.Waiting or Mood.Stuck:
                Fill(b, Rect(16, -72, 20, 20, 10), color);
                b.Text(mood == Mood.Waiting ? "!" : "?", 15, Color.White, 26, -62);
                break;
            case Mood.Asleep:   // 睡覺：頭上斜斜往上三個 z，一個比一個大（同 Mac；不跟泡泡一起上下飄）
                var zz = F(0.62, 0.68, 0.88);
                (double X, double Y, double S)[] zs = { (17, -52, 11), (28, -64, 15), (42, -79, 20) };
                for (int i = 0; i < zs.Length; i++)
                {
                    var z = ctx;
                    double w = KuboMath.Wave(t + i * 0.5, 2.4);
                    z.Opacity = 0.55 + 0.45 * w;
                    z.Translate(0, -2 * w);
                    z.Text("z", zs[i].S, zz, zs[i].X, zs[i].Y);
                }
                break;
        }
    }
}
