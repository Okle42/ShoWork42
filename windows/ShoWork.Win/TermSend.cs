using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;

namespace ShoWork;

// 把文字「打進」某個 Claude Code 的終端機（Mac 版的 `tmux send-keys -l <text>`＋`send-keys Enter`）。
//
// 做法：AttachConsole(claude.exe 的 pid) → 開 CONIN$ → WriteConsoleInputW 塞按鍵事件。
//   • 傳統主控台（conhost）和 Windows Terminal（ConPTY，輸入緩衝區在 OpenConsole.exe 裡）都是同一條：
//     字直接進那個 session 的主控台輸入緩衝區，跟從鍵盤打進去一樣，不經過 WT、不切分頁、不搶焦點、不動剪貼簿。
//   • 掛到別人的主控台只在「用完即丟」的子行程裡做（ShoWorkAgent.exe --term-inject），跟 showork.exe console 同理：
//     掛著的時候那個分頁按 Ctrl+C 或被關掉，主控台會連掛上去的行程一起送 CTRL_CLOSE，不能讓 agent 本身掛上去。
//   • 跟 Mac 一樣先送字、停 150 ms、再送 Enter：同一批裡字和 Enter 一起到，Claude Code 會當成貼上，Enter 變成換行不送出。
//   • 換行一律換成空白（同 Mac BoardActions.sendBack）：中途的 Enter 會把半句話先送出去。
//
// 目標一定要閉環驗證（Mac 09-26 搬錯視窗的教訓）：sessionId → ~/.claude/sessions/<pid>.json 的 pid → 那個 pid 真的是 claude.exe、
// 而且不是 session 開始後才出生的（pid 被重用）。驗不過就不送。
//
// 接上去的地方（之後做）：
//   退回（BoardActions.sendBack）      TermSend.Send(sid, 意見, enter: true)
//   自動交接（HandoverClear）          if (TermSend.IsIdle(sid, out _)) TermSend.Send(sid, "/clear", true) … 換了 sid 後 TermSend.Send(pid, kickoff, true)
//   戰情中心回答（BoardActions.answer）TermSend.Send(sid, 答案, true)；失敗再走 Peer（messagingSocketPath）
public static class TermSend
{
    public enum Outcome { Sent, NoSession, NotClaude, AccessDenied, NoConsole, WriteFailed, HelperFailed, Empty }

    public readonly record struct Result(Outcome Outcome, int Pid, string Message)
    {
        public bool Ok => Outcome == Outcome.Sent;
    }

    /// 字和 Enter 中間停多久（同 Mac 的 0.15 秒）
    public const int EnterDelayMs = 150;
    /// 斜線指令一個字一個字打、中間停這麼久（Mac 10-27：一次貼進去的 /clear 被當一般訊息；逐字打才會被當指令）
    public const int SlashTypingMs = 15;

    // ───────────────────────── 對外 API ─────────────────────────

    /// 把一句話打進那個 session 的輸入框；enter＝送出。target＝sessionId 或 claude.exe 的 pid。
    /// 不檢查忙不忙（退回、回答是使用者按了才送）；自動交接這類「沒人按」的要先問 IsIdle。
    public static Result Send(string target, string text, bool enter = true, string? claudeDir = null)
    {
        var line = Normalize(text);
        if (line.Length == 0 && !enter) return new(Outcome.Empty, 0, "沒有要送的字");
        if (Resolve(target, claudeDir) is not { } r) return new(Outcome.NoSession, 0, $"找不到 {target} 的 Claude Code session（~/.claude/sessions 裡沒有、或行程已結束）");
        if (!IsClaude(r)) return new(Outcome.NotClaude, r.Pid, $"pid {r.Pid} 已經不是那個 claude.exe（結束了或 pid 被重用），不送");
        return Inject(r.Pid, line, enter);
    }

    /// 送具名按鍵（選單用：down／up／enter／tab／space／esc；一個一個送、中間停 80 ms）。
    /// 注意 esc：Claude Code 在工作時按 Esc＝中斷它，只能在確定是選單時用。
    public static Result SendKeys(string target, IEnumerable<string> keys, string? claudeDir = null)
    {
        var names = keys.Select(k => k.Trim().ToLowerInvariant()).ToList();
        if (names.Count == 0 || names.Any(k => !Named.ContainsKey(k))) return new(Outcome.Empty, 0, $"不認得的按鍵：{string.Join(",", names)}（可用 {string.Join("／", Named.Keys)}）");
        if (Resolve(target, claudeDir) is not { } r) return new(Outcome.NoSession, 0, $"找不到 {target} 的 Claude Code session");
        if (!IsClaude(r)) return new(Outcome.NotClaude, r.Pid, $"pid {r.Pid} 已經不是那個 claude.exe，不送");
        return Inject(r.Pid, "", false, string.Join(",", names));
    }

