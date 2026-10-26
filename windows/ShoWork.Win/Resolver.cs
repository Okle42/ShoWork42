using System.Diagnostics;
using System.Text;
using static ShoWork.Native;

namespace ShoWork;

/// AI process → the window you see. The Windows counterpart of the Mac Resolver (tty → window).
///
///   classic console   AttachConsole(pid) → GetConsoleWindow() is the ConsoleWindowClass window itself
///   Windows Terminal  GetConsoleWindow() is ConPTY's hidden PseudoConsoleWindow; WT sets its OWNER to the
///                     WT window that currently holds the tab (and re-owns it when a tab is dragged to another
///                     window), so owner = the window, for background tabs too. Measured on WT 1.24.
///   anything else     (VS Code terminal, no owner, unknown class) ⇒ no window: better dark than the wrong window
static class Resolver
{
    public const string ConsoleClass = "ConsoleWindowClass", PseudoClass = "PseudoConsoleWindow", TerminalClass = "CASCADIA_HOSTING_WINDOW_CLASS";

    public readonly record struct ConsoleInfo(int Pid, IntPtr Hwnd, string Title);

    /// showork.exe sits next to the agent. Attaching to another process's console happens there, in a
    /// throwaway process: a Ctrl+C or a closed tab during the attach would otherwise hit the agent.
    static string Helper => Path.Combine(AppContext.BaseDirectory, "showork.exe");

    /// Console window + console title of each pid (runs the helper; call off the UI thread).
    public static List<ConsoleInfo> Consoles(IEnumerable<int> pids)
    {
        var list = new List<ConsoleInfo>();
        var args = string.Join(' ', pids);
        if (args.Length == 0) return list;
        try
        {
            var psi = new ProcessStartInfo(Helper, "console " + args)
            {
                UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true, StandardOutputEncoding = Encoding.UTF8,
            };
            using var p = Process.Start(psi)!;
            var output = p.StandardOutput.ReadToEndAsync();
            if (!p.WaitForExit(3000)) { try { p.Kill(); } catch { } return list; }
            foreach (var line in output.Result.Split('\n', StringSplitOptions.RemoveEmptyEntries))
            {
                var f = line.Split('\t');
                if (f.Length >= 3 && int.TryParse(f[0], out var pid) && long.TryParse(f[1], out var h))
                    list.Add(new ConsoleInfo(pid, new IntPtr(h), f[2]));
            }
        }
        catch (Exception e) { Log.Note($"HELPER {e.GetType().Name}: {e.Message}"); }
        return list;
    }

    /// The window to glow for a console (0 = none). Cheap; evaluated on every render and watchdog tick
    /// because a WT tab can be dragged into another window at any time.
    public static IntPtr WindowOf(IntPtr console)
    {
        if (console == IntPtr.Zero || !IsWindow(console)) return IntPtr.Zero;
        var cls = ClassOf(console);
        if (cls == ConsoleClass) return console;
        if (cls == PseudoClass)
        {
            var owner = GetWindow(console, GW_OWNER);
            if (owner != IntPtr.Zero && ClassOf(owner) == TerminalClass) return owner;
        }
        return IntPtr.Zero;
    }

    public static bool IsTerminal(IntPtr window) => ClassOf(window) == TerminalClass;

    /// Every visible Windows Terminal window.
    public static List<IntPtr> Terminals()
    {
        var list = new List<IntPtr>();
        EnumWindows((h, _) => { if (IsWindowVisible(h) && ClassOf(h) == TerminalClass) list.Add(h); return true; }, IntPtr.Zero);
        return list;
    }

    /// A title without the glyphs AI tools put in front and keep changing (Claude's ◐◑◒◓ spinner, ✳ idle, · ).
    public static string BareTitle(string title) =>
        System.Text.RegularExpressions.Regex.Replace(title ?? "", @"^[^\p{L}\p{N}]+", "").Trim();

    /// Every pane of every tab in a WT window has its own PseudoConsoleWindow owned by that window.
    public static List<IntPtr> PanesOf(IntPtr terminal)
    {
        var list = new List<IntPtr>();
        EnumWindows((h, _) =>
        {
            if (GetWindow(h, GW_OWNER) == terminal && ClassOf(h) == PseudoClass) list.Add(h);
            return true;
        }, IntPtr.Zero);
        return list;
    }

    /// Is this WT pane the one on screen? WT's window title is the active pane's title and ConPTY keeps
    /// each pane's title, so compare (read-only; nothing is ever written to a title).
    ///   window title == mine                      → selected
    ///   window title == some other pane's, not mine → background: keep green
    ///   no match (renamed tab, suppressed titles)  → can't tell: treat as selected (the active tab stays right)
    public static bool LooksSelected(string windowTitle, string mine, IEnumerable<string> others) =>
        windowTitle == mine || !others.Contains(windowTitle);
}
