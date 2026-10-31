using System.Text;
using System.Text.RegularExpressions;

namespace ShoWork.Hooks;

// 隊長連動（Mac 版 Sources/ShoWorkCore/CaptainLink.swift 的移植；規則、文字、檔案格式都照抄）：
//   ① 開工卡：使用者直接下指令（UserPromptSubmit）⇒ 提醒組員動手前先發 showork card --kind start；開工卡也進隊長收件匣。
//   ② 動作預告：PreToolUse(Bash) 比對高風險指令（board\guard\preview.tsv，可改）。擋＝擋下等放行；告＝只通知隊長。
//      git push 不在這裡（1 樓保全 PushGuard 照舊）。只看 Bash 工具。
// 正規表示式：Mac 是 NSRegularExpression（ICU），這裡是 .NET Regex。用到的語法（lookahead、\b、\s、反向參照、不分大小寫）兩邊意思相同；
// 已知的小差異：Swift 把 "\r\n" 當成一個字，所以 CRLF 的指令在 Mac 不會在 \r\n 切段，這裡會（Windows 比較合理）。
static class CaptainLink
{
    // MARK: ① 開工卡

    /// 這則 prompt 是不是使用者直接下的指令（要發開工卡）
    public static bool NeedsStart(string? prompt)
    {
        var p = prompt?.Trim();
        if (string.IsNullOrEmpty(p)) return false;
        // 其他 session 的訊息、看板轉送、背景工作通知、系統訊息：都是包在 <…> 標籤裡進來的
        foreach (var tag in new[] { "<cross-session-message", "<task-notification", "<system-reminder", "<local-command", "<command-name>", "<bash-" })
            if (p.StartsWith(tag, StringComparison.Ordinal)) return false;
        return true;
    }

    /// 距上一道使用者指令多久以上算新任務
    public static readonly TimeSpan NewTaskGap = TimeSpan.FromMinutes(10);
    static string PromptMark(string sid) => Path.Combine(HookPaths.Board, "prompts", sid);
    public static DateTime? LastPrompt(string sid) => File.Exists(PromptMark(sid)) ? File.GetLastWriteTimeUtc(PromptMark(sid)) : null;
    public static void TouchPrompt(string sid, DateTime now)
    {
        try
        {
            var f = PromptMark(sid);
            Directory.CreateDirectory(Path.GetDirectoryName(f)!);
            File.WriteAllBytes(f, Array.Empty<byte>());
            File.SetLastWriteTimeUtc(f, now);
        }
        catch { }
    }

    /// 10 分鐘內的連續指令：只有換了任務才發
    public static string SameTaskContext(string showork, string? doing) =>
        $"【開工卡】你手上的任務是「{doing ?? "（還沒報）"}」。這道指令如果是同一件事接著做，不用發開工卡；換成新任務才在動手前發："
        + $"\"{showork}\" card --kind start --doing \"<新任務>\" --summary \"<要做什麼>\" --how \"<打算怎麼做>\" --touch \"<會動到什麼>\" --outward \"<對外動作或「無」>\"";

    /// 注入給組員的提醒（UserPromptSubmit 的 additionalContext）
    public static string StartContext(string showork) => $"""
        【開工卡】這是使用者直接下的指令。動手（讀檔以外的任何改動、跑會改東西的指令）之前，先用 Bash 發一張開工卡給隊長，發完直接開始做、不用等回覆：
        "{showork}" card --kind start --doing "<這件事，10 個字內>" --summary "<要做什麼，一句話>" --how "<打算怎麼做>" --touch "<會動到哪些檔／repo／系統設定；沒有寫「無」>" --outward "<要不要 push、部署、對外傳訊息；沒有寫「無」>"
        只是聊天、回答問題、不動手的回合不用發。不要把使用者的原話整段貼進卡片。
        """;

    // MARK: ② 動作預告（兩級：擋＝等放行；告＝只通知）

    public sealed record Rule(string Name, bool Block, string Pattern);

