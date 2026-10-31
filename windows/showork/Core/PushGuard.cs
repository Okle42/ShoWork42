using System.Text;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;

namespace ShoWork.Hooks;

// 1 樓保全：push 守門（Mac 版 Sources/ShoWorkCore/PushGuard.swift 的移植，規則與文字照抄）。
// PreToolUse hook（`showork guard-push`）在 AI 跑 `git push` 之前檢查要推出去的東西；擋下就回 deny。每次檢查記在 board\guard\pushes.jsonl。
//   擋（block）：ghosts、old-history/* 分支、force push 或刪除 main／master、privateDataRepos 的 data/、finance*.json、像金鑰的字串
//   提醒（warn）：關鍵字（board\guard\keywords.txt，一行一個，不進任何 repo）；推到 strict-repos.txt 裡的 repo 時關鍵字也算擋
// Windows：git 是 PATH 上的 git.exe；cd 的 Git Bash 路徑（/c/Users/…）換成 C:/Users/…，git -C 才認得。

sealed record PushCall(string Dir, List<string> Args);

sealed class PushEvent
{
    public DateTime At;
    public string? Session;
    public string? Name;                 // 英文名
    public string Repo = "";             // owner/name（看不出來就資料夾名）
    public string Dir = "";
    public List<string> Refs = new();
    public int Commits;
    public string Verdict = "ok";        // ok／warn／block
    public List<string> Reasons = new();
    public bool Secret;                  // 擋下的原因裡有金鑰
    public string? Head;                 // 檢查時的 HEAD（保全面板「放行一次」認這個）

    public JsonObject ToJson()
    {
        var o = new JsonObject { ["at"] = HookJson.Iso(At) };
        o.Put("session", Session); o.Put("name", Name);
        o["repo"] = Repo; o["dir"] = Dir; o["refs"] = HookJson.Arr(Refs); o["commits"] = Commits; o["verdict"] = Verdict;
        o["reasons"] = HookJson.Arr(Reasons); o["secret"] = Secret;
        o.Put("head", Head);
        return o;
    }
}

static class PushGuard
{
    public delegate (int Code, string Out) Git(string dir, string[] args);

    public static string Dir => Path.Combine(HookPaths.Board, "guard");
    public static string LogPath => Path.Combine(Dir, "pushes.jsonl");

    // MARK: 從 Bash 指令找出 git push

    /// 簡單的 shell 斷詞：引號、跳脫；&& || ; | 換行 當成獨立的分隔符號
    public static List<string> Tokenize(string s)
    {
        var out_ = new List<string>();
        var cur = new StringBuilder(); bool has = false;
        char? q = null; bool esc = false;
        void Flush() { if (has) out_.Add(cur.ToString()); cur.Clear(); has = false; }
        for (int i = 0; i < s.Length; i++)
        {
            var c = s[i];
            if (esc) { cur.Append(c); esc = false; continue; }
            if (q is { } qq)
            {
                if (c == qq) q = null; else if (c == '\\' && qq == '"') esc = true; else cur.Append(c);
                continue;
            }
            switch (c)
            {
                case '\\': esc = true; has = true; break;
                case '\'' or '"': q = c; has = true; break;
                case ' ' or '\t': Flush(); break;
                case '\n' or ';': Flush(); out_.Add(";"); break;
                case '&' when cur.Length > 0 && cur[^1] == '>': cur.Append(c); break;     // 2>&1
                case '&' or '|':
                    Flush();
                    if (i + 1 < s.Length && s[i + 1] == c) { out_.Add(new string(c, 2)); i++; } else out_.Add(c.ToString());
                    break;
                default: cur.Append(c); has = true; break;
            }
        }
        Flush();
        return out_;
    }

    /// Windows 的 Git Bash 路徑 /c/Users/… → C:/Users/…（只在 Windows 換；Mac 的 /c/… 是真的資料夾）
    public static string NativePath(string p)
    {
        if (OperatingSystem.IsWindows() && p.Length >= 2 && p[0] == '/' && char.IsAsciiLetter(p[1]) && (p.Length == 2 || p[2] == '/'))
            return char.ToUpperInvariant(p[1]) + ":/" + (p.Length > 3 ? p[3..] : "");
        return p;
    }

