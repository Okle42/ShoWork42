using System.Drawing.Drawing2D;

namespace ShoWork;

// 11-02 P8 第二輪：Mac BoardWindow.swift 的工具列（新任務⋯、交給隊長⋯、AI 審核、ctx 門檻＋自動收尾）與對話框
// （SendBackSheet、ParkSheet、DispatchSheet、CaptainSheet、NewTaskSheet）的 WinForms 轉寫。
// Mac 的 sheet 從視窗上緣滑下來；Windows 用置中在戰情中心上的強制回應對話框（同樣擋住後面、Esc 取消、預設鈕是送出）。
// 多行輸入框裡 Enter 是換行（同 Mac 的 TextEditor）；Ctrl+Enter 送出。

/// 工具列：新任務⋯／交給隊長⋯兩顆按鈕、AI 審核開關、ctx 門檻（點開選 %）＋自動收尾開關。全部自己畫（同 ViewSwitch），窄的時候換短標籤
sealed class BoardControls : Control
{
    readonly BoardForm owner;
    public event Action? NewTask, ToCaptain;
    public event Action? Changed;            // 開關或門檻改了（卡片的 ctx 顏色要重畫）
    bool shortLabels;
    readonly List<(Rectangle Rect, string Id)> hits = new();
    string? hover;

