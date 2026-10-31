using System.Diagnostics;
using System.Text;
using System.Text.Json.Nodes;
using ShoWork.Hooks;

namespace ShoWork;

// showork.exe 的 hook 端子指令（W5，Mac 版 Sources/showork/main.swift＋CaptainCLI.swift 的移植）：
//   showork brief          SessionStart hook：印出給 AI 的戰情中心說明
//   showork card …         AI 每輪自報（完成度／信心度／要你決定的事）；--kind start 開工卡也進隊長收件匣
//   showork title          UserPromptSubmit hook：開工卡提醒；使用者打「放行」／「放行 <單號>」放行被擋的指令
//   showork guard-push     PreToolUse(Bash) hook：動作預告（擋／告）＋1 樓保全的 push 守門
//   showork preview-check "<指令>"…   動作預告的分類試算（不擋、不送、不寫檔）
//   showork names          活著的 session：英文名、session 名、正在做的任務
//   showork captain [ack <單號｜all>]   把目前這個 session 設成隊長，印出隊長守則與收件匣未處理的單
//   showork release <單號>  隊長放行被擋下的動作
// hook（brief／title／guard-push）的合約：永遠 exit 0、出錯安靜略過；stdin 是 Claude Code 給的 hook JSON。
// 輸出一律 UTF-8 位元組直接寫 stdout（Windows 主控台的字碼頁會把中文弄壞）。
// 邏輯都在可測的函式裡（輸入字串、回傳輸出字串），Run 只負責讀 stdin／環境變數、寫 stdout。
static class HookCli
{
    static readonly string[] HookCommands = { "brief", "title", "guard-push" };
    public static bool Handles(string cmd) => cmd is "brief" or "card" or "title" or "guard-push" or "preview-check" or "names" or "captain" or "release";

    /// 審核員自己（SHOWORK_REVIEWER）與 `claude -p` 這類無頭呼叫（CLAUDE_CODE_ENTRYPOINT＝sdk-*）不上看板、不用自報
    static bool IsReviewer => Environment.GetEnvironmentVariable("SHOWORK_REVIEWER") != null
        || (Environment.GetEnvironmentVariable("CLAUDE_CODE_ENTRYPOINT") ?? "").StartsWith("sdk", StringComparison.Ordinal);
    static string? EnvSid => HookPaths.Env("CLAUDE_CODE_SESSION_ID");

    /// 提示詞裡給 AI 跑的 showork 路徑：Claude Code 在 Windows 用 Git Bash 跑指令 ⇒ 正斜線（安裝器寫進 hooks 的也是這個樣子）
    public static string ShoworkPath => (Environment.ProcessPath ?? "showork").Replace('\\', '/');

    public static int Run(string[] args)
    {
        bool hook = HookCommands.Contains(args[0]);
        try
        {
            var now = DateTime.UtcNow;
            switch (args[0])
            {
                case "brief":
                    if (!IsReviewer) Out(Brief(Stdin(1 << 20), EnvSid, ShoworkPath));
                    return 0;
                case "title":
                    if (!IsReviewer) Out(Title(Stdin(1 << 20), EnvSid, now, ShoworkPath));
                    return 0;
                case "guard-push":
                    if (Stdin(64 << 20) is { } j && GuardPush(j, now, RunGit, GhView) is { } o) Out(o + "\n");
                    return 0;
                case "card":
                    if (IsReviewer) return 0;
                    return Report(Card(args.Skip(1).ToList(), EnvSid, now));
                case "preview-check":
                    Out(PreviewCheck(args.Skip(1), Directory.GetCurrentDirectory(), RunGit, GhView));
                    return 0;
                case "names":
                    Out(Names());
                    return 0;
                case "captain":
                    return Report(Captain(args.Skip(1).ToList(), EnvSid, now, ShoworkPath));
                case "release":
                    return Report(Release(args.Skip(1).ToList(), EnvSid, now));
            }
        }
        catch (Exception e)
        {
            if (!hook) { Err($"showork {args[0]}：{e.Message}\n"); return 1; }
        }
        return 0;                                  // hook 絕不讓 Claude 失敗
    }

