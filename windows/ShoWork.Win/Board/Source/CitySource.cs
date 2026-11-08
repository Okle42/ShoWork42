using System.Diagnostics;
using System.Net.Sockets;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace ShoWork;

// Mac 版 Sources/ShoWorkAgent/CitySource.swift（CityMonitor）的 Windows 轉寫（11-02 P8）。全部在背景跑，不新增常駐 Timer：
//   掛在看板既有的刷新上（BoardForm 的 refresh 叫 tick()），每一類自己比時間決定要不要做：
//     cool42 狀態檔   每次 tick（Windows 沒有 cool42 ⇒ 永遠讀不到；SHOWORK_COOL42_STATE 指一個檔可以測）
//     磁碟            每 60 秒（DriveInfo；Mac：URLResourceKey＋掛載通知。Windows 沒接 WM_DEVICECHANGE，插拔最慢 60 秒才看到）
//     ssh 伺服器      每 60 秒對每個 Host 的 22 埠（或 config 寫的 Port）做一次 2 秒逾時的 TCP connect（只連一個埠，不掃描）
//     GitHub 港口     每 60 秒 stat 各 repo 的 .git/refs/remotes/origin 底下的檔案＋packed-refs 的 mtime（FETCH_HEAD 分進港／出港）
//     雲端            每 5 分鐘：OneDrive／Google Drive／iCloud for Windows／Dropbox／Box 的同步資料夾在不在（＋系統登記的同步根目錄）。
//                     同步進度一般程式讀不到（Windows 的 Cloud Files API 沒給整體狀態；iCloud 沒有 brctl）⇒ sync 一律 nil，名牌只寫「已連線」
//     防火牆＋城門    每 5 分鐘跑 netsh advfirewall show allprofiles state、netstat -ano -p TCP／TCPv6（都不用系統管理員權限）
//     電廠（額度）    每次 tick 讀 %USERPROFILE%\.claude\cache\rate_limits.json（Mac 的 statusLine 腳本存的；Windows 的 statusLine 沒在存就讀不到）
//   結果組成 CityState，跟上次不一樣才發布（Changed 事件；畫面沒變就不重推）。
// 測試：SHOWORK_CITY_DEMO=1 換成示範值（含各種警示）；SHOWORK_CITY=off 整個不收、不畫；SHOWORK_SSH_CONFIG 換 ssh config；SHOWORK_REPOS 換 repo 資料夾。
// Windows 的 repo 在哪（11-02 Surface 調查）：沒有 ~/github-repos，repo 直接放在家目錄底下（C:\Users\<名>\ShoWork42、wall42）。
//   ⇒ 依序看 SHOWORK_REPOS、~/github-repos、~/source/repos（Visual Studio 預設）、~/Documents/GitHub（GitHub Desktop 預設）、~/repos、家目錄本身，
//     每個根目錄只看第一層、.git 是資料夾才算（worktree 的 .git 是檔案，不算），同名只算一次。

public static class CityPaths
{
    public static string home => BoardReader.DefaultHome;
    public static string sshConfig => Environment.GetEnvironmentVariable("SHOWORK_SSH_CONFIG") is { Length: > 0 } p ? p : Path.Combine(home, ".ssh", "config");
    public static string claude => BoardReader.DefaultClaudeDir;
    /// 港口／常駐部門看的 repo 根目錄（見檔頭）
    public static List<string> repoRoots()
    {
        var env = Environment.GetEnvironmentVariable("SHOWORK_REPOS");
        if (!string.IsNullOrEmpty(env)) return env.Split(Path.PathSeparator, StringSplitOptions.RemoveEmptyEntries).ToList();
        var h = home;
        return new[] { Path.Combine(h, "github-repos"), Path.Combine(h, "source", "repos"), Path.Combine(h, "Documents", "GitHub"), Path.Combine(h, "repos"), h }
            .Where(Directory.Exists).ToList();
    }
    /// 第一層的 git repo：名稱 → 路徑（同名留第一個根目錄的；符號連結／目錄連接不碰：不為了看 mtime 去喚醒外接碟）
    public static Dictionary<string, string> repos()
    {
        var out_ = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        foreach (var root in repoRoots())
        {
            IEnumerable<DirectoryInfo> dirs;
            try { dirs = new DirectoryInfo(root).EnumerateDirectories().ToList(); } catch { continue; }
            foreach (var d in dirs)
            {
                if (d.Name.StartsWith('.') || out_.ContainsKey(d.Name)) continue;
                try { if (d.Attributes.HasFlag(FileAttributes.ReparsePoint)) continue; } catch { continue; }
                if (Directory.Exists(Path.Combine(d.FullName, ".git"))) out_[d.Name] = d.FullName;
            }
        }
        return out_;
    }
}