    public BoardControls(BoardForm owner)
    {
        this.owner = owner;
        SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw, true);
        SetStyle(ControlStyles.Selectable, false);
    }

    float S => DeviceDpi / 96f;
    Font F => owner.Fonts.Get(12 * S);
    const TextFormatFlags TF = TextFormatFlags.NoPrefix | TextFormatFlags.SingleLine | TextFormatFlags.NoPadding;

    public bool Short { get => shortLabels; set { if (shortLabels == value) return; shortLabels = value; Invalidate(); } }

    /// 每一項：(id, 字, 種類)
    IEnumerable<(string Id, string Text, string Kind)> Items(bool s)
    {
        yield return ("newTask", s ? "新任務" : "新任務⋯", "button");
        yield return ("captain", s ? "隊長" : "交給隊長⋯", "button");
        yield return ("review", s ? "審核" : "AI 審核", "switch");
        yield return ("ctx", (s ? "" : "ctx ") + $"{CtxGuard.TokenLimit / 1000}k ⌄", "link");
        yield return ("wrap", s ? "收尾" : "自動收尾", "switch");
    }

    int Gap => (int)(12 * S);
    int ItemWidth(string text, string kind)
    {
        int tw = TextRenderer.MeasureText(text, F, Size.Empty, TF).Width;
        return kind switch
        {
            "button" => tw + (int)(30 * S),            // 圖示 12＋左右留白
            "switch" => tw + (int)(6 * S + 30 * S),
            _ => tw + (int)(4 * S),
        };
    }
    public int WidthFor(bool s) => Items(s).Sum(i => ItemWidth(i.Text, i.Kind)) + Gap * (Items(s).Count() - 1) - (int)(Gap * 0.6);
    public override Size GetPreferredSize(Size proposedSize) => new(WidthFor(shortLabels), (int)(26 * S));

    string Tip(string id) => id switch
    {
        "newTask" => "在選的資料夾開一個 Claude 背景 session（不開視窗）",
        "captain" => owner.CaptainCard == null ? $"還沒有隊長：送出時會開一個 {BoardActions.ModelTitle(BoardActions.CaptainModel)} 背景隊長" : "把一件事交給隊長，由它決定給哪個 session",
        "review" => $"AI 審核：卡片進「待審」時，請 {Reviewer.Model} 獨立審一次（走你的訂閱額度）",
        "ctx" => $"點一下改門檻：AI 記憶量用到 {CtxGuard.TokenLimit / 1000}k 就通知你；開著自動收尾時，也請那個 AI 收尾",
        _ => $"自動收尾：AI 記憶量到 {CtxGuard.TokenLimit / 1000}k 會通知你；開著時，等那個 AI 停下來就請它 commit、規則允許才 push、更新交接",
    };

    protected override void OnMouseMove(MouseEventArgs e)
    {
        base.OnMouseMove(e);
        var h = hits.FirstOrDefault(x => x.Rect.Contains(e.Location)).Id;
        Cursor = h != null ? Cursors.Hand : Cursors.Default;
        if (h == hover) return;
        hover = h;
        owner.Tips.SetToolTip(this, h == null ? null : Tip(h));
        Invalidate();
    }

    protected override void OnMouseLeave(EventArgs e) { base.OnMouseLeave(e); if (hover != null) { hover = null; Invalidate(); } }

    protected override void OnMouseClick(MouseEventArgs e)
    {
        base.OnMouseClick(e);
        if (e.Button != MouseButtons.Left) return;
        var hit = hits.FirstOrDefault(x => x.Rect.Contains(e.Location));
        switch (hit.Id)
        {
            case "newTask": NewTask?.Invoke(); break;
            case "captain": ToCaptain?.Invoke(); break;
            case "review": Reviewer.Shared.Enabled = !Reviewer.Shared.Enabled; Invalidate(); Changed?.Invoke(); break;
            case "wrap": CtxGuard.Shared.AutoWrapUp = !CtxGuard.Shared.AutoWrapUp; Invalidate(); Changed?.Invoke(); break;
            case "ctx": CtxMenu(hit.Rect); break;
        }
    }

    /// ctx 交接門檻：250k–1000k（Mac 10-29 Kang 的 CtxLimitPanel；Windows 用選單選常用值）
    void CtxMenu(Rectangle at)
    {
        var menu = new ContextMenuStrip { ShowCheckMargin = true, ShowImageMargin = false };
        menu.Items.Add(new ToolStripLabel("AI 記憶量用到多少就交接") { ForeColor = SystemColors.GrayText });
        foreach (var v in CtxGuard.TokenPresets)
        {
            var item = new ToolStripMenuItem($"{v / 1000}k" + (v == Hooks.ContextGuard.DefaultTokenLimit ? "（建議）" : "")) { Checked = v == CtxGuard.TokenLimit };
            item.Click += (_, _) => { CtxGuard.SetTokenLimit(v); Parent?.PerformLayout(); Invalidate(); Changed?.Invoke(); };
            menu.Items.Add(item);
        }
        menu.Items.Add(new ToolStripLabel("只看這一個條件：到了就通知你；開著自動收尾時，等那個 AI 停下來就請它收尾交接。") { ForeColor = SystemColors.GrayText });
        menu.Closed += (_, _) => BeginInvoke(menu.Dispose);
        menu.Show(this, new Point(at.Left, at.Bottom));
    }

    protected override void OnPaint(PaintEventArgs e)
    {
        var g = e.Graphics;
        var th = owner.Theme;
        float s = S;
        g.Clear(th.Back);
        g.SmoothingMode = SmoothingMode.AntiAlias;
        hits.Clear();
        int x = 0, h = Height;
        int lineH = TextRenderer.MeasureText("國", F, Size.Empty, TF).Height;
        var items = Items(shortLabels).ToList();
        for (int i = 0; i < items.Count; i++)
        {
            var (id, text, kind) = items[i];
            int w = ItemWidth(text, kind);
            var r = new Rectangle(x, 0, w, h);
            bool hot = hover == id;
            switch (kind)
            {
                case "button":
                    using (var p = IslandCardView.Rounded(new RectangleF(r.X + 0.5f, r.Y + 0.5f, r.Width - 1, r.Height - 1), 6 * s))
                    {
                        using var b = new SolidBrush(hot ? Lighten(th.Card, th.Dark ? 18 : -10) : th.Card);
                        g.FillPath(b, p);
                        using var pen = new Pen(th.Separator);
                        g.DrawPath(pen, p);
                    }
                    var ic = new RectangleF(r.X + 9 * s, (h - 12 * s) / 2, 12 * s, 12 * s);
                    if (id == "newTask") Plus(g, ic, th.Text, s); else Crown(g, ic, th.Text);
                    TextRenderer.DrawText(g, text, F, new Point((int)(r.X + 25 * s), (h - lineH) / 2), th.Text, TF);
                    break;
                case "switch":
                    bool on = id == "review" ? Reviewer.Shared.Enabled : CtxGuard.Shared.AutoWrapUp;
                    TextRenderer.DrawText(g, text, F, new Point(r.X, (h - lineH) / 2), th.Text, TF);
                    float tw = 26 * s, tht = 15 * s, tx = r.Right - tw, ty = (h - tht) / 2;
                    using (var p = IslandCardView.Rounded(new RectangleF(tx, ty, tw, tht), tht / 2))
                    using (var b = new SolidBrush(on ? Accent(th) : th.Track)) g.FillPath(b, p);
                    float k = tht - 3 * s, kx = on ? tx + tw - k - 1.5f * s : tx + 1.5f * s;
                    using (var b = new SolidBrush(Color.White)) g.FillEllipse(b, kx, ty + 1.5f * s, k, k);
                    break;
                default:
                    TextRenderer.DrawText(g, text, F, new Point(r.X, (h - lineH) / 2), hot ? Accent(th) : th.Text, TF);
                    break;
            }
            hits.Add((r, id));
            x += w + (kind == "link" ? (int)(Gap * 0.4) : Gap);
        }
    }

    static Color Accent(BoardTheme th) => th.Dark ? Color.FromArgb(0x0A, 0x84, 0xFF) : Color.FromArgb(0x00, 0x7A, 0xFF);
    static Color Lighten(Color c, int d) => Color.FromArgb(Math.Clamp(c.R + d, 0, 255), Math.Clamp(c.G + d, 0, 255), Math.Clamp(c.B + d, 0, 255));

    /// SF Symbols 的 plus
    static void Plus(Graphics g, RectangleF r, Color c, float s)
    {
        using var pen = new Pen(c, 1.6f * s) { StartCap = LineCap.Round, EndCap = LineCap.Round };
        float cx = r.X + r.Width / 2, cy = r.Y + r.Height / 2, k = r.Width * 0.42f;
        g.DrawLine(pen, cx - k, cy, cx + k, cy);
        g.DrawLine(pen, cx, cy - k, cx, cy + k);
    }

    /// SF Symbols 的 crown（三個尖、底下一條）
    static void Crown(Graphics g, RectangleF r, Color c)
    {
        float x = r.X, y = r.Y, w = r.Width, hh = r.Height;
        var pts = new[]
        {
            new PointF(x, y + hh * 0.25f), new PointF(x + w * 0.28f, y + hh * 0.55f), new PointF(x + w * 0.5f, y + hh * 0.1f),
            new PointF(x + w * 0.72f, y + hh * 0.55f), new PointF(x + w, y + hh * 0.25f), new PointF(x + w * 0.88f, y + hh * 0.78f),
            new PointF(x + w * 0.12f, y + hh * 0.78f),
        };
        using var b = new SolidBrush(c);
        g.FillPolygon(b, pts);
        g.FillRectangle(b, x + w * 0.12f, y + hh * 0.84f, w * 0.76f, hh * 0.14f);
    }
}

