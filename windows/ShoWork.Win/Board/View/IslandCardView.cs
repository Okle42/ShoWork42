using System.Drawing.Drawing2D;
using Microsoft.Win32;

namespace ShoWork;

/// 戰情中心的顏色（深色／淺色跟系統的「應用程式模式」）
sealed record BoardTheme(bool Dark, Color Back, Color Card, Color Bubble, Color Text, Color Secondary, Color Tertiary, Color Separator, Color Track)
{
    /// 70–84% 的橘字：深色用系統橘 #FF9F0A；淺色白底上只有約 2:1 看不清 ⇒ 改深橘 #B25E00（約 4.7:1，過 WCAG AA）
    public Color Warn => Dark ? Color.FromArgb(0xFF, 0x9F, 0x0A) : Color.FromArgb(0xB2, 0x5E, 0x00);

    public static BoardTheme Current()
    {
        bool dark = false;
        try { dark = Registry.GetValue(@"HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize", "AppsUseLightTheme", 1) is 0; } catch { }
        // 截圖驗收用：SHOWORK_BOARD_THEME=light／dark，不必去改使用者的系統設定
        var forced = Environment.GetEnvironmentVariable("SHOWORK_BOARD_THEME");
        if (forced is "light" or "dark") dark = forced == "dark";
        // 深色照 Mac 截圖：視窗底 > 卡片稍亮 > 對話框最暗
        return dark
            ? new(true, C(0x202020), C(0x2E2E2E), C(0x1C1C1C), C(0xFFFFFF), C(0xA8A8A8), C(0x7A7A7A), C(0x4A4A4A), C(0x4A4A4A))
            : new(false, C(0xF3F3F3), C(0xE7E7E7), C(0xFFFFFF), C(0x1B1B1B), C(0x5F5F5F), C(0x8A8A8A), C(0xC4C4C4), C(0xD6D6D6));
    }
    static Color C(int rgb) => Color.FromArgb((rgb >> 16) & 0xFF, (rgb >> 8) & 0xFF, rgb & 0xFF);
}

/// 字型快取（像素單位，跟著 DPI；DPI 一變就整批丟掉）
sealed class BoardFonts : IDisposable
{
    public const string Family = "Microsoft JhengHei UI";
    readonly Dictionary<(int, bool), Font> cache = new();
    public Font Get(double px, bool bold = false)
    {
        int key = (int)Math.Round(px * 4);                     // 0.25 px 一格，避免縮放時每個大小都開一個字型
        if (!cache.TryGetValue((key, bold), out var f))
            cache[(key, bold)] = f = new Font(Family, key / 4f, bold ? FontStyle.Bold : FontStyle.Regular, GraphicsUnit.Pixel);
        return f;
    }
    public void Dispose() { foreach (var f in cache.Values) f.Dispose(); cache.Clear(); }
}

/// 一座島：左邊是島（IslandArt），右邊是每個角色的對話框；上面一行島名＋計數。
/// 這一塊只在資料、大小、主題或滑鼠停留變了才重畫；動畫只動 IslandArt。
sealed class IslandCardView : Control
{
    readonly IslandArt art = new();
    readonly BoardForm owner;
    Island island = new();
    IslandCardLayout L;
    string? lit;                                       // 滑鼠停在哪個角色／對話框
    readonly List<(RectangleF Rect, Islander? Who)> bubbleRects = new();
    RectangleF moreRect;
    string? tipText;

    public IslandArt Art => art;
    public string Project => island.Project;