    /// 路徑展開：~、Git Bash 路徑、相對路徑、. 與 ..（Mac：expandingTildeInPath＋standardizingPath）
    public static string Resolve(string p, string baseDir)
    {
        var e = p == "~" ? HookPaths.Home : p.StartsWith("~/", StringComparison.Ordinal) ? HookPaths.Home + p[1..] : p;
        e = NativePath(e);
        try
        {
            return Path.TrimEndingDirectorySeparator(Path.IsPathRooted(e) ? Path.GetFullPath(e) : Path.GetFullPath(Path.Combine(baseDir, e)));
        }
        catch { return Path.Combine(baseDir, e); }
    }

    /// 資料夾名（Mac：lastPathComponent）
    public static string LastComponent(string dir) => Path.GetFileName(dir.TrimEnd('/', '\\')) is { Length: > 0 } n ? n : dir;

    /// 指令裡每一個 git push（跟著 cd 與 -C 算出在哪個資料夾跑）
    public static List<PushCall> Calls(string command, string cwd)
    {
        var out_ = new List<PushCall>();
        if (!command.Contains("push")) return out_;
        var dir = cwd;
        var vars = new Dictionary<string, string>();
        foreach (System.Collections.DictionaryEntry kv in Environment.GetEnvironmentVariables()) vars[(string)kv.Key] = (string?)kv.Value ?? "";
        // $X、${X}：前面 X=… 設過的或環境變數；展不開的留著 $（check 會因為找不到 repo 而擋）
        string Expand(string s)
        {
            if (!s.Contains('$')) return s;
            var r = s;
            foreach (var (k, v) in vars.OrderByDescending(kv => kv.Key.Length))
                r = r.Replace("${" + k + "}", v).Replace("$" + k, v);
            return r;
        }
        void Handle(List<string> seg)
        {
            int t = 0;
            while (t < seg.Count && seg[t].Contains('=') && !seg[t].StartsWith('-') && !seg[t].StartsWith('/'))      // FOO=bar
            {
                var kv = seg[t].Split('=', 2);
                if (kv.Length == 2 && kv[0].All(ch => char.IsLetterOrDigit(ch) || ch == '_')) vars[kv[0]] = Expand(kv[1]);
                t++;
            }
            while (t < seg.Count && seg[t] is "command" or "env" or "time" or "nohup" or "exec" or "sudo") t++;
            if (t >= seg.Count) return;
            var g = seg[t];
            if (g == "cd") { if (seg.Count - t >= 2) dir = Resolve(Expand(seg[t + 1]), dir); return; }
            if (!(g == "git" || g.EndsWith("/git") || g.Equals("git.exe", StringComparison.OrdinalIgnoreCase) || g.EndsWith("/git.exe", StringComparison.OrdinalIgnoreCase))) return;
            t++;
            var d = dir;
            while (t < seg.Count && seg[t].StartsWith('-'))
            {
                var f = seg[t++];
                if (f == "-C" && t < seg.Count) d = Resolve(Expand(seg[t++]), d);
                else if (f == "-c" && t < seg.Count) t++;
            }
            if (t >= seg.Count || seg[t] != "push") return;
            // 去掉轉向（2>&1、> log、>>x）
            var args = new List<string>(); bool skip = false;
            foreach (var x in seg.Skip(t + 1))
            {
                if (skip) { skip = false; continue; }
                if (x is "<" or ">" or ">>" or "2>" or "&>") { skip = true; continue; }
                if (x.Length == 0) { args.Add(x); continue; }
                if (x[0] is '<' or '>' || (char.IsDigit(x[0]) && x.Length > 1 && x[1] is '>' or '<') || x.StartsWith("&>")) continue;
                args.Add(x);
            }
            out_.Add(new PushCall(d, args));
        }
        var cur = new List<string>();
        foreach (var tok in Tokenize(command))
        {
            if (tok is ";" or "&&" or "||" or "|" or "&") { Handle(cur); cur = new(); } else cur.Add(tok);
        }
        Handle(cur);
        return out_;
    }

    // MARK: 檢查

    sealed class Args
    {
        public string? Remote;
        public List<string> Refspecs = new();
        public bool Force, All, Delete;
    }

