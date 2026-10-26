using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text.Json;

namespace ShoWork;

// 戰情中心的資料層（Mac 版 BoardSource.swift 的 BoardReader）：讀一次本機的 Claude Code 狀態，組成看板。
// 全部唯讀：不寫 ~/.claude、也不寫 ShoWork 自己的資料夾（Mac 會把隊員進出、信箱訊息記進 board\history.jsonl，
// Windows 唯讀版先不記，隊伍資料夾被 Claude Code 刪掉後就看不到了）。
//
// 各資料來源在 Windows 的狀況（10-15 Surface 實測）：
//   sessions\<pid>.json      有資料夾、目前是空的（沒開著的 claude）。格式假設同 Mac，見 SessionRecord。
//   projects\<slug>\*.jsonl  有，cwd 是 "C:\\Users\\Demo User" 這種原生路徑（不是 Git Bash 的 /c/…）。
//   光暈狀態（glows）        Mac 讀 Application Support\ShoWork42\state.json；Windows 的 agent 也存 %LOCALAPPDATA%\ShoWork42\state.json
//                            （[{Pid,Created,Agent,State}]），一樣讀得到，key 是 claude.exe 的 pid。
//   teams\、inboxes\         Claude Code 的功能，Windows 應該一樣；Surface 上還沒有，讀不到就空。
//   board\cards 等           自報／審核／決定：Windows 還沒有寫的人 ⇒ 空。
//   board\captain.json       隊長：Windows 還沒有 `showork captain` ⇒ 空。
//   cache\rate_limits.json   流量、cache\ctx\<sid>.json：由 statusLine 腳本存，Surface 沒有 ⇒ 空（流量表、🧠 不顯示）。
public sealed class BoardReader
{
    public sealed class Snapshot
    {
        public List<SessionRecord> Sessions = new();
        public Dictionary<string, TranscriptInfo> Transcripts = new();
        public Dictionary<int, WorkState> Glows = new();
        public List<TeamConfig> Teams = new();
        public List<TeamMessage> Inbox = new();
        public Dictionary<string, SelfReport> Reports = new();
        public Dictionary<string, Review> Reviews = new();
        public Dictionary<string, Decision> Decisions = new();
        public Dictionary<string, ContextUse> Contexts = new();
        public RateLimits? RateLimits;
        public string? Captain;                  // 隊長的 sessionId（還開著才算）
    }

    public const int TailBytes = 512 * 1024;
    const int CwdBackBytes = 8 << 20;

    public string ClaudeDir { get; }
    public string SupportDir { get; }
    public string Home { get; }
    /// session 的行程還在不在（測試可換掉）
    public Func<SessionRecord, bool> Alive { get; init; } = ProcessAlive;
    public Func<string, bool> IsRepo { get; init; } = DefaultIsRepo;

    public BoardReader(string claudeDir, string supportDir, string home) { ClaudeDir = claudeDir; SupportDir = supportDir; Home = home; }

    public static string DefaultHome => Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
    /// SHOWORK_CLAUDE_DIR 給測試用（同 Mac）
    public static string DefaultClaudeDir =>
        Environment.GetEnvironmentVariable("SHOWORK_CLAUDE_DIR") is { Length: > 0 } d ? d : Path.Combine(DefaultHome, ".claude");
    public static BoardReader Default() => new(DefaultClaudeDir, Wire.SupportDir, DefaultHome);

    /// worktree 的 .git 是檔案，一般 repo 是資料夾，兩種都算
    public static bool DefaultIsRepo(string p)
    {
        var g = Path.Combine(p, ".git");
        return Directory.Exists(g) || File.Exists(g);
    }

    /// 查一個 pid 的結果：不存在／存在（開始時間讀得到才有）／存在但沒權限查（比自己權限高的行程，例如以系統管理員開的終端機）
    public enum ProbeResult { Gone, Alive, Denied }

