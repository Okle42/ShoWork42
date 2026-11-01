using System.Diagnostics;
using System.Drawing.Drawing2D;
using System.Runtime.InteropServices;
using System.Text.Json;
using Microsoft.Win32;
using static ShoWork.Native;

namespace ShoWork;

/// 戰情中心視窗：部門島卡片格＋工具列（新任務⋯、交給隊長⋯、AI 審核、ctx 門檻＋自動收尾、帳號流量）。Mac 版 BoardWindow.swift／IslandView.swift 的移植。
/// 11-02 P8 第二輪：大樓網頁的按鈕（收件匣回答、權限、選擇題、隊長、派工、退回、丟待辦、放行、重新審核、重新裝潢、天氣地點⋯，見 Web\PROTOCOL.md）
/// 都在這裡接（OnOfficeAction）；對話框在 BoardSheets.cs。只有正式 agent（系統匣開的）會自動審核、自動回報派工、自動收尾（Mac：Engine.current != nil）。
/// 每 1.5 秒重讀一次看板（同 Mac），沒變就不重畫；島的動畫 8 fps，只在有人在動、視窗看得到、沒開「減少動態效果」時跑。
/// W6：左上「卡片／大樓」切換；大樓＝WebView2＋three.js（OfficeHost），WebView2 Runtime 不在或壞掉就退回卡片、切換鈕變灰。
sealed class BoardForm : Form
{
    public sealed record Options(bool Demo = false, Size? Size = null, string? Shot = null, bool ExitAfterShot = false, bool TopMost = false, bool? Tower = null);

    static BoardForm? instance;

    /// 系統匣「戰情中心…」：開（或叫回）視窗
    public static void ShowSingleton()
    {
        if (instance == null || instance.IsDisposed) { instance = new BoardForm(new Options(Demo: DemoFromEnv)); instance.Show(); }
        if (instance.WindowState == FormWindowState.Minimized) instance.WindowState = FormWindowState.Normal;
        instance.Activate();
    }

    static bool DemoFromEnv => Environment.GetEnvironmentVariable("SHOWORK_BOARD_DEMO") is "1";

    readonly Options opt;
    readonly BoardReader reader = BoardReader.Default();
    readonly System.Windows.Forms.Timer refresh = new() { Interval = 1500 };
    readonly System.Windows.Forms.Timer anim = new() { Interval = (int)(1000 / KuboMath.Fps) };
    readonly Panel scroller;
    readonly UsageBar usage;
    readonly BoardControls controls;
    readonly List<IslandCardView> views = new();
    readonly DateTime demoAt = DateTime.UtcNow;
    System.Windows.Forms.Timer? shotTimer;           // --shot 的一次性計時器：視窗先被關掉時要一起丟掉
    List<Island> islands = new();
    string signature = "";
    bool reading, shown;

    // MARK: 大樓檢視（W6）
    readonly ViewSwitch switcher;
    OfficeHost? office;
    bool tower;                                     // 現在看大樓
    // 11-02 P8：大樓照搬 Mac（Board\Core＋Board\Source）：OfficeSource 組 office2 JSON（樓層號名冊、主題、閒晃、保全、城市、天氣、圖譜）
    OfficeSource? officeSource;
    OfficeWeather? weather;
    readonly GraphSource graph = new();
    List<BoardCard> lastCards = new();
    string officeJson = "";
    DateTime officeAt;                              // 上次組大樓的時間（資料沒變也每 15 秒重組一次：閒晃的時段、2 小時降樓要看時間）
    Panel? detail;                                  // 點角色後浮在大樓上的那張卡（沿用 IslandCardView）
    IslandCardView? detailView;
    string? detailId;
    static string ViewPrefPath => Path.Combine(Wire.SupportDir, "board", "board-view.txt");
    // 11-02 P8 第二輪：收件匣、隊長對話、進度條（BoardModel 的 @Published）
    List<CaptainLine> captainThread = new(), sessionThread = new();
    List<CaptainTaskInfo> captainTasks = new();
    List<RunProgress> runs = new();
    Dictionary<string, Review> reviews = new();
    bool captainBusy;
    bool guardScanning;
    /// 正式 agent（系統匣開的）才會自動審核、自動回報派工、自動收尾、巡邏（Mac：Engine.current != nil）
    static bool Official => !BoardWindowTestMode && Engine.Current != null;
    public BoardCard? CaptainCard => lastCards.FirstOrDefault(c => c.Captain && !c.IsQueued);

    public BoardTheme Theme { get; private set; } = BoardTheme.Current();
    public BoardFonts Fonts { get; private set; } = new();
    public ToolTip Tips { get; } = new() { InitialDelay = 400, AutoPopDelay = 20000, ReshowDelay = 100 };
    public bool ReduceMotion { get; private set; } = ReadReduceMotion();
    /// 視窗看得到（沒縮小、沒被完全蓋住、不在別的虛擬桌面）
    bool visibleOnScreen = true;
    int frames;                                     // 量測用：動畫一共重畫了幾格

    public BoardForm(Options opt)
    {
        this.opt = opt;
        Text = "AI工作戰情中心";
        AutoScaleMode = AutoScaleMode.None;
        StartPosition = FormStartPosition.CenterScreen;
        try { Icon = Icon.ExtractAssociatedIcon(Environment.ProcessPath!); } catch { }
        ResizeRedraw = true;                        // 視窗邊緣（工具列與卡片格以外的底色）放大時也要補畫
        scroller = new BufferedPanel();
        // 只往下捲：橫捲軸先關掉再開 AutoScroll（WinForms 的固定寫法；卡片寬度本來就扣過直捲軸，不該有橫捲）
        scroller.HorizontalScroll.Enabled = false;
        scroller.HorizontalScroll.Visible = false;
        scroller.HorizontalScroll.Maximum = 0;
        scroller.AutoScroll = true;
        scroller.HandleCreated += (_, _) => ThemeScrollBars();
        scroller.Paint += PaintEmpty;
        scroller.Scroll += (_, _) => AnimateTick();
        scroller.MouseWheel += (_, _) => AnimateTick();
        usage = new UsageBar(this);
        switcher = new ViewSwitch(this);
        switcher.Changed += t => SetTower(t, remember: true);
        controls = new BoardControls(this);
        controls.NewTask += () => OpenSheet(new NewTaskSheet(this, Folders(lastCards), Toast));
        controls.ToCaptain += () => OpenSheet(new CaptainSheet(this, CaptainCard, BoardWindowTestMode, Toast));
        controls.Changed += () => { Repaint(); PerformLayout(); };
        Controls.Add(controls);
        Controls.Add(switcher);
        Controls.Add(usage);
        Controls.Add(scroller);
        ApplyTheme();
        refresh.Tick += (_, _) => Refresh_();
        anim.Tick += (_, _) => AnimateTick();
        SystemEvents.UserPreferenceChanged += PreferenceChanged;
        if (opt.TopMost) TopMost = true;
        WireActions();
    }

    // MARK: 動作的接線（BoardActions 的委派：剪貼簿、跳到視窗、通知）

    void WireActions()
    {
        BoardActions.CopyToClipboard = text =>
        {
            bool ok = false;
            void Set() { try { Clipboard.SetText(text); ok = true; } catch { } }
            try { if (InvokeRequired) Invoke(Set); else Set(); } catch { }
            return ok;
        };
        BoardActions.FocusWindow = FocusCard;
        BoardActions.Notify = (title, body) =>
        {
            Log.Note($"NOTICE {title}：{body}");
            try { BeginInvoke(() => Toast($"{title}：{body}")); } catch { }
        };
        Reviewer.Shared.TranscriptOf = c => reader.TranscriptPathOf(c.SessionId);
        Reviewer.Shared.Changed += AsyncRefresh;
        TaskRouter.Shared.Changed += AsyncRefresh;
    }

    void AsyncRefresh() { try { if (!IsDisposed) BeginInvoke(Refresh_); } catch { } }

    /// 跳到那個 AI 的終端機視窗：光暈引擎知道它在哪（Mac：Engine.current.tabs 的 placements）；測試視窗沒有引擎 ⇒ 自己找那個 pid 的主控台
    static bool FocusCard(BoardCard c)
    {
        IntPtr w = IntPtr.Zero;
        if (Engine.Current?.Sessions.FirstOrDefault(s => s.Pid == c.Pid) is { Window: var ew } && ew != IntPtr.Zero) w = ew;
        if (w == IntPtr.Zero && c.Pid > 0)
            try { if (Resolver.Consoles(new[] { c.Pid }).FirstOrDefault() is { Hwnd: var h } && h != IntPtr.Zero) w = Resolver.WindowOf(h); } catch { }
        if (w == IntPtr.Zero) return false;
        Engine.JumpTo(w);
        return true;
    }

