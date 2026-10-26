using System.Runtime.InteropServices;

namespace ShoWork;

/// Win32 calls the glow needs. Everything here is user-mode and needs no admin rights.
static class Native
{
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
    [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X, Y; public POINT(int x, int y) { X = x; Y = y; } }
    [StructLayout(LayoutKind.Sequential)] public struct SIZE { public int W, H; public SIZE(int w, int h) { W = w; H = h; } }
    [StructLayout(LayoutKind.Sequential, Pack = 1)]
    public struct BLENDFUNCTION { public byte BlendOp, BlendFlags, SourceConstantAlpha, AlphaFormat; }

    public const int WS_EX_LAYERED = 0x80000, WS_EX_TRANSPARENT = 0x20, WS_EX_TOOLWINDOW = 0x80, WS_EX_NOACTIVATE = 0x8000000;
    public const int ULW_ALPHA = 2;
    public const byte AC_SRC_OVER = 0, AC_SRC_ALPHA = 1;
    public const uint SWP_NOSIZE = 0x1, SWP_NOMOVE = 0x2, SWP_NOACTIVATE = 0x10, SWP_SHOWWINDOW = 0x40, SWP_HIDEWINDOW = 0x80;
    public const uint GW_HWNDNEXT = 2, GW_HWNDPREV = 3;
    public const int DWMWA_EXTENDED_FRAME_BOUNDS = 9, DWMWA_CLOAKED = 14;

    public const uint EVENT_SYSTEM_FOREGROUND = 0x0003, EVENT_SYSTEM_MINIMIZESTART = 0x0016, EVENT_SYSTEM_MINIMIZEEND = 0x0017;
    public const uint EVENT_OBJECT_DESTROY = 0x8001, EVENT_OBJECT_REORDER = 0x8004, EVENT_OBJECT_LOCATIONCHANGE = 0x800B;
    public const uint WINEVENT_OUTOFCONTEXT = 0, WINEVENT_SKIPOWNPROCESS = 2;
    public const int OBJID_WINDOW = 0;

    public delegate void WinEventProc(IntPtr hook, uint ev, IntPtr hwnd, int idObject, int idChild, uint thread, uint time);

    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool UpdateLayeredWindow(IntPtr hwnd, IntPtr hdcDst, ref POINT pptDst, ref SIZE psize, IntPtr hdcSrc,
        ref POINT pptSrc, int crKey, ref BLENDFUNCTION pblend, int dwFlags);
    /// blend-only update (no new bitmap, no move) — what the breathing animation uses: nothing is redrawn
    [DllImport("user32.dll", EntryPoint = "UpdateLayeredWindow", SetLastError = true)]
    public static extern bool UpdateLayeredWindowBlend(IntPtr hwnd, IntPtr hdcDst, IntPtr pptDst, IntPtr psize, IntPtr hdcSrc,
        IntPtr pptSrc, int crKey, ref BLENDFUNCTION pblend, int dwFlags);

