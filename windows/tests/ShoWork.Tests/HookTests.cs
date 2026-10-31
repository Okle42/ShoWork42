using System.Diagnostics;
using System.Net.Sockets;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;
using ShoWork.Hooks;
using Xunit;

// 這些測試改環境變數（SHOWORK_HOME 等）切到暫存資料夾：整個測試組件不平行跑，免得互踩
[assembly: CollectionBehavior(DisableTestParallelization = true)]

namespace ShoWork.Tests;

/// W5 hook 端（showork card／title／guard-push／release）。對照 Mac 的 Tests/ShoWorkCoreTests/CaptainLinkTests.swift、PushGuardTests.swift。
/// 假名、假指令；資料一律寫在暫存資料夾（SHOWORK_HOME、SHOWORK_CLAUDE_DIR、SHOWORK_LOCAL_CONFIG）
public sealed class HookTests : IDisposable
{
    static readonly DateTime T0 = DateTime.UnixEpoch.AddSeconds(1_792_650_000);
    readonly string root = Path.Combine(Path.GetTempPath(), "sw-hook-" + Guid.NewGuid().ToString("N")[..8]);
    string Board => Path.Combine(root, "home", "board");
    static readonly string[] Vars = { "SHOWORK_HOME", "SHOWORK_CLAUDE_DIR", "SHOWORK_LOCAL_CONFIG", "SHOWORK_CAPTAIN_INBOX", "SHOWORK_RELEASE_LOG",
                                      "SHOWORK_PREAPPROVAL_LOG", "SHOWORK_PREVIEW_RULES", "SHOWORK_REVIEWER", "CLAUDE_CODE_ENTRYPOINT" };

    public HookTests()
    {
        foreach (var v in Vars) Environment.SetEnvironmentVariable(v, null);
        Directory.CreateDirectory(Path.Combine(root, "claude", "sessions"));
        Environment.SetEnvironmentVariable("SHOWORK_HOME", Path.Combine(root, "home"));
        Environment.SetEnvironmentVariable("SHOWORK_CLAUDE_DIR", Path.Combine(root, "claude"));
        // 同 Mac 的 LocalFixture（假名）
        var local = Path.Combine(root, "local.json");
        File.WriteAllText(local, """{"owner":"Demo User","privateDataRepos":["ProjectC"],"winHosts":["winbox"],"noKickoffRepos":["ProjectC"]}""");
        Environment.SetEnvironmentVariable("SHOWORK_LOCAL_CONFIG", local);
    }

    public void Dispose()
    {
        foreach (var v in Vars) Environment.SetEnvironmentVariable(v, null);
        try { Directory.Delete(root, true); } catch { }
    }

    static (int, string) NoGit(string d, string[] a) => (128, "");
    static (string, bool)? NoView(string r) => null;
    static JsonObject Obj(string? s) => (JsonObject)JsonNode.Parse(s!)!;
    static string Stdin(string sid, string cmd, string cwd = "/x") =>
        new JsonObject { ["session_id"] = sid, ["cwd"] = cwd, ["tool_input"] = new JsonObject { ["command"] = cmd } }.ToJsonString();
    static string Prompt(string sid, string prompt, string cwd = "/x") =>
        new JsonObject { ["session_id"] = sid, ["hook_event_name"] = "UserPromptSubmit", ["prompt"] = prompt, ["cwd"] = cwd }.ToJsonString();
    static string? DenyId(string? output)
    {
        if (output == null) return null;
        var h = Obj(output)["hookSpecificOutput"]!;
        Assert.Equal("deny", h["permissionDecision"]!.GetValue<string>());
        return Regex.Match(h["permissionDecisionReason"]!.GetValue<string>(), @"單號 (B[A-Z0-9]{4})").Groups[1].Value;
    }

    // MARK: card

    [Fact] // 卡片檔：欄位名、時間格式跟 Mac 寫的一樣；Windows 看板（Board\Card.cs）讀得懂；英文名也存起來
    public void CardFileMatchesMac()
    {
        var (code, out_, err) = HookCli.Card(new List<string> { "--doing", "改按鈕顏色", "--status", "review", "--progress", "80%", "--confidence", "130",
            "--summary", "改好了", "--ask", "要 push 嗎", "--options", "好，push|先不要| |好，push", "--how", "改 View.cs", "--report", "/x/r.md", "--task", "T1" },
            "S1", T0.AddMilliseconds(56));
        Assert.Equal(0, code);
        Assert.Contains("找不到派工單 T1", err);                               // 沒有這張單：自報照存
        var j = Obj(File.ReadAllText(Path.Combine(Board, "cards", "S1.json")));
        // 實際 Mac 卡片檔看到的鍵（doing／how／progress／summary／confidence／at／status／report／ask／options）＋task
        Assert.Equal(new[] { "ask", "at", "confidence", "doing", "how", "options", "progress", "report", "status", "summary", "task" },
                     j.Select(kv => kv.Key).OrderBy(k => k, StringComparer.Ordinal).ToArray());
        Assert.Matches(@"^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.056Z$", j["at"]!.GetValue<string>());
        Assert.Equal("review", j["status"]!.GetValue<string>());
        Assert.Equal(100, j["confidence"]!.GetValue<int>());
        Assert.Equal(new[] { "好，push", "先不要" }, j["options"]!.AsArray().Select(x => x!.GetValue<string>()));
        var back = BoardJson.Decode<SelfReport>(j.ToJsonString())!;           // 看板那邊的讀法
        Assert.True(back.Status == ReportStatus.Review && back.Progress == 80 && back.Ask == "要 push 嗎" && back.At == T0.AddMilliseconds(56));
        Assert.Equal($"ok（{NicknameStore.Get("S1")!.Name}-改按鈕顏色）\n", out_);
        var names = Obj(File.ReadAllText(Path.Combine(Board, "names", "S1.json")));
        Assert.Equal("改按鈕顏色", names["doing"]!.GetValue<string>());
        Assert.Contains(names["name"]!.GetValue<string>(), Nicknames.Pool);
    }