    /// 新任務可選的資料夾：看板上出現過的專案根目錄（Mac BoardView.folders）
    static List<string> Folders(IEnumerable<BoardCard> cards)
    {
        var home = BoardReader.DefaultHome;
        var seen = new List<string>();
        foreach (var c in cards)
            if (c.Cwd is { } d && GitRoot(d, home) is var r && !BoardPath.Same(r, home) && !seen.Contains(r, StringComparer.OrdinalIgnoreCase)) seen.Add(r);
        return seen;
    }
    static string GitRoot(string p, string home)
    {
        for (string? d = p; d != null && !BoardPath.Same(d, home); d = BoardPath.Parent(d))
            if (BoardReader.DefaultIsRepo(d)) return d;
        return p;
    }

    /// 對話框（Mac 的 sheet）：置中在戰情中心上、強制回應
    void OpenSheet(Form f)
    {
        try { f.ShowDialog(this); } finally { f.Dispose(); }
        Refresh_();
    }

    /// 底部提示（Mac BoardView.show：6 秒後收掉）。大樓在畫面上就交給網頁的 toast；卡片畫面用工具列下方的一行
    public void Toast(string text)
    {
        if (IsDisposed) return;
        if (tower && office?.Ready == true) { office.Post(new System.Text.Json.Nodes.JsonObject { ["type"] = "toast", ["text"] = text }); return; }
        toastText = text;
        toastAt = DateTime.UtcNow;
        Invalidate();
        var t = new System.Windows.Forms.Timer { Interval = 6000 };
        t.Tick += (_, _) => { t.Dispose(); if (DateTime.UtcNow - toastAt >= TimeSpan.FromSeconds(5.9)) { toastText = null; Invalidate(); } };
        t.Start();
    }
    string? toastText;
    DateTime toastAt;

    protected override void OnPaint(PaintEventArgs e)
    {
        base.OnPaint(e);
        if (toastText == null) return;
        // 卡片畫面的提示：浮在底部中間的膠囊（Mac：.regularMaterial Capsule）
        float s = S;
        var f = Fonts.Get(13 * s);
        var sz = TextRenderer.MeasureText(toastText, f, new Size((int)(ClientSize.Width * 0.8), 0), TextFormatFlags.WordBreak | TextFormatFlags.NoPrefix);
        var r = new Rectangle((ClientSize.Width - sz.Width) / 2 - (int)(14 * s), ClientSize.Height - sz.Height - (int)(36 * s), sz.Width + (int)(28 * s), sz.Height + (int)(16 * s));
        e.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
        using (var p = IslandCardView.Rounded(r, r.Height / 2f))
        using (var b = new SolidBrush(Theme.Card)) e.Graphics.FillPath(b, p);
        TextRenderer.DrawText(e.Graphics, toastText, f, Rectangle.Inflate(r, -(int)(14 * s), -(int)(8 * s)), Theme.Text, TextFormatFlags.WordBreak | TextFormatFlags.NoPrefix | TextFormatFlags.HorizontalCenter);
    }

    float S => DeviceDpi / 96f;

    protected override void OnHandleCreated(EventArgs e)
    {
        base.OnHandleCreated(e);
        int dark = Theme.Dark ? 1 : 0;
        DwmSetWindowAttribute(Handle, 20 /*DWMWA_USE_IMMERSIVE_DARK_MODE*/, ref dark, sizeof(int));
        // 看得到的大小（DWM 外框，不含隱形的縮放邊）= 指定的邏輯大小 × DPI；Mac 的 1180×680 是預設
        var want = opt.Size ?? new Size(1180, 680);
        SizeVisible((int)(want.Width * S), (int)(want.Height * S));
        // CenterScreen 是照改大小之前的預設大小算的：改完再置中一次，上緣不超出工作區（以前 820×700 在 150% 的 Surface 上底下 1/10 跑出螢幕）
        if (StartPosition == FormStartPosition.CenterScreen)
        {
            var wa = Screen.FromHandle(Handle).WorkingArea;
            Location = new Point(wa.Left + Math.Max(0, (wa.Width - Width) / 2), wa.Top + Math.Max(0, (wa.Height - Height) / 2));
        }
        ApplyMinimumSize();
    }

    void ApplyMinimumSize() => MinimumSize = new Size((int)(360 * S), (int)(300 * S));

    /// 讓「看得到的視窗」剛好是 w×h 實際像素（Form.Size 含左右下各幾 px 的隱形邊框）
    void SizeVisible(int w, int h)
    {
        Size = new Size(w, h);
        if (GetWindowRect(Handle, out var wr) && DwmGetWindowAttribute(Handle, DWMWA_EXTENDED_FRAME_BOUNDS, out RECT fr, Marshal.SizeOf<RECT>()) == 0)
        {
            int extraW = (wr.Right - wr.Left) - (fr.Right - fr.Left), extraH = (wr.Bottom - wr.Top) - (fr.Bottom - fr.Top);
            Size = new Size(w + extraW, h + extraH);
        }
    }

    protected override void OnShown(EventArgs e)
    {
        base.OnShown(e);
        shown = true;
        Invalidate(true);                           // OnHandleCreated 改過大小：第一次畫的時候可能還是舊大小
        // 一開始看哪個：--board-tower／SHOWORK_BOARD_VIEW=tower|cards（測試）＞上次選的＞卡片
        bool want = opt.Tower ?? (Environment.GetEnvironmentVariable("SHOWORK_BOARD_VIEW") is { Length: > 0 } ev ? ev == "tower" : ReadViewPref());
        switcher.Enabled = OfficeHost.RuntimeVersion != null;
        if (!switcher.Enabled) Tips.SetToolTip(switcher, "這台電腦沒有 WebView2 Runtime，只能看卡片（Windows 11 內建；Windows 10 要另外裝）");
        if (want) SetTower(true, remember: false);
        Log.Note($"BOARD open demo={opt.Demo} dpi={DeviceDpi} size={Size} client={ClientSize} reduce={ReduceMotion}");
        Refresh_();
        refresh.Start();
        if (opt.Shot is { } path)
        {
            // 截圖驗收：等動畫跑幾格再拍
            shotTimer = new System.Windows.Forms.Timer { Interval = 3000 };
            shotTimer.Tick += (_, _) =>
            {
                shotTimer?.Dispose();
                shotTimer = null;
                if (IsDisposed) return;
                try { Snapshot(path); } catch (Exception x) { Log.Note($"BOARD shot failed {x}"); }
                if (opt.ExitAfterShot) Close();
            };
            shotTimer.Start();
        }
    }

    // MARK: 版面

    protected override void OnLayout(LayoutEventArgs e)
    {
        base.OnLayout(e);
        if (usage == null) return;
        float s = S;
        int pad = (int)(16 * s);
        int w = Math.Max(0, ClientSize.Width - pad * 2);
        var sw = switcher.PreferredSize;
        int gap = (int)(12 * s), y0 = (int)(12 * s);
        switcher.Bounds = new Rectangle(pad, y0, sw.Width, sw.Height);
        // 視窗窄時不硬擠一排（Mac 10-13 ViewThatFits）：一排 → 兩排（流量表換到第二排）→ 兩排短標籤
        int left = w - sw.Width - gap;
        int uw1 = usage.MetersWidth;
        bool one = controls.WidthFor(false) + gap * 2 + uw1 <= left;
        controls.Short = !one && controls.WidthFor(false) > left;
        int cw = Math.Min(left, controls.WidthFor(controls.Short));
        controls.Bounds = new Rectangle(switcher.Right + gap, y0, Math.Max(0, cw), sw.Height);
        int top;
        if (one)
        {
            int uh = usage.HeightFor(uw1);
            usage.Bounds = new Rectangle(pad + w - uw1, y0 + Math.Max(0, (sw.Height - uh) / 2), uw1, uh);
            top = Math.Max(usage.Bottom, switcher.Bottom) + gap;
        }
        else
        {
            int uh = usage.HeightFor(w);
            usage.Bounds = new Rectangle(pad, switcher.Bottom + (int)(8 * s), w, uh);
            top = usage.Bottom + gap;
        }
        scroller.Bounds = new Rectangle(pad, top, w, Math.Max(0, ClientSize.Height - top - pad));
        if (office != null) office.View.Bounds = scroller.Bounds;
        LayoutDetail();
        LayoutGrid();
    }

