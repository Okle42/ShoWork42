using System.Diagnostics;
using Microsoft.Win32;

namespace ShoWork;

/// Claude Code hooks (InstallerHooks.cs) and autostart, both reversible. Same safety rules as the Mac showork_install.py:
///   • back up settings.json before every write (settings.json.bak-<time>, next to it)
///   • merge only: append our hook groups; never touch, reorder or rewrite anyone else's (an older ShoWork42's groups are replaced, like the Mac installer)
///   • idempotent: installing twice changes nothing
///   • uninstall removes exactly the groups whose command runs showork.exe emit … --agent claude (or brief／title／guard-push)
///   • write atomically and re-parse before replacing the file
/// Plus: install keeps the original bytes; if uninstall leaves exactly that content, those bytes are
/// written back, so install + uninstall is byte-for-byte a no-op.
static partial class Installer
{
    // MARK: autostart — HKCU Run, per user, no admin

    /// HKCU\Software\Microsoft\Windows\CurrentVersion; SHOWORK_REG_ROOT moves Run and Uninstall under another HKCU key (tests).
    public static string RegRoot =>
        Environment.GetEnvironmentVariable("SHOWORK_REG_ROOT") is { Length: > 0 } r ? r : @"Software\Microsoft\Windows\CurrentVersion";
    static string RunKey => RegRoot + @"\Run";
    const string RunName = "ShoWork42";

    public static void SetAutostart(bool on, string agentExe)
    {
        using var k = Registry.CurrentUser.CreateSubKey(RunKey);
        if (on) k.SetValue(RunName, $"\"{agentExe}\"");
        else if (k.GetValue(RunName) != null) k.DeleteValue(RunName);
    }

    public static string? Autostart()
    {
        using var k = Registry.CurrentUser.OpenSubKey(RunKey);
        return k?.GetValue(RunName) as string;
    }

    // MARK: whole install — copy the build to %LOCALAPPDATA%\ShoWork42\bin, hooks, autostart, start

    /// Running agents started from the install folder — a dev or test build running elsewhere is none of our business.
    public static List<Process> InstalledAgents()
    {
        var installed = Path.GetFullPath(Path.Combine(InstallDir, "ShoWorkAgent.exe"));
        return Process.GetProcessesByName("ShoWorkAgent").Where(p =>
        {
            if (p.Id == Environment.ProcessId) return false;
            try { return p.MainModule?.FileName is { } f && Native.SamePath(f, installed); } catch { return false; }
        }).ToList();
    }

    public static void StopRunningAgents()
    {
        foreach (var p in InstalledAgents())
        {
            try { p.Kill(); p.WaitForExit(3000); } catch { }
        }
    }

    public static void CopyBuild(string from, string to)
    {
        Directory.CreateDirectory(to);
        foreach (var f in Directory.GetFiles(from))
        {
            var name = Path.GetFileName(f);
            if (name.EndsWith(".pdb", StringComparison.OrdinalIgnoreCase)) continue;
            var tmp = Path.Combine(to, "." + name + ".new");
            File.Copy(f, tmp, overwrite: true);
            File.Move(tmp, Path.Combine(to, name), overwrite: true);   // never a half-copied binary
        }
        // W6 office tower: the page (Web\) and WebView2Loader.dll (runtimes\win-*\native\) live in subfolders of a normal build
        // (the packed single exe carries both inside, so these folders only exist for dev builds)
        foreach (var sub in new[] { "Web", "runtimes" })
            if (Directory.Exists(Path.Combine(from, sub))) CopyTree(Path.Combine(from, sub), Path.Combine(to, sub));
    }

    static void CopyTree(string from, string to)
    {
        Directory.CreateDirectory(to);
        foreach (var f in Directory.GetFiles(from))
        {
            var name = Path.GetFileName(f);
            var tmp = Path.Combine(to, "." + name + ".new");
            File.Copy(f, tmp, overwrite: true);
            File.Move(tmp, Path.Combine(to, name), overwrite: true);
        }
        foreach (var d in Directory.GetDirectories(from)) CopyTree(d, Path.Combine(to, Path.GetFileName(d)));
    }
}