    [Fact] // 參數錯誤：訊息跟 Mac 一字不差；沒有 session id 就 exit 1
    public void CardErrors()
    {
        Assert.Equal("缺 --status", CardReport.Parse(new[] { "--progress", "5" }, T0).Error);
        Assert.Equal("--status 只能是 working／review／done／blocked", CardReport.Parse(new[] { "--status", "ok" }, T0).Error);
        Assert.Equal("--kind 只有 start（開工卡）／wrapup（收尾完）", CardReport.Parse(new[] { "--kind", "nope", "--status", "done" }, T0).Error);
        Assert.Equal("--kind wrapup 要帶 --handoff <交接文件絕對路徑>", CardReport.Parse(new[] { "--kind", "wrapup", "--handoff", "x.md" }, T0).Error);
        Assert.Equal("不認得的參數 --x", CardReport.Parse(new[] { "--status", "done", "--x", "1" }, T0).Error);
        Assert.Null(CardReport.Parse(new[] { "--status", "done", "--options", "A|B" }, T0).Ok!.Options);     // 沒 --ask 就不留選項
        Assert.Equal("一二三四五六七八九十一二三四五六七八九十一二三四⋯", Nicknames.CleanDoing("一二三四五六七八九十一二三四五六七八九十一二三四五\n六"));
        Assert.Equal(1, HookCli.Card(new List<string> { "--status", "done" }, null, T0).Code);
        Assert.False(Directory.Exists(Path.Combine(Board, "cards")));
    }

    [Fact] // 開工卡：沒寫 --status 當 working，進隊長收件匣（delivered=false，Mac 讀得回去的欄位都在）
    public void StartCardGoesToInbox()
    {
        var (code, _, _) = HookCli.Card(new List<string> { "--kind", "start", "--doing", "改按鈕", "--summary", "按鈕改藍", "--how", "改 View.cs",
                                                            "--touch", "專案A/View.cs", "--outward", "無" }, "S2", T0);
        Assert.Equal(0, code);
        var card = Obj(File.ReadAllText(Path.Combine(Board, "cards", "S2.json")));
        Assert.True(card["status"]!.GetValue<string>() == "working" && card["kind"]!.GetValue<string>() == "start" && card["touch"]!.GetValue<string>() == "專案A/View.cs");
        var f = Assert.Single(Directory.GetFiles(Path.Combine(Board, "captain-inbox")));
        var j = Obj(File.ReadAllText(f));
        Assert.Equal(new[] { "at", "delivered", "id", "kind", "kinds", "name", "sid", "text" }, j.Select(kv => kv.Key).OrderBy(k => k, StringComparer.Ordinal).ToArray());
        Assert.Matches("^S[A-Z2-9]{4}$", j["id"]!.GetValue<string>());
        Assert.True(j["kind"]!.GetValue<string>() == "start" && j["text"]!.GetValue<string>() == "改按鈕：按鈕改藍" && !j["delivered"]!.GetValue<bool>());
        Assert.Empty(j["kinds"]!.AsArray());
        Assert.Equal("S2", Assert.Single(CaptainInbox.Pending(T0.AddMinutes(1))).Sid);
    }

    // MARK: 動作預告規則（同 Mac 的 CaptainLinkTests.rules／hitSegment／falsePositives）

    static List<string> Names(string c) => CaptainLink.Match(c, CaptainLink.Rules(LocalConfig.Current)).Select(r => (r.Block ? "擋:" : "告:") + r.Name).ToList();