    void LayoutGrid()
    {
        if (islands.Count == 0) { scroller.AutoScrollMinSize = Size.Empty; scroller.Invalidate(); return; }
        // 每張一樣大、剛好塞滿視窗（Mac 10-12 Kang）；塞不下才往下捲。像素對齊見 GridPixels（以前四捨五入多 1px ⇒ 冒出兩條捲軸）
        int sb = GetSystemMetricsForDpi(2 /*SM_CXVSCROLL*/, (uint)DeviceDpi);
        var (cells, scroll, content) = GridPixels.Place(islands.Count, scroller.Width, scroller.Height, sb, S);
        scroller.SuspendLayout();
        var off = scroller.AutoScrollPosition;
        for (int i = 0; i < views.Count && i < cells.Count; i++)
            views[i].Bounds = new Rectangle(cells[i].X + off.X, cells[i].Y + off.Y, cells[i].W, cells[i].H);
        scroller.AutoScrollMinSize = scroll ? new Size(0, content) : Size.Empty;
        scroller.ResumeLayout();
    }

    /// 捲軸跟著深色／淺色（不設的話深色主題裡是白色系統捲軸）
    void ThemeScrollBars()
    {
        if (!scroller.IsHandleCreated) return;
        try { SetWindowTheme(scroller.Handle, Theme.Dark ? "DarkMode_Explorer" : "Explorer", null); } catch { }
    }

    void PaintEmpty(object? sender, PaintEventArgs e)
    {
        if (islands.Count > 0) return;
        var r = scroller.ClientRectangle;
        var f1 = Fonts.Get(17 * S, bold: true);
        var f2 = Fonts.Get(13 * S);
        int h1 = TextRenderer.MeasureText("國", f1).Height;
        var mid = r.Height / 2;
        TextRenderer.DrawText(e.Graphics, "還沒有 session", f1, new Rectangle(0, mid - h1, r.Width, h1), Theme.Text, TextFormatFlags.HorizontalCenter);
        TextRenderer.DrawText(e.Graphics, "開一個 Claude Code，它就會出現在島上。", f2, new Rectangle(0, mid + (int)(4 * S), r.Width, h1), Theme.Secondary,
                              TextFormatFlags.HorizontalCenter | TextFormatFlags.NoPrefix);
    }

    // MARK: 資料

    /// 讀看板在背景執行緒（讀 transcript 尾端可能要幾十 ms），結果回 UI 執行緒；看不到的時候不讀，回來時補讀
    void Refresh_()
    {
        try { RefreshCore(); }
        catch (Exception x) { Failed("refresh", x); }
    }

    /// UI 執行緒上的計時器出錯：停掉計時器、記 log，不跳 WinForms 的例外對話框（8 fps 每格都丟會一直疊出來）
    void Failed(string where, Exception x)
    {
        Log.Note($"BOARD {where} failed, timers stopped: {x}");
        refresh.Stop();
        anim.Stop();
    }

    void RefreshCore()
    {
        CheckVisible();
        if (reading || !shown || (!visibleOnScreen && signature.Length > 0)) return;
        reading = true;
        var now = DateTime.UtcNow;
        Task.Run(() =>
        {
            List<BoardCard> cards; RateLimits? limits; BoardReader.Snapshot? snap = null;
            if (opt.Demo) { cards = BoardDemo.Cards(demoAt); limits = BoardDemo.Limits(demoAt); }
            else
            {
                snap = reader.Read();
                cards = reader.Cards(snap, now);
                limits = snap.RateLimits;
            }
            var sig = JsonSerializer.Serialize(cards, Board.DumpJson);
            return (cards, limits, sig, snap);
        }).ContinueWith(t =>
        {
            if (t.Exception is { } x) Log.Note($"BOARD read failed {x.InnerException ?? x}");
            if (IsDisposed) return;
            try
            {
                BeginInvoke(() =>
                {
                    reading = false;
                    try { if (t.IsCompletedSuccessfully) { ApplySnapshot(t.Result.snap, t.Result.cards); Apply(t.Result.cards, t.Result.limits, t.Result.sig); } }
                    catch (Exception x2) { Failed("apply", x2); }
                });
            }
            catch { }
        });
    }

    /// 門檻改了：卡片上 ctx 的顏色跟著變（資料沒變，只重畫）
    public void Repaint() { foreach (var v in views) v.Invalidate(true); }

    /// 收件匣、隊長對話、派工單、進度條（Mac BoardModel.apply 的後半）＋自動審核、ctx 收尾、派工回報、保全巡邏
    void ApplySnapshot(BoardReader.Snapshot? s, List<BoardCard> cards)
    {
        if (s == null) return;
        captainThread = s.CaptainThread;
        sessionThread = reader.Watching != null ? s.SessionThread : new();
        runs = s.Runs;
        reviews = s.Reviews;
        // 隊長面板的派工單：還在做的（3 天內有動靜）＋要你看的（24 小時內）；卡住的排最前面
        var now = DateTime.UtcNow;
        int Rank(CaptainTaskInfo.TaskState st) => st == CaptainTaskInfo.TaskState.blocked ? 0 : st == CaptainTaskInfo.TaskState.review ? 1 : 2;
        captainTasks = s.Tasks.Where(t => (CaptainTasks.Open(t.State) && now - t.UpdatedAt < TimeSpan.FromDays(3))
                                          || (t.State == CaptainTaskInfo.TaskState.review && now - t.UpdatedAt < TimeSpan.FromDays(1)))
                              .OrderBy(t => Rank(t.State)).ThenByDescending(t => t.UpdatedAt).ToList();
        if (Official) Reviewer.Shared.Consider(cards, s.Reviews);
        CtxGuard.Shared.Check(cards, Official);
        TaskRouter.Shared.Check(s.Tasks, Official);
        Patrol();
    }

    /// 定時巡邏：每 30 分鐘最多一次。只有正式 agent 會巡（測試視窗不動手、不掃網路）
    void Patrol()
    {
        if (!Official) return;
        var sc = GuardScanner.Shared;
        if (GuardScanner.PatrolDue(BoardPrefs.Bool("office.guardPatrol", false), sc.IsRunning, officeSource?.Guard.status(DateTime.UtcNow).LastScan, sc.LastStarted, DateTime.UtcNow)
            && File.Exists(GuardScanner.Script))
            GuardScan();
    }

    /// 立即掃描（你按的，或定時巡邏）：背景跑掃描腳本；同時只跑一個（Mac BoardModel.guardScan）
    bool GuardScan()
    {
        if (!File.Exists(GuardScanner.Script)) return false;
        bool ok = GuardScanner.Shared.Scan(code =>
        {
            Log.Note($"GUARD scan done code={code}");
            try { BeginInvoke(() => { guardScanning = false; UpdateOffice(force: true); Refresh_(); }); } catch { }
        });
        if (ok) { guardScanning = true; Log.Note($"GUARD scan start {GuardScanner.Script}"); UpdateOffice(force: true); }
        return ok;
    }

    void Apply(List<BoardCard> cards, RateLimits? limits, string sig)
    {
        if (IsDisposed) return;
        lastCards = cards;
        if (sig == signature) { usage.Set(limits, islands.Count); UpdateOffice(force: ExtrasChanged()); Retime(); return; }
        signature = sig;
        islands = Islands.Build(cards);
        UpdateOffice(force: true);
        // 同一座島沿用同一個控制項（影分身出現／離開的時間記在裡面）
        var old = views.ToDictionary(v => v.Project, StringComparer.OrdinalIgnoreCase);
        var next = new List<IslandCardView>();
        foreach (var i in islands)
        {
            if (!old.Remove(i.Project, out var v)) { v = new IslandCardView(this); scroller.Controls.Add(v); }
            next.Add(v);
        }
        foreach (var v in old.Values) { scroller.Controls.Remove(v); v.Dispose(); }
        views.Clear();
        views.AddRange(next);
        LayoutGrid();
        for (int i = 0; i < islands.Count; i++) views[i].SetIsland(islands[i]);
        // 島數也算在工具列的「要不要重畫」裡（以前只看流量字，沒流量資料時 0→3 座島一直顯示「唯讀」）
        usage.Set(limits, islands.Count);
        scroller.Invalidate();
        Retime();
        Log.Note($"BOARD apply islands={islands.Count} cards={cards.Count} anim={anim.Enabled} visible={visibleOnScreen}");
    }

    // MARK: 大樓（W6）

    static bool ReadViewPref() { try { return File.Exists(ViewPrefPath) && File.ReadAllText(ViewPrefPath).Trim() == "tower"; } catch { return false; } }
    static void WriteViewPref(bool t)
    {
        try { Directory.CreateDirectory(Path.GetDirectoryName(ViewPrefPath)!); File.WriteAllText(ViewPrefPath, t ? "tower" : "cards"); } catch { }
    }

