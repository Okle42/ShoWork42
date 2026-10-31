namespace ShoWork.Hooks;

// 動作預告「GitHub 公開發言（gh）」的細判（Mac 版 Sources/ShoWorkCore/GHGuard.swift 的移植）。
// preview.tsv 的正規表示式先粗篩，命中後這裡逐段看真正的目標 repo：全部都是 Okle42 自己的私有 repo ⇒ 不擋；
// 其他帳號、公開、判不出來（gh 失敗、路徑用變數）⇒ 照擋等放行。gh api 只算 repos/… 路徑的寫入。
static class GHGuard
{
    public const string RuleName = "GitHub 公開發言（gh）";
    /// 自己的帳號：私有 repo 不擋
    public static readonly HashSet<string> OwnOwners = new() { "okle42" };

    /// 一段 gh 指令的目標：None＝不是對外發言；Repos＝owner/name；Unknown＝判不出來（原因）
    public sealed record Target(string Kind, List<string> Repos, string Why)
    {
        public static readonly Target None = new("none", new(), "");
        public static Target Of(params string[] rs) => new("repos", rs.ToList(), "");
        public static Target Unknown(string why) => new("unknown", new(), why);
    }

    /// 查 repo 的擁有者與是否私有（gh repo view）；查不到回 null
    public delegate (string Owner, bool IsPrivate)? View(string repo);

    static bool IsGh(string? g) => g != null && (g == "gh" || g.EndsWith("/gh"));

    /// 這段（已拆好的參數，第一個是 gh）是要對哪個 repo 發言
    public static Target TargetOf(List<string> tok, string dir, PushGuard.Git git)
    {
        if (tok.Count < 2 || !IsGh(tok[0])) return Target.None;
        var a = tok.Skip(1).ToList();
        // -R／--repo 可以出現在任何位置
        string? repo = null;
        for (int i = 0; i < a.Count;)
        {
            var x = a[i];
            if ((x == "-R" || x == "--repo") && i + 1 < a.Count) { repo = a[i + 1]; a.RemoveRange(i, 2); continue; }
            if (x.StartsWith("--repo=")) { repo = x[7..]; a.RemoveAt(i); continue; }
            if (x.StartsWith("-R") && x.Length > 2) { repo = x[2..]; a.RemoveAt(i); continue; }
            i++;
        }
        var sub = a.FirstOrDefault() ?? ""; var verb = a.Count > 1 ? a[1] : "";
        var outward = new HashSet<string> { "issue comment", "issue create", "pr create", "pr comment", "pr review", "release create" };
        if (sub == "api") return ApiTarget(a.Skip(1).ToList(), dir, git);
        if (!outward.Contains(sub + " " + verb)) return Target.None;
        if (repo != null) return Target.Of(PushGuard.RepoName(repo));
        // 參數是網址（gh issue comment https://github.com/o/n/issues/5）
        foreach (var x in a.Skip(2))
            if (UrlRepo(x) is { } r) return Target.Of(r);
        return DirRepos(dir, git);
    }

    static Target ApiTarget(List<string> a, string dir, PushGuard.Git git)
    {
        string? method = null, path = null; bool fields = false;
        var skip2 = new HashSet<string> { "-H", "--header", "-q", "--jq", "-t", "--template", "--hostname", "--cache", "-p", "--preview" };
        for (int i = 0; i < a.Count;)
        {
            var x = a[i];
            if (x == "-X" || x == "--method") { method = i + 1 < a.Count ? a[i + 1].ToUpperInvariant() : null; i += 2; continue; }
            if (x.StartsWith("--method=")) method = x[9..].ToUpperInvariant();
            else if (x.StartsWith("-X") && x.Length > 2) method = x[2..].ToUpperInvariant();
            else if (x is "-f" or "-F" or "--field" or "--raw-field" or "--input") { fields = true; i += 2; continue; }
            else if (x.StartsWith("--field=") || x.StartsWith("--raw-field=") || x.StartsWith("--input=")) fields = true;
            else if (skip2.Contains(x)) { i += 2; continue; }
            else if (!x.StartsWith('-') && path == null) path = x;
            i++;
        }
        var m = method ?? (fields ? "POST" : "GET");
        if (m is not ("POST" or "PATCH" or "PUT" or "DELETE") || path == null) return Target.None;
        var parts = path.Split('?')[0].Split('/', StringSplitOptions.RemoveEmptyEntries);
        if (parts.FirstOrDefault() != "repos") return Target.None;
        if (parts.Length < 3) return Target.Unknown($"gh api 路徑看不出 repo（{path}）");
        if (parts[1] == "{owner}" || parts[2] == "{repo}") return DirRepos(dir, git);
        if (parts[1].Contains('$') || parts[2].Contains('$')) return Target.Unknown($"gh api 路徑用了變數（{path}）");
        return Target.Of(parts[1] + "/" + parts[2]);
    }

