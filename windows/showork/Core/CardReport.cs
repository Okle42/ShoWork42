using System.Globalization;
using System.Text.Json.Nodes;

namespace ShoWork.Hooks;

// `showork card` 的自報（Mac 版 Sources/ShoWorkCore/Card.swift 的 SelfReport＋CardRules.brief）。
// 存在 board\cards\<sessionId>.json，欄位名跟 Mac 一樣（看板 ShoWork.Win\Board\Card.cs 讀的就是這份）。
// 名字跟看板那邊的 SelfReport 錯開（CardReport），兩邊的原始檔會一起編進測試。

sealed class CardReport
{
    public static readonly string[] Statuses = { "working", "review", "done", "blocked" };

    public string Status = "working";
    public int? Progress;            // 0–100
    public int? Confidence;          // 0–100
    public string? Summary;
    public string? Ask;              // 要使用者決定／回答的事
    public string? Report;           // 報告檔路徑
    public string? Task;             // 隊長派工單號（--task）
    public string? Doing;            // 正在做的任務（--doing，卡片標題「英文名-任務」）
    public List<string>? Options;    // --ask 的快速選項（--options "A|B|C"）
    public string? How;              // 這一輪用的方法與工具
    public string? Kind;             // start（開工卡）／wrapup（收尾完）
    public string? Handoff;          // --handoff 交接文件絕對路徑（wrapup 必帶）
    public string? Touch;            // 會動到哪些檔／repo／系統設定
    public string? Outward;          // 要不要 push、部署、對外傳訊息
    public DateTime At;
    public bool IsStart => Kind == "start";
    public bool IsWrapup => Kind == "wrapup";

    public static int Clamp(int v) => Math.Clamp(v, 0, 100);

    /// 選項：去空白、去重複、最多 4 個、每個最多 40 字；全空就 null
    public static List<string>? CleanOptions(IEnumerable<string> xs)
    {
        var out_ = new List<string>();
        foreach (var x in xs.Select(x => x.Trim()))
            if (x.Length > 0 && !out_.Contains(x) && out_.Count < 4) out_.Add(SwiftText.Prefix(x, 40));
        return out_.Count == 0 ? null : out_;
    }

    static bool Num(string v, out int n) =>
        int.TryParse(v.Trim('%', ' '), NumberStyles.AllowLeadingSign, CultureInfo.InvariantCulture, out n);

    /// `showork card` 的參數 → 回報；格式錯回傳錯誤訊息（給 AI 看得懂的中文，跟 Mac 一字不差）
    public static (CardReport? Ok, string? Error) Parse(IReadOnlyList<string> args, DateTime now)
    {
        var r = new CardReport { At = now };
        string? status = null;
        List<string>? opts = null;
        static string? Text(string v) { var t = v.Trim(); return t.Length == 0 ? null : t; }
        for (int i = 0; i < args.Count; i += 2)
        {
            var k = args[i];
            if (i + 1 >= args.Count) return (null, $"{k} 後面少了值");
            var v = args[i + 1];
            switch (k)
            {
                case "--status":
                    if (!Statuses.Contains(v)) return (null, "--status 只能是 working／review／done／blocked");
                    status = v; break;
                case "--progress":
                    if (!Num(v, out var p)) return (null, "--progress 要是 0–100 的數字");
                    r.Progress = Clamp(p); break;
                case "--confidence":
                    if (!Num(v, out var c)) return (null, "--confidence 要是 0–100 的數字");
                    r.Confidence = Clamp(c); break;
                case "--summary": r.Summary = v; break;
                case "--ask": r.Ask = v.Length == 0 ? null : v; break;
                case "--report": r.Report = v.Length == 0 ? null : v; break;
                case "--task": r.Task = v.Length == 0 ? null : v; break;
                case "--doing": r.Doing = Nicknames.CleanDoing(v); break;
                case "--options": opts = v.Split('|', StringSplitOptions.RemoveEmptyEntries).ToList(); break;
                case "--how": r.How = Text(v); break;
                case "--kind":
                    if (v is not ("start" or "wrapup")) return (null, "--kind 只有 start（開工卡）／wrapup（收尾完）");
                    r.Kind = v; break;
                case "--handoff": r.Handoff = Text(v); break;
                case "--touch": r.Touch = Text(v); break;
                case "--outward": r.Outward = Text(v); break;
                default: return (null, $"不認得的參數 {k}");
            }
        }
        // 開工卡沒寫 --status 就當 working；收尾卡當 done，而且一定要給交接文件的絕對路徑
        if (r.Kind == "wrapup")
        {
            // Mac 看開頭是不是「/」；Windows 的絕對路徑是 C:\… 或 C:/…（Git Bash 的 /c/… 也收）
            if (r.Handoff is not { } h || !(h.StartsWith('/') || Path.IsPathFullyQualified(h))) return (null, "--kind wrapup 要帶 --handoff <交接文件絕對路徑>");
            if (!File.Exists(h)) return (null, $"找不到交接文件：{h}");
        }
        status ??= r.Kind == "start" ? "working" : r.Kind == "wrapup" ? "done" : null;
        if (status == null) return (null, "缺 --status");
        r.Status = status;
        r.Options = r.Ask == null || opts == null ? null : CleanOptions(opts);
        return (r, null);
    }

