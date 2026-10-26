using System.Diagnostics;
using System.Reflection;
using Microsoft.Win32;

namespace ShoWork;

/// W4: one downloadable exe. pack.ps1 builds ShoWork42.exe (runtime inside) and ShoWork42-small.exe (needs the
/// .NET 8 Desktop Runtime); both carry the native showork.exe as a resource. Double-click one and it offers to
/// install itself into %LOCALAPPDATA%\ShoWork42\bin (per user, no admin), and it shows up in Settings → Apps
/// for uninstalling. A dev build (no resource inside) keeps the old behaviour: no arguments = run the agent.
static class Package
{
    const string Name = "ShoWork42", AgentExe = "ShoWorkAgent.exe", CliExe = "showork.exe";

    public static string Version =>
        typeof(Package).Assembly.GetCustomAttribute<AssemblyInformationalVersionAttribute>()?.InformationalVersion.Split('+')[0]
        ?? typeof(Package).Assembly.GetName().Version?.ToString(3) ?? "0";

    /// A packaged exe: the native showork.exe travels inside it.
    public static bool IsPacked => typeof(Package).Assembly.GetManifestResourceInfo(CliExe) != null;

    static string Bin => Installer.InstallDir;
    static string InstalledAgent => Path.Combine(Bin, AgentExe);

    public static bool RunningInstalled =>
        Native.SamePath(Environment.ProcessPath!, InstalledAgent);

    // MARK: install / uninstall

    /// Stop the installed agent, put this build into bin, merge the hooks, autostart, list in Settings → Apps, start.
    public static string Install(string settings)
    {
        Installer.StopRunningAgents();
        Directory.CreateDirectory(Bin);
        if (IsPacked)
        {
            if (!RunningInstalled) CopyAtomic(Environment.ProcessPath!, InstalledAgent);
            using (var s = typeof(Package).Assembly.GetManifestResourceStream(CliExe)!) WriteAtomic(s, Path.Combine(Bin, CliExe));
            // a packaged install is exactly two files; whatever an older dev install left (dlls, json) goes
            foreach (var f in Directory.GetFiles(Bin))
                if (!Path.GetFileName(f).Equals(AgentExe, StringComparison.OrdinalIgnoreCase) && !Path.GetFileName(f).Equals(CliExe, StringComparison.OrdinalIgnoreCase))
                    try { File.Delete(f); } catch { }
        }
        else
        {
            var here = Path.GetFullPath(AppContext.BaseDirectory).TrimEnd('\\');
            if (!Native.SamePath(here, Bin)) Installer.CopyBuild(here, Bin);
        }
        var hooks = Installer.InstallHooks(settings, Path.Combine(Bin, CliExe));
        Installer.SetAutostart(true, InstalledAgent);
        Register();
        // ShellExecute: the agent must not inherit our stdout (a caller piping us would wait forever)
        Process.Start(new ProcessStartInfo(InstalledAgent) { UseShellExecute = true, WorkingDirectory = Bin });
        return $"installed {Version} to {Bin}; hooks: {hooks}; autostart: on; agent: running";
    }

    /// Everything Install did, undone. settings.json (the glow look) stays for a later reinstall.
    public static string Uninstall(string settings)
    {
        Installer.StopRunningAgents();
        var hooks = Installer.UninstallHooks(settings);
        Installer.SetAutostart(false, "");
        Unregister();
        foreach (var f in new[] { "state.json", "agent.log" }) try { File.Delete(Path.Combine(Wire.SupportDir, f)); } catch { }
        string files;
        if (!Directory.Exists(Bin)) files = "no files";
        else if (RunningInstalled)
        {
            // an exe can't delete itself: a hidden cmd does it once we have exited, retrying for ~15 s
            // (a 155 MB exe that was just scanned or is still unmapping stays locked for a moment)
            Process.Start(new ProcessStartInfo("cmd.exe",
                    $"/d /c for /l %i in (1,1,15) do @if exist \"{Bin}\" (ping -n 2 127.0.0.1 >nul & rmdir /s /q \"{Bin}\" 2>nul)")
                { UseShellExecute = false, CreateNoWindow = true, WorkingDirectory = Path.GetTempPath() });
            files = $"{Bin} removed after exit";
        }
        else { Directory.Delete(Bin, recursive: true); files = $"{Bin} removed"; }
        return $"hooks: {hooks}; autostart: off; Settings → Apps: removed; {files}";
    }