public sealed class CityMonitor
{
    public static readonly CityMonitor shared = new();
    public static bool off => Environment.GetEnvironmentVariable("SHOWORK_CITY") == "off";
    public static bool demo => Environment.GetEnvironmentVariable("SHOWORK_CITY_DEMO") != null;
    static bool trace => Environment.GetEnvironmentVariable("SHOWORK_CITY_TRACE") != null;
    /// --board-window 測試視窗不寫回設定
    public static bool testWindow { get; set; }
    static readonly DateTime demoShipAt = DateTime.UtcNow;
    static string prefsPath => Path.Combine(Wire.SupportDir, "city.json");     // Mac：UserDefaults city.knownDisks／city.diskSeen

    readonly object gate = new();
    CityState state = new();
    DateTime lastDisk = DateTime.MinValue, lastServer = DateTime.MinValue, lastPort = DateTime.MinValue, lastCloud = DateTime.MinValue, lastWall = DateTime.MinValue;
    Dictionary<string, DateTime> refs = new();
    List<string> known = new();
    Dictionary<string, DateTime> seen = new();
    CityState latestState = new();
    bool started, publishedOnce, busy;
    List<string> lastMounted = new();

    /// 懸停卡要的最新細節（含不發布的：伺服器延遲、檢查時間）
    public CityState latest { get { lock (gate) return latestState; } }
    /// 發布的版本（內容變了才換）
    public CityState current { get { lock (gate) return state; } }
    /// 發布了新的 CityState（背景執行緒叫）
    public event Action<CityState>? Changed;

    /// 看板 refresh 叫：每一類自己比時間；跑完有變才發布。同一時間只跑一輪（上一輪還沒跑完就跳過）
    public void tick(bool force = false)
    {
        if (off) return;
        lock (gate) { if (busy) return; busy = true; }
        Task.Run(() =>
        {
            try { run(force); }
            catch (Exception x) { Log.Note($"CITY tick failed {x.GetType().Name} {x.Message}"); }
            finally { lock (gate) busy = false; }
        });
    }

    /// 同步跑一輪（--city-dump 用；伺服器也等它連完）
    public CityState runOnce()
    {
        run(true, waitServers: true);
        return latest;
    }

    void run(bool force, bool waitServers = false)
    {
        if (!started)
        {
            started = true;
            loadPrefs();
        }
        if (demo) { var d = demoState(); setLatest(d); publish(d); return; }
        var now = DateTime.UtcNow;
        CityState s; lock (gate) s = state.Copy();
        s.Power = power(s.Power, now);
        s.Grid = grid(s.Grid, now);
        if (force || now - lastDisk >= TimeSpan.FromSeconds(60)) { lastDisk = now; s.Disks = disks(); }
        if (force || now - lastCloud >= TimeSpan.FromMinutes(5)) { lastCloud = now; s.Clouds = clouds(now); }
        if (force || now - lastWall >= TimeSpan.FromMinutes(5)) { lastWall = now; s.Firewall = firewall(now); }
        if (force || now - lastPort >= TimeSpan.FromSeconds(60))
        {
            lastPort = now;
            var sw = Stopwatch.StartNew();
            s = port(s, now);
            if (trace) Console.WriteLine($"city port scan {sw.ElapsedMilliseconds} ms repos={s.Repos}");
        }
        // 船只留 30 秒（夠畫面看到一次）
        s.Ships.RemoveAll(x => (now - x.At).TotalSeconds > 30);
        publish(s);
        if (force || now - lastServer >= TimeSpan.FromSeconds(60))
        {
            lastServer = now;
            var t = checkServers(now);
            if (waitServers) t.Wait(TimeSpan.FromSeconds(10));
        }
    }