    /// Windows 沒有 kill(pid, 0)：行程在、而且不是 session 開始之後才出生的（pid 被重用）才算。
    /// 沒權限查＝還在（同 Mac 的 `kill(pid,0)==0 || errno==EPERM`）——以前用 Process.HasExited，碰到提權的 claude.exe 丟存取被拒、被當成殘留檔，卡片就不見了。
    public static bool ProcessAlive(SessionRecord r) => ProcessAlive(r, Probe);

    public static bool ProcessAlive(SessionRecord r, Func<int, (ProbeResult Result, DateTime? StartUtc)> probe) => probe(r.Pid) switch
    {
        (ProbeResult.Gone, _) => false,
        (ProbeResult.Alive, { } start) => r.SameOwner(start),
        _ => true,                                         // Denied，或開始時間讀不到：當它還在
    };

    /// OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION) 跨完整性層級通常拿得到（一般權限查得到提權行程）；拿不到時看錯誤碼分「不存在」和「沒權限」
    public static (ProbeResult, DateTime?) Probe(int pid)
    {
        if (!OperatingSystem.IsWindows())
        {
            try { using var p = Process.GetProcessById(pid); return (p.HasExited ? ProbeResult.Gone : ProbeResult.Alive, p.StartTime.ToUniversalTime()); }
            catch (ArgumentException) { return (ProbeResult.Gone, null); }
            catch { return (ProbeResult.Denied, null); }
        }
        if (pid <= 0) return (pid == 0 ? ProbeResult.Alive : ProbeResult.Gone, null);   // 0＝System Idle Process
        var h = OpenProcess(0x1000 /*PROCESS_QUERY_LIMITED_INFORMATION*/, false, pid);
        if (h == IntPtr.Zero)
        {
            int err = Marshal.GetLastWin32Error();
            return (err == 5 /*ERROR_ACCESS_DENIED*/ ? ProbeResult.Denied : ProbeResult.Gone, null);   // 87＝ERROR_INVALID_PARAMETER：沒這個 pid
        }
        try
        {
            // 結束了但還有人握著 handle 的行程 OpenProcess 也會成功 ⇒ 要看結束碼（STILL_ACTIVE＝259）
            if (GetExitCodeProcess(h, out var code) && code != 259) return (ProbeResult.Gone, null);
            DateTime? start = GetProcessTimes(h, out var created, out _, out _, out _) ? DateTime.FromFileTimeUtc(created) : null;
            return (ProbeResult.Alive, start);
        }
        finally { CloseHandle(h); }
    }

    [DllImport("kernel32.dll", SetLastError = true)] static extern IntPtr OpenProcess(uint access, bool inherit, int pid);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool GetExitCodeProcess(IntPtr h, out uint code);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool GetProcessTimes(IntPtr h, out long created, out long exited, out long kernel, out long user);
    [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);

    public Snapshot Read()
    {
        var s = new Snapshot();
        foreach (var f in Files(Path.Combine(ClaudeDir, "sessions"), "*.json"))
        {
            if (Text(f) is not { } j || SessionRecord.Decode(j) is not { } r) continue;
            if (r.Kind == "background" || !Alive(r)) continue;           // 行程不在＝殘留檔
            s.Sessions.Add(r);
        }
        foreach (var r in s.Sessions) s.Transcripts[r.SessionId] = Transcript(r);
        Prune(s.Sessions);
        s.Glows = Glows(Path.Combine(SupportDir, "state.json"));
        foreach (var team in Dirs(Path.Combine(ClaudeDir, "teams")))
        {
            if (Text(Path.Combine(team, "config.json")) is not { } cj || TeamConfig.Decode(cj) is not { } c) continue;
            s.Teams.Add(c);
            foreach (var f in Files(Path.Combine(team, "inboxes"), "*.json"))
                if (Text(f) is { } ib) s.Inbox.AddRange(TeamMessage.DecodeInbox(ib, Path.GetFileNameWithoutExtension(f)));
        }
        s.Reports = ReadAll<SelfReport>("cards");
        s.Reviews = ReadAll<Review>("reviews");
        s.Decisions = ReadAll<Decision>("decisions");
        var rl = Environment.GetEnvironmentVariable("SHOWORK_RATE_LIMITS") is { Length: > 0 } x ? x : Path.Combine(ClaudeDir, "cache", "rate_limits.json");
        s.RateLimits = Text(rl) is { } rj ? RateLimits.Parse(rj) : null;
        foreach (var r in s.Sessions)
            if (Text(Path.Combine(ClaudeDir, "cache", "ctx", r.SessionId + ".json")) is { } cj2 && ContextUse.Parse(cj2) is { } cu) s.Contexts[r.SessionId] = cu;
        if (Text(Path.Combine(SupportDir, "board", "captain.json")) is { } capj)
        {
            try
            {
                using var doc = JsonDocument.Parse(capj);
                if (doc.RootElement.TryGetProperty("sessionId", out var sid) && sid.GetString() is { } id && s.Sessions.Any(r => r.SessionId == id))
                    s.Captain = id;
            }
            catch { }
        }
        return s;
    }

