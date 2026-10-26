// showork.exe — the tiny command every adapter (Claude Code hook) calls.
//   showork emit <working|done|input|clear> [--agent claude] [--pid N]
//   showork console <pid> [<pid>…]      (for the agent) print "pid<TAB>console hwnd<TAB>console title" per pid
//
// Contract with the AI tools that call us (hooks): this must NEVER slow them down or fail them.
//   • always exits 0, prints nothing on success
//   • gives up after 200 ms if the agent isn't there (a missing pipe returns at once)
//   • never reads stdin (hook JSON may be large; we don't need it)
using System.Runtime.InteropServices;
using System.Text;
using ShoWork;

static class Cli
{
    static readonly long started = Environment.TickCount64;

    static int Main(string[] args)
    {
        try
        {
            if (args.Length >= 2 && args[0] == "emit") Emit(args);
            else if (args.Length >= 2 && args[0] == "console") return Consoles(args);
        }
        catch { }                            // a hook must never fail Claude
        return 0;
    }

    static void Emit(string[] args)
    {
        // hard deadline, whatever happens below (slow disk, scheduler, a wedged pipe write)
        new Thread(() => { Thread.Sleep(190); ExitProcess(0); }) { IsBackground = true }.Start();

        var ev = args[1];
        if (Array.IndexOf(Wire.Events, ev) < 0) return;
        string agent = "generic";
        int pid = 0;
        for (int i = 2; i + 1 < args.Length; i += 2)
        {
            if (args[i] == "--agent") agent = args[i + 1];
            else if (args[i] == "--pid") int.TryParse(args[i + 1], out pid);
        }
        if (!Wire.ValidAgent(agent)) return;
        long stamp = 0;
        if (pid <= 0) (pid, stamp) = FindAI(agent);
        if (pid <= 0) return;                // not under an AI we know: nothing to light up

        var line = Encoding.UTF8.GetBytes($"{{\"v\":1,\"event\":\"{ev}\",\"agent\":\"{agent}\",\"pid\":{pid},\"t\":{stamp}}}\n");
        var path = @"\\.\pipe\" + Wire.PipeName(UserSid());
        for (int attempt = 0; attempt < 2; attempt++)
        {
            // SECURITY_IDENTIFICATION: whoever owns the pipe can't impersonate us
            var h = CreateFileW(path, GENERIC_WRITE, 0, IntPtr.Zero, OPEN_EXISTING, SECURITY_SQOS_PRESENT | SECURITY_IDENTIFICATION, IntPtr.Zero);
            if (h != INVALID_HANDLE_VALUE)
            {
                WriteFile(h, line, line.Length, out _, IntPtr.Zero);
                CloseHandle(h);
                return;
            }
            if (Marshal.GetLastWin32Error() != ERROR_PIPE_BUSY) return;     // no agent running: fine
            var left = 180 - (int)(Environment.TickCount64 - started);
            if (left <= 0 || !WaitNamedPipeW(path, (uint)left)) return;
        }
    }

    /// Walk up from our parent (Git Bash → … → claude.exe) to the AI process. Also returns when the AI
    /// started this hook: the creation time of the process it spawned for it (the hook shell). Async hooks
    /// can arrive out of order; the agent drops anything older than what it already has.
    static (int pid, long stamp) FindAI(string agent)
    {
        var exe = agent switch { "claude" => "claude.exe", _ => null };
        if (exe == null) return (0, 0);
        var procs = Snapshot();
        int me = Environment.ProcessId;
        if (!procs.TryGetValue(me, out var cur)) return (0, 0);
        int child = me;
        for (int hop = 0; hop < 16; hop++)
        {
            int p = cur.ppid;
            if (p <= 4 || !procs.TryGetValue(p, out var parent)) return (0, 0);
            // a dead parent's pid can be reused by a younger process: a real parent is older than its child
            if (!OlderThan(p, child)) return (0, 0);
            if (parent.exe.Equals(exe, StringComparison.OrdinalIgnoreCase)) return (p, CreationTime(child));
            child = p;
            cur = parent;
        }
        return (0, 0);
    }

    static Dictionary<int, (int ppid, string exe)> Snapshot()
    {
        var d = new Dictionary<int, (int, string)>();
        var snap = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
        if (snap == INVALID_HANDLE_VALUE) return d;
        try
        {
            var e = new PROCESSENTRY32W { dwSize = (uint)Marshal.SizeOf<PROCESSENTRY32W>() };
            for (bool ok = Process32FirstW(snap, ref e); ok; ok = Process32NextW(snap, ref e))
                d[(int)e.th32ProcessID] = ((int)e.th32ParentProcessID, e.szExeFile);
        }
        finally { CloseHandle(snap); }
        return d;
    }

    static bool OlderThan(int a, int b)
    {
        long ta = CreationTime(a), tb = CreationTime(b);
        return ta != 0 && tb != 0 && ta <= tb;
    }

