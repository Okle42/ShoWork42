using System.Drawing.Drawing2D;
using static ShoWork.Native;

namespace ShoWork;

/// The "dynamic island" of the Windows version: a dark rounded panel above the tray icon listing every
/// AI session (state, window, for how long). Click a row to jump to that window. Created on click and
/// disposed when it closes (deactivate, Esc, click outside), so it costs nothing while hidden.
sealed class IslandFlyout : Form
{
    static readonly Color Bg = Color.FromArgb(0x20, 0x20, 0x23), Hover = Color.FromArgb(0x33, 0x33, 0x38),
                          Text1 = Color.FromArgb(0xF2, 0xF2, 0xF5), Text2 = Color.FromArgb(0x9A, 0x9A, 0xA2),
                          Line = Color.FromArgb(0x38, 0x38, 0x3E), IdleDot = Color.FromArgb(0x8E, 0x8E, 0x93);
    const TextFormatFlags One = TextFormatFlags.SingleLine | TextFormatFlags.NoPrefix | TextFormatFlags.VerticalCenter |
                                TextFormatFlags.EndEllipsis | TextFormatFlags.NoPadding;

    readonly Engine engine;
    readonly Rectangle anchor;
    readonly float k;                                  // monitor DPI / 96: layout is in physical pixels
    readonly Font head, main, small;
    readonly System.Windows.Forms.Timer tick = new() { Interval = 1000 };   // "3 秒 → 4 秒" while open only
    readonly IntPtr foregroundAtShow = GetForegroundWindow();
    List<SessionView> rows = new();
    string counts = "";
    int more, hover = -1;
    bool activated;

    int Pad => (int)(12 * k);
    int HeadH => (int)(34 * k);
    int RowH => (int)(48 * k);
    int EmptyH => (int)(56 * k);

    public IslandFlyout(Engine engine, Rectangle anchor)
    {
        this.engine = engine;
        this.anchor = anchor;
        k = TrayPlace.Scale(anchor);
        FormBorderStyle = FormBorderStyle.None;
        AutoScaleMode = AutoScaleMode.None;
        StartPosition = FormStartPosition.Manual;
        ShowInTaskbar = false;
        TopMost = true;
        KeyPreview = true;
        DoubleBuffered = true;
        BackColor = Bg;
        Text = "ShoWork42";
        head = new Font("Microsoft JhengHei UI", 13 * k, FontStyle.Bold, GraphicsUnit.Pixel);
        main = new Font("Microsoft JhengHei UI", 13 * k, FontStyle.Regular, GraphicsUnit.Pixel);
        small = new Font("Microsoft JhengHei UI", 12 * k, FontStyle.Regular, GraphicsUnit.Pixel);
        tick.Tick += (_, _) => OnTick();
        engine.Changed += Reload;
        Reload();
    }

    protected override CreateParams CreateParams
    {
        get { var cp = base.CreateParams; cp.ExStyle |= WS_EX_TOOLWINDOW; return cp; }
    }

    protected override void OnHandleCreated(EventArgs e)
    {
        base.OnHandleCreated(e);
        if (!TrayPlace.RoundCorners(Handle))
        {
            using var p = Rounded(new Rectangle(Point.Empty, Size), 8 * k);
            Region = new Region(p);
        }
    }

    protected override void OnShown(EventArgs e)
    {
        base.OnShown(e);
        SetForegroundWindow(Handle);                   // a tray click lets us take the foreground
        Activate();
        tick.Start();
    }

    protected override void OnActivated(EventArgs e) { base.OnActivated(e); activated = true; }
    protected override void OnDeactivate(EventArgs e) { base.OnDeactivate(e); Close(); }

    /// Also close when Windows refused to activate us and the user has moved on to another window.
    void OnTick()
    {
        var fg = GetForegroundWindow();
        if (!activated && fg != Handle && fg != foregroundAtShow) { Close(); return; }
        Invalidate();
    }

    /// Rows from Engine.Sessions (live while open); resizes and re-anchors when the count changes.
    void Reload()
    {
        if (IsDisposed) return;
        var all = engine.Sessions;
        var wa = Screen.FromRectangle(anchor).WorkingArea;
        int fit = Math.Max(1, (int)((wa.Height * 0.7 - HeadH - Pad) / RowH));
        rows = all.Take(all.Count > fit ? fit - 1 : fit).ToList();
        more = all.Count - rows.Count;
        counts = string.Join("・", new[] { WorkState.Input, WorkState.Done, WorkState.Working }
            .Select(s => (s, n: all.Count(x => x.State == s))).Where(x => x.n > 0)
            .Select(x => $"{TrayPlace.StateText(x.s)} {x.n}"));
        if (hover >= rows.Count) hover = -1;
        int h = HeadH + (rows.Count == 0 ? EmptyH : rows.Count * RowH + (more > 0 ? (int)(28 * k) : 0)) + Pad / 2;
        var size = new Size((int)(340 * k), h);
        var at = TrayPlace.Place(anchor, size, (int)(12 * k));
        if (Bounds != new Rectangle(at, size))
        {
            Bounds = new Rectangle(at, size);
            if (IsHandleCreated && Region != null) { using var p = Rounded(new Rectangle(Point.Empty, Size), 8 * k); Region = new Region(p); }
        }
        Invalidate();
    }

    int RowAt(Point p) => p.Y < HeadH ? -1 : (p.Y - HeadH) / RowH is var i && i < rows.Count ? i : -1;

