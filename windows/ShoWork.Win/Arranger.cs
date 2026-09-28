using System.Drawing;
using System.Runtime.InteropServices;
using static ShoWork.Native;

namespace ShoWork;

/// Arranges every terminal window (classic conhost + Windows Terminal), each monitor on its own. Port of the Mac
/// Arranger (Kang 09-26): auto re-arrange when the number of terminal windows changes (a setting; off by default
/// here until the settings page wires AutoEnabled), Ctrl+Alt+L = arrange now (with 4 windows it toggles columns ⇄ 2×2).
///
/// Which windows: top-level ConsoleWindowClass / CASCADIA_HOSTING_WINDOW_CLASS that are visible, not minimised,
/// not cloaked (another virtual desktop) and not full screen (WT F11 — the Mac skips native full screen too).
/// Each belongs to the monitor that holds its centre (nearest monitor when it is off all of them).
///
/// Maximised windows ARE arranged: they are restored first (SW_SHOWNOACTIVATE, never activated). On the Mac a
/// window filling the screen is an ordinary window and gets arranged; only native full screen is left alone, and
/// setting the rect of a still-maximised window would leave Windows believing it is maximised.
///
/// Test safety (enforced here, not in scripts — Mac 09-26 incident; a test instance = SHOWORK_PIPE set, and it
/// arranges nothing unless SHOWORK_ONLY_WIDS is set too):
///   SHOWORK_ONLY_WIDS=h1,h2,…       refuse to touch ANYTHING if a terminal window outside the list is on screen
///   SHOWORK_ARRANGE_ONLY_LISTED=1   (tests only, Windows addition) candidates = the listed windows only, so a test
///                                   can run while the user's own terminal is open; without ONLY_WIDS nothing is a candidate
///   SHOWORK_ARRANGE_NOOP=1          plan and log, move nothing
///   SHOWORK_AUTO_ARRANGE=1          auto-arrange on regardless of AutoEnabled
static class Arranger
{
    static bool auto;
    static SynchronizationContext? ui;
    /// The "auto arrange" setting (the Mac default is on; the settings page owns it and persists it).
    /// Hooks and timers only work on the UI thread: a set from elsewhere is posted there.
    public static bool AutoEnabled
    {
        get => auto;
        set
        {
            if (ui != null && SynchronizationContext.Current != ui) { ui.Post(_ => AutoEnabled = value, null); return; }
            auto = value;
            Refresh();
        }
    }
    /// With exactly 4 windows on a monitor: four columns or 2×2. Ctrl+Alt+L flips it.
    public static LayoutPlan.FourStyle FourStyle = LayoutPlan.FourStyle.Columns;

    static bool AutoOn => auto || Environment.GetEnvironmentVariable("SHOWORK_AUTO_ARRANGE") == "1";

    readonly record struct Target(IntPtr Hwnd, Rectangle Frame, IntPtr Monitor);
    readonly record struct Placed(IntPtr Hwnd, int Row, IntPtr Monitor);

    static bool started, busy, again;                   // again: an arrange asked for while busy runs after it
    static readonly object chainLock = new();
    static bool stacking;                               // a z-order chain runs on its worker thread (under chainLock)
    static (IntPtr after, List<IntPtr> windows)? nextChain;
    static int lastCount = -1;
    static HashSet<IntPtr> known = new();               // terminal windows seen at the last count (their DESTROY has no class)
    static List<Placed> arranged = new();               // windows of the last ≥6 (overlapping) layout: drives restacking
    static readonly List<IntPtr> countHooks = new();
    static IntPtr focusHook;
    static WinEventProc? countProc, focusProc;          // keep the delegates alive while the hooks exist
    static System.Windows.Forms.Timer? recount, settle;
    static HotKeyWindow? hotkey;