    void setLatest(CityState s) { lock (gate) latestState = s; }

    void publish(CityState s)
    {
        setLatest(s);
        lock (gate)
        {
            if (s.Same(state) && publishedOnce) return;
            publishedOnce = true;
            state = s;
        }
        if (trace) Console.WriteLine($"city publish disks={s.Disks.Count} clouds={s.Clouds.Count} servers={string.Join(",", s.Servers.Select(x => $"{x.Alias}:{(x.Online == null ? "?" : x.Online.Value ? "on" : "off")}"))} fw={s.Firewall.Enabled?.ToString() ?? "?"} ports={s.Firewall.Ports.Count} ships={string.Join(",", s.Ships.Select(x => x.Repo))} alerts={s.alerts.Count}");
        Changed?.Invoke(s);
    }

    // MARK: 設定（拔掉的外接碟名單、最後看到的時間）

    void loadPrefs()
    {
        try
        {
            if (!File.Exists(prefsPath) || JsonNode.Parse(File.ReadAllText(prefsPath)) is not JsonObject o) return;
            known = (o["knownDisks"] as JsonArray)?.Select(x => x?.ToString() ?? "").Where(x => x.Length > 0).ToList() ?? new();
            if (o["diskSeen"] is JsonObject ds)
                foreach (var (k, v) in ds) if (v is JsonValue jv && jv.TryGetValue<double>(out var t)) seen[k] = MacMirror.FromSeconds(t);
        }
        catch { }
    }
    void savePrefs()
    {
        if (testWindow) return;      // 測試視窗不寫回你的設定
        try
        {
            var o = new JsonObject { ["knownDisks"] = new JsonArray(known.Select(k => (JsonNode?)k).ToArray()),
                                     ["diskSeen"] = new JsonObject(seen.Select(kv => KeyValuePair.Create(kv.Key, (JsonNode?)MacMirror.Seconds(kv.Value)))) };
            Directory.CreateDirectory(Path.GetDirectoryName(prefsPath)!);
            var tmp = prefsPath + $".{Environment.ProcessId}.tmp";
            File.WriteAllText(tmp, o.ToJsonString());
            File.Move(tmp, prefsPath, overwrite: true);
        }
        catch { }
    }

    // MARK: 電廠（cool42：Windows 沒有）

    CityPower power(CityPower old, DateTime now)
    {
        string? text = null;
        if (Environment.GetEnvironmentVariable("SHOWORK_COOL42_STATE") is { Length: > 0 } p) { try { text = File.ReadAllText(p); } catch { } }
        var pw = CityParse.cool42(text, now);
        return CityRules.powerChanged(old, pw) ? pw : old;
    }

    // MARK: 電廠＝AI 額度（statusLine 存的 rate_limits.json；每次 tick 讀一個小檔，換格才算變）
    // 測試：SHOWORK_CITY_GRID=dim|flicker|blackout 換成假數字

    CityGrid grid(CityGrid old, DateTime now)
    {
        var g = fakeGrid(now) ?? CityRules.grid(rateLimits(), now);
        return CityRules.gridChanged(old, g) ? g : old;
    }

    public static RateLimits? rateLimits()
    {
        var path = Environment.GetEnvironmentVariable("SHOWORK_RATE_LIMITS") is { Length: > 0 } x ? x : Path.Combine(CityPaths.claude, "cache", "rate_limits.json");
        try { return File.Exists(path) ? RateLimits.Parse(File.ReadAllText(path)) : null; } catch { return null; }
    }

    public static CityGrid? fakeGrid(DateTime now)
    {
        if (Environment.GetEnvironmentVariable("SHOWORK_CITY_GRID") is not { } v) return null;
        double five = v switch { "dim" => 86, "flicker" => 97, "blackout" => 100, _ => 40 };
        var r = new RateLimits { FiveHour = new RateLimits.Window(five, now.AddMinutes(80)), SevenDay = new RateLimits.Window(58, now.AddDays(3)) };
        return CityRules.grid(r, now);
    }

    // MARK: 磁碟（DriveInfo，不跑 wmic）

