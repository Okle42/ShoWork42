using System.Diagnostics;
using System.Drawing.Drawing2D;
using System.Runtime.InteropServices;
using System.Text.Json;
using Microsoft.Win32;
using static ShoWork.Native;

namespace ShoWork;

/// 戰情中心視窗（唯讀版）：部門島卡片格＋工具列的帳號流量。Mac 版 BoardWindow.swift／IslandView.swift 的移植。
/// 不做會動到別的東西的按鈕（新任務、交給隊長、AI 審核、自動收尾、退回、放行、丟待辦），也不跳到終端機視窗。
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
    TowerRegistry? registry;                        // 樓層號名冊（board\tower.json；示範資料只放記憶體）
    List<BoardCard> lastCards = new();
    string officeJson = "";
    DateTime officeAt;                              // 上次組大樓的時間（資料沒變也每分鐘重組一次：2 小時降樓要看時間）
    Panel? detail;                                  // 點角色後浮在大樓上的那張卡（沿用 IslandCardView）
    IslandCardView? detailView;
    string? detailId;
    static string ViewPrefPath => Path.Combine(Wire.SupportDir, "board", "board-view.txt");
    static string RegistryPath => Path.Combine(Wire.SupportDir, "board", "tower.json");

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
        Controls.Add(switcher);
        Controls.Add(usage);
        Controls.Add(scroller);
        ApplyTheme();
        refresh.Tick += (_, _) => Refresh_();
        anim.Tick += (_, _) => AnimateTick();
        SystemEvents.UserPreferenceChanged += PreferenceChanged;
        if (opt.TopMost) TopMost = true;
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
        switcher.Bounds = new Rectangle(pad, (int)(12 * s), sw.Width, sw.Height);
        int uw = Math.Max(0, w - sw.Width - (int)(12 * s));
        int uh = usage.HeightFor(uw);
        usage.Bounds = new Rectangle(switcher.Right + (int)(12 * s), (int)(12 * s), uw, uh);
        int top = Math.Max(usage.Bottom, switcher.Bottom) + (int)(12 * s);
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
            List<BoardCard> cards; RateLimits? limits;
            if (opt.Demo) { cards = BoardDemo.Cards(demoAt); limits = BoardDemo.Limits(demoAt); }
            else
            {
                var snap = reader.Read();
                cards = reader.Cards(snap, now);
                limits = snap.RateLimits;
            }
            var sig = JsonSerializer.Serialize(cards, Board.DumpJson);
            return (cards, limits, sig);
        }).ContinueWith(t =>
        {
            if (t.Exception is { } x) Log.Note($"BOARD read failed {x.InnerException ?? x}");
            if (IsDisposed) return;
            try
            {
                BeginInvoke(() =>
                {
                    reading = false;
                    try { if (t.IsCompletedSuccessfully) Apply(t.Result.cards, t.Result.limits, t.Result.sig); }
                    catch (Exception x2) { Failed("apply", x2); }
                });
            }
            catch { }
        });
    }

    /// 門檻改了：卡片上 ctx 的顏色跟著變（資料沒變，只重畫）
    public void Repaint() { foreach (var v in views) v.Invalidate(true); }

    void Apply(List<BoardCard> cards, RateLimits? limits, string sig)
    {
        if (IsDisposed) return;
        lastCards = cards;
        if (sig == signature) { usage.Set(limits, islands.Count); UpdateOffice(force: false); Retime(); return; }
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

    /// 卡片 → 大樓 JSON，內容變了才推；資料沒變時每分鐘重組一次（2 小時降樓要看時間）
    void UpdateOffice(bool force)
    {
        if (!force && DateTime.UtcNow - officeAt < TimeSpan.FromMinutes(1)) return;
        officeAt = DateTime.UtcNow;
        registry ??= opt.Demo ? new TowerRegistry() : TowerRegistry.Decode(ReadText(RegistryPath));
        var colors = new Dictionary<string, string>
        {
            ["working"] = Hex(GlowWindow.ColorOf(WorkState.Working)), ["waiting"] = Hex(GlowWindow.ColorOf(WorkState.Input)),
            ["finished"] = Hex(GlowWindow.ColorOf(WorkState.Done)),
        };
        var (snap, dirty) = OfficeScene.Build(lastCards, registry, DateTime.UtcNow, colors: colors, reduceMotion: ReduceMotion);
        if (dirty && !opt.Demo)
        {
            try
            {
                Directory.CreateDirectory(Path.GetDirectoryName(RegistryPath)!);
                var tmp = RegistryPath + $".{Environment.ProcessId}.tmp";
                File.WriteAllText(tmp, registry.Encode());
                File.Move(tmp, RegistryPath, overwrite: true);
            }
            catch (Exception x) { Log.Note($"OFFICE registry save failed {x.Message}"); }
        }
        if (detailId != null) ShowDetail(detailId);             // 細節卡跟著資料更新（人走了就收掉）
        officeJson = OfficeScene.Json(snap);
        office?.Push(officeJson);                               // OfficeHost 自己比對，沒變就不推
    }

    /// 光暈顏色 → #RRGGBB（關掉的狀態是透明，給頁面預設灰）
    static string Hex(Color c) => c.A == 0 ? "#8E8E93" : $"#{c.R:X2}{c.G:X2}{c.B:X2}";
    static string? ReadText(string p) { try { return File.Exists(p) ? File.ReadAllText(p) : null; } catch { return null; } }

    /// 點了角色：大樓左下角浮一張卡（同一個 IslandCardView，只放這個人）；null＝收掉
    void ShowDetail(string? id)
    {
        if (IsDisposed) return;
        var who = id == null ? default : islands.SelectMany(i => i.People.Select(p => (Island: i, Person: p))).FirstOrDefault(x => x.Person.Id == id);
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

/// 工具列：帳號流量（5 小時、7 天）。左邊寫島數／session 數。放不下一排就換兩排，不壓字（Mac 10-13 的 ViewThatFits）
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

    // ctx 門檻（Mac 10-15 Kang：可調，建議 70%）：左邊字後面一個可點的「ctx 85% ⌄」，點開選 60～90%
    Rectangle ctxHit;
    string CtxLabel => $"ctx {(int)ContextGuard.Threshold}% ⌄";
    const string Sep = "　・　";

    protected override void OnMouseMove(MouseEventArgs e)
    {
        base.OnMouseMove(e);
        Cursor = ctxHit.Contains(e.Location) ? Cursors.Hand : Cursors.Default;
    }

    protected override void OnMouseClick(MouseEventArgs e)
    {
        base.OnMouseClick(e);
        if (e.Button != MouseButtons.Left || !ctxHit.Contains(e.Location)) return;
        var menu = new ContextMenuStrip { ShowCheckMargin = true, ShowImageMargin = false };
        menu.Items.Add(new ToolStripLabel("超過就該收尾（卡片上的 ctx 變紅）") { ForeColor = SystemColors.GrayText });
        foreach (var v in ContextGuard.Choices)
        {
            var item = new ToolStripMenuItem($"{(int)v}%" + (v == 70 ? "（建議）" : "")) { Checked = v == ContextGuard.Threshold };
            item.Click += (_, _) =>
            {
                ContextGuard.Set(v);
                drawn = "";
                Parent?.PerformLayout();
                Invalidate();
                owner.Repaint();
            };
            menu.Items.Add(item);
        }
        menu.Closed += (_, _) => BeginInvoke(menu.Dispose);
        menu.Show(this, new Point(ctxHit.Left, ctxHit.Bottom));
    }

    int islandCount;

    /// 流量＋島數。顯示的字（左邊的「N 座島」、流量的「剩幾分」）變了才重畫
    public void Set(RateLimits? l, int islands)
    {
        limits = l;
        islandCount = islands;
        var key = Summary() + "|" + string.Join("|", Meters(DateTime.UtcNow).Select(m => m.Head + m.Left + m.Used));
        if (key == drawn) return;
        drawn = key;
        Parent?.PerformLayout();                    // Summary 寬度變了，一排／兩排可能跟著變
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

    /// 排法：一排（左字＋右流量表）→ 兩排（字一排、流量表一排）→ 三排（流量表也上下疊）
    (int Rows, bool StackMeters) Plan(int width)
    {
        var ms = Meters(DateTime.UtcNow).ToList();
        int gap = (int)(14 * S);
        int metersW = ms.Count == 0 ? TextRenderer.MeasureText(NoData, Small, Size.Empty, F).Width : ms.Sum(MeterWidth) + gap * (ms.Count - 1);
        int summaryW = TextRenderer.MeasureText(Summary() + Sep + CtxLabel, owner.Fonts.Get(12 * S), Size.Empty, F).Width;
        if (summaryW + gap * 2 + metersW <= width) return (1, false);
        if (metersW <= width) return (2, false);
        return (2, true);
    }

    const string NoData = "帳號流量：尚無資料";

    string Summary() => islandCount == 0 ? "唯讀" : $"{islandCount} 座島・唯讀";

    public int HeightFor(int width)
    {
        var (rows, stack) = Plan(width);
        int n = Meters(DateTime.UtcNow).Count();
        int meters = n == 0 ? LineH : stack ? n * MeterH + (n - 1) * (int)(6 * S) : MeterH;
        return rows == 1 ? Math.Max(meters, LineH) : LineH + (int)(8 * S) + meters;
    }

    protected override void OnPaint(PaintEventArgs e)
    {
        var g = e.Graphics;
        var th = owner.Theme;
        g.Clear(th.Back);
        g.SmoothingMode = SmoothingMode.AntiAlias;
        float s = S;
        var now = DateTime.UtcNow;
        var ms = Meters(now).ToList();
        var (rows, stack) = Plan(Width);
        int gap = (int)(14 * s);
        // 左邊的字
        var sf = owner.Fonts.Get(12 * s);
        var head = Summary() + Sep;
        TextRenderer.DrawText(g, head, sf, new Rectangle(0, 0, Width, LineH + (int)(2 * s)), th.Secondary, F | TextFormatFlags.EndEllipsis);
        int cx = TextRenderer.MeasureText(head, sf, Size.Empty, F).Width;
        var label = CtxLabel;
        var lsz = TextRenderer.MeasureText(label, sf, Size.Empty, F);
        TextRenderer.DrawText(g, label, sf, new Point(cx, 0), th.Text, F);
        ctxHit = new Rectangle(cx - (int)(4 * s), 0, lsz.Width + (int)(8 * s), LineH + (int)(4 * s));
        int y = rows == 1 ? 0 : LineH + (int)(8 * s);
        if (ms.Count == 0)
        {
            int w0 = TextRenderer.MeasureText(NoData, Small, Size.Empty, F).Width;
            TextRenderer.DrawText(g, NoData, Small, new Point(rows == 1 ? Width - w0 : 0, y), th.Secondary, F);
            return;
        }
        int total = ms.Sum(MeterWidth) + gap * (ms.Count - 1);
        int x = rows == 1 ? Width - total : 0;
        foreach (var m in ms)
        {
            int mw = MeterWidth(m);
            DrawMeter(g, th, m, x, y, mw, s);
            if (stack) y += MeterH + (int)(6 * s); else x += mw + gap;
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