    [Fact]
    public void Rules()
    {
        Assert.Equal(new[] { "擋:rm 刪除（暫存區以外）" }, Names("rm -rf build/"));
        Assert.Empty(Names("rm -f /tmp/x.png"));
        Assert.Empty(Names("rm -rf /private/tmp/claude-501/s/scratchpad/a"));
        Assert.Equal(new[] { "擋:rm 刪除（暫存區以外）" }, Names("rm /tmp/a.txt src/main.swift"));
        Assert.Empty(Names("git rm --cached a.txt"));
        Assert.Equal(new[] { "告:mv 到非暫存區" }, Names("mv a.txt b.txt"));
        Assert.Empty(Names("mv a.txt /tmp/trash/"));
        Assert.Equal(new[] { "告:mv 到非暫存區" }, Names("mv \"$TMPDIR/x\" ~/Desktop/x"));
        Assert.Empty(Names("git mv old.swift new.swift"));
        Assert.Empty(Names("git commit -m \"改 rm 規則、mv 也擋\""));
        Assert.Empty(Names("python3 - <<'EOF'\nos.system('rm -rf x')\nEOF"));
        Assert.Equal(new[] { "擋:firebase 部署" }, Names("firebase deploy --only hosting"));
        Assert.Equal(new[] { "告:App 封裝（xcodebuild archive）" }, Names("xcodebuild -scheme App archive -archivePath /tmp/a"));
        Assert.Equal(new[] { "擋:App 上傳 App Store Connect" }, Names("xcrun altool --upload-app -f a.ipa"));
        foreach (var c in new[] { "xcodebuild -exportArchive -archivePath /tmp/A.xcarchive -exportOptionsPlist opts.plist -exportPath /tmp/out",
                                  "cd 專案A && xcodebuild -exportArchive -archivePath build/A.xcarchive -exportOptionsPlist ExportOptions.plist",
                                  "xcrun notarytool submit a.zip --wait", "/Applications/Transporter.app/Contents/itms/bin/iTMSTransporter -m upload -f a.itmsp",
                                  "bundle exec fastlane ios pilot upload", "fastlane deliver" })
            Assert.Equal(new[] { "擋:App 上傳 App Store Connect" }, Names(c));
        Assert.Empty(Names("xcodebuild -scheme 專案A build"));
        Assert.Equal(new[] { "擋:LINE 對外傳訊（line_send.py）" }, Names("python3 line_send.py 對方 '晚上見'"));
        Assert.Equal(new[] { "告:改系統設定（defaults write）" }, Names("defaults write com.acme.app key -bool true"));
        Assert.Equal(new[] { "告:寫入 ~/.claude/scripts 或 data" }, Names("cp a.py ~/.claude/scripts/a.py"));
        Assert.Empty(Names("cat ~/.claude/scripts/a.py"));
        Assert.Equal(new[] { "告:遠端 Windows 寫入（ssh winbox）" }, Names("ssh winbox 'Set-ItemProperty HKCU:\\X -Name Y -Value 1'"));
        Assert.Empty(Names("ssh winbox 'Get-ChildItem C:\\'"));
        Assert.Empty(Names("echo 'rm -rf /' | grep rm"));
        Assert.Empty(Names("python3 -c \"import os; os.system('defaults write x y')\""));
        Assert.Equal(new[] { "擋:rm 刪除（暫存區以外）" }, Names("cd 專案A && sudo rm -rf build"));
        Assert.Equal(new[] { "擋:rm 刪除（暫存區以外）" }, Names("ls $(rm -rf build)"));
        Assert.Empty(Names("T=$(mktemp -d); touch $T/a; rm -rf $T"));
        Assert.Empty(Names("S=/private/tmp/claude-501/x/scratchpad/legs && rm -f $S/*.png"));
        Assert.Empty(Names("D=\"$TMPDIR/demo\"; mv a.txt \"$D/\""));
        Assert.Equal(new[] { "擋:rm 刪除（暫存區以外）" }, Names("T=$(mktemp -d); rm -rf $T ~/專案A"));
        Assert.Empty(Names("rm -rf \"/tmp/WT\" 2>/dev/null"));
        Assert.Empty(Names("rm -rf '/private/tmp/WT' >/dev/null 2>&1"));
        Assert.Equal(new[] { "擋:rm 刪除（暫存區以外）" }, Names("rm -rf ~/專案A 2>/dev/null"));
        Assert.Equal(new[] { "告:mv 到非暫存區" }, Names("mv a.txt ~/專案A/ 2>/dev/null"));
        Assert.Equal(new[] { "擋:GitHub 公開發言（gh）" }, Names("gh pr create --title x --body y"));
        Assert.Equal(new[] { "擋:GitHub 公開發言（gh）" }, Names("gh api repos/acme/demo/issues -f title=x"));
        Assert.Empty(Names("gh pr view 3"));
    }

    [Fact] // showork 自己的指令不看（Windows 的 showork.exe 路徑也是）；串接時摘要只列命中的那段
    public void HitSegmentAndShowork()
    {
        Assert.Empty(Names("\"C:/Users/Demo User/AppData/Local/ShoWork42/bin/showork.exe\" card --kind start --how \"改 line_send.py 的 rm 判斷\""));
        Assert.Empty(Names("showork b1 post --text \"mv 前先備份\""));
        var cmd = "\"/Users/demo/Library/Application Support/ShoWork42/bin/showork\" card --kind start --doing \"傳訊\" --how \"line_send.py 傳給對方\" && python3 ~/demo/line_send.py 對方 '晚上見'";
        var hs = CaptainLink.Hits(cmd, CaptainLink.Rules(LocalConfig.Current));
        Assert.Equal(new[] { "LINE 對外傳訊（line_send.py）" }, hs.Select(h => h.Rule.Name));
        var sum = CaptainLink.HitSummary(cmd, hs);
        Assert.StartsWith("python3 ~/demo/line_send.py ‹訊息內容略›", sum);
        Assert.DoesNotContain("晚上見", sum);
        Assert.Equal("curl -H 'X: ‹長字串›' x", CaptainLink.Summary("curl -H 'X: abcdefghijklmnopqrstuvwxyz0123456789ABCD' x"));
        Assert.Equal(CaptainLink.Fingerprint("rm a "), CaptainLink.Fingerprint("rm a"));
        Assert.NotEqual(CaptainLink.Fingerprint("rm a"), CaptainLink.Fingerprint("rm b"));
        Assert.Equal("cbf29ce484222325", CaptainLink.Fingerprint(""));                       // FNV-1a 64 的起始值，同 Mac
        Assert.Equal(new[] { new CaptainLink.Rule("規則A", true, "\\bfoo\\b"), new CaptainLink.Rule("預告", false, "bar") },
                     CaptainLink.ParseRules("# 註解\n規則A\t擋\t\\bfoo\\b\n壞行\n預告\t告\tbar\r\n"));
    }