    /// 切換卡片／大樓。大樓第一次打開才建 WebView2；不能用就留在卡片
    void SetTower(bool on, bool remember)
    {
        if (on && (OfficeHost.RuntimeVersion == null || office?.Failed == true)) on = false;
        if (remember) WriteViewPref(on);
        tower = on;
        switcher.Tower = on;
        if (on && office == null)
        {
            office = new OfficeHost();
            office.Selected += id => { try { BeginInvoke(() => ShowDetail(id)); } catch { } };
            office.ActionReceived += m => { try { BeginInvoke(() => OnOfficeAction(m)); } catch { } };
            office.Broken += why => { try { BeginInvoke(() => OfficeBroken(why)); } catch { } };
            office.View.Bounds = scroller.Bounds;
            Controls.Add(office.View);
            office.View.BringToFront();
            office.Start();
        }
        if (office != null) office.View.Visible = on && visibleOnScreen;
        scroller.Visible = !on;
        if (!on) ShowDetail(null);
        UpdateOffice(force: true);
        Retime();
        Log.Note($"BOARD view={(on ? "tower" : "cards")}");
    }

    void OfficeBroken(string why)
    {
        if (IsDisposed) return;
        switcher.Enabled = false;
        Tips.SetToolTip(switcher, "大樓畫面打不開，先看卡片（" + why + "）");
        SetTower(false, remember: false);
        if (office != null) { Controls.Remove(office.View); office.Dispose(); }
    }

    /// 卡片 → 大樓 JSON（office2），內容變了才推；資料沒變時每 15 秒重組一次（Mac 看板的 15 秒保底刷新：閒晃的時段、2 小時降樓要看時間）
    void UpdateOffice(bool force)
    {
        if (!force && DateTime.UtcNow - officeAt < TimeSpan.FromSeconds(WanderPlanner.bucket)) return;
        officeAt = DateTime.UtcNow;
        if (officeSource == null)
        {
            // 正式 agent（系統匣開的戰情中心）才寫名冊、主題快取、呼叫 claude；--board-window 測試視窗只讀（同 Mac）
            officeSource = new OfficeSource(opt.Demo, official: !BoardWindowTestMode);
            officeSource.Decor.Changed += () => { try { BeginInvoke(() => UpdateOffice(force: true)); } catch { } };
            weather = new OfficeWeather(testMode: BoardWindowTestMode);
            weather.Changed += () => { try { BeginInvoke(() => UpdateOffice(force: true)); } catch { } };
            CityMonitor.testWindow = BoardWindowTestMode;
            CityMonitor.shared.Changed += _ => { try { BeginInvoke(() => UpdateOffice(force: true)); } catch { } };
        }
        // 城市、天氣掛在同一個刷新上（各自比時間決定要不要真的去讀；Mac：看板 15 秒 timer 叫 CityMonitor.tick）
        CityMonitor.shared.tick();
        weather!.tick();
        officeSource.visible = tower && visibleOnScreen && webVisible;
        var colors = new Dictionary<string, string>
        {
            ["working"] = Hex(GlowWindow.ColorOf(WorkState.Working)), ["waiting"] = Hex(GlowWindow.ColorOf(WorkState.Input)),
            ["finished"] = Hex(GlowWindow.ColorOf(WorkState.Done)),
        };
        var city = CityMonitor.off ? null : CityMonitor.shared.current;
        var now = DateTime.UtcNow;
        officeSource.lighting = Enum.TryParse<OfficeLighting>(BoardPrefs.Str("office.lighting") ?? "", out var lt) ? lt : OfficeLighting.auto;
        officeJson = officeSource.Build(lastCards, now, city, weather.main, weather.current, graph.consider(officeSource.Tower, now), colors, ReduceMotion,
                                        scanning: guardScanning, extra: Extras());
        if (detailId != null) ShowDetail(detailId);             // 細節卡跟著資料更新（人走了就收掉）
        office?.Push(officeJson);                               // OfficeHost 自己比對，沒變就不推
    }

    // MARK: 大樓網頁的選填欄位（PROTOCOL.md 的選填表：收件匣、隊長對話、派工單、進度條、天氣列）

    System.Text.Json.Nodes.JsonObject Extras()
    {
        var o = new System.Text.Json.Nodes.JsonObject
        {
            ["captainThread"] = MacMirror.Encode(captainThread),
            ["captainTasks"] = MacMirror.Encode(captainTasks),
            ["sessionThread"] = MacMirror.Encode(sessionThread),
            ["runs"] = MacMirror.Encode(runs),
            ["reviewing"] = MacMirror.Encode(Reviewer.Shared.Running.OrderBy(x => x, StringComparer.Ordinal).ToList()),
            ["captainBusy"] = captainBusy,
            ["captainModelTitle"] = BoardActions.ModelTitle(BoardActions.CaptainModel),
        };
        if (weather != null) { o["weatherSites"] = weather.sitesJson(); o["weatherMenuStatus"] = weather.menuStatus; }
        return o;
    }

    string extrasSig = "";
    bool ExtrasChanged()
    {
        var j = MacMirror.Json(Extras());
        if (j == extrasSig) return false;
        extrasSig = j;
        return true;
    }

    // MARK: 大樓網頁的動作（{type:"action", action, …}；欄位見 Web\PROTOCOL.md）

    /// 卡片 id（排隊卡是 sid#q0）或 sessionId → 卡片
    BoardCard? CardOf(JsonElement m)
    {
        string? id = Str(m, "id"), sid = Str(m, "sessionId");
        var all = lastCards.Concat(officeSource?.Islands.SelectMany(i => i.People.Select(p => p.Card)) ?? Enumerable.Empty<BoardCard>());
        return all.FirstOrDefault(c => id != null && c.Id == id) ?? all.FirstOrDefault(c => sid != null && c.SessionId == sid && !c.IsQueued);
    }
    static string? Str(JsonElement m, string k) => m.TryGetProperty(k, out var v) && v.ValueKind == JsonValueKind.String ? v.GetString() : null;

    /// 示範卡片（demo-00…）借用的是假的 session：不送任何動作（Mac：OfficeDemo.mode != nil 只顯示 toast）
    bool DemoCard(BoardCard c) => opt.Demo || c.SessionId.StartsWith("demo-", StringComparison.Ordinal);

    void Post(System.Text.Json.Nodes.JsonObject o) => office?.Post(o);
    void PostToast(string text, bool captainDone = false)
    {
        var o = new System.Text.Json.Nodes.JsonObject { ["type"] = "toast", ["text"] = text };
        if (captainDone) o["captainDone"] = true;
        Post(o);
    }

    /// 背景跑（打字進終端機、送收件匣、開 session 會等），做完回 UI 執行緒
    void Run<T>(Func<T> work, Action<T> done) =>
        Task.Run(work).ContinueWith(t =>
        {
            if (t.Exception is { } x) Log.Note($"BOARD action failed {x.InnerException ?? x}");
            try { BeginInvoke(() => { if (!IsDisposed) done(t.IsCompletedSuccessfully ? t.Result : default!); }); } catch { }
        });

    void OnOfficeAction(JsonElement m)
    {
        if (IsDisposed) return;
        var action = Str(m, "action") ?? "";
        try { HandleAction(action, m); }
        catch (Exception x) { Log.Note($"BOARD action {action} failed: {x}"); PostToast($"做不到：{x.Message}"); }
    }

