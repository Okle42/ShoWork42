using System.Diagnostics;
using System.Text;
using System.Text.Json.Nodes;
namespace ShoWork.Hooks;

// 11-02：namespace 改成 ShoWork.Hooks（原本 ShoWork）：看板那邊（ShoWork.Win\Board，namespace ShoWork）也有 Permit、B1Board⋯，
// 測試專案兩邊一起編，放在 ShoWork 底下會先找到看板那一份。

// showork.exe 的 hook 端子指令（W5，Mac 版 Sources/showork/main.swift＋CaptainCLI.swift 的移植）：
//   showork brief          SessionStart hook：印出給 AI 的戰情中心說明
//   showork card …         AI 每輪自報（完成度／信心度／要你決定的事）；--kind start 開工卡也進隊長收件匣
//   showork title          UserPromptSubmit hook：開工卡提醒；使用者打「放行」／「放行 <單號>」放行被擋的指令
//   showork guard-push     PreToolUse(Bash) hook：動作預告（擋／告）＋1 樓保全的 push 守門
//   showork preview-check "<指令>"…   動作預告的分類試算（不擋、不送、不寫檔）
//   showork names          活著的 session：英文名、session 名、正在做的任務
//   showork captain [ack <單號｜all>]   把目前這個 session 設成隊長，印出隊長守則與收件匣未處理的單
//   showork release <單號>  隊長放行被擋下的動作
//   （以下 11-02 補齊 Mac 有、Windows 沒有的）
//   showork permit         PermissionRequest hook：等你在戰情中心收件匣按允許／拒絕（讀 stdin、最久等 1 小時；Permit.cs）
//   showork ctx-wrapup     Stop hook：ctx 到門檻就請它收尾（Mac 的 hook_ctx_wrapup.py；CtxWrapup.cs）
//   showork statusline     Claude Code 的 statusLine：寫 ctx／5 小時與 7 天用量檔，再印狀態列（串接使用者原本的；StatusLine.cs）
//   showork roster [--json]  名冊：每個 session 的名字、專案、在做什麼、重工警告（名冊由 ShoWorkAgent 每 3 秒寫）
//   showork task add --to <英文名> --text "…" [--then-to <下一棒> --then "…"]｜showork task cancel <單號>｜showork tasks [--all]
//   showork b1 read [--n 20｜--all]｜showork b1 post --text "…" [--re <編號>]｜showork b1 hint
//   showork tick [--fresh] 看板的背景工作（ShoWorkAgent 每 5 秒叫一次）：工作卡片轉隊長、合併預告、交接提醒、巡檢（派工回報在看板的 TaskRouter）
// hook（brief／title／guard-push）的合約：永遠 exit 0、出錯安靜略過；stdin 是 Claude Code 給的 hook JSON。
// 輸出一律 UTF-8 位元組直接寫 stdout（Windows 主控台的字碼頁會把中文弄壞）。
// 邏輯都在可測的函式裡（輸入字串、回傳輸出字串），Run 只負責讀 stdin／環境變數、寫 stdout。
static class HookCli
{
    static readonly string[] HookCommands = { "brief", "title", "guard-push", "permit", "ctx-wrapup", "statusline", "tick" };
    public static bool Handles(string cmd) => cmd is "brief" or "card" or "title" or "guard-push" or "preview-check" or "names" or "captain" or "release"
        or "permit" or "ctx-wrapup" or "statusline" or "roster" or "task" or "tasks" or "b1" or "tick";