    /// Call once on the UI thread (it needs the message loop for the hotkey and the WinEvent hooks).
    public static void Start()
    {
        if (started) return;
        started = true;
        ui = SynchronizationContext.Current;
        countProc = OnCountEvent;
        focusProc = OnForeground;
        recount = new() { Interval = 200 };                 // coalesce a burst of show/hide events into one count
        recount.Tick += (_, _) => { recount.Stop(); CheckCount(); };
        settle = new() { Interval = 800 };                  // Mac: a new/closed window re-arranges after 0.8 s
        settle.Tick += (_, _) => { settle.Stop(); ArrangeNow(); lastCount = Targets().Count; };
        hotkey = new HotKeyWindow();
        Application.ApplicationExit += (_, _) => Stop();
        lastCount = Targets().Count;                         // like the Mac: no arranging at launch, only on changes
        Refresh();
    }

    public static void Stop()
    {
        if (!started) return;
        started = false;
        HookCount(false);
        HookFocus(false);
        recount?.Stop();
        settle?.Stop();
        hotkey?.Dispose();
    }

    /// Arrange every monitor now (tray menu 立即排版, Ctrl+Alt+L, auto). UI thread.
    public static void ArrangeNow() => Arrange(Plan());

    /// Ctrl+Alt+L: with 4 windows on some monitor, flip columns ⇄ 2×2 first (Mac ⌃⌥L).
    static void OnHotKey()
    {
        // while busy the queued re-arrange uses FourStyle as it is: flipping now would not match the screen
        if (!busy && Targets().GroupBy(t => t.Monitor).Any(g => g.Count() == 4))
            FourStyle = FourStyle == LayoutPlan.FourStyle.Columns ? LayoutPlan.FourStyle.Grid : LayoutPlan.FourStyle.Columns;
        Log.Note($"ARRANGE hotkey four={FourStyle}");
        ArrangeNow();
    }

    // MARK: auto — event driven, no polling: hooks exist only while auto arrange is on

    static void Refresh()
    {
        if (!started) return;
        HookCount(AutoOn);
        if (!AutoOn) { lastCount = -1; settle?.Stop(); }
        else if (lastCount < 0) CheckCount();               // switched on: arrange what is there (Mac: count ≠ −1)
    }

    static void CheckCount()
    {
        if (!AutoOn) return;
        int n = Targets().Count;
        if (n == lastCount) return;
        Log.Note($"ARRANGE count {lastCount}→{n}");
        lastCount = n;
        settle!.Stop();
        settle.Start();
    }

    const uint EVENT_OBJECT_HIDE = 0x8003, EVENT_OBJECT_CLOAKED = 0x8017, EVENT_OBJECT_UNCLOAKED = 0x8018;

    static void HookCount(bool on)
    {
        if (on == countHooks.Count > 0) return;
        if (on)
        {
            foreach (var (lo, hi) in new[] {
                         (EVENT_SYSTEM_MINIMIZESTART, EVENT_SYSTEM_MINIMIZEEND),
                         (EVENT_OBJECT_DESTROY, EVENT_OBJECT_HIDE),          // destroy, show, hide
                         (EVENT_OBJECT_CLOAKED, EVENT_OBJECT_UNCLOAKED) })
                countHooks.Add(SetWinEventHook(lo, hi, IntPtr.Zero, countProc!, 0, 0, WINEVENT_OUTOFCONTEXT | WINEVENT_SKIPOWNPROCESS));
        }
        else
        {
            foreach (var h in countHooks) UnhookWinEvent(h);
            countHooks.Clear();
        }
    }

    /// Only terminal windows matter: a class check (or the known set, for destroyed ones) before anything else.
    static void OnCountEvent(IntPtr hook, uint ev, IntPtr hwnd, int idObject, int idChild, uint thread, uint time)
    {
        if (idObject != OBJID_WINDOW || idChild != 0 || hwnd == IntPtr.Zero) return;
        if (!known.Contains(hwnd) && !IsTerminalClass(ClassOf(hwnd))) return;
        recount!.Stop();
        recount.Start();
    }

    // MARK: which windows, where

    static bool IsTerminalClass(string cls) => cls == Resolver.ConsoleClass || cls == Resolver.TerminalClass;