    [Fact] // preview.tsv 不在就寫預設（含版本字）；之後以檔案為準
    public void RulesFile()
    {
        var rules = CaptainLink.LoadRules();
        var f = Path.Combine(Board, "guard", "preview.tsv");
        var text = File.ReadAllText(f);
        Assert.Contains("格式 v6", text);
        Assert.Contains("Demo User", text);
        Assert.Equal(rules.Count, CaptainLink.ParseRules(text).Count);
        File.WriteAllText(f, "# 格式 v6\n只有我\t擋\t^foo\\b\n");
        Assert.Equal("只有我", Assert.Single(CaptainLink.LoadRules()).Name);
    }

    // MARK: 擋 → 放行 → 用一次

    [Fact] // 擋下 → 重試同一張單 → 使用者打「放行」→ 跑一次放行 → 再跑又擋（新單）
    public void BlockReleaseOnce()
    {
        var cmd = "rm -rf build";
        var id1 = DenyId(HookCli.GuardPush(Stdin("S3", cmd), T0, NoGit, NoView));
        Assert.Matches("^B[A-Z2-9]{4}$", id1);
        Assert.Equal(id1, DenyId(HookCli.GuardPush(Stdin("S3", "cd 專案A && " + cmd), T0.AddSeconds(5), NoGit, NoView)));   // 沒命中的段落不影響指紋
        Assert.Single(Directory.GetFiles(Path.Combine(Board, "captain-inbox")));
        // 別的 session 打放行：放不到這張
        HookCli.Title(Prompt("S9", "放行"), null, T0.AddSeconds(8), "/x/showork");
        Assert.NotNull(DenyId(HookCli.GuardPush(Stdin("S3", cmd), T0.AddSeconds(9), NoGit, NoView)));
        var t = Obj(HookCli.Title(Prompt("S3", "放行"), null, T0.AddSeconds(10), "/x/showork"));
        Assert.StartsWith($"使用者剛放行了單號 {id1}", t["hookSpecificOutput"]!["additionalContext"]!.GetValue<string>());
        Assert.Null(HookCli.GuardPush(Stdin("S3", cmd), T0.AddSeconds(20), NoGit, NoView));                // 放行一次
        var item = CaptainInbox.Item(id1!)!;
        Assert.True(item.Released == T0.AddSeconds(10) && item.Used == T0.AddSeconds(20));
        var id2 = DenyId(HookCli.GuardPush(Stdin("S3", cmd), T0.AddSeconds(30), NoGit, NoView));           // 再跑又擋
        Assert.NotEqual(id1, id2);
        var log = Assert.Single(CaptainInbox.Releases());
        Assert.True(log.Str("id") == id1 && log.Str("source") == "使用者輸入" && log.Str("target") == "S3" && log.Str("by") == "S3");
        // 放行 30 分鐘過期
        HookCli.Title(Prompt("S3", $"放行 {id2!.ToLowerInvariant()}"), null, T0.AddSeconds(40), "/x/showork");
        Assert.NotNull(DenyId(HookCli.GuardPush(Stdin("S3", cmd), T0.AddSeconds(40 + 1801), NoGit, NoView)));
        // 不擋的（mv）只進收件匣
        Assert.Null(HookCli.GuardPush(Stdin("S3", "mv a.txt b.txt"), T0, NoGit, NoView));
        Assert.Contains(CaptainInbox.All(), i => i.Kind == "notice" && i.Kinds.SequenceEqual(new[] { "mv 到非暫存區" }));
        // 隊長自己不擋；審核員不擋
        CaptainStore.SetCaptain("S3", null, T0);
        Assert.Null(HookCli.GuardPush(Stdin("S3", cmd), T0.AddSeconds(50), NoGit, NoView));
    }

    [Fact] // 隊長 showork release：只有隊長能放；放了紀錄 source＝release 指令；captain 印未處理的單並標已送
    public void CaptainRelease()
    {
        var id = DenyId(HookCli.GuardPush(Stdin("S4", "firebase deploy"), T0, NoGit, NoView))!;
        Assert.Equal(1, HookCli.Release(new List<string> { id }, "C1", T0).Code);                       // 還不是隊長
        var (code, out_, _) = HookCli.Captain(new List<string>(), "C1", T0.AddSeconds(1), "/x/showork");
        Assert.Equal(0, code);
        Assert.StartsWith("[AI工作戰情中心] 你現在是隊長。", out_);
        Assert.Contains($"{id} ", out_);
        Assert.Contains("【收件匣未處理 1 則】", out_);
        Assert.True(CaptainInbox.Item(id)!.Delivered);
        Assert.Equal(1, HookCli.Release(new List<string> { "BZZZZ" }, "C1", T0).Code);
        var r = HookCli.Release(new List<string> { id.ToLowerInvariant() }, "C1", T0.AddSeconds(2));
        Assert.Equal(0, r.Code);
        Assert.Contains("（30 分鐘內、限一次）", r.Out);
        Assert.Equal("release 指令", Assert.Single(CaptainInbox.Releases()).Str("source"));
        Assert.Null(HookCli.GuardPush(Stdin("S4", "firebase deploy"), T0.AddSeconds(3), NoGit, NoView));
        Assert.Equal((0, "沒有符合的未處理單\n", ""), HookCli.Captain(new List<string> { "ack", "all" }, "C1", T0.AddSeconds(4), "/x"));
    }

