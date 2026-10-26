using System.Diagnostics;
using System.Drawing.Drawing2D;
using System.Numerics;

namespace ShoWork;

/// 島（含角色、影分身）自己一個控制項：動畫每格只 Invalidate 這一塊，對話框、標題、工具列都不重畫
/// （Mac 10-13 的教訓：整個視窗每格重排版 CPU 21–27%）。計時器在 BoardForm，一個視窗只有一個。
sealed class IslandArt : Control
{
    static readonly Stopwatch clock = Stopwatch.StartNew();
    /// 動畫時間（秒）。只拿來算週期，從幾開始都一樣
    public static double Now => clock.Elapsed.TotalSeconds;

    Island? island;
    List<Islander> people = new();
    IslandGeometry geo = new(1);
    double scale = 1;
    string? focus;
    // 影分身出現／消失的時間：出現「噗」一下、走了淡出（Mac 10-13 Kang：像影分身之術，去別人家繞一繞就消失）
    readonly Dictionary<string, double> born = new();
    readonly Dictionary<string, (Islander Who, double At)> gone = new();

    /// 減少動態效果開著：畫靜止的第 0 格
    public bool ReduceMotion;
    /// 滑鼠停在哪個角色上（給卡片點亮對應的對話框）
    public event Action<string?>? Hovered;
    string? hovered;