    List<CityDisk> disks()
    {
        var out_ = new List<CityDisk>();
        var sys = Path.GetPathRoot(Environment.SystemDirectory) ?? "C:\\";
        var mounted = new List<string>();
        DriveInfo[] all;
        try { all = DriveInfo.GetDrives(); } catch { all = Array.Empty<DriveInfo>(); }
        foreach (var d in all)
        {
            bool isSys = string.Equals(d.Name, sys, StringComparison.OrdinalIgnoreCase);
            if (!OperatingSystem.IsWindows() && !isSys && d.Name != "/") { if (!d.Name.StartsWith("/Volumes/")) continue; }
            if (d.DriveType is DriveType.CDRom or DriveType.Ram or DriveType.NoRootDirectory or DriveType.Unknown) continue;
            bool ready; try { ready = d.IsReady; } catch { ready = false; }
            if (!ready) continue;
            bool isInt = isSys || (!OperatingSystem.IsWindows() && d.Name == "/");
            string label = ""; try { label = d.VolumeLabel; } catch { }
            var name = isInt ? "Data" : label.Length > 0 ? label : d.Name.TrimEnd('\\', '/');
            try
            {
                long plain = d.TotalFreeSpace;
                // Windows 的 AvailableFreeSpace＝這個使用者能用的（有配額時比 TotalFreeSpace 小）≈ Mac 的「重要用途可用」
                out_.Add(new CityDisk(name, isInt, total: d.TotalSize, available: CityParse.available(d.AvailableFreeSpace, plain), availablePlain: plain,
                                      format: d.DriveFormat, mountPath: d.Name));
            }
            catch { out_.Add(new CityDisk(name, isInt, mountPath: d.Name)); }
            if (!isInt) mounted.Add(name);
        }
        // 內建碟排第一（Mac：根目錄先放）
        out_ = out_.OrderBy(x => x.IsInternal ? 0 : 1).ToList();
        // 最後看到的時間：插著的每次更新（記憶體），插拔名單變了才寫回設定（不每分鐘寫）
        foreach (var n in mounted) seen[n] = DateTime.UtcNow;
        bool dirty = !lastMounted.SequenceEqual(mounted);
        lastMounted = mounted;
        var merged = CityParse.rememberDisks(known, mounted);
        if (!merged.SequenceEqual(known)) { known = merged; dirty = true; }
        if (dirty) savePrefs();
        // 拔掉的外接碟不再留一座拉下鐵捲門的堆場（11-01 Kang：拔掉了就該消失）；known／seen 照記，插回來時排回原本的順序
        return out_;
    }

    // MARK: 雲端（同步資料夾在不在；同步進度讀不到）

    List<CityCloud> clouds(DateTime now)
    {
        var out_ = new List<CityCloud>();
        void add(string name, bool icloud = false) { if (!out_.Any(c => c.Name == name)) out_.Add(new CityCloud(name, icloud, null, now)); }
        var h = CityPaths.home;
        // iCloud for Windows：%USERPROFILE%\iCloudDrive（沒有 brctl：剩餘額度、同步狀態都讀不到）
        if (Directory.Exists(Path.Combine(h, "iCloudDrive"))) add("iCloud Drive", icloud: true);
        // OneDrive：環境變數（個人版、公司版各一個）＋家目錄底下 OneDrive／OneDrive - 公司
        foreach (var v in new[] { "OneDriveConsumer", "OneDriveCommercial", "OneDrive" })
            if (Environment.GetEnvironmentVariable(v) is { Length: > 0 } p && Directory.Exists(p)) { add("OneDrive"); break; }
        try { if (Directory.EnumerateDirectories(h, "OneDrive*").Any()) add("OneDrive"); } catch { }
        // Google Drive for desktop：虛擬磁碟（預設 G:，標籤 Google Drive）或舊版的 ~/Google Drive
        try
        {
            foreach (var d in DriveInfo.GetDrives())
            {
                string label = ""; try { if (d.IsReady) label = d.VolumeLabel; } catch { }
                if (label.Contains("Google Drive", StringComparison.OrdinalIgnoreCase)) add("Google Drive");
            }
        }
        catch { }
        if (Directory.Exists(Path.Combine(h, "Google Drive")) || Directory.Exists(Path.Combine(h, "My Drive"))) add("Google Drive");
        // Dropbox：%LOCALAPPDATA%\Dropbox\info.json 記著同步資料夾在哪
        var dbInfo = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Dropbox", "info.json");
        try
        {
            if (File.Exists(dbInfo) && JsonNode.Parse(File.ReadAllText(dbInfo)) is JsonObject o
                && o.Select(kv => kv.Value?["path"]?.ToString()).Any(p => p != null && Directory.Exists(p))) add("Dropbox");
        }
        catch { }
        if (Directory.Exists(Path.Combine(h, "Dropbox"))) add("Dropbox");
        if (Directory.Exists(Path.Combine(h, "Box"))) add("Box");
        // 系統登記的同步根目錄（Cloud Files API；Mac 的 ~/Library/CloudStorage 對應）：其他雲端（Synology Drive⋯）也會在這裡
        foreach (var n in syncRoots()) add(n, icloud: n == "iCloud Drive");
        return out_;
    }