    public IslandCardView(BoardForm owner)
    {
        this.owner = owner;
        SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw, true);
        SetStyle(ControlStyles.Selectable, false);
        Controls.Add(art);
        art.Hovered += id => SetLit(id);
        art.MouseMove += (_, e) => Tip(art, art.PersonAt(e.Location) is { } id ? island.People.FirstOrDefault(p => p.Id == id) : null);
    }

    float S => DeviceDpi / 96f;

    public void SetIsland(Island next)
    {
        island = next;
        Relayout();
    }

    protected override void OnSizeChanged(EventArgs e) { base.OnSizeChanged(e); Relayout(); }

    void Relayout()
    {
        if (Width <= 0 || Height <= 0) return;
        L = IslandCardLayout.Of(island, Width / S, Height / S);
        var shown = island.People.Take(IslandCardLayout.MaxPeople).ToList();
        var (gw, gh) = L.Geo.Size;
        art.BackColor = owner.Theme.Card;
        art.Bounds = new Rectangle((int)Math.Round(L.IslandX * S), (int)Math.Round(L.IslandY * S),
                                   (int)Math.Ceiling(gw * L.IslandScale * S), (int)Math.Ceiling(gh * L.IslandScale * S));
        art.ReduceMotion = owner.ReduceMotion;
        art.SetIsland(island, shown, L.Geo, L.IslandScale, lit);
        Invalidate();
    }

    public void ThemeChanged() { art.BackColor = owner.Theme.Card; art.ReduceMotion = owner.ReduceMotion; art.Invalidate(); Invalidate(); }

    void SetLit(string? id)
    {
        if (lit == id) return;
        lit = id;
        art.SetFocus(id);
        Invalidate();
    }

    // MARK: 畫

    protected override void OnPaintBackground(PaintEventArgs e) { }

    protected override void OnPaint(PaintEventArgs e)
    {
        if (BoardForm.FaultPaint) throw new InvalidOperationException("SHOWORK_BOARD_FAULT=paint（測試）");
        var g = e.Graphics;
        var th = owner.Theme;
        var fonts = owner.Fonts;
        float s = S;
        g.Clear(th.Back);
        g.SmoothingMode = SmoothingMode.AntiAlias;
        using (var bg = Rounded(new RectangleF(0, 0, Width - 1, Height - 1), 12 * s))
        using (var b = new SolidBrush(th.Card)) g.FillPath(b, bg);
        Header(g, th, fonts, s);
        bubbleRects.Clear();
        moreRect = RectangleF.Empty;
        var fit = L.Fit;
        if (fit == null) return;
        float y = (float)(L.BubbleY * s), x = (float)(L.BubbleX * s), w = (float)(L.BubbleW * s), h = (float)(fit.Height * s);
        foreach (var p in fit.Visible)
        {
            var r = new RectangleF(x, y, w, h);
            Bubble(g, th, fonts, p, r, s);
            bubbleRects.Add((r, p));
            y += h + (float)(BubbleFit.Gap * s);
        }
        if (fit.Hidden.Count > 0 && fit.Visible.Count < fit.Slots)
        {
            // 放不下的不切一半，收成一格（Mac 10-13 Kang：底下被遮掉）；角色還在島上，停在角色上一樣看得到
            moreRect = new RectangleF(x, y, w, h);
            using (var path = Rounded(moreRect, 10 * s))
            using (var pen = new Pen(th.Separator, 1 * s) { DashPattern = new[] { 4f, 3f } }) g.DrawPath(pen, path);
            TextRenderer.DrawText(g, $"還有 {fit.Hidden.Count} 個⋯", fonts.Get(12 * L.TextScale * s), Rectangle.Round(moreRect), th.Secondary,
                                  TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter | TextFormatFlags.NoPrefix);
        }
    }

    void Header(Graphics g, BoardTheme th, BoardFonts fonts, float s)
    {
        float pad = (float)(IslandCardLayout.Pad * s), hh = (float)(IslandCardLayout.HeaderH * s);
        var flags = TextFormatFlags.NoPrefix | TextFormatFlags.VerticalCenter | TextFormatFlags.SingleLine;
        var small = fonts.Get(11 * s);
        // 右邊由右往左排：（+N）（排隊）卡住 做完 進行中「N 件等你」
        float right = Width - pad - 2 * s;
        void Count(Mood m, int n)
        {
            var txt = n.ToString();
            var tw = TextRenderer.MeasureText(g, txt, small, Size.Empty, flags).Width;
            right -= tw;
            TextRenderer.DrawText(g, txt, small, new Rectangle((int)right, (int)pad, tw, (int)hh), th.Secondary, flags);
            right -= 3 * s + 7 * s;
            using var b = new SolidBrush(KuboArt.Tint(m));
            g.FillEllipse(b, right, pad + (hh - 7 * s) / 2, 7 * s, 7 * s);
            right -= 8 * s;
        }
        if (island.People.Count > IslandCardLayout.MaxPeople)
        {
            var txt = $"+{island.People.Count - IslandCardLayout.MaxPeople}";
            var tw = TextRenderer.MeasureText(g, txt, small, Size.Empty, flags).Width;
            right -= tw;
            TextRenderer.DrawText(g, txt, small, new Rectangle((int)right, (int)pad, tw, (int)hh), th.Secondary, flags);
            right -= 8 * s;
        }
        if (island.Queued > 0)
        {
            var txt = $"排隊 {island.Queued}";
            var tw = TextRenderer.MeasureText(g, txt, small, Size.Empty, flags).Width;
            right -= tw;
            TextRenderer.DrawText(g, txt, small, new Rectangle((int)right, (int)pad, tw, (int)hh), th.Secondary, flags);
            right -= 8 * s;
        }
        if (island.Count(Mood.Stuck) > 0) Count(Mood.Stuck, island.Count(Mood.Stuck));
        Count(Mood.Finished, island.Count(Mood.Finished));
        Count(Mood.Working, island.Count(Mood.Working));
        int waiting = island.Count(Mood.Waiting);
        if (waiting > 0)
        {
            var bold = fonts.Get(11 * s, bold: true);
            var txt = $"{waiting} 件等你";
            var nf = flags | TextFormatFlags.NoPadding;
            var sz = TextRenderer.MeasureText(g, txt, bold, Size.Empty, nf);
            float pw = sz.Width + 14 * s, ph = sz.Height + 4 * s;
            var r = new RectangleF(right - pw, pad + (hh - ph) / 2, pw, ph);
            using (var path = Rounded(r, ph / 2))
            using (var b = new SolidBrush(KuboArt.Tint(Mood.Waiting))) g.FillPath(b, path);
            // 字的方框照量到的大小置中放（給太矮的框，正黑體會被裁掉下半）
            TextRenderer.DrawText(g, txt, bold, new Rectangle((int)Math.Round(r.X + (pw - sz.Width) / 2), (int)Math.Round(r.Y + (ph - sz.Height) / 2), sz.Width, sz.Height),
                                  Color.White, nf | TextFormatFlags.NoClipping);
            right = r.Left - 8 * s;
        }
        // 島名：剩下的寬度，放不下就「…」
        var head = fonts.Get(13 * s, bold: true);
        TextRenderer.DrawText(g, island.Project, head, new Rectangle((int)(pad + 2 * s), (int)pad, Math.Max(0, (int)(right - pad - 4 * s)), (int)hh),
                              th.Text, flags | TextFormatFlags.EndEllipsis);
    }

    void Bubble(Graphics g, BoardTheme th, BoardFonts fonts, Islander p, RectangleF r, float s)
    {
        var tint = KuboArt.Tint(p.Mood);
        bool on = lit == p.Id;
        using (var path = BubblePath(r, s))
        {
            using (var b = new SolidBrush(th.Bubble)) g.FillPath(b, path);
            using var pen = new Pen(Color.FromArgb(p.Mood is Mood.Idle or Mood.Asleep ? 89 : 230, tint), (on ? 2.5f : 1.5f) * s);
            g.DrawPath(pen, path);
        }
        double k = L.TextScale;
        bool compact = BubbleFit.Compact(r.Height / s);
        float px = (float)(10 * k * s), py = compact ? 4 * s : (float)(7 * k * s);
        var inner = new RectangleF(r.X + px, r.Y + py, r.Width - px * 2, r.Height - py * 2);
        var save = g.Clip;
        g.SetClip(r);                                      // 字永遠留在框裡（Mac 10-13：小視窗摘要畫到框外）
        float y = inner.Y;
        // 標題（隊長前面一頂小皇冠）
        var titleFont = fonts.Get(13 * k * s, bold: true);
        float tx = inner.X;
        if (p.Card.Captain)
        {
            float cs = (float)(11 * k * s);
            DrawCrown(g, tx, y + 1 * s, cs);
            tx += cs + 5 * s;
        }
        int maxLines = r.Height / s < 80 ? 1 : 2;
        var flags = TextFormatFlags.NoPrefix | TextFormatFlags.WordBreak | TextFormatFlags.EndEllipsis | TextFormatFlags.TextBoxControl;
        int lineH = TextRenderer.MeasureText(g, "國", titleFont, Size.Empty, TextFormatFlags.NoPadding).Height;
        int tw = Math.Max(1, (int)(inner.Right - tx));
        var need = TextRenderer.MeasureText(g, p.Card.Title, titleFont, new Size(tw, int.MaxValue), flags | TextFormatFlags.NoPadding);
        int th1 = Math.Min(need.Height, lineH * maxLines);
        TextRenderer.DrawText(g, p.Card.Title, titleFont, new Rectangle((int)tx, (int)y, tw, th1), th.Text, th.Bubble,
                              (maxLines == 1 ? TextFormatFlags.SingleLine | TextFormatFlags.EndEllipsis | TextFormatFlags.NoPrefix : flags) | TextFormatFlags.NoPadding);
        y += th1 + (compact ? 1 * s : (float)(3 * k * s));
        // 📈 🎯 🧠
        y += Gauges(g, th, fonts, p.Card, inner.X, y, inner.Right, k, s) + (compact ? 0 : (float)(3 * k * s));
        if (!compact && inner.Bottom - y > 4 * s)
        {
            // 不限行數：框多高就顯示多少，放不下才在最後一行「…」
            TextRenderer.DrawText(g, BubbleText.Line(p.Card), fonts.Get(11.5 * k * s),
                                  new Rectangle((int)inner.X, (int)y, (int)inner.Width, (int)(inner.Bottom - y)), th.Secondary, th.Bubble, flags | TextFormatFlags.NoPadding);
        }
        g.Clip = save;
    }

    /// 回傳這一行的高度
    float Gauges(Graphics g, BoardTheme th, BoardFonts fonts, BoardCard c, float x, float y, float right, double k, float s)
    {
        var f = fonts.Get(11 * k * s);
        var flags = TextFormatFlags.NoPrefix | TextFormatFlags.SingleLine | TextFormatFlags.NoPadding;
        int h = TextRenderer.MeasureText(g, "0%", f, Size.Empty, flags).Height;
        float icon = h * 0.92f, gap = (float)(10 * k * s);
        void Item(Action<Graphics, float, float, float> draw, string text, Color color)
        {
            if (x >= right) return;
            draw(g, x, y + (h - icon) / 2, icon);
            x += icon + 4 * s;
            var w = TextRenderer.MeasureText(g, text, f, Size.Empty, flags).Width;
            TextRenderer.DrawText(g, text, f, new Rectangle((int)x, (int)y, Math.Max(0, Math.Min(w, (int)(right - x))), h), color, th.Bubble, flags | TextFormatFlags.EndEllipsis);
            x += w + gap;
        }
        static string Pct(int? v) => v is { } n ? $"{n}%" : "—";
        Item(GaugeIcons.Chart, Pct(BubbleText.Progress(c)), th.Text);
        Item(GaugeIcons.Target, Pct(BubbleText.Confidence(c)), th.Text);
        double limit = ContextGuard.Threshold;
        var ctxColor = c.Ctx is { } x0 ? x0.Percent >= limit ? Color.FromArgb(0xFF, 0x45, 0x3A) : x0.Percent >= Math.Min(70, limit - 10) ? th.Warn : th.Text : th.Text;
        Item(GaugeIcons.Brain, c.Ctx is { } x1 ? $"{(int)x1.Percent}%" : "—", ctxColor);
        return h;
    }

    static void DrawCrown(Graphics g, float x, float y, float size)
    {
        var st = g.Save();
        g.TranslateTransform(x + size / 2, y + size * 0.95f);
        g.ScaleTransform(size / 22f, size / 22f);
        g.TranslateTransform(0, 41);
        using (var p = KuboArt.Crown())
        {
            using (var b = new SolidBrush(Color.FromArgb(255, 199, 61))) g.FillPath(b, p);
            using var pen = new Pen(Color.FromArgb(201, 145, 26), 1.2f) { LineJoin = LineJoin.Round };
            g.DrawPath(pen, p);
        }
        g.Restore(st);
    }

    /// 圓角框＋左邊一個小尾巴（指向島上的角色）
    static GraphicsPath BubblePath(RectangleF r, float s)
    {
        var p = Rounded(r, 10 * s);
        float y = Math.Min(r.Top + 22 * s, r.Top + r.Height / 2);
        p.StartFigure();
        p.AddLines(new[] { new PointF(r.Left + 0.5f * s, y - 6 * s), new PointF(r.Left - 7 * s, y), new PointF(r.Left + 0.5f * s, y + 6 * s) });
        p.FillMode = FillMode.Winding;
        return p;
    }

    public static GraphicsPath Rounded(RectangleF r, float radius)
    {
        var p = new GraphicsPath();
        float d = Math.Min(radius * 2, Math.Min(r.Width, r.Height));
        if (d <= 0) { p.AddRectangle(r); return p; }
        p.AddArc(r.X, r.Y, d, d, 180, 90);
        p.AddArc(r.Right - d, r.Y, d, d, 270, 90);
        p.AddArc(r.Right - d, r.Bottom - d, d, d, 0, 90);
        p.AddArc(r.X, r.Bottom - d, d, d, 90, 90);
        p.CloseFigure();
        return p;
    }

    // MARK: 滑鼠：停在對話框上點亮它和島上的角色、顯示完整內容（唯讀：不跳視窗、沒有按鈕）

    protected override void OnMouseMove(MouseEventArgs e)
    {
        base.OnMouseMove(e);
        var hit = bubbleRects.FirstOrDefault(b => b.Rect.Contains(e.Location));
        SetLit(hit.Who?.Id);
        if (hit.Who != null) Tip(this, hit.Who);
        else if (moreRect.Contains(e.Location))
            SetTip(this, "視窗拉大就看得到：\n" + string.Join("\n", L.Fit.Hidden.Select(h => h.Card.Title)));
        else SetTip(this, null);
    }

    protected override void OnMouseLeave(EventArgs e) { base.OnMouseLeave(e); SetLit(null); SetTip(this, null); }

    void Tip(Control on, Islander? who)
    {
        if (who == null) { SetTip(on, null); return; }
        var c = who.Card;
        var lines = new List<string> { (c.Captain ? "👑 " : "") + c.Title, $"{c.Project}・{c.Reason}" };
        if (c.Report?.Ask is { } ask) lines.Add($"要你決定：{ask}");
        if (c.Report?.Summary is { } sum) lines.Add(sum);
        if (c.Detail is { } d && d != c.Report?.Summary) lines.Add(d.Length > 400 ? d[..400] + "⋯" : d);
        SetTip(on, string.Join("\n", lines));
    }

    void SetTip(Control on, string? text)
    {
        if (text == tipText) return;
        tipText = text;
        owner.Tips.SetToolTip(on, text);
    }
}