    public IslandArt()
    {
        // 雙緩衝自己做：WinForms 內建的共用緩衝只重用 225×96 以內的，比它大（島都比它大）每畫一格就新開一塊再丟掉
        SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint | ControlStyles.Opaque | ControlStyles.ResizeRedraw, true);
        SetStyle(ControlStyles.Selectable, false);
        TabStop = false;
    }

    public void SetIsland(Island next, List<Islander> shown, IslandGeometry g, double s, string? focusId)
    {
        double now = Now;
        var old = island?.Ghosts ?? new();
        var ids = next.Ghosts.Select(x => x.Id).ToHashSet();
        foreach (var x in next.Ghosts) if (!born.ContainsKey(x.Id)) { born[x.Id] = now; gone.Remove(x.Id); }
        foreach (var x in old) if (!ids.Contains(x.Id)) { born.Remove(x.Id); gone[x.Id] = (x, now); }
        island = next; people = shown; geo = g; scale = s; focus = focusId;
        Invalidate();
    }

    public void SetFocus(string? id) { if (focus != id) { focus = id; Invalidate(); } }

    /// 有東西在動：有人不是閒置／卡住、有影分身、或剛走的還在淡出
    public bool Moving
    {
        get
        {
            double now = Now;
            foreach (var k in gone.Where(kv => now - kv.Value.At >= KuboMath.FadeSeconds).Select(kv => kv.Key).ToList()) gone.Remove(k);
            return people.Any(p => p.Mood is not (Mood.Idle or Mood.Asleep or Mood.Stuck)) || (island?.Ghosts.Count ?? 0) > 0 || gone.Count > 0;
        }
    }

    float Dpi => DeviceDpi / 96f;

    readonly BufferedGraphicsContext buffer = new() { MaximumBuffer = new Size(4096, 4096) };

    /// 量測用：畫島一共花了多少時間（BoardForm 關閉時寫進 log）
    public static long PaintTicks, PaintCount;

    protected override void OnPaint(PaintEventArgs e)
    {
        long t0 = Stopwatch.GetTimestamp();
        try
        {
            using var bg = buffer.Allocate(e.Graphics, ClientRectangle);
            PaintIsland(bg.Graphics);
            bg.Render(e.Graphics);
        }
        finally { PaintTicks += Stopwatch.GetTimestamp() - t0; PaintCount++; }
    }

    // 快取（10-15 Surface 實測：整座島每格全部重畫 2.8 ms、看板 CPU 11%）：島身＋底色、每格的地板、桌子（閒置的人連身體）
    // 不會動，先畫成點陣圖；每格只貼圖＋畫光圈、角色、泡泡、影分身。疊放順序跟全部重畫一樣。
    sealed record Baked(Bitmap Bmp, int X, int Y) : IDisposable { public void Dispose() => Bmp.Dispose(); }
    Bitmap? baseBmp;
    readonly List<(Baked Floor, Baked Desk)> tiles = new();
    string bakedKey = "";

    void DropCache()
    {
        baseBmp?.Dispose(); baseBmp = null;
        foreach (var (f, d) in tiles) { f.Dispose(); d.Dispose(); }
        tiles.Clear();
        bakedKey = "";
    }

    Matrix3x2 Base => Matrix3x2.CreateScale((float)(scale * Dpi));
    Matrix3x2 TileMatrix(int n)
    {
        var (x, y) = geo.Spot(n);
        return Matrix3x2.CreateScale((float)IslandGeometry.K) * Matrix3x2.CreateTranslation((float)x, (float)y) * Base;
    }

    static Graphics Prep(Graphics g)
    {
        g.SmoothingMode = SmoothingMode.AntiAlias;
        g.PixelOffsetMode = PixelOffsetMode.HighQuality;
        return g;
    }

    /// 在 m 座標下 box 這塊畫成一張剛好包住的點陣圖（透明底，原點對齊實際像素，不會差半格）
    static Baked Bake(RectangleF box, Matrix3x2 m, Action<Pen2> draw)
    {
        var pts = new[] { new Vector2(box.Left, box.Top), new Vector2(box.Right, box.Top), new Vector2(box.Left, box.Bottom), new Vector2(box.Right, box.Bottom) }
            .Select(v => Vector2.Transform(v, m)).ToArray();
        int x0 = (int)Math.Floor(pts.Min(p => p.X)) - 2, y0 = (int)Math.Floor(pts.Min(p => p.Y)) - 2;
        int x1 = (int)Math.Ceiling(pts.Max(p => p.X)) + 2, y1 = (int)Math.Ceiling(pts.Max(p => p.Y)) + 2;
        var bmp = new Bitmap(Math.Max(1, x1 - x0), Math.Max(1, y1 - y0), System.Drawing.Imaging.PixelFormat.Format32bppPArgb);
        using (var g = Prep(Graphics.FromImage(bmp)))
            draw(new Pen2(g, m * Matrix3x2.CreateTranslation(-x0, -y0)));
        return new Baked(bmp, x0, y0);
    }

    void EnsureCache()
    {
        if (island == null) return;
        var key = $"{Width}x{Height}|{scale:F4}|{DeviceDpi}|{BackColor.ToArgb()}|{island.Project}|{geo.Side}|" +
                  string.Join(",", people.Select(p => $"{p.Mood}{p.Accessory}"));
        if (key == bakedKey && baseBmp != null) return;
        DropCache();
        bakedKey = key;
        var color = KuboArt.IslandColor(island.Project);
        baseBmp = new Bitmap(Math.Max(1, Width), Math.Max(1, Height), System.Drawing.Imaging.PixelFormat.Format32bppPArgb);
        using (var g = Prep(Graphics.FromImage(baseBmp)))
        {
            g.Clear(BackColor);
            KuboArt.Island(new Pen2(g, Base), geo, color);
        }
        var floor = KuboArt.Blend(color, 0.45, Color.Black);
        for (int n = 0; n < people.Count; n++)
        {
            var p = people[n];
            var m = TileMatrix(n);
            var f = Bake(KuboArt.FloorBox, m, c => KuboArt.TileFloor(c, floor));
            var d = Bake(KuboArt.DeskBox, m, c =>
            {
                KuboArt.TileDesk(c, p.Mood);
                if (Still(p.Mood)) KuboArt.TileBody(c, p.Mood, p.Accessory, 0);     // 閒置／睡覺的人不會動，跟桌子一起畫（Zzz、咖啡熱氣停在第一格，同 Mac 整島閒置時停計時器）
            });
            tiles.Add((f, d));
        }
    }

    static bool Still(Mood m) => m is Mood.Idle or Mood.Asleep;

    void PaintIsland(Graphics g)
    {
        if (island == null) { g.Clear(BackColor); return; }
        EnsureCache();
        g.CompositingMode = CompositingMode.SourceCopy;          // 底圖不透明：直接蓋過去，不用混色
        g.DrawImageUnscaled(baseBmp!, 0, 0);
        g.CompositingMode = CompositingMode.SourceOver;
        Prep(g);
        double now = Now;
        double t = ReduceMotion ? 0 : now;
        var ctx = new Pen2(g, Base);
        // 影分身在島的後半圈就先畫（被居民擋住），前半圈最後畫
        void Ghosts(bool back)
        {
            foreach (var x in island.Ghosts.Where(x => KuboMath.GhostBehind(x.Id, t) == back))
                KuboArt.Ghost(ctx, geo, x, t, now - born.GetValueOrDefault(x.Id, double.NegativeInfinity), 1);
            foreach (var (x, at) in gone.Values.Where(v => KuboMath.GhostBehind(v.Who.Id, t) == back).ToList())
            {
                double f = 1 - (now - at) / KuboMath.FadeSeconds;
                if (f > 0) KuboArt.Ghost(ctx, geo, x, t, 10, f);
            }
        }
        Ghosts(back: true);
        // 先畫後排（y 小的）再畫前排，前面的角色蓋住後面的
        foreach (var n in Enumerable.Range(0, people.Count).OrderBy(n => geo.Spot(n).Y))
        {
            var p = people[n];
            var (floorBmp, deskBmp) = tiles[n];
            double tp = t + KuboMath.Phase(p.Id);
            g.ResetTransform();
            g.DrawImageUnscaled(floorBmp.Bmp, floorBmp.X, floorBmp.Y);
            var c = new Pen2(g, TileMatrix(n));
            KuboArt.TileRing(c, p.Mood, tp, p.Id == focus);
            g.ResetTransform();
            g.DrawImageUnscaled(deskBmp.Bmp, deskBmp.X, deskBmp.Y);
            if (!Still(p.Mood)) KuboArt.TileBody(c, p.Mood, p.Accessory, tp);
        }
        Ghosts(back: false);
        g.ResetTransform();
    }

    protected override void OnSizeChanged(EventArgs e) { base.OnSizeChanged(e); DropCache(); }
    protected override void OnBackColorChanged(EventArgs e) { base.OnBackColorChanged(e); DropCache(); }
    protected override void OnDpiChangedAfterParent(EventArgs e) { base.OnDpiChangedAfterParent(e); DropCache(); }
    protected override void Dispose(bool disposing) { if (disposing) { DropCache(); buffer.Dispose(); } base.Dispose(disposing); }

    /// 角色的可點範圍（Mac：80×92，中心在地板中心往上 22）
    string? HitPerson(Point pt)
    {
        double s = scale * Dpi;
        for (int n = people.Count - 1; n >= 0; n--)
        {
            var (x, y) = geo.Spot(n);
            var r = new RectangleF((float)((x - 40) * s), (float)((y - 22 - 46) * s), (float)(80 * s), (float)(92 * s));
            if (r.Contains(pt)) return people[n].Id;
        }
        return null;
    }

    public string? PersonAt(Point pt) => HitPerson(pt);

    protected override void OnMouseMove(MouseEventArgs e)
    {
        base.OnMouseMove(e);
        var h = HitPerson(e.Location);
        if (h != hovered) { hovered = h; Hovered?.Invoke(h); }
    }

    protected override void OnMouseLeave(EventArgs e)
    {
        base.OnMouseLeave(e);
        if (hovered != null) { hovered = null; Hovered?.Invoke(null); }
    }
}
