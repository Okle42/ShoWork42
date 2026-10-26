// Test-only helper for the W1 e2e. Talks to a test Claude's console WITHOUT focusing it (WriteConsoleInput),
// reads what is on its screen, and snapshots window rectangles. Never used by ShoWork itself.
//   Sw42Probe type <pid> <text>                 type text into pid's console
//   Sw42Probe key <pid> enter|esc|up|down|tab   press one key there
//   Sw42Probe wait <pid> <regex> <timeoutMs>    poll the screen every 25 ms; print the time it first matches
//   Sw42Probe screen <pid>                      print the visible screen
//   Sw42Probe windows                           visible top-level windows: hwnd, rect, pid, class, title
//   Sw42Probe front <hwnd>                      bring a (test!) window to the front
//   Sw42Probe shift                             one Shift key press (goes to the foreground window)
//   Sw42Probe click <hwnd>                      left click in the middle of a (test!) window, cursor restored
using System.Runtime.InteropServices;
using System.Text;
using System.Text.RegularExpressions;

static class Probe
{
    static int Main(string[] a)
    {
        // UTF-8 to the caller's pipe, bound before any console switching (never touch the console code page)
        var o = new StreamWriter(Console.OpenStandardOutput(), new UTF8Encoding(false)) { AutoFlush = true };
        o.Flush();
        try
        {
            switch (a[0])
            {
                case "type": Attach(a[1]); Type(a[2]); return 0;
                case "key": Attach(a[1]); Key(a[2]); return 0;
                case "screen": Attach(a[1]); o.WriteLine(Screen()); return 0;
                case "wait":
                {
                    Attach(a[1]);
                    var re = new Regex(a[2]);
                    var until = Environment.TickCount64 + int.Parse(a[3]);
                    while (Environment.TickCount64 < until)
                    {
                        if (re.IsMatch(Screen())) { o.WriteLine(DateTime.Now.ToString("HH:mm:ss.fff")); return 0; }
                        Thread.Sleep(25);
                    }
                    o.WriteLine("timeout");
                    return 1;
                }
                case "windows": Windows(o); return 0;
                case "front":
                {
                    var h = new IntPtr(long.Parse(a[1]));
                    // being the last input lifts the foreground lock; a zero-distance mouse move is input
                    // but not a key or click, so it doesn't acknowledge green in whatever window is in front
                    mouse_event(1, 0, 0, 0, UIntPtr.Zero);
                    SetForegroundWindow(h);
                    Thread.Sleep(250);
                    o.WriteLine(GetForegroundWindow() == h ? "ok" : "failed");
                    return 0;
                }
                case "shift": Tap(0x10); return 0;
                case "click":
                {
                    var h = new IntPtr(long.Parse(a[1]));
                    DwmGetWindowAttribute(h, 9, out RECT r, 16);
                    GetCursorPos(out var old);
                    SetCursorPos((r.L + r.R) / 2, (r.T + r.B) / 2);
                    mouse_event(2, 0, 0, 0, UIntPtr.Zero);
                    mouse_event(4, 0, 0, 0, UIntPtr.Zero);
                    Thread.Sleep(50);
                    SetCursorPos(old.X, old.Y);
                    return 0;
                }
            }
        }
        catch (Exception e) { o.WriteLine("error: " + e.Message); return 2; }
        return 64;
    }

    static IntPtr conin, conout;

    static void Attach(string pid)
    {
        FreeConsole();
        if (!AttachConsole(uint.Parse(pid))) throw new Exception($"AttachConsole({pid}) failed: {Marshal.GetLastWin32Error()}");
        conin = CreateFileW("CONIN$", 0xC0000000, 3, IntPtr.Zero, 3, 0, IntPtr.Zero);
        conout = CreateFileW("CONOUT$", 0xC0000000, 3, IntPtr.Zero, 3, 0, IntPtr.Zero);
    }

    static void Type(string text)
    {
        foreach (var c in text)
        {
            short vk = VkKeyScanW(c);
            bool shift = (vk & 0x100) != 0;
            Send((ushort)(vk & 0xFF), c, shift ? 0x10u : 0);
        }
    }

    static void Key(string name)
    {
        var (vk, ch) = name switch
        {
            "enter" => (0x0D, '\r'), "esc" => (0x1B, '\x1b'), "up" => (0x26, '\0'), "down" => (0x28, '\0'), "tab" => (0x09, '\t'),
            _ => throw new ArgumentException(name),
        };
        Send((ushort)vk, ch, 0);
    }

