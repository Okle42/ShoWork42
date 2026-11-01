using System.Diagnostics;
using System.Globalization;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace ShoWork.Hooks;

// `showork statusline`：Claude Code 的 statusLine 指令（Mac 是使用者自己的 ~/.claude/scripts/statusline.py；Windows 沒有，做進 showork.exe）。
// Claude Code 每次刷新狀態列都把一份 JSON 從 stdin 給它（context_window、rate_limits、model、cost⋯，訂閱制才有 rate_limits）。
// 這裡做兩件事，跟 Mac statusline.py 寫的檔一模一樣（戰情中心 BoardReader 讀的就是這兩份）：
//   ~/.claude/cache/ctx/<session_id>.json   {"used_percentage":…, "total_input_tokens":…, "at": unix 秒}（卡片的 ctx、Stop hook 的收尾門檻）
//   ~/.claude/cache/rate_limits.json        {"rate_limits":{"five_hour":{used_percentage,resets_at},"seven_day":{…}}, "at":"yyyy-MM-dd HH:mm:ss"}
//     多個 session 的狀態列輪流寫，閒著的 session 手上是舊數字 ⇒ 合併寫入（10-26 Mac 修過的跳動）：
//     重置時間晚的一定比較新；同一時段（差 10 分鐘內）取較大的 %；已過重置時間的舊值丟掉；原子寫入。
// 印出的狀態列：使用者原本有自己的 statusLine ⇒ 安裝時記在 statusline-chain.json，這裡把同一份 stdin 交給它、原樣印它的輸出（串接，不蓋掉）；
// 沒有 ⇒ 印一行簡短的「模型｜ctx｜5h｜7d」。
static class StatusLine
{
    public static string CtxDir => Path.Combine(HookPaths.ClaudeDir, "cache", "ctx");
    public static string RateLimitsPath => Path.Combine(HookPaths.ClaudeDir, "cache", "rate_limits.json");
    /// 安裝器記下的「使用者原本的 statusLine」（InstallerHooks.cs 寫）
    public static string ChainPath => Path.Combine(HookPaths.Support, "statusline-chain.json");

    static double? Num(JsonNode? o, string k) => o is JsonObject j && j[k] is JsonValue v && v.GetValueKind() == JsonValueKind.Number ? v.GetValue<double>() : null;

    /// 寫檔（ctx、rate_limits）；回傳解析好的 stdin（null＝不是 JSON）
    public static JsonObject? Record(string? stdin, DateTime now)
    {
        if (HookJson.Parse(stdin) is not JsonObject d) return null;
        double nowSec = (now - DateTime.UnixEpoch).TotalSeconds;
        var ctx = d["context_window"];
        if (Num(ctx, "used_percentage") is { } used && d.Str("session_id") is { Length: > 0 } sid && sid.IndexOfAny(Path.GetInvalidFileNameChars()) < 0)
            HookJson.WriteAtomic(Path.Combine(CtxDir, sid + ".json"), HookJson.Text(new JsonObject
            {
                ["used_percentage"] = used, ["total_input_tokens"] = Num(ctx, "total_input_tokens") ?? 0, ["at"] = nowSec,
            }));
        if (d["rate_limits"] is JsonObject rl && rl.Count > 0)
        {
            var old = HookJson.ReadObject(RateLimitsPath)?["rate_limits"] as JsonObject;
            var merged = Merge(old, rl, nowSec);
            HookJson.WriteAtomic(RateLimitsPath, HookJson.Text(new JsonObject
            {
                ["rate_limits"] = merged, ["at"] = now.ToLocalTime().ToString("yyyy-MM-dd HH:mm:ss", CultureInfo.InvariantCulture),
            }));
        }
        return d;
    }

    /// statusline.py 的合併規則（純函式）
    public static JsonObject Merge(JsonObject? old, JsonObject fresh, double nowSec)
    {
        var merged = (JsonObject)fresh.DeepClone();
        foreach (var k in new[] { "five_hour", "seven_day" })
        {
            var o = old?[k] as JsonObject; var n = fresh[k] as JsonObject;
            if (o == null || o.Count == 0 || (Num(o, "resets_at") ?? 0) <= nowSec) continue;    // 舊的已過重置時間就不留
            if (n == null || n.Count == 0) { merged[k] = o.DeepClone(); continue; }
            double ro = Num(o, "resets_at") ?? 0, rn = Num(n, "resets_at") ?? 0;
            if (ro - rn > 600 || (Math.Abs(ro - rn) <= 600 && (Num(o, "used_percentage") ?? 0) > (Num(n, "used_percentage") ?? 0)))
                merged[k] = o.DeepClone();
        }
        return merged;
    }

    // MARK: 印出來的那一行

