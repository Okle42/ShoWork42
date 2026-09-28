using System; using System.Runtime.InteropServices; using System.Drawing; using System.Drawing.Imaging; using System.Collections.Generic; using System.Text;

/// W2 test helpers: find the test agent's windows, capture ONLY them (PrintWindow / own-window rects),
/// and snapshot every visible window's rect to prove nothing else moved.
public static class W2
{
    public delegate bool CB(IntPtr h, IntPtr l);
    [DllImport("user32.dll")] static extern bool EnumWindows(CB cb, IntPtr l);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr h, IntPtr hdc, uint f);
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; }
    [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X, Y; }
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
    [DllImport("user32.dll")] public static extern IntPtr WindowFromPoint(POINT p);
    [DllImport("user32.dll")] public static extern IntPtr GetAncestor(IntPtr h, uint f);
    [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint f);
    [DllImport("user32.dll")] public static extern IntPtr GetWindow(IntPtr h, uint cmd);
    [DllImport("user32.dll")] public static extern IntPtr PostMessage(IntPtr h, uint msg, IntPtr w, IntPtr l);
    [DllImport("user32.dll")] public static extern IntPtr SendMessage(IntPtr h, uint msg, IntPtr w, IntPtr l);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern IntPtr FindWindowEx(IntPtr parent, IntPtr after, string cls, string title);
    [DllImport("dwmapi.dll")] static extern int DwmGetWindowAttribute(IntPtr h, int a, out RECT r, int s);

    public static string Title(IntPtr h) { var s = new StringBuilder(256); GetWindowText(h, s, 256); return s.ToString(); }
    public static RECT Rect(IntPtr h) { RECT r; GetWindowRect(h, out r); return r; }
    public static RECT Vis(IntPtr h) { RECT r; if (DwmGetWindowAttribute(h, 9, out r, 16) != 0) GetWindowRect(h, out r); return r; }

    public static List<IntPtr> Of(uint pid)
    {
        var f = new List<IntPtr>();
        EnumWindows((h, l) => { uint p; GetWindowThreadProcessId(h, out p); if (p == pid && IsWindowVisible(h)) f.Add(h); return true; }, IntPtr.Zero);
        return f;
    }

    /// "hwnd:L,T,R,B" of every visible top-level window except those in `skip` processes
    public static List<string> AllRects(uint[] skip)
    {
        var f = new List<string>();
        EnumWindows((h, l) =>
        {
            uint p; GetWindowThreadProcessId(h, out p);
            if (IsWindowVisible(h) && Array.IndexOf(skip, p) < 0) { RECT r; GetWindowRect(h, out r); f.Add(h + ":" + r.L + "," + r.T + "," + r.R + "," + r.B); }
            return true;
        }, IntPtr.Zero);
        return f;
    }

    public static void Shot(IntPtr h, string path)
    {
        RECT r; GetWindowRect(h, out r);
        using (var b = new Bitmap(r.R - r.L, r.B - r.T))
        {
            using (var g = Graphics.FromImage(b)) { var dc = g.GetHdc(); PrintWindow(h, dc, 2); g.ReleaseHdc(dc); }
            b.Save(path, ImageFormat.Png);
        }
    }

    /// Every sample point of the rect hits one of `mine` (click-through glows are skipped by WindowFromPoint,
    /// so the answer is the window under them) — then a screen capture of the rect shows only our windows.
    public static bool OnlyMine(RECT r, IntPtr[] mine)
    {
        for (int y = r.T + 2; y < r.B; y += 12)
            for (int x = r.L + 2; x < r.R; x += 12)
            {
                var h = GetAncestor(WindowFromPoint(new POINT { X = x, Y = y }), 2);
                if (Array.IndexOf(mine, h) < 0) return false;
            }
        return true;
    }

    public static void Capture(RECT r, string path)
    {
        using (var b = new Bitmap(r.R - r.L, r.B - r.T))
        {
            using (var g = Graphics.FromImage(b)) g.CopyFromScreen(r.L, r.T, 0, 0, b.Size);
            b.Save(path, ImageFormat.Png);
        }
    }
}
