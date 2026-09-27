using static ShoWork.Native;

namespace ShoWork;

/// W0 technical spike: glow follows a classic console window (drag, resize, stacking, minimise,
/// virtual desktops). No hooks yet.
///
///   ShoWorkAgent.exe --console-hwnd <pid> <outfile>   write the console window HWND of process <pid>
///   ShoWorkAgent.exe --glow <hwnd> [working|done|input] [seconds]   glow around that window
static class Program
{
    static readonly List<GlowWindow> glows = new();
    static WinEventProc? proc;                       // keep the delegate alive while the hooks exist

    [STAThread]
    static int Main(string[] args)
    {
        if (args.Length == 3 && args[0] == "--console-hwnd")
        {
            // the production mapping for W1: attach to the AI's console and ask which window draws it
            FreeConsole();
            var h = AttachConsole(uint.Parse(args[1])) ? GetConsoleWindow() : IntPtr.Zero;
            File.WriteAllText(args[2], h.ToInt64().ToString());
            return h == IntPtr.Zero ? 1 : 0;
        }
        if (args.Length >= 2 && args[0] == "--glow")
        {
            var target = new IntPtr(long.Parse(args[1]));
            if (!IsWindow(target)) return 2;
            var state = args.Length >= 3 ? Enum.Parse<WorkState>(args[2], ignoreCase: true) : WorkState.Working;
            ApplicationConfiguration.Initialize();
            var g = new GlowWindow(target, state);
            glows.Add(g);
            g.Show();
            g.Sync();
            Hook();
            var watchdog = new System.Windows.Forms.Timer { Interval = 250 };
            watchdog.Tick += (_, _) => { foreach (var x in glows.ToArray()) if (!x.StackedRight) x.Sync(); if (glows.All(x => x.IsDisposed)) Application.Exit(); };
            watchdog.Start();
            if (args.Length >= 4 && int.TryParse(args[3], out var secs))
            {
                var stop = new System.Windows.Forms.Timer { Interval = secs * 1000 };
                stop.Tick += (_, _) => Application.Exit();
                stop.Start();
            }
            Application.Run();
            return 0;
        }
        return 64;
    }

    /// Out-of-context WinEvent hooks (no DLL injection, no admin). Events arrive on this UI thread.
    static void Hook()
    {
        proc = OnEvent;
        foreach (var (lo, hi) in new[] {
                     (EVENT_SYSTEM_FOREGROUND, EVENT_SYSTEM_FOREGROUND),
                     (EVENT_SYSTEM_MINIMIZESTART, EVENT_SYSTEM_MINIMIZEEND),
                     (EVENT_OBJECT_DESTROY, EVENT_OBJECT_DESTROY),
                     (EVENT_OBJECT_REORDER, EVENT_OBJECT_REORDER),
                     (EVENT_OBJECT_LOCATIONCHANGE, EVENT_OBJECT_LOCATIONCHANGE) })
            SetWinEventHook(lo, hi, IntPtr.Zero, proc, 0, 0, WINEVENT_OUTOFCONTEXT | WINEVENT_SKIPOWNPROCESS);
    }

    static void OnEvent(IntPtr hook, uint ev, IntPtr hwnd, int idObject, int idChild, uint thread, uint time)
    {
        if (ev == EVENT_OBJECT_LOCATIONCHANGE && idObject != OBJID_WINDOW) return;   // carets, cursors…
        foreach (var g in glows.ToArray())
        {
            if (g.IsDisposed) continue;
            // anything that can change where the target is or what sits right above the glow
            if (hwnd == g.Target || ev == EVENT_SYSTEM_FOREGROUND || ev == EVENT_OBJECT_REORDER) g.Sync();
        }
    }
}
