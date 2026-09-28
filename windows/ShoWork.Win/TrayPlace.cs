using System.Reflection;
using System.Runtime.InteropServices;
using static ShoWork.Native;

namespace ShoWork;

/// Where the notification area is, so the island flyout and the pill can open next to it wherever the
/// taskbar is (bottom/top/left/right, any monitor, any DPI). All coordinates are physical pixels (PerMonitorV2).
static class TrayPlace
{
    public enum Edge { Bottom, Top, Left, Right }

    [StructLayout(LayoutKind.Sequential)]
    struct NOTIFYICONIDENTIFIER { public uint cbSize; public IntPtr hWnd; public uint uID; public Guid guidItem; }

    [DllImport("shell32.dll")] static extern int Shell_NotifyIconGetRect(ref NOTIFYICONIDENTIFIER id, out RECT r);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern IntPtr FindWindow(string cls, string? title);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern IntPtr FindWindowEx(IntPtr parent, IntPtr after, string cls, string? title);
    [DllImport("user32.dll")] static extern IntPtr MonitorFromRect(ref RECT r, uint flags);
    [DllImport("shcore.dll")] static extern int GetDpiForMonitor(IntPtr mon, int type, out uint x, out uint y);
    [DllImport("dwmapi.dll")] static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int v, int size);

    /// The tray icon's own rect. WinForms keeps the icon's window and id private; reading them by type is
    /// cheap and falls back to the notification area when a future WinForms renames things.
    public static Rectangle? IconRect(NotifyIcon icon)
    {
        try
        {
            IntPtr hwnd = IntPtr.Zero; uint id = 0; bool gotId = false;
            foreach (var f in typeof(NotifyIcon).GetFields(BindingFlags.Instance | BindingFlags.NonPublic))
            {
                var v = f.GetValue(icon);
                if (v is NativeWindow nw) hwnd = nw.Handle;
                else if (!gotId && f.Name.TrimStart('_').Equals("id", StringComparison.OrdinalIgnoreCase) && v is uint or int)
                { id = Convert.ToUInt32(v); gotId = true; }
            }
            if (hwnd == IntPtr.Zero || !gotId) return null;
            var nid = new NOTIFYICONIDENTIFIER { cbSize = (uint)Marshal.SizeOf<NOTIFYICONIDENTIFIER>(), hWnd = hwnd, uID = id };
            if (Shell_NotifyIconGetRect(ref nid, out var r) != 0 || r.Right <= r.Left) return null;
            return Rectangle.FromLTRB(r.Left, r.Top, r.Right, r.Bottom);
        }
        catch { return null; }
    }

    /// The icon if Windows says where it is (it may sit in the hidden-icons overflow), else the whole
    /// notification area of the main taskbar, else a point near the corner of the primary work area.
    public static Rectangle Anchor(NotifyIcon icon)
    {
        if (IconRect(icon) is { } r && Screen.AllScreens.Any(s => s.Bounds.IntersectsWith(r))) return r;
        var tray = FindWindow("Shell_TrayWnd", null);
        var notify = tray == IntPtr.Zero ? IntPtr.Zero : FindWindowEx(tray, IntPtr.Zero, "TrayNotifyWnd", null);
        if (notify != IntPtr.Zero && GetWindowRect(notify, out var n) && n.Right > n.Left)
            return Rectangle.FromLTRB(n.Left, n.Top, n.Right, n.Bottom);
        var wa = Screen.PrimaryScreen!.WorkingArea;
        return new Rectangle(wa.Right - 1, wa.Bottom - 1, 1, 1);
    }

    /// Which screen edge the taskbar holding `anchor` is on: the side the work area gives up, or (auto-hide
    /// taskbar, work area = whole screen) the edge nearest to the anchor.
    public static Edge EdgeOf(Rectangle anchor)
    {
        var s = Screen.FromRectangle(anchor);
        Rectangle b = s.Bounds, wa = s.WorkingArea;
        if (wa.Bottom < b.Bottom && anchor.Top >= wa.Bottom - 1) return Edge.Bottom;
        if (wa.Top > b.Top && anchor.Bottom <= wa.Top + 1) return Edge.Top;
        if (wa.Left > b.Left && anchor.Right <= wa.Left + 1) return Edge.Left;
        if (wa.Right < b.Right && anchor.Left >= wa.Right - 1) return Edge.Right;
        int cx = anchor.Left + anchor.Width / 2, cy = anchor.Top + anchor.Height / 2;
        var d = new[] { (Edge.Bottom, b.Bottom - cy), (Edge.Top, cy - b.Top), (Edge.Left, cx - b.Left), (Edge.Right, b.Right - cx) };
        return d.MinBy(x => x.Item2).Item1;
    }

    /// Top-left for a `size` window beside the taskbar, centred on the anchor and kept inside the work area.
    public static Point Place(Rectangle anchor, Size size, int gap)
    {
        var s = Screen.FromRectangle(anchor);
        var wa = s.WorkingArea;
        int cx = anchor.Left + anchor.Width / 2, cy = anchor.Top + anchor.Height / 2;
        int ClampX(int x) => Math.Max(wa.Left + gap, Math.Min(x, wa.Right - size.Width - gap));
        int ClampY(int y) => Math.Max(wa.Top + gap, Math.Min(y, wa.Bottom - size.Height - gap));
        return EdgeOf(anchor) switch
        {
            Edge.Top => new Point(ClampX(cx - size.Width / 2), Math.Max(wa.Top, anchor.Bottom) + gap),
            Edge.Left => new Point(Math.Max(wa.Left, anchor.Right) + gap, ClampY(cy - size.Height / 2)),
            Edge.Right => new Point(Math.Min(wa.Right, anchor.Left) - size.Width - gap, ClampY(cy - size.Height / 2)),
            _ => new Point(ClampX(cx - size.Width / 2), Math.Min(wa.Bottom, anchor.Top) - size.Height - gap),
        };
    }

    /// DPI of the monitor showing `r` (96 = 100 %). Our windows are laid out for it before they are created,
    /// so they never get a WM_DPICHANGED rescale.
    public static float Scale(Rectangle r)
    {
        var rc = new RECT { Left = r.Left, Top = r.Top, Right = r.Right, Bottom = r.Bottom };
        var mon = MonitorFromRect(ref rc, 2 /*MONITOR_DEFAULTTONEAREST*/);
        return GetDpiForMonitor(mon, 0 /*MDT_EFFECTIVE_DPI*/, out var x, out _) == 0 ? x / 96f : 1f;
    }

    /// Windows 11 rounded corners and shadow on a borderless window; false on Windows 10.
    public static bool RoundCorners(IntPtr hwnd)
    {
        int round = 2;                                       // DWMWCP_ROUND
        return DwmSetWindowAttribute(hwnd, 33 /*DWMWA_WINDOW_CORNER_PREFERENCE*/, ref round, sizeof(int)) == 0;
    }

    /// 「3 分鐘」: how long a session has been in its state.
    public static string Ago(DateTime since)
    {
        var d = DateTime.Now - since;
        if (d.TotalSeconds < 60) return $"{Math.Max(0, (int)d.TotalSeconds)} 秒";
        if (d.TotalMinutes < 60) return $"{(int)d.TotalMinutes} 分鐘";
        return d.Minutes == 0 ? $"{(int)d.TotalHours} 小時" : $"{(int)d.TotalHours} 小時 {d.Minutes} 分";
    }

    public static string StateText(WorkState s) => s switch
    {
        WorkState.Working => "工作中", WorkState.Done => "已完成", WorkState.Input => "等你回答", _ => "",
    };

    /// "claude" → "Claude" for the pill's sentence.
    public static string AgentName(string agent) =>
        agent.Length == 0 || agent == "generic" ? "AI" : char.ToUpperInvariant(agent[0]) + agent[1..];

    /// Width a single line needs (measured without ellipsis, which would shrink it, plus AA slack).
    public static int TextWidth(string s, Font f) =>
        TextRenderer.MeasureText(s, f, new Size(int.MaxValue, int.MaxValue), TextFormatFlags.SingleLine | TextFormatFlags.NoPrefix | TextFormatFlags.NoPadding).Width + 2;

    /// After the island or pill closes: give back the pages its fonts (the CJK font is large) and bitmaps
    /// touched, so the resident agent returns to its idle working set.
    public static void Trim()
    {
        GC.Collect();                                        // no WaitForPendingFinalizers: the forms are disposed, not finalized
        SetProcessWorkingSetSize(-1 /*this process*/, -1, -1);
    }

    [DllImport("kernel32.dll")] static extern bool SetProcessWorkingSetSize(IntPtr process, nint min, nint max);

    public const int WM_DPICHANGED = 0x02E0;
}