    static Args Parse(List<string> a)
    {
        var r = new Args(); var pos = new List<string>();
        var takesValue = new HashSet<string> { "-o", "--push-option", "--receive-pack", "--exec", "--repo" };
        for (int i = 0; i < a.Count; i++)
        {
            var x = a[i];
            if (x == "--") { pos.AddRange(a.Skip(i + 1)); break; }
            if (x.StartsWith('-'))
            {
                if (takesValue.Contains(x)) { i++; continue; }
                if (x == "--force" || x == "--force-if-includes" || x.StartsWith("--force-with-lease")) r.Force = true;
                else if (x is "--all" or "--mirror" or "--branches") { r.All = true; if (x == "--mirror") r.Force = true; }
                else if (x == "--delete") r.Delete = true;
                else if (!x.StartsWith("--") && x.Length > 1)               // -fu、-d
                {
                    if (x.Contains('f')) r.Force = true;
                    if (x.Contains('d')) r.Delete = true;
                }
                continue;
            }
            pos.Add(x);
        }
        r.Remote = pos.FirstOrDefault();
        r.Refspecs = pos.Skip(1).ToList();
        return r;
    }

    /// 遠端網址 → owner/name
    public static string RepoName(string url)
    {
        var s = url.Trim();
        if (s.EndsWith(".git")) s = s[..^4];
        var parts = s.Split(new[] { '/', ':' }, StringSplitOptions.RemoveEmptyEntries);
        return string.Join("/", parts.TakeLast(2));
    }

    static readonly (string Name, Regex Re)[] SecretPatterns = new (string, string)[]
    {
        ("私鑰", @"-----BEGIN [A-Z ]*PRIVATE KEY-----"),
        ("Anthropic 金鑰", @"sk-ant-[A-Za-z0-9_\-]{20,}"),
        ("OpenAI 金鑰", @"\bsk-(proj-)?[A-Za-z0-9]{32,}"),
        ("GitHub token", @"\b(gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{30,})"),
        ("AWS 金鑰", @"\bAKIA[0-9A-Z]{16}\b"),
        ("Google API 金鑰", @"\bAIza[0-9A-Za-z_\-]{35}"),
        ("Slack token", @"\bxox[abprs]-[A-Za-z0-9\-]{10,}"),
        ("Claude Code 收件鑰匙", @"""peerToken""\s*:\s*""[^""]{16,}"""),
    }.Select(p => (p.Item1, new Regex(p.Item2, RegexOptions.CultureInvariant))).ToArray();

    /// 新增的那幾行（git log -p 的 + 行）裡找金鑰與關鍵字；回傳各是「檔案：什麼」
    public static (List<string> Secrets, List<string> Words) Scan(string patch, List<string> keywords)
    {
        string file = "?"; var secrets = new List<string>(); var words = new List<string>();
        foreach (var raw0 in patch.Split('\n', StringSplitOptions.RemoveEmptyEntries))
        {
            var raw = raw0.TrimEnd('\r');
            if (raw.StartsWith("+++ ")) { file = raw.StartsWith("+++ b/") ? raw[6..] : raw[4..]; continue; }
            if (!raw.StartsWith('+')) continue;
            var line = raw[1..];
            foreach (var (n, re) in SecretPatterns)
                if (re.IsMatch(line)) { var s = $"{file}：{n}"; if (!secrets.Contains(s)) secrets.Add(s); }
            foreach (var w in keywords)
                if (line.Contains(w, StringComparison.OrdinalIgnoreCase)) { var s = $"{file}：「{w}」"; if (!words.Contains(s)) words.Add(s); }
        }
        return (secrets, words);
    }

    /// 一行一個，# 開頭是註解
    public static List<string> List(string path) =>
        (HookJson.ReadText(path) ?? "").Split(new[] { '\n', '\r' }, StringSplitOptions.RemoveEmptyEntries)
            .Select(SwiftText.TrimSpaces).Where(x => x.Length > 0 && !x.StartsWith('#')).ToList();

    static string More(List<string> xs) => string.Join("、", xs.Take(5)) + (xs.Count > 5 ? $" 等 {xs.Count} 處" : "");