    [Fact] // 同 Mac 的 ④：consume 只認放行過、同指紋、30 分鐘內、一次；別人的單不能放；ack
    public void Inbox()
    {
        var fp = CaptainLink.Fingerprint("rm -rf build");
        InboxItem It(string id, string fp2) => new() { Id = id, Kind = "block", At = T0, Sid = "a", Name = "對方", Project = "專案A", Kinds = new() { "rm 刪除（暫存區以外）" }, Text = "rm -rf build", Fingerprint = fp2 };
        CaptainInbox.Save(It("BAAAA", fp));
        Assert.False(CaptainInbox.Consume("a", fp, T0.AddSeconds(10)));
        Assert.Equal("BAAAA", CaptainInbox.Waiting("a", fp)!.Id);
        Assert.Null(CaptainInbox.Release(null, "b", "b", "使用者", "使用者輸入", T0.AddSeconds(20)));
        Assert.NotNull(CaptainInbox.Release("baaaa", null, "cap", "隊長", "release 指令", T0.AddSeconds(20)));
        Assert.False(CaptainInbox.Consume("a", CaptainLink.Fingerprint("rm -rf src"), T0.AddSeconds(30)));
        Assert.True(CaptainInbox.Consume("a", fp, T0.AddSeconds(30)));
        Assert.False(CaptainInbox.Consume("a", fp, T0.AddSeconds(40)));
        CaptainInbox.Save(It("BCCCC", "x"));
        Assert.Equal(1, CaptainInbox.Ack("bcccc", T0.AddSeconds(70)));
        Assert.DoesNotContain(CaptainInbox.Pending(T0.AddSeconds(70)), i => i.Id == "BCCCC");
        Assert.Contains("隊長轉述Demo User的決定", CaptainLink.DenyReason(CaptainInbox.Item("BAAAA")!));
        Assert.Contains("showork release BAAAA", CaptainLink.BlockText(CaptainInbox.Item("BAAAA")!));
    }

    // MARK: 事先放行

    [Fact] // 點名的動作、否定小句不算、rm 不算（同 Mac 的 ④b）
    public void PreapprovalRules()
    {
        const string gh = "GitHub 公開發言（gh）", line = "LINE 對外傳訊（line_send.py）", rm = "rm 刪除（暫存區以外）";
        Assert.True(CaptainInbox.Authorizes("開 PR，用 LINE 通知對方", gh));
        Assert.True(CaptainInbox.Authorizes("開 PR，用 LINE 通知對方", line));
        Assert.True(CaptainInbox.Authorizes("先開 PR，不通知", gh));
        Assert.False(CaptainInbox.Authorizes("先開 PR，不通知", line));
        Assert.False(CaptainInbox.Authorizes("先不要開 PR", gh));
        Assert.False(CaptainInbox.Authorizes("都先不要", gh));
        Assert.False(CaptainInbox.Authorizes("好，現在做", gh));
        Assert.False(CaptainInbox.Authorizes("刪掉吧", rm));
        Assert.True(CaptainInbox.Authorizes("好，上傳 TestFlight", "App 上傳 App Store Connect"));
        Assert.Null(CaptainInbox.UsePreapproval("a", new() { gh }, T0));
        CaptainInbox.RecordAnswer("a", "開 PR，用 LINE 通知對方", "要開 PR 嗎？", T0);
        Assert.Null(CaptainInbox.UsePreapproval("b", new() { gh }, T0.AddSeconds(10)));
        Assert.Null(CaptainInbox.UsePreapproval("a", new() { gh, rm }, T0.AddSeconds(10)));
        Assert.StartsWith("開 PR", CaptainInbox.UsePreapproval("a", new() { gh }, T0.AddSeconds(10))!.Answer);
        Assert.Null(CaptainInbox.UsePreapproval("a", new() { gh }, T0.AddSeconds(20)));            // 每種一次
        Assert.Null(CaptainInbox.UsePreapproval("a", new() { line }, T0.AddSeconds(1801)));        // 30 分鐘過期
        var j = Obj("{\"x\":" + File.ReadAllText(Path.Combine(Board, "permits", "preapprovals.json")) + "}")["x"]!.AsArray().Single()!;
        Assert.Equal(new[] { "answer", "at", "question", "sid", "used" }, j.AsObject().Select(kv => kv.Key).OrderBy(k => k, StringComparer.Ordinal).ToArray());
    }

    [Fact] // guard-push 走事先放行：點名的照常跑、記成已放行＋已用、稽核紀錄 source＝戰情中心回答；同一種第二次照擋；rm 照擋
    public void PreapprovalThroughGuard()
    {
        CaptainInbox.RecordAnswer("S5", "好，用 LINE 通知對方", "要通知嗎？", T0);
        var line = "python3 ~/demo/line_send.py 對方 '晚上見'";
        Assert.Null(HookCli.GuardPush(Stdin("S5", line), T0.AddSeconds(5), NoGit, NoView));
        var i = Assert.Single(CaptainInbox.All());
        Assert.True(i.Released == T0.AddSeconds(5) && i.Used == T0.AddSeconds(5) && !i.Delivered);       // 沒有隊長：留在收件匣
        Assert.Equal("戰情中心回答", Assert.Single(CaptainInbox.Releases()).Str("source"));
        Assert.NotNull(DenyId(HookCli.GuardPush(Stdin("S5", line), T0.AddSeconds(6), NoGit, NoView)));
        CaptainInbox.RecordAnswer("S5", "刪掉吧，部署也可以", null, T0.AddSeconds(7));
        Assert.NotNull(DenyId(HookCli.GuardPush(Stdin("S5", "rm -rf build"), T0.AddSeconds(8), NoGit, NoView)));
        Assert.Null(HookCli.GuardPush(Stdin("S5", "firebase deploy"), T0.AddSeconds(9), NoGit, NoView));
        Assert.NotNull(DenyId(HookCli.GuardPush(Stdin("S5", line), T0.AddSeconds(31 * 60), NoGit, NoView)));
    }