    // MARK: 輸入輸出

    static string? Stdin(int max)
    {
        if (!Console.IsInputRedirected) return null;
        try
        {
            using var s = Console.OpenStandardInput();
            using var ms = new MemoryStream();
            var buf = new byte[64 << 10];
            int n;
            while (ms.Length < max && (n = s.Read(buf, 0, buf.Length)) > 0) ms.Write(buf, 0, n);
            return Encoding.UTF8.GetString(ms.ToArray());
        }
        catch { return null; }
    }

    static void Out(string s) { if (s.Length == 0) return; using var o = Console.OpenStandardOutput(); o.Write(Encoding.UTF8.GetBytes(s)); }
    static void Err(string s) { if (s.Length == 0) return; using var o = Console.OpenStandardError(); o.Write(Encoding.UTF8.GetBytes(s)); }
    static int Report((int Code, string Out, string Err) r) { Out(r.Out); Err(r.Err); return r.Code; }

    static JsonObject? HookInput(string? stdin) => HookJson.Parse(stdin) as JsonObject;

    // MARK: brief

    /// SessionStart：Mac 會先看自動接手（Handover.claim），Windows 沒有自動交接，只印說明
    public static string Brief(string? stdin, string? envSid, string showork)
    {
        var sid = HookInput(stdin).Str("session_id") is { Length: > 0 } s ? s : envSid;
        return Hooks.Brief.Text(showork, sid == null ? null : NicknameStore.Ensure(sid).Name) + "\n";
    }

    // MARK: card

    public static (int Code, string Out, string Err) Card(List<string> args, string? sid, DateTime now)
    {
        if (sid == null) return (1, "", "showork card：找不到 CLAUDE_CODE_SESSION_ID（要在 Claude Code 裡跑）\n");
        var (r, e) = CardReport.Parse(args, now);
        if (r == null) return (1, "", $"showork card：{e}\n");
        var path = CardReport.CardPath(sid);
        if (!HookJson.WriteAtomic(path, HookJson.Text(r.ToJson()))) return (1, "", $"showork card：寫不進 {Path.GetDirectoryName(path)}\n");
        var err = "";
        if (r.Task is { } id && !CaptainStore.ApplyTask(id, r)) err += $"showork card：找不到派工單 {id}（自報已存）\n";
        if (r.IsStart)       // 開工卡也進隊長收件匣（看板轉送成功才標已送；新隊長 showork captain 會看到沒送到的）
            CaptainInbox.Save(new InboxItem
            {
                Id = CaptainInbox.NewID("start"), Kind = "start", At = r.At, Sid = sid, Name = NicknameStore.Ensure(sid, now).Name,
                Project = CaptainStore.Project(sid), Text = string.Join("：", new[] { r.Doing, r.Summary }.Where(x => x != null)),
            });
        var n = NicknameStore.Update(sid, r.Doing, now);
        // Mac 的收尾卡會登記交接、等看板自動 /clear；Windows 沒有自動交接，卡片照存
        if (r.IsWrapup) return (0, $"ok（{n.Name}：收尾卡已存；Windows 版還沒有自動 /clear，請使用者手動 /clear）\n", err);
        return (0, r.Doing == null ? $"ok（{n.Name}：沒帶 --doing，卡片標題的任務沒更新）\n" : $"ok（{n.Name}-{n.Doing}）\n", err);
    }

    // MARK: title

