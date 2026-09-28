using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using static ShoWork.Native;

namespace ShoWork;

/// The island "expanding": a small capsule that pops up just above the tray when a session finishes or
/// needs an answer — 「● Claude 完成了  window title」. Never takes focus (NOACTIVATE, shown without
/// activation, MA_NOACTIVATE), fades in, hides itself after ~4 s (not while the mouse is on it), and a
/// click jumps to that window. Per-pixel-alpha layered window, like the glow; disposed when hidden.
sealed class IslandPill : Form
{
    static readonly Color Bg = Color.FromArgb(0x20, 0x20, 0x23), Text1 = Color.FromArgb(0xF2, 0xF2, 0xF5),
                          Text2 = Color.FromArgb(0xA8, 0xA8, 0xB0), Edge = Color.FromArgb(0x48, 0x48, 0x50);
    const TextFormatFlags One = TextFormatFlags.SingleLine | TextFormatFlags.NoPrefix | TextFormatFlags.VerticalCenter |
                                TextFormatFlags.EndEllipsis | TextFormatFlags.NoPadding;
    const int WS_EX_TOPMOST = 0x8, WM_MOUSEACTIVATE = 0x21, MA_NOACTIVATE = 3;
    const int FadeSteps = 8;

    readonly Func<int, IntPtr> windowOf;              // pid → its window now (it may resolve after the pill shows)
    readonly System.Windows.Forms.Timer fade = new() { Interval = 16 };
    readonly System.Windows.Forms.Timer hold = new() { Interval = 4000 };
    int step, dir;                                    // fade progress 0..FadeSteps, +1 in / -1 out / 0 still
    Bitmap? art;
    Point at;

    public int Pid { get; private set; }

    public IslandPill(Func<int, IntPtr> windowOf)
    {
        this.windowOf = windowOf;
        FormBorderStyle = FormBorderStyle.None;
        AutoScaleMode = AutoScaleMode.None;
        StartPosition = FormStartPosition.Manual;
        ShowInTaskbar = false;
        Text = "ShoWork42";
        fade.Tick += (_, _) => Fade();
        hold.Tick += (_, _) => { hold.Stop(); dir = -1; fade.Start(); };
    }

    protected override bool ShowWithoutActivation => true;

    protected override CreateParams CreateParams
    {
        get
        {
            var cp = base.CreateParams;
            cp.ExStyle |= WS_EX_LAYERED | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE | WS_EX_TOPMOST;
            return cp;
        }
    }

    /// Show (or retarget, if already up) for `s`; `extra` = how many other sessions arrived in the same burst.
    public void Pop(SessionView s, int extra, Rectangle anchor)
    {
        Pid = s.Pid;
        float k = TrayPlace.Scale(anchor);
        art?.Dispose();
        art = Draw(s, extra, k);
        at = TrayPlace.Place(anchor, art.Size, (int)(12 * k));
        Bounds = new Rectangle(at, art.Size);
        if (!Visible) { step = 0; Show(); }
        dir = step < FadeSteps ? 1 : 0;
        Blit();
        if (dir != 0) fade.Start();
        hold.Stop();
        hold.Start();
    }