    void HandleAction(string action, JsonElement m)
    {
        Log.Note($"BOARD action {action}");
        switch (action)
        {
            case "answer":
            {
                var text = Str(m, "text") ?? "";
                if (CardOf(m) is not { } c || text.Trim().Length == 0) { PostToast("找不到這張卡片（可能剛結束）"); return; }
                if (DemoCard(c)) { PostToast($"示範資料：不送出（{text.Length} 字）"); return; }
                Run(() => BoardActions.Answer(c, text), msg => { PostToast(msg ?? ""); Refresh_(); });
                return;
            }
            case "permit":
            {
                if (CardOf(m) is not { } c) { PostToast("找不到這張卡片（可能剛結束）"); return; }
                if (DemoCard(c)) { PostToast("示範資料：不回答權限"); return; }
                Dictionary<string, List<string>>? answers = null;
                if (m.TryGetProperty("answers", out var a) && a.ValueKind == JsonValueKind.Object)
                {
                    answers = new();
                    foreach (var q in a.EnumerateObject())
                        answers[q.Name] = q.Value.ValueKind == JsonValueKind.Array ? q.Value.EnumerateArray().Where(x => x.ValueKind == JsonValueKind.String).Select(x => x.GetString()!).ToList()
                                        : q.Value.ValueKind == JsonValueKind.String ? new() { q.Value.GetString()! } : new();
                }
                // 網頁看到的那個對話框已經換了（又跳了新的）⇒ 不要把舊答案套到新的上
                if (Str(m, "permitId") is { } pid && c.Permit is { } p && p.Id != pid) { PostToast($"「{c.Title}」又跳了新的對話框，請再看一次"); Refresh_(); return; }
                PostToast(BoardActions.AnswerPermit(c, Str(m, "decision") ?? "allow", Str(m, "message"), answers));
                Refresh_();
                return;
            }
            case "askCaptain":
            {
                var text = Str(m, "text") ?? "";
                if (BoardWindowTestMode) { PostToast("測試：不交給隊長", captainDone: true); return; }
                captainBusy = true;
                Post(new System.Text.Json.Nodes.JsonObject { ["type"] = "captainBusy", ["busy"] = true });
                Run(() => BoardActions.AskCaptain(text), msg =>
                {
                    captainBusy = false;
                    BoardHistory.Append(new Dictionary<string, string> { ["ev"] = "tocaptain", ["text"] = text });
                    PostToast(msg ?? "送不到隊長", captainDone: true);
                    Refresh_();
                });
                return;
            }
            case "focus":
            {
                if (CardOf(m) is not { } c) { PostToast("找不到這個 session 的視窗"); return; }
                if (DemoCard(c)) { PostToast("示範資料：不跳到視窗"); return; }
                Run(() => BoardActions.Focus(c), msg => { if (msg != null) PostToast(msg); });
                return;
            }
            case "approve":
                if (CardOf(m) is { } ac && !DemoCard(ac)) { BoardActions.Approve(ac); Refresh_(); }
                return;
            case "dispatch":
                if (CardOf(m) is { } dc)
                    OpenSheet(new DispatchSheet(this, dc, lastCards.Where(x => !x.IsQueued && x.SessionId != dc.SessionId && !x.Captain && x.Name != null).Select(x => x.Name!).ToList(),
                                                CaptainCard?.SessionId, Toast));
                return;
            case "sendBack":
                if (CardOf(m) is { } sc) OpenSheet(new SendBackSheet(this, sc, Toast));
                return;
            case "park":
                if (CardOf(m) is { } pc) OpenSheet(new ParkSheet(this, pc, () => { }));
                return;
            case "review":
                if (CardOf(m) is { } rc && !DemoCard(rc)) { Reviewer.Shared.Start(rc, force: true); UpdateOffice(force: true); }
                return;
            case "redecorate":
            {
                var project = Str(m, "project") ?? "";
                if (opt.Demo || officeSource == null) { PostToast("示範資料：不重新裝潢"); return; }
                PostToast(officeSource.Decor.redecorate(project, lastCards));
                return;
            }
            case "guardScan":
            {
                string msg;
                if (opt.Demo) msg = "示範資料：不掃描";
                else if (BoardWindowTestMode && Environment.GetEnvironmentVariable("SHOWORK_WIFIWATCH_SCRIPT") == null) msg = "測試視窗不掃描真的網路";
                else if (!File.Exists(GuardScanner.Script)) msg = $"這台電腦沒有 Wi-Fi 掃描腳本（{GuardScanner.Script}）；Mac 的 wifiwatch.sh 不能在 Windows 跑";
                else msg = GuardScan() ? "開始掃描 Wi-Fi（約數十秒）" : "已經在掃描了";
                PostToast(msg);
                return;
            }
            case "pushAllow":
            {
                if (Str(m, "dir") is { } dir) BoardActions.PushAllow(dir, Str(m, "head"));
                PostToast("已放行一次：同一個資料夾、同一個 commit 的下一次 push（30 分鐘內）");
                return;
            }
            case "watch":
            {
                var sid = Str(m, "sessionId");
                if (reader.Watching != sid) { reader.Watching = sid; sessionThread = new(); Refresh_(); }
                // 點了角色：WinForms 細節卡跟著開（11-02 P8：取代舊的 {type:"select"}；網頁的返回鈕沒有 id，不動細節卡）
                if (m.TryGetProperty("id", out var idv) && idv.ValueKind == JsonValueKind.String) ShowDetail(idv.GetString());
                return;
            }
            case "openGraph":
            {
                if (opt.Demo) { PostToast("示範資料：開啟整棟大樓知識星雲"); return; }
                var project = Str(m, "project") ?? "";
                Run(() => GraphHtml(project), r =>
                {
                    if (r == null) { PostToast("知識圖譜還沒產生（找不到 graphify 的輸出）"); return; }
                    try { Process.Start(new ProcessStartInfo(r.Value.Path) { UseShellExecute = true }); PostToast($"開啟 {r.Value.Name} 知識圖譜"); }
                    catch (Exception x) { PostToast($"開不了知識圖譜：{x.Message}"); }
                });
                return;
            }
            case "b1Refresh":
                Post(new System.Text.Json.Nodes.JsonObject { ["type"] = "b1Posts", ["posts"] = B1Json.All() });
                return;
            case "weatherSearch":
            {
                var q = Str(m, "query") ?? "";
                weather?.search(q, (rs, note) =>
                {
                    try { BeginInvoke(() => Post(new System.Text.Json.Nodes.JsonObject { ["type"] = "weatherResults", ["results"] = MacMirror.Encode(rs), ["note"] = note })); } catch { }
                });
                return;
            }
            case "setPref":
            {
                var key = Str(m, "key") ?? "";
                if (!m.TryGetProperty("value", out var v)) return;
                switch (key)
                {
                    case "lighting": case "style": BoardPrefs.Set("office." + key, v.ValueKind == JsonValueKind.String ? v.GetString() : null); break;
                    case "guardPatrol": BoardPrefs.Set("office.guardPatrol", v.ValueKind == JsonValueKind.True); break;
                    case "weather": weather?.setEnabled(v.ValueKind == JsonValueKind.True); break;
                    case "weatherPlaces":
                        if (v.ValueKind == JsonValueKind.Array)
                            weather?.setSites(v.EnumerateArray().Select(x => x.ValueKind == JsonValueKind.Object
                                ? new WeatherSite(Str(x, "title") ?? "", x.TryGetProperty("lat", out var la) && la.ValueKind == JsonValueKind.Number ? la.GetDouble() : 0,
                                                  x.TryGetProperty("lon", out var lo) && lo.ValueKind == JsonValueKind.Number ? lo.GetDouble() : 0, Str(x, "detail")) : null)
                                .OfType<WeatherSite>().ToList());
                        break;
                }
                UpdateOffice(force: true);
                return;
            }
            case "wanderVisible":
                webVisible = !(m.TryGetProperty("visible", out var wv) && wv.ValueKind == JsonValueKind.False);
                UpdateOffice(force: true);
                return;
        }
        Log.Note($"BOARD action unknown {action}");
    }
    bool webVisible = true;

    /// 點地下室神經網路要開哪一份（Mac GraphSource.htmlFor）：那個專案的 3D 星雲／graph.html；沒有就任一份
    static (string Name, string Path)? GraphHtml(string project)
    {
        string? Html(string dir) => new[] { Path.Combine(dir, "graphify-out", "graph3d.html"), Path.Combine(dir, "graphify-out", "graph.html") }.FirstOrDefault(File.Exists);
        if (Html(GraphPaths.@out(project)) is { } mine) return (project, mine);
        try
        {
            if (!Directory.Exists(GraphPaths.dir)) return null;
            foreach (var d in Directory.GetDirectories(GraphPaths.dir).OrderBy(x => x, StringComparer.Ordinal))
                if (!Path.GetFileName(d).StartsWith('_') && Html(d) is { } h) return (Path.GetFileName(d), h);
        }
        catch { }
        return null;
    }

    /// --board-window（不開 pipe、不發光的測試視窗）：不寫名冊、不呼叫 claude、天氣不連網
    static bool BoardWindowTestMode => Environment.GetCommandLineArgs().Contains("--board-window") || Environment.GetCommandLineArgs().Contains("--board-demo");

    /// 光暈顏色 → #RRGGBB（關掉的狀態是透明，給頁面預設灰）
    static string Hex(Color c) => c.A == 0 ? "#8E8E93" : $"#{c.R:X2}{c.G:X2}{c.B:X2}";
    static string? ReadText(string p) { try { return File.Exists(p) ? File.ReadAllText(p) : null; } catch { return null; } }