    [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr hwnd, IntPtr after, int x, int y, int cx, int cy, uint flags);
    [DllImport("user32.dll")] public static extern IntPtr GetWindow(IntPtr hwnd, uint cmd);
    [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr hwnd);
    [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr hwnd);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hwnd);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint pid);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hwnd, out RECT r);
    [DllImport("user32.dll")] public static extern IntPtr GetDC(IntPtr hwnd);
    [DllImport("user32.dll")] public static extern int ReleaseDC(IntPtr hwnd, IntPtr hdc);
    [DllImport("user32.dll")] public static extern uint GetDpiForWindow(IntPtr hwnd);
    [DllImport("user32.dll")]
    public static extern IntPtr SetWinEventHook(uint min, uint max, IntPtr hmod, WinEventProc proc, uint pid, uint thread, uint flags);
    [DllImport("user32.dll")] public static extern bool UnhookWinEvent(IntPtr hook);

    [DllImport("gdi32.dll")] public static extern IntPtr CreateCompatibleDC(IntPtr hdc);
    [DllImport("gdi32.dll")] public static extern bool DeleteDC(IntPtr hdc);
    [DllImport("gdi32.dll")] public static extern IntPtr SelectObject(IntPtr hdc, IntPtr obj);
    [DllImport("gdi32.dll")] public static extern bool DeleteObject(IntPtr obj);

    [DllImport("dwmapi.dll")] public static extern int DwmGetWindowAttribute(IntPtr hwnd, int attr, out RECT r, int size);
    [DllImport("dwmapi.dll")] public static extern int DwmGetWindowAttribute(IntPtr hwnd, int attr, out int v, int size);

    [DllImport("kernel32.dll")] public static extern bool AttachConsole(uint pid);
    [DllImport("kernel32.dll")] public static extern bool FreeConsole();
    [DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow();

    public const uint GW_OWNER = 4, GA_ROOT = 2;
    public const int WH_KEYBOARD_LL = 13, WH_MOUSE_LL = 14;
    public const int WM_KEYDOWN = 0x100, WM_SYSKEYDOWN = 0x104, WM_LBUTTONDOWN = 0x201;
    public const uint SYNCHRONIZE = 0x100000, PROCESS_QUERY_LIMITED_INFORMATION = 0x1000;

    public delegate IntPtr HookProc(int code, IntPtr wParam, IntPtr lParam);
    public delegate bool EnumWindowsProc(IntPtr hwnd, IntPtr lParam);

    [DllImport("user32.dll")] public static extern IntPtr SetWindowsHookEx(int id, HookProc proc, IntPtr hmod, uint thread);
    [DllImport("user32.dll")] public static extern bool UnhookWindowsHookEx(IntPtr hook);
    [DllImport("user32.dll")] public static extern IntPtr CallNextHookEx(IntPtr hook, int code, IntPtr wParam, IntPtr lParam);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] public static extern IntPtr GetModuleHandle(string? name);
    [DllImport("user32.dll")] public static extern IntPtr WindowFromPoint(POINT p);
    [DllImport("user32.dll")] public static extern IntPtr GetAncestor(IntPtr hwnd, uint flags);
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumWindowsProc cb, IntPtr lParam);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetClassName(IntPtr hwnd, System.Text.StringBuilder s, int n);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowText(IntPtr hwnd, System.Text.StringBuilder s, int n);
    [DllImport("kernel32.dll", SetLastError = true)] public static extern IntPtr OpenProcess(uint access, bool inherit, uint pid);
    [DllImport("kernel32.dll")] public static extern bool GetProcessTimes(IntPtr h, out long creation, out long exit, out long kernel, out long user);
    [DllImport("kernel32.dll")] public static extern bool CloseHandle(IntPtr h);
    [DllImport("user32.dll")] public static extern bool DestroyIcon(IntPtr h);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hwnd, int cmd);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hwnd);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] static extern uint GetLongPathNameW(string shortPath, System.Text.StringBuilder longPath, uint size);

    /// Same file or folder? %TEMP% and friends are often 8.3 short paths (C:\Users\ABCDEF~1\…) while a
    /// process reports its long path, so expand both before comparing (W4 e2e found this).
    public static bool SamePath(string a, string b) =>
        string.Equals(LongPath(a).TrimEnd('\\'), LongPath(b).TrimEnd('\\'), StringComparison.OrdinalIgnoreCase);

    static string LongPath(string p)
    {
        var full = Path.GetFullPath(p);
        var sb = new System.Text.StringBuilder(1024);
        var n = GetLongPathNameW(full, sb, (uint)sb.Capacity);
        return n > 0 && n < sb.Capacity ? sb.ToString() : full;              // a path that doesn't exist stays as is
    }

    public static string ClassOf(IntPtr hwnd)
    {
        var s = new System.Text.StringBuilder(256);
        return GetClassName(hwnd, s, s.Capacity) > 0 ? s.ToString() : "";
    }

    public static string TitleOf(IntPtr hwnd)
    {
        var s = new System.Text.StringBuilder(1024);
        GetWindowText(hwnd, s, s.Capacity);
        return s.ToString();
    }

    /// Process creation time (FILETIME); with the pid it identifies a process even after the pid is reused. 0 = gone.
    public static long CreationTime(int pid)
    {
        var h = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, false, (uint)pid);
        if (h == IntPtr.Zero) return 0;
        try { return GetProcessTimes(h, out var c, out _, out _, out _) ? c : 0; }
        finally { CloseHandle(h); }
    }

    /// The window as you see it. GetWindowRect includes Windows 10/11's invisible resize borders (~7px),
    /// which would put the glow a few pixels away from the real edge.
    public static RECT VisibleRect(IntPtr hwnd)
    {
        if (DwmGetWindowAttribute(hwnd, DWMWA_EXTENDED_FRAME_BOUNDS, out RECT r, Marshal.SizeOf<RECT>()) == 0) return r;
        GetWindowRect(hwnd, out r);
        return r;
    }

    /// First VISIBLE window below `hwnd` in z-order. A console window keeps invisible helper windows
    /// (IME etc.) right under it, so "the window directly below" is almost never what you see (W0 test).
    public static IntPtr NextVisibleBelow(IntPtr hwnd)
    {
        var h = GetWindow(hwnd, GW_HWNDNEXT);
        for (int i = 0; i < 64 && h != IntPtr.Zero && !IsWindowVisible(h); i++) h = GetWindow(h, GW_HWNDNEXT);
        return h;
    }

    /// First VISIBLE window above `hwnd` in z-order (the inward glow's check; same invisible helpers as below).
    public static IntPtr NextVisibleAbove(IntPtr hwnd)
    {
        var h = GetWindow(hwnd, GW_HWNDPREV);
        for (int i = 0; i < 64 && h != IntPtr.Zero && !IsWindowVisible(h); i++) h = GetWindow(h, GW_HWNDPREV);
        return h;
    }

    /// Cloaked = on another virtual desktop (or a suspended UWP window): on screen for Win32, invisible to you.
    public static bool IsCloaked(IntPtr hwnd) =>
        DwmGetWindowAttribute(hwnd, DWMWA_CLOAKED, out int v, sizeof(int)) == 0 && v != 0;
}
