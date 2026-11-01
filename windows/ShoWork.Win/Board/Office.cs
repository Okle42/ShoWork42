namespace ShoWork;

// 角色的英文名＋任務（W6 起的 Windows 版；Mac Nickname.swift：卡片標題＝「英文名-任務」）。
// 11-02 P8：3D 大樓改成照搬 Mac（Board\Core\：Tower、TowerTheme、Wander、City⋯，推 office2 給網頁），
//   W6 精簡版的樓層號名冊、主題、OfficeScene 拿掉了；這裡只剩英文名（看板卡片、測試還在用）。
// 這個檔不碰 WinForms（測試專案直接連）。

/// 角色頭上的英文名＋任務（Mac Nickname.swift：卡片標題＝「英文名-任務」）
public static class OfficeNames
{
    public static readonly string[] Pool = { "Alex", "Bella", "Chris", "Dora", "Ethan", "Fiona", "Gavin", "Hana", "Ivan", "Jade", "Kyle", "Luna", "Milo",
                                             "Nina", "Oscar", "Penny", "Quinn", "Ruby", "Sam", "Tina", "Umar", "Vera", "Wade", "Xena", "Yuki", "Zack" };

    /// 「Alex」或「Alex-任務」⇒ (Alex, 任務或 null)；不像英文名（大寫字母開頭、英數、≤12 字；you-88 這種自動名不算）就 null
    public static (string Name, string? Task)? Parse(string? s)
    {
        if (string.IsNullOrWhiteSpace(s)) return null;
        var parts = s.Trim().Split('-', 2);
        var n = parts[0];
        if (n.Length is 0 or > 12 || !char.IsAsciiLetterUpper(n[0]) || !n.All(char.IsAsciiLetterOrDigit)) return null;
        var task = parts.Length > 1 && parts[1].Trim().Length > 0 ? parts[1].Trim() : null;
        return (n, task);
    }

    /// 任務字串：一行、太長截斷（同 Mac Nicknames.cleanDoing，24 字）
    public static string Clean(string s)
    {
        var t = string.Join(" ", s.Split('\n', '\r')).Trim();
        return Board.Length(t) > 24 ? Board.Prefix(t, 24) + "⋯" : t;
    }

    /// 每張卡（排隊卡除外）→ (英文名, 任務)。有名字的先佔，沒有的照 sessionId 雜湊從名字池挑沒人用的（26 個用完加數字）
    public static Dictionary<string, (string Name, string Task)> Assign(IEnumerable<BoardCard> cards)
    {
        var list = cards.Where(c => !c.IsQueued).ToList();
        var out_ = new Dictionary<string, (string, string)>();
        var taken = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        var pending = new List<BoardCard>();
        foreach (var c in list)
        {
            // 標題只認「名字-任務」（只有一個英文字的標題，例如 README，不當名字）
            var named = Parse(c.Name) ?? (Parse(c.Title) is { Task: not null } t ? t : null);
            if (named is { } n && taken.Add(n.Name))
            {
                out_[c.Id] = (n.Name, Clean(n.Task ?? TaskOf(c)));
            }
            else pending.Add(c);
        }
        foreach (var c in pending)
        {
            int start = (int)(Fnv(c.SessionId.Length > 0 ? c.SessionId : c.Id) % (uint)Pool.Length);
            string name = Pool[start];
            for (int round = 1, i = 0; ; i++)
            {
                if (i == Pool.Length) { i = 0; round++; }
                var cand = Pool[(start + i) % Pool.Length] + (round == 1 ? "" : round.ToString());
                if (taken.Add(cand)) { name = cand; break; }
            }
            out_[c.Id] = (name, Clean(TaskOf(c)));
        }
        return out_;
    }

    /// FNV-1a 32 位元（.NET 的 string.GetHashCode 每次開程式都不一樣，不能拿來「穩定」挑）
    public static uint Fnv(string s)
    {
        uint h = 2166136261;
        foreach (var b in System.Text.Encoding.UTF8.GetBytes(s)) { h ^= b; h *= 16777619; }
        return h;
    }

    /// 標題是「Alex-任務」取任務那段，否則整個標題
    static string TaskOf(BoardCard c) => Parse(c.Title) is { Task: { } t } ? t : c.Title;
}