/// 對話框的底：標題、說明、內容、右下角「取消／送出」（Mac 的 sheet：padding 20、寬 420–520）
abstract class SheetForm : Form
{
    protected readonly BoardTheme Th;
    protected readonly TableLayoutPanel Body;
    protected readonly Button Ok, Cancel;
    protected readonly Label Busy, Error;
    readonly FlowLayoutPanel buttons;

    protected SheetForm(BoardForm owner, string title, string okText, int width)
    {
        Th = owner.Theme;
        Text = "AI工作戰情中心";
        FormBorderStyle = FormBorderStyle.FixedDialog;
        MaximizeBox = MinimizeBox = false;
        ShowInTaskbar = false;
        StartPosition = FormStartPosition.CenterParent;
        AutoScaleMode = AutoScaleMode.Dpi;
        Font = new Font(BoardFonts.Family, 10f);
        BackColor = Th.Back;
        ForeColor = Th.Text;
        AutoSize = true;
        AutoSizeMode = AutoSizeMode.GrowAndShrink;
        Padding = new Padding(20);
        Body = new TableLayoutPanel { ColumnCount = 1, AutoSize = true, AutoSizeMode = AutoSizeMode.GrowAndShrink, Dock = DockStyle.Fill, Width = width };
        Body.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, width));
        Controls.Add(Body);
        AddLabel(title, bold: true, size: 12f);
        Ok = new Button { Text = okText, AutoSize = true, Enabled = false, FlatStyle = FlatStyle.System };
        Cancel = new Button { Text = "取消", AutoSize = true, DialogResult = DialogResult.Cancel, FlatStyle = FlatStyle.System };
        Busy = new Label { AutoSize = true, ForeColor = Th.Secondary, Visible = false, Margin = new Padding(0, 8, 12, 0) };
        Error = new Label { AutoSize = true, ForeColor = Color.FromArgb(0xFF, 0x45, 0x3A), Visible = false, MaximumSize = new Size(width, 0), Margin = new Padding(0, 4, 0, 0) };
        buttons = new FlowLayoutPanel { FlowDirection = FlowDirection.RightToLeft, AutoSize = true, Dock = DockStyle.Fill, WrapContents = false, Margin = new Padding(0, 10, 0, 0) };
        buttons.Controls.Add(Ok); buttons.Controls.Add(Cancel); buttons.Controls.Add(Busy);
        AcceptButton = Ok;
        CancelButton = Cancel;
        Ok.Click += (_, _) => Submit();
        KeyPreview = true;
        KeyDown += (_, e) => { if (e.Control && e.KeyCode == Keys.Enter && Ok.Enabled) { e.SuppressKeyPress = true; Submit(); } };
        HandleCreated += (_, _) =>
        {
            int dark = Th.Dark ? 1 : 0;
            DwmSetWindowAttribute(Handle, 20, ref dark, sizeof(int));
        };
    }

    /// 子類別加完內容後叫：錯誤訊息與按鈕列放最後
    protected void Finish() { Body.Controls.Add(Error); Body.Controls.Add(buttons); }

    protected Label AddLabel(string text, bool bold = false, float size = 10f, bool secondary = false, Color? color = null)
    {
        var l = new Label
        {
            Text = text, AutoSize = true, MaximumSize = new Size(Body.ColumnStyles[0].Width is var w ? (int)w : 460, 0),
            Font = new Font(BoardFonts.Family, size, bold ? FontStyle.Bold : FontStyle.Regular), ForeColor = color ?? (secondary ? Th.Secondary : Th.Text),
            Margin = new Padding(0, 0, 0, 8), UseMnemonic = false,
        };
        Body.Controls.Add(l);
        return l;
    }

    protected TextBox AddText(int lines, string? placeholder = null)
    {
        var t = new TextBox
        {
            Multiline = lines > 1, AcceptsReturn = lines > 1, ScrollBars = lines > 1 ? ScrollBars.Vertical : ScrollBars.None, Dock = DockStyle.Fill,
            Height = lines > 1 ? lines * 22 : 26, PlaceholderText = placeholder ?? "", BackColor = Th.Bubble, ForeColor = Th.Text, BorderStyle = BorderStyle.FixedSingle,
            Margin = new Padding(0, 0, 0, 8),
        };
        Body.Controls.Add(t);
        return t;
    }

    protected CheckBox AddCheck(string text)
    {
        var c = new CheckBox { Text = text, AutoSize = true, ForeColor = Th.Text, Margin = new Padding(0, 0, 0, 8), UseMnemonic = false };
        Body.Controls.Add(c);
        return c;
    }

    protected void ShowError(string? m) { Error.Text = m ?? ""; Error.Visible = m != null; }
    protected void SetBusy(bool on, string text = "")
    {
        Busy.Text = on ? "⏳ " + text : ""; Busy.Visible = on;
        Ok.Enabled = !on && CanSubmit(); Cancel.Enabled = !on;
    }

    protected abstract bool CanSubmit();
    protected abstract void Submit();
    protected void Recheck() => Ok.Enabled = !Busy.Visible && CanSubmit();

    /// 背景跑（會等的：開 session、送訊息、打字進終端機），回 UI 執行緒收尾
    protected void Background<T>(Func<T> work, Action<T> done)
    {
        Task.Run(work).ContinueWith(t =>
        {
            if (IsDisposed) return;
            try { BeginInvoke(() => { if (!IsDisposed) done(t.IsCompletedSuccessfully ? t.Result : default!); }); } catch { }
        });
    }

    [System.Runtime.InteropServices.DllImport("dwmapi.dll")] static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int value, int size);
}