    /// HKLM\…\Explorer\SyncRootManager 底下這個使用者的同步根目錄 → 顯示名（OneDrive!S-1-5-…!Personal → OneDrive）。讀不到回空的
    static List<string> syncRoots()
    {
        var out_ = new List<string>();
        if (!OperatingSystem.IsWindows()) return out_;
        try
        {
            var sid = System.Security.Principal.WindowsIdentity.GetCurrent().User?.Value ?? "";
            using var k = Microsoft.Win32.Registry.LocalMachine.OpenSubKey(@"SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\SyncRootManager");
            if (k == null) return out_;
            foreach (var name in k.GetSubKeyNames())
            {
                if (sid.Length > 0 && !name.Contains(sid, StringComparison.OrdinalIgnoreCase)) continue;
                using var sub = k.OpenSubKey(name + @"\UserSyncRoots");
                var path = sub?.GetValueNames().Select(v => sub.GetValue(v) as string).FirstOrDefault(p => p != null);
                if (path == null || !Directory.Exists(path)) continue;
                var provider = name.Split('!')[0];
                var display = provider.ToLowerInvariant() switch
                {
                    "icloud" or "iclouddrive" => "iCloud Drive",
                    _ when provider.StartsWith("iCloud", StringComparison.OrdinalIgnoreCase) => "iCloud Drive",
                    _ when provider.StartsWith("GoogleDrive", StringComparison.OrdinalIgnoreCase) || provider.StartsWith("DriveFS", StringComparison.OrdinalIgnoreCase) => "Google Drive",
                    _ => CityParse.cloudName(provider),
                };
                if (!out_.Contains(display)) out_.Add(display);
            }
        }
        catch { }
        return out_;
    }

    // MARK: 防火牆＋城門（每 5 分鐘）

    CityFirewall firewall(DateTime now)
    {
        if (!OperatingSystem.IsWindows()) return new CityFirewall(null, new(), now);
        var fw = run("netsh", "advfirewall show allprofiles state");
        var t4 = run("netstat", "-ano -p TCP");
        var t6 = run("netstat", "-ano -p TCPv6");
        var names = new Dictionary<int, string?>();
        string? name(int pid)
        {
            if (names.TryGetValue(pid, out var n)) return n;
            try { n = pid == 0 ? "System Idle" : pid == 4 ? "System" : Process.GetProcessById(pid).ProcessName; } catch { n = null; }
            names[pid] = n;
            return n;
        }
        var ports = t4 == null && t6 == null ? new List<ListenPort>() : CityParseWin.netstat((t4 ?? "") + "\n" + (t6 ?? ""), name);
        return new CityFirewall(fw == null ? null : CityParseWin.firewall(fw), ports, now);
    }

    [System.Runtime.InteropServices.DllImport("kernel32.dll")] static extern uint GetOEMCP();