    /// 具名按鍵 → (VK, 掃描碼, 字)
    public static readonly IReadOnlyDictionary<string, (ushort Vk, ushort Scan, char Ch)> Named = new Dictionary<string, (ushort, ushort, char)>
    {
        ["enter"] = (0x0D, 0x1C, '\r'), ["tab"] = (0x09, 0x0F, '\t'), ["space"] = (0x20, 0x39, ' '), ["esc"] = (0x1B, 0x01, '\x1b'),
        ["up"] = (0x26, 0x48, '\0'), ["down"] = (0x28, 0x50, '\0'), ["left"] = (0x25, 0x4B, '\0'), ["right"] = (0x27, 0x4D, '\0'),
    };

    public static Key[] NamedKeys(string name) => Named[name] is var (vk, sc, ch) ? new[] { new Key(true, vk, sc, ch), new Key(false, vk, sc, ch) } : Array.Empty<Key>();

    /// 現在送字安不安全：Claude Code 自己說 idle、光暈不是「工作中」或「等你回答（對話框）」、
    /// 而且使用者鍵盤已經靜了 minKeyIdleSec 秒（0＝不看鍵盤，同 Mac Handover.keyIdle 10-26 起的設定）。
    /// 對話框開著時打字會被當成對話框的答案（選項／允許），所以紅色一律不送。
    public static bool IsIdle(string target, out string why, double minKeyIdleSec = 0, string? claudeDir = null)
    {
        if (Resolve(target, claudeDir) is not { } r) { why = "找不到 session"; return false; }
        var glows = BoardReader.Glows(Path.Combine(Wire.SupportDir, "state.json"));
        return Ready(r.Status, glows.TryGetValue(r.Pid, out var g) ? g : null, KeyIdleSeconds(), minKeyIdleSec, out why);
    }

    // ───────────────────────── 純邏輯（單元測試） ─────────────────────────

    /// 換行換成空白、去頭尾空白（同 Mac sendBack）
    public static string Normalize(string? text) =>
        (text ?? "").Replace("\r\n", " ").Replace('\r', ' ').Replace('\n', ' ').Trim();

    /// sessions/<pid>.json 的 status＋光暈狀態＋鍵盤閒置 ⇒ 能不能送
    public static bool Ready(string? status, WorkState? glow, double keyIdleSec, double minKeyIdleSec, out string why)
    {
        if (status is "busy") { why = "Claude Code 回報 busy（正在跑）"; return false; }
        if (status is "waiting") { why = "Claude Code 在等權限／問題的回答"; return false; }
        if (glow == WorkState.Working) { why = "光暈是工作中"; return false; }
        if (glow == WorkState.Input) { why = "光暈是紅色：對話框開著，打字會變成對話框的答案"; return false; }
        if (minKeyIdleSec > 0 && keyIdleSec < minKeyIdleSec) { why = $"使用者 {keyIdleSec:0} 秒前還在打字（要靜 {minKeyIdleSec:0} 秒）"; return false; }
        why = status is "idle" ? "idle" : $"status={status ?? "（沒有）"}，光暈不是工作中";
        return true;
    }

    /// target 是數字就當 pid，否則當 sessionId；只認行程還在的
    public static SessionRecord? Find(string target, IEnumerable<SessionRecord> sessions)
    {
        target = target.Trim();
        var list = sessions.ToList();
        if (int.TryParse(target, out var pid)) return list.FirstOrDefault(s => s.Pid == pid);
        return list.FirstOrDefault(s => s.SessionId.Equals(target, StringComparison.OrdinalIgnoreCase))
            // 只給前 8 碼也認（看板 log 都只印 8 碼），但不唯一就不認
            ?? (target.Length >= 8 && list.Where(s => s.SessionId.StartsWith(target, StringComparison.OrdinalIgnoreCase)).ToList() is [var one] ? one : null);
    }

    public readonly record struct Key(bool Down, ushort Vk, ushort Scan, char Ch);

    /// 一段字 → 按鍵事件（每個 UTF-16 單位一組按下／放開；VK 給 0、字放 UnicodeChar，跟輸入法送出的字一樣，中文、emoji 的代理對都照送）
    public static List<Key> Keys(string text)
    {
        var list = new List<Key>(text.Length * 2);
        foreach (var c in text) { list.Add(new(true, 0, 0, c)); list.Add(new(false, 0, 0, c)); }
        return list;
    }