/// 退回並補指示（Mac SendBackSheet）
sealed class SendBackSheet : SheetForm
{
    readonly BoardCard card;
    readonly TextBox text;
    readonly Action<string> onDone;

    public SendBackSheet(BoardForm owner, BoardCard card, Action<string> onDone) : base(owner, $"退回「{card.Title}」", "送出", 420)
    {
        this.card = card; this.onDone = onDone;
        AddLabel("這句話會打進那個 session 的輸入框並送出；打不進去（例如以系統管理員開的終端機）會拷貝到剪貼簿並跳過去。", secondary: true);
        text = AddText(5);
        text.TextChanged += (_, _) => Recheck();
        Finish();
    }

    protected override bool CanSubmit() => text.Text.Trim().Length > 0;
    protected override void Submit()
    {
        if (!CanSubmit()) return;
        SetBusy(true, "送出中⋯");
        var t = text.Text;
        Background(() => BoardActions.SendBack(card, t), r => { onDone(r.Message); Close(); });
    }
}

/// 丟回待辦（Mac ParkSheet）
sealed class ParkSheet : SheetForm
{
    readonly BoardCard card;
    readonly TextBox note;
    readonly Action onDone;

    public ParkSheet(BoardForm owner, BoardCard card, Action onDone) : base(owner, $"把「{card.Title}」丟回待辦", "丟回待辦", 380)
    {
        this.card = card; this.onDone = onDone;
        note = AddText(1, "備註（選填），例如：下週再看");
        AddLabel("這個 session 一有新動靜，就會自動回到它該在的欄。", secondary: true);
        Finish();
        Ok.Enabled = true;
    }

