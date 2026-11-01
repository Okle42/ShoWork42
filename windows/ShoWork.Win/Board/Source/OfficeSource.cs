using System.Diagnostics;

namespace ShoWork;

// 3D 大樓的資料接線（11-02 P8）：Mac ShoWorkAgent/TowerSource.swift（樓層號名冊存檔、7 天用量、AI 選主題）＋BoardSource.swift 的
// applyTower／decorChanged／replanWander／guardStatus 的 Windows 版。全部掛在看板既有的刷新上，不新增 timer。
// 只有正式 agent 會寫檔、會呼叫 claude；測試視窗（--board-window）只讀現有的名冊／主題，在記憶體裡算（同 Mac）。
// 檔案都在 %LOCALAPPDATA%\ShoWork42\board\（跟 Mac 的 board/ 同格式）：tower.json、themes\<專案>.json、decor_ledger.json、guard\pushes.jsonl。

public static class TowerPaths
{
    public static string board => Path.Combine(Wire.SupportDir, "board");
    /// board\tower.json：樓層號名冊
    public static string registry => Path.Combine(board, "tower.json");
    /// AI 選主題的工作資料夾（空的：避免載入專案的 CLAUDE.md）
    public static string decorCwd => Path.Combine(Wire.SupportDir, "decor-cwd");
    /// wifiwatch 的名冊與紀錄（Mac：~/.claude/data/；Windows 沒有 wifiwatch，有人放檔案進來才讀得到）
    public static string wifiwatchDevices => Path.Combine(CityPaths.claude, "data", "wifiwatch_devices.json");
    public static string wifiwatchLog => Path.Combine(CityPaths.claude, "data", "wifiwatch.log");
    public static string pushes => Path.Combine(board, "guard", "pushes.jsonl");
}

/// AI 選主題的 claude 呼叫（Mac DecorRunner；旗標照 Mac 10-20 實測 claude 2.1.303）：
///   --tools "" 不給任何工具、--strict-mcp-config 不載入 MCP、--no-session-persistence 不寫對話紀錄、--system-prompt 換掉預設的長系統提示詞、
///   --max-turns 1、--model haiku、--output-format json；SHOWORK_REVIEWER=1 讓 showork hook 早退（不發光、不上看板）；cwd 是空資料夾。
/// Windows 的 claude 有幾種裝法：原生 claude.exe（~/.local/bin）、PATH 上的 claude.exe、npm 全域（claude.cmd／claude.ps1 → bin\claude.exe；舊版 → node cli.js）。
/// .cmd／.ps1 要經過 cmd／PowerShell 轉一手、參數引號會被吃（README 已知坑 10），所以 npm 版直接跑它包著的 claude.exe（或 node cli.js）。
public static class DecorRunner
{
    public const string model = "haiku";
    public static List<string> args() => new() { "-p", "--model", model, "--output-format", "json", "--max-turns", "1", "--tools", "", "--strict-mcp-config",
                                                 "--no-session-persistence", "--system-prompt", DecorPrompt.system };