    public static readonly Key[] EnterKeys = { new(true, 0x0D, 0x1C, '\r'), new(false, 0x0D, 0x1C, '\r') };

    /// 斜線指令要逐字打（貼上的 /clear 會被當成一般訊息）
    public static bool TypeSlowly(string line) => line.StartsWith('/');

    public static string Encode(string s) => Convert.ToBase64String(Encoding.UTF8.GetBytes(s));
    public static string Decode(string b64) => Encoding.UTF8.GetString(Convert.FromBase64String(b64));

    // ───────────────────────── 找目標 ─────────────────────────

    static SessionRecord? Resolve(string target, string? claudeDir)
    {
        var dir = Path.Combine(claudeDir ?? BoardReader.DefaultClaudeDir, "sessions");
        var list = new List<SessionRecord>();
        try
        {
            foreach (var f in Directory.EnumerateFiles(dir, "*.json"))
            {
                string j;
                try { j = File.ReadAllText(f); } catch { continue; }
                if (SessionRecord.Decode(j) is { } r && BoardReader.ProcessAlive(r, BoardReader.Probe)) list.Add(r);
            }
        }
        catch { }
        if (Find(target, list) is { } hit) return hit;
        // 沒 session 檔、但給的是 pid（例如測試用的 PowerShell 替身）：直接打給那個 pid，只是少了 claude.exe 的驗證
        return int.TryParse(target.Trim(), out var pid) && pid > 0 ? new SessionRecord { Pid = pid, SessionId = "", Name = "(pid)" } : null;
    }

    /// pid 真的是 claude.exe、而且是 session 開始時那一個（沒有 session 檔的替身目標不驗）
    static bool IsClaude(SessionRecord r)
    {
        if (r.SessionId.Length == 0) return true;
        try
        {
            using var p = Process.GetProcessById(r.Pid);
            if (!p.ProcessName.Equals("claude", StringComparison.OrdinalIgnoreCase)) return false;
            return r.SameOwner(p.StartTime.ToUniversalTime());
        }
        catch (System.ComponentModel.Win32Exception) { return true; }       // 提權的 claude.exe 查不到名字：交給 AttachConsole 判斷
        catch { return false; }
    }

    static double KeyIdleSeconds()
    {
        var li = new LASTINPUTINFO { cbSize = (uint)Marshal.SizeOf<LASTINPUTINFO>() };
        if (!GetLastInputInfo(ref li)) return double.MaxValue;
        return (uint)(Environment.TickCount - (int)li.dwTime) / 1000.0;
    }

    // ───────────────────────── 送字：起子行程 ─────────────────────────

    static string Self => Environment.ProcessPath ?? Path.Combine(AppContext.BaseDirectory, "ShoWorkAgent.exe");

    static Result Inject(int pid, string line, bool enter, string keys = "")
    {
        try
        {
            var psi = new ProcessStartInfo(Self) { UseShellExecute = false, CreateNoWindow = true };
            foreach (var a in new[] { "--term-inject", pid.ToString(), Encode(line), enter ? "1" : "0", keys }) psi.ArgumentList.Add(a);
            using var p = Process.Start(psi)!;
            if (!p.WaitForExit(10_000)) { try { p.Kill(); } catch { } return new(Outcome.HelperFailed, pid, "送字的子行程 10 秒沒結束"); }
            return (InjectCode)p.ExitCode switch
            {
                InjectCode.Ok => new(Outcome.Sent, pid, enter ? $"已打進 pid {pid} 並送出" : $"已打進 pid {pid}（沒按 Enter）"),
                InjectCode.Denied => new(Outcome.AccessDenied, pid, $"pid {pid} 的主控台不讓掛上去（多半是以系統管理員開的終端機，ShoWork 沒提權）"),
                InjectCode.NoConsole => new(Outcome.NoConsole, pid, $"pid {pid} 沒有主控台可掛（VS Code 終端機以外的特殊宿主，或行程已結束）"),
                InjectCode.Write => new(Outcome.WriteFailed, pid, $"掛上了，但寫不進 pid {pid} 的輸入緩衝區"),
                var c => new(Outcome.HelperFailed, pid, $"送字的子行程結束碼 {(int)c}"),
            };
        }
        catch (Exception e) { return new(Outcome.HelperFailed, pid, $"起不了送字的子行程：{e.Message}"); }
    }

    enum InjectCode { Ok = 0, Usage = 2, Denied = 3, NoConsole = 4, Write = 5 }

    // ───────────────────────── 送字：子行程本體 ─────────────────────────