    protected override bool CanSubmit() => true;
    protected override void Submit() { BoardActions.Park(card, note.Text.Trim()); onDone(); Close(); }
}

/// 看板上直接派工（可設接力：它做完自動交給下一個；Mac DispatchSheet）
sealed class DispatchSheet : SheetForm
{
    readonly BoardCard card;
    readonly string? captain;
    readonly TextBox text, thenText;
    readonly CheckBox relay;
    readonly ComboBox thenTo;
    readonly Action<string> onDone;

    public DispatchSheet(BoardForm owner, BoardCard card, List<string> others, string? captain, Action<string> onDone)
        : base(owner, $"派工給 {card.Name ?? card.Title}", "派出", 440)
    {
        this.card = card; this.captain = captain; this.onDone = onDone;
        AddLabel($"{card.Project}・{card.Title}", secondary: true);
        if (card.SameProject.Count > 0) AddLabel($"‼ 同專案還有 {string.Join("、", card.SameProject)}", color: Th.Warn);
        AddLabel("訊息會排進它的收件匣，下一次它用工具時讀到，不會打進輸入框。" + (captain == null ? "回報會用系統通知告訴你。" : "回報會傳給隊長。"), secondary: true);
        text = AddText(5);
        relay = AddCheck("做完後自動交給下一個（接力）");
        relay.Enabled = others.Count > 0;
        thenTo = new ComboBox { DropDownStyle = ComboBoxStyle.DropDownList, Dock = DockStyle.Fill, Visible = false, Margin = new Padding(0, 0, 0, 8) };
        thenTo.Items.Add("請選擇");
        foreach (var o in others) thenTo.Items.Add(o);
        thenTo.SelectedIndex = 0;
        Body.Controls.Add(thenTo);
        thenText = AddText(1, "下一棒要做什麼（會附上這一棒的回報）");
        thenText.Visible = false;
        relay.CheckedChanged += (_, _) => { thenTo.Visible = thenText.Visible = relay.Checked; Recheck(); };
        foreach (var c in new Control[] { text, thenText }) c.TextChanged += (_, _) => Recheck();
        thenTo.SelectedIndexChanged += (_, _) => Recheck();
        Finish();
    }

    protected override bool CanSubmit() =>
        text.Text.Trim().Length > 0 && (!relay.Checked || (thenTo.SelectedIndex > 0 && thenText.Text.Trim().Length > 0));

    protected override void Submit()
    {
        if (!CanSubmit()) return;
        SetBusy(true);
        ShowError(null);
        string t = text.Text, cap = captain ?? "";
        string? nt = relay.Checked ? (string)thenTo.SelectedItem! : null, nx = relay.Checked ? thenText.Text : null;
        Background(() => BoardActions.Dispatch(card, t, nt, nx, captain), r =>
        {
            SetBusy(false);
            if (r.Id is { } id)
            {
                BoardHistory.Append(new Dictionary<string, string> { ["ev"] = "dispatch", ["id"] = id, ["to"] = card.SessionId, ["text"] = t });
                onDone($"已派工 {id} 給 {card.Name ?? card.Title}");
                Close();
            }
            else ShowError($"送不出去：{r.Error}");
        });
    }
}

/// 交給隊長：由隊長決定給誰（Mac CaptainSheet）
sealed class CaptainSheet : SheetForm
{
    readonly BoardCard? captain;
    readonly TextBox text;
    readonly bool testMode;
    readonly Action<string> onDone;

    public CaptainSheet(BoardForm owner, BoardCard? captain, bool testMode, Action<string> onDone)
        : base(owner, captain != null ? $"♛ 交給隊長（{captain.Name ?? captain.Title}）" : $"♛ 交給隊長（送出時開 {BoardActions.ModelTitle(BoardActions.CaptainModel)} 隊長）", "交給隊長", 440)
    {
        this.captain = captain; this.testMode = testMode; this.onDone = onDone;
        AddLabel("隊長會看名冊，決定交給哪個 session，或自己做。訊息排進它的收件匣，不會打斷它正在做的事。", secondary: true);
        text = AddText(6);
        text.TextChanged += (_, _) => Recheck();
        Finish();
    }