    /// SHOWORK_ONLY_WIDS as a set (null = not in test mode).
    static HashSet<IntPtr>? OnlyWids =>
        Environment.GetEnvironmentVariable("SHOWORK_ONLY_WIDS") is { } s
            ? s.Split(',', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries)
               .Select(x => long.TryParse(x, out var v) ? new IntPtr(v) : IntPtr.Zero).Where(h => h != IntPtr.Zero).ToHashSet()
            : null;

    static List<Target> Targets()
    {
        var list = new List<Target>();
        var seen = new HashSet<IntPtr>();
        EnumWindows((h, _) =>
        {
            if (!IsTerminalClass(ClassOf(h))) return true;
            seen.Add(h);
            // hung (not responding): leave it alone, a move would wait on it; it rejoins (count change) when it recovers
            if (!IsWindowVisible(h) || IsIconic(h) || IsCloaked(h) || IsHungAppWindow(h)) return true;
            var r = VisibleRect(h);
            var f = Rectangle.FromLTRB(r.Left, r.Top, r.Right, r.Bottom);
            if (f.Width <= 0 || f.Height <= 0) return true;
            var mon = MonitorFromPoint(new POINT(f.Left + f.Width / 2, f.Top + f.Height / 2), MONITOR_DEFAULTTONEAREST);
            if (!IsZoomed(h) && Monitor(mon) is { } m && f == m.Bounds) return true;       // full screen (WT F11)
            list.Add(new Target(h, f, mon));
            return true;
        }, IntPtr.Zero);
        known = seen;
        if (Environment.GetEnvironmentVariable("SHOWORK_ARRANGE_ONLY_LISTED") == "1")
        {
            var allow = OnlyWids ?? new();
            list.RemoveAll(t => !allow.Contains(t.Hwnd));
        }
        return list;
    }

    /// Reading order (top→bottom, left→right) keeps windows near where they were (80 pt bands, like the Mac).
    static List<Target> Ordered(IEnumerable<Target> ts, double pt) =>
        ts.OrderBy(t => Math.Round(t.Frame.Top / (80 * pt), MidpointRounding.AwayFromZero)).ThenBy(t => t.Frame.Left).ToList();

    /// One independent layout per monitor.
    static List<(Target t, Rectangle f)> Plan()
    {
        var pairs = new List<(Target, Rectangle)>();
        foreach (var g in Targets().GroupBy(t => t.Monitor).OrderBy(g => g.Key))
        {
            if (Monitor(g.Key) is not { } m) continue;
            var ts = Ordered(g, m.Pt);
            pairs.AddRange(ts.Zip(LayoutPlan.Frames(ts.Count, m.Work, FourStyle, m.Pt)));
        }
        return pairs;
    }

    // MARK: moving

    static void Arrange(List<(Target t, Rectangle f)> pairs)
    {
        if (busy) { again = true; Log.Note("ARRANGE queued: still settling the previous one"); return; }
        // a test instance (its own SHOWORK_PIPE) that turns 自動排版 on must never reach the user's terminals
        if (OnlyWids == null && !string.IsNullOrEmpty(Environment.GetEnvironmentVariable("SHOWORK_PIPE")))
        {
            if (pairs.Count > 0) Log.Note($"ARRANGE REFUSED: test instance (SHOWORK_PIPE) without SHOWORK_ONLY_WIDS, {pairs.Count} windows left alone");
            return;
        }
        if (OnlyWids is { } allow)
        {
            var foreign = pairs.Where(p => !allow.Contains(p.t.Hwnd)).Select(p => p.t.Hwnd).ToList();
            if (foreign.Count > 0) { Log.Note($"ARRANGE REFUSED: windows outside SHOWORK_ONLY_WIDS on screen: {string.Join(",", foreign)}"); return; }
        }
        foreach (var (t, f) in pairs) Log.Note($"ARRANGE plan {t.Hwnd} [{t.Frame.X},{t.Frame.Y},{t.Frame.Width},{t.Frame.Height}] → [{f.X},{f.Y},{f.Width},{f.Height}]");
        // guard-only mode: everything above ran, nothing below moves a window
        if (Environment.GetEnvironmentVariable("SHOWORK_ARRANGE_NOOP") == "1") { Log.Note($"ARRANGE NOOP: would arrange {pairs.Count} windows"); return; }
        if (pairs.Count == 0) return;
        _ = Apply(pairs);
    }

