using System.Text.Json.Nodes;

namespace ShoWork.Hooks;

// Agent交流互動板（Mac 版 Sources/ShoWorkCore/B1Talk.swift 的移植，board\b1-board.jsonl 格式相同）。
// 10-27 Kang（T1027193007）改成「收尾時順便留、不叫醒人」：
//   • 只在收尾那一輪（Stop hook 的收尾提示，用 `showork b1 hint` 取這段；Windows 的 `showork ctx-wrapup` 直接接上）順便留，不多開一輪
//   • 頂多一則、可以零則；只留「需要修正」的事，附證據；每則留言同時轉給現任隊長（【交流板】）

static class B1Talk
{
    public const int MaxChars = 150;
    /// 硬上限（超過就截斷；建議字數是 MaxChars）
    public const int HardChars = 300;
    /// 收尾提示裡直接附上板上最近幾則
    public const int RecentN = 5;
    /// 附上的每則截到幾個字
    public const int RecentChars = 60;

    /// 收尾提示裡加的那段（接在發收尾卡之前，收尾卡順延成 ⑤）
    public static string WrapupNote(string showork, List<B1Post> recent)
    {
        var t = "④交流板檢討（頂多一則、可以零則）：這段工作有失敗、被使用者／隊長糾正、或重工繞遠路才留，一切順利就不留；"
            + $"要留就 `\"{showork}\" b1 post --text \"<{MaxChars} 字以內>\"`（**硬上限 {MaxChars} 字，寫好先數字數再送**）：哪裡錯或繞遠路、根因、建議改成什麼規則或做法，附證據（檔名、log、SHA）；"
            + "通用好用技巧不留；不寫帳號、金鑰、客戶名、真實人名";
        var last = recent.Skip(Math.Max(0, recent.Count - RecentN)).ToList();
        if (last.Count == 0) return t + "。";
        t += $"。板上最近 {last.Count} 則（同一個坑已經有人寫過：沒有新證據就不留；有新證據——不同 SHA、不同根因——才加 `--re <編號>` 回覆，只寫新的部分）：";
        t += string.Join("｜", last.Select(p =>
        {
            var x = SwiftText.Count(p.Text) > RecentChars ? SwiftText.Prefix(p.Text, RecentChars) + "…" : p.Text;
            return $"#{p.Id} {p.Name}" + (p.Re is { } r ? $"↪#{r}" : "") + $"：{x}";
        }));
        return t;
    }
}

/// 一則留言（只增不改）
sealed class B1Post
{
    public int Id;
    public DateTime At;
    public string Sid = "";
    public string Name = "";
    public string Project = "";
    public string Text = "";
    public int? Re;

    public JsonObject ToJson()
    {
        var o = new JsonObject { ["id"] = Id, ["at"] = HookJson.Iso(At), ["sid"] = Sid, ["name"] = Name, ["project"] = Project, ["text"] = Text };
        o.Put("re", Re);
        return o;
    }

    public static B1Post? From(JsonNode? o) =>
        o.Int("id") is { } id && o.Date("at") is { } at && o.Str("sid") is { } sid && o.Str("name") is { } n && o.Str("project") is { } p && o.Str("text") is { } t
            ? new B1Post { Id = id, At = at, Sid = sid, Name = n, Project = p, Text = t, Re = o.Int("re") } : null;

    /// 一行顯示：#12 10-24 03:10 Ruby（ShoWork42）↪#9：內容
    public string Line() =>
        $"#{Id} {At.ToLocalTime():MM-dd HH:mm} {Name}" + (Project.Length == 0 ? "" : $"（{Project}）") + (Re is { } r ? $" ↪#{r}" : "") + $"：{Text}";

    /// 轉給隊長的那則
    public string CaptainText =>
        $"【交流板 #{Id}】{Name}" + (Project.Length == 0 ? "" : $"（{Project}）") + (Re is { } r ? $" 回應 #{r}" : "") + $"：{Text}\n"
        + "（工作心得，請收進流程優化的參考；不用回。全部留言：showork b1 read）";
}

static class B1Board
{
    public static string FilePath => HookPaths.Env("SHOWORK_B1_BOARD") ?? Path.Combine(HookPaths.Board, "b1-board.jsonl");

    public static List<B1Post> All() =>
        (HookJson.ReadText(FilePath) ?? "").Split('\n', StringSplitOptions.RemoveEmptyEntries).Select(l => B1Post.From(HookJson.Parse(l))).OfType<B1Post>().ToList();

    /// 整理文字：去頭尾空白、換行改空白、超過硬上限截斷
    public static string Clean(string s)
    {
        var t = SwiftText.TrimSpaces(s.Replace("\r", " ").Replace("\n", " "));
        return SwiftText.Count(t) > B1Talk.HardChars ? SwiftText.Prefix(t, B1Talk.HardChars) + "…" : t;
    }

    /// 加一則（編號＝目前最大 +1）；空字串不收
    public static B1Post? Post(string sid, string name, string project, string text, int? re, DateTime now)
    {
        var t = Clean(text);
        if (t.Length == 0) return null;
        var all = All();
        var p = new B1Post { Id = (all.Count == 0 ? 0 : all.Max(x => x.Id)) + 1, At = now, Sid = sid, Name = name, Project = project, Text = t, Re = re };
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(FilePath)!);
            File.AppendAllText(FilePath, HookJson.Text(p.ToJson()) + "\n", new System.Text.UTF8Encoding(false));
        }
        catch { return null; }
        return p;
    }
}
