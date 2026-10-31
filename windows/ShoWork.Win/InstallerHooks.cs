using System.Text;
using System.Text.Encodings.Web;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;

namespace ShoWork;

/// Claude Code hooks: merge into / remove from settings.json (the rules are in Installer.cs's header).
/// Pure file work, no WinForms or registry, so windows/tests/ShoWork.Tests links this file and runs it on macOS too.
static partial class Installer
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

    static readonly Regex Ours = new(@"showork\.exe""? (emit (working|done|input|clear) --agent claude|brief|title|guard-push)$");

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
        // 戰情中心的 hook 端（W5，同 Mac 的 showork_install.py）：brief／title／guard-push 的輸出 Claude 要用，不能 async
        JsonObject Sub(string? matcher, string sub, int timeout)
        {
            var g = new JsonObject();
            if (matcher != null) g["matcher"] = matcher;
            g["hooks"] = new JsonArray(new JsonObject { ["type"] = "command", ["command"] = $"\"{showork.Replace('\\', '/')}\" {sub}", ["timeout"] = timeout });
            return g;
        }
        // The question dialog (AskUserQuestion) shows at once, but its elicitation Notification arrives
        // ~6 s later (Mac, 09-28), so its PreToolUse turns red directly — and the catch-all "working"
        // excludes it, or a late purple could land on top of the red. Permission prompts have no such delay.
        var pre = Group("AskUserQuestion", "input");
        pre.Add(Group("^(?!AskUserQuestion$).*", "working", async: true)[0]!.DeepClone());
        // 動作預告（擋／告）＋1 樓保全的 push 守門；不是高風險指令也不是 git push 就馬上放行
        pre.Add(Sub("Bash", "guard-push", 60));
        var prompt = Group(null, "working", async: true);
        // 開工卡提醒；使用者打「放行」放行被擋的指令（Windows 不改視窗標題，所以只裝在 UserPromptSubmit）
        prompt.Add(Sub(null, "title", 2));
        return new JsonObject
        {
            ["UserPromptSubmit"] = prompt,
            ["PreToolUse"] = pre,
            // Windows 09-28: the permission_prompt Notification also comes ~6 s after the dialog appears;
            // PermissionRequest fires as the dialog opens. (Answer within 6 s and the Notification never comes.)
            ["PermissionRequest"] = Group(null, "input"),
            ["PostToolUse"] = Group("*", "working", async: true),
            ["Stop"] = Group(null, "done"),
            // permission prompts / questions only — the 60 s idle reminder would turn green into red
            ["Notification"] = Group("permission_prompt|elicitation_dialog", "input"),
            ["SessionEnd"] = Group(null, "clear"),
            // 每個新 session（含 /clear、壓縮後）告訴 AI 每輪用 `showork card` 自報
            ["SessionStart"] = new JsonArray(Sub(null, "brief", 2)),
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
            // already ours and identical: nothing to do. An older ShoWork42 left different ones (W5 added title／guard-push／brief,
            // or the exe moved): replace only ours, everyone else's groups keep their place (same as the Mac installer's merge)
            var mine = list.Where(IsOurs).ToList();
            var want = groups!.AsArray();
            if (mine.Count == want.Count && mine.Zip(want).All(p => JsonNode.DeepEquals(p.First, p.Second))) continue;
            var others = list.Where(g => !IsOurs(g)).Select(g => g?.DeepClone()).ToList();
            hooks[ev] = new JsonArray(others.Concat(want.Select(g => g!.DeepClone())).ToArray());
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
}