    /// Up to 3 passes: a window moved onto a monitor with another DPI rescales itself (WM_DPICHANGED) after
    /// the first move, and a terminal may apply its size asynchronously; the retry waits without blocking the UI.
    /// Every call into another process is asynchronous (ShowWindowAsync, SWP_ASYNCWINDOWPOS): a window that stops
    /// responding mid-arrange must not freeze the agent's only UI thread (glows, tray, pipe, hotkey).
    static async Task Apply(List<(Target t, Rectangle f)> pairs)
    {
        busy = true;
        try
        {
            bool restored = false;
            foreach (var (t, _) in pairs)
                if (IsZoomed(t.Hwnd)) restored |= ShowWindowAsync(t.Hwnd, SW_SHOWNOACTIVATE);   // restore, never activate
            if (restored) await Task.Delay(120);            // let the restores land before measuring borders
            for (int attempt = 0; attempt < 3; attempt++)
            {
                int wrong = 0;
                foreach (var (t, f) in pairs)
                {
                    if (!IsWindow(t.Hwnd) || IsHungAppWindow(t.Hwnd) || Close(VisibleRect(t.Hwnd), f, Monitor(t.Monitor)?.Pt ?? 1)) continue;
                    wrong++;
                    Place(t.Hwnd, f);
                }
                if (wrong == 0) break;
                if (attempt < 2) await Task.Delay(120);
            }
            Stack(pairs);
            Log.Note($"ARRANGE done {pairs.Count} windows");
        }
        catch (Exception e) { Log.Note($"ARRANGE {e.GetType().Name}: {e.Message}"); }
        finally
        {
            busy = false;
            if (again) { again = false; ArrangeNow(); }
        }
    }

    /// `f` is the visible frame; GetWindowRect adds the invisible resize borders (DWM frame bounds don't), so the
    /// rect we set is grown by exactly the border this window has now. Never activates, never changes z-order here.
    static void Place(IntPtr h, Rectangle f)
    {
        GetWindowRect(h, out var raw);
        var vis = VisibleRect(h);
        int l = vis.Left - raw.Left, t = vis.Top - raw.Top, r = raw.Right - vis.Right, b = raw.Bottom - vis.Bottom;
        SetWindowPos(h, IntPtr.Zero, f.X - l, f.Y - t, f.Width + l + r, f.Height + t + b,
                     SWP_NOACTIVATE | SWP_NOZORDER | SWP_NOOWNERZORDER | SWP_ASYNCWINDOWPOS);
    }

    /// Origin exact; size may be a little smaller (a terminal can snap to its character grid), never bigger.
    static bool Close(RECT a, Rectangle b, double pt)
    {
        int dw = a.Right - a.Left - b.Width, dh = a.Bottom - a.Top - b.Height, slack = (int)(25 * pt);
        return Math.Abs(a.Left - b.X) <= 2 && Math.Abs(a.Top - b.Y) <= 2 && dw >= -slack && dw <= 2 && dh >= -slack && dh <= 2;
    }

    // MARK: stacking — later windows on top so staggered title bars show; the window you're in stays on top

