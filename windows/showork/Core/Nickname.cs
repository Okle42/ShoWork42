using System.Diagnostics;
using System.Text;
using System.Text.Json.Nodes;

namespace ShoWork.Hooks;

// 戰情中心上每個 AI 的英文名＋正在做的任務（Mac 版 Sources/ShoWorkCore/Nickname.swift 的移植）。
// 存在 board\names\<sid>.json：{"name":"Alex","doing":"…","at":"…"}；名字跟著 session 走，session 結束後可以給新的 session 用。

sealed class Nickname
{
    public string Name = "";
    public string? Doing;
    public DateTime? At;
    public string? HandoverFrom;         // Mac 的自動交接（Handover.swift）寫的；Windows 只照抄，不用

    public JsonObject ToJson()
    {
        var o = new JsonObject { ["name"] = Name };
        o.Put("doing", Doing); o.Put("at", At); o.Put("handoverFrom", HandoverFrom);
        return o;
    }

    public static Nickname? From(JsonNode? o) => o.Str("name") is { } n
        ? new Nickname { Name = n, Doing = o.Str("doing"), At = o.Date("at"), HandoverFrom = o.Str("handoverFrom") } : null;
}

/// ~/.claude/sessions/<pid>.json 的一筆（只取 hook 端要的欄位；看板那邊的 SessionRecord 在 ShoWork.Win\Board）
sealed class PeerSession
{
    public int Pid;
    public string SessionId = "";
    public string Cwd = "";
    public string? Name;
    public string? Kind;
    public string? Entrypoint;
    public string? MessagingSocketPath;  // 跨 session 訊息的收件位置（Claude Code 內建 SendMessage 用的）

    public static PeerSession? Decode(string? json)
    {
        var o = HookJson.Parse(json) as JsonObject;
        if (o == null || o.Str("sessionId") is not { Length: > 0 } sid || o.Int("pid") is not { } pid) return null;
        return new PeerSession
        {
            Pid = pid, SessionId = sid, Cwd = o.Str("cwd") ?? "", Name = o.Str("name"), Kind = o.Str("kind"),
            Entrypoint = o.Str("entrypoint"), MessagingSocketPath = o.Str("messagingSocketPath"),
        };
    }

    public static string Dir => Path.Combine(HookPaths.ClaudeDir, "sessions");

    /// 全部的紀錄（不管行程在不在）
    public static List<PeerSession> All() =>
        HookJson.Files(Dir, "*.json").Select(f => Decode(HookJson.ReadText(f))).OfType<PeerSession>().ToList();

    /// 現在活著的 session（Mac：kill(pid, 0) == 0 || errno == EPERM）
    public static List<PeerSession> Live() => All().Where(r => Alive(r.Pid)).ToList();

    /// 行程還在；沒權限查（提權的終端機）也算在
    public static bool Alive(int pid)
    {
        if (pid <= 0) return false;
        try { using var p = Process.GetProcessById(pid); return !p.HasExited; }
        catch (ArgumentException) { return false; }
        catch { return true; }
    }
}

static class Nicknames
{
    /// 好念、字首不重複
    public static readonly string[] Pool = { "Alex", "Bella", "Chris", "Dora", "Ethan", "Fiona", "Gavin", "Hana", "Ivan", "Jade", "Kyle", "Luna", "Milo",
                                             "Nina", "Oscar", "Penny", "Quinn", "Ruby", "Sam", "Tina", "Umar", "Vera", "Wade", "Xena", "Yuki", "Zack" };

    /// transcript 開頭的 custom-title／agent-name（「Bella-在做的事」取「-」前面）；要是英文名的樣子（字母開頭、英數、≤12 字）
    public static string? Inherited(byte[]? head)
    {
        if (head == null) return null;
        foreach (var raw in Encoding.UTF8.GetString(head).Split('\n').Take(20))
        {
            if (HookJson.Parse(raw) is not JsonObject o) continue;
            var v = o.Str("type") == "custom-title" ? o.Str("customTitle") : o.Str("type") == "agent-name" ? o.Str("agentName") : null;
            if (v?.Split('-', 2)[0] is not { Length: > 0 and <= 12 } t) continue;
            if (char.IsAsciiLetter(t[0]) && t.All(char.IsAsciiLetterOrDigit)) return t;
        }
        return null;
    }

    /// 挑一個還沒被用掉的名字；26 個都用完就加數字（Alex2⋯）
    public static string Pick(ISet<string> taken)
    {
        for (int round = 1; round < 1000; round++)
            foreach (var n in Pool)
            {
                var c = round == 1 ? n : n + round;
                if (!taken.Contains(c)) return c;
            }
        return Pool[0];
    }

    /// 最近用過的名字也算佔用（session 結束後 Remote Control 還會留一筆同名的離線紀錄）
    public static readonly TimeSpan ReuseAfter = TimeSpan.FromDays(3);

    public static HashSet<string> Taken(Dictionary<string, Nickname> all, ISet<string> live, string me, DateTime now) =>
        all.Where(kv => kv.Key != me && (live.Contains(kv.Key) || kv.Value.At is { } at && now - at < ReuseAfter))
           .Select(kv => kv.Value.Name).ToHashSet();

    /// Character.isNewline：\n \r（含 \r\n）、垂直定位、換頁、NEL、行／段分隔
    static readonly char[] NewLines = { '\n', '\r', '\u000B', '\u000C', '\u0085', '\u2028', '\u2029' };