    /// 暫存區（rm 到這些地方不擋、mv 到這些地方不通知）
    const string Temp = @"['""]?(?:/tmp/|/private/tmp/|/private/var/folders/|/var/folders/|\$\{?TMPDIR|\$TMP\b|[^\s;&|]*scratchpad)";
    const string ClaudeDirPat = @"(?:~|\$HOME|\$\{HOME\}|/Users/[^/\s]+)/\.claude/(?:scripts|data)\b";

    /// 預設清單（第一次用會寫成 preview.tsv，之後以檔案為準）。比對的對象是「一段指令」（見 SegmentPairs），所以 ^ 就是指令的第一個詞
    public static List<Rule> DefaultRules => Rules(LocalConfig.Current);
    public static List<Rule> Rules(LocalConfig local)
    {
        var rs = new List<Rule>
        {
            new("rm 刪除（暫存區以外）", true,
                // 重導向（2>/dev/null、>log）不是要刪的目標
                @"^rm\s+(?:-[a-zA-Z]+\s+)*(?:[^\s;&|]+\s+)*?(?!" + Temp + @")(?!-)(?![0-9&]*[<>])[^\s;&|]+"),
            // mv 可以復原，只通知不擋（rm 刪了救不回來，照擋）
            new("mv 到非暫存區", false,
                @"^mv\s+(?:[^\n]*?\s)?(?!" + Temp + @")(?![0-9&]*[<>])[^\s]+(?:\s+[0-9&]*[<>]>?\s*\S+)*\s*$"),
            new("firebase 部署", true, @"^(?:npx\s+)?firebase\s+deploy\b"),
            // xcodebuild archive 只是本機打包、不對外，只通知；真正會上傳的 -exportArchive／altool 等照擋
            new("App 封裝（xcodebuild archive）", false, @"^xcodebuild\b(?!.*\s-exportArchive\b).*\barchive\b"),
            new("App 上傳 App Store Connect", true,
                @"^xcodebuild\b.*\s-exportArchive\b|^(?:xcrun\s+)?(?:altool\b|notarytool\s+submit\b)|^\S*(?:iTMSTransporter|Transporter)\b|^(?:bundle\s+exec\s+)?fastlane\s+(?:\S+\s+)?(?:deliver|pilot|upload_to_app_store|upload_to_testflight)\b"),
            new("LINE 對外傳訊（line_send.py）", true, @"^(?:python3?\s+(?:-\S+\s+)*)?\S*line_send\.py\b"),
            // 這裡粗篩，Okle42 私有 repo 免擋的細判在 GHGuard
            new("GitHub 公開發言（gh）", true,
                @"^(?:\S*/)?gh\s+(?:.*\s)?(?:issue\s+(?:comment|create)|pr\s+(?:create|comment|review)|release\s+create)\b|^(?:\S*/)?gh\s+(?:.*\s)?api\b.*\s(?:-X\s*|--method[\s=]+)(?:POST|PATCH|PUT|DELETE)\b|^(?:\S*/)?gh\s+(?:.*\s)?api\b.*\s(?:-f|-F|--field|--raw-field|--input)(?:\s|=)"),
            new("改系統設定（defaults write）", false, @"^defaults\s+(?:-currentHost\s+)?write\b"),
            new("寫入 ~/.claude/scripts 或 data", false,
                @"^(?:cp|mv|tee|install|ln|rsync)\b.*\s" + ClaudeDirPat + @"\S*\s*$|>>?\s*" + ClaudeDirPat + @"|^sed\s+-i\S*\s.*" + ClaudeDirPat),
        };
        // 遠端 Windows 主機別名在本機設定 local.json 的 winHosts
        foreach (var h in local.WinHosts ?? new())
            rs.Add(new($"遠端 Windows 寫入（ssh {h}）", false,
                @"^ssh\s+" + Regex.Escape(h) + @"\b.*\b(?:Set-|Remove-|New-Item|Rename-|Move-Item|Copy-Item|Stop-|Restart-|Install-|Uninstall-|reg(?:\.exe)?\s+(?:add|delete|import))"));
        return rs;
    }

    /// preview.tsv 格式版本（舊格式的檔案會被換成新的預設）
    const string RulesVersion = "格式 v6";

    public static string RulesFile => HookPaths.Env("SHOWORK_PREVIEW_RULES") ?? Path.Combine(HookPaths.Board, "guard", "preview.tsv");