    [Fact] // gh 細判：Okle42 私有 repo 免擋；公開、別人的、查不到的照擋並附原因
    public void GhExemption()
    {
        (string, bool)? View(string r) => r == "okle42/private-demo" ? ("Okle42", true) : r == "okle42/public-demo" ? ("Okle42", false) : null;
        Assert.Equal("不擋\tgh pr create -R okle42/private-demo --title x\n", HookCli.PreviewCheck(new[] { "gh pr create -R okle42/private-demo --title x" }, "/x", NoGit, View));
        var o = HookCli.PreviewCheck(new[] { "gh issue comment 3 -R okle42/public-demo -b hi", "gh pr create --repo acme/demo", "gh pr create" }, "/x", NoGit, View).Split('\n');
        Assert.Equal("擋：GitHub 公開發言（gh）\tgh issue comment 3 -R okle42/public-demo -b hi（okle42/public-demo 不是 Okle42 的私有 repo）", o[0]);
        Assert.EndsWith("（acme/demo 不是 Okle42 的私有 repo）", o[1]);
        Assert.EndsWith("（/x 不是有 remote 的 git 資料夾）", o[2]);
    }

    // MARK: title（開工卡提醒）

    [Fact]
    public void KickoffNag()
    {
        string? Ctx(string json) => json.Length == 0 ? null : Obj(json)["hookSpecificOutput"]?["additionalContext"]?.GetValue<string>();
        var first = Ctx(HookCli.Title(Prompt("S6", "幫我把專案A的按鈕改成藍色"), null, T0, "C:/Demo/showork.exe"))!;
        Assert.StartsWith("【開工卡】這是使用者直接下的指令。", first);
        Assert.Contains("\"C:/Demo/showork.exe\" card --kind start", first);
        HookCli.Card(new List<string> { "--status", "working", "--doing", "改按鈕" }, "S6", T0);
        var again = HookCli.Title(Prompt("S6", "再調亮一點"), null, T0.AddMinutes(5), "/x/showork");
        Assert.StartsWith("【開工卡】你手上的任務是「改按鈕」。", Ctx(again));
        Assert.Equal(NicknameStore.Get("S6")!.Name, Obj(again)["hookSpecificOutput"]!["sessionTitle"]!.GetValue<string>());
        Assert.DoesNotContain("terminalSequence", again);
        Assert.StartsWith("【開工卡】這是使用者", Ctx(HookCli.Title(Prompt("S6", "換別的事"), null, T0.AddMinutes(16), "/x/showork")));
        Assert.Null(Ctx(HookCli.Title(Prompt("S6", "<cross-session-message from=\"uds:/tmp/x.sock\">【派工回報】</cross-session-message>"), null, T0.AddMinutes(40), "/x")));
        Assert.Null(Ctx(HookCli.Title(Prompt("S7", "做事", cwd: @"C:\Users\Demo User\ProjectC\src"), null, T0, "/x")));   // noKickoffRepos
        Assert.Equal("", HookCli.Title(Prompt("S8", "<task-notification>完成</task-notification>"), null, T0, "/x"));         // 還沒取名、沒提醒：不輸出
        CaptainStore.SetCaptain("S6", null, T0);
        Assert.Null(Ctx(HookCli.Title(Prompt("S6", "幫我看一下"), null, T0.AddHours(2), "/x")));                                // 隊長不用發
        Assert.Contains("[ShoWork42 AI工作戰情中心]", HookCli.Brief("{\"session_id\":\"S6\"}", null, "/x/showork"));
        Assert.Contains($"你在戰情中心的名字是 {NicknameStore.Get("S6")!.Name}", HookCli.Brief("{\"session_id\":\"S6\"}", null, "/x/showork"));
    }

    // MARK: 1 樓保全（PushGuard）

    static (int, string) RealGit(string dir, string[] a) => HookCli.RunGit(dir, a);
    void Sh(string dir, params string[] a) { var r = HookCli.RunExe(HookCli.FindExe("git"), new[] { "-C", dir }.Concat(a)); Assert.True(r.Code == 0, string.Join(" ", a)); }