    const string R = "\u001b[0m", Dim = "\u001b[2m";
    static string C(string code, string s) => $"\u001b[{code}m{s}{R}";
    static string Heat(double p) => p >= 85 ? "91" : p >= 60 ? "93" : "92";

    /// 距離重置還多久：2h05m、3d4h、45m
    public static string Until(double? resetsAt, double nowSec)
    {
        if (resetsAt is not { } r || r <= nowSec) return "";
        var s = (long)(r - nowSec);
        if (s >= 86400) return $"{s / 86400}d{s % 86400 / 3600}h";
        if (s >= 3600) return $"{s / 3600}h{s % 3600 / 60:00}m";
        return $"{s / 60}m";
    }

    /// 沒串接時自己的狀態列：模型｜ctx 23% 46k｜5h 15%↻2h05m｜7d 15%↻3d4h
    public static string Line(JsonObject d, DateTime now)
    {
        double nowSec = (now - DateTime.UnixEpoch).TotalSeconds;
        var parts = new List<string>();
        if (d["model"].Str("display_name") is { Length: > 0 } m) parts.Add(C("96", m));
        var ctx = d["context_window"];
        if (Num(ctx, "used_percentage") is { } used)
        {
            var tot = Num(ctx, "total_input_tokens") ?? 0;
            parts.Add($"{Dim}ctx{R} {C(Heat(used), $"{used:0}%")}" + (tot > 0 ? $" {Dim}{tot / 1000:0}k{R}" : ""));
        }
        foreach (var (key, label) in new[] { ("five_hour", "5h"), ("seven_day", "7d") })
        {
            if (d["rate_limits"]?[key] is not JsonObject w || Num(w, "used_percentage") is not { } p) continue;
            var left = Until(Num(w, "resets_at"), nowSec);
            parts.Add($"{Dim}{label}{R} {C(Heat(p), $"{p:0}%")}" + (left.Length > 0 ? $"{Dim}↻{left}{R}" : ""));
        }
        if (Num(d["cost"], "total_cost_usd") is { } cost) parts.Add(C("92", $"${cost:0.00}"));
        return string.Join("  ", parts);
    }

    /// 使用者原本的 statusLine 指令（安裝時記下的）；沒有＝null
    public static string? ChainedCommand() => HookJson.ReadObject(ChainPath)?["statusLine"].Str("command") is { Length: > 0 } c ? c : null;

    /// 跑使用者原本的指令：同一份 stdin、原樣回它的 stdout；5 秒沒好就放棄（回 null）
    public static string? RunChained(string command, string stdin, int timeoutMs = 5000)
    {
        var (exe, args) = Shell(command);
        try
        {
            var psi = new ProcessStartInfo(exe)
            {
                RedirectStandardInput = true, RedirectStandardOutput = true, RedirectStandardError = true, UseShellExecute = false, CreateNoWindow = true,
                StandardOutputEncoding = Encoding.UTF8, StandardInputEncoding = new UTF8Encoding(false),
            };
            foreach (var a in args) psi.ArgumentList.Add(a);
            using var p = Process.Start(psi)!;
            var outTask = p.StandardOutput.ReadToEndAsync();
            p.ErrorDataReceived += (_, _) => { };
            p.BeginErrorReadLine();
            p.StandardInput.Write(stdin);
            p.StandardInput.Close();
            if (!p.WaitForExit(timeoutMs)) { try { p.Kill(true); } catch { } return null; }
            return outTask.Result;
        }
        catch { return null; }
    }

    /// Claude Code 在 Windows 用 Git Bash 跑 statusLine／hook 指令；找不到 Git Bash 才退回 cmd.exe。macOS（測試）用 /bin/sh
    public static (string Exe, string[] Args) Shell(string command)
    {
        if (!OperatingSystem.IsWindows()) return ("/bin/sh", new[] { "-c", command });
        var bash = HookPaths.Env("CLAUDE_CODE_GIT_BASH_PATH");
        if (bash == null || !File.Exists(bash))
            bash = new[] { @"C:\Program Files\Git\bin\bash.exe", @"C:\Program Files (x86)\Git\bin\bash.exe" }.FirstOrDefault(File.Exists);
        return bash != null ? (bash, new[] { "-c", command }) : ("cmd.exe", new[] { "/d", "/s", "/c", command });
    }

    /// `showork statusline` 本體：寫檔、印狀態列。永遠不丟例外
    public static string Run(string? stdin, DateTime now)
    {
        JsonObject? d = null;
        try { d = Record(stdin, now); } catch { }
        if (ChainedCommand() is { } cmd && RunChained(cmd, stdin ?? "") is { } o) return o;
        return d == null ? "" : Line(d, now) + "\n";
    }
}