    static string? UrlRepo(string s)
    {
        var k = s.IndexOf("github.com/", StringComparison.Ordinal);
        if (k < 0) return null;
        var p = s[(k + 11)..].Split('/', StringSplitOptions.RemoveEmptyEntries);
        return p.Length >= 2 ? p[0] + "/" + p[1] : null;
    }

    /// 沒指定 repo：gh 用資料夾的 remote（fork 的 PR 會開到上游）⇒ 每個 remote 都算
    static Target DirRepos(string dir, PushGuard.Git git)
    {
        if (dir.Contains('$') || dir.Contains('`')) return Target.Unknown($"資料夾用了變數（{dir}）");
        var r = git(dir, new[] { "remote", "-v" });
        var out_ = new List<string>();
        foreach (var line in r.Out.Split('\n', StringSplitOptions.RemoveEmptyEntries))
        {
            var cols = line.Split(new[] { ' ', '\t' }, StringSplitOptions.RemoveEmptyEntries);
            if (cols.Length < 2) continue;
            var n = PushGuard.RepoName(cols[1]);
            if (!out_.Contains(n)) out_.Add(n);
        }
        return r.Code == 0 && out_.Count > 0 ? Target.Of(out_.ToArray()) : Target.Unknown($"{dir} 不是有 remote 的 git 資料夾");
    }

    /// 命中「GitHub 公開發言」的指令能不能免擋：每一段 gh 發言的目標都是 Okle42 的私有 repo 才免。回傳 null＝免擋；否則是擋的原因
    public static string? BlockReason(string cmd, string cwd, CaptainLink.Rule rule, PushGuard.Git git, View view)
    {
        if (CaptainLink.Rx(rule.Pattern) is not { } re) return "規則讀不懂";
        var dir = cwd; var reasons = new List<string>(); var checkedRepos = new Dictionary<string, bool>();
        foreach (var s in CaptainLink.SegmentPairs(cmd))
        {
            var tok = PushGuard.Tokenize(s.Raw);
            if (tok.FirstOrDefault() == "cd")
            {
                dir = tok.Count >= 2 ? PushGuard.Resolve(tok[1], dir) : HookPaths.Home;
                continue;
            }
            if (!re.IsMatch(s.Norm)) continue;
            var t = TargetOf(tok, dir, git);
            switch (t.Kind)
            {
                case "none":
                    // 正規表示式抓到、這裡卻看不出是 gh 發言（包在別的指令裡）⇒ 不冒險
                    if (!IsGh(tok.FirstOrDefault())) reasons.Add("看不出 gh 指令的目標");
                    break;
                case "unknown": reasons.Add(t.Why); break;
                default:
                    foreach (var r in t.Repos)
                    {
                        bool ok;
                        if (checkedRepos.TryGetValue(r, out var c)) ok = c;
                        else if (!OwnOwners.Contains(r.Split('/')[0].ToLowerInvariant())) ok = false;
                        else if (view(r) is { } v) ok = OwnOwners.Contains(v.Owner.ToLowerInvariant()) && v.IsPrivate;
                        else { ok = false; reasons.Add($"查不到 {r} 是不是私有"); }
                        checkedRepos[r] = ok;
                        if (!ok && !reasons.Any(x => x.Contains(r))) reasons.Add($"{r} 不是 Okle42 的私有 repo");
                    }
                    break;
            }
        }
        return reasons.Count == 0 ? null : string.Join("；", reasons);
    }
}