    /// UserPromptSubmit：開工卡提醒（使用者直接下的指令；隊長自己不用；local.json 的 noKickoffRepos 不發）。
    ///   距上一道使用者指令超過 10 分鐘＝完整提醒；10 分鐘內＝只在換了任務時才發。
    ///   使用者打「放行」／「放行 <單號>」＝放行這個 session 被擋下的指令（寫 board\permits\releases.jsonl）。
    /// Mac 的 Ghostty 標題（terminalSequence、做完時補寫 OSC 0）Windows 不做，只輸出 hookSpecificOutput
    public static string Title(string? stdin, string? envSid, DateTime now, string showork)
    {
        var o = HookInput(stdin);
        var sid = envSid ?? (o.Str("session_id") is { Length: > 0 } s ? s : null);
        var ev = o.Str("hook_event_name"); var prompt = o.Str("prompt"); var cwd = o.Str("cwd");
        string? nag = null;
        if (ev == "UserPromptSubmit" && sid != null && CaptainLink.NeedsStart(prompt))
        {
            var p = prompt!.Trim();
            if (p.StartsWith("放行", StringComparison.Ordinal))
            {
                var id = SwiftText.TrimSpaces(p[2..]).Split(' ', StringSplitOptions.RemoveEmptyEntries).FirstOrDefault();
                var who = NicknameStore.Get(sid)?.Name ?? "使用者";
                if (CaptainInbox.Release(id, sid, sid, $"使用者（在 {who} 的終端機）", "使用者輸入", now) is { } i)
                {
                    if (CaptainStore.Captain() is { } cap && cap != sid && Peer.Find(cap) is { } to)
                        Peer.Send(to, $"【已放行 {i.Id}】使用者在 {who} 的終端機放行：{i.Text}", "AI工作戰情中心（動作預告）");
                    nag = $"使用者剛放行了單號 {i.Id}（{i.Text}）。現在可以再跑一次剛才被擋下的同一個指令（30 分鐘內有效、只能用一次）。";
                }
            }
            else if (CaptainStore.Captain() != sid && !LocalConfig.Current.SkipsKickoff(cwd ?? ""))
            {
                var last = CaptainLink.LastPrompt(sid);
                CaptainLink.TouchPrompt(sid, now);
                nag = last is { } l && now - l < CaptainLink.NewTaskGap
                    ? CaptainLink.SameTaskContext(showork, NicknameStore.Get(sid)?.Doing)
                    : CaptainLink.StartContext(showork);
            }
        }
        if (sid == null) return "";
        var n = NicknameStore.Get(sid);
        if (n != null) NicknameStore.Touch(sid, now);
        var outp = Nicknames.HookOutput(n, ev, nag);
        return outp.Length == 0 ? "" : outp + "\n";
    }

    // MARK: guard-push

