using System.Diagnostics;
using static ShoWork.Native;

namespace ShoWork;

///   ShoWorkAgent.exe                         run the agent (tray icon, named pipe, glows)
///   ShoWorkAgent.exe --install               copy this build to %LOCALAPPDATA%\ShoWork42\bin, hooks, autostart, start
///   ShoWorkAgent.exe --uninstall             stop, remove hooks and autostart
///   ShoWorkAgent.exe --install-hooks   [--settings PATH]   merge our hooks into Claude's settings.json
///   ShoWorkAgent.exe --uninstall-hooks [--settings PATH]
///   ShoWorkAgent.exe --install-autostart | --uninstall-autostart     HKCU Run
///   ShoWorkAgent.exe --status
/// W0 debugging:
///   ShoWorkAgent.exe --console-hwnd <pid> <outfile>   write the console window HWND of process <pid>
///   ShoWorkAgent.exe --glow <hwnd> [working|done|input] [seconds]   glow around that window
static class Program
{
    static readonly List<GlowWindow> glows = new();
    static WinEventProc? proc;                       // keep the delegate alive while the hooks exist

    [STAThread]
    static int Main(string[] args)
    {
        var settings = args.SkipWhile(a => a != "--settings").Skip(1).FirstOrDefault() ?? Installer.DefaultSettings;
        var showork = Path.Combine(AppContext.BaseDirectory, "showork.exe");
        var self = Environment.ProcessPath!;
        switch (args.FirstOrDefault())
        {
            case null or "--after": return RunAgent(args);
            case "--install-hooks": return Report(() => Installer.InstallHooks(settings, showork));
            case "--uninstall-hooks": return Report(() => Installer.UninstallHooks(settings));
            case "--install-autostart": return Report(() => { Installer.SetAutostart(true, self); return "on"; });
            case "--uninstall-autostart": return Report(() => { Installer.SetAutostart(false, self); return "off"; });
            case "--install": return Report(() => Install(settings));
            case "--uninstall": return Report(() => Uninstall(settings));
            case "--status":
                return Report(() => $"hooks installed: {Installer.CountOurs(settings)}/{Installer.OurHooks("x").Sum(kv => kv.Value!.AsArray().Count)}   autostart: {Installer.Autostart() ?? "off"}   " +
                                    $"agent running: {Process.GetProcessesByName("ShoWorkAgent").Any(p => p.Id != Environment.ProcessId)}");
        }
        if (args.Length == 3 && args[0] == "--console-hwnd")
        {
            FreeConsole();
            var h = AttachConsole(uint.Parse(args[1])) ? GetConsoleWindow() : IntPtr.Zero;
            File.WriteAllText(args[2], h.ToInt64().ToString());
            return h == IntPtr.Zero ? 1 : 0;
        }
        if (args.Length >= 2 && args[0] == "--glow") return GlowSpike(args);
        return 64;
    }

    /// WinExe: attach to the calling console (if any) so install/status output is visible there.
    static int Report(Func<string> action)
    {
        AttachConsole(unchecked((uint)-1));
        try
        {
            Console.WriteLine(action());
            return 0;
        }
        catch (Exception e)
        {
            Console.Error.WriteLine($"error: {e.Message}");
            return 1;
        }
    }

    static string Install(string settings)
    {
        var bin = Installer.InstallDir;
        var here = Path.GetFullPath(AppContext.BaseDirectory).TrimEnd('\\');
        if (!string.Equals(here, Path.GetFullPath(bin).TrimEnd('\\'), StringComparison.OrdinalIgnoreCase))
        {
            Installer.StopRunningAgents();
            Installer.CopyBuild(here, bin);
        }
        var agent = Path.Combine(bin, "ShoWorkAgent.exe");
        var hooks = Installer.InstallHooks(settings, Path.Combine(bin, "showork.exe"));
        Installer.SetAutostart(true, agent);
        if (!Process.GetProcessesByName("ShoWorkAgent").Any(p => p.Id != Environment.ProcessId))
            // ShellExecute: the agent must not inherit our stdout (a caller piping us would wait forever)
            Process.Start(new ProcessStartInfo(agent) { UseShellExecute = true, WorkingDirectory = bin });
        return $"installed to {bin}; hooks: {hooks}; autostart: on; agent: running";
    }

    static string Uninstall(string settings)
    {
        Installer.StopRunningAgents();
        var hooks = Installer.UninstallHooks(settings);
        Installer.SetAutostart(false, "");
        return $"hooks: {hooks}; autostart: off; agent: stopped (files stay in {Installer.InstallDir})";
    }

    static int RunAgent(string[] args)
    {
        // 重新載入 starts a new agent that waits for the old one to let go of the pipe
        if (args.Length >= 2 && args[0] == "--after" && int.TryParse(args[1], out var old))
            try { Process.GetProcessById(old).WaitForExit(5000); } catch { }
        ApplicationConfiguration.Initialize();
        var ui = new Control();
        ui.CreateControl();                                    // a handle to BeginInvoke onto
        var engine = new Engine(ui);
        var server = new PipeServer(m => { try { ui.BeginInvoke(() => engine.Handle(m)); } catch { } });
        if (!server.Start()) { Log.Note("another agent owns the pipe; exiting"); return 3; }
        Log.Note($"AGENT start pid={Environment.ProcessId} pipe={PipeServer.Name}");
        engine.Start(
            reload: () =>
            {
                engine.Stop();
                Process.Start(new ProcessStartInfo(Environment.ProcessPath!, $"--after {Environment.ProcessId}") { UseShellExecute = true });
                Application.Exit();
            },
            quit: () => { engine.Stop(); Application.Exit(); });
        Application.Run();
        return 0;
    }

    static int GlowSpike(string[] args)
    {
        var target = new IntPtr(long.Parse(args[1]));
        if (!IsWindow(target)) return 2;
        var state = args.Length >= 3 ? Enum.Parse<WorkState>(args[2], ignoreCase: true) : WorkState.Working;
        ApplicationConfiguration.Initialize();
        var g = new GlowWindow(target, state);
        glows.Add(g);
        g.Show();
        g.Sync();
        proc = OnEvent;
        foreach (var (lo, hi) in new[] {
                     (EVENT_SYSTEM_FOREGROUND, EVENT_SYSTEM_FOREGROUND),
                     (EVENT_SYSTEM_MINIMIZESTART, EVENT_SYSTEM_MINIMIZEEND),
                     (EVENT_OBJECT_DESTROY, EVENT_OBJECT_DESTROY),
                     (EVENT_OBJECT_REORDER, EVENT_OBJECT_REORDER),
                     (EVENT_OBJECT_LOCATIONCHANGE, EVENT_OBJECT_LOCATIONCHANGE) })
            SetWinEventHook(lo, hi, IntPtr.Zero, proc, 0, 0, WINEVENT_OUTOFCONTEXT | WINEVENT_SKIPOWNPROCESS);
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

    static void OnEvent(IntPtr hook, uint ev, IntPtr hwnd, int idObject, int idChild, uint thread, uint time)
    {
        if (ev == EVENT_OBJECT_LOCATIONCHANGE && idObject != OBJID_WINDOW) return;   // carets, cursors…
        foreach (var g in glows.ToArray())
        {
            if (g.IsDisposed) continue;
            if (hwnd == g.Target || ev == EVENT_SYSTEM_FOREGROUND || ev == EVENT_OBJECT_REORDER) g.Sync();
        }
    }
}