/// 📈 🎯 🧠 自己畫（GDI 的 emoji 只有單色，Mac 那邊是彩色）
static class GaugeIcons
{
    public static void Chart(Graphics g, float x, float y, float s)
    {
        var st = g.Save();
        g.SmoothingMode = SmoothingMode.AntiAlias;
        using (var p = IslandCardView.Rounded(new RectangleF(x, y, s, s), s * 0.18f))
        {
            g.FillPath(Brushes.White, p);
            using var border = new Pen(Color.FromArgb(200, 200, 205), Math.Max(1, s * 0.06f));
            g.DrawPath(border, p);
        }
        using (var grid = new Pen(Color.FromArgb(215, 220, 235), Math.Max(1, s * 0.05f)))
            for (int i = 1; i <= 2; i++) g.DrawLine(grid, x + s * 0.12f, y + s * i / 3f, x + s * 0.88f, y + s * i / 3f);
        using (var line = new Pen(Color.FromArgb(232, 59, 59), Math.Max(1.2f, s * 0.12f)) { LineJoin = LineJoin.Round, StartCap = LineCap.Round, EndCap = LineCap.Round })
            g.DrawLines(line, new[] { new PointF(x + s * 0.15f, y + s * 0.78f), new PointF(x + s * 0.4f, y + s * 0.5f), new PointF(x + s * 0.58f, y + s * 0.62f), new PointF(x + s * 0.85f, y + s * 0.2f) });
        g.Restore(st);
    }