    /// PreToolUse(Bash)：動作預告（擋／告，規則在 CaptainLink）＋1 樓保全（PushGuard）。回傳要印的 hook JSON；null＝照常放行
    public static string? GuardPush(string stdin, DateTime now, PushGuard.Git git, GHGuard.View view)
    {
        var o = HookInput(stdin);
        if (o?["tool_input"].Str("command") is not { } cmd) return null;
        var sid = o.Str("session_id");
        var cwd = o.Str("cwd") ?? Directory.GetCurrentDirectory();
        var captain = CaptainStore.Captain();
        if (!IsReviewer && sid != null && captain != sid)     // 隊長自己不擋不預告（隊長只審不做）
        {
            var hs = CaptainLink.Hits(cmd, CaptainLink.LoadRules());
            var ghWhy = GhExempt(hs, cmd, cwd, git, view);
            var hits = hs.Select(h => h.Rule).ToList();
            if (hits.Count > 0)
            {
                var fp = CaptainLink.BlockFingerprint(cmd, hits);
                var project = CaptainStore.Project(sid);
                var name = NicknameStore.Get(sid)?.Name ?? sid[..Math.Min(8, sid.Length)];
                var blocks = hits.Where(r => r.Block).ToList();
                var notices = hits.Where(r => !r.Block).ToList();
                InboxItem NewBlock(string text) => new()
                {
                    Id = CaptainInbox.NewID("block"), Kind = "block", At = now, Sid = sid, Name = name, Project = project,
                    Kinds = hits.Select(r => r.Name).ToList(), Text = text, Fingerprint = fp,
                };
                // 放行單只查一次：consume 會把單記成已用，兩個分支各查一次的話，第一次用掉、第二次查不到又開新單
                bool released = blocks.Count > 0 && CaptainInbox.Consume(sid, fp, now);
                Preapproval? pre = blocks.Count > 0 && !released ? CaptainInbox.UsePreapproval(sid, blocks.Select(r => r.Name).ToList(), now) : null;
                if (pre != null)
                {
                    // 戰情中心回答已點名這個動作＝事先放行：記成已放行＋已用、通知隊長，照常往下跑
                    var item = CaptainInbox.ReleaseByAnswer(CaptainInbox.Waiting(sid, fp) ?? NewBlock(CaptainLink.HitSummary(cmd, hs)), pre, now);
                    if (captain != null && Peer.Find(captain) is { } to
                        && Peer.Send(to, $"【已放行 {item.Id}】{CaptainLink.Label(name, project)}：使用者在戰情中心回答「{pre.Answer}」已點名這個動作・{item.Text}", "AI工作戰情中心（動作預告）").Id != null)
                    { item.Delivered = true; CaptainInbox.Save(item); }
                }
                else if (blocks.Count > 0 && !released)
                {
                    // 擋下等放行：同一個指令重試不再開新單；第一次立即送隊長（不在線就留在收件匣）
                    var item = CaptainInbox.Waiting(sid, fp) ?? NewBlock(CaptainLink.HitSummary(cmd, hs) + (ghWhy != null ? $"（{ghWhy}）" : ""));
                    if (!item.Delivered && captain != null && Peer.Find(captain) is { } to
                        && Peer.Send(to, CaptainLink.BlockText(item), "AI工作戰情中心（動作預告）").Id != null) item.Delivered = true;
                    CaptainInbox.Save(item);
                    return HookJson.Text(new JsonObject
                    {
                        ["hookSpecificOutput"] = new JsonObject
                        {
                            ["hookEventName"] = "PreToolUse", ["permissionDecision"] = "deny", ["permissionDecisionReason"] = CaptainLink.DenyReason(item),
                        },
                    });
                }
                // 不擋的：先進收件匣，Mac 的看板把同一 session 一小段時間內的合成一則送（Windows 看板還不送，留在收件匣給 showork captain）
                if (notices.Count > 0)
                    CaptainInbox.Save(new InboxItem
                    {
                        Id = CaptainInbox.NewID("notice"), Kind = "notice", At = now, Sid = sid, Name = name, Project = project,
                        Kinds = notices.Select(r => r.Name).ToList(), Text = CaptainLink.HitSummary(cmd, hs.Where(h => !h.Rule.Block).ToList()),
                    });
            }
        }
        if (!cmd.Contains("push")) return null;
        var calls = PushGuard.Calls(cmd, cwd);
        if (calls.Count == 0) return null;
        var kw = PushGuard.List(Path.Combine(PushGuard.Dir, "keywords.txt"));
        var strict = PushGuard.List(Path.Combine(PushGuard.Dir, "strict-repos.txt"));
        var evs = new List<PushEvent>();
        foreach (var c in calls)
        {
            var e = PushGuard.Check(c, git, kw, strict, now);
            e.Session = sid; e.Name = sid == null ? null : NicknameStore.Get(sid)?.Name;
            if (e.Verdict == "block")
            {
                var xs = PushGuard.Allows();
                var rest = PushGuard.Apply(e, xs, now);
                if (!rest.SequenceEqual(xs)) PushGuard.SaveAllows(rest);
            }
            PushGuard.Append(e);
            evs.Add(e);
        }
        return PushGuard.HookOutput(evs);
    }