    /// 叫這個 hook／CLI 的 claude 行程（往上找第一個有 ~/.claude/sessions/<pid>.json 的祖先；Mac 的 Handover.claudePID）。
    /// Win32 的行程樹在 Program.cs，Main 開頭接上；測試裡是 null
    public static Func<int?> ClaudePid = () => null;
    /// 行程還在不在（permit 等回答時看 AI 結束了沒）
    public static Func<int, bool> Alive = PeerSession.Alive;

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
                case "permit":
                    if (!IsReviewer && Stdin(64 << 20) is { } pj && PermitHook(pj) is { } po) Out(po + "\n");
                    return 0;
                case "ctx-wrapup":
                    if (!IsReviewer && CtxWrapup.Run(Stdin(1 << 20), ShoworkPath, HookPaths.Env("SHOWORK_TEST_CTX"), now) is { } wo) Out(wo + "\n");
                    return 0;
                case "statusline":
                    Out(StatusLine.Run(Stdin(4 << 20), now));
                    return 0;
                case "roster":
                    return Report(RosterCli(args.Contains("--json"), now));
                case "tasks":
                    return Report(TasksCli(args.Contains("--all"), now));
                case "task":
                    return Report(TaskCli(args.Skip(1).ToList(), EnvSid, now, ShoworkPath));
                case "b1":
                    return Report(B1Cli(args.Skip(1).ToList(), EnvSid, now, ShoworkPath));
                case "tick":
                    Tick(args.Contains("--fresh"), now, ShoworkPath);
                    return 0;
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
            // Windows PowerShell 用管線餵原生程式時會在前面加 BOM（11-01 Surface 實測：guard-push 因此整段 JSON 解析失敗、不擋）
            return Encoding.UTF8.GetString(ms.ToArray()).TrimStart('﻿');
        }
        catch { return null; }
    }

    static void Out(string s) { if (s.Length == 0) return; using var o = Console.OpenStandardOutput(); o.Write(Encoding.UTF8.GetBytes(s)); }
    static void Err(string s) { if (s.Length == 0) return; using var o = Console.OpenStandardError(); o.Write(Encoding.UTF8.GetBytes(s)); }
    static int Report((int Code, string Out, string Err) r) { Out(r.Out); Err(r.Err); return r.Code; }

    static JsonObject? HookInput(string? stdin) => HookJson.Parse(stdin) as JsonObject;

    // MARK: brief

    /// SessionStart：先看自動接手（Handover.Claim：hook JSON 的 session_id／source／cwd；/clear 後 sid 會換，以 JSON 為準），再印說明
    public static string Brief(string? stdin, string? envSid, string showork, DateTime? now = null)
    {
        var o = HookInput(stdin);
        var sid = o.Str("session_id") is { Length: > 0 } s ? s : envSid;
        var claim = sid == null ? null : Handover.Claim(sid, ClaudePid(), o.Str("cwd"), o.Str("source"), now ?? DateTime.UtcNow);
        return (claim != null ? claim + "\n" : "") + Hooks.Brief.Text(showork, sid == null ? null : NicknameStore.Ensure(sid).Name) + "\n";
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
        if (r.IsWrapup && r.Handoff is { } h)   // 收尾完（Handover.cs ②）：看板（ShoWorkAgent 的 HandoverClear）等它閒下來送 /clear
        {
            var cwd = PeerSession.Live().FirstOrDefault(x => x.SessionId == sid)?.Cwd ?? Directory.GetCurrentDirectory();
            Handover.Save(new HandoverRecord { Sid = sid, Pid = ClaudePid() ?? 0, Cwd = cwd, Name = NicknameStore.Ensure(sid, now).Name, Handoff = h, Summary = r.Summary, At = r.At });
        }
        var n = NicknameStore.Update(sid, r.Doing, now);
        if (r.IsWrapup) return (0, $"ok（{n.Name}：已登記交接，停下來後看板會自動 /clear，新 context 自動接手）\n", err);
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
        string? nag = null, typed = null, handoverNote = null;
        // 11-01 使用者：「我叫你傳 LINE 還要再打放行」⇒ 使用者在 session 直接打的指令也算事先放行（同戰情中心回答：點名的動作、30 分鐘、每種一次、否定句不算）。
        //   已經擋著的單，這則指令點名了就直接放行。其他 session／系統訊息（NeedsStart 擋掉的 <…> 標籤）不算。（Mac 2ce3a8a）
        if (ev == "UserPromptSubmit" && sid != null && CaptainLink.NeedsStart(prompt) && !prompt!.Trim().StartsWith("放行", StringComparison.Ordinal))
            typed = TypedRelease(sid, prompt.Trim(), now);
        // 收尾後只有使用者本人又下指令才不自動 /clear；其他 session／看板的訊息回一段「交接中」提醒（T1026230337）
        if (ev == "UserPromptSubmit" && sid != null) handoverNote = Handover.NoteNewPrompt(sid, prompt, now);
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
                else nag = CaptainLink.ReleaseMissText(id);
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
        var ctx = string.Join("\n", new[] { typed, nag, handoverNote }.Where(x => x != null));
        var n = NicknameStore.Get(sid);
        if (n != null) NicknameStore.Touch(sid, now);
        var outp = Nicknames.HookOutput(n, ev, ctx.Length == 0 ? null : ctx);
        return outp.Length == 0 ? "" : outp + "\n";
    }

    /// 使用者打的指令點名了被擋的動作 ⇒ 記成事先放行；已經擋著的單直接放行，回給 AI 的一句話（沒有＝null）
    public static string? TypedRelease(string sid, string p, DateTime now)
    {
        CaptainInbox.RecordAnswer(sid, p, null, now);
        var waiting = CaptainInbox.All().Where(i => i.Kind == "block" && i.Sid == sid && i.Released == null && now - i.At < CaptainInbox.ReleaseTTL).ToList();
        if (waiting.LastOrDefault(i => i.Kinds.Count > 0 && i.Kinds.All(k => CaptainInbox.Authorizes(p, k))) is not { } item
            || CaptainInbox.UsePreapproval(sid, item.Kinds, now) is not { } pre) return null;
        var who = NicknameStore.Get(sid)?.Name ?? "使用者";
        CaptainInbox.Release(item.Id, sid, sid, $"使用者（在 {who} 的終端機下指令：{SwiftText.Prefix(pre.Answer, 40)}）", "使用者輸入", now);
        return $"使用者這則指令已點名放行單號 {item.Id}（{item.Text}）。現在可以再跑一次剛才被擋下的同一個指令（30 分鐘內有效、只能用一次）。";
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
                    var item = CaptainInbox.ReleaseByAnswer(CaptainInbox.Waiting(sid, fp, now) ?? NewBlock(CaptainLink.HitSummary(cmd, hs)), pre, now);
                    if (captain != null && Peer.Find(captain) is { } to
                        && Peer.Send(to, $"【已放行 {item.Id}】{CaptainLink.Label(name, project)}：使用者在戰情中心回答「{pre.Answer}」已點名這個動作・{item.Text}", "AI工作戰情中心（動作預告）").Id != null)
                    { item.Delivered = true; CaptainInbox.Save(item); }
                }
                else if (blocks.Count > 0 && !released)
                {
                    // 擋下等放行：同一個指令重試不再開新單；第一次立即送隊長（不在線就留在收件匣）
                    var item = CaptainInbox.Waiting(sid, fp, now) ?? NewBlock(CaptainLink.HitSummary(cmd, hs) + (ghWhy != null ? $"（{ghWhy}）" : ""));
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

    // MARK: permit

    /// PermissionRequest hook：把要求寫給戰情中心，等你在收件匣按「允許／一律允許／拒絕」（規則在 Permit.cs）。
    /// 終端機的對話框照常出現；先在終端機答了、AI 結束、等超過一小時，就安靜離開（不回 decision，交還給終端機）。
    /// AskUserQuestion／ExitPlanMode 也走這條：收件匣顯示題目選項／計畫內容，回答時改 updatedInput。
    public static string? PermitHook(string stdin, Action<int>? sleep = null)
    {
        var o = HookInput(stdin);
        if (Permit.Request(o, ClaudePid(), DateTime.UtcNow) is not { } req) return null;
        return Permit.Wait(req, o, Alive, sleep ?? Thread.Sleep, () => DateTime.UtcNow);
    }

    // MARK: roster／tasks／task（Mac 的 CaptainCLI.swift）

    /// 名冊要是 30 秒內寫的才算數（常駐程式沒在跑就是舊的）
    static Roster? FreshRoster(DateTime now) => CaptainStore.Roster() is { } r && now - r.At < TimeSpan.FromSeconds(30) ? r : null;

    /// zh_TW 的 RelativeDateTimeFormatter（.short）：「3 分鐘前」
    public static string Relative(DateTime t, DateTime now)
    {
        var s = (now - t).TotalSeconds;
        if (s < 1) return "現在";
        if (s < 60) return $"{(int)s} 秒前";
        if (s < 3600) return $"{(int)(s / 60)} 分鐘前";
        if (s < 86400) return $"{(int)(s / 3600)} 小時前";
        return $"{(int)(s / 86400)} 天前";
    }

    public static (int Code, string Out, string Err) RosterCli(bool json, DateTime now)
    {
        if (FreshRoster(now) is not { } r) return (1, "", "名冊沒有更新（AI工作戰情中心的常駐程式 ShoWorkAgent 沒在跑？系統匣有沒有 ShoWork42 圖示）\n");
        if (json) return (0, HookJson.Text(r.ToJson()) + "\n", "");
        var sb = new StringBuilder();
        var open = CaptainStore.Tasks().Where(t => t.IsOpen).ToList();
        foreach (var e in r.Entries.OrderBy(e => e.Captain ? 0 : 1).ThenBy(e => e.Project, StringComparer.Ordinal))
        {
            var head = $"■ {e.Name}{(e.Captain ? "（隊長）" : "")}｜{e.Project}｜{RosterEntry.ColumnTitle(e.Column)}：{e.Reason}";
            if (e.CtxTokens is { } tk) head += $"｜ctx {tk / 1000}k"; else if (e.Ctx is { } c) head += $"｜ctx {c}%";
            if (e.Kind == "bg") head += "｜背景";
            if (e.LastActivity is { } la) head += $"｜{Relative(la, now)}";
            sb.Append(head).Append('\n');
            sb.Append($"  在做：{e.Title}\n");
            if (e.Summary is { Length: > 0 } s) sb.Append($"  最後：{SwiftText.Prefix(s, 120)}\n");
            if (e.Handover is { } h) sb.Append($"  🔁 {h}（自動交接；/clear 前不要派新工作給它）\n");
            if (e.SameProject.Count > 0) sb.Append($"  ⚠ 同專案還有：{string.Join("、", e.SameProject)}（不要再派同專案的事給別人）\n");
            foreach (var t in open.Where(t => t.ToSession == e.SessionId || t.To == e.Name))
                sb.Append($"  派工 {t.Id}［{CaptainTask.Title(t.State)}］{SwiftText.Prefix(t.Text, 60)}\n");
        }
        return (0, sb.ToString(), "");
    }

    public static (int Code, string Out, string Err) TasksCli(bool all, DateTime now)
    {
        var ts = CaptainStore.Tasks().Where(t => all || t.IsOpen || now - t.UpdatedAt < TimeSpan.FromHours(12)).ToList();
        if (ts.Count == 0) return (0, "沒有派工單\n", "");
        var sb = new StringBuilder();
        static string F(DateTime d) => d.ToLocalTime().ToString("MM-dd HH:mm", System.Globalization.CultureInfo.InvariantCulture);
        foreach (var t in ts)
        {
            var proj = t.Project == null ? "" : t.Project.StartsWith('（') ? t.Project : $"（{t.Project}）";
            sb.Append($"{t.Id}［{CaptainTask.Title(t.State)}］→ {t.To}{proj}｜派出 {F(t.CreatedAt)}｜更新 {F(t.UpdatedAt)}\n");
            sb.Append($"  任務：{SwiftText.Prefix(t.Text.Replace("\n", " "), 100)}\n");
            if (t.Summary != null) sb.Append($"  回報：{t.Summary}\n");
            if (t.Ask != null) sb.Append($"  要使用者決定：{t.Ask}\n");
        }
        return (0, sb.ToString(), "");
    }

    public static (int Code, string Out, string Err) TaskCli(List<string> a, string? sid, DateTime now, string showork)
    {
        var sub = a.Count == 0 ? "" : a[0];
        var rest = a.Skip(1).ToList();
        switch (sub)
        {
            case "add": return TaskAdd(rest, sid, now, showork);
            case "cancel":
                if (rest.FirstOrDefault() is not { } id || CaptainStore.Task(id) is not { } t) return (1, "", "showork task cancel <單號>：找不到這張單\n");
                t.State = "cancelled"; t.UpdatedAt = now; CaptainStore.Save(t);
                var note = $"【隊長取消 {id}】這張派工不用做了：{SwiftText.Prefix(t.Text.Replace("\n", " "), 60)}。已經做到一半的就停在安全的地方，回報目前狀態即可。";
                bool ok = Peer.Find(t.ToSession ?? t.To) is { } to && Peer.Send(to, note, "AI工作戰情中心").Id != null;
                return (0, ok ? $"已取消 {id}，也通知 {t.To} 不用做了\n" : $"已取消 {id}；通知 {t.To} 失敗，請用 SendMessage 告訴它不用做了\n", "");
            default:
                return (1, "", "用法：showork task add --to <英文名，例如 Chris> --text \"…\"｜showork task cancel <單號>\n");
        }
    }

    static (int Code, string Out, string Err) TaskAdd(List<string> a, string? from, DateTime now, string showork)
    {
        string? to = null, text = null, thenTo = null, thenText = null;
        for (int i = 0; i < a.Count; i += 2)
        {
            var k = a[i];
            if (i + 1 >= a.Count) return (1, "", $"{k} 後面少了值\n");
            var v = a[i + 1];
            switch (k)
            {
                case "--to": to = v; break;
                case "--text": text = v; break;
                case "--then-to": thenTo = v; break;
                case "--then": thenText = v; break;
                default: return (1, "", $"不認得的參數 {k}\n");
            }
        }
        if (to == null || text == null || text.Trim().Length == 0)
            return (1, "", "用法：showork task add --to <英文名，例如 Chris> --text \"…\" [--then-to <下一棒> --then \"…\"]\n");
        if ((thenTo == null) != (thenText == null)) return (1, "", "--then-to 和 --then 要一起給\n");
        if (from == null) return (1, "", "要在隊長的 Claude Code session 裡跑\n");
        var roster = FreshRoster(now);
        // 短名（Chris）或全名都可以；名冊只有活著的 session，回收重用的名字自然指向現在那一個
        var nick = NicknameStore.All().ToDictionary(kv => kv.Key, kv => kv.Value.Name);
        List<RosterEntry> Entries(string n) => roster == null ? new()
            : ShortName.Match(n, roster.Entries.Select(e => (e.SessionId, (string?)e.Name)).ToList(), nick).Select(s => roster.Entries.First(e => e.SessionId == s)).ToList();
        RosterEntry? Entry(string n) => Entries(n) is [var one] ? one : null;
        foreach (var n in new[] { to }.Concat(thenTo != null ? new[] { thenTo } : Array.Empty<string>()))
            if (Entries(n) is { Count: > 1 } many)
                return (1, "", $"「{n}」有 {many.Count} 個開著的 session，請改用全名或 sessionId：" + string.Join("、", many.Select(e => $"{e.Name}（{e.SessionId[..Math.Min(8, e.SessionId.Length)]}）")) + "\n");
        var target = Entry(to);
        if (roster != null && target == null) return (1, "", $"名冊裡沒有「{to}」；先跑 showork roster 看名字\n");
        if (thenTo != null && roster != null && Entry(thenTo) == null) return (1, "", $"名冊裡沒有下一棒「{thenTo}」\n");
        if (target?.SessionId == from) return (1, "", "不能派給自己\n");
        if (CaptainStore.Captain() != from) CaptainStore.SetCaptain(from, CaptainStore.SessionName(from), now);
        var id = Dispatch.NewId(now, CaptainStore.Tasks().Select(t => t.Id).ToHashSet());
        var task = new CaptainTask
        {
            Id = id, From = from, To = target?.Name ?? to, ToSession = target?.SessionId, Project = target?.Project, Text = text, CreatedAt = now, UpdatedAt = now,
            ThenTo = thenTo == null ? null : Entry(thenTo) is { } te ? nick.GetValueOrDefault(te.SessionId) ?? te.Name : thenTo, ThenText = thenText,
        };
        var err = "";
        if (target is { SameProject.Count: > 0 } w) err += $"⚠ {w.Project} 還有別的 session：{string.Join("、", w.SameProject)}\n";
        if (target?.CtxTokens is { } tk && tk >= ContextGuard.TokenLimit) err += $"⚠ {to} 的 context 已用 {tk / 1000}k（門檻 {ContextGuard.TokenLimit / 1000}k），可能做不完\n";
        var (saved, e2) = Dispatch.Send(task, showork, CaptainStore.SessionName(from) ?? "隊長");
        if (e2 == null)
            return (0, $"單號 {id}：已送進 {saved.To} 的收件匣" + (saved.ThenTo != null ? $"；它做完會自動接力給 {saved.ThenTo}" : "") + "。回報會由看板自動傳給你。\n", err);
        return (0, $"單號 {id} 已建，但直送失敗（{e2}）。請改用 SendMessage（to: \"{saved.To}\"）送出以下全文：\n-----\n{Dispatch.Message(saved, showork)}\n", err);
    }

    // MARK: b1（Mac 的 B1CLI.swift）

    public static (int Code, string Out, string Err) B1Cli(List<string> a, string? sid, DateTime now, string showork)
    {
        var sub = a.Count == 0 ? "read" : a[0];
        var rest = a.Skip(1).ToList();
        string? Value(string flag) { int i = rest.IndexOf(flag); return i >= 0 && i + 1 < rest.Count ? rest[i + 1] : null; }
        switch (sub)
        {
            case "read":
                var posts = B1Board.All();
                if (posts.Count == 0) return (0, "Agent交流互動板還是空的。\n", "");
                int n = rest.Contains("--all") ? posts.Count : int.TryParse(Value("--n"), out var k) ? k : 20;
                var sb = new StringBuilder($"Agent交流互動板（共 {posts.Count} 則，最近 {Math.Min(n, posts.Count)} 則）：\n");
                foreach (var p in posts.Skip(Math.Max(0, posts.Count - n))) sb.Append(p.Line()).Append('\n');
                return (0, sb.ToString(), "");
            case "post":
                if (Value("--text") is not { } text) return (1, "", "用法：showork b1 post --text \"<150 字以內>\" [--re <編號>]\n");
                if (sid == null) return (1, "", "showork b1 post：要在 Claude Code 裡跑（找不到 CLAUDE_CODE_SESSION_ID）\n");
                var name = NicknameStore.Ensure(sid, now).Name;
                var project = CaptainStore.Project(sid) ?? "";
                int? re = int.TryParse(Value("--re")?.Trim('#'), out var r) ? r : null;
                if (B1Board.Post(sid, name, project, text, re, now) is not { } post) return (1, "", "沒有留成（內容是空的，或寫檔失敗）\n");
                var o = $"已留言 #{post.Id}" + (SwiftText.Count(B1Board.Clean(text)) > B1Talk.MaxChars ? $"（超過 {B1Talk.MaxChars} 字，下次精簡一點）" : "") + "\n";
                // 轉給現任隊長（自己就是隊長、或隊長不在線就不送；留言本身已經在板上）
                if (CaptainStore.Captain() is { } cap && cap != sid && Peer.Find(cap) is { } to)
                {
                    var (ok, e) = Peer.Send(to, post.CaptainText, "AI工作戰情中心（Agent交流互動板）");
                    o += ok != null ? $"已轉給隊長 {to.Name ?? ""}\n" : $"轉給隊長失敗（{e}）；留言在板上，隊長用 showork b1 read 看得到\n";
                }
                return (0, o, "");
            case "hint":
                return (0, B1Talk.WrapupNote(showork, B1Board.All()) + "\n", "");
            default:
                return (1, "", "用法：showork b1 read [--n 20｜--all]｜showork b1 post --text \"…\" [--re <編號>]｜showork b1 hint\n");
        }
    }

    // MARK: tick：看板的背景工作（Mac BoardSource 的 relayCards／flushNotices／TaskRouter／HandoverClear 的 interrupted／captainAlarm）

    static string RelayState => Path.Combine(HookPaths.Board, "relay-state.json");
    static string AlarmState => Path.Combine(HookPaths.Board, "alarm-state.json");
    static void TickLog(string s, DateTime now) => HookJson.AppendLine(Path.Combine(HookPaths.Board, "tick.log"), $"{now.ToLocalTime():yyyy-MM-dd HH:mm:ss} {s}");

    /// fresh＝常駐程式剛啟動（卡片轉送重新播種、巡檢從現在起算）。每一段各自吞例外，一段壞了不擋其他
    public static void Tick(bool fresh, DateTime now, string showork)
    {
        var live = PeerSession.Live();
        var captain = CaptainStore.Captain() is { } c && live.Any(r => r.SessionId == c) ? c : null;
        var roster = CaptainStore.Roster();
        void Try(Action f) { try { f(); } catch (Exception e) { TickLog("error " + e.Message, now); } }
        Try(() => RelayCards(fresh, captain, roster, now));
        Try(() => FlushNotices(captain, now));
        // 派工回報與接力（Mac 的 TaskRouter）由看板那邊的 ShoWork.Win\Board\BoardActions.cs TaskRouter 做，這裡不重複送
        Try(() => NotifyInterrupted(captain, now));
        Try(() => CaptainAlarm(fresh, captain, roster != null && now - roster.At < TimeSpan.FromSeconds(30) ? roster : null, now));
    }

    /// 工作卡片自動轉送隊長（CardRelay.cs）
    static void RelayCards(bool fresh, string? captain, Roster? roster, DateTime now)
    {
        if (Prefs.Flag(CardRelay.SettingKey) == false) return;
        var state = fresh ? new CardRelay.State() : CardRelay.State.From(HookJson.ReadObject(RelayState));
        var reports = CardReport.All();
        var nick = NicknameStore.All();
        var project = (roster?.Entries ?? new()).GroupBy(e => e.SessionId).ToDictionary(g => g.Key, g => g.First().Project);
        var outs = CardRelay.Plan(reports, captain, captain != null, state, now, (sid, r) =>
            CardRelay.Text(nick.GetValueOrDefault(sid)?.Name ?? project.GetValueOrDefault(sid) ?? sid[..Math.Min(8, sid.Length)], project.GetValueOrDefault(sid), r));
        HookJson.WriteAtomic(RelayState, HookJson.Text(state.ToJson()));
        if (outs.Count == 0 || captain == null || Peer.Find(captain) is not { } to) return;
        foreach (var o in outs)
        {
            var (id, err) = Peer.Send(to, o.Text, "AI工作戰情中心");
            TickLog($"RELAY card {o.SessionId[..Math.Min(8, o.SessionId.Length)]} → {to.Name ?? captain} {id ?? err}", now);
            // 開工卡送到了 ⇒ 收件匣那張標成已送
            if (id != null && reports.GetValueOrDefault(o.SessionId)?.IsStart == true)
                foreach (var i in CaptainInbox.All().Where(i => i.Kind == "start" && i.Sid == o.SessionId && !i.Delivered)) { i.Delivered = true; CaptainInbox.Save(i); }
        }
    }

    /// 收件匣裡還沒送的預告：同一 session 安靜 5 秒（最多等 30 秒）合成一則送隊長
    static void FlushNotices(string? captain, DateTime now)
    {
        if (captain == null) return;
        var due = CaptainLink.DueNotices(CaptainInbox.All(), now);
        if (due.Count == 0 || Peer.Find(captain) is not { } to) return;
        foreach (var g in due)
        {
            var (id, err) = Peer.Send(to, CaptainLink.NoticeText(g), "AI工作戰情中心（動作預告）");
            TickLog($"PREVIEW {g[0].Name} ×{g.Count} → {to.Name ?? captain} {id ?? err}", now);
            if (id != null) foreach (var i in g) { i.Delivered = true; CaptainInbox.Save(i); }
        }
    }

    /// 派工單做完／要你決定／卡住 ⇒ 傳【派工回報】給隊長；做完又有下一棒 ⇒ 自動派給下一棒（Mac 的 TaskRouter）
    static void RouteTasks(DateTime now, string showork)
    {
        foreach (var t in CaptainStore.Tasks().Where(t => Dispatch.ShouldNotify(t) || (t.State == "done" && t.ThenTo != null && t.FollowUp == null)))
        {
            CaptainTask? follow = null;
            if (Dispatch.NextLeg(t, Dispatch.NewId(now, CaptainStore.Tasks().Select(x => x.Id).ToHashSet()), now) is { } next)
            {
                var (saved, err) = Dispatch.Send(next, showork);
                follow = saved;
                TickLog($"ROUTER followup {t.Id} → {saved.Id} {saved.To} {err ?? "ok"}", now);
            }
            string? notified = null;
            if (Dispatch.ShouldNotify(t))
            {
                // 隊長不在（或從看板直接派的）：Mac 發系統通知；Windows 的 showork 沒有通知管道，記 log、卡片上看得到
                if (Peer.Find(t.From) is { } cap && cap.SessionId != t.ToSession)
                    TickLog($"ROUTER notify {t.Id} {t.State} → {cap.Name ?? cap.SessionId} {Peer.Send(cap, Dispatch.ReportText(t, follow), "AI工作戰情中心").Error ?? "ok"}", now);
                else TickLog($"ROUTER notify {t.Id} {t.State}：隊長不在線", now);
                notified = t.State;
            }
            // 寫回前再讀一次：對方可能剛好又回報了，只動我們自己的欄位
            if (CaptainStore.Task(t.Id) is not { } freshT) continue;
            if (follow != null) freshT.FollowUp = follow.Id;
            if (notified != null) freshT.Notified = notified;
            CaptainStore.Save(freshT);
        }
    }

    /// 收尾後使用者又派新工作（interrupted）⇒ 轉隊長一則提醒（Mac HandoverClear 的 .interrupted）
    static void NotifyInterrupted(string? captain, DateTime now)
    {
        foreach (var r in Handover.All().Where(r => r.State == "interrupted" && !r.Notified))
        {
            r.Notified = true;
            Handover.Save(r);
            var text = $"【交接提醒】{r.Name} 已在 {r.At.ToLocalTime():HH:mm} 收尾（交接 {r.Handoff}），但之後使用者又派了新工作，所以先不自動 /clear；"
                + "ctx 再多 150k 時 Stop hook 會再請它收尾一次。要現在就換手，請它做完這件後再發一次 showork card --kind wrapup。";
            Handover.Log($"interrupted {r.Name} {r.Sid[..Math.Min(8, r.Sid.Length)]}", now);
            if (captain != null && captain != r.Sid && Peer.Find(captain) is { } to) Peer.Send(to, text, "AI工作戰情中心（交接）");
        }
    }

    /// 隊長鬧鐘：每 captain.alarmMinutes 分鐘（預設 30）送【巡檢時間】；名冊跟上次一樣只送「無變化」；沒有隊長不送
    static void CaptainAlarm(bool fresh, string? captain, Roster? roster, DateTime now)
    {
        var st = HookJson.ReadObject(AlarmState);
        if (fresh || st.Date("at") == null) { HookJson.WriteAtomic(AlarmState, HookJson.Text(new JsonObject { ["at"] = HookJson.Iso(now) })); return; }   // 看板啟動算起，不一開就送
        if (captain == null || roster == null) return;
        var min = Prefs.Number(CaptainLink.AlarmKey) ?? 30;
        if (min <= 0 || now - st.Date("at")!.Value < TimeSpan.FromMinutes(min)) return;
        var (full, sig) = CaptainLink.Alarm(roster, CaptainInbox.Pending(now).Count, now);
        var text = sig == st.Str("sig") ? CaptainLink.AlarmUnchanged(roster.Entries.Count(e => !e.Captain)) : full;
        HookJson.WriteAtomic(AlarmState, HookJson.Text(new JsonObject { ["at"] = HookJson.Iso(now), ["sig"] = sig }));
        CaptainInbox.Prune(now);
        if (Peer.Find(captain) is { } to) TickLog($"ALARM → {to.Name ?? captain} {Peer.Send(to, text, "AI工作戰情中心（巡檢）").Error ?? "ok"}", now);
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