    /// Mac raises the windows in layout order, then the focused one. Here the same order is built by inserting each
    /// window right under the previous one, starting under the foreground window: no activation, and the terminals
    /// never jump above an app you are using (a background agent must not steal the top from you).
    /// Without a normal app window in front (desktop, taskbar, a topmost or tool window) they go to the top of the
    /// normal band instead: anchored under Progman/WorkerW they would vanish behind the wallpaper.
    static void Stack(List<(Target t, Rectangle f)> pairs)
    {
        var fg = GetForegroundWindow();
        var chain = pairs.Select(p => p.t.Hwnd).Where(h => h != fg).Reverse().ToList();
        ChainBelow(IsAnchor(fg) ? fg : HWND_TOP, chain);
        arranged = pairs.GroupBy(p => p.t.Monitor).Where(g => g.Count() >= 6)
                        .SelectMany(g => g.Zip(LayoutPlan.Rows(g.Count()), (p, row) => new Placed(p.t.Hwnd, row, p.t.Monitor))).ToList();
        HookFocus(arranged.Count > 0);
    }

    /// A visible, normal (not topmost, not tool, not shell) top-level window we can safely sit under.
    static bool IsAnchor(IntPtr h)
    {
        if (h == IntPtr.Zero || h == GetShellWindow() || !IsWindowVisible(h) || IsIconic(h) || IsCloaked(h)) return false;
        if (GetAncestor(h, GA_ROOT) != h || (GetWindowLong(h, GWL_EXSTYLE) & (WS_EX_TOPMOST | WS_EX_TOOLWINDOW)) != 0) return false;
        return ClassOf(h) is not ("Progman" or "WorkerW" or "Shell_TrayWnd" or "Shell_SecondaryTrayWnd");
    }

    /// The order depends on each call finishing before the next (SWP_ASYNCWINDOWPOS would not keep it), and a
    /// synchronous cross-process SetWindowPos waits for the target: so the chain runs on a worker thread, one at a
    /// time, skipping hung windows. While one runs (or is stuck on a window that just stopped responding) only the
    /// newest request waits: an older order is stale by then.
    static void ChainBelow(IntPtr after, List<IntPtr> windows)
    {
        lock (chainLock)
        {
            nextChain = (after, windows);
            if (stacking) return;
            stacking = true;
        }
        Task.Run(() =>
        {
            while (true)
            {
                (IntPtr after, List<IntPtr> windows) c;
                lock (chainLock)
                {
                    if (nextChain is not { } n) { stacking = false; return; }
                    c = n;
                    nextChain = null;
                }
                try
                {
                    foreach (var h in c.windows)
                    {
                        if (!IsWindow(h) || IsHungAppWindow(h)) continue;
                        SetWindowPos(h, c.after, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE | SWP_NOOWNERZORDER);
                        c.after = h;
                    }
                }
                catch { }
            }
        });
    }

    static void HookFocus(bool on)
    {
        if (on == (focusHook != IntPtr.Zero)) return;
        if (on) focusHook = SetWinEventHook(EVENT_SYSTEM_FOREGROUND, EVENT_SYSTEM_FOREGROUND, IntPtr.Zero, focusProc!, 0, 0, WINEVENT_OUTOFCONTEXT | WINEVENT_SKIPOWNPROCESS);
        else { UnhookWinEvent(focusHook); focusHook = IntPtr.Zero; }
    }

    /// Kang 09-26: the row you're in goes on top; the closer another row is to yours, the higher it sits
    /// (click a bottom window ⇒ the middle row re-emerges above the top row). Only the monitor you're on.
    static void OnForeground(IntPtr hook, uint ev, IntPtr hwnd, int idObject, int idChild, uint thread, uint time)
    {
        arranged.RemoveAll(p => !IsWindow(p.Hwnd));
        if (arranged.Count == 0) { HookFocus(false); return; }
        var me = arranged.FirstOrDefault(p => p.Hwnd == hwnd);
        if (me.Hwnd == IntPtr.Zero) return;
        var nearestFirst = arranged.Where(p => p.Monitor == me.Monitor && p.Hwnd != hwnd)
                                   .OrderBy(p => Math.Abs(p.Row - me.Row)).ThenByDescending(p => p.Row).Select(p => p.Hwnd).ToList();
        ChainBelow(hwnd, nearestFirst);
    }

    // MARK: monitors