    /// 讀一次＋組成卡片（標上隊長、同專案重工）
    public List<BoardCard> Cards(Snapshot s, DateTime now) =>
        Captain.Annotate(Board.Build(s.Sessions, s.Transcripts, s.Glows, s.Teams, s.Inbox, now, Home, IsRepo,
                                     s.Reports, s.Reviews, s.Decisions, s.Contexts), s.Captain);

    /// ShoWork 自己的光暈狀態：agent 每次 Render 都存 state.json（Engine.Save）。同一個 pid 有多筆取最急的。
    public static Dictionary<int, WorkState> Glows(string path)
    {
        var out_ = new Dictionary<int, WorkState>();
        if (Text(path) is not { } j) return out_;
        try
        {
            using var doc = JsonDocument.Parse(j);
            if (doc.RootElement.ValueKind != JsonValueKind.Array) return out_;
            foreach (var x in doc.RootElement.EnumerateArray())
            {
                if (!x.TryGetProperty("Pid", out var p) || !x.TryGetProperty("State", out var st)
                    || !Enum.TryParse<WorkState>(st.GetString(), ignoreCase: true, out var ws)) continue;
                var pid = p.GetInt32();
                out_[pid] = StateMachine.WindowState(new[] { out_.GetValueOrDefault(pid, WorkState.Idle), ws });
            }
        }
        catch { }
        return out_;
    }

    Dictionary<string, T> ReadAll<T>(string kind) where T : class
    {
        var out_ = new Dictionary<string, T>();
        foreach (var f in Files(Path.Combine(SupportDir, "board", kind), "*.json"))
            if (Text(f) is { } j && BoardJson.Decode<T>(j) is { } v) out_[Path.GetFileNameWithoutExtension(f)] = v;
        return out_;
    }

    // MARK: 對話紀錄

    readonly Dictionary<string, (DateTime Mtime, long Size, TranscriptInfo Info)> transcriptCache = new();
    readonly Dictionary<string, (long Offset, List<CwdMark> Cwds)> cwdCache = new();
    readonly Dictionary<string, string> pathCache = new();

    /// 結束的 session 從快取拿掉（不然看板開幾天，快取只增不減；cwdCache 每筆最多 CwdWindow 筆）
    void Prune(List<SessionRecord> live)
    {
        var keep = live.Select(r => r.SessionId).ToHashSet();
        foreach (var k in transcriptCache.Keys.Where(k => !keep.Contains(k)).ToList()) transcriptCache.Remove(k);
        foreach (var k in cwdCache.Keys.Where(k => !keep.Contains(k)).ToList()) cwdCache.Remove(k);
        foreach (var k in pathCache.Keys.Where(k => !keep.Contains(k)).ToList()) pathCache.Remove(k);
    }