    /// 跑一個系統指令（10 秒沒結束就砍）；失敗＝nil。
    /// 輸出的編碼看狀況（11-02 Surface 實測：ssh 進來時 netsh 寫 UTF-8，桌面上是系統的 OEM 字碼頁 950）⇒ 先試嚴格 UTF-8，不合法再用 OEM 字碼頁。
    /// ShoWorkAgent 是 InvariantGlobalization（CurrentCulture 的字碼頁是 437）⇒ OEM 字碼頁直接問系統
    static string? run(string exe, string args)
    {
        try
        {
            var psi = new ProcessStartInfo(exe, args) { RedirectStandardOutput = true, RedirectStandardError = true, UseShellExecute = false, CreateNoWindow = true };
            using var p = Process.Start(psi);
            if (p == null) return null;
            using var ms = new MemoryStream();
            var copy = p.StandardOutput.BaseStream.CopyToAsync(ms);
            _ = p.StandardError.ReadToEndAsync();
            if (!p.WaitForExit(10_000)) { try { p.Kill(true); } catch { } return null; }
            copy.Wait(2000);
            return decode(ms.ToArray());
        }
        catch { return null; }
    }

    public static string decode(byte[] b)
    {
        try { return new System.Text.UTF8Encoding(false, throwOnInvalidBytes: true).GetString(b); }
        catch (System.Text.DecoderFallbackException) { }
        if (OperatingSystem.IsWindows())
        {
            try
            {
                System.Text.Encoding.RegisterProvider(System.Text.CodePagesEncodingProvider.Instance);
                return System.Text.Encoding.GetEncoding((int)GetOEMCP()).GetString(b);
            }
            catch { }
        }
        return System.Text.Encoding.UTF8.GetString(b);
    }

    // MARK: 港口（GitHub）

    CityState port(CityState s0, DateTime now)
    {
        var s = s0;
        var cur = new Dictionary<string, DateTime>(); var fetched = new Dictionary<string, DateTime>();
        foreach (var (name, dir) in CityPaths.repos())
        {
            var git = Path.Combine(dir, ".git");
            DateTime? latest = null;
            void see(string p) { try { if (File.Exists(p)) { var m = File.GetLastWriteTimeUtc(p); latest = latest is { } l && l > m ? l : m; } } catch { } }
            see(Path.Combine(git, "packed-refs"));
            var origin = Path.Combine(git, "refs", "remotes", "origin");
            try { if (Directory.Exists(origin)) foreach (var f in Directory.EnumerateFiles(origin, "*", SearchOption.AllDirectories)) see(f); } catch { }
            if (latest is { } lt) cur[name] = lt;
            try { var fh = Path.Combine(git, "FETCH_HEAD"); if (File.Exists(fh)) fetched[name] = File.GetLastWriteTimeUtc(fh); } catch { }
        }
        foreach (var r in CityParse.departures(refs, cur))
            s.Ships.Add(new CityShip(r, now, CityParse.isInbound(cur.TryGetValue(r, out var c) ? c : now, fetched.TryGetValue(r, out var f) ? f : null)));
        refs = cur;
        s.Repos = cur.Count;
        s.Recent = cur.OrderByDescending(kv => kv.Value).Take(5).Select(kv => new CityShip(kv.Key, kv.Value)).ToList();
        return s;
    }

    // MARK: ssh 伺服器（每 60 秒一個埠的 TCP connect，2 秒逾時）

    Task checkServers(DateTime now)
    {
        string text = "";
        try { if (File.Exists(CityPaths.sshConfig)) text = File.ReadAllText(CityPaths.sshConfig); } catch { }
        var hosts = CityParse.sshHosts(text);
        // 名單變了（新增／刪掉 Host）先發布「檢查中」
        CityState s; lock (gate) s = state.Copy();
        var old = s.Servers.GroupBy(x => x.Alias).ToDictionary(g => g.Key, g => g.First());
        s.Servers = hosts.Select(h =>
        {
            var v = old.TryGetValue(h.Alias, out var o) ? o with { } : new CityServer(h.Alias);
            v.HostName = h.HostName; v.Port = h.Port;
            return v;
        }).ToList();
        publish(s);
        return Task.WhenAll(hosts.Select(async h =>
        {
            var sw = Stopwatch.StartNew();
            bool ok = await probe(h.HostName, h.Port);
            int ms = (int)sw.ElapsedMilliseconds;
            CityState s2;
            lock (gate)
            {
                s2 = state.Copy();
                int i = s2.Servers.FindIndex(x => x.Alias == h.Alias);
                if (i < 0) return;
                var at = DateTime.UtcNow;
                bool same = state.Servers[i].Online == ok;
                s2.Servers[i].Online = ok;
                s2.Servers[i].CheckedAt = at;
                if (ok) { s2.Servers[i].LastOnline = at; s2.Servers[i].LatencyMs = ms; }
                // 檢查時間、延遲不算「畫面要變」：只有在線／離線變了才發布；懸停卡讀 latest 拿得到
                if (same) { state = s2; latestState = s2; return; }
            }
            publish(s2);
        }));
    }