    /// preview.tsv：一行「類別<TAB>擋|告<TAB>正規表示式」，# 開頭是註解；檔案不在就寫預設的
    public static List<Rule> LoadRules()
    {
        var f = RulesFile;
        var text = HookJson.ReadText(f);
        if (text == null || !text.Contains(RulesVersion))
        {
            var owner = LocalConfig.Current.OwnerName;
            var head = $"# 動作預告（T1024033803 ②，{RulesVersion}）：一行「類別<TAB>擋|告<TAB>正規表示式」，不分大小寫。\n"
                + "# 比對的是「一段指令」：以 ; && || | 換行切開、去掉 sudo／env／VAR=值 前綴，引號內容換成 Q（ssh 那段保留引號內容），heredoc 內文拿掉 ⇒ ^ 就是指令的第一個詞。\n"
                + $"# 擋＝先擋下、等隊長轉述{owner}的決定（showork release）或{owner}在那個 session 打「放行」；告＝只通知隊長不擋。# 開頭是註解，刪掉這個檔會重寫預設\n";
            var rules = DefaultRules;
            var body = string.Join("\n", rules.Select(r => $"{r.Name}\t{(r.Block ? "擋" : "告")}\t{r.Pattern}")) + "\n";
            HookJson.WriteAtomic(f, head + body);
            return rules;
        }
        return ParseRules(text);
    }

    public static List<Rule> ParseRules(string text)
    {
        var out_ = new List<Rule>();
        foreach (var line in text.Split('\n', StringSplitOptions.RemoveEmptyEntries))
        {
            if (line.StartsWith('#')) continue;
            var f = line.Split('\t', 3).Select(SwiftText.TrimSpaces).ToArray();
            if (f.Length != 3 || f[0].Length == 0 || f[2].Length == 0) continue;
            out_.Add(new Rule(f[0], f[1] == "擋", f[2].TrimEnd('\r')));
        }
        return out_;
    }

    static readonly Dictionary<string, Regex?> cache = new();
    /// 編不起來的規則當沒有（同 Swift 的 try? NSRegularExpression）
    public static Regex? Rx(string pattern)
    {
        lock (cache)
        {
            if (cache.TryGetValue(pattern, out var r)) return r;
            try { r = new Regex(pattern, RegexOptions.IgnoreCase | RegexOptions.CultureInvariant); } catch { r = null; }
            return cache[pattern] = r;
        }
    }

    static readonly Regex TempVar = new(@"(?:^|[;&|\n(]|\s)(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)=[""']?(?:\$\(\s*mktemp\b|/tmp/|/private/tmp/|/private/var/folders/|/var/folders/|\$\{?TMPDIR\b|\$\{?TMP\b|[^\s;&|""']*scratchpad)", RegexOptions.CultureInvariant);
    static readonly Regex Heredoc = new(@"<<-?\s*['""]?(\w+)['""]?([^\n]*)\n.*?\n\s*\1\b", RegexOptions.Singleline | RegexOptions.CultureInvariant);
    static readonly Regex Prefix = new(@"^(?:\s+|[{!]\s*|(?:sudo|env|time|nohup|exec|command|then|do|else|if|while|until)\s+(?:-\S+\s+)*|[A-Za-z_][A-Za-z0-9_]*=(?:'[^']*'|""(?:[^""\\]|\\.)*""|\S*)\s*)+", RegexOptions.CultureInvariant);
    static readonly Regex Quoted = new(@"(['""])([^'""]*)\1", RegexOptions.CultureInvariant);

    /// 把整條 Bash 指令切成會被執行的「一段段指令」：關鍵字只算出現在指令層級的，引號、heredoc、python -c 參數內的不算
    ///   1. 拿掉 heredoc 內文  2. 依引號外的 ; && || | & 換行切段  3. 去掉 sudo／env／VAR=值／time／nohup／( { ! 這類前綴
    ///   4. 引號內容換成 Q（ssh 開頭的那段保留：遠端要跑的指令就在引號裡）
    public static List<string> Segments(string cmd) => SegmentPairs(cmd).Select(p => p.Norm).ToList();