    static Bitmap Draw(SessionView s, int extra, float k)
    {
        int h = (int)(38 * k), pad = (int)(15 * k), dot = (int)(10 * k), gap = (int)(9 * k), maxW = (int)(380 * k);
        using var bold = new Font("Microsoft JhengHei UI", 13 * k, FontStyle.Bold, GraphicsUnit.Pixel);
        using var reg = new Font("Microsoft JhengHei UI", 13 * k, FontStyle.Regular, GraphicsUnit.Pixel);
        var head = $"{TrayPlace.AgentName(s.Agent)} {(s.State == WorkState.Input ? "在等你回答" : "完成了")}" + (extra > 0 ? $" +{extra}" : "");
        var headW = TrayPlace.TextWidth(head, bold);
        var titleW = s.Title.Length == 0 ? 0 : Math.Min(TrayPlace.TextWidth(s.Title, reg), maxW - 2 * pad - dot - 2 * gap - headW);
        titleW = Math.Max(0, titleW);
        int w = pad + dot + gap + headW + (titleW > 0 ? gap + titleW : 0) + pad;

        // opaque first: GDI text (font fallback for ✳ and the like, ClearType-grade) can't write alpha,
        // then the capsule shape is cut out of it with an anti-aliased texture fill
        using var flat = new Bitmap(w, h, PixelFormat.Format32bppRgb);
        using (var g = Graphics.FromImage(flat))
        {
            g.Clear(Bg);
            g.SmoothingMode = SmoothingMode.AntiAlias;
            using (var b = new SolidBrush(GlowWindow.ColorOf(s.State))) g.FillEllipse(b, pad, (h - dot) / 2f, dot, dot);
            int x = pad + dot + gap;
            TextRenderer.DrawText(g, head, bold, new Rectangle(x, 0, headW, h), Text1, Bg, One);
            if (titleW > 0) TextRenderer.DrawText(g, s.Title, reg, new Rectangle(x + headW + gap, 0, titleW, h), Text2, Bg, One);
        }
        var art = new Bitmap(w, h, PixelFormat.Format32bppPArgb);
        using (var g = Graphics.FromImage(art))
        {
            g.SmoothingMode = SmoothingMode.AntiAlias;
            g.Clear(Color.Transparent);
            using var path = Capsule(new RectangleF(0.5f, 0.5f, w - 1, h - 1));
            using var tex = new TextureBrush(flat);
            g.FillPath(tex, path);
            using var edge = new Pen(Edge, Math.Max(1f, k));
            g.DrawPath(edge, path);
        }
        return art;
    }

    static GraphicsPath Capsule(RectangleF r)
    {
        var p = new GraphicsPath();
        float d = r.Height;
        p.AddArc(r.Left, r.Top, d, d, 90, 180);
        p.AddArc(r.Right - d, r.Top, d, d, 270, 180);
        p.CloseFigure();
        return p;
    }

    byte Alpha => (byte)(255 * step / FadeSteps);

    void Blit()
    {
        if (art == null || !IsHandleCreated) return;
        var screen = GetDC(IntPtr.Zero);
        var mem = CreateCompatibleDC(screen);
        var hbmp = art.GetHbitmap(Color.FromArgb(0));
        var old = SelectObject(mem, hbmp);
        var dst = at;
        var pdst = new POINT(dst.X, dst.Y);
        var sz = new SIZE(art.Width, art.Height);
        var src = new POINT(0, 0);
        var blend = new BLENDFUNCTION { BlendOp = AC_SRC_OVER, SourceConstantAlpha = Alpha, AlphaFormat = AC_SRC_ALPHA };
        UpdateLayeredWindow(Handle, screen, ref pdst, ref sz, mem, ref src, 0, ref blend, ULW_ALPHA);
        SelectObject(mem, old);
        DeleteObject(hbmp);
        DeleteDC(mem);
        ReleaseDC(IntPtr.Zero, screen);
    }

    /// ~130 ms fade in or out; only the layer alpha changes. The timer runs only while fading.
    void Fade()
    {
        step = Math.Clamp(step + dir, 0, FadeSteps);
        var blend = new BLENDFUNCTION { BlendOp = AC_SRC_OVER, SourceConstantAlpha = Alpha, AlphaFormat = AC_SRC_ALPHA };
        UpdateLayeredWindowBlend(Handle, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, 0, ref blend, ULW_ALPHA);
        if (dir > 0 && step == FadeSteps) { fade.Stop(); dir = 0; }
        else if (dir < 0 && step == 0) { fade.Stop(); Close(); }
    }

    protected override void OnMouseEnter(EventArgs e)
    {
        base.OnMouseEnter(e);
        hold.Stop();
        if (dir < 0) dir = 1;                         // caught while fading out: come back
        if (dir != 0) fade.Start();
    }

    protected override void OnMouseLeave(EventArgs e) { base.OnMouseLeave(e); hold.Start(); }

    /// We received the click, so Windows lets us bring the target forward.
    protected override void OnMouseClick(MouseEventArgs e)
    {
        base.OnMouseClick(e);
        if (e.Button == MouseButtons.Left) Engine.JumpTo(windowOf(Pid));
        Close();
    }

    protected override void WndProc(ref Message m)
    {
        if (m.Msg == WM_MOUSEACTIVATE) { m.Result = MA_NOACTIVATE; return; }
        if (m.Msg == TrayPlace.WM_DPICHANGED) { m.Result = IntPtr.Zero; return; }
        base.WndProc(ref m);
    }

    protected override void Dispose(bool disposing)
    {
        if (disposing) { fade.Dispose(); hold.Dispose(); art?.Dispose(); }
        base.Dispose(disposing);
    }
}