    readonly record struct MonitorInfo(Rectangle Bounds, Rectangle Work, double Pt);

    /// Physical pixels (the agent is Per-Monitor V2); Pt = pixels per point for the Mac's point constants.
    static MonitorInfo? Monitor(IntPtr mon)
    {
        var mi = new MONITORINFO { cbSize = Marshal.SizeOf<MONITORINFO>() };
        if (mon == IntPtr.Zero || !GetMonitorInfo(mon, ref mi)) return null;
        double pt = GetDpiForMonitor(mon, 0, out var dx, out _) == 0 && dx > 0 ? dx / 96.0 : 1;
        return new MonitorInfo(Rectangle.FromLTRB(mi.rcMonitor.Left, mi.rcMonitor.Top, mi.rcMonitor.Right, mi.rcMonitor.Bottom),
                               Rectangle.FromLTRB(mi.rcWork.Left, mi.rcWork.Top, mi.rcWork.Right, mi.rcWork.Bottom), pt);
    }

    // MARK: Ctrl+Alt+L

    /// Message-only window that receives WM_HOTKEY.
    sealed class HotKeyWindow : NativeWindow, IDisposable
    {
        const int Id = 0x5357;                               // "SW"
        readonly bool registered;

        public HotKeyWindow()
        {
            CreateHandle(new CreateParams { Parent = HWND_MESSAGE });
            registered = RegisterHotKey(Handle, Id, MOD_CONTROL | MOD_ALT | MOD_NOREPEAT, 0x4C /*L*/);
            Log.Note(registered ? "ARRANGE hotkey Ctrl+Alt+L registered" : $"ARRANGE hotkey Ctrl+Alt+L taken (error {Marshal.GetLastWin32Error()})");
        }

        protected override void WndProc(ref Message m)
        {
            if (m.Msg == WM_HOTKEY && m.WParam == Id) OnHotKey();
            else base.WndProc(ref m);
        }

        public void Dispose()
        {
            if (registered) UnregisterHotKey(Handle, Id);
            DestroyHandle();
        }
    }

    // MARK: Win32 used only here

    const int SW_SHOWNOACTIVATE = 4, GWL_EXSTYLE = -20, WS_EX_TOPMOST = 0x8, WM_HOTKEY = 0x312;
    const uint SWP_NOZORDER = 0x4, SWP_NOOWNERZORDER = 0x200, SWP_ASYNCWINDOWPOS = 0x4000, MONITOR_DEFAULTTONEAREST = 2;
    const uint MOD_ALT = 1, MOD_CONTROL = 2, MOD_NOREPEAT = 0x4000;
    static readonly IntPtr HWND_TOP = IntPtr.Zero, HWND_MESSAGE = new(-3);

    [StructLayout(LayoutKind.Sequential)]
    struct MONITORINFO { public int cbSize; public RECT rcMonitor, rcWork; public uint dwFlags; }

    [DllImport("user32.dll")] static extern bool IsZoomed(IntPtr hwnd);
    [DllImport("user32.dll")] static extern bool IsHungAppWindow(IntPtr hwnd);
    [DllImport("user32.dll")] static extern bool ShowWindowAsync(IntPtr hwnd, int cmd);
    [DllImport("user32.dll")] static extern IntPtr GetShellWindow();
    [DllImport("user32.dll")] static extern int GetWindowLong(IntPtr hwnd, int index);
    [DllImport("user32.dll")] static extern IntPtr MonitorFromPoint(POINT p, uint flags);
    [DllImport("user32.dll")] static extern bool GetMonitorInfo(IntPtr mon, ref MONITORINFO mi);
    [DllImport("shcore.dll")] static extern int GetDpiForMonitor(IntPtr mon, int type, out uint dpiX, out uint dpiY);
    [DllImport("user32.dll", SetLastError = true)] static extern bool RegisterHotKey(IntPtr hwnd, int id, uint mods, uint vk);
    [DllImport("user32.dll")] static extern bool UnregisterHotKey(IntPtr hwnd, int id);
}