    protected override void OnMouseMove(MouseEventArgs e)
    {
        base.OnMouseMove(e);
        var i = RowAt(e.Location);
        Cursor = i >= 0 && rows[i].Window != IntPtr.Zero ? Cursors.Hand : Cursors.Default;
        if (i != hover) { hover = i; Invalidate(); }
    }

    protected override void OnMouseLeave(EventArgs e) { base.OnMouseLeave(e); if (hover != -1) { hover = -1; Invalidate(); } }

    protected override void OnMouseClick(MouseEventArgs e)
    {
        base.OnMouseClick(e);
        if (e.Button == MouseButtons.Left && RowAt(e.Location) is var i and >= 0) Jump(rows[i]);
    }

    protected override bool ProcessCmdKey(ref Message msg, Keys key)
    {
        switch (key)
        {
            case Keys.Escape: Close(); return true;
            case Keys.Down when rows.Count > 0: hover = (hover + 1) % rows.Count; Invalidate(); return true;
            case Keys.Up when rows.Count > 0: hover = hover <= 0 ? rows.Count - 1 : hover - 1; Invalidate(); return true;
            case Keys.Enter when rows.Count > 0: Jump(rows[Math.Max(0, hover)]); return true;
        }
        return base.ProcessCmdKey(ref msg, key);
    }

    /// Jump first (we are the foreground, so SetForegroundWindow is allowed), then go away.
    void Jump(SessionView s)
    {
        if (s.Window != IntPtr.Zero) Engine.JumpTo(s.Window);
        Close();
    }

    protected override void OnPaint(PaintEventArgs e)
    {
        var g = e.Graphics;
        g.SmoothingMode = SmoothingMode.AntiAlias;
        int w = ClientSize.Width, pad = Pad;
        // header: name + non-zero counts
        TextRenderer.DrawText(g, "ShoWork42", head, new Rectangle(pad, 0, w / 2, HeadH), Text1, Bg, One);
        TextRenderer.DrawText(g, counts, small, new Rectangle(w / 3, 0, w - w / 3 - pad, HeadH), Text2, Bg, One | TextFormatFlags.Right);
        using (var line = new Pen(Line)) g.DrawLine(line, pad, HeadH - 1, w - pad, HeadH - 1);

        if (rows.Count == 0)
        {
            TextRenderer.DrawText(g, "沒有 AI 在工作", main, new Rectangle(0, HeadH, w, EmptyH), Text2, Bg,
                                  One | TextFormatFlags.HorizontalCenter);
            return;
        }
        int dot = (int)(10 * k), gap = (int)(10 * k);
        for (int i = 0; i < rows.Count; i++)
        {
            var s = rows[i];
            var r = new Rectangle(0, HeadH + i * RowH, w, RowH);
            var bg = i == hover ? Hover : Bg;
            if (i == hover)
            {
                using var hb = new SolidBrush(Hover);
                using var hp = Rounded(Rectangle.Inflate(r, -pad / 2, -(int)(2 * k)), 6 * k);
                g.FillPath(hb, hp);
            }
            var c = s.State == WorkState.Idle ? IdleDot : GlowWindow.ColorOf(s.State);
            using (var b = new SolidBrush(c)) g.FillEllipse(b, pad, r.Top + (RowH - dot) / 2f, dot, dot);
            int x = pad + dot + gap, half = RowH / 2;
            var ago = TrayPlace.Ago(s.Since);
            var agoW = TrayPlace.TextWidth(ago, small);
            TextRenderer.DrawText(g, TrayPlace.StateText(s.State), head, new Rectangle(x, r.Top + (int)(4 * k), w - x - agoW - 2 * pad, half - (int)(2 * k)), c, bg, One);
            TextRenderer.DrawText(g, ago, small, new Rectangle(w - pad - agoW, r.Top + (int)(4 * k), agoW, half - (int)(2 * k)), Text2, bg, One);
            var title = s.Title.Length > 0 ? s.Title : s.Window == IntPtr.Zero ? "（還在找視窗…）" : "（沒有標題）";
            TextRenderer.DrawText(g, title, main, new Rectangle(x, r.Top + half, w - x - pad, half - (int)(6 * k)),
                                  s.Title.Length > 0 ? Text1 : Text2, bg, One);
        }
        if (more > 0)
            TextRenderer.DrawText(g, $"還有 {more} 個…", small, new Rectangle(pad, HeadH + rows.Count * RowH, w - 2 * pad, (int)(28 * k)),
                                  Text2, Bg, One);
    }

    static GraphicsPath Rounded(RectangleF r, float rad)
    {
        var p = new GraphicsPath();
        float d = rad * 2;
        p.AddArc(r.Left, r.Top, d, d, 180, 90);
        p.AddArc(r.Right - d, r.Top, d, d, 270, 90);
        p.AddArc(r.Right - d, r.Bottom - d, d, d, 0, 90);
        p.AddArc(r.Left, r.Bottom - d, d, d, 90, 90);
        p.CloseFigure();
        return p;
    }

    /// Laid out for its monitor's DPI before creation; ignore WinForms' rescale if it is dragged across.
    protected override void WndProc(ref Message m)
    {
        if (m.Msg == TrayPlace.WM_DPICHANGED) { m.Result = IntPtr.Zero; return; }
        base.WndProc(ref m);
    }

    protected override void OnFormClosed(FormClosedEventArgs e)
    {
        engine.Changed -= Reload;
        tick.Stop();
        base.OnFormClosed(e);
    }

    protected override void Dispose(bool disposing)
    {
        if (disposing) { engine.Changed -= Reload; tick.Dispose(); head.Dispose(); main.Dispose(); small.Dispose(); }
        base.Dispose(disposing);
    }
}
