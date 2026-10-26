namespace ShoWork;

// 部門島（Mac 10-12 決策板：像素豆 Kubo、全部陶土橘、光圈＋泡泡＋動作、皇冠／耳機／眼鏡）。Mac 版 Islands.swift 的移植。
// 看板的另一種看法：一個專案一座島，島上一個 session 一個角色。這裡只有分組與狀態對應，畫面另外做。

/// 角色的樣子，跟看板欄位一對一，只是換成角色看得懂的話
public enum Mood
{
    Working,    // 進行中：紫光圈、打字
    Waiting,    // 等你回答／AI 要你決定：紅「!」、跳
    Finished,   // 做完了你還沒看：綠勾、搖擺
    Stuck,      // 卡住：橘「?」
    Idle,       // 做完你也看過了：休息，睜眼、拿一杯冒熱氣的咖啡
    Asleep,     // 開了 claude 但從來沒交代過事：睡覺，閉眼、頭上 Zzz（Mac 10-15 Kang）
}

public enum Accessory { Crown, Headset, Glasses }

public static class Moods
{
    public static Mood Of(BoardCard c) => c.Column switch
    {
        BoardColumn.Active => Mood.Working,
        BoardColumn.Review => c.Reason == "等你回答" || c.Reason.StartsWith("要你決定", StringComparison.Ordinal) ? Mood.Waiting : Mood.Finished,
        BoardColumn.Stuck => Mood.Stuck,
        _ => c.Unused ? Mood.Asleep : Mood.Idle,
    };
}

public sealed record Islander(BoardCard Card, Mood Mood, Accessory? Accessory)
{
    public string Id => Card.Id;
}

public sealed class Island
{
    public string Project = "";
    public List<Islander> People = new();
    public int Queued;                              // 排隊中的訊息（看板上的待辦卡）
    public List<Islander> Ghosts = new();           // 別座島的人 cd 過來逛一下（影分身，本尊留在自己島上）

    public int Count(Mood m) => People.Count(p => p.Mood == m);
    /// 要你處理的：等你回答＋做完沒看＋卡住
    public int NeedsYou => People.Count(p => p.Mood is Mood.Waiting or Mood.Finished or Mood.Stuck);
}

public static class Islands
{
    /// 回訊息類（戴耳機）：預設是秘書、電話窗口
    public static readonly string[] DefaultHeadsetProjects = { "ProjectC", "ProjectE" };
    /// 研究／審核類（戴眼鏡）：看標題
    static readonly string[] GlassesWords = { "研究", "審核", "審查", "盤點", "review", "research", "audit" };

    public static Accessory? AccessoryOf(BoardCard c, IEnumerable<string> headsetProjects)
    {
        if (c.Captain) return Accessory.Crown;
        if (headsetProjects.Any(p => string.Equals(p, c.Project, StringComparison.OrdinalIgnoreCase))) return Accessory.Headset;
        var t = c.Title.ToLowerInvariant();
        if (GlassesWords.Any(t.Contains)) return Accessory.Glasses;
        return null;
    }

    static int Rank(Mood m) => m switch { Mood.Waiting => 0, Mood.Stuck => 1, Mood.Finished => 2, Mood.Working => 3, Mood.Idle => 4, Mood.Asleep => 5, _ => 6 };

    /// 排序：要你處理的島在前，其次是在忙的，最後才是全閒置的；島內同理。
    /// 專案名不分大小寫（Windows 的資料夾名同一個，cwd 大小寫可能不同），島名用第一次看到的寫法。
    public static List<Island> Build(IEnumerable<BoardCard> cards, IEnumerable<string>? headsetProjects = null)
    {
        var headset = (headsetProjects ?? DefaultHeadsetProjects).ToList();
        var cmp = StringComparer.OrdinalIgnoreCase;
        var order = new List<string>();
        var people = new Dictionary<string, List<Islander>>(cmp);
        var queued = new Dictionary<string, int>(cmp);
        foreach (var c in cards)
        {
            if (!order.Contains(c.Project, cmp)) order.Add(c.Project);
            if (c.IsQueued) { queued[c.Project] = queued.GetValueOrDefault(c.Project) + 1; continue; }
            if (!people.TryGetValue(c.Project, out var list)) people[c.Project] = list = new();
            list.Add(new Islander(c, Moods.Of(c), AccessoryOf(c, headset)));
        }
        var islands = new List<Island>();
        foreach (var p in order)
        {
            // OrderBy 是穩定排序：同一種狀態保持原本（看板）的先後
            var ps = people.GetValueOrDefault(p)?.OrderBy(x => Rank(x.Mood)).ToList() ?? new();
            var q = queued.GetValueOrDefault(p);
            if (ps.Count == 0 && q == 0) continue;
            islands.Add(new Island { Project = p, People = ps, Queued = q });
        }
        // 影分身：只去已經有的島（不為了逛一下多開一座，整個版面會重排）
        var everyone = islands.SelectMany(i => i.People).ToList();
        foreach (var i in islands)
            i.Ghosts = everyone.Where(x => x.Card.Visiting != null && cmp.Equals(x.Card.Visiting, i.Project)).ToList();
        static int IslandRank(Island i) => i.NeedsYou > 0 ? 0 : i.Count(Mood.Working) > 0 ? 1 : 2;
        return islands.OrderBy(IslandRank).ToList();
    }
}

/// 卡片排法（Mac 10-12 Kang：每張一樣大、全部剛好塞滿視窗）。試每一種欄數，挑讓卡片最大的。
public readonly record struct IslandGrid(int Cols, int Rows, double Width, double Height)
{
    /// `aspect`＝卡片理想的寬高比（島在左、對話框在右，偏寬）；高度低於 `minHeight` 就不硬塞，改成可以往下捲
    public static IslandGrid Fit(int count, double width, double height, double gap = 12,
                                 double aspect = 1.7, double minHeight = 170, double minWidth = 300)
    {
        int n = Math.Max(count, 1);
        var best = new IslandGrid(1, n, width, height);
        double bestScore = double.NegativeInfinity;
        for (int c = 1; c <= n; c++)
        {
            int r = (n + c - 1) / c;
            if ((r - 1) * c >= n) continue;                       // 最後一列整列空著 ⇒ 跟少一欄一樣，跳過
            double w = (width - (c - 1) * gap) / c;
            double h = (height - (r - 1) * gap) / r;
            if (w <= 0 || h <= 0 || (c != 1 && w < minWidth)) continue;   // 太窄放不下對話框 ⇒ 寧可少欄、往下捲
            // 卡片「有效大小」：太扁就被寬度卡、太高就被高度卡
            double score = Math.Min(w / aspect, h);
            if (score > bestScore) { bestScore = score; best = new IslandGrid(c, r, w, Math.Max(h, minHeight)); }
        }
        return best;
    }
}