    static void Send(ushort vk, char c, uint ctrl)
    {
        var recs = new INPUT_RECORD[2];
        for (int i = 0; i < 2; i++)
        {
            recs[i].EventType = 1;
            recs[i].KeyDown = i == 0 ? 1 : 0;
            recs[i].Repeat = 1;
            recs[i].Vk = vk;
            recs[i].Scan = (ushort)MapVirtualKeyW(vk, 0);
            recs[i].Char = c;
            recs[i].Ctrl = ctrl;
        }
        WriteConsoleInputW(conin, recs, 2, out _);
        Thread.Sleep(8);
    }

    static string Screen()
    {
        if (!GetConsoleScreenBufferInfo(conout, out var info)) return "";
        var sb = new StringBuilder();
        int w = info.WinRight - info.WinLeft + 1;
        var line = new StringBuilder(w);
        for (int y = info.WinTop; y <= info.WinBottom; y++)
        {
            line.Clear();
            line.EnsureCapacity(w);
            var buf = new char[w];
            ReadConsoleOutputCharacterW(conout, buf, (uint)w, (uint)((y << 16) | (ushort)info.WinLeft), out var n);
            sb.Append(buf, 0, (int)n).Append('\n');
        }
        return sb.ToString();
    }

    static void Windows(TextWriter o)
    {
        EnumWindows((h, _) =>
        {
            if (!IsWindowVisible(h)) return true;
            DwmGetWindowAttribute(h, 14, out int cloaked, 4);
            if (cloaked != 0) return true;
            if (DwmGetWindowAttribute(h, 9, out RECT r, 16) != 0) GetWindowRect(h, out r);
            if (r.R - r.L <= 0 || r.B - r.T <= 0) return true;
            GetWindowThreadProcessId(h, out var pid);
            var cls = new StringBuilder(256); GetClassNameW(h, cls, 256);
            var title = new StringBuilder(256); GetWindowTextW(h, title, 256);
            o.WriteLine($"{h}\t{r.L},{r.T},{r.R},{r.B}\t{IsIconic(h)}\t{pid}\t{cls}\t{title.ToString().Replace('\t', ' ')}");
            return true;
        }, IntPtr.Zero);
    }

    static void Tap(byte vk) { keybd_event(vk, 0, 0, UIntPtr.Zero); keybd_event(vk, 0, 2, UIntPtr.Zero); }

    [StructLayout(LayoutKind.Explicit, Size = 20)]
    struct INPUT_RECORD
    {
        [FieldOffset(0)] public ushort EventType;
        [FieldOffset(4)] public int KeyDown;
        [FieldOffset(8)] public ushort Repeat;
        [FieldOffset(10)] public ushort Vk;
        [FieldOffset(12)] public ushort Scan;
        [FieldOffset(14)] public char Char;
        [FieldOffset(16)] public uint Ctrl;
    }

    [StructLayout(LayoutKind.Sequential)]
    struct CSBI
    {
        public short SizeX, SizeY, CurX, CurY; public ushort Attr;
        public short WinLeft, WinTop, WinRight, WinBottom, MaxX, MaxY;
    }

    [StructLayout(LayoutKind.Sequential)] struct RECT { public int L, T, R, B; }
    [StructLayout(LayoutKind.Sequential)] struct POINT { public int X, Y; }
    delegate bool EnumProc(IntPtr h, IntPtr l);

    [DllImport("kernel32.dll")] static extern bool FreeConsole();
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool AttachConsole(uint pid);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern IntPtr CreateFileW(string name, uint access, uint share, IntPtr sa, uint disp, uint flags, IntPtr tmpl);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] static extern bool WriteConsoleInputW(IntPtr h, INPUT_RECORD[] recs, uint n, out uint written);
    [DllImport("kernel32.dll")] static extern bool GetConsoleScreenBufferInfo(IntPtr h, out CSBI info);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] static extern bool ReadConsoleOutputCharacterW(IntPtr h, char[] buf, uint len, uint coord, out uint read);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern short VkKeyScanW(char c);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern uint MapVirtualKeyW(uint code, uint type);
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc cb, IntPtr l);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] static extern bool IsIconic(IntPtr h);
    [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetClassNameW(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetWindowTextW(IntPtr h, StringBuilder s, int n);
    [DllImport("dwmapi.dll")] static extern int DwmGetWindowAttribute(IntPtr h, int a, out RECT r, int s);
    [DllImport("dwmapi.dll")] static extern int DwmGetWindowAttribute(IntPtr h, int a, out int v, int s);
    [DllImport("user32.dll")] static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] static extern void keybd_event(byte vk, byte scan, uint flags, UIntPtr extra);
    [DllImport("user32.dll")] static extern void mouse_event(uint flags, int dx, int dy, uint data, UIntPtr extra);
    [DllImport("user32.dll")] static extern bool GetCursorPos(out POINT p);
    [DllImport("user32.dll")] static extern bool SetCursorPos(int x, int y);
}