    /// (原文, 比對用)：原文給預告摘要
    public static List<(string Raw, string Norm)> SegmentPairs(string cmd)
    {
        var t = cmd;
        // 同一條指令前面把變數設成暫存路徑（T=$(mktemp -d)、S=/private/tmp/…）⇒ 後面的 $T、${T} 當成 /tmp/ 底下
        foreach (var n in TempVar.Matches(t).Select(m => m.Groups[1].Value).Distinct().ToList())
            t = Regex.Replace(t, @"\$\{?" + n + @"\b\}?", "/tmp/" + n, RegexOptions.CultureInvariant);
        t = Heredoc.Replace(t, "$2");
        // 引號外的分隔符切段（保留原文，第 4 步才換引號內容）
        var raw = new List<string>();
        var cur = new StringBuilder();
        char? q = null; bool esc = false;
        for (int i = 0; i < t.Length; i++)
        {
            var c = t[i];
            if (esc) { cur.Append(c); esc = false; continue; }
            if (c == '\\' && q != '\'') { esc = true; cur.Append(c); continue; }
            if (q is { } qq) { if (c == qq) q = null; cur.Append(c); continue; }
            if (c is '\'' or '"') { q = c; cur.Append(c); continue; }
            if (c is ';' or '|' or '&' or '\n' or '(' or ')' or '`')
            {
                raw.Add(cur.ToString()); cur.Clear();
                if (i + 1 < t.Length && (c is '|' or '&') && t[i + 1] == c) i++;
                continue;
            }
            if (c == '$' && i + 1 < t.Length && t[i + 1] == '(') { raw.Add(cur.ToString()); cur.Clear(); i++; continue; }   // $( … ) 裡也是指令
            cur.Append(c);
        }
        raw.Add(cur.ToString());
        var out_ = new List<(string, string)>();
        foreach (var seg in raw)
        {
            var s = SwiftText.TrimSpaces(Prefix.Replace(seg, ""));
            if (s.Length == 0 || IsShowork(s)) continue;        // showork 自己的指令（card／release…）整段不看
            var r = s;
            if (!s.StartsWith("ssh ", StringComparison.Ordinal)) s = BlankQuotes(s);
            out_.Add((r, s));
        }
        return out_;
    }

    /// 這段指令是不是 showork 本身（"…/ShoWork42/bin/showork" card …）。Windows 另外認 showork.exe 與反斜線路徑
    public static bool IsShowork(string s)
    {
        string first;
        if (s.Length > 0 && s[0] is '"' or '\'') first = new string(s.Skip(1).TakeWhile(ch => ch != s[0]).ToArray());
        else first = new string(s.TakeWhile(ch => !char.IsWhiteSpace(ch)).ToArray());
        var f = first.EndsWith(".exe", StringComparison.OrdinalIgnoreCase) ? first[..^4] : first;
        return f == "showork" || f.EndsWith("/showork", StringComparison.Ordinal) || f.EndsWith("\\showork", StringComparison.Ordinal);
    }

    /// 引號內容換成 Q，但開頭的暫存路徑字首留著（"/tmp/… → "/tmp/Q"），讓 rm／mv 的暫存區判斷還看得到
    public static string BlankQuotes(string s) => Quoted.Replace(s, m =>
    {
        var body = m.Groups[2].Value; var qc = m.Groups[1].Value;
        var keep = new[] { "/tmp/", "/private/tmp/", "/private/var/folders/", "/var/folders/", "$TMPDIR", "${TMPDIR", "$TMP/" }.FirstOrDefault(p => body.StartsWith(p, StringComparison.Ordinal))
            ?? (body.Contains("scratchpad") ? "scratchpad/" : null);
        return qc + (keep ?? "") + "Q" + qc;
    });

    /// 命中的規則（依清單順序；任一段指令符合就算）
    public static List<Rule> Match(string cmd, List<Rule> rules) => Hits(cmd, rules).Select(h => h.Rule).ToList();