    /// ShoWorkAgent.exe --term-inject <pid> <base64 UTF-8 字> <1|0 按 Enter>（只給 TermSend 自己叫）
    public static int InjectMain(string[] args)
    {
        if (args.Length < 4 || !uint.TryParse(args[1], out var pid)) return (int)InjectCode.Usage;
        string line;
        try { line = Decode(args[2]); } catch { return (int)InjectCode.Usage; }
        bool enter = args[3] == "1";

        FreeConsole();
        SetConsoleCtrlHandler(IntPtr.Zero, true);              // 掛著的時候那邊按 Ctrl+C 不會打到我們
        if (!AttachConsole(pid))
            return Marshal.GetLastWin32Error() == 5 /*ERROR_ACCESS_DENIED*/ ? (int)InjectCode.Denied : (int)InjectCode.NoConsole;
        try
        {
            var h = CreateFileW("CONIN$", GENERIC_READ | GENERIC_WRITE, FILE_SHARE_READ | FILE_SHARE_WRITE, IntPtr.Zero, OPEN_EXISTING, 0, IntPtr.Zero);
            if (h == new IntPtr(-1)) return (int)InjectCode.Write;
            try
            {
                if (line.Length > 0)
                {
                    if (TypeSlowly(line))
                        foreach (var c in line) { if (!Write(h, Keys(c.ToString()))) return (int)InjectCode.Write; Thread.Sleep(SlashTypingMs); }
                    else if (!Write(h, Keys(line))) return (int)InjectCode.Write;
                }
                if (enter)
                {
                    if (line.Length > 0) Thread.Sleep(EnterDelayMs);
                    if (!Write(h, EnterKeys)) return (int)InjectCode.Write;
                }
                foreach (var k in (args.Length > 4 ? args[4] : "").Split(',', StringSplitOptions.RemoveEmptyEntries))
                {
                    if (!Named.ContainsKey(k)) return (int)InjectCode.Usage;
                    if (!Write(h, NamedKeys(k))) return (int)InjectCode.Write;
                    Thread.Sleep(80);
                }
                return (int)InjectCode.Ok;
            }
            finally { CloseHandle(h); }
        }
        finally { FreeConsole(); }
    }

    static bool Write(IntPtr h, IReadOnlyList<Key> keys)
    {
        var recs = new INPUT_RECORD[keys.Count];
        for (int i = 0; i < keys.Count; i++)
            recs[i] = new INPUT_RECORD
            {
                EventType = KEY_EVENT,
                Key = new KEY_EVENT_RECORD { bKeyDown = keys[i].Down ? 1 : 0, wRepeatCount = 1, wVirtualKeyCode = keys[i].Vk, wVirtualScanCode = keys[i].Scan, UnicodeChar = keys[i].Ch },
            };
        int off = 0;
        while (off < recs.Length)                                // 一次最多寫一部分，照實際寫入數往下推
        {
            var chunk = recs[off..];
            if (!WriteConsoleInputW(h, chunk, (uint)chunk.Length, out var n) || n == 0) return false;
            off += (int)n;
        }
        return true;
    }

    // ───────────────────────── Win32 ─────────────────────────

    const ushort KEY_EVENT = 1;
    const uint GENERIC_READ = 0x80000000, GENERIC_WRITE = 0x40000000, FILE_SHARE_READ = 1, FILE_SHARE_WRITE = 2, OPEN_EXISTING = 3;

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct KEY_EVENT_RECORD
    {
        public int bKeyDown; public ushort wRepeatCount, wVirtualKeyCode, wVirtualScanCode; public char UnicodeChar; public uint dwControlKeyState;
    }

    [StructLayout(LayoutKind.Explicit, CharSet = CharSet.Unicode)]
    struct INPUT_RECORD
    {
        [FieldOffset(0)] public ushort EventType;
        [FieldOffset(4)] public KEY_EVENT_RECORD Key;
    }

    [StructLayout(LayoutKind.Sequential)] struct LASTINPUTINFO { public uint cbSize, dwTime; }

    [DllImport("kernel32.dll", SetLastError = true)] static extern bool AttachConsole(uint pid);
    [DllImport("kernel32.dll")] static extern bool FreeConsole();
    [DllImport("kernel32.dll")] static extern bool SetConsoleCtrlHandler(IntPtr handler, bool add);
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern IntPtr CreateFileW(string name, uint access, uint share, IntPtr sa, uint disposition, uint flags, IntPtr template);
    [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern bool WriteConsoleInputW(IntPtr h, INPUT_RECORD[] recs, uint n, out uint written);
    [DllImport("user32.dll")] static extern bool GetLastInputInfo(ref LASTINPUTINFO li);
}
