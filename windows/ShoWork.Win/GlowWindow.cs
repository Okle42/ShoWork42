using System.Drawing;
using System.Drawing.Drawing2D;
using static ShoWork.Native;

namespace ShoWork;

/// The glow around one target window: a click-through, never-activated layered window kept directly
/// BELOW the target in z-order, so the target covers the middle and only the ring around it shows
/// (same idea as the Mac version's `order(.below, relativeTo:)`).
///
/// Cost model: the ring bitmap is drawn only when the target's SIZE or the state changes. Moving is a
/// SetWindowPos; breathing only changes the layer's constant alpha (UpdateLayeredWindow without a
/// bitmap) — nothing is re-rendered per frame.
sealed class GlowWindow : Form
{
    public IntPtr Target { get; }
    public WorkState State { get; private set; }

    int pad;                                  // physical px around the window, scaled with the target's DPI
    Size ringSize;                            // target size the current bitmap was drawn for
    byte alpha = 255;
    readonly System.Windows.Forms.Timer breathe = new() { Interval = 33 };   // ~30 fps is plenty for a 3.2 s breath
    readonly DateTime born = DateTime.Now;

    public GlowWindow(IntPtr target, WorkState state)
    {
        Target = target;
        State = state;
        FormBorderStyle = FormBorderStyle.None;
        ShowInTaskbar = false;
        StartPosition = FormStartPosition.Manual;
        breathe.Tick += (_, _) => Breathe();
    }

    protected override bool ShowWithoutActivation => true;

    protected override CreateParams CreateParams
    {
        get
        {
            var cp = base.CreateParams;
            cp.ExStyle |= WS_EX_LAYERED | WS_EX_TRANSPARENT | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE;
            return cp;
        }
    }

    public static Color ColorOf(WorkState s) => s switch
    {
        WorkState.Working => Color.FromArgb(0xA8, 0x6B, 0xFF),   // purple
        WorkState.Done => Color.FromArgb(0x30, 0xD1, 0x58),      // green #30D158
        WorkState.Input => Color.FromArgb(0xFF, 0x45, 0x3A),     // red
        _ => Color.Transparent,
    };

    public void SetState(WorkState s)
    {
        if (s == State) return;
        State = s;
        ringSize = Size.Empty;                 // force a repaint in the new colour
        Sync();
    }

    /// Put the ring exactly around the target and directly below it. Called on move/resize/reorder
    /// events and by the watchdog. Hides itself while the target is minimised, hidden or cloaked.
    public void Sync()
    {
        if (!IsWindow(Target)) { Close(); return; }
        if (State == WorkState.Idle || IsIconic(Target) || !IsWindowVisible(Target) || IsCloaked(Target))
        {
            Log.Note($"HIDE {Target} idle={State == WorkState.Idle} iconic={IsIconic(Target)} visible={IsWindowVisible(Target)} cloaked={IsCloaked(Target)}");
            if (Visible) { SetWindowPos(Handle, IntPtr.Zero, 0, 0, 0, 0, SWP_HIDEWINDOW | SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE); Visible = false; }
            breathe.Stop();
            return;
        }
        var r = VisibleRect(Target);
        var size = new Size(r.Right - r.Left, r.Bottom - r.Top);
        pad = (int)(40 * GetDpiForWindow(Target) / 96.0);
        if (size != ringSize) Render(size);
        // hWndInsertAfter = target ⇒ we go right after (= below) it
        SetWindowPos(Handle, Target, r.Left - pad, r.Top - pad, size.Width + 2 * pad, size.Height + 2 * pad,
                     SWP_NOACTIVATE | SWP_SHOWWINDOW);
        Visible = true;
        Log.Note($"SHOW {Target} rect={r.Left},{r.Top},{r.Right},{r.Bottom} pad={pad} below={NextVisibleBelow(Target) == Handle} glowVisible={IsWindowVisible(Handle)}");
        if (!breathe.Enabled) breathe.Start();
    }

    /// Is the glow still the first visible window below its target? (a few GetWindow calls)
    public bool StackedRight => !Visible || NextVisibleBelow(Target) == Handle;

    void Render(Size target)
    {
        ringSize = target;
        int w = target.Width + 2 * pad, h = target.Height + 2 * pad;
        using var bmp = new Bitmap(w, h, System.Drawing.Imaging.PixelFormat.Format32bppPArgb);
        using (var g = Graphics.FromImage(bmp))
        {
            g.SmoothingMode = SmoothingMode.AntiAlias;
            g.Clear(Color.Transparent);
            var c = ColorOf(State);
            float radius = 8 * GetDpiForWindow(Target) / 96f;            // Windows 11 window corners
            var inner = new RectangleF(pad, pad, target.Width, target.Height);
            // soft outer glow: rings from the edge outwards, alpha falling off quadratically
            for (int i = pad; i >= 1; i--)
            {
                float t = 1 - i / (float)pad;
                int a = (int)(150 * t * t);
                if (a <= 0) continue;
                using var pen = new Pen(Color.FromArgb(a, c), 2f);
                using var path = Rounded(RectangleF.Inflate(inner, i, i), radius + i);
                g.DrawPath(pen, path);
            }
            // crisp edge ring right at the window border
            using var edge = new Pen(Color.FromArgb(235, c), 3f * GetDpiForWindow(Target) / 96f);
            using var ep = Rounded(RectangleF.Inflate(inner, 1, 1), radius + 1);
            g.DrawPath(edge, ep);
        }
        var screen = GetDC(IntPtr.Zero);
        var mem = CreateCompatibleDC(screen);
        var hbmp = bmp.GetHbitmap(Color.FromArgb(0));
        var old = SelectObject(mem, hbmp);
        var r = VisibleRect(Target);
        var dst = new POINT(r.Left - pad, r.Top - pad);
        var sz = new SIZE(w, h);
        var src = new POINT(0, 0);
        var blend = new BLENDFUNCTION { BlendOp = AC_SRC_OVER, SourceConstantAlpha = alpha, AlphaFormat = AC_SRC_ALPHA };
        UpdateLayeredWindow(Handle, screen, ref dst, ref sz, mem, ref src, 0, ref blend, ULW_ALPHA);
        SelectObject(mem, old);
        DeleteObject(hbmp);
        DeleteDC(mem);
        ReleaseDC(IntPtr.Zero, screen);
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

    /// Mac version: purple breathes (3.2 s), green steady, red gentle pulse.
    void Breathe()
    {
        double t = (DateTime.Now - born).TotalSeconds;
        double k = State switch
        {
            WorkState.Working => 0.55 + 0.45 * (0.5 + 0.5 * Math.Sin(t * 2 * Math.PI / 3.2)),
            WorkState.Input => 0.75 + 0.25 * (0.5 + 0.5 * Math.Sin(t * 2 * Math.PI / 1.2)),
            _ => 1.0,
        };
        byte a = (byte)(255 * k);
        if (a == alpha) return;
        alpha = a;
        var blend = new BLENDFUNCTION { BlendOp = AC_SRC_OVER, SourceConstantAlpha = alpha, AlphaFormat = AC_SRC_ALPHA };
        UpdateLayeredWindowBlend(Handle, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, 0, ref blend, ULW_ALPHA);
    }

    protected override void Dispose(bool disposing)
    {
        if (disposing) breathe.Dispose();
        base.Dispose(disposing);
    }
}
