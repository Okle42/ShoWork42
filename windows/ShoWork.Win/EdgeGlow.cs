using System.Drawing;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;
using static ShoWork.Native;

namespace ShoWork;

/// Mac EdgeGlow: while the foreground window covers its whole monitor (game, video, F11 browser, WT full
/// screen) every other glow on that monitor is buried behind it. Then the most urgent green/red among the
/// windows you can't see becomes a thin line along that monitor's edges. Purple never shows here.
///
/// Four thin topmost strips instead of one monitor-sized layered window: a few KB of bitmap, not 8 MB.
/// Drawn once per (monitor, state, DPI); nothing animates, so no timer.
sealed class EdgeGlow : IDisposable
{
    readonly EdgeStrip[] strips = new EdgeStrip[4];
    (Rectangle mon, WorkState state, int dpi, Color color)? shown;   // colour too: the settings page can change it while shown
    IntPtr raisedOver;                       // foreground window the strips were last put above
    bool disposed;                           // a render queued before Stop can still arrive afterwards

    /// What the edge shows now (Idle = hidden), for the status file.
    public WorkState State => shown?.state ?? WorkState.Idle;

    /// Cheap (a handful of user32 calls): called on every render, foreground change and watchdog tick.
    /// Returns whether what the edge shows changed.
    public bool Update(IEnumerable<GlowWindow> glows)
    {
        var was = State;
        Apply(glows);
        return State != was;
    }

    void Apply(IEnumerable<GlowWindow> glows)
    {
        if (disposed) return;
        var front = GetForegroundWindow();
        var mon = FullScreenMonitor(front);
        if (mon == IntPtr.Zero) { Hide(); return; }
        var s = StateMachine.WindowState(glows
            .Where(g => !g.IsDisposed && g.Target != front && g.State is WorkState.Done or WorkState.Input && Buried(g.Target, mon))
            .Select(g => g.State));
        if (s is not (WorkState.Done or WorkState.Input)) { Hide(); return; }
        var mi = new MONITORINFO { cbSize = Marshal.SizeOf<MONITORINFO>() };
        GetMonitorInfo(mon, ref mi);
        int dpi = GetDpiForMonitor(mon, 0 /*MDT_EFFECTIVE_DPI*/, out var dx, out _) == 0 ? (int)dx : 96;
        Show(mi.rcMonitor, s, dpi, front);
    }

    /// The monitor `hwnd` fills exactly (0 = not full screen). A maximised captioned window can overhang the
    /// monitor by its resize borders when the taskbar auto-hides; that is not full screen.
    static IntPtr FullScreenMonitor(IntPtr hwnd)
    {
        if (hwnd == IntPtr.Zero || !IsWindowVisible(hwnd) || IsIconic(hwnd) || IsCloaked(hwnd)) return IntPtr.Zero;
        // the desktop covers every monitor; Alt+Tab / Task View / Start take the foreground with a monitor-sized shell window
        if (ClassOf(hwnd) is "Progman" or "WorkerW" or "Shell_TrayWnd" or "Shell_SecondaryTrayWnd" or "MultitaskingViewFrame"
            or "XamlExplorerHostIslandWindow" or "ForegroundStaging" or "Windows.UI.Core.CoreWindow") return IntPtr.Zero;
        if (IsZoomed(hwnd) && (GetWindowLong(hwnd, GWL_STYLE) & WS_CAPTION) == WS_CAPTION) return IntPtr.Zero;
        var mon = MonitorFromWindow(hwnd, MONITOR_DEFAULTTONULL);
        if (mon == IntPtr.Zero) return IntPtr.Zero;
        var mi = new MONITORINFO { cbSize = Marshal.SizeOf<MONITORINFO>() };
        if (!GetMonitorInfo(mon, ref mi) || !GetWindowRect(hwnd, out var r)) return IntPtr.Zero;
        var m = mi.rcMonitor;
        return r.Left <= m.Left && r.Top <= m.Top && r.Right >= m.Right && r.Bottom >= m.Bottom ? mon : IntPtr.Zero;
    }

    /// Can't be seen: behind the full-screen window on its monitor, minimised, or on another virtual desktop.
    /// A glowing window on another monitor is still visible, so it doesn't count (Mac: !targetOnScreen).
    static bool Buried(IntPtr target, IntPtr fullScreenMonitor) =>
        IsIconic(target) || !IsWindowVisible(target) || IsCloaked(target) || MonitorFromWindow(target, MONITOR_DEFAULTTONEAREST) == fullScreenMonitor;

    void Show(RECT m, WorkState s, int dpi, IntPtr front)
    {
        int line = Math.Max(1, (int)Math.Round(3 * dpi / 96.0)), soft = (int)Math.Round(8 * dpi / 96.0), t = line + soft;
        int w = m.Right - m.Left, h = m.Bottom - m.Top;
        var key = Rectangle.FromLTRB(m.Left, m.Top, m.Right, m.Bottom);
        var color = GlowWindow.ColorOf(s);
        bool redraw = shown != (key, s, dpi, color);
        if (redraw)
        {
            shown = (key, s, dpi, color);
            // top / bottom full width, left / right in between: every pixel's alpha follows its distance to the nearest edge
            var parts = new[] { new Rectangle(0, 0, w, t), new Rectangle(0, h - t, w, t), new Rectangle(0, t, t, h - 2 * t), new Rectangle(w - t, t, t, h - 2 * t) };
            for (int i = 0; i < 4; i++)
            {
                if (strips[i] == null) { strips[i] = new EdgeStrip(); strips[i].Show(); }   // shown empty first, as GlowWindow: WinForms' first show must not resize a painted layer
                strips[i].Draw(m.Left, m.Top, w, h, parts[i], line, soft, color);
            }
            Log.Note($"EDGE {s} monitor={m.Left},{m.Top},{m.Right},{m.Bottom} line={line}");
        }
        // re-assert topmost only when drawn or the front window changed (a topmost full-screen player may have
        // come up since), not on every watchdog tick
        if (!redraw && front == raisedOver) return;
        raisedOver = front;
        foreach (var x in strips) x.Raise();
    }