    /// (執行檔, 前置參數)；找不到回 null
    public static (string exe, List<string> pre)? claude()
    {
        var h = BoardReader.DefaultHome;
        var native = Path.Combine(h, ".local", "bin", "claude.exe");
        if (File.Exists(native)) return (native, new());
        var path = (Environment.GetEnvironmentVariable("PATH") ?? "").Split(Path.PathSeparator, StringSplitOptions.RemoveEmptyEntries);
        foreach (var d in path)
        {
            var exe = Path.Combine(d, OperatingSystem.IsWindows() ? "claude.exe" : "claude");
            if (File.Exists(exe)) return (exe, new());
        }
        var appdata = Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData);
        // 11-02 Surface 實測（npm 全域裝的 2.1.x）：claude.cmd 叫的是 node_modules\@anthropic-ai\claude-code\bin\claude.exe（原生），沒有 cli.js
        var npmExe = Path.Combine(appdata, "npm", "node_modules", "@anthropic-ai", "claude-code", "bin", "claude.exe");
        if (File.Exists(npmExe)) return (npmExe, new());
        var cli = Path.Combine(appdata, "npm", "node_modules", "@anthropic-ai", "claude-code", "cli.js");
        if (File.Exists(cli))
        {
            var node = path.Select(d => Path.Combine(d, "node.exe")).FirstOrDefault(File.Exists);
            if (node != null) return (node, new() { cli });
        }
        return null;
    }

    public static (int code, string @out, string err) real(string prompt)
    {
        if (claude() is not { } c) return (-1, "", "找不到 claude 指令");
        try
        {
            Directory.CreateDirectory(TowerPaths.decorCwd);
            var psi = new ProcessStartInfo(c.exe)
            {
                RedirectStandardInput = true, RedirectStandardOutput = true, RedirectStandardError = true, UseShellExecute = false, CreateNoWindow = true,
                WorkingDirectory = TowerPaths.decorCwd,
                StandardOutputEncoding = System.Text.Encoding.UTF8, StandardErrorEncoding = System.Text.Encoding.UTF8,
            };
            foreach (var a in c.pre.Concat(args())) psi.ArgumentList.Add(a);
            psi.Environment["SHOWORK_REVIEWER"] = "1";
            using var p = Process.Start(psi)!;
            var o = p.StandardOutput.ReadToEndAsync(); var e = p.StandardError.ReadToEndAsync();
            using (var w = new StreamWriter(p.StandardInput.BaseStream, new System.Text.UTF8Encoding(false))) w.Write(prompt);
            if (!p.WaitForExit(60_000)) { try { p.Kill(true); } catch { } return (-2, o.IsCompleted ? o.Result : "", "逾時 60 秒"); }
            return (p.ExitCode, o.Result, e.Result);
        }
        catch (Exception x) { return (-1, "", x.Message); }
    }

    /// 不呼叫 AI 的假 runner：固定回一個合法結果
    public static (int code, string @out, string err) fake(string prompt) =>
        (0, """{"type":"result","is_error":false,"result":"{\"theme\":\"monitor\",\"accentColor\":\"#5B8DB8\",\"props\":[\"console\",\"wall_clock\"],\"reason\":\"假 runner\"}","total_cost_usd":0}""", "");
}

/// 樓層主題的看板端（Mac TowerDecor）：決定什麼時候叫 ThemePicker、收集線索（卡片＋transcript 尾端＋README）
public sealed class TowerDecor
{
    public ThemePicker picker { get; }
    /// 只有正式 agent 會呼叫 AI、會寫快取；測試視窗只讀
    public bool official { get; }
    /// AI 裝潢開關（Mac：office.decorAI，預設開）。Windows：%LOCALAPPDATA%\ShoWork42\board\decor-off 存在＝關
    public bool enabled => !File.Exists(Path.Combine(TowerPaths.board, "decor-off"));
    readonly Dictionary<string, BoardColumn> prevColumn = new();
    readonly HashSet<string> readmeAsked = new();
    readonly Dictionary<string, WorkSignature> identities = new();

    public TowerDecor(bool official, ThemePicker.Runner? runner = null)
    {
        this.official = official;
        picker = new ThemePicker(TowerPaths.board, runner ?? DecorRunner.real, DecorRunner.model);
    }

    /// 每次刷新叫一次：找出「一輪工作結束」的專案（卡片從進行中／卡住變成待審／完成／待辦），交給 picker 判斷
    public void consider(List<BoardCard> cards, TowerPlan tower)
    {
        var ended = new HashSet<string>();
        foreach (var c in cards.Where(c => !c.Id.Contains('#')))
            if (prevColumn.TryGetValue(c.Id, out var p) && p is BoardColumn.Active or BoardColumn.Stuck && c.Column is BoardColumn.Review or BoardColumn.Done or BoardColumn.Todo)
                ended.Add(c.Project.ToLowerInvariant());
        prevColumn.Clear();
        foreach (var c in cards.Where(c => !c.Id.Contains('#'))) prevColumn.TryAdd(c.Id, c.Column);
        if (!official) return;
        foreach (var f in tower.projectFloors)
        {
            if (f.Project is not { } name) continue;
            var mine = cards.Where(c => string.Equals(c.Project, name, StringComparison.OrdinalIgnoreCase) && !c.Id.Contains('#')).ToList();
            start(name, mine, ended.Contains(name.ToLowerInvariant()), force: false);
        }
    }