    public static void Target(Graphics g, float x, float y, float s)
    {
        var st = g.Save();
        g.SmoothingMode = SmoothingMode.AntiAlias;
        var red = Color.FromArgb(226, 47, 52);
        float[] rs = { 0.48f, 0.36f, 0.24f, 0.12f };
        for (int i = 0; i < rs.Length; i++)
        {
            float r = s * rs[i];
            using var b = new SolidBrush(i % 2 == 0 ? red : Color.White);
            g.FillEllipse(b, x + s / 2 - r, y + s / 2 - r, r * 2, r * 2);
        }
        using (var dart = new Pen(Color.FromArgb(60, 140, 220), Math.Max(1.2f, s * 0.1f)) { EndCap = LineCap.Round, StartCap = LineCap.Round })
            g.DrawLine(dart, x + s / 2, y + s / 2, x + s * 0.98f, y + s * 0.05f);
        g.Restore(st);
    }

    public static void Brain(Graphics g, float x, float y, float s)
    {
        var st = g.Save();
        g.SmoothingMode = SmoothingMode.AntiAlias;
        using (var b = new SolidBrush(Color.FromArgb(246, 160, 184))) g.FillEllipse(b, x, y + s * 0.12f, s, s * 0.78f);
        using (var pen = new Pen(Color.FromArgb(206, 94, 128), Math.Max(1, s * 0.07f)) { StartCap = LineCap.Round, EndCap = LineCap.Round })
        {
            g.DrawLine(pen, x + s / 2, y + s * 0.18f, x + s / 2, y + s * 0.86f);
            g.DrawArc(pen, x + s * 0.12f, y + s * 0.3f, s * 0.3f, s * 0.3f, 200, 200);
            g.DrawArc(pen, x + s * 0.58f, y + s * 0.42f, s * 0.3f, s * 0.3f, 20, 200);
        }
        g.Restore(st);
    }
}