    /// 點了角色：大樓左下角浮一張卡（同一個 IslandCardView，只放這個人）；null＝收掉
    void ShowDetail(string? id)
    {
        if (IsDisposed) return;
        // 示範模式的大樓用 OfficeDemo 的示範卡片（demo-00…），跟卡片畫面的不是同一批 ⇒ 兩邊都找
        var all = islands.Concat(officeSource?.Islands ?? new()).SelectMany(i => i.People.Select(p => (Island: i, Person: p)));
        var who = id == null ? default : all.FirstOrDefault(x => x.Person.Id == id);
        if (who.Person == null || !tower)
        {
            if (detail != null) { Controls.Remove(detail); detail.Dispose(); detail = null; detailView = null; }
            if (detailId != null && id == null) office?.Deselect();
            detailId = null;
            return;
        }
        detailId = id;
        if (detail == null)
        {
            detail = new Panel { BackColor = Theme.Back };
            detailView = new IslandCardView(this) { Dock = DockStyle.Fill };
            var close = new Label { Text = "✕", AutoSize = false, TextAlign = ContentAlignment.MiddleCenter, Cursor = Cursors.Hand, ForeColor = Theme.Secondary, BackColor = Theme.Card };
            close.Click += (_, _) => ShowDetail(null);
            detail.Controls.Add(close);
            detail.Controls.Add(detailView);
            close.BringToFront();
            Controls.Add(detail);
        }
        detail.BringToFront();
        detailView!.SetIsland(new Island { Project = who.Island.Project, People = new() { who.Person } });
        LayoutDetail();
    }

    void LayoutDetail()
    {
        if (detail == null) return;
        float s = S;
        int dw = (int)Math.Min(480 * s, scroller.Width - 24 * s), dh = (int)(200 * s);
        detail.Bounds = new Rectangle(scroller.Left + (int)(12 * s), scroller.Bottom - dh - (int)(12 * s), Math.Max(0, dw), dh);
        if (detail.Controls.OfType<Label>().FirstOrDefault() is { } x) x.Bounds = new Rectangle(detail.Width - (int)(30 * s), (int)(6 * s), (int)(22 * s), (int)(22 * s));
    }

    // MARK: 動畫

    /// 要動才開計時器：有人在動、視窗看得到、沒開「減少動態效果」
    void Retime()
    {
        bool run = visibleOnScreen && !ReduceMotion && !tower && views.Any(v => v.Art.Moving);
        if (run && !anim.Enabled) anim.Start();
        else if (!run && anim.Enabled) anim.Stop();
    }

    void AnimateTick()
    {
        try { AnimateCore(); }
        catch (Exception x) { Failed("anim", x); }
    }

    void AnimateCore()
    {
        if (!anim.Enabled) return;
        var view = scroller.ClientRectangle;
        bool any = false;
        foreach (var v in views)
        {
            if (!v.Art.Moving) continue;
            any = true;
            // 捲到看不到的島不畫
            var r = scroller.RectangleToClient(v.Art.RectangleToScreen(v.Art.ClientRectangle));
            if (!r.IntersectsWith(view)) continue;
            v.Art.Invalidate();
            frames++;
        }
        if (!any) Retime();
    }

    void CheckVisible()
    {
        bool v = IsHandleCreated && Visible && !IsIconic(Handle) && !Occlusion.Covered(Handle);
        if (v == visibleOnScreen) return;
        visibleOnScreen = v;
        Log.Note($"BOARD visible={v} frames={frames} anim={anim.Enabled}");
        // 看不到就把 WebView2 藏起來：瀏覽器自己停掉 requestAnimationFrame，大樓不耗 GPU
        if (office != null) office.View.Visible = tower && v;
        if (v) Refresh_();
        Retime();
    }

    protected override void OnResize(EventArgs e) { base.OnResize(e); if (IsHandleCreated) CheckVisible(); }
    protected override void OnActivated(EventArgs e) { base.OnActivated(e); CheckVisible(); }
    protected override void OnMove(EventArgs e) { base.OnMove(e); if (IsHandleCreated) CheckVisible(); }

    // MARK: 主題、減少動態效果、DPI

    void PreferenceChanged(object? sender, UserPreferenceChangedEventArgs e)
    {
        if (IsDisposed) return;
        try { BeginInvoke(() => { Theme = BoardTheme.Current(); ReduceMotion = ReadReduceMotion(); ApplyTheme(); Retime(); }); } catch { }
    }

    void ApplyTheme()
    {
        BackColor = Theme.Back;
        scroller.BackColor = Theme.Back;
        usage.BackColor = Theme.Back;
        if (IsHandleCreated)
        {
            int dark = Theme.Dark ? 1 : 0;
            DwmSetWindowAttribute(Handle, 20, ref dark, sizeof(int));
        }
        foreach (var v in views) v.ThemeChanged();
        ThemeScrollBars();
        usage.Invalidate();
        scroller.Invalidate();
    }

    protected override void OnDpiChanged(DpiChangedEventArgs e)
    {
        base.OnDpiChanged(e);
        Fonts.Dispose();
        Fonts = new BoardFonts();
        ApplyMinimumSize();                         // 最小大小也跟著新 DPI（以前只在開窗時算一次）
        PerformLayout();
        foreach (var v in views) v.ThemeChanged();
    }

    /// 「控制台 > 輕鬆存取 > 在 Windows 中顯示動畫」關掉 ⇒ SPI_GETCLIENTAREAANIMATION 是 false（相當於 Mac 的減少動態效果）
    static bool ReadReduceMotion()
    {
        if (Environment.GetEnvironmentVariable("SHOWORK_REDUCE_MOTION") is "1") return true;   // 測試用：不必去改使用者的系統設定
        bool on = true;
        try { SystemParametersInfo(0x1042 /*SPI_GETCLIENTAREAANIMATION*/, 0, ref on, 0); } catch { }
        return !on;
    }

    // MARK: 截圖（只拍自己這個視窗）

    /// 驗收用截圖。主檔用 CopyFromScreen 拍螢幕上真正的像素（先叫到最上層、等一格）——PrintWindow(PW_RENDERFULLCONTENT) 會逼整個視窗重畫，
    /// 拍不到「沒變就不重畫」造成的沒更新、也拍不到系統捲軸真正的樣子（審查 10-15：同一刻 PrintWindow 有「3 座島」、螢幕上是「唯讀」）。
    /// 另存一張 PrintWindow 版（*.pw.png）對照，log 記兩張不一樣的像素比例（動畫在動，島上本來就會差一些）。
    void Snapshot(string path)
    {
        bool wasTop = TopMost;
        TopMost = true;
        SetForegroundWindow(Handle);
        Update();
        Application.DoEvents();
        Thread.Sleep(150);                          // 讓 DWM 把這一格合成到螢幕上
        DwmGetWindowAttribute(Handle, DWMWA_EXTENDED_FRAME_BOUNDS, out RECT fr, Marshal.SizeOf<RECT>());
        var crop = Rectangle.Intersect(new Rectangle(fr.Left, fr.Top, fr.Right - fr.Left, fr.Bottom - fr.Top), SystemInformation.VirtualScreen);
        using var screen = new Bitmap(crop.Width, crop.Height, System.Drawing.Imaging.PixelFormat.Format24bppRgb);
        using (var g = Graphics.FromImage(screen)) g.CopyFromScreen(crop.Location, Point.Empty, crop.Size);
        if (!wasTop) TopMost = false;
        using var printed = PrintWindowShot();
        Directory.CreateDirectory(Path.GetDirectoryName(Path.GetFullPath(path))!);
        using (var fs = File.Create(path)) screen.Save(fs, System.Drawing.Imaging.ImageFormat.Png);
        var pw = Path.ChangeExtension(path, ".pw.png");
        using (var fs = File.Create(pw)) printed.Save(fs, System.Drawing.Imaging.ImageFormat.Png);
        Log.Note($"BOARD shot {path} {crop.Size} dpi={DeviceDpi} frames={frames} anim={anim.Enabled} visible={visibleOnScreen} reduce={ReduceMotion} " +
                 $"screen_vs_print_diff={DiffRatio(screen, printed, crop.X - fr.Left, crop.Y - fr.Top):P2}");
    }