    public void Hide()
    {
        if (shown == null) return;
        shown = null;
        foreach (var x in strips) x?.Conceal();
        Log.Note("EDGE hidden");
    }

    public void Dispose()
    {
        disposed = true;
        shown = null;
        for (int i = 0; i < strips.Length; i++) { strips[i]?.Dispose(); strips[i] = null!; }
    }

    /// One edge strip: click-through, topmost, never activated.
    sealed class EdgeStrip : Form
    {
        public EdgeStrip()
        {
            FormBorderStyle = FormBorderStyle.None;
            ShowInTaskbar = false;
            StartPosition = FormStartPosition.Manual;
        }

        protected override bool ShowWithoutActivation => true;

        /// Draw gives UpdateLayeredWindow the exact physical rect; WinForms applying a rescaled suggested rect
        /// after a DPI change would shift or resize the layer until the next redraw.
        protected override void WndProc(ref Message m)
        {
            if (m.Msg == 0x02E0 /*WM_DPICHANGED*/) { m.Result = IntPtr.Zero; return; }
            base.WndProc(ref m);
        }

        protected override CreateParams CreateParams
        {
            get
            {
                var cp = base.CreateParams;
                cp.ExStyle |= WS_EX_LAYERED | WS_EX_TRANSPARENT | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE | WS_EX_TOPMOST;
                return cp;
            }
        }

        /// `part` is in monitor-relative pixels; alpha: solid line, then quadratic fall-off inwards (Mac: 3 pt line + 6 pt shadow).
        public void Draw(int left, int top, int w, int h, Rectangle part, int line, int soft, Color c)
        {
            if (part.Width <= 0 || part.Height <= 0) return;
            using var bmp = new Bitmap(part.Width, part.Height, PixelFormat.Format32bppPArgb);
            var data = bmp.LockBits(new Rectangle(0, 0, part.Width, part.Height), ImageLockMode.WriteOnly, bmp.PixelFormat);
            var px = new int[part.Width * part.Height];
            for (int y = 0; y < part.Height; y++)
                for (int x = 0; x < part.Width; x++)
                {
                    int ax = part.X + x, ay = part.Y + y;
                    int d = Math.Min(Math.Min(ax, ay), Math.Min(w - 1 - ax, h - 1 - ay));
                    int a = d < line ? 230 : (int)(150 * Math.Pow(1 - (d - line + 1) / (double)(soft + 1), 2));
                    if (a <= 0) continue;
                    px[y * part.Width + x] = a << 24 | c.R * a / 255 << 16 | c.G * a / 255 << 8 | c.B * a / 255;
                }
            Marshal.Copy(px, 0, data.Scan0, px.Length);
            bmp.UnlockBits(data);

            var screen = GetDC(IntPtr.Zero);
            var mem = CreateCompatibleDC(screen);
            var hbmp = bmp.GetHbitmap(Color.FromArgb(0));
            var old = SelectObject(mem, hbmp);
            var dst = new POINT(left + part.X, top + part.Y);
            var sz = new SIZE(part.Width, part.Height);
            var src = new POINT(0, 0);
            var blend = new BLENDFUNCTION { BlendOp = AC_SRC_OVER, SourceConstantAlpha = 255, AlphaFormat = AC_SRC_ALPHA };
            UpdateLayeredWindow(Handle, screen, ref dst, ref sz, mem, ref src, 0, ref blend, ULW_ALPHA);
            SelectObject(mem, old);
            DeleteObject(hbmp);
            DeleteDC(mem);
            ReleaseDC(IntPtr.Zero, screen);
        }

        public void Raise()
        {
            SetWindowPos(Handle, HWND_TOPMOST, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE | SWP_SHOWWINDOW);
            Visible = true;
        }

        public void Conceal()
        {
            if (!Visible) return;
            SetWindowPos(Handle, IntPtr.Zero, 0, 0, 0, 0, SWP_HIDEWINDOW | SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE);
            Visible = false;
        }
    }

    // Win32 used only here (kept out of Native.cs so parallel branches merge cleanly)
    [StructLayout(LayoutKind.Sequential)]
    struct MONITORINFO { public int cbSize; public RECT rcMonitor, rcWork; public uint dwFlags; }
    const int WS_EX_TOPMOST = 0x8, GWL_STYLE = -16, WS_CAPTION = 0xC00000;
    const uint MONITOR_DEFAULTTONULL = 0, MONITOR_DEFAULTTONEAREST = 2;
    static readonly IntPtr HWND_TOPMOST = new(-1);
    [DllImport("user32.dll")] static extern IntPtr MonitorFromWindow(IntPtr hwnd, uint flags);
    [DllImport("user32.dll")] static extern bool GetMonitorInfo(IntPtr mon, ref MONITORINFO mi);
    [DllImport("user32.dll")] static extern bool IsZoomed(IntPtr hwnd);
    [DllImport("user32.dll")] static extern int GetWindowLong(IntPtr hwnd, int index);
    [DllImport("shcore.dll")] static extern int GetDpiForMonitor(IntPtr mon, int type, out uint dpiX, out uint dpiY);
}
