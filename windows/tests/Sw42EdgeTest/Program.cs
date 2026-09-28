// ShoWork42 W2 驗收：全螢幕邊緣光。
//   Sw42EdgeTest.exe <bin dir with ShoWorkAgent.exe + showork.exe> <result file>
// 自己開一個私有 agent（SHOWORK_PIPE／SHOWORK_HOME／SHOWORK_STATUS_FILE）、一個 conhost 測試視窗、一個自己的無框全螢幕視窗。
// 規矩：只動自己開的視窗（白名單）；前後比對其他所有視窗的位置與大小；截圖只取邊緣附近幾個小方塊、只在記憶體裡看顏色。
using System.Diagnostics;
using System.Drawing;
using System.Runtime.InteropServices;
using System.Text.Json;

static class EdgeTest
{
    static readonly List<string> results = new();
    static int pass, fail;
    static string status = "";

    [STAThread]
    static int Main(string[] a)
    {
        // same guard as tests\guard.ps1: with the user's own auto-arrange on, our test windows would make it
        // rearrange the user's terminals
        try
        {
            var real = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "ShoWork42", "settings.json");
            if (File.Exists(real) && System.Text.Json.JsonDocument.Parse(File.ReadAllText(real)).RootElement
                    .TryGetProperty("general", out var g) && g.TryGetProperty("autoArrange", out var on) && on.GetBoolean())
            {
                Console.WriteLine("拒絕執行：你自己的 ShoWork42 開著「自動排版」，請先在系統匣選單取消勾選。");
                return 2;
            }
        }
        catch (Exception e) when (e is IOException or System.Text.Json.JsonException or InvalidOperationException) { }
        var bin = a[0]; var outFile = a[1];
        var work = Path.Combine(Path.GetTempPath(), "sw42-edge-" + DateTime.Now.ToString("yyyyMMdd-HHmmss"));
        Directory.CreateDirectory(Path.Combine(work, "home"));
        status = Path.Combine(work, "status.json");
        var pipe = "sw42-edge-" + Guid.NewGuid().ToString("N")[..8];
        var mine = new HashSet<int> { Environment.ProcessId };
        var before = Windows(mine);
        Process? agent = null, con = null; int cmdPid = 0;
        try
        {
            var psi = new ProcessStartInfo(Path.Combine(bin, "ShoWorkAgent.exe")) { UseShellExecute = false };
            psi.Environment["SHOWORK_PIPE"] = pipe; psi.Environment["SHOWORK_HOME"] = Path.Combine(work, "home");
            psi.Environment["SHOWORK_STATUS_FILE"] = status; psi.Environment["SHOWORK_DEBUG"] = "1";
            agent = Process.Start(psi)!; mine.Add(agent.Id);
            Thread.Sleep(1500);
            Check("私有 agent 啟動", !agent.HasExited, $"pid={agent.Id}");

            con = Process.Start(new ProcessStartInfo("conhost.exe", "cmd /k title sw42-edge-test") { UseShellExecute = false })!;
            mine.Add(con.Id);
            for (int i = 0; i < 50 && cmdPid == 0; i++) { Thread.Sleep(100); cmdPid = ChildOf(con.Id, "cmd.exe"); }
            mine.Add(cmdPid);
            Check("conhost 測試視窗", cmdPid != 0, $"conhost={con.Id} cmd={cmdPid}");

            void Emit(string ev)
            {
                var e = new ProcessStartInfo(Path.Combine(bin, "showork.exe"), $"emit {ev} --agent claude --pid {cmdPid}") { UseShellExecute = false, CreateNoWindow = true };
                e.Environment["SHOWORK_PIPE"] = pipe;
                Process.Start(e)!.WaitForExit();
            }
            Emit("done");
            var conWin = IntPtr.Zero;
            Wait(() => { var s = Status(); if (s == null) return false; foreach (var t in s.Value.GetProperty("tabs").EnumerateArray()) conWin = new IntPtr(t.GetProperty("window").GetInt64()); return conWin != IntPtr.Zero && Glow(s.Value) == "done"; }, 8000);
            Check("conhost 變綠、有光暈", conWin != IntPtr.Zero, $"window={conWin}");

            var (cpu0, ws0) = Measure(agent, 10);
            results.Add($"METRIC 只有光暈（沒有全螢幕）：CPU {cpu0:F2}%  working set {ws0:F1} MB");
            var mon = Screen.FromHandle(conWin).Bounds;
            uint dpi = GetDpiForWindow(conWin);
            using var form = new Form { FormBorderStyle = FormBorderStyle.None, StartPosition = FormStartPosition.Manual, Bounds = mon, BackColor = Color.FromArgb(20, 20, 20), Text = "sw42-edge-fullscreen" };
            form.Show(); Pump(300);
            Front(form.Handle); Pump(500);
            Check("自己的全螢幕視窗在最前面", GetForegroundWindow() == form.Handle, $"monitor={mon} dpi={dpi}");

            Check("全螢幕＋被蓋住的綠 → 邊緣綠", WaitEdge("done"), Edge());
            var strips = Strips(agent.Id);
            int t = (int)Math.Round(3 * dpi / 96.0) + (int)Math.Round(8 * dpi / 96.0);
            Check("四條邊、都 topmost＋click-through＋不搶焦點", strips.Count == 4 && strips.All(s => s.ok), string.Join(" ", strips.Select(s => s.desc)));
            var covered = strips.Count == 4 && strips.Any(s => s.r == new Rectangle(mon.Left, mon.Top, mon.Width, t)) && strips.Any(s => s.r == new Rectangle(mon.Left, mon.Bottom - t, mon.Width, t))
                          && strips.Any(s => s.r == new Rectangle(mon.Left, mon.Top + t, t, mon.Height - 2 * t)) && strips.Any(s => s.r == new Rectangle(mon.Right - t, mon.Top + t, t, mon.Height - 2 * t));
            Check("四條邊貼齊這個螢幕、厚度依 DPI", covered, $"thickness={t}");
            Check("邊緣畫面顏色：綠", Pixels(mon, c => c.G > 150 && c.G > c.R + 60 && c.G > c.B + 60), PixelDesc(mon));
            Check("邊緣內側是全螢幕視窗本身（線很細）", Inner(mon, t), "");
            Check("點得穿：邊上那一點的視窗是全螢幕視窗", WindowFromPoint(new POINT { X = mon.Left + mon.Width / 2, Y = mon.Top + 1 }) == form.Handle, "");
            Check("邊緣出現沒有搶走焦點", GetForegroundWindow() == form.Handle, "");

            var (cpu, ws) = Measure(agent, 10);
            Check("邊緣亮著時 agent 閒置 CPU < 1%", cpu < 1.0, $"{cpu:F2}%");
            Check("邊緣亮著時 working set < 60 MB", ws < 60, $"{ws:F1} MB");

            Emit("input");
            Check("紅 → 邊緣紅", WaitEdge("input") && Pixels(mon, c => c.R > 150 && c.R > c.G + 60), PixelDesc(mon));
            Emit("working");
            Check("紫不上邊緣", WaitEdge("idle") && Strips(agent.Id).Count == 0, Edge());
            Emit("done");
            Check("再變綠 → 邊緣回來", WaitEdge("done"), Edge());

            form.Bounds = new Rectangle(mon.Left, mon.Top, mon.Width, mon.Height - 1); Pump(400);
            Check("差 1 px 不算全螢幕 → 邊緣收起", WaitEdge("idle"), Edge());
            form.Bounds = mon; Pump(400);
            Check("回到全螢幕 → 邊緣回來（位置變化事件）", WaitEdge("done"), Edge());

            form.FormBorderStyle = FormBorderStyle.Sizable; form.WindowState = FormWindowState.Maximized; Pump(600);
            Check("有標題列的最大化視窗不算全螢幕", WaitEdge("idle"), Edge());
            form.WindowState = FormWindowState.Normal; form.FormBorderStyle = FormBorderStyle.None; form.Bounds = mon; Pump(400);
            Check("無框全螢幕 → 邊緣回來", WaitEdge("done"), Edge());

            Front(conWin); Pump(500);
            Check("前景換成非全螢幕視窗 → 邊緣收起", WaitEdge("idle"), Edge());
            Front(form.Handle); Pump(400);
            Check("前景回到全螢幕 → 邊緣回來（前景事件）", WaitEdge("done"), Edge());
            Emit("clear");
            Check("沒有光暈了 → 邊緣收起", WaitEdge("idle"), Edge());
            form.Close();
        }
        catch (Exception e) { Check("例外", false, e.ToString()); }
        finally
        {
            try { if (cmdPid != 0) Process.GetProcessById(cmdPid).Kill(); } catch { }
            try { con?.Kill(); } catch { }
            try { agent?.Kill(); } catch { }
            Thread.Sleep(800);
        }
        var after = Windows(mine);
        var moved = before.Where(kv => after.TryGetValue(kv.Key, out var v) && v != kv.Value).Select(kv => $"{kv.Key}:{kv.Value}→{after[kv.Key]}").ToList();
        Check("其他視窗位置／大小／最小化都沒變", moved.Count == 0, $"compared={before.Keys.Count(after.ContainsKey)} changed=[{string.Join(" ", moved)}]");
        results.Add($"TOTAL {pass}/{pass + fail}  work={work}");
        File.WriteAllLines(outFile, results);
        return fail == 0 ? 0 : 1;
    }

    static void Check(string name, bool ok, string detail) { if (ok) pass++; else fail++; results.Add($"{(ok ? "PASS" : "FAIL")} {name}  {detail}"); }

    static void Pump(int ms) { var sw = Stopwatch.StartNew(); while (sw.ElapsedMilliseconds < ms) { Application.DoEvents(); Thread.Sleep(15); } }
    static bool Wait(Func<bool> f, int ms) { var sw = Stopwatch.StartNew(); while (sw.ElapsedMilliseconds < ms) { if (f()) return true; Pump(50); } return f(); }

    static JsonElement? Status()
    {
        try { return JsonDocument.Parse(File.ReadAllText(status)).RootElement.Clone(); } catch { return null; }
    }
    static string Glow(JsonElement s) { foreach (var g in s.GetProperty("glows").EnumerateArray()) return g.GetProperty("state").GetString()!; return ""; }
    static string Edge() => Status() is { } s && s.TryGetProperty("edge", out var e) ? e.GetString()! : "?";
    static bool WaitEdge(string want) { var ok = Wait(() => Edge() == want, 3000); Pump(150); return ok; }

    static void Front(IntPtr h) { mouse_event(1, 0, 0, 0, UIntPtr.Zero); SetForegroundWindow(h); }

    /// The agent's visible topmost layered windows = the edge strips (the glow itself is not topmost).
    static List<(Rectangle r, bool ok, string desc)> Strips(int agentPid)
    {
        var l = new List<(Rectangle, bool, string)>();
        EnumWindows((h, _) =>
        {
            GetWindowThreadProcessId(h, out var pid);
            if (pid != agentPid || !IsWindowVisible(h)) return true;
            int ex = GetWindowLong(h, -20);
            if ((ex & 0x8) == 0) return true;
            GetWindowRect(h, out var r);
            bool ok = (ex & 0x80000) != 0 && (ex & 0x20) != 0 && (ex & 0x8000000) != 0;
            l.Add((Rectangle.FromLTRB(r.L, r.T, r.R, r.B), ok, $"[{r.L},{r.T},{r.R},{r.B} ex={ex:X}]"));
            return true;
        }, IntPtr.Zero);
        return l;
    }

    /// Only 4 tiny squares right at the monitor's edges, looked at in memory, never saved.
    static IEnumerable<Color> EdgeSamples(Rectangle m)
    {
        foreach (var p in new[] { new Point(m.Left + m.Width / 2, m.Top), new Point(m.Left + m.Width / 2, m.Bottom - 2), new Point(m.Left, m.Top + m.Height / 2), new Point(m.Right - 2, m.Top + m.Height / 2) })
        {
            using var b = new Bitmap(2, 2);
            using (var g = Graphics.FromImage(b)) g.CopyFromScreen(p, Point.Empty, b.Size);
            yield return b.GetPixel(0, 0);
        }
    }
    static bool Pixels(Rectangle m, Func<Color, bool> ok) => EdgeSamples(m).All(ok);
    static string PixelDesc(Rectangle m) => string.Join(" ", EdgeSamples(m).Select(c => $"({c.R},{c.G},{c.B})"));
    static bool Inner(Rectangle m, int t)
    {
        using var b = new Bitmap(1, 1);
        using (var g = Graphics.FromImage(b)) g.CopyFromScreen(new Point(m.Left + m.Width / 2, m.Top + t + 4), Point.Empty, b.Size);
        var c = b.GetPixel(0, 0);
        return Math.Abs(c.R - 20) < 6 && Math.Abs(c.G - 20) < 6 && Math.Abs(c.B - 20) < 6;
    }

    static (double cpu, double wsMb) Measure(Process p, int seconds)
    {
        p.Refresh(); var c0 = p.TotalProcessorTime; var sw = Stopwatch.StartNew();
        Pump(seconds * 1000);
        p.Refresh();
        return ((p.TotalProcessorTime - c0).TotalMilliseconds / sw.Elapsed.TotalMilliseconds / Environment.ProcessorCount * 100, p.WorkingSet64 / 1048576.0);
    }

    static Dictionary<IntPtr, string> Windows(HashSet<int> skip)
    {
        var d = new Dictionary<IntPtr, string>();
        EnumWindows((h, _) =>
        {
            GetWindowThreadProcessId(h, out var pid);
            if (skip.Contains((int)pid) || !IsWindowVisible(h)) return true;
            GetWindowRect(h, out var r);
            d[h] = $"{r.L},{r.T},{r.R},{r.B}{(IsIconic(h) ? " min" : "")}";
            return true;
        }, IntPtr.Zero);
        return d;
    }

    static int ChildOf(int parent, string exe)
    {
        var snap = CreateToolhelp32Snapshot(2, 0);
        try
        {
            var e = new PROCESSENTRY32W { dwSize = (uint)Marshal.SizeOf<PROCESSENTRY32W>() };
            for (bool ok = Process32FirstW(snap, ref e); ok; ok = Process32NextW(snap, ref e))
                if (e.th32ParentProcessID == parent && e.szExeFile.Equals(exe, StringComparison.OrdinalIgnoreCase)) return (int)e.th32ProcessID;
        }
        finally { CloseHandle(snap); }
        return 0;
    }

    [StructLayout(LayoutKind.Sequential)] struct RECT { public int L, T, R, B; }
    [StructLayout(LayoutKind.Sequential)] struct POINT { public int X, Y; }
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct PROCESSENTRY32W
    {
        public uint dwSize, cntUsage, th32ProcessID; public IntPtr th32DefaultHeapID; public uint th32ModuleID, cntThreads, th32ParentProcessID;
        public int pcPriClassBase; public uint dwFlags; [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 260)] public string szExeFile;
    }
    delegate bool EnumProc(IntPtr h, IntPtr l);
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc cb, IntPtr l);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] static extern bool IsIconic(IntPtr h);
    [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] static extern int GetWindowLong(IntPtr h, int i);
    [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] static extern IntPtr WindowFromPoint(POINT p);
    [DllImport("user32.dll")] static extern uint GetDpiForWindow(IntPtr h);
    [DllImport("user32.dll")] static extern void mouse_event(uint f, int x, int y, uint d, UIntPtr e);
    [DllImport("kernel32.dll")] static extern IntPtr CreateToolhelp32Snapshot(uint f, uint pid);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] static extern bool Process32FirstW(IntPtr s, ref PROCESSENTRY32W e);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] static extern bool Process32NextW(IntPtr s, ref PROCESSENTRY32W e);
    [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);
}