    protected override bool CanSubmit() => text.Text.Trim().Length > 0;
    protected override void Submit()
    {
        if (!CanSubmit()) return;
        // 測試視窗看的是你真的 session：不送、不開隊長
        if (testMode) { onDone("測試：不交給隊長"); Close(); return; }
        SetBusy(true, captain == null ? "正在開隊長⋯" : "送出中⋯");
        var t = text.Text;
        Background(() => BoardActions.AskCaptain(t), msg =>
        {
            BoardHistory.Append(new Dictionary<string, string> { ["ev"] = "tocaptain", ["text"] = t });
            onDone(msg ?? "送不到隊長");
            Close();
        });
    }
}

/// 新任務：在選的資料夾開 Claude 背景 session（Mac NewTaskSheet）
sealed class NewTaskSheet : SheetForm
{
    readonly ComboBox folder;
    readonly Label path;
    readonly TextBox prompt;
    readonly CheckBox fullAuto;
    readonly List<string> folders;
    readonly Action<string> onDone;

    public NewTaskSheet(BoardForm owner, List<string> folders, Action<string> onDone) : base(owner, "新任務", "開始", 480)
    {
        this.folders = folders.ToList(); this.onDone = onDone;
        AddLabel("在選的資料夾開一個 Claude 背景 session（不開視窗），看板上看得到；要看細節用 claude attach。", secondary: true);
        var row = new FlowLayoutPanel { AutoSize = true, WrapContents = false, Dock = DockStyle.Fill, Margin = new Padding(0, 0, 0, 4) };
        row.Controls.Add(new Label { Text = "資料夾", AutoSize = true, ForeColor = Th.Text, Margin = new Padding(0, 6, 8, 0) });
        folder = new ComboBox { DropDownStyle = ComboBoxStyle.DropDownList, Width = 300 };
        var pick = new Button { Text = "選擇⋯", AutoSize = true, FlatStyle = FlatStyle.System };
        row.Controls.Add(folder); row.Controls.Add(pick);
        Body.Controls.Add(row);
        path = AddLabel("", size: 8.5f, secondary: true);
        AddLabel("要它做什麼");
        prompt = AddText(6);
        fullAuto = AddCheck("全自動（不問權限，等同 bypassPermissions）");
        Finish();
        Fill(null);
        folder.SelectedIndexChanged += (_, _) => { path.Text = Selected ?? ""; Recheck(); };
        prompt.TextChanged += (_, _) => Recheck();
        pick.Click += (_, _) =>
        {
            using var d = new FolderBrowserDialog { UseDescriptionForTitle = true, Description = "新任務要在哪個資料夾跑" };
            if (d.ShowDialog(this) != DialogResult.OK) return;
            if (!this.folders.Contains(d.SelectedPath, StringComparer.OrdinalIgnoreCase)) this.folders.Add(d.SelectedPath);
            Fill(d.SelectedPath);
        };
    }

    string? Selected => folder.SelectedIndex > 0 ? folders[folder.SelectedIndex - 1] : null;

    void Fill(string? select)
    {
        folder.Items.Clear();
        folder.Items.Add("請選擇");
        foreach (var f in folders) folder.Items.Add(BoardPath.LastComponent(f));
        folder.SelectedIndex = select == null ? 0 : folders.FindIndex(f => string.Equals(f, select, StringComparison.OrdinalIgnoreCase)) + 1;
    }

    protected override bool CanSubmit() => Selected != null && prompt.Text.Trim().Length > 0;
    protected override void Submit()
    {
        if (!CanSubmit()) return;
        SetBusy(true);
        ShowError(null);
        string f = Selected!, p = prompt.Text; bool a = fullAuto.Checked;
        Background(() => BoardActions.NewTask(f, p, a), r =>
        {
            SetBusy(false);
            if (r.Id is { } id)
            {
                BoardHistory.Append(new Dictionary<string, string> { ["ev"] = "newtask", ["folder"] = f, ["bg"] = id, ["prompt"] = p });
                onDone($"已開背景 session {id}");
                Close();
            }
            else ShowError(r.Error?.Contains("not trusted") == true ? "這個資料夾還沒信任過：先在終端機進去跑一次 claude 並同意。" : r.Error);
        });
    }
}
