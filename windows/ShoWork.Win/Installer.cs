using System.Diagnostics;
using System.Text;
using System.Text.Encodings.Web;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;
using Microsoft.Win32;

namespace ShoWork;

/// Claude Code hooks and autostart, both reversible. Same safety rules as the Mac showork_install.py:
///   • back up settings.json before every write (settings.json.bak-<time>, next to it)
///   • merge only: append our hook groups; never touch, reorder or rewrite anyone else's
///   • idempotent: installing twice changes nothing
///   • uninstall removes exactly the groups whose command runs showork.exe emit … --agent claude
///   • write atomically and re-parse before replacing the file
/// Plus: install keeps the original bytes; if uninstall leaves exactly that content, those bytes are
/// written back, so install + uninstall is byte-for-byte a no-op.
static class Installer
{
    static string SupportDir => Wire.SupportDir;
    public static string InstallDir => Path.Combine(SupportDir, "bin");
    static string Pristine => Path.Combine(SupportDir, "settings.pre-install.json");
    static string PristineAbsent => Pristine + ".absent";

    public static string DefaultSettings
    {
        get
        {
            var dir = Environment.GetEnvironmentVariable("CLAUDE_CONFIG_DIR");
            if (string.IsNullOrEmpty(dir)) dir = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".claude");
            return Path.Combine(dir, "settings.json");
        }
    }

    static readonly Regex Ours = new(@"showork\.exe""? emit (working|done|input|clear) --agent claude$");

    /// Claude Code on Windows runs hook commands with Git Bash: quote the path (the user folder has a
    /// space) and use forward slashes (a backslash is an escape character to bash).
    ///
    /// Git Bash + a .NET exe costs ~0.2 s per hook, so the purple hooks that fire on every tool call run
    /// async (Claude doesn't wait for them); showork stamps each event with the hook's start time and the
    /// agent drops a late, older one. The green/red/clear hooks stay synchronous, like the Mac version.
    public static JsonObject OurHooks(string showork)
    {
        JsonObject Cmd(string ev, bool async)
        {
            var c = new JsonObject
            {
                ["type"] = "command",
                ["command"] = $"\"{showork.Replace('\\', '/')}\" emit {ev} --agent claude",
                ["timeout"] = 2,
            };
            if (async) c["async"] = true;
            return c;
        }
        JsonArray Group(string? matcher, string ev, bool async = false)
        {
            var g = new JsonObject();
            if (matcher != null) g["matcher"] = matcher;
            g["hooks"] = new JsonArray(Cmd(ev, async));
            return new JsonArray(g);
        }
        // The question dialog (AskUserQuestion) shows at once, but its elicitation Notification arrives
        // ~6 s later (Mac, 09-28), so its PreToolUse turns red directly — and the catch-all "working"
        // excludes it, or a late purple could land on top of the red. Permission prompts have no such delay.
        var pre = Group("AskUserQuestion", "input");
        pre.Add(Group("^(?!AskUserQuestion$).*", "working", async: true)[0]!.DeepClone());
        return new JsonObject
        {
            ["UserPromptSubmit"] = Group(null, "working", async: true),
            ["PreToolUse"] = pre,
            // Windows 09-28: the permission_prompt Notification also comes ~6 s after the dialog appears;
            // PermissionRequest fires as the dialog opens. (Answer within 6 s and the Notification never comes.)
            ["PermissionRequest"] = Group(null, "input"),
            ["PostToolUse"] = Group("*", "working", async: true),
            ["Stop"] = Group(null, "done"),
            // permission prompts / questions only — the 60 s idle reminder would turn green into red
            ["Notification"] = Group("permission_prompt|elicitation_dialog", "input"),
            ["SessionEnd"] = Group(null, "clear"),
        };
    }

    static bool IsOurs(JsonNode? group) =>
        group?["hooks"] is JsonArray hs && hs.Any(h => h?["command"]?.GetValue<string>() is string c && Ours.IsMatch(c));

    public static string InstallHooks(string settings, string showork)
    {
        var (root, original) = Load(settings);
        var hooks = root["hooks"] as JsonObject;
        if (hooks == null) { hooks = new JsonObject(); root["hooks"] = hooks; }
        bool changed = false;
        foreach (var (ev, groups) in OurHooks(showork))
        {
            var list = hooks[ev] as JsonArray;
            if (list == null) { list = new JsonArray(); hooks[ev] = list; }
            if (list.Any(IsOurs)) continue;
            foreach (var g in groups!.AsArray()) list.Add(g!.DeepClone());
            changed = true;
        }
        if (!changed) return "already installed";
        // remember the untouched file, once: an uninstall that gets back to it restores these exact bytes
        if (!HasOurs(original))
        {
            Directory.CreateDirectory(SupportDir);
            if (original == null) { File.WriteAllText(PristineAbsent, ""); File.Delete(Pristine); }
            else { File.WriteAllBytes(Pristine, original); File.Delete(PristineAbsent); }
        }
        Save(settings, root, original);
        return "merged";
    }

    public static string UninstallHooks(string settings)
    {
        var (root, original) = Load(settings);
        if (original == null) return "nothing to remove";
        bool changed = false;
        if (root["hooks"] is JsonObject hooks)
        {
            foreach (var ev in hooks.Select(kv => kv.Key).ToList())
            {
                if (hooks[ev] is not JsonArray list) continue;
                var keep = list.Where(g => !IsOurs(g)).Select(g => g?.DeepClone()).ToList();
                if (keep.Count == list.Count) continue;
                changed = true;
                if (keep.Count > 0) hooks[ev] = new JsonArray(keep.ToArray());
                else hooks.Remove(ev);                                  // we created this list; leave no trace
            }
            if (changed && hooks.Count == 0) root.Remove("hooks");
        }
        if (!changed) return "nothing to remove";
        Backup(settings);
        if (File.Exists(Pristine) && JsonNode.DeepEquals(root, Parse(File.ReadAllBytes(Pristine))))
            WriteAtomic(settings, File.ReadAllBytes(Pristine));
        else if (File.Exists(PristineAbsent) && root.Count == 0)
            File.Delete(settings);
        else
            WriteAtomic(settings, Serialize(root, original));
        File.Delete(Pristine);
        File.Delete(PristineAbsent);
        return "removed";
    }

    public static int CountOurs(string settings)
    {
        var (root, _) = Load(settings);
        return root["hooks"] is JsonObject h ? h.Sum(kv => kv.Value is JsonArray a ? a.Count(IsOurs) : 0) : 0;
    }

    static bool HasOurs(byte[]? bytes)
    {
        if (bytes == null) return false;
        try { return Parse(bytes)?["hooks"] is JsonObject h && h.Any(kv => kv.Value is JsonArray a && a.Any(IsOurs)); }
        catch { return false; }
    }

    static (JsonObject root, byte[]? original) Load(string path)
    {
        if (!File.Exists(path)) return (new JsonObject(), null);
        var bytes = File.ReadAllBytes(path);
        var node = Parse(bytes);
        return (node as JsonObject ?? throw new InvalidDataException($"{path} is not a JSON object"), bytes);
    }

    /// Lenient like Claude Code: a UTF-8 BOM, comments and trailing commas are fine.
    static JsonNode? Parse(byte[] bytes) =>
        JsonNode.Parse(bytes is [0xEF, 0xBB, 0xBF, ..] ? bytes.AsSpan(3) : bytes, documentOptions: new JsonDocumentOptions { CommentHandling = JsonCommentHandling.Skip, AllowTrailingCommas = true });

    static void Save(string path, JsonObject root, byte[]? original)
    {
        Backup(path);
        WriteAtomic(path, Serialize(root, original));
    }

    /// Two-space JSON like Claude Code writes it, keeping the file's own line endings, final newline and BOM.
    static byte[] Serialize(JsonObject root, byte[]? original)
    {
        var text = root.ToJsonString(new JsonSerializerOptions { WriteIndented = true, Encoder = JavaScriptEncoder.UnsafeRelaxedJsonEscaping });
        var o = original == null ? "" : Encoding.UTF8.GetString(original);
        text = text.Replace("\r\n", "\n");                              // .NET 8 indents with Environment.NewLine
        if (o.Contains("\r\n")) text = text.Replace("\n", "\r\n");
        if (original == null || o.EndsWith('\n')) text += o.Contains("\r\n") ? "\r\n" : "\n";
        var bom = original is [0xEF, 0xBB, 0xBF, ..];
        return (bom ? Encoding.UTF8.GetPreamble() : Array.Empty<byte>()).Concat(Encoding.UTF8.GetBytes(text)).ToArray();
    }

    static void Backup(string path)
    {
        if (File.Exists(path)) File.Copy(path, $"{path}.bak-{DateTime.Now:yyyyMMdd-HHmmss}", overwrite: true);
    }

    static void WriteAtomic(string path, byte[] bytes)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        var tmp = Path.Combine(Path.GetDirectoryName(path)!, $".settings.{Environment.ProcessId}.tmp");
        File.WriteAllBytes(tmp, bytes);
        Parse(File.ReadAllBytes(tmp));
        File.Move(tmp, path, overwrite: true);
    }

    // MARK: autostart — HKCU Run, per user, no admin

    const string RunKey = @"Software\Microsoft\Windows\CurrentVersion\Run", RunName = "ShoWork42";

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
            try { return string.Equals(p.MainModule?.FileName, installed, StringComparison.OrdinalIgnoreCase); } catch { return false; }
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
    }
}