    Bitmap PrintWindowShot()
    {
        GetWindowRect(Handle, out var wr);
        DwmGetWindowAttribute(Handle, DWMWA_EXTENDED_FRAME_BOUNDS, out RECT fr, Marshal.SizeOf<RECT>());
        int w = wr.Right - wr.Left, h = wr.Bottom - wr.Top;
        using var full = new Bitmap(w, h, System.Drawing.Imaging.PixelFormat.Format32bppArgb);
        using (var g = Graphics.FromImage(full))
        {
            var hdc = g.GetHdc();
            PrintWindow(Handle, hdc, 2 /*PW_RENDERFULLCONTENT*/);
            g.ReleaseHdc(hdc);
        }
        var crop = Rectangle.Intersect(new Rectangle(fr.Left - wr.Left, fr.Top - wr.Top, fr.Right - fr.Left, fr.Bottom - fr.Top), new Rectangle(0, 0, w, h));
        var shot = new Bitmap(crop.Width, crop.Height, System.Drawing.Imaging.PixelFormat.Format24bppRgb);
        using (var g = Graphics.FromImage(shot)) g.DrawImage(full, new Rectangle(0, 0, crop.Width, crop.Height), crop, GraphicsUnit.Pixel);
        return shot;
    }

    /// 螢幕實拍（a，可能被螢幕邊緣切掉）跟 PrintWindow（b，整個視窗）重疊的部分有幾成像素不一樣（每 2 px 取樣一次，夠看出整塊沒更新）
    static double DiffRatio(Bitmap a, Bitmap b, int dx, int dy)
    {
        int n = 0, diff = 0;
        for (int y = 0; y < a.Height && y + dy < b.Height; y += 2)
            for (int x = 0; x < a.Width && x + dx < b.Width; x += 2, n++)
            {
                if (x + dx < 0 || y + dy < 0) continue;
                Color p = a.GetPixel(x, y), q = b.GetPixel(x + dx, y + dy);
                if (Math.Abs(p.R - q.R) + Math.Abs(p.G - q.G) + Math.Abs(p.B - q.B) > 24) diff++;
            }
        return n == 0 ? 0 : (double)diff / n;
    }

    /// 量測用：SHOWORK_BOARD_STATS=<檔案> ⇒ 關閉時寫下動畫一共畫了幾格
    protected override void OnFormClosed(FormClosedEventArgs e)
    {
        if (Environment.GetEnvironmentVariable("SHOWORK_BOARD_STATS") is { Length: > 0 } stats)
            try { File.WriteAllText(stats, $"frames={frames}\n"); } catch { }
        Log.Note($"BOARD close frames={frames} paints={IslandArt.PaintCount} paint_ms_avg={(IslandArt.PaintCount == 0 ? 0 : IslandArt.PaintTicks * 1000.0 / Stopwatch.Frequency / IslandArt.PaintCount):F2}");
        SystemEvents.UserPreferenceChanged -= PreferenceChanged;
        office?.Dispose();
        office = null;
        shotTimer?.Dispose();
        shotTimer = null;
        refresh.Dispose();
        anim.Dispose();
        Tips.Dispose();
        if (instance == this) instance = null;
        base.OnFormClosed(e);
        Fonts.Dispose();
    }

    public int Frames => frames;

    [DllImport("dwmapi.dll")] static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int value, int size);
    [DllImport("user32.dll")] static extern bool SystemParametersInfo(uint action, uint param, ref bool value, uint winIni);
    [DllImport("user32.dll")] static extern bool PrintWindow(IntPtr hwnd, IntPtr hdc, uint flags);
    [DllImport("user32.dll")] static extern int GetSystemMetricsForDpi(int index, uint dpi);
    [DllImport("uxtheme.dll", CharSet = CharSet.Unicode)] static extern int SetWindowTheme(IntPtr hwnd, string app, string? idList);

    /// 測試用：SHOWORK_BOARD_FAULT=paint ⇒ 島卡片畫圖時丟例外，驗 agent 不會跳例外對話框、只關戰情中心
    public static bool FaultPaint { get; } = Environment.GetEnvironmentVariable("SHOWORK_BOARD_FAULT") is "paint";

    /// agent 的 UI 執行緒例外：是戰情中心的就把它關掉（光暈、pipe 照常）
    public static void CloseAfterError()
    {
        foreach (var f in Application.OpenForms.OfType<BoardForm>().ToList()) try { f.Close(); } catch { }
    }

    sealed class BufferedPanel : Panel
    {
        public BufferedPanel() => SetStyle(ControlStyles.OptimizedDoubleBuffer | ControlStyles.AllPaintingInWmPaint | ControlStyles.ResizeRedraw, true);
    }
}

/// 視窗是不是被別的視窗完全蓋住（Windows 沒有 Mac 的 occlusionState）：
/// 從自己往上看 z-order 比較高的頂層視窗，把它們看得到的範圍挖掉，挖完沒剩就是被蓋住。
/// 點擊穿透的透明視窗（光暈之類）、隱形（cloaked）、最小化的都不算擋住。也順便把螢幕外的部分挖掉。
static class Occlusion
{
    const int NULLREGION = 1, RGN_AND = 1, RGN_DIFF = 4;
    const int GWL_EXSTYLE = -20;

    public static bool Covered(IntPtr hwnd)
    {
        if (DwmGetWindowAttribute(hwnd, DWMWA_CLOAKED, out int cloaked, sizeof(int)) == 0 && cloaked != 0) return true;   // 別的虛擬桌面
        if (DwmGetWindowAttribute(hwnd, DWMWA_EXTENDED_FRAME_BOUNDS, out RECT me, Marshal.SizeOf<RECT>()) != 0) return false;
        var rgn = CreateRectRgn(me.Left, me.Top, me.Right, me.Bottom);
        var screen = CreateRectRgn(0, 0, 0, 0);
        try
        {
            // 只留在螢幕上的部分
            foreach (var s in Screen.AllScreens)
            {
                var b = s.Bounds;
                var one = CreateRectRgn(b.Left, b.Top, b.Right, b.Bottom);
                CombineRgn(screen, screen, one, 2 /*RGN_OR*/);
                DeleteObject(one);
            }
            if (CombineRgn(rgn, rgn, screen, RGN_AND) == NULLREGION) return true;
            for (var h = GetWindow(hwnd, GW_HWNDPREV); h != IntPtr.Zero; h = GetWindow(h, GW_HWNDPREV))
            {
                if (!IsWindowVisible(h) || IsIconic(h)) continue;
                if (DwmGetWindowAttribute(h, DWMWA_CLOAKED, out int c, sizeof(int)) == 0 && c != 0) continue;
                long ex = GetWindowLongPtr(h, GWL_EXSTYLE).ToInt64();
                if ((ex & WS_EX_LAYERED) != 0 && (ex & WS_EX_TRANSPARENT) != 0) continue;     // 點擊穿透的疊加層
                if (DwmGetWindowAttribute(h, DWMWA_EXTENDED_FRAME_BOUNDS, out RECT r, Marshal.SizeOf<RECT>()) != 0 && !GetWindowRect(h, out r)) continue;
                if (r.Right <= r.Left || r.Bottom <= r.Top) continue;
                var other = CreateRectRgn(r.Left, r.Top, r.Right, r.Bottom);
                int res = CombineRgn(rgn, rgn, other, RGN_DIFF);
                DeleteObject(other);
                if (res == NULLREGION) return true;
            }
            return false;
        }
        finally { DeleteObject(rgn); DeleteObject(screen); }
    }

    [DllImport("gdi32.dll")] static extern IntPtr CreateRectRgn(int l, int t, int r, int b);
    [DllImport("gdi32.dll")] static extern int CombineRgn(IntPtr dst, IntPtr a, IntPtr b, int mode);
    [DllImport("user32.dll", EntryPoint = "GetWindowLongPtrW")] static extern IntPtr GetWindowLongPtr(IntPtr h, int i);
}

/// 讀寫門檻（設定檔屬於 App，核心規則那一半在 IslandLayout.cs，測試專案只連核心）
public static partial class ContextGuard
{
    public static double Threshold => Clamp(GlowSettings.Shared.General.CtxThreshold);
    public static void Set(double v) => GlowSettings.Shared.SetGeneral(GlowSettings.Shared.General with { CtxThreshold = Clamp(v) });
}

/// 工具列右邊：帳號流量（5 小時、7 天；Mac UsageView）。放不下一排就上下疊，不壓字（Mac 10-13 的 ViewThatFits）。
/// 11-02 P8 第二輪：左邊的「N 座島・唯讀」拿掉（Mac 沒有；看板不再唯讀），ctx 門檻搬到 BoardControls
sealed class UsageBar : Control
{
    readonly BoardForm owner;
    RateLimits? limits;
    string drawn = "";