    /// 你按的「重新裝潢」：跳過「工作內容有沒有變」與同專案 6 小時，但總次數／成本上限、同時一個照樣擋
    public string redecorate(string project, List<BoardCard> cards)
    {
        if (!official) return "測試視窗不呼叫 AI";
        var mine = cards.Where(c => string.Equals(c.Project, project, StringComparison.OrdinalIgnoreCase) && !c.Id.Contains('#')).ToList();
        if (DecorPolicy.blocked(project, picker.ledgerSnapshot, picker.runningProject != null, enabled, true, picker.Limits, DateTime.UtcNow) is { } why) return $"暫時不能重新裝潢：{why}";
        return start(project, mine, true, true) ? $"已請 AI 重新裝潢「{project}」" : "暫時不能重新裝潢";
    }

    /// AI 回來、本地結果寫好（背景執行緒叫）：畫面重推
    public event Action? Changed;

    bool start(string project, List<BoardCard> cards, bool turnEnded, bool force)
    {
        var cur = picker.cached(project);
        bool first = cur == null || cur.Source != "ai";
        bool wantReadme = first && !readmeAsked.Contains(project.ToLowerInvariant());
        var snap = cards.ToList();
        bool started = picker.consider(project, turnEnded, enabled, () => gather(project, snap, wantReadme), force,
            changed: v => { Log.Note($"DECOR {project} → {v.Theme.rawValue()} {v.Source} {v.Reason}"); Changed?.Invoke(); },
            finished: d => { if (d.Case == "keep" && d.Why?.StartsWith("AI 失敗") == true) Log.Note($"DECOR {project} {d.Why}"); });
        if (started && wantReadme) readmeAsked.Add(project.ToLowerInvariant());
        return started;
    }

    /// 專案身分（專案名＋README 標題與第一段）：每個專案只讀一次 README（4KB），之後用記憶體裡的
    public WorkSignature identity(string project, List<BoardCard> cards)
    {
        var k = project.ToLowerInvariant();
        if (identities.TryGetValue(k, out var s)) return s;
        var readme = root(project, cards) is { } r ? readmeHead(r) : null;
        s = WorkSignature.make(new DecorInput(project) { Readme = readme });
        identities[k] = s;
        return s;
    }

    /// 收集線索（背景）：卡片標題、自報摘要、AI 最後一句；每個 session 的 transcript 尾端 200KB；README 前 600 字
    public static DecorInput gather(string project, List<BoardCard> cards, bool readme)
    {
        var inp = new DecorInput(project);
        foreach (var c in cards)
        {
            inp.Notes.Add(c.Title);
            if (c.Report?.Summary is { } s) inp.Notes.Add(s);
            if (c.Detail is { } d) inp.Notes.Add(Board.Prefix(d, 200));
            var x = DecorInput.extract(tail(c));
            inp.Prompts.AddRange(x.prompts.TakeLast(3)); inp.Paths.AddRange(x.paths); inp.Commands.AddRange(x.commands);
        }
        if (readme && root(project, cards) is { } r) inp.Readme = readmeHead(r);
        return inp;
    }

    /// 對話紀錄尾端 200KB（同審核員）
    static string tail(BoardCard c)
    {
        try
        {
            var slug = new SessionRecord { Cwd = c.Cwd ?? BoardReader.DefaultHome }.ProjectSlug;
            var path = Path.Combine(CityPaths.claude, "projects", slug, c.SessionId + ".jsonl");
            if (!File.Exists(path)) return "";
            using var fs = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
            long size = fs.Length;
            fs.Seek(size > 200_000 ? size - 200_000 : 0, SeekOrigin.Begin);
            using var sr = new StreamReader(fs, System.Text.Encoding.UTF8);
            return sr.ReadToEnd();
        }
        catch { return ""; }
    }

    /// 專案資料夾：repo 根目錄底下的同名資料夾，不然從卡片的 cwd 往上找 .git
    public static string? root(string project, IEnumerable<BoardCard> cards)
    {
        if (CityPaths.repos().TryGetValue(project, out var r)) return r;
        foreach (var c in cards)
        {
            var p = c.Cwd;
            while (!string.IsNullOrEmpty(p))
            {
                if (BoardReader.DefaultIsRepo(p)) return p;
                p = BoardPath.Parent(p);
            }
        }
        return null;
    }

    public static string? readmeHead(string root)
    {
        foreach (var n in new[] { "README.md", "README.zh-TW.md", "README", "readme.md" })
        {
            var f = Path.Combine(root, n);
            if (!File.Exists(f)) continue;
            try
            {
                using var fs = File.OpenRead(f);
                var buf = new byte[4096]; int len = fs.Read(buf, 0, buf.Length);
                // 10-20 §4.3：先去掉徽章／圖片／程式碼再取前 600 字
                return Board.Prefix(DecorInput.cleanReadme(System.Text.Encoding.UTF8.GetString(buf, 0, len)).Trim(), 600);
            }
            catch { return null; }
        }
        return null;
    }
}