    /// 單埠 TCP connect：連上＝在線；2 秒內沒連上或被拒＝離線。只建連線、立刻關，不傳任何資料
    static async Task<bool> probe(string host, int port)
    {
        if (port <= 0 || port > 65535) return false;
        try
        {
            using var c = new TcpClient();
            using var cts = new CancellationTokenSource(TimeSpan.FromSeconds(2));
            await c.ConnectAsync(host, port, cts.Token);
            return c.Connected;
        }
        catch { return false; }
    }

    // MARK: 示範值（SHOWORK_CITY_DEMO=1；名字、數字都是假的）

    public static CityState demoState(DateTime? at = null)
    {
        var t = at ?? demoShipAt;
        var s = new CityState { Demo = true };
        long g = 1_000_000_000;
        s.Disks = new()
        {
            new CityDisk("Data", true, total: 245 * g, available: 13 * g, availablePlain: 11 * g, format: "APFS", mountPath: "/"),
            new CityDisk("DEMO-SD", false, total: 128 * g, available: 35 * g, availablePlain: 35 * g, format: "APFS", mountPath: "/Volumes/DEMO-SD"),
            new CityDisk("DEMO-USB", false, total: 64 * g, available: 3 * g, availablePlain: 3 * g, format: "MS-DOS (FAT32)", mountPath: "/Volumes/DEMO-USB"),
        };
        s.Clouds = new()
        {
            new CityCloud("iCloud Drive", true, new CloudSync { Remaining = 92 * g, DriveState = "idle", LastSync = t.AddSeconds(-300), CaughtUp = true, Pending = 0, Blocked = 0, DesktopDocs = true }, t),
            new CityCloud("Google Drive", checkedAt: t),
        };
        s.Servers = new()
        {
            new CityServer("demo-server", true, t, t, 12, "demo-server.local", 22),
            new CityServer("demo-nas", false, t, t.AddHours(-3), 4, "192.0.2.10", 22),
        };
        s.Recent = new() { new CityShip("demo-app", t.AddSeconds(-120)), new CityShip("demo-site", t.AddSeconds(-5400)) };
        s.Firewall = new CityFirewall(Environment.GetEnvironmentVariable("SHOWORK_CITY_DEMO") == "calm", new()
        {
            new(4242, "demo-local", false), new(5037, "demo-adb", false), new(6463, "demo-chat", false),
            new(5000, "demo-airplay", true), new(7000, "demo-airplay", true), new(8766, "demo-screen", true),
            new(9888, "demo-audio", true, "audio-bridge"),
        }, t);
        s.Power = new CityPower(92, 81, "hot");
        s.Grid = fakeGrid(t) ?? CityRules.grid(new RateLimits { FiveHour = new(72, t.AddHours(2)), SevenDay = new(40, t.AddDays(4)) }, t);
        s.Repos = 12;
        if (Environment.GetEnvironmentVariable("SHOWORK_CITY_SHIP") is { } r) s.Ships = new() { new CityShip(r, t, Environment.GetEnvironmentVariable("SHOWORK_CITY_SHIP_IN") != null) };
        if (Environment.GetEnvironmentVariable("SHOWORK_CITY_DEMO") == "calm")
        {
            s.Disks[2].Available = 40 * g; s.Servers[1].Online = true; s.Firewall.Ports.RemoveAt(s.Firewall.Ports.Count - 1); s.Power = new CityPower(68, 30, "ok");
            s.Disks[0].Available = 60 * g;
        }
        return s;
    }
}