    /// 測試用：快取裡記著幾個 session
    public int CachedSessions => transcriptCache.Keys.Union(cwdCache.Keys).Union(pathCache.Keys).Count();

    /// 對話紀錄的位置：先照 slug 規則找；找不到（Claude Code 把太長的路徑截短加雜湊、或規則跟猜的不同）就到各專案資料夾找同名檔
    string? TranscriptPath(SessionRecord r)
    {
        var p = Path.Combine(ClaudeDir, "projects", r.ProjectSlug, r.SessionId + ".jsonl");
        if (File.Exists(p)) return p;
        if (pathCache.TryGetValue(r.SessionId, out var c) && File.Exists(c)) return c;
        foreach (var d in Dirs(Path.Combine(ClaudeDir, "projects")))
        {
            var q = Path.Combine(d, r.SessionId + ".jsonl");
            if (File.Exists(q)) return pathCache[r.SessionId] = q;
        }
        return null;
    }

    /// 對話紀錄只在檔案變了才重讀尾端
    TranscriptInfo Transcript(SessionRecord r)
    {
        if (TranscriptPath(r) is not { } path) return new TranscriptInfo();
        try
        {
            var fi = new FileInfo(path);
            if (transcriptCache.TryGetValue(r.SessionId, out var c) && c.Mtime == fi.LastWriteTimeUtc && c.Size == fi.Length) return c.Info;
            // Claude Code 正在寫：要允許別人同時寫／換名
            using var fs = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
            long size = fs.Length;
            fs.Seek(Math.Max(0, size - TailBytes), SeekOrigin.Begin);
            var info = TranscriptInfo.Parse(ReadToEnd(fs));
            if (info.Title == null && c.Info?.Title is { } old) info.Title = old;     // 標題在尾端外就沿用
            info.RecentWorkCwds = WorkCwds(r.SessionId, fs, size);
            transcriptCache[r.SessionId] = (fi.LastWriteTimeUtc, size, info);
            return info;
        }
        catch { return new TranscriptInfo(); }
    }

    /// 最近做事的地方：尾端 512KB 常常只剩十幾筆（讀圖的行很大），住哪會亂跳 ⇒ 另外記，第一次往回讀 8MB，之後只讀新增的
    List<CwdMark> WorkCwds(string sid, FileStream fs, long size)
    {
        var c = cwdCache.TryGetValue(sid, out var old) ? old : (Math.Max(0, size - CwdBackBytes), new List<CwdMark>());
        if (size < c.Item1) c = (Math.Max(0, size - CwdBackBytes), new List<CwdMark>());   // 檔案被改寫
        fs.Seek(c.Item1, SeekOrigin.Begin);
        var d = ReadToEnd(fs);
        int end = Array.LastIndexOf(d, (byte)'\n') + 1;                                    // 最後一行可能還沒寫完，下次再讀
        var all = c.Item2.Concat(TranscriptInfo.WorkCwds(d.AsSpan(0, end))).ToList();
        if (all.Count > TranscriptInfo.CwdWindow) all = all.Skip(all.Count - TranscriptInfo.CwdWindow).ToList();
        cwdCache[sid] = (c.Item1 + end, all);
        return all;
    }

    static byte[] ReadToEnd(Stream s) { using var ms = new MemoryStream(); s.CopyTo(ms); return ms.ToArray(); }

    static string? Text(string path)
    {
        try
        {
            if (!File.Exists(path)) return null;
            using var fs = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
            using var sr = new StreamReader(fs);
            return sr.ReadToEnd();
        }
        catch { return null; }
    }
    static IEnumerable<string> Files(string dir, string pattern) { try { return Directory.Exists(dir) ? Directory.GetFiles(dir, pattern) : Array.Empty<string>(); } catch { return Array.Empty<string>(); } }
    static IEnumerable<string> Dirs(string dir) { try { return Directory.Exists(dir) ? Directory.GetDirectories(dir) : Array.Empty<string>(); } catch { return Array.Empty<string>(); } }
}