    /// 動作預告命中「GitHub 公開發言」時細判：目標全是 Okle42 私有 repo ⇒ 從 hs 拿掉、回 null；否則留著、回擋的原因
    static string? GhExempt(List<(CaptainLink.Rule Rule, string Segment)> hs, string cmd, string cwd, PushGuard.Git git, GHGuard.View view)
    {
        int i = hs.FindIndex(h => h.Rule.Name == GHGuard.RuleName);
        if (i < 0) return null;
        var why = GHGuard.BlockReason(cmd, cwd, hs[i].Rule, git, view);
        if (why == null) hs.RemoveAt(i);
        return why;
    }

    // MARK: preview-check

    public static string PreviewCheck(IEnumerable<string> cmds, string cwd, PushGuard.Git git, GHGuard.View view)
    {
        var sb = new StringBuilder();
        foreach (var c in cmds)
        {
            var hs = CaptainLink.Hits(c, CaptainLink.LoadRules());
            var gh = GhExempt(hs, c, cwd, git, view);
            sb.Append(hs.Count == 0 ? "不擋" : string.Join("、", hs.Select(h => (h.Rule.Block ? "擋：" : "告：") + h.Rule.Name)))
              .Append('\t').Append(hs.Count == 0 ? CaptainLink.Summary(c) : CaptainLink.HitSummary(c, hs))
              .Append(gh != null ? $"（{gh}）" : "").Append('\n');
        }
        return sb.ToString();
    }

    // MARK: names／captain／release

    public static string Names()
    {
        var names = NicknameStore.All();
        var sb = new StringBuilder();
        foreach (var r in PeerSession.Live().Where(r => r.Entrypoint != "sdk-cli")
                     .OrderBy(r => names.TryGetValue(r.SessionId, out var n) ? n.Name : "~", StringComparer.Ordinal))
        {
            names.TryGetValue(r.SessionId, out var n);
            sb.Append($"{n?.Name ?? "（還沒取名）"}\t{r.Name ?? "-"}\t{n?.Doing ?? "（還沒報任務）"}\n");
        }
        return sb.ToString();
    }

    public static (int Code, string Out, string Err) Captain(List<string> a, string? sid, DateTime now, string showork)
    {
        if (sid == null) return (1, "", "showork captain：要在 Claude Code 裡跑（找不到 CLAUDE_CODE_SESSION_ID）\n");
        if (a.FirstOrDefault() == "ack")       // 隊長處理過的收件匣單標已讀
        {
            if (CaptainStore.Captain() != sid) return (1, "", "只有現任隊長能 ack 收件匣\n");
            if (a.Count < 2) return (1, "", "用法：showork captain ack <單號｜all>\n");
            var n = a.Skip(1).Sum(id => CaptainInbox.Ack(id, now));
            return (0, n == 0 ? "沒有符合的未處理單\n" : $"已標 {n} 筆為已處理\n", "");
        }
        CaptainStore.SetCaptain(sid, CaptainStore.SessionName(sid), now);
        var sb = new StringBuilder(CaptainStore.Manual(showork)).Append('\n');
        // 收件匣裡還沒送到隊長的、還在等放行的：先印，印完標成已送
        var pend = CaptainInbox.Pending(now);
        if (pend.Count > 0)
        {
            sb.Append($"\n【收件匣未處理 {pend.Count} 則】（開工卡、動作預告、擋下等放行）\n");
            foreach (var i in pend)
            {
                sb.Append("  ").Append(i.Line).Append('\n');
                if (!i.Delivered) { i.Delivered = true; CaptainInbox.Save(i); }
            }
        }
        return (0, sb.ToString(), "");
    }