    public static PushEvent Check(PushCall c, Git git, List<string> keywords, List<string> strict, DateTime now)
    {
        var a = Parse(c.Args);
        var block = new List<string>(); var warn = new List<string>(); bool secret = false;
        // 看不出在哪個 repo（路徑用了展不開的變數、或不是 git 資料夾）就擋：不能檢查的 push 不放行
        if (c.Dir.Contains('$') || c.Dir.Contains('`') || git(c.Dir, new[] { "rev-parse", "--git-dir" }).Code != 0)
            return new PushEvent { At = now, Repo = LastComponent(c.Dir), Dir = c.Dir, Verdict = "block",
                                   Reasons = new() { $"保全看不出要推的是哪個 repo（{c.Dir}）；請 cd 到實際路徑、不要用變數，再推一次" } };
        string G(params string[] x) => git(c.Dir, x).Out.Trim();
        var branch = G("symbolic-ref", "--quiet", "--short", "HEAD");
        var upstreamRemote = branch.Length == 0 ? "" : G("config", $"branch.{branch}.remote");
        var remote = a.Remote ?? (upstreamRemote.Length == 0 ? "origin" : upstreamRemote);
        bool isURL = remote.Contains('/') || remote.Contains(':');
        var url = isURL ? remote : G("remote", "get-url", remote);
        var repo = url.Length == 0 ? LastComponent(c.Dir) : RepoName(url);
        var shortName = repo.Split('/').LastOrDefault() ?? repo;

        // 要推哪些分支
        var specs = a.Refspecs;
        if (a.All) specs = G("for-each-ref", "--format=%(refname:short)", "refs/heads").Split('\n', StringSplitOptions.RemoveEmptyEntries).Select(x => x.TrimEnd('\r')).ToList();
        else if (specs.Count == 0 && branch.Length > 0) specs = new() { branch };
        var srcs = new List<string>(); var refs = new List<string>();
        foreach (var s in specs)
        {
            bool plus = s.StartsWith('+');
            var body = plus ? s[1..] : s;
            var parts = body.Split(':', 2);
            var src = parts[0]; var dst = parts.Length > 1 ? parts[1] : src;
            var dstName = dst.Replace("refs/heads/", "");
            refs.Add(dstName.Length == 0 ? src : dstName);
            if (src.Contains("old-history/") || dst.Contains("old-history/")) block.Add($"old-history/ 分支是改名前的舊歷史，絕不推（{s}）");
            bool main = dstName is "main" or "master";
            if (main && (a.Force || plus)) block.Add($"force push 到 {dstName} 會改寫遠端歷史");
            if (main && (a.Delete || (parts.Length > 1 && src.Length == 0))) block.Add($"要刪除遠端的 {dstName}");
            if (src.Length > 0 && !a.Delete && !src.StartsWith("refs/tags/")) srcs.Add(src);
        }
        if (shortName.Equals("ghosts", StringComparison.OrdinalIgnoreCase))
            block.Add("ghosts 的遠端因為資安重寫過歷史，本機的「領先」是舊歷史，推了會把清掉的東西推回去；要同步用 reset --hard");

        // 要推出去的 commit 與內容
        int commits = 0;
        if (srcs.Count > 0)
        {
            var not = isURL ? new[] { "--not", "--remotes" } : new[] { "--not", $"--remotes={remote}" };
            string[] With(params string[] head) => head.Concat(srcs).Concat(not).ToArray();
            commits = git(c.Dir, With("rev-list", "--max-count=500")).Out.Split('\n', StringSplitOptions.RemoveEmptyEntries).Count(x => x.Trim().Length > 0);
            if (commits > 0)
            {
                var paths = git(c.Dir, With("log", "--format=", "--name-only", "--diff-filter=AM", "--max-count=500")).Out
                    .Split('\n', StringSplitOptions.RemoveEmptyEntries).Select(x => x.TrimEnd('\r')).ToList();
                if (LocalConfig.Current.IsPrivateDataRepo(shortName) && paths.FirstOrDefault(p => p.StartsWith("data/")) is { } dp)
                    block.Add($"{shortName} 的 data/ 是私人內容（本機設定 privateDataRepos），不進 git：{dp}");
                if (paths.FirstOrDefault(p => Path.GetFileName(p).ToLowerInvariant().StartsWith("finance") && p.EndsWith(".json")) is { } fp)
                    block.Add($"財務資料檔不進 git：{fp}");
                var patch = git(c.Dir, With("log", "-p", "--format=", "--no-color", "-U0", "--no-ext-diff", "--max-count=500")).Out;
                var (sec, words) = Scan(patch, keywords);
                if (sec.Count > 0) { secret = true; block.Add("像金鑰的字串：" + More(sec)); }
                if (words.Count > 0)
                {
                    var w = "客戶／機密關鍵字：" + More(words);
                    if (strict.Any(x => x.Equals(repo, StringComparison.OrdinalIgnoreCase) || x.Equals(shortName, StringComparison.OrdinalIgnoreCase)))
                        block.Add(w + $"（{repo} 是公開或公司 repo）");
                    else warn.Add(w);
                }
            }
        }
        return new PushEvent
        {
            At = now, Repo = repo, Dir = c.Dir, Refs = refs, Commits = commits,
            Verdict = block.Count > 0 ? "block" : warn.Count > 0 ? "warn" : "ok",
            Reasons = block.Concat(warn).ToList(), Secret = secret, Head = G("rev-parse", "HEAD"),
        };
    }