    /// 存檔格式：Swift JSONEncoder 的 SelfReport（nil 的欄位不寫）
    public JsonObject ToJson()
    {
        var o = new JsonObject { ["status"] = Status };
        o.Put("progress", Progress); o.Put("confidence", Confidence); o.Put("summary", Summary); o.Put("ask", Ask);
        o.Put("report", Report); o.Put("task", Task); o.Put("doing", Doing);
        if (Options != null) o["options"] = HookJson.Arr(Options);
        o.Put("how", How); o.Put("kind", Kind); o.Put("handoff", Handoff); o.Put("touch", Touch); o.Put("outward", Outward);
        o["at"] = HookJson.Iso(At);
        return o;
    }

    public static string CardPath(string sid) => Path.Combine(HookPaths.Board, "cards", sid + ".json");
}

static class Brief
{
    /// 注入每個新 session 的說明（SessionStart hook 的輸出會進 AI 的 context）。內容同 Mac 的 CardRules.brief
    public static string Text(string showork, string? name)
    {
        var who = name != null ? $"你在戰情中心的名字是 {name}，卡片標題會顯示「{name}-正在做的任務」。" : "第一次自報後會分到一個英文名，卡片標題顯示「英文名-正在做的任務」。";
        return $"""
            [ShoWork42 AI工作戰情中心] 每一輪做完事、回覆使用者之前，用 Bash 跑一次（不用跟使用者提）：
            "{showork}" card --doing "<正在做的任務，10 個字內>" --status <working|review|done|blocked> --progress <0-100> --confidence <0-100> --summary "<一句話：做了什麼、結果>" [--ask "<需要使用者決定或回答的事>" --options "<選項1>|<選項2>"] [--how "<這一輪用的方法與工具，一句話>"] [--report "<報告檔絕對路徑>"]
            {who}--doing 每次都要帶、寫「現在」手上這件事（換任務就換），使用者靠它做戰情管控。
            status：review＝需要使用者看過或決定；done＝完成、不需要看；blocked＝卡住做不下去，等外部的事（等回信、等背景工作）也用 blocked，終端機會亮橘；working＝還沒做完、會繼續。confidence 是你對「做對了」的把握，要誠實，沒驗證過就不要給高分。有 --ask 時附 2–4 個 --options（| 分隔、每個是完整的一句回答，例如 "好，push|先不要"），使用者會在戰情中心按一下就把那句話送給你。--how 寫這一輪用了什麼方法和工具（例如「讀 3 個檔＋改 Inbox.swift＋swift test」），戰情中心會把卡片轉給隊長審。只是聊天、沒動手做事的回合可省略。
            跟使用者提到其他 AI session 時，一律用英文名（不要說 {Environment.UserName}-xx 或 session id）；對照表："{showork}" names。
            """;
    }
}
