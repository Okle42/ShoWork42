using System.Diagnostics;
using static ShoWork.Native;

namespace ShoWork;

///   ShoWorkAgent.exe                         run the agent (tray icon, named pipe, glows)
///   ShoWork42.exe                            (packaged, W4) offer to install itself; the installed copy runs the agent
///   ShoWorkAgent.exe --agent                 run the agent whatever this exe is
///   ShoWorkAgent.exe --install   [--quiet]   into %LOCALAPPDATA%\ShoWork42\bin: hooks, autostart, Settings → Apps, start
///   ShoWorkAgent.exe --uninstall [--quiet]   all of that undone and bin deleted (the glow settings stay)
///   ShoWorkAgent.exe --version
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
        var quiet = args.Contains("--quiet");
        switch (args.FirstOrDefault())
        {
            // the downloaded ShoWork42.exe asks to install itself; the installed copy (and a dev build) is the agent
            case null when Package.IsPacked && !Package.RunningInstalled: return Package.FirstRun(settings);
            case null or "--after" or "--agent": return RunAgent(args);
            case "--version": return Report(() => Package.Version, quiet: true);
            case "--install": return Report(() => Package.Install(settings), quiet);
            case "--uninstall": return Report(() => Package.Uninstall(settings), quiet);
            case "--install-hooks": return Report(() => Installer.InstallHooks(settings, showork));
            case "--uninstall-hooks": return Report(() => Installer.UninstallHooks(settings));
            case "--install-autostart": return Report(() => { Installer.SetAutostart(true, self); return "on"; });
            case "--uninstall-autostart": return Report(() => { Installer.SetAutostart(false, self); return "off"; });
            case "--status":
                return Report(() => $"hooks installed: {Installer.CountOurs(settings)}/{Installer.OurHooks("x").Sum(kv => kv.Value!.AsArray().Count)}   autostart: {Installer.Autostart() ?? "off"}   " +
                                    $"agent running: {Installer.InstalledAgents().Count > 0}");
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
    /// Started from Settings → Apps (no console to attach to), the answer goes into a dialog unless --quiet.
    static int Report(Func<string> action, bool quiet = true)
    {
        bool console = AttachConsole(unchecked((uint)-1));
        try
        {
            var r = action();
            Console.WriteLine(r);
            if (!console && !quiet) { ApplicationConfiguration.Initialize(); Package.Info("ShoWork42", r); }
            return 0;
        }
        catch (Exception e)
        {
            Console.Error.WriteLine($"error: {e.Message}");
            if (!console && !quiet)
            {
                ApplicationConfiguration.Initialize();
                TaskDialog.ShowDialog(new TaskDialogPage { Caption = "ShoWork42", Heading = "沒有完成", Text = e.Message, Icon = TaskDialogIcon.Error });
            }
            return 1;
        }
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
        // W2/W3 wiring: the settings file owns 自動排版; the tray menu and the settings page both change it there
        var settings = GlowSettings.Shared;
        Arranger.AutoEnabled = settings.General.AutoArrange;
        settings.Changed += () => Arranger.AutoEnabled = settings.General.AutoArrange;
        TrayHooks.OpenSettings = SettingsWindow.ShowSingleton;
        TrayHooks.ArrangeNow = Arranger.ArrangeNow;
        TrayHooks.GetAutoArrange = () => settings.General.AutoArrange;
        TrayHooks.SetAutoArrange = on => settings.SetGeneral(settings.General with { AutoArrange = on });
        Arranger.Start();                                      // W3: Ctrl+Alt+L, auto arrange (stops itself on exit)
        // W2 tests: SHOWORK_OPEN_SETTINGS=1 opens the settings window at start, =N (seconds) opens it later, like a user would
        if (int.TryParse(Environment.GetEnvironmentVariable("SHOWORK_OPEN_SETTINGS"), out var openAfter) && openAfter > 0)
        {
            var open = new System.Windows.Forms.Timer { Interval = openAfter == 1 ? 1 : openAfter * 1000 };
            open.Tick += (_, _) => { open.Dispose(); SettingsWindow.ShowSingleton(); };
            open.Start();
        }
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