    // MARK: hook 輸出、紀錄

    /// PreToolUse 的回應：擋下就 deny；只是提醒就附 additionalContext；沒事回 null（不輸出，照常走）
    public static string? HookOutput(List<PushEvent> evs)
    {
        var blocked = evs.Where(e => e.Verdict == "block").ToList();
        var warned = evs.Where(e => e.Verdict == "warn").ToList();
        var o = new JsonObject { ["hookEventName"] = "PreToolUse" };
        if (blocked.Count > 0)
        {
            o["permissionDecision"] = "deny";
            o["permissionDecisionReason"] = "🛡️ 這次 push 被 1 樓保全擋下（不是 git 或網路壞了，不要重試同一個指令）。\n"
                + $"repo：{string.Join("、", blocked.Select(e => e.Repo))}\n原因：\n"
                + string.Join("\n", blocked.SelectMany(e => e.Reasons).Select(r => "・" + r))
                + "\n該怎麼做：能處理的先處理（改寫那幾個 commit、移掉檔案或金鑰）再推；不要換個寫法繞過保全。"
                + $"如果你認為是誤擋，請找{LocalConfig.Current.OwnerName}核可：他在戰情中心 1 樓保全面板按「放行一次」（認這次的 HEAD，30 分鐘內有效）後你再推一次，"
                + "或他自己在終端機打 `! git push …`。用 showork card --status blocked 回報被擋的原因。";
        }
        else if (warned.Count > 0)
            o["additionalContext"] = $"🛡️ 1 樓保全提醒（{string.Join("、", warned.Select(e => e.Repo))}）：" + string.Join("；", warned.SelectMany(e => e.Reasons))
                + "。這個 repo 不是公開／公司 repo，所以沒擋；如果這些字不該出現，推完後跟使用者說一聲。";
        else return null;
        return HookJson.Text(new JsonObject { ["hookSpecificOutput"] = o });
    }

    // MARK: 放行一次（使用者在保全面板按；Windows 看板還沒有這顆按鈕，Mac 寫的 allow.json 格式照讀）

    public sealed record Allow(string Dir, string Head, DateTime Until);
    public static string AllowPath => Path.Combine(Dir, "allow.json");

    public static List<Allow> Allows(string? path = null) =>
        HookJson.Parse(HookJson.ReadText(path ?? AllowPath)) is JsonArray a
            ? a.Where(x => x.Str("dir") != null && x.Str("head") != null && x.Date("until") != null)
               .Select(x => new Allow(x.Str("dir")!, x.Str("head")!, x.Date("until")!.Value)).ToList()
            : new();

    public static void SaveAllows(List<Allow> xs, string? path = null) =>
        HookJson.WriteAtomic(path ?? AllowPath, HookJson.Text(new JsonArray(xs.Select(x =>
            (JsonNode?)new JsonObject { ["dir"] = x.Dir, ["head"] = x.Head, ["until"] = HookJson.Iso(x.Until) }).ToArray())));

    /// 被擋的這筆如果放行過（同資料夾、同 HEAD、沒過期）⇒ 改成放行，用掉那張放行單；回傳剩下的放行單
    public static List<Allow> Apply(PushEvent e, List<Allow> xs, DateTime now)
    {
        var live = xs.Where(x => x.Until > now).ToList();
        int i = e.Verdict == "block" && e.Head != null ? live.FindIndex(x => x.Dir == e.Dir && x.Head == e.Head) : -1;
        if (i < 0) return live;
        e.Verdict = "ok";
        e.Reasons = new() { LocalConfig.Current.OwnerName + "在保全面板放行一次：" + string.Join("；", e.Reasons) };
        live.RemoveAt(i);
        return live;
    }

    public static void Append(PushEvent e, string? path = null) => HookJson.AppendLine(path ?? LogPath, HookJson.Text(e.ToJson()));
}