    /// 命中的規則＋命中的那一段原文（第一段符合的）
    public static List<(Rule Rule, string Segment)> Hits(string cmd, List<Rule> rules)
    {
        var segs = SegmentPairs(cmd);
        var out_ = new List<(Rule, string)>();
        foreach (var r in rules)
        {
            if (Rx(r.Pattern) is not { } re) continue;
            foreach (var sg in segs)
                if (re.IsMatch(sg.Norm)) { out_.Add((r, sg.Raw)); break; }
        }
        return out_;
    }

    /// 預告摘要：命中的那幾段（去重複）；整條指令比命中段長就標「（整條共 N 段，只列命中的）」
    public static string HitSummary(string cmd, List<(Rule Rule, string Segment)> hs)
    {
        var segs = new List<string>();
        foreach (var h in hs) if (!segs.Contains(h.Segment)) segs.Add(h.Segment);
        var n = SegmentPairs(cmd).Count;
        return string.Join(" ／ ", segs.Select(Summary)) + (n > segs.Count ? $"（整條共 {n} 段，只列命中的）" : "");
    }

    static readonly Regex LongString = new(@"[A-Za-z0-9_\-+=]{32,}", RegexOptions.CultureInvariant);
    /// 指令摘要：壓成一行、長字串（金鑰、token 長相）遮掉、LINE 訊息內容不帶、最多 160 字
    public static string Summary(string cmd)
    {
        var t = cmd;
        var k = t.IndexOf("line_send.py", StringComparison.Ordinal);
        if (k >= 0) t = t[..(k + "line_send.py".Length)] + " ‹訊息內容略›";
        t = t.Replace("\n", " ⏎ ");
        t = LongString.Replace(t, "‹長字串›");
        t = SwiftText.TrimSpaces(t);
        return SwiftText.Count(t) > 160 ? SwiftText.Prefix(t, 160) + "⋯" : t;
    }

    /// 擋下等放行用的指紋：只看命中「擋」規則的那幾段（規則名＋那段原文，去掉多的空白）。
    /// 前面多一行 showork card、重跑時沒有，指紋照樣對得上；真的換了要擋的動作才算新指令
    public static string BlockFingerprint(string cmd, List<Rule> rules)
    {
        var segs = SegmentPairs(cmd);
        var parts = new List<string>();
        foreach (var r in rules.Where(r => r.Block))
        {
            if (Rx(r.Pattern) is not { } re) continue;
            foreach (var sg in segs.Where(sg => re.IsMatch(sg.Norm)))
                parts.Add(r.Name + "\t" + string.Join(" ", SwiftText.Words(sg.Raw)));
        }
        return parts.Count == 0 ? Fingerprint(cmd) : Fingerprint(string.Join("\n", parts));
    }

    /// 指令指紋（FNV-1a 64，同 Mac）
    public static string Fingerprint(string cmd)
    {
        ulong h = 0xcbf29ce484222325;
        foreach (var b in Encoding.UTF8.GetBytes(cmd.Trim())) { h ^= b; h = unchecked(h * 0x100000001b3); }
        return h.ToString("x");
    }

    public static string Label(string name, string? project) => name + (string.IsNullOrEmpty(project) ? "" : $"（{project}）");

    /// 擋下時給 AI 的理由
    public static string DenyReason(InboxItem item)
    {
        var owner = LocalConfig.Current.OwnerName;
        return $"⛔️ 這個指令需要放行才能跑（{string.Join("、", item.Kinds)}，單號 {item.Id}）。已通知隊長，不要重試、不要換寫法繞過，也不要自己跑 showork release。\n"
            + $"要放行請隊長轉述{owner}的決定（隊長跑 showork release {item.Id}），或{owner}在這個 session 直接打「放行」。放行後再跑一次同一個指令（30 分鐘內有效、只能用一次）。\n"
            + "等的時候用 showork card --status blocked 回報卡在哪；能改用暫存區（scratchpad、/tmp）的就改用。";
    }

    /// 擋下：立即送隊長
    public static string BlockText(InboxItem item)
    {
        var owner = LocalConfig.Current.OwnerName;
        return $"【動作預告・擋下 {item.Id}】{Label(item.Name, item.Project)}：{string.Join("、", item.Kinds)}・{item.Text}\n"
            + $"（已擋下等放行。{owner}明說同意這個動作才 showork release {item.Id}；隊長不能自己決定放行對外動作）";
    }
}