    [Fact] // 關鍵字命中：一般 repo 提醒、strict-repos 擋；金鑰長相擋；force push main 擋；cd 與 -C 算對資料夾
    public void PushGuardKeywords()
    {
        var remote = Path.Combine(root, "remotes", "demo-repo.git");
        var work = Path.Combine(root, "work");
        Directory.CreateDirectory(remote); Directory.CreateDirectory(work);
        Sh(remote, "init", "-q", "--bare");
        Sh(work, "init", "-q", "-b", "main");
        Sh(work, "config", "user.email", "demo@example.invalid"); Sh(work, "config", "user.name", "Demo User");
        Sh(work, "remote", "add", "origin", remote);
        File.WriteAllText(Path.Combine(work, "a.txt"), "hello\n");
        Sh(work, "add", "."); Sh(work, "commit", "-q", "-m", "one"); Sh(work, "push", "-q", "origin", "main");
        File.WriteAllText(Path.Combine(work, "b.txt"), "給 DemoClientX 的報價\n");
        Sh(work, "add", "."); Sh(work, "commit", "-q", "-m", "two");

        var calls = PushGuard.Calls($"cd {root} && git -C work push origin main 2>&1 | tail -1", "/");
        var c = Assert.Single(calls);
        Assert.Equal(Path.GetFullPath(work), c.Dir);
        Assert.Equal(new[] { "origin", "main" }, c.Args);
        Assert.Empty(PushGuard.Calls("git log --oneline", work));

        var kw = new List<string> { "democlientx" };
        var e = PushGuard.Check(c, RealGit, kw, new(), T0);
        Assert.Equal("warn", e.Verdict);
        Assert.Equal(1, e.Commits);
        Assert.Equal("remotes/demo-repo", e.Repo);
        Assert.Contains("b.txt：「democlientx」", e.Reasons.Single());
        Assert.Contains("additionalContext", PushGuard.HookOutput(new() { e })!);
        var s = PushGuard.Check(c, RealGit, kw, new() { "demo-repo" }, T0);
        Assert.Equal("block", s.Verdict);
        Assert.Contains("deny", PushGuard.HookOutput(new() { s })!);
        Assert.Equal("block", PushGuard.Check(new PushCall(work, new() { "--force", "origin", "main" }), RealGit, new(), new(), T0).Verdict);
        Assert.Equal("block", PushGuard.Check(new PushCall(Path.Combine(root, "nope"), new()), RealGit, new(), new(), T0).Verdict);
        File.WriteAllText(Path.Combine(work, "c.txt"), "key = " + "AKIA" + "ABCDEFGHIJKLMNOP\n");
        Sh(work, "add", "."); Sh(work, "commit", "-q", "-m", "three");
        var k = PushGuard.Check(c, RealGit, new(), new(), T0);
        Assert.True(k.Verdict == "block" && k.Secret && k.Reasons.Single().Contains("c.txt：AWS 金鑰"));

        // 整條 hook：keywords.txt／strict-repos.txt 從 board\guard 讀；紀錄寫 pushes.jsonl（Mac 的欄位）
        Directory.CreateDirectory(Path.Combine(Board, "guard"));
        File.WriteAllText(Path.Combine(Board, "guard", "keywords.txt"), "# 註解\nDemoClientX\n");
        var outp = HookCli.GuardPush(Stdin("S10", "git push origin main", work), T0, RealGit, NoView)!;
        Assert.Contains("AWS 金鑰", Obj(outp)["hookSpecificOutput"]!["permissionDecisionReason"]!.GetValue<string>());
        var log = Obj(File.ReadAllLines(Path.Combine(Board, "guard", "pushes.jsonl")).Single());
        Assert.Equal(new[] { "at", "commits", "dir", "head", "reasons", "refs", "repo", "secret", "session", "verdict" },
                     log.Select(kv => kv.Key).OrderBy(x => x, StringComparer.Ordinal).ToArray());
        // 保全面板「放行一次」（allow.json，同 HEAD）⇒ 放行、用掉
        PushGuard.SaveAllows(new() { new PushGuard.Allow(work, log.Str("head")!, T0.AddMinutes(30)) });
        Assert.Null(HookCli.GuardPush(Stdin("S10", "git push origin main", work), T0.AddMinutes(1), RealGit, NoView));
        Assert.Empty(PushGuard.Allows());
    }

    // MARK: 寄給隊長（Peer）

    [Fact] // 訊息格式同 Mac；Unix socket 真的送得到；連不上時單子留 delivered=false
    public void PeerSend()
    {
        var lines = Peer.Lines("tok", "內容", "AI工作戰情中心（動作預告）", null, "id1");
        Assert.Equal("""{"token":"tok","type":"auth"}""", lines[0]);
        var m = Obj(lines[1]);
        Assert.Equal(new[] { "from", "message", "msgV", "msg_id", "priority", "type" }, m.Select(kv => kv.Key).ToArray());
        Assert.Equal("<cross-session-message from=\"uds:\" from-name=\"AI工作戰情中心（動作預告）\">\n內容\n</cross-session-message>", m["message"]!["content"]!.GetValue<string>());
        Assert.Equal("cap", Peer.PipeName(@"\\.\pipe\cap"));
        Assert.Equal("cap", Peer.PipeName("//./pipe/cap"));
        Assert.Null(Peer.PipeName("/tmp/cc-socks/1.sock"));

        // 隊長的 session（行程＝這個測試自己，算活著）；收件 socket 還沒開 ⇒ 擋下的單 delivered=false
        var pid = Environment.ProcessId;
        var sock = Path.Combine(Path.GetTempPath(), $"sw{pid % 100000}.sock");
        File.Delete(sock);
        File.WriteAllText(Path.Combine(root, "claude", "sessions", $"{pid}.json"),
            new JsonObject { ["pid"] = pid, ["sessionId"] = "CAP", ["cwd"] = "/x", ["name"] = "Demo", ["messagingSocketPath"] = sock }.ToJsonString());
        File.WriteAllText(Path.Combine(root, "claude", "sessions", $"{pid}.abc.key"), """{"peerToken":"secret-demo"}""");
        CaptainStore.SetCaptain("CAP", "Demo", T0);
        var id = DenyId(HookCli.GuardPush(Stdin("S11", "firebase deploy"), T0, NoGit, NoView))!;
        Assert.False(CaptainInbox.Item(id)!.Delivered);

        using var listener = new Socket(AddressFamily.Unix, SocketType.Stream, ProtocolType.Unspecified);
        listener.Bind(new UnixDomainSocketEndPoint(sock));
        listener.Listen(1);
        var got = Task.Run(() =>
        {
            using var c = listener.Accept();
            var buf = new byte[1 << 16]; var ms = new MemoryStream(); int n;
            while ((n = c.Receive(buf)) > 0) ms.Write(buf, 0, n);
            return Encoding.UTF8.GetString(ms.ToArray());
        });
        var id2 = DenyId(HookCli.GuardPush(Stdin("S11", "firebase deploy --only hosting"), T0.AddSeconds(1), NoGit, NoView))!;
        Assert.True(got.Wait(5000));
        var sent = got.Result.Split('\n', StringSplitOptions.RemoveEmptyEntries);
        Assert.Equal("""{"token":"secret-demo","type":"auth"}""", sent[0]);
        Assert.StartsWith($"<cross-session-message from=\"uds:\" from-name=\"AI工作戰情中心（動作預告）\">\n【動作預告・擋下 {id2}】", Obj(sent[1])["message"]!["content"]!.GetValue<string>());
        Assert.True(CaptainInbox.Item(id2)!.Delivered);
        File.Delete(sock);
        Assert.Equal("Demo", Assert.Single(PeerSession.Live()).Name);
        Assert.Contains("Demo", HookCli.Names());
    }
}