    static void CopyAtomic(string from, string to)
    {
        using var s = File.OpenRead(from);
        WriteAtomic(s, to);
    }

    static void WriteAtomic(Stream s, string to)
    {
        var tmp = to + ".new";
        using (var f = File.Create(tmp)) s.CopyTo(f);
        File.Move(tmp, to, overwrite: true);                     // never a half-written binary
    }

    // MARK: Settings → Apps (HKCU Uninstall key: per user, no admin)

    static string UninstallKey => Installer.RegRoot + @"\Uninstall\" + Name;

    static void Register()
    {
        using var k = Registry.CurrentUser.CreateSubKey(UninstallKey);
        k.SetValue("DisplayName", Name);
        k.SetValue("DisplayVersion", Version);
        k.SetValue("Publisher", Name);
        k.SetValue("DisplayIcon", InstalledAgent);
        k.SetValue("InstallLocation", Bin);
        k.SetValue("UninstallString", $"\"{InstalledAgent}\" --uninstall");
        k.SetValue("QuietUninstallString", $"\"{InstalledAgent}\" --uninstall --quiet");
        k.SetValue("NoModify", 1, RegistryValueKind.DWord);
        k.SetValue("NoRepair", 1, RegistryValueKind.DWord);
        var kb = Directory.GetFiles(Bin).Sum(f => new FileInfo(f).Length) / 1024;
        k.SetValue("EstimatedSize", (int)Math.Min(kb, int.MaxValue), RegistryValueKind.DWord);
    }

    static void Unregister()
    {
        using var root = Registry.CurrentUser.OpenSubKey(Installer.RegRoot + @"\Uninstall", writable: true);
        if (root?.OpenSubKey(Name) != null) root.DeleteSubKeyTree(Name);
    }

    public static string? InstalledVersion
    {
        get
        {
            using var k = Registry.CurrentUser.OpenSubKey(UninstallKey);
            return File.Exists(InstalledAgent) ? k?.GetValue("DisplayVersion") as string ?? "?" : null;
        }
    }

    // MARK: double-click on the downloaded exe

    /// Ask before touching anything: what gets installed, where, and that Claude's settings are merged (and backed up).
    public static int FirstRun(string settings)
    {
        ApplicationConfiguration.Initialize();
        var installed = InstalledVersion;
        if (installed == Version)
        {
            if (Installer.InstalledAgents().Count == 0)
                Process.Start(new ProcessStartInfo(InstalledAgent) { UseShellExecute = true, WorkingDirectory = Bin });
            Info("ShoWork42 已經安裝好了", $"版本 {Version}，正在執行（右下角系統匣的圓點）。右鍵圓點 →「設定…」可以調整光暈。");
            return 0;
        }
        var page = new TaskDialogPage
        {
            Caption = Name,
            Heading = installed == null ? $"安裝 ShoWork42 {Version}？" : $"把 ShoWork42 從 {installed} 更新到 {Version}？",
            Text = "終端機裡的 AI 在工作（紫）、做完了（綠）、在等你回答（紅）時，視窗外圍會發光。\n\n安裝會：\n" +
                   $"• 放到 {Bin}（只有你這個帳號，不需要系統管理員）\n" +
                   "• 在 Claude Code 的設定（~/.claude/settings.json）加上 ShoWork 的 hooks，寫入前先備份；解除安裝時原樣拿掉\n" +
                   "• 開機時自動啟動，並列在「設定 > 應用程式」裡可以解除安裝",
            Buttons = { new TaskDialogButton(installed == null ? "安裝" : "更新") { Tag = true }, TaskDialogButton.Cancel },
            Icon = TaskDialogIcon.Information,
        };
        if (TaskDialog.ShowDialog(page).Tag is not true) return 0;
        try
        {
            Install(settings);
            Info(installed == null ? "安裝好了" : "更新好了",
                 "右下角系統匣有 ShoWork42 的圓點：左鍵看各個 AI 的狀態，右鍵有設定。\n已經開著的 Claude Code 會自動讀到新的 hooks；下一次送出提示就會開始發光。");
            return 0;
        }
        catch (Exception e)
        {
            TaskDialog.ShowDialog(new TaskDialogPage { Caption = Name, Heading = "安裝失敗", Text = e.Message, Icon = TaskDialogIcon.Error });
            return 1;
        }
    }

    public static void Info(string heading, string text) =>
        TaskDialog.ShowDialog(new TaskDialogPage { Caption = Name, Heading = heading, Text = text, Icon = TaskDialogIcon.ShieldSuccessGreenBar });
}