    /// 任務字串整理：去掉換行、頭尾空白，太長截斷（卡片一行放得下）
    public static string? CleanDoing(string s)
    {
        var t = SwiftText.TrimSpaces(string.Join(" ", s.Split(NewLines, StringSplitOptions.RemoveEmptyEntries)));
        if (t.Length == 0) return null;
        return SwiftText.Count(t) > 24 ? SwiftText.Prefix(t, 24) + "⋯" : t;
    }

    /// UserPromptSubmit 的 hook 輸出：sessionTitle（＝英文名，SendMessage 的地址）＋additionalContext（開工卡提醒／放行回覆）。
    /// Mac 另外帶 terminalSequence（OSC 0 改 Ghostty 標題）；Windows 不帶：W1 的 Windows Terminal 分頁判斷靠主控台標題比對，
    /// 不在這裡另外改標題。n＝null（還沒取名）時只帶 context；沒東西可說回空字串（不輸出）
    public static string HookOutput(Nickname? n, string? hookEvent, string? context)
    {
        if (hookEvent != "UserPromptSubmit") return "";
        var h = new JsonObject { ["hookEventName"] = "UserPromptSubmit" };
        if (n != null) h["sessionTitle"] = n.Name;
        if (context != null) h["additionalContext"] = context;
        if (h.Count <= 1) return "";
        return HookJson.Text(new JsonObject { ["hookSpecificOutput"] = h });
    }
}

/// 英文短名當收訊地址（Mac 的 ShortName）：只看「現在活著的」；兩個活的同名就全回，讓呼叫端報錯
static class ShortName
{
    public static List<string> Match(string who, IReadOnlyList<(string Sid, string? Name)> sessions, IReadOnlyDictionary<string, string> nick)
    {
        var w = SwiftText.TrimSpaces(who);
        if (w.Length == 0) return new();
        var exact = sessions.Where(s => s.Name == w || s.Sid == w).Select(s => s.Sid).ToList();
        if (exact.Count > 0) return exact;
        var shortHits = sessions.Where(s =>
                (nick.TryGetValue(s.Sid, out var n) && string.Equals(n, w, StringComparison.OrdinalIgnoreCase))
                || (s.Name?.ToLowerInvariant().StartsWith(w.ToLowerInvariant() + "-", StringComparison.Ordinal) ?? false))
            .Select(s => s.Sid).ToList();
        if (shortHits.Count > 0) return shortHits;
        return SwiftText.Count(w) >= 6 ? sessions.Where(s => s.Sid.StartsWith(w, StringComparison.Ordinal)).Select(s => s.Sid).ToList() : new();
    }
}

/// board\names\<sid>.json 的讀寫
static class NicknameStore
{
    public static string Dir => Path.Combine(HookPaths.Board, "names");

    public static Nickname? Get(string sid) => Nickname.From(HookJson.ReadObject(Path.Combine(Dir, sid + ".json")));

    public static Dictionary<string, Nickname> All()
    {
        var out_ = new Dictionary<string, Nickname>();
        foreach (var f in HookJson.Files(Dir, "*.json"))
        {
            var sid = Path.GetFileNameWithoutExtension(f);
            if (Get(sid) is { } n) out_[sid] = n;
        }
        return out_;
    }

    static void Save(string sid, Nickname n) => HookJson.WriteAtomic(Path.Combine(Dir, sid + ".json"), HookJson.Text(n.ToJson()));

    /// 這個 session 的名字；還沒有就從沒用到的名字裡挑一個存起來
    public static Nickname Ensure(string sid, DateTime? now = null)
    {
        if (Get(sid) is { } n0) return n0;
        var t = now ?? DateTime.UtcNow;
        var all = All();
        var live = PeerSession.Live().Select(r => r.SessionId).ToHashSet();
        // 同一個程序換了 sessionId（transcript 開頭抄著舊的 custom-title）⇒ 沿用那個名字，只要現在沒有別的活著的 session 用它
        if (Nicknames.Inherited(HeadOfTranscript(sid)) is { } old
            && !all.Any(kv => kv.Key != sid && live.Contains(kv.Key) && kv.Value.Name == old))
        {
            var n1 = new Nickname { Name = old, At = t };
            Save(sid, n1);
            return n1;
        }
        var n = new Nickname { Name = Nicknames.Pick(Nicknames.Taken(all, live, sid, t)), At = t };
        Save(sid, n);
        return n;
    }

    /// ~/.claude/projects/*/<sid>.jsonl 前 16 KB；找不到＝null
    static byte[]? HeadOfTranscript(string sid)
    {
        var root = Path.Combine(HookPaths.ClaudeDir, "projects");
        try
        {
            if (!Directory.Exists(root)) return null;
            foreach (var d in Directory.GetDirectories(root))
            {
                var f = Path.Combine(d, sid + ".jsonl");
                if (!File.Exists(f)) continue;
                using var fs = new FileStream(f, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
                var buf = new byte[16 << 10];
                int n = fs.ReadAtLeast(buf, buf.Length, throwOnEndOfStream: false);
                return buf[..n];
            }
        }
        catch { }
        return null;
    }

    /// 還活著：at 當「最後出現」用（名字冷卻從這裡算）；一小時最多寫一次
    public static void Touch(string sid, DateTime now)
    {
        if (Get(sid) is not { } n || (n.At ?? DateTime.MinValue) >= now.AddHours(-1)) return;
        n.At = now; Save(sid, n);
    }

    /// 自報帶了 --doing 就更新任務
    public static Nickname Update(string sid, string? doing, DateTime? now = null)
    {
        var n = Ensure(sid, now);
        if (doing != null && doing != n.Doing) { n.Doing = doing; n.At = now ?? DateTime.UtcNow; Save(sid, n); }
        return n;
    }
}