    static long CreationTime(int pid)
    {
        var h = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, false, (uint)pid);
        if (h == IntPtr.Zero) return 0;
        try { return GetProcessTimes(h, out var c, out _, out _, out _) ? c : 0; }
        finally { CloseHandle(h); }
    }

    static string UserSid()
    {
        if (!OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, out var tok)) return "unknown";
        try
        {
            GetTokenInformation(tok, 1 /*TokenUser*/, IntPtr.Zero, 0, out int len);
            var buf = Marshal.AllocHGlobal(len);
            try
            {
                if (!GetTokenInformation(tok, 1, buf, len, out _)) return "unknown";
                if (!ConvertSidToStringSidW(Marshal.ReadIntPtr(buf), out var s)) return "unknown";
                var sid = Marshal.PtrToStringUni(s)!;
                LocalFree(s);
                return sid;
            }
            finally { Marshal.FreeHGlobal(buf); }
        }
        finally { CloseHandle(tok); }
    }

    /// Runs as a short-lived helper of the agent: attaching to someone else's console is only safe in a
    /// throwaway process (a Ctrl+C or a closed tab while attached would kill the attached process).
    /// In a classic console the hwnd is the window itself; in Windows Terminal it is ConPTY's hidden
    /// PseudoConsoleWindow, whose owner is the WT window currently holding that tab.
    static int Consoles(string[] args)
    {
        var outH = GetStdHandle(STD_OUTPUT_HANDLE);           // the agent's pipe; grab it before switching consoles
        var sb = new StringBuilder();
        SetConsoleCtrlHandler(IntPtr.Zero, true);
        for (int i = 1; i < args.Length; i++)
        {
            if (!uint.TryParse(args[i], out var pid)) continue;
            FreeConsole();
            long hwnd = 0; string title = "";
            if (AttachConsole(pid))
            {
                hwnd = GetConsoleWindow().ToInt64();
                var t = new StringBuilder(1024);
                GetConsoleTitleW(t, t.Capacity);
                title = t.ToString().Replace('\t', ' ').Replace('\n', ' ').Replace('\r', ' ');
                FreeConsole();
            }
            sb.Append(pid).Append('\t').Append(hwnd).Append('\t').Append(title).Append('\n');
        }
        var bytes = Encoding.UTF8.GetBytes(sb.ToString());
        WriteFile(outH, bytes, bytes.Length, out _, IntPtr.Zero);
        return 0;
    }

    const uint GENERIC_WRITE = 0x40000000, OPEN_EXISTING = 3, SECURITY_SQOS_PRESENT = 0x00100000, SECURITY_IDENTIFICATION = 0x00010000;
    const int ERROR_PIPE_BUSY = 231;
    const uint TH32CS_SNAPPROCESS = 2, PROCESS_QUERY_LIMITED_INFORMATION = 0x1000, TOKEN_QUERY = 8;
    const int STD_OUTPUT_HANDLE = -11;
    static readonly IntPtr INVALID_HANDLE_VALUE = new(-1);

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct PROCESSENTRY32W
    {
        public uint dwSize, cntUsage, th32ProcessID; public IntPtr th32DefaultHeapID; public uint th32ModuleID, cntThreads, th32ParentProcessID;
        public int pcPriClassBase; public uint dwFlags;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 260)] public string szExeFile;
    }

    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern IntPtr CreateFileW(string name, uint access, uint share, IntPtr sa, uint disposition, uint flags, IntPtr template);
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)] static extern bool WaitNamedPipeW(string name, uint ms);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool WriteFile(IntPtr h, byte[] buf, int n, out int written, IntPtr ov);
    [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);
    [DllImport("kernel32.dll")] static extern void ExitProcess(uint code);
    [DllImport("kernel32.dll", SetLastError = true)] static extern IntPtr CreateToolhelp32Snapshot(uint flags, uint pid);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] static extern bool Process32FirstW(IntPtr snap, ref PROCESSENTRY32W e);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] static extern bool Process32NextW(IntPtr snap, ref PROCESSENTRY32W e);
    [DllImport("kernel32.dll")] static extern IntPtr OpenProcess(uint access, bool inherit, uint pid);
    [DllImport("kernel32.dll")] static extern bool GetProcessTimes(IntPtr h, out long creation, out long exit, out long kernel, out long user);
    [DllImport("kernel32.dll")] static extern IntPtr GetCurrentProcess();
    [DllImport("advapi32.dll")] static extern bool OpenProcessToken(IntPtr process, uint access, out IntPtr token);
    [DllImport("advapi32.dll")] static extern bool GetTokenInformation(IntPtr token, int cls, IntPtr buf, int len, out int needed);
    [DllImport("advapi32.dll", CharSet = CharSet.Unicode)] static extern bool ConvertSidToStringSidW(IntPtr sid, out IntPtr str);
    [DllImport("kernel32.dll")] static extern IntPtr LocalFree(IntPtr p);
    [DllImport("kernel32.dll")] static extern IntPtr GetStdHandle(int which);
    [DllImport("kernel32.dll")] static extern bool FreeConsole();
    [DllImport("kernel32.dll")] static extern bool AttachConsole(uint pid);
    [DllImport("kernel32.dll")] static extern IntPtr GetConsoleWindow();
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] static extern int GetConsoleTitleW(StringBuilder title, int size);
    [DllImport("kernel32.dll")] static extern bool SetConsoleCtrlHandler(IntPtr handler, bool add);
}