/// 安裝器合併 hooks（ShoWork.Win\InstallerHooks.cs）：W5 加的 brief／title／guard-push 也裝、也能乾淨移除；舊版裝過的升級時只換掉我們的
public sealed class InstallerHookTests : IDisposable
{
    readonly string root = Path.Combine(Path.GetTempPath(), "sw-inst-" + Guid.NewGuid().ToString("N")[..8]);
    string Settings => Path.Combine(root, "claude", "settings.json");
    const string Exe = @"C:\Users\Demo User\AppData\Local\ShoWork42\bin\showork.exe";
    const string Original = "{\n  \"model\": \"demo\",\n  \"hooks\": {\n    \"PreToolUse\": [\n      {\n        \"matcher\": \"Bash\",\n        \"hooks\": [ { \"type\": \"command\", \"command\": \"other-tool check\" } ]\n      }\n    ]\n  }\n}\n";

    public InstallerHookTests()
    {
        Directory.CreateDirectory(Path.Combine(root, "claude"));
        Environment.SetEnvironmentVariable("SHOWORK_HOME", Path.Combine(root, "home"));
        File.WriteAllText(Settings, Original);
    }
    public void Dispose() { Environment.SetEnvironmentVariable("SHOWORK_HOME", null); try { Directory.Delete(root, true); } catch { } }

    JsonObject Hooks() => (JsonObject)JsonNode.Parse(File.ReadAllText(Settings))!["hooks"]!;
    static string Cmd(JsonNode? g) => g!["hooks"]![0]!["command"]!.GetValue<string>();

    [Fact]
    public void InstallUpgradeUninstall()
    {
        Assert.Equal("merged", Installer.InstallHooks(Settings, Exe));
        Assert.Equal(11, Installer.CountOurs(Settings));
        var pre = Hooks()["PreToolUse"]!.AsArray();
        Assert.Equal("other-tool check", Cmd(pre[0]));                                       // 別人的留在原位
        Assert.Equal("\"C:/Users/Demo User/AppData/Local/ShoWork42/bin/showork.exe\" guard-push", Cmd(pre[^1]));
        Assert.Equal("Bash", pre[^1]!["matcher"]!.GetValue<string>());
        Assert.Equal(60, pre[^1]!["hooks"]![0]!["timeout"]!.GetValue<int>());
        Assert.EndsWith("\" title", Cmd(Hooks()["UserPromptSubmit"]!.AsArray()[^1]));
        Assert.Null(Hooks()["UserPromptSubmit"]!.AsArray()[^1]!["hooks"]![0]!["async"]);  // 要等它的輸出
        Assert.EndsWith("\" brief", Cmd(Hooks()["SessionStart"]!.AsArray().Single()));
        Assert.Equal("already installed", Installer.InstallHooks(Settings, Exe));

        // 舊版（W4）只裝了 emit：拿掉 W5 的三組，再裝一次 ⇒ 補上、別人的不動
        var root0 = JsonNode.Parse(File.ReadAllText(Settings))!.AsObject();
        var h = root0["hooks"]!.AsObject();
        h.Remove("SessionStart");
        foreach (var ev in new[] { "PreToolUse", "UserPromptSubmit" })
        {
            var keep = h[ev]!.AsArray().Where(g => !Cmd(g).EndsWith(" guard-push") && !Cmd(g).EndsWith(" title")).Select(g => g!.DeepClone()).ToArray();
            h[ev] = new JsonArray(keep);
        }
        File.WriteAllText(Settings, root0.ToJsonString(new JsonSerializerOptions { WriteIndented = true }) + "\n");
        Assert.Equal(8, Installer.CountOurs(Settings));
        Assert.Equal("merged", Installer.InstallHooks(Settings, Exe));
        Assert.Equal(11, Installer.CountOurs(Settings));
        Assert.Equal("other-tool check", Cmd(Hooks()["PreToolUse"]!.AsArray()[0]));

        // 移除：回到原本的位元組
        Assert.Equal("removed", Installer.UninstallHooks(Settings));
        Assert.Equal(Original, File.ReadAllText(Settings));
        Assert.Equal(0, Installer.CountOurs(Settings));
    }
}