/// 樓層號名冊＋7 天用量（Mac TowerStore 的讀檔存檔部分）
public static partial class TowerStore
{
    public static TowerRegistry load()
    {
        try { return TowerRegistry.decode(File.Exists(TowerPaths.registry) ? File.ReadAllText(TowerPaths.registry) : null); } catch { return new(); }
    }
    public static void save(TowerRegistry r)
    {
        try
        {
            Directory.CreateDirectory(TowerPaths.board);
            var tmp = TowerPaths.registry + $".{Environment.ProcessId}.tmp";
            File.WriteAllText(tmp, r.encoded());
            File.Move(tmp, TowerPaths.registry, overwrite: true);
        }
        catch (Exception x) { Log.Note($"OFFICE registry save failed {x.Message}"); }
    }

    /// 最近 7 天用量（MB）：只在有新專案要發號碼時才算（第一次排名、之後偶爾一個新專案）
    public static Dictionary<string, double> usage(List<OfficeDepartment> departments, List<BoardCard> cards)
    {
        var repos = CityPaths.repos();
        var paths = new Dictionary<string, List<string>>();
        foreach (var d in departments)
        {
            var l = paths.TryGetValue(d.Name, out var x) ? x : paths[d.Name] = new();
            if (repos.TryGetValue(d.Name, out var rp)) l.Add(rp);
            if (TowerDecor.root(d.Name, cards.Where(c => c.Project == d.Name)) is { } r && !l.Contains(r, StringComparer.OrdinalIgnoreCase)) l.Add(r);
        }
        return ProjectUsage.scan(Path.Combine(CityPaths.claude, "projects"), paths, DateTime.UtcNow);
    }
}

/// 前台・保全（Mac BoardSource.guardStatus）：wifiwatch 名冊／紀錄＋push 守門的紀錄（24 小時）；檔案沒變就沿用上次的結果
public sealed class GuardSource
{
    string stamp = "";
    GuardStatus? cached;

    static string fileStamp(string p) { try { var f = new FileInfo(p); return f.Exists ? $"{f.LastWriteTimeUtc.Ticks}:{f.Length}" : "-"; } catch { return "-"; } }
    static string? text(string p) { try { return File.Exists(p) ? File.ReadAllText(p) : null; } catch { return null; } }

    public GuardStatus status(DateTime now)
    {
        var st = fileStamp(TowerPaths.wifiwatchDevices) + "/" + fileStamp(TowerPaths.wifiwatchLog) + "/" + fileStamp(TowerPaths.pushes);
        if (st == stamp && cached is { } c && (c.Stale || (c.LastScan is { } ls && now - ls <= WifiWatch.staleAfter))) return c;
        var g = WifiWatch.parse(text(TowerPaths.wifiwatchDevices), text(TowerPaths.wifiwatchLog), now);
        g.merge(recentPushes(text(TowerPaths.pushes), now.AddDays(-1)));
        stamp = st; cached = g;
        return g;
    }

    /// pushes.jsonl → since 之後的，新的在前（Mac PushGuard.recent）
    public static List<GuardPushEvent> recentPushes(string? data, DateTime since) =>
        (data ?? "").Split('\n').Select(GuardPushEvent.decode).OfType<GuardPushEvent>().Where(e => e.At >= since).OrderByDescending(e => e.At).ToList();
}

/// 看板每次刷新叫 Build：組大樓、主題、閒晃、保全、城市、天氣、圖譜 ⇒ office2 JSON。只在 UI 執行緒叫（狀態不上鎖）
public sealed class OfficeSource
{
    readonly bool demo, official;
    readonly TowerRegistry registry;
    TowerPlan tower = new();
    WanderPlan wander = new();
    Dictionary<string, FloorDecor> decor = new();
    List<ResidentProject> residents = new();
    DateTime? residentsAt;
    readonly OfficeDemo.TowerCache demoTower = new();
    public TowerDecor Decor { get; }
    public GuardSource Guard { get; } = new();
    /// 看得到大樓嗎（看不到：不出發、進行中的直接落地；Mac BoardModel.wanderVisible）
    public bool visible { get; set; } = true;
    public OfficeLighting lighting { get; set; } = OfficeLighting.auto;
    public TowerPlan Tower => tower;
    /// 上次推給網頁的島（點角色找卡片用；示範模式是 OfficeDemo 的示範卡片）
    public List<Island> Islands { get; private set; } = new();