    public UsageBar(BoardForm owner)
    {
        this.owner = owner;
        SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw, true);
        SetStyle(ControlStyles.Selectable, false);
    }

    float S => DeviceDpi / 96f;

    /// 流量。顯示的字（「剩幾分」）變了才重畫
    public void Set(RateLimits? l, int islands)
    {
        limits = l;
        var key = string.Join("|", Meters(DateTime.UtcNow).Select(m => m.Head + m.Left + m.Used));
        if (key == drawn) return;
        drawn = key;
        owner.Tips.SetToolTip(this, l?.SnapshotAt is { } at ? $"帳號流量（訂閱額度）・資料時間 {at.ToLocalTime():HH:mm}，由 Claude Code 狀態列更新"
                                                            : l != null ? "帳號流量（訂閱額度）" : "Claude Code 的狀態列要把 rate_limits 存到 ~/.claude/cache/rate_limits.json");
        Parent?.PerformLayout();                    // 寬度變了，一排／兩排可能跟著變
        Invalidate();
    }

    record struct Meter(string Label, string Head, string? Left, double Used);

    IEnumerable<Meter> Meters(DateTime now)
    {
        if (limits?.Current(now) is not { } l) yield break;
        Meter M(string label, RateLimits.Window w) => new(label, $"{(int)Math.Round(w.Used)}%",
            w.ResetsAt is { } r && r > now ? "↻ " + BubbleText.Left(r - now) : null, w.Used);
        if (l.FiveHour is { } a) yield return M("5 小時", a);
        if (l.SevenDay is { } b) yield return M("7 天", b);
    }

    Font Small => owner.Fonts.Get(11 * S);
    Font SmallBold => owner.Fonts.Get(11 * S, bold: true);
    const TextFormatFlags F = TextFormatFlags.NoPrefix | TextFormatFlags.SingleLine | TextFormatFlags.NoPadding;

    int MeterWidth(Meter m)
    {
        int w = TextRenderer.MeasureText(m.Label, Small, Size.Empty, F).Width + (int)(4 * S)
              + TextRenderer.MeasureText(m.Head, SmallBold, Size.Empty, F).Width;
        if (m.Used >= 70) w += (int)(4 * S + 11 * S);
        if (m.Left is { } left) w += (int)(4 * S) + TextRenderer.MeasureText(left, Small, Size.Empty, F).Width;
        return Math.Max(w, (int)(120 * S));
    }

    int LineH => TextRenderer.MeasureText("國", Small, Size.Empty, F).Height;
    int MeterH => LineH + (int)(3 * S + 6 * S);
    int Gap => (int)(14 * S);
    const string NoData = "帳號流量：尚無資料";

    /// 一排放得下的寬度
    public int MetersWidth
    {
        get
        {
            var ms = Meters(DateTime.UtcNow).ToList();
            return ms.Count == 0 ? TextRenderer.MeasureText(NoData, Small, Size.Empty, F).Width + 2 : ms.Sum(MeterWidth) + Gap * (ms.Count - 1);
        }
    }

    bool Stack(int width) => MetersWidth > width;

    public int HeightFor(int width)
    {
        int n = Meters(DateTime.UtcNow).Count();
        if (n == 0) return LineH;
        return Stack(width) ? n * MeterH + (n - 1) * (int)(6 * S) : MeterH;
    }

    protected override void OnPaint(PaintEventArgs e)
    {
        var g = e.Graphics;
        var th = owner.Theme;
        g.Clear(th.Back);
        g.SmoothingMode = SmoothingMode.AntiAlias;
        float s = S;
        var ms = Meters(DateTime.UtcNow).ToList();
        if (ms.Count == 0)
        {
            TextRenderer.DrawText(g, NoData, Small, new Point(0, 0), th.Secondary, F);
            return;
        }
        bool stack = Stack(Width);
        int x = 0, y = 0;
        foreach (var m in ms)
        {
            int mw = MeterWidth(m);
            DrawMeter(g, th, m, x, y, mw, s);
            if (stack) y += MeterH + (int)(6 * s); else x += mw + Gap;
        }
    }

    void DrawMeter(Graphics g, BoardTheme th, Meter m, int x, int y, int w, float s)
    {
        var level = m.Used >= 90 ? Color.FromArgb(0xFF, 0x45, 0x3A) : m.Used >= 70 ? Color.FromArgb(0xFF, 0x9F, 0x0A) : GlowWindow.ColorOf(WorkState.Working);
        int cx = x;
        void T(string text, Font f, Color c)
        {
            int tw = TextRenderer.MeasureText(text, f, Size.Empty, F).Width;
            TextRenderer.DrawText(g, text, f, new Point(cx, y), c, F);
            cx += tw + (int)(4 * s);
        }
        T(m.Label, Small, th.Secondary);
        T(m.Head, SmallBold, th.Text);
        if (m.Used >= 70)
        {
            // ⚠ 三角形（自己畫，GDI 的 emoji 是單色）
            float sz = 11 * s, ty = y + (LineH - sz) / 2f;
            using var b = new SolidBrush(level);
            g.FillPolygon(b, new[] { new PointF(cx + sz / 2, ty), new PointF(cx + sz, ty + sz), new PointF(cx, ty + sz) });
            TextRenderer.DrawText(g, "!", owner.Fonts.Get(8 * s, bold: true), new Rectangle(cx, (int)(ty + 1 * s), (int)sz, (int)sz), Color.Black,
                                  TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter | TextFormatFlags.NoPadding);
            cx += (int)(sz + 4 * s);
        }
        if (m.Left is { } left) T(left, Small, th.Tertiary);
        // 進度條：寬 120、圓頭
        float by = y + LineH + 3 * s, bh = 5 * s, bw = 120 * s;
        using (var track = IslandCardView.Rounded(new RectangleF(x, by, bw, bh), bh / 2))
        using (var tb = new SolidBrush(th.Track)) g.FillPath(tb, track);
        float fw = (float)(bw * Math.Clamp(m.Used, 0, 100) / 100);
        if (fw > 0.5f)
            using (var bar = IslandCardView.Rounded(new RectangleF(x, by, Math.Max(fw, bh), bh), bh / 2))
            using (var fb = new SolidBrush(level)) g.FillPath(fb, bar);
    }
}

/// 左上角的「卡片／大樓」切換（兩格的分段按鈕）。不能用時整個變灰、點了沒反應
sealed class ViewSwitch : Control
{
    readonly BoardForm owner;
    bool towerOn;
    static readonly string[] Labels = { "卡片", "大樓" };
    public event Action<bool>? Changed;

    public ViewSwitch(BoardForm owner)
    {
        this.owner = owner;
        SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw, true);
        SetStyle(ControlStyles.Selectable, false);
        Cursor = Cursors.Hand;
    }

    float S => DeviceDpi / 96f;
    Font F => owner.Fonts.Get(12 * S);

    public bool Tower { get => towerOn; set { if (towerOn == value) return; towerOn = value; Invalidate(); } }

    int SegW => (int)(TextRenderer.MeasureText("大樓", F).Width + 22 * S);
    public override Size GetPreferredSize(Size proposedSize) => new(SegW * 2 + (int)(4 * S), (int)(26 * S));

    protected override void OnEnabledChanged(EventArgs e) { base.OnEnabledChanged(e); Cursor = Enabled ? Cursors.Hand : Cursors.Default; Invalidate(); }

    protected override void OnMouseClick(MouseEventArgs e)
    {
        base.OnMouseClick(e);
        if (!Enabled || e.Button != MouseButtons.Left) return;
        bool t = e.X >= Width / 2;
        if (t == towerOn) return;
        Tower = t;
        Changed?.Invoke(t);
    }

    protected override void OnPaint(PaintEventArgs e)
    {
        var g = e.Graphics;
        var th = owner.Theme;
        float s = S;
        g.Clear(th.Back);
        g.SmoothingMode = SmoothingMode.AntiAlias;
        using (var p = IslandCardView.Rounded(new RectangleF(0.5f, 0.5f, Width - 1, Height - 1), 7 * s))
        using (var b = new SolidBrush(th.Card)) g.FillPath(b, p);
        float pad = 2 * s, half = (Width - pad * 2) / 2f;
        using (var p = IslandCardView.Rounded(new RectangleF(pad + (towerOn ? half : 0), pad, half, Height - pad * 2), 5 * s))
        using (var b = new SolidBrush(th.Dark ? Color.FromArgb(0x55, 0x55, 0x58) : Color.White)) g.FillPath(b, p);
        for (int i = 0; i < 2; i++)
        {
            var r = Rectangle.Round(new RectangleF(pad + i * half, 0, half, Height));
            var c = !Enabled ? th.Tertiary : (i == 1) == towerOn ? th.Text : th.Secondary;
            TextRenderer.DrawText(g, Labels[i], F, r, c, TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter | TextFormatFlags.NoPrefix);
        }
    }
}