    /// 隊長放行被擋下的動作：只能用在使用者已經明說同意的事；每次都記在 board\permits\releases.jsonl
    public static (int Code, string Out, string Err) Release(List<string> a, string? sid, DateTime now)
    {
        if (a.FirstOrDefault() is not { } id) return (1, "", "用法：showork release <單號>（單號在【動作預告・擋下】那則訊息裡）\n");
        if (sid == null || CaptainStore.Captain() != sid)
            return (1, "", "只有現任隊長能放行。使用者要放行，請在被擋的那個 session 直接打「放行」。\n");
        if (CaptainInbox.Release(id, null, sid, CaptainStore.SessionName(sid) ?? "隊長", "release 指令", now) is not { } i)
            return (1, "", $"找不到等放行的單號 {id}（打錯、已放行過、或超過 24 小時）\n");
        if (Peer.Find(i.Sid) is { } r)
            Peer.Send(r, $"【已放行 {i.Id}】隊長轉述使用者的決定放行了：{i.Text}。現在可以再跑一次剛才被擋下的同一個指令（30 分鐘內、只能用一次）。", "AI工作戰情中心（動作預告）");
        return (0, $"已放行 {i.Id}：{CaptainLink.Label(i.Name, i.Project)}・{i.Text}（30 分鐘內、限一次）\n", "");
    }

    // MARK: 跑 git／gh

    /// PATH 上找執行檔（Windows 另外試 PATHEXT 的副檔名，先 .exe）；找不到回 null
    public static string? FindExe(string name, params string[] fallbacks)
    {
        var exts = OperatingSystem.IsWindows()
            ? new[] { ".exe" }.Concat((Environment.GetEnvironmentVariable("PATHEXT") ?? ".COM;.EXE;.BAT;.CMD").Split(';', StringSplitOptions.RemoveEmptyEntries)).Distinct(StringComparer.OrdinalIgnoreCase).ToArray()
            : new[] { "" };
        foreach (var d in (Environment.GetEnvironmentVariable("PATH") ?? "").Split(Path.PathSeparator, StringSplitOptions.RemoveEmptyEntries))
            foreach (var e in exts)
            {
                try { var f = Path.Combine(d.Trim('"'), name + e); if (File.Exists(f)) return f; } catch { }
            }
        return fallbacks.FirstOrDefault(File.Exists);
    }

    /// 跑外部指令拿輸出；timeout 到了就殺掉（gh 卡網路 ⇒ 判不出來＝擋）
    public static (int Code, string Out) RunExe(string? exe, IEnumerable<string> args, int timeoutMs = 60_000)
    {
        if (exe == null) return (127, "");
        try
        {
            var psi = new ProcessStartInfo(exe)
            {
                RedirectStandardOutput = true, RedirectStandardError = true, RedirectStandardInput = true, UseShellExecute = false, CreateNoWindow = true,
                StandardOutputEncoding = Encoding.UTF8,
            };
            foreach (var x in args) psi.ArgumentList.Add(x);
            using var p = Process.Start(psi)!;
            p.StandardInput.Close();
            p.ErrorDataReceived += (_, _) => { };
            p.BeginErrorReadLine();
            var outTask = p.StandardOutput.ReadToEndAsync();      // 先讀完再等，免得輸出塞滿管子卡住
            if (!p.WaitForExit(timeoutMs)) { try { p.Kill(true); } catch { } return (124, ""); }
            return (p.ExitCode, outTask.Result);
        }
        catch { return (127, ""); }
    }

    static string? gitExe, ghExe;
    public static (int Code, string Out) RunGit(string dir, string[] args) =>
        RunExe(gitExe ??= FindExe("git", @"C:\Program Files\Git\cmd\git.exe", "/usr/bin/git"), new[] { "-C", dir }.Concat(args));

    public static (string Owner, bool IsPrivate)? GhView(string repo)
    {
        var r = RunExe(ghExe ??= FindExe("gh", @"C:\Program Files\GitHub CLI\gh.exe", "/opt/homebrew/bin/gh", "/usr/local/bin/gh"),
                       new[] { "repo", "view", repo, "--json", "isPrivate,owner" }, 8000);
        if (r.Code != 0 || HookJson.Parse(r.Out) is not JsonObject j || j["isPrivate"] is not JsonValue pv
            || pv.GetValueKind() is not (System.Text.Json.JsonValueKind.True or System.Text.Json.JsonValueKind.False) || j["owner"].Str("login") is not { } owner) return null;
        return (owner, pv.GetValueKind() == System.Text.Json.JsonValueKind.True);
    }
}