    /// `demo`＝示範卡片（記憶體裡的名冊，不碰 board\tower.json）；`official`＝正式 agent（會寫名冊、主題快取，會呼叫 claude）
    public OfficeSource(bool demo, bool official, ThemePicker.Runner? runner = null)
    {
        this.demo = demo; this.official = official && !demo;
        registry = demo ? new TowerRegistry() : TowerStore.load();
        Decor = new TowerDecor(this.official, runner);
    }

    List<ResidentProject> residentProjects(DateTime now)
    {
        if (residentsAt is { } t && now - t < ResidentProjects.rescanInterval && now >= t) return residents;
        // Windows：repo 根目錄可能有好幾個（見 CityPaths.repoRoots），各自掃第一層，同名留第一個
        var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        residents = CityPaths.repoRoots().SelectMany(r => ResidentProjects.scan(r, now)).Where(p => seen.Add(p.Name)).ToList();
        residents.Sort((a, b) => ResidentProjects.compare(a.Name, b.Name));
        residentsAt = now;
        return residents;
    }

    public string Build(List<BoardCard> cards0, DateTime now, CityState? city, WeatherSite site, WeatherNow? weather, NeuralGraph? graph,
                        IReadOnlyDictionary<string, string>? colors = null, bool reduceMotion = false)
    {
        var mode = demo ? "all" : OfficeDemo.mode;
        var cards = OfficeDemo.apply(mode, cards0, now);
        var islands = ShoWork.Islands.Build(cards);
        Islands = islands;
        bool rain = weather?.kind.isWet() ?? false;
        TowerPlan plan; Dictionary<string, FloorDecor> d; WanderPlan w;
        if (mode != null)
        {
            var deps = OfficeDemo.departments(new(), cards, mode);
            (plan, d, w) = demoTower.make(deps, cards, new Dictionary<string, FloorDecor>(), now, rain);
        }
        else
        {
            var deps = OfficeDepartments.build(residentProjects(now).Select(r => r.Name), cards);
            // applyTower
            var accents = decor.ToDictionary(kv => kv.Key, kv => kv.Value.AccentColor);
            var (p, dirty) = TowerPlan.build(deps, cards, registry, () => TowerStore.usage(deps, cards), accents, now);
            if (dirty && official) TowerStore.save(registry);
            tower = p;
            decorChanged(cards);
            Decor.consider(cards, tower);
            // replanWander
            wander = WanderPlanner.plan(TowerStore.people(cards, tower), tower, wander.States, now, visible, TowerStore.wanderMode, rain, wander.Cars);
            plan = tower; d = decor; w = wander;
        }
        if (mode != null) tower = plan;
        var guardStatus = Guard.status(now);
        var json = Office2.Payload(plan, d, w, islands, guardStatus, scanning: false, city, now, lighting, site, weather, graph, colors, reduceMotion);
        return Office2.Json(json);
    }

    /// 主題快取（或 AI 剛回來）→ 發布：快取有的用快取，沒有的先用專案名的本地評分（不阻塞畫面），測試覆寫最後蓋上去
    void decorChanged(List<BoardCard> cards)
    {
        var d = Decor.picker.all();
        foreach (var f in tower.projectFloors)
        {
            if (f.Project is not { } name) continue;
            var k = name.ToLowerInvariant();
            // 10-20 UI/UX 優化 §4.3：用「專案身分」校正——AI 挑的主題不在身分前 2 名就不採用、識別色鎖主題色
            var id = Decor.identity(name, cards.Where(c => string.Equals(c.Project, name, StringComparison.OrdinalIgnoreCase)).ToList());
            if (d.TryGetValue(k, out var c))
            {
                var r = DecorPolicy.reconcile(c, id);
                if (MacMirror.Json(MacMirror.Encode(r)) != MacMirror.Json(MacMirror.Encode(c))) { d[k] = r; if (official) Decor.picker.store(name, r); }
            }
            else d[k] = FloorDecor.local(id, DateTime.UnixEpoch, "還沒判斷，先用專案身分");
        }
        foreach (var (k, v) in TowerStore.themeOverrides(DateTime.UtcNow)) d[k] = v;
        decor = d;
    }
}
